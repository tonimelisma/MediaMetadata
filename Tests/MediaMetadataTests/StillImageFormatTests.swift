import Foundation
import XCTest
@testable import MediaMetadata

/// PNG, WebP and GIF identified and read from their bytes, each its own family (0.8.0).
final class StillImageFormatTests: XCTestCase {
    private typealias Fixtures = StillImageFixtures

    // MARK: - Detection and size

    func testPNGIsIdentifiedAndReadFromItsBytes() {
        let bytes = Fixtures.png(width: 640, height: 480)
        assertStill(bytes, family: .png, fileType: .png, width: 640, height: 480)
    }

    func testGIFIsIdentifiedAndReadFromItsBytes() {
        assertStill(Fixtures.gif(width: 320, height: 200), family: .gif, fileType: .gif, width: 320, height: 200)
        assertStill(Fixtures.gif(width: 7, height: 9, version: "87a"), family: .gif, fileType: .gif, width: 7, height: 9)
    }

    func testWebPSizeComesFromEachBitstreamHeader() {
        // Lossy: 14-bit fields; the top two (scaling) bits must not leak into the size.
        assertStill(Fixtures.webpLossy(width: 0xC000 | 1024, height: 0x4000 | 768), family: .webp, fileType: .webp, width: 1024, height: 768)
        assertStill(Fixtures.webpLossless(width: 16383, height: 1), family: .webp, fileType: .webp, width: 16383, height: 1)
        assertStill(Fixtures.webpLossless(width: 300, height: 200), family: .webp, fileType: .webp, width: 300, height: 200)
        // Extended: the VP8X canvas, not the 1x1 bitstream behind it.
        assertStill(Fixtures.webpExtended(width: 4032, height: 3024), family: .webp, fileType: .webp, width: 4032, height: 3024)
        assertStill(Fixtures.webpExtended(width: 1 << 24, height: 1), family: .webp, fileType: .webp, width: 1 << 24, height: 1)
    }

    func testStillsCarryNoTimestampsWithoutExif() {
        for bytes in [Fixtures.png(width: 2, height: 2), Fixtures.gif(width: 2, height: 2), Fixtures.webpLossy(width: 2, height: 2)] {
            let result = read(bytes)
            XCTAssertTrue(result.timestamps.entries.isEmpty)
            XCTAssertNil(result.camera)
            XCTAssertNil(result.geometry?.orientation)
        }
    }

    // MARK: - Exif

    func testPNGExifGivesOrientationTimestampsAndCamera() {
        assertStandardExif(read(Fixtures.png(width: 400, height: 300, exif: Fixtures.standardExif())), width: 400, height: 300)
    }

    func testPNGExifWrittenWithAJPEGStylePrefixIsStillRead() {
        let bytes = Fixtures.png(width: 400, height: 300, exif: Fixtures.exifPrefix + Fixtures.standardExif())
        assertStandardExif(read(bytes), width: 400, height: 300)
    }

    func testWebPExifGivesOrientationTimestampsAndCamera() {
        assertStandardExif(read(Fixtures.webpExtended(width: 400, height: 300, exif: Fixtures.standardExif())), width: 400, height: 300)
        let prefixed = Fixtures.webpExtended(width: 400, height: 300, exif: Fixtures.exifPrefix + Fixtures.standardExif())
        assertStandardExif(read(prefixed), width: 400, height: 300)
    }

    func testTheContainerHeaderSizeWinsOverExifDimensions() {
        // Exif dimensions are carried over from the original and go stale on a resize.
        let exif = Fixtures.standardExif(extraExifEntries: [
            (Fixtures.pixelXDimensionTag, .long(4000)), (Fixtures.pixelYDimensionTag, .long(3000)),
        ])
        for bytes in [Fixtures.png(width: 400, height: 300, exif: exif), Fixtures.webpExtended(width: 400, height: 300, exif: exif)] {
            let geometry = read(bytes).geometry
            XCTAssertEqual(geometry?.pixelWidth, 400)
            XCTAssertEqual(geometry?.pixelHeight, 300)
        }
    }

