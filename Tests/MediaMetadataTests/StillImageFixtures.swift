import Foundation

/// Synthetic PNG, WebP and GIF files, built byte by byte so no real photo is committed.
///
/// Each builder writes the container structure the format's specification describes —
/// PNG chunks carry a real CRC — though the pixel data is filler, so a test that breaks the
/// structure does so deliberately.
enum StillImageFixtures {
    // MARK: - Exif TIFF

    enum Value {
        case short(UInt16)
        case long(UInt32)
        case ascii(String)
    }

    static let orientationTag: UInt16 = 0x0112
    static let makeTag: UInt16 = 0x010F
    static let dateTimeOriginalTag: UInt16 = 0x9003
    static let offsetTimeOriginalTag: UInt16 = 0x9011
    static let pixelXDimensionTag: UInt16 = 0xA002
    static let pixelYDimensionTag: UInt16 = 0xA003

    /// The Exif most tests use: rotated a quarter (orientation 6), made by "Apple", taken
    /// 2024-05-06 07:08:09 at UTC+03:00.
    static func standardExif(extraExifEntries: [(UInt16, Value)] = []) -> Data {
        exifTIFF(
            ifd0: [(orientationTag, .short(6)), (makeTag, .ascii("Apple"))],
            exif: [(dateTimeOriginalTag, .ascii("2024:05:06 07:08:09")), (offsetTimeOriginalTag, .ascii("+03:00"))] + extraExifEntries
        )
    }

    /// A little-endian TIFF with IFD0 and, when `exif` is not empty, an Exif IFD that IFD0
    /// points at. Values longer than four bytes go in a data area after the directories.
    static func exifTIFF(ifd0: [(UInt16, Value)], exif: [(UInt16, Value)]) -> Data {
        let exifPointerTag: UInt16 = 0x8769
        let ifd0Count = ifd0.count + (exif.isEmpty ? 0 : 1)
        let exifOffset = 8 + 2 + 12 * ifd0Count + 4
        var dataOffset = exifOffset + (exif.isEmpty ? 0 : 2 + 12 * exif.count + 4)
        var dataArea = Data()

        func directory(_ entries: [(UInt16, Value)]) -> Data {
            var out = le16(UInt16(entries.count))
            for (tag, value) in entries.sorted(by: { $0.0 < $1.0 }) {
                switch value {
                case let .short(number):
                    out += le16(tag) + le16(3) + le32(1) + le16(number) + le16(0)
                case let .long(number):
                    out += le16(tag) + le16(4) + le32(1) + le32(number)
                case let .ascii(text):
                    let bytes = Data(text.utf8) + Data([0])
                    if bytes.count <= 4 {
                        out += le16(tag) + le16(2) + le32(UInt32(bytes.count)) + bytes + Data(repeating: 0, count: 4 - bytes.count)
                    } else {
                        out += le16(tag) + le16(2) + le32(UInt32(bytes.count)) + le32(UInt32(dataOffset))
                        dataArea += bytes
                        dataOffset += bytes.count
                    }
                }
            }
            return out + le32(0)
        }

        var ifd0Entries = ifd0
        if !exif.isEmpty {
            ifd0Entries.append((exifPointerTag, .long(UInt32(exifOffset))))
        }
        var tiff = Data("II".utf8) + le16(42) + le32(8)
        tiff += directory(ifd0Entries)
        if !exif.isEmpty {
            tiff += directory(exif)
        }
        return tiff + dataArea
    }

    static let exifPrefix = Data("Exif".utf8) + Data([0, 0])

    // MARK: - PNG

    enum ExifPlacement {
        case beforeImageData
        case afterImageData
    }

    static func png(
        width: UInt32,
        height: UInt32,
        exif: Data? = nil,
        placement: ExifPlacement = .beforeImageData,
        imageDataLength: Int = 16
    ) -> Data {
        let ihdr = be32(width) + be32(height) + Data([8, 6, 0, 0, 0])
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + pngChunk("IHDR", ihdr)
        if let exif, placement == .beforeImageData {
            data += pngChunk("eXIf", exif)
        }
        data += pngChunk("IDAT", Data(repeating: 0x55, count: imageDataLength))
        if let exif, placement == .afterImageData {
            data += pngChunk("eXIf", exif)
        }
        return data + pngChunk("IEND", Data())
    }

    static func pngChunk(_ type: String, _ payload: Data) -> Data {
        let typeAndPayload = Data(type.utf8) + payload
        return be32(UInt32(payload.count)) + typeAndPayload + be32(crc32(typeAndPayload))
    }

    // MARK: - WebP

    /// Extended format: `VP8X` canvas, a lossy bitstream that disagrees with it (so a test
    /// can tell which one was read), then `EXIF` when given.
    static func webpExtended(width: UInt32, height: UInt32, exif: Data? = nil) -> Data {
        let flags: UInt8 = exif == nil ? 0 : 0x08
        let vp8x = Data([flags, 0, 0, 0]) + le24(width - 1) + le24(height - 1)
        var chunks = riffChunk("VP8X", vp8x) + riffChunk("VP8 ", vp8KeyFrame(width: 1, height: 1))
        if let exif {
            chunks += riffChunk("EXIF", exif)
        }
        return riff(chunks)
    }

    /// Simple lossy format: one `VP8 ` chunk.
    static func webpLossy(width: UInt16, height: UInt16) -> Data {
        riff(riffChunk("VP8 ", vp8KeyFrame(width: width, height: height)))
    }

    /// Simple lossless format: one `VP8L` chunk.
    static func webpLossless(width: UInt32, height: UInt32) -> Data {
        let bits = (width - 1) | ((height - 1) << 14) | (1 << 28)
        return riff(riffChunk("VP8L", Data([0x2F]) + le32(bits) + Data(repeating: 0, count: 8)))
    }

    static func vp8KeyFrame(width: UInt16, height: UInt16) -> Data {
        // Frame tag: key frame (bit 0 clear), version 0, shown, first-partition size 0.
        Data([0x10, 0x00, 0x00, 0x9D, 0x01, 0x2A]) + le16(width) + le16(height) + Data(repeating: 0, count: 8)
    }

    static func riff(_ chunks: Data, formType: String = "WEBP") -> Data {
        Data("RIFF".utf8) + le32(UInt32(4 + chunks.count)) + Data(formType.utf8) + chunks
    }

    static func riffChunk(_ id: String, _ payload: Data) -> Data {
        var chunk = Data(id.utf8) + le32(UInt32(payload.count)) + payload
        if payload.count % 2 == 1 {
            chunk.append(0)
        }
        return chunk
    }

    // MARK: - GIF

    static func gif(width: UInt16, height: UInt16, version: String = "89a") -> Data {
        // Header, logical screen descriptor (no global colour table), an empty image
        // descriptor and trailer: enough structure to be a GIF, no pixels needed.
        var data = Data("GIF\(version)".utf8)
        data += le16(width) + le16(height)
        data += Data([0x00, 0x00, 0x00, 0x2C])
        data += le16(0) + le16(0)
        data += le16(width) + le16(height)
        data += Data([0x00, 0x02, 0x01, 0x00, 0x00, 0x3B])
        return data
    }

    // MARK: - Bytes

    static func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    static func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    static func le24(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF)])
    }

    static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
