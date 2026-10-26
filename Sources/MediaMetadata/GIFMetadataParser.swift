import Foundation

let gifParserName = "MediaMetadata.GIFMetadataParser"

/// Reads a GIF's logical screen size: little-endian 16-bit width and height at offsets 6
/// and 8, straight after the `GIF87a`/`GIF89a` signature.
///
/// GIF has no standard place for a capture date, a camera or a location, so the size is
/// all it reports. The logical screen is the canvas every frame is drawn on, which is the
/// size a viewer shows.
struct GIFMetadataParser {
    private let source: MediaByteSource
    private let fileExtension: String

    init(source: MediaByteSource, fileExtension: String) {
        self.source = source
        self.fileExtension = fileExtension
    }

    func parse() -> ParsedMetadata {
        var result = StillImageResult(family: .gif, fileExtension: fileExtension, parser: gifParserName)
        guard source.size >= 10,
              let data = try? source.data(offset: 6, length: 4),
              data.count == 4 else {
            result.appendDiagnostic(code: "gifTruncatedHeader", message: "The GIF is too short to hold its logical screen size.", byteRange: nil)
            return result.build()
        }
        let bytes = Array(data)
        let width = Int(bytes[0]) | Int(bytes[1]) << 8
        let height = Int(bytes[2]) | Int(bytes[3]) << 8
        result.appendFinding(namespace: "gif.screen", key: "Width", value: String(width), sourcePath: "gif.LogicalScreen.Width", byteRange: 6..<8)
        result.appendFinding(namespace: "gif.screen", key: "Height", value: String(height), sourcePath: "gif.LogicalScreen.Height", byteRange: 8..<10)
        if width > 0, height > 0 {
            result.size = StillImageResult.Size(width: width, height: height)
        } else {
            result.appendDiagnostic(code: "gifEmptyLogicalScreen", message: "The GIF logical screen is \(width)x\(height).", byteRange: 6..<10)
        }
        return result.build()
    }
}