    func testExifEvidenceIDsStillPointAtTheirFindings() {
        let parsed = MediaMetadataReader.extract(
            source: StillImageMemorySource(bytes: Fixtures.png(width: 4, height: 4, exif: Fixtures.standardExif())),
            fileExtension: "png"
        )
        let original = parsed.timestamps.first { $0.role == .original }
        let keys = original?.evidenceIDs.compactMap { id in parsed.findings.first { $0.id == id }?.key }
        XCTAssertEqual(keys?.sorted(), ["DateTimeOriginal", "OffsetTimeOriginal"])
        XCTAssertEqual(parsed.findings.map(\.id), Array(parsed.findings.indices))
    }

    func testPNGExifAfterImageDataIsNotRead() {
        // The specification puts eXIf before IDAT; reaching a late one means walking past
        // all the image data, so the parse stops at the first IDAT and never gets there.
        let imageDataLength = 300_000
        let bytes = Fixtures.png(width: 64, height: 64, exif: Fixtures.standardExif(), placement: .afterImageData, imageDataLength: imageDataLength)
        let result = read(bytes)
        XCTAssertEqual(result.outcome, .parsed)
        XCTAssertEqual(result.geometry?.pixelWidth, 64)
        XCTAssertTrue(result.timestamps.entries.isEmpty)
        XCTAssertNil(result.geometry?.orientation)
        let idatHeaderEnd: UInt64 = 8 + 25 + 8
        XCTAssertLessThanOrEqual(result.readCost.highestOffsetTouched, idatHeaderEnd, "IDAT payload must not be read")
    }

    func testWebPStopsOnceTheCanvasSaysThereIsNoExif() {
        // A VP8X without the EXIF flag settles everything; the bitstream behind it is not visited.
        let bytes = Fixtures.webpExtended(width: 10, height: 10)
        let result = read(bytes)
        XCTAssertEqual(result.geometry?.pixelWidth, 10)
        XCTAssertLessThanOrEqual(result.readCost.highestOffsetTouched, 12 + 8 + 10)
    }

    // MARK: - RIFF form types

    func testRIFFFormTypeDecidesTheFamily() {
        let avi = Fixtures.riff(Fixtures.riffChunk("JUNK", Data(count: 4)), formType: "AVI ")
        let wav = Fixtures.riff(Fixtures.riffChunk("fmt ", Data(count: 16)), formType: "WAVE")
        let cases: [(Data, MediaFormat.Family, MediaFileType?, ReadOutcome)] = [
            (avi, .riffAVI, .avi, .parsed),
            (wav, .riffWAV, .wav, .parsed),
            (Fixtures.webpLossy(width: 8, height: 8), .webp, .webp, .parsed),
            (Fixtures.riff(Data(), formType: "RMID"), .unknown, nil, .unsupported),
        ]
        for (bytes, family, fileType, outcome) in cases {
            let identified = MediaMetadataReader.identify(source: StillImageMemorySource(bytes: bytes), filenameHint: "a.bin")
            XCTAssertEqual(identified.family, family, "identify \(family)")
            XCTAssertEqual(identified.fileType, fileType, "identify \(family)")
            XCTAssertEqual(identified.detectedByMagic, family != .unknown)
            let result = read(bytes)
            XCTAssertEqual(result.format.family, family, "read \(family)")
            XCTAssertEqual(result.format.fileType, fileType, "read \(family)")
            XCTAssertEqual(result.outcome, outcome, "read \(family)")
        }
    }

    // MARK: - Malformed input

