import Foundation

let pngParserName = "MediaMetadata.PNGMetadataParser"
/// The eight bytes every PNG datastream starts with.
let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
/// Chunk headers walked before giving up; real files have a handful before `IDAT`.
private let maxPNGChunkCount = 4096
/// The PNG specification's limit on a chunk's length field.
private let maxPNGChunkLength: UInt64 = 0x7FFF_FFFF

/// Reads a PNG's size from `IHDR` and its Exif from `eXIf`.
///
/// Walks chunk headers (length and type) from offset 8 and stops at the first `IDAT` or at
/// `IEND`, so it never reads image data. That is also why an `eXIf` placed after `IDAT` is
/// not read: the PNG specification (Third Edition, Table 7) requires `eXIf` before `IDAT`,
/// and reaching a misplaced one means walking every `IDAT` chunk header across the whole
/// file — on a remote transport, fetching most of it — for metadata the format says is
/// not there.
struct PNGMetadataParser {
    private let source: MediaByteSource
    private var result: StillImageResult

    init(source: MediaByteSource, fileExtension: String) {
        self.source = source
        result = StillImageResult(family: .png, fileExtension: fileExtension, parser: pngParserName)
    }

    mutating func parse() -> ParsedMetadata {
        var offset: UInt64 = 8
        var chunkCount = 0
        var sawIHDR = false
        while let headerEnd = adding(offset, 8), headerEnd <= source.size {
            guard chunkCount < maxPNGChunkCount else {
                result.appendDiagnostic(code: "pngChunkLimitExceeded", message: "PNG chunk count before IDAT exceeded the parser limit.", byteRange: nil)
                break
            }
            chunkCount += 1
            guard let header = try? source.data(offset: offset, length: 8), header.count == 8 else {
                result.appendDiagnostic(code: "pngTruncatedChunkHeader", message: "Could not read a PNG chunk header.", byteRange: offset..<headerEnd)
                break
            }
            let bytes = Array(header)
            let length = UInt64(bigEndianUInt32(bytes, at: 0))
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            // Image data starts here, and nothing the parser reads may follow it.
            if type == "IDAT" || type == "IEND" {
                break
            }
            guard length <= maxPNGChunkLength,
                  let payloadEnd = adding(headerEnd, length),
                  payloadEnd <= source.size else {
                result.appendDiagnostic(
                    code: "pngChunkExceedsFile",
                    message: "PNG chunk \(type) extends past the end of the file.",
                    byteRange: offset..<source.size
                )
                break
            }
            let payload = headerEnd..<payloadEnd
            switch type {
            case "IHDR" where !sawIHDR:
                sawIHDR = true
                readHeader(payload: payload)
            case "eXIf" where !result.hasEmbeddedExif:
                if !result.parseEmbeddedExif(source: source, payload: payload) {
                    result.appendDiagnostic(code: "pngExifUnreadable", message: "The PNG eXIf chunk does not hold a TIFF structure.", byteRange: payload)
                }
            default:
                break
            }
            // Payload, then the four-byte CRC.
            guard let next = adding(payloadEnd, 4) else {
                break
            }
            offset = next
        }
        if !sawIHDR {
            result.appendDiagnostic(code: "pngMissingIHDR", message: "The PNG has no readable IHDR chunk before its image data.", byteRange: nil)
        }
        return result.build()
    }

    /// `IHDR` opens with the width and height as big-endian 32-bit integers. The
    /// specification puts it first; it is read wherever it appears before `IDAT`, so a PNG
    /// with a vendor chunk ahead of it (Apple's `CgBI`) still reports its size.
    private mutating func readHeader(payload: Range<UInt64>) {
        guard payload.upperBound - payload.lowerBound >= 8,
              let data = try? source.data(offset: payload.lowerBound, length: 8),
              data.count == 8 else {
            result.appendDiagnostic(code: "pngTruncatedIHDR", message: "The PNG IHDR chunk is too short to hold a size.", byteRange: payload)
            return
        }
        let bytes = Array(data)
        let width = bigEndianUInt32(bytes, at: 0)
        let height = bigEndianUInt32(bytes, at: 4)
        result.appendFinding(namespace: "png.IHDR", key: "Width", value: String(width), sourcePath: "png.IHDR.Width", byteRange: payload.lowerBound..<(payload.lowerBound + 4))
        result.appendFinding(namespace: "png.IHDR", key: "Height", value: String(height), sourcePath: "png.IHDR.Height", byteRange: (payload.lowerBound + 4)..<(payload.lowerBound + 8))
        guard width > 0, height > 0, UInt64(width) <= maxPNGChunkLength, UInt64(height) <= maxPNGChunkLength else {
            result.appendDiagnostic(code: "pngInvalidIHDRSize", message: "The PNG IHDR size \(width)x\(height) is outside the range the specification allows.", byteRange: payload)
            return
        }
        result.size = StillImageResult.Size(width: Int(width), height: Int(height))
    }

    private func bigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }
}
