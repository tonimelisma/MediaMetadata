import Foundation
@testable import MediaMetadata
import XCTest

/// A still's Exif exposure tags, read from a JPEG's Exif IFD and from the Exif a HEIF and a
/// PNG embed.
final class ExposureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEveryExposureTagIsReported() throws {
        let exposure = try XCTUnwrap(read(jpeg(exifEntries: [
            rational(0x829A, 1, 250),
            rational(0x829D, 28, 10),
            short(0x8822, 3),
            short(0x8827, 400),
            signedRational(0x9204, -1, 3),
            short(0x9207, 5),
            short(0x9209, 0x19),
            rational(0x920A, 350, 10),
            short(0xA403, 1),
            short(0xA405, 52),
        ])).exposure)
        XCTAssertEqual(exposure.exposureTime, ExposureTime(numerator: 1, denominator: 250))
        XCTAssertEqual(try XCTUnwrap(exposure.exposureTime).seconds, 0.004, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(exposure.fNumber), 2.8, accuracy: 1e-12)
        XCTAssertEqual(exposure.program, .aperturePriority)
        XCTAssertEqual(exposure.isoSensitivity, 400)
        XCTAssertEqual(try XCTUnwrap(exposure.exposureBiasEV), -1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(exposure.meteringMode, .pattern)
        XCTAssertEqual(exposure.flash, Flash(fired: true, mode: .auto, redEyeReduction: false, hasFlashFunction: true))
        XCTAssertEqual(try XCTUnwrap(exposure.focalLengthMillimeters), 35, accuracy: 1e-12)
        XCTAssertEqual(exposure.whiteBalance, .manual)
        XCTAssertEqual(exposure.focalLengthIn35mmFilmMillimeters, 52)
    }

    func testAShutterTimeKeepsTheFractionTheCameraWrote() throws {
        let exposure = try XCTUnwrap(read(jpeg(exifEntries: [rational(0x829A, 10, 2500)])).exposure)
        XCTAssertEqual(exposure.exposureTime, ExposureTime(numerator: 10, denominator: 2500))
    }

    func testASaturatedSensitivityReadsTheTagSensitivityTypeNames() throws {
        let exposure = try XCTUnwrap(read(jpeg(exifEntries: [short(0x8827, 65535), long(0x8833, 102_400)])).exposure)
        XCTAssertEqual(exposure.isoSensitivity, 102_400)
    }

    func testASaturatedSensitivityAloneIsNotReported() throws {
        let exposure = read(jpeg(exifEntries: [short(0x8827, 65535), short(0x9209, 0x10)])).exposure
        XCTAssertNil(exposure?.isoSensitivity)
    }

    func testUnknownValuesAreNotReported() throws {
        let exposure = read(jpeg(exifEntries: [
            short(0x8822, 0),
            short(0x9207, 0),
            rational(0x829D, 0, 1),
            rational(0x920A, 0, 0),
            short(0xA405, 0),
        ])).exposure
        XCTAssertNil(exposure)
    }

    func testAFlashThatDidNotFireIsReported() throws {
        let flash = try XCTUnwrap(read(jpeg(exifEntries: [short(0x9209, 0x10)])).exposure?.flash)
        XCTAssertEqual(flash, Flash(fired: false, mode: .off))
        XCTAssertEqual(Flash(exifValue: 0x20), Flash(fired: false, mode: nil, redEyeReduction: false, hasFlashFunction: false))
        XCTAssertEqual(Flash(exifValue: 0x41).redEyeReduction, true)
    }

    func testAStillWithoutExposureTagsReportsNone() throws {
        XCTAssertNil(read(jpeg(exifEntries: [ascii(0x9003, "2026:09:22 11:55:06")])).exposure)
    }

    func testAHEIFReportsTheExposureOfItsExifItem() throws {
        let file = StillImageFixtures.heif(exifItem: StillImageFixtures.exifPrefix + embeddedExif)
        let exposure = try XCTUnwrap(read(file, extension: "heic").exposure)
        XCTAssertEqual(exposure.isoSensitivity, 64)
        XCTAssertEqual(exposure.exposureTime, ExposureTime(numerator: 1, denominator: 120))
    }