    func testTruncatedAndMalformedFilesKeepTheirFamilyWithoutASize() {
        let png = Fixtures.png(width: 64, height: 48)
        let pngSignature = png.prefix(8)
        let cases: [(name: String, bytes: Data, family: MediaFormat.Family, code: String)] = [
            ("png signature only", pngSignature, .png, "pngMissingIHDR"),
            ("png cut inside IHDR", png.prefix(20), .png, "pngChunkExceedsFile"),
            ("png IHDR too short", pngSignature + Fixtures.pngChunk("IHDR", Data(count: 4)), .png, "pngTruncatedIHDR"),
            ("png zero width", Fixtures.png(width: 0, height: 48), .png, "pngInvalidIHDRSize"),
            ("png oversized chunk length", pngSignature + Fixtures.be32(0xFFFF_FFF0) + Data("tEXt".utf8) + Data(count: 8), .png, "pngChunkExceedsFile"),
            ("png IDAT first", pngSignature + Fixtures.pngChunk("IDAT", Data(count: 4)), .png, "pngMissingIHDR"),
            ("gif signature only", Data("GIF89a".utf8), .gif, "gifTruncatedHeader"),
            ("gif empty screen", Fixtures.gif(width: 0, height: 0), .gif, "gifEmptyLogicalScreen"),
            ("webp header only", Fixtures.riff(Data()), .webp, "webpMissingSize"),
            ("webp lossy inter frame", Fixtures.riff(Fixtures.riffChunk("VP8 ", Data([0x01]) + Fixtures.vp8KeyFrame(width: 8, height: 8).dropFirst())), .webp, "webpInvalidVP8"),
            ("webp lossless bad signature", Fixtures.riff(Fixtures.riffChunk("VP8L", Data(count: 5))), .webp, "webpInvalidVP8L"),
            ("webp VP8X too short", Fixtures.riff(Fixtures.riffChunk("VP8X", Data(count: 4))), .webp, "webpTruncatedVP8X"),
            ("webp chunk past end", Fixtures.webpLossy(width: 8, height: 8).prefix(24), .webp, "webpChunkExceedsFile"),
        ]
        for testCase in cases {
            let parsed = MediaMetadataReader.extract(source: StillImageMemorySource(bytes: testCase.bytes), fileExtension: "bin")
            let result = MediaMetadataResult(parsed)
            XCTAssertEqual(result.outcome, .parsed, testCase.name)
            XCTAssertEqual(result.format.family, testCase.family, testCase.name)
            XCTAssertNil(result.geometry, testCase.name)
            XCTAssertTrue(parsed.diagnostics.contains { $0.code == testCase.code }, "\(testCase.name): \(parsed.diagnostics.map(\.code))")
        }
    }

    func testUnreadableExifKeepsTheSize() {
        let garbage = Data("not a tiff at all".utf8)
        for (bytes, code) in [
            (Fixtures.png(width: 5, height: 6, exif: garbage), "pngExifUnreadable"),
            (Fixtures.webpExtended(width: 5, height: 6, exif: garbage), "webpExifUnreadable"),
        ] {
            let parsed = MediaMetadataReader.extract(source: StillImageMemorySource(bytes: bytes), fileExtension: "bin")
            let result = MediaMetadataResult(parsed)
            XCTAssertEqual(result.outcome, .parsed)
            XCTAssertEqual(result.geometry?.pixelWidth, 5)
            XCTAssertEqual(result.geometry?.pixelHeight, 6)
            XCTAssertTrue(parsed.diagnostics.contains { $0.code == code })
        }
    }

    func testABrokenTIFFInsideExifKeepsTheContainerFamily() {
        // A TIFF header whose IFD0 points past the end: the TIFF parser gives up, the PNG does not.
        let brokenTIFF = Data("II".utf8) + Fixtures.le16(42) + Fixtures.le32(0x00FF_FFFF)
        let result = read(Fixtures.png(width: 9, height: 9, exif: brokenTIFF))
        XCTAssertEqual(result.outcome, .parsed)
        XCTAssertEqual(result.format.family, .png)
        XCTAssertEqual(result.geometry?.pixelWidth, 9)
    }

    // MARK: - Families and revisions

