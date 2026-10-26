import Foundation

let webPParserName = "MediaMetadata.WebPMetadataParser"
/// Chunk headers walked before giving up. An animated WebP has one `ANMF` per frame, so
/// this is what bounds the walk toward a trailing `EXIF`.
private let maxWebPChunkCount = 4096

/// Reads a WebP's size and its Exif.
///
/// A WebP is a RIFF file with form type `WEBP`. The size comes from, in order of
/// authority: the extended-format `VP8X` canvas, or — in a simple-format file, which has
/// no `VP8X` — the bitstream header of its one `VP8 ` (lossy) or `VP8L` (lossless) chunk.
/// Exif sits in an `EXIF` chunk, which the format puts after the image data, so the walk
/// reads chunk headers past the bitstream without reading its payload.
///
/// The walk ends once nothing more can be learned: when the size is known and either the
/// Exif has been read or the `VP8X` flags say there is none. Without a `VP8X` a
/// conforming file holds only its one bitstream chunk, so the walk ends at the file's end.
struct WebPMetadataParser {
    private let source: MediaByteSource
    private var result: StillImageResult

    init(source: MediaByteSource, fileExtension: String) {
        self.source = source
        result = StillImageResult(family: .webp, fileExtension: fileExtension, parser: webPParserName)
    }

    mutating func parse() -> ParsedMetadata {
        var offset: UInt64 = 12
        var chunkCount = 0
        /// `nil` until a `VP8X` says whether an `EXIF` chunk follows.
        var declaresExif: Bool?
        while let headerEnd = adding(offset, 8), headerEnd <= source.size {
            guard chunkCount < maxWebPChunkCount else {
                result.appendDiagnostic(code: "webpChunkLimitExceeded", message: "WebP chunk count exceeded the parser limit.", byteRange: nil)
                break
            }
            chunkCount += 1
            guard let header = try? source.data(offset: offset, length: 8), header.count == 8 else {
                result.appendDiagnostic(code: "webpTruncatedChunkHeader", message: "Could not read a WebP chunk header.", byteRange: offset..<headerEnd)
                break
            }
            let bytes = Array(header)
            let type = String(decoding: bytes[0..<4], as: UTF8.self)
            let length = UInt64(littleEndian(bytes[4..<8]))
            guard let payloadEnd = adding(headerEnd, length), payloadEnd <= source.size else {
                result.appendDiagnostic(
                    code: "webpChunkExceedsFile",
                    message: "WebP chunk \(type) extends past the end of the file.",
                    byteRange: offset..<source.size
                )
                break
            }
            let payload = headerEnd..<payloadEnd
            switch type {
            case "VP8X" where declaresExif == nil:
                declaresExif = readExtendedHeader(payload: payload)
            case "VP8 " where declaresExif == nil && result.size == nil:
                readLossyHeader(payload: payload)
            case "VP8L" where declaresExif == nil && result.size == nil:
                readLosslessHeader(payload: payload)
            case "EXIF" where !result.hasEmbeddedExif:
                if !result.parseEmbeddedExif(source: source, payload: payload) {
                    result.appendDiagnostic(code: "webpExifUnreadable", message: "The WebP EXIF chunk does not hold a TIFF structure.", byteRange: payload)
                }
            default:
                break
            }
            if result.hasEmbeddedExif || declaresExif == false {
                break
            }
            // Chunks are padded to an even length.
            guard let next = adding(payloadEnd, length % 2) else {
                break
            }
            offset = next
        }
        if result.size == nil {
            result.appendDiagnostic(code: "webpMissingSize", message: "The WebP has no readable VP8X, VP8 or VP8L size.", byteRange: nil)
        }
        return result.build()
    }

