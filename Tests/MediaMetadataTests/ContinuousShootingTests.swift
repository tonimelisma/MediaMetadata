import Foundation
@testable import MediaMetadata
import XCTest

/// A camera's burst: a Sony MakerNote records the drive mode (`ReleaseMode`, tag `0xB049`)
/// and the frame's number in the sequence (`SequenceNumber`, tag `0xB04A`). A frame of a
/// continuous sequence reports its number; a single shot, a bracket, another maker's file
/// and a not-applicable number report none. The values match an a6700 ARW read with
/// ExifTool 13.55 (frame 3 of a continuous sequence: `ReleaseMode` 2, `SequenceNumber` 3).
final class ContinuousShootingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAContinuousFrameReportsItsNumber() throws {
        XCTAssertEqual(try read(make: "SONY", releaseMode: 2, sequence: 3), 3)
    }

    func testASonyHeaderBeforeTheDirectoryIsSkipped() throws {
        XCTAssertEqual(try read(make: "SONY", releaseMode: 2, sequence: 1, header: true), 1)
    }

    func testASingleShotABracketAndANotApplicableNumberReportNone() throws {
        XCTAssertNil(try read(make: "SONY", releaseMode: 0, sequence: 0))
        XCTAssertNil(try read(make: "SONY", releaseMode: 5, sequence: 2))
        XCTAssertNil(try read(make: "SONY", releaseMode: 2, sequence: 0xFFFF))
        XCTAssertNil(try read(make: "SONY", releaseMode: 2, sequence: 0))
    }

    func testAnotherMakersMakerNoteIsNotReadAsSonys() throws {
        XCTAssertNil(try read(make: "NIKON CORPORATION", releaseMode: 2, sequence: 3))
    }

    // MARK: - Fixture

    /// A little-endian Exif JPEG: IFD0 holds `Make` and the Exif pointer; the Exif IFD holds
    /// a MakerNote whose IFD has the two drive-mode shorts inline, as the a6700 writes them.
    private func read(make: String, releaseMode: UInt16, sequence: UInt16, header: Bool = false) throws -> Int? {
        let makeText = Data(make.utf8) + Data([0])
        // TIFF header (8), IFD0 (2 + 2 × 12 + 4 = 30), then the Make text, the Exif IFD
        // (2 + 12 + 4 = 18) and the MakerNote.
        let ifd0Offset: UInt32 = 8
        let makeOffset = ifd0Offset + 30
        let exifOffset = makeOffset + UInt32(makeText.count)
        let noteOffset = exifOffset + 18
        var note = header ? Data("SONY DSC ".utf8) + Data([0, 0, 0]) : Data()
        note += le16(2)
        note += le16(0xB049) + le16(3) + le32(1) + le16(releaseMode) + le16(0)
        note += le16(0xB04A) + le16(3) + le32(1) + le16(sequence) + le16(0)
        note += le32(0)

        var tiff = Data("II".utf8) + le16(42) + le32(ifd0Offset)
        tiff += le16(2)
        tiff += le16(0x010F) + le16(2) + le32(UInt32(makeText.count)) + le32(makeOffset)
        tiff += le16(0x8769) + le16(4) + le32(1) + le32(exifOffset)
        tiff += le32(0)
        tiff += makeText
        tiff += le16(1) + le16(0x927C) + le16(7) + le32(UInt32(note.count)) + le32(noteOffset) + le32(0)
        tiff += note

        let app1 = Data("Exif".utf8) + Data([0, 0]) + tiff
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1]) + be16(UInt16(app1.count + 2)) + app1 + Data([0xFF, 0xD9])
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        try jpeg.write(to: url)
        return MediaMetadataReader.read(url: url).continuousShootingFrame
    }

    private func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    private func be16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }
}