    func testNewFamiliesAreStillsWithTheirOwnRevision() {
        for family in [MediaFormat.Family.png, .webp, .gif] {
            XCTAssertEqual(MediaFormat.Kind(family: family), .image)
            XCTAssertEqual(MediaMetadataReader.extractionRevision(for: family), 0)
        }
        XCTAssertEqual(MediaFileType(family: .png, brand: nil, fileExtension: "bin"), .png)
        XCTAssertEqual(MediaFileType(family: .webp, brand: nil, fileExtension: "bin"), .webp)
        XCTAssertEqual(MediaFileType(family: .gif, brand: nil, fileExtension: "bin"), .gif)
    }

    // MARK: - Helpers

    private func read(_ bytes: Data, hint: String = "a.bin") -> MediaMetadataResult {
        MediaMetadataReader.read(source: StillImageMemorySource(bytes: bytes), filenameHint: hint)
    }

    /// The bytes decide: every fixture is read under a `.bin` hint.
    private func assertStill(
        _ bytes: Data,
        family: MediaFormat.Family,
        fileType: MediaFileType,
        width: Int,
        height: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let identified = MediaMetadataReader.identify(source: StillImageMemorySource(bytes: bytes), filenameHint: "a.bin")
        XCTAssertEqual(identified.family, family, "identify", file: file, line: line)
        XCTAssertEqual(identified.fileType, fileType, "identify", file: file, line: line)
        XCTAssertEqual(identified.kind, .image, "identify", file: file, line: line)
        XCTAssertTrue(identified.detectedByMagic, file: file, line: line)

        let result = read(bytes)
        XCTAssertEqual(result.outcome, .parsed, file: file, line: line)
        XCTAssertEqual(result.format.family, family, file: file, line: line)
        XCTAssertEqual(result.format.kind, .image, file: file, line: line)
        XCTAssertEqual(result.format.fileType, fileType, file: file, line: line)
        XCTAssertFalse(result.format.isCameraRaw, file: file, line: line)
        XCTAssertEqual(result.geometry?.pixelWidth, width, file: file, line: line)
        XCTAssertEqual(result.geometry?.pixelHeight, height, file: file, line: line)
        XCTAssertFalse(result.readCost.readWholeResource || result.readCost.uniqueBytesRead > 64, "reads headers only", file: file, line: line)
    }

    private func assertStandardExif(_ result: MediaMetadataResult, width: Int, height: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.outcome, .parsed, file: file, line: line)
        XCTAssertEqual(result.geometry?.orientation, .right, file: file, line: line)
        XCTAssertEqual(result.geometry?.pixelWidth, width, file: file, line: line)
        XCTAssertEqual(result.geometry?.displayPixelWidth, height, "orientation 6 turns the picture a quarter", file: file, line: line)
        XCTAssertEqual(result.camera?.make, "Apple", file: file, line: line)
        let original = result.timestamps.original
        XCTAssertEqual(original?.year, 2024, file: file, line: line)
        XCTAssertEqual(original?.month, 5, file: file, line: line)
        XCTAssertEqual(original?.day, 6, file: file, line: line)
        XCTAssertEqual(original?.hour, 7, file: file, line: line)
        XCTAssertEqual(original?.minute, 8, file: file, line: line)
        XCTAssertEqual(original?.second, 9, file: file, line: line)
        XCTAssertEqual(original?.utcOffsetSeconds, 3 * 3600, file: file, line: line)
        XCTAssertEqual(original?.instant, ISO8601DateFormatter().date(from: "2024-05-06T04:08:09Z"), file: file, line: line)
        XCTAssertEqual(result.timestamps.captureWallClock?.role, .original, file: file, line: line)
    }
}

/// Bytes in memory, answered exactly as asked.
struct StillImageMemorySource: MediaByteSource {
    let bytes: Data

    var size: UInt64 { UInt64(bytes.count) }

    func data(offset: UInt64, length: Int) throws -> Data? {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else {
            return nil
        }
        let start = Int(offset)
        return bytes.subdata(in: start ..< (start + length))
    }

    func close() {}
}