    /// `VP8X`: one flag byte, three reserved, then the canvas width and height minus one as
    /// 24-bit little-endian integers. Returns whether the flags declare an `EXIF` chunk.
    private mutating func readExtendedHeader(payload: Range<UInt64>) -> Bool? {
        guard let bytes = read(payload, length: 10) else {
            result.appendDiagnostic(code: "webpTruncatedVP8X", message: "The WebP VP8X chunk is too short.", byteRange: payload)
            return nil
        }
        let width = littleEndian(bytes[4..<7]) + 1
        let height = littleEndian(bytes[7..<10]) + 1
        appendSize(namespace: "webp.VP8X", width: Int(width), height: Int(height), at: payload.lowerBound + 4, fieldLength: 3, keys: ("CanvasWidth", "CanvasHeight"))
        return bytes[0] & 0x08 != 0
    }

    /// `VP8 `: a three-byte frame tag (bit 0 clear on a key frame), the start code
    /// `9D 01 2A`, then 14-bit width and height in little-endian 16-bit fields whose top two
    /// bits are a scaling hint.
    private mutating func readLossyHeader(payload: Range<UInt64>) {
        guard let bytes = read(payload, length: 10) else {
            result.appendDiagnostic(code: "webpTruncatedVP8", message: "The WebP VP8 chunk is too short to hold a frame header.", byteRange: payload)
            return
        }
        guard bytes[0] & 0x01 == 0, bytes[3..<6].elementsEqual([0x9D, 0x01, 0x2A]) else {
            result.appendDiagnostic(code: "webpInvalidVP8", message: "The WebP VP8 chunk does not start with a key frame.", byteRange: payload)
            return
        }
        let width = littleEndian(bytes[6..<8]) & 0x3FFF
        let height = littleEndian(bytes[8..<10]) & 0x3FFF
        appendSize(namespace: "webp.VP8", width: Int(width), height: Int(height), at: payload.lowerBound + 6, fieldLength: 2, keys: ("Width", "Height"))
    }

    /// `VP8L`: the signature byte `0x2F`, then a little-endian bit field of 14-bit width
    /// minus one and 14-bit height minus one.
    private mutating func readLosslessHeader(payload: Range<UInt64>) {
        guard let bytes = read(payload, length: 5) else {
            result.appendDiagnostic(code: "webpTruncatedVP8L", message: "The WebP VP8L chunk is too short to hold a header.", byteRange: payload)
            return
        }
        guard bytes[0] == 0x2F else {
            result.appendDiagnostic(code: "webpInvalidVP8L", message: "The WebP VP8L chunk lacks its 0x2F signature.", byteRange: payload)
            return
        }
        let bits = littleEndian(bytes[1..<5])
        let width = (bits & 0x3FFF) + 1
        let height = ((bits >> 14) & 0x3FFF) + 1
        result.appendFinding(namespace: "webp.VP8L", key: "Width", value: String(width), sourcePath: "webp.VP8L.Width", byteRange: (payload.lowerBound + 1)..<(payload.lowerBound + 5))
        result.appendFinding(namespace: "webp.VP8L", key: "Height", value: String(height), sourcePath: "webp.VP8L.Height", byteRange: (payload.lowerBound + 1)..<(payload.lowerBound + 5))
        result.size = StillImageResult.Size(width: Int(width), height: Int(height))
    }

    private mutating func appendSize(namespace: String, width: Int, height: Int, at offset: UInt64, fieldLength: UInt64, keys: (width: String, height: String)) {
        result.appendFinding(namespace: namespace, key: keys.width, value: String(width), sourcePath: "\(namespace).\(keys.width)", byteRange: offset..<(offset + fieldLength))
        result.appendFinding(namespace: namespace, key: keys.height, value: String(height), sourcePath: "\(namespace).\(keys.height)", byteRange: (offset + fieldLength)..<(offset + 2 * fieldLength))
        guard width > 0, height > 0 else {
            result.appendDiagnostic(code: "webpEmptySize", message: "The WebP \(namespace) size is \(width)x\(height).", byteRange: offset..<(offset + 2 * fieldLength))
            return
        }
        result.size = StillImageResult.Size(width: width, height: height)
    }

    private func read(_ payload: Range<UInt64>, length: Int) -> [UInt8]? {
        guard payload.upperBound - payload.lowerBound >= UInt64(length),
              let data = try? source.data(offset: payload.lowerBound, length: length),
              data.count == length else {
            return nil
        }
        return Array(data)
    }

    private func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }
}
