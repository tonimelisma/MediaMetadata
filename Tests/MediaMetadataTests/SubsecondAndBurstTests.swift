import Foundation
@testable import MediaMetadata
import XCTest

/// Two frames shot within one second share a whole-second wall clock. What tells them apart
/// is the EXIF SubSec tag each wall clock carries, and — for an iPhone burst — the Apple
/// MakerNote burst identifier every frame of one burst shares.
final class SubsecondAndBurstTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOriginalReportsItsOwnSubsecondDigits() throws {
        let url = try write(jpeg(exifEntries: [
            ascii(0x9003, "2026:09:22 11:55:06"),
            ascii(0x9291, "387"),
        ]))
        let original = try XCTUnwrap(MediaMetadataReader.read(url: url).timestamps.original)
        XCTAssertEqual(original.second, 6)
        XCTAssertEqual(original.fractionalSecondDigits, "387")
    }

    func testPaddingIsDroppedAndAValueWithoutDigitsSaysNothing() throws {
        XCTAssertEqual(TIFFMetadataParser.fractionalSecondDigits(from: "60  \0"), "60")
        XCTAssertNil(TIFFMetadataParser.fractionalSecondDigits(from: "   "))
        XCTAssertNil(TIFFMetadataParser.fractionalSecondDigits(from: ""))
    }

    func testNoTagLendsItsFractionToAnotherRole() throws {
        let url = try write(jpeg(exifEntries: [
            ascii(0x9003, "2026:09:22 11:55:06"),
            ascii(0x9004, "2026:09:22 11:55:06"),
            ascii(0x9292, "604"),
        ]))
        let timestamps = MediaMetadataReader.read(url: url).timestamps
        XCTAssertNil(timestamps.original?.fractionalSecondDigits)
        XCTAssertEqual(timestamps.digitized?.fractionalSecondDigits, "604")
    }

    func testAFileWithoutSubsecondsReportsNone() throws {
        let url = try write(jpeg(exifEntries: [ascii(0x9003, "2026:09:22 11:55:06")]))
        XCTAssertNil(MediaMetadataReader.read(url: url).timestamps.original?.fractionalSecondDigits)
    }

    func testABurstFrameReportsItsBurstIdentifier() throws {
        let burst = "8A1C2B3D-4E5F-6071-8293-A4B5C6D7E8F9"
        let url = try write(jpeg(exifEntries: [undefined(0x927C, appleMakerNote(burst: burst))]))
        XCTAssertEqual(MediaMetadataReader.read(url: url).burstIdentifier, burst)
    }

    func testAStillOutsideABurstReportsNone() throws {
        let url = try write(jpeg(exifEntries: [ascii(0x9003, "2026:09:22 11:55:06")]))
        XCTAssertNil(MediaMetadataReader.read(url: url).burstIdentifier)
    }

    // MARK: - Fixtures

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let payload: Data
    }

    private func ascii(_ tag: UInt16, _ text: String) -> Entry {
        Entry(tag: tag, type: 2, payload: Data(text.utf8) + Data([0]))
    }

    private func undefined(_ tag: UInt16, _ data: Data) -> Entry {
        Entry(tag: tag, type: 7, payload: data)
    }

    /// An Apple MakerNote whose IFD holds only the burst identifier (tag `0x000B`), its value
    /// offset counted from the MakerNote's start.
    private func appleMakerNote(burst: String) -> Data {
        let text = Data(burst.utf8) + Data([0])
        let headerLength = 14
        let ifdLength = 2 + 12 + 4
        var note = Data("Apple iOS".utf8) + Data([0, 0, 1]) + Data("MM".utf8)
        note += be16(1)
        note += be16(0x000B) + be16(2) + be32(UInt32(text.count)) + be32(UInt32(headerLength + ifdLength))
        note += be32(0)
        return note + text
    }

    /// A big-endian Exif TIFF in a JPEG: IFD0 points at an Exif IFD holding `exifEntries`,
    /// in tag order, values of more than four bytes placed after the IFD. A MakerNote's own
    /// offsets count from its start, so its absolute position is all it needs.
    private func jpeg(exifEntries: [Entry]) -> Data {
        let entries = exifEntries.sorted { $0.tag < $1.tag }
        let exifIFDOffset: UInt32 = 8 + 2 + 12 + 4
        var dataOffset = exifIFDOffset + 2 + UInt32(entries.count) * 12 + 4
        var directory = be16(UInt16(entries.count))
        var values = Data()
        for entry in entries {
            directory += be16(entry.tag) + be16(entry.type) + be32(UInt32(entry.payload.count))
            if entry.payload.count <= 4 {
                directory += entry.payload + Data(repeating: 0, count: 4 - entry.payload.count)
            } else {
                directory += be32(dataOffset)
                values += entry.payload
                dataOffset += UInt32(entry.payload.count)
            }
        }
        directory += be32(0)
        var tiff = Data("MM".utf8) + be16(42) + be32(8)
        tiff += be16(1) + be16(0x8769) + be16(4) + be32(1) + be32(exifIFDOffset) + be32(0)
        tiff += directory + values
        let app1 = Data("Exif".utf8) + Data([0, 0]) + tiff
        return Data([0xFF, 0xD8, 0xFF, 0xE1]) + be16(UInt16(app1.count + 2)) + app1 + Data([0xFF, 0xD9])
    }

    private func write(_ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
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
