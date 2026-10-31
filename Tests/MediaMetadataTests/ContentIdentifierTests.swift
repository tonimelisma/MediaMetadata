import Foundation
@testable import MediaMetadata
import XCTest

/// A Live Photo's still and motion movie share Apple's content identifier. The still carries
/// it in its Apple MakerNote; the movie as a QuickTime metadata key.
///
/// The layout below is the one a real iPhone HEIC carries (verified with `exiftool -v3`):
/// `Apple iOS\0`, version `00 01`, `MM`, then a big-endian IFD whose value offsets count from
/// the start of the MakerNote, with the identifier as a 37-byte ASCII string in tag `0x0011`.
final class ContentIdentifierTests: XCTestCase {
    private let identifier = "66E9019A-9CAF-4603-A6C3-2F22030B7C65"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStillReportsTheAppleMakerNoteIdentifier() throws {
        let url = try write(jpeg(makerNote: appleMakerNote(identifier: identifier)), extension: "jpg")
        XCTAssertEqual(MediaMetadataReader.read(url: url).contentIdentifier, identifier)
    }

    func testMovieReportsTheQuickTimeKey() throws {
        let url = try write(
            box("moov", payload: mdtaMetaBox(["com.apple.quicktime.content.identifier": identifier])),
            extension: "mov"
        )
        XCTAssertEqual(MediaMetadataReader.read(url: url).contentIdentifier, identifier)
    }

    func testAnotherVendorsMakerNoteReportsNone() throws {
        var makerNote = appleMakerNote(identifier: identifier)
        makerNote.replaceSubrange(0..<5, with: Data("Nikon".utf8))
        let url = try write(jpeg(makerNote: makerNote), extension: "jpg")
        XCTAssertNil(MediaMetadataReader.read(url: url).contentIdentifier)
    }

    func testATruncatedMakerNoteReportsNoneAndStillReadsTheFile() throws {
        let makerNote = appleMakerNote(identifier: identifier).prefix(20)
        let url = try write(jpeg(makerNote: Data(makerNote)), extension: "jpg")
        let result = MediaMetadataReader.read(url: url)
        XCTAssertNil(result.contentIdentifier)
        XCTAssertEqual(result.outcome, .parsed)
    }

    func testAFileWithoutOneReportsNone() throws {
        let url = try write(
            box("moov", payload: mdtaMetaBox(["com.apple.quicktime.make": "Apple"])),
            extension: "mov"
        )
        XCTAssertNil(MediaMetadataReader.read(url: url).contentIdentifier)
    }

    // MARK: - Fixtures

    /// An Apple MakerNote: header, then an IFD with MakerNoteVersion and ContentIdentifier,
    /// then the identifier's bytes at an offset counted from the MakerNote's start.
    private func appleMakerNote(identifier: String) -> Data {
        let text = Data(identifier.utf8) + Data([0])
        let headerLength = 14
        let ifdLength = 2 + 2 * 12 + 4
        var note = Data("Apple iOS".utf8) + Data([0, 0, 1]) + Data("MM".utf8)
        note += be16(2)
        note += be16(0x0001) + be16(9) + be32(1) + be32(11)
        note += be16(0x0011) + be16(2) + be32(UInt32(text.count)) + be32(UInt32(headerLength + ifdLength))
        note += be32(0)
        return note + text
    }

    /// A big-endian Exif TIFF whose Exif IFD holds only the MakerNote, wrapped in a JPEG.
    private func jpeg(makerNote: Data) -> Data {
        let exifIFDOffset: UInt32 = 8 + 2 + 12 + 4
        let makerNoteOffset = exifIFDOffset + 2 + 12 + 4
        var tiff = Data("MM".utf8) + be16(42) + be32(8)
        tiff += be16(1) + be16(0x8769) + be16(4) + be32(1) + be32(exifIFDOffset) + be32(0)
        tiff += be16(1) + be16(0x927C) + be16(7) + be32(UInt32(makerNote.count)) + be32(makerNoteOffset) + be32(0)
        tiff += makerNote
        let app1 = Data("Exif".utf8) + Data([0, 0]) + tiff
        return Data([0xFF, 0xD8, 0xFF, 0xE1]) + be16(UInt16(app1.count + 2)) + app1 + Data([0xFF, 0xD9])
    }

    private func mdtaMetaBox(_ values: [String: String]) -> Data {
        let ordered = values.sorted { $0.key < $1.key }
        var keysPayload = be32(0) + be32(UInt32(ordered.count))
        for (key, _) in ordered {
            keysPayload += be32(UInt32(8 + key.utf8.count)) + Data("mdta".utf8) + Data(key.utf8)
        }
        var ilstPayload = Data()
        for (index, (_, value)) in ordered.enumerated() {
            let data = box("data", payload: be32(1) + be32(0) + Data(value.utf8))
            ilstPayload += box(typeBytes: be32(UInt32(index + 1)), payload: data)
        }
        let handler = box("hdlr", payload: be32(0) + be32(0) + Data("mdta".utf8) + Data(repeating: 0, count: 13))
        return box("meta", payload: be32(0) + handler + box("keys", payload: keysPayload) + box("ilst", payload: ilstPayload))
    }

    private func box(_ type: String, payload: Data) -> Data {
        box(typeBytes: Data(type.utf8), payload: payload)
    }

    private func box(typeBytes: Data, payload: Data) -> Data {
        be32(UInt32(8 + payload.count)) + typeBytes + payload
    }

    private func write(_ data: Data, extension fileExtension: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: url)
        return url
    }

    private func be16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