    func testAPNGReportsTheExposureOfItsExifChunk() throws {
        let file = StillImageFixtures.png(width: 4, height: 4, exif: embeddedExif)
        XCTAssertEqual(read(file, extension: "png").exposure?.isoSensitivity, 64)
    }

    /// Two real camera files, checked against what Spotlight's Image I/O importer reads.
    func testRealFilesReportWhatImageIOReads() throws {
        let media = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/otos-catalog-state-robustness/Media", isDirectory: true)
        let jpeg = try XCTUnwrap(MediaMetadataReader.read(url: media.appendingPathComponent("jpeg-exif-offset-date.jpg")).exposure)
        XCTAssertEqual(try XCTUnwrap(jpeg.exposureTime).seconds, 0.008, accuracy: 1e-9)
        XCTAssertEqual(jpeg.fNumber, 6.3)
        XCTAssertEqual(jpeg.focalLengthMillimeters, 18)
        XCTAssertEqual(jpeg.isoSensitivity, 400)
        XCTAssertEqual(jpeg.flash?.fired, false)
        let heic = try XCTUnwrap(MediaMetadataReader.read(url: media.appendingPathComponent("ios-heic-offset-date.heic")).exposure)
        XCTAssertEqual(heic.exposureTime, ExposureTime(numerator: 1, denominator: 345))
        XCTAssertEqual(heic.fNumber, 2)
        XCTAssertEqual(try XCTUnwrap(heic.focalLengthMillimeters), 6, accuracy: 0.5)
        XCTAssertEqual(heic.isoSensitivity, 25)
        XCTAssertEqual(heic.flash?.fired, false)
    }

    // MARK: - Fixtures

    private var embeddedExif: Data {
        StillImageFixtures.exifTIFF(ifd0: [], exif: [(0x8827, .short(64)), (0x829A, .rational(1, 120))])
    }

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let payload: Data
    }

    private func ascii(_ tag: UInt16, _ text: String) -> Entry {
        let bytes = Data(text.utf8) + Data([0])
        return Entry(tag: tag, type: 2, count: UInt32(bytes.count), payload: bytes)
    }

    private func short(_ tag: UInt16, _ value: UInt16) -> Entry {
        Entry(tag: tag, type: 3, count: 1, payload: be16(value))
    }

    private func long(_ tag: UInt16, _ value: UInt32) -> Entry {
        Entry(tag: tag, type: 4, count: 1, payload: be32(value))
    }

    private func rational(_ tag: UInt16, _ numerator: UInt32, _ denominator: UInt32) -> Entry {
        Entry(tag: tag, type: 5, count: 1, payload: be32(numerator) + be32(denominator))
    }

    private func signedRational(_ tag: UInt16, _ numerator: Int32, _ denominator: Int32) -> Entry {
        Entry(tag: tag, type: 10, count: 1, payload: be32(UInt32(bitPattern: numerator)) + be32(UInt32(bitPattern: denominator)))
    }

    /// A big-endian Exif TIFF in a JPEG: IFD0 points at an Exif IFD holding `exifEntries` in
    /// tag order, values of more than four bytes placed after the IFD.
    private func jpeg(exifEntries: [Entry]) -> Data {
        let entries = exifEntries.sorted { $0.tag < $1.tag }
        let exifIFDOffset: UInt32 = 8 + 2 + 12 + 4
        var dataOffset = exifIFDOffset + 2 + UInt32(entries.count) * 12 + 4
        var directory = be16(UInt16(entries.count))
        var values = Data()
        for entry in entries {
            directory += be16(entry.tag) + be16(entry.type) + be32(entry.count)
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

    private func read(_ data: Data, extension fileExtension: String = "jpg") -> MediaMetadataResult {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        XCTAssertNoThrow(try data.write(to: url))
        return MediaMetadataReader.read(url: url)
    }

    private func be16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    private func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}
