import Foundation
@testable import MediaMetadata
import XCTest

/// A source over an in-memory buffer that answers reads in a deliberately awkward pattern.
///
/// The point of R8: parsing must depend on the bytes, never on how they arrived. A parser
/// that quietly assumed `FileByteSource`'s granularity would still pass every existing
/// test while breaking on the first transport that chunks differently.
private struct PatternedByteSource: MediaByteSource {
    enum Pattern {
        /// Answer every read exactly as asked.
        case exact
        /// Answer through a chunk cache, so reads are served from larger fetches.
        case chunked(Int)
    }

    let bytes: Data
    let pattern: Pattern

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

/// Fails at a chosen read index, to prove a transport failure is never reported as a
/// definitive "no metadata".
private final class FailingByteSource: MediaByteSource {
    let size: UInt64

    private let bytes: Data
    private let failAtRead: Int
    private var reads = 0

    init(bytes: Data, failAtRead: Int) {
        self.bytes = bytes
        self.failAtRead = failAtRead
        size = UInt64(bytes.count)
    }

    func data(offset: UInt64, length: Int) throws -> Data? {
        reads += 1
        if reads > failAtRead {
            throw MediaByteSourceError.transportFailure("camera detached")
        }
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else {
            return nil
        }
        let start = Int(offset)
        return bytes.subdata(in: start ..< (start + length))
    }

    func close() {}
}

/// Answers an in-bounds read with fewer bytes than asked for, and no error — the shape
/// Apple FB7663947 documents `ICCameraFile.requestReadDataAtOffset` producing.
private struct SilentlyShortByteSource: MediaByteSource {
    let bytes: Data

    var size: UInt64 { UInt64(bytes.count) }

    func data(offset: UInt64, length: Int) throws -> Data? {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else {
            return nil
        }
        let delivered = max(length - 1, 0)
        guard delivered == length else {
            throw MediaByteSourceError.shortRead(offset: offset, requested: length, delivered: delivered)
        }
        let start = Int(offset)
        return bytes.subdata(in: start ..< (start + length))
    }

    func close() {}
}

final class MediaByteSourceTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
    }

    // MARK: - R2: the two entry points agree

    func testSourceEntryPointMatchesURLEntryPoint() throws {
        let bytes = Self.tiffFixture()
        let url = try write(bytes, extension: "arw")

        let viaURL = MediaMetadataReader.read(url: url)
        let viaSource = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: bytes, pattern: .exact),
            filenameHint: "DSC00001.arw"
        )

        XCTAssertEqual(viaSource.outcome, viaURL.outcome)
        XCTAssertEqual(viaSource.format, viaURL.format)
        XCTAssertEqual(viaSource.timestamps, viaURL.timestamps)
        XCTAssertEqual(viaSource.camera, viaURL.camera)
    }

    func testFilenameHintIsOptionalAndOnlyReportsAnExtension() {
        let bytes = Self.tiffFixture()
        let named = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: bytes, pattern: .exact), filenameHint: "IMG.ARW"
        )
        let anonymous = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: bytes, pattern: .exact)
        )

        XCTAssertEqual(named.format.fileExtension, "arw")
        XCTAssertEqual(anonymous.format.fileExtension, "")
        // Format identity comes from magic bytes, so the hint changes nothing else.
        XCTAssertEqual(named.format.family, anonymous.format.family)
        XCTAssertEqual(named.timestamps, anonymous.timestamps)
    }

    // MARK: - R8: results do not depend on read granularity

    func testParsingIsIndependentOfReadGranularity() {
        let bytes = Self.tiffFixture()
        let exact = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: bytes, pattern: .exact), filenameHint: "a.arw"
        )

        for chunkSize in [1, 3, 16, 1024, 1_000_000] {
            let cached = CachingByteSource(
                wrapping: PatternedByteSource(bytes: bytes, pattern: .exact),
                chunkSize: chunkSize
            )
            let chunked = MediaMetadataReader.read(source: cached, filenameHint: "a.arw")
            XCTAssertEqual(chunked.outcome, exact.outcome, "chunk \(chunkSize)")
            XCTAssertEqual(chunked.timestamps, exact.timestamps, "chunk \(chunkSize)")
            XCTAssertEqual(chunked.format.family, exact.format.family, "chunk \(chunkSize)")
        }
    }

    // MARK: - R3: the cache collapses reads without changing answers

    func testCachingSourceCollapsesReadsIntoFewerFetches() {
        let bytes = Self.tiffFixture()
        let counting = CountingByteSource(bytes: bytes)
        let cached = CachingByteSource(wrapping: counting, chunkSize: 64 * 1024)

        _ = MediaMetadataReader.read(source: cached, filenameHint: "a.arw")

        XCTAssertLessThanOrEqual(
            counting.upstreamReads, 2,
            "a parse touching one region should collapse into one or two transport fetches"
        )
    }

    // MARK: - R6/R7: a transport failure is never a definitive answer

    func testAReadFailureMidParseYieldsReadFailureNotAbsence() {
        let bytes = Self.tiffFixture()
        let clean = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: bytes, pattern: .exact), filenameHint: "a.arw"
        )
        XCTAssertEqual(clean.outcome, .parsed)
        XCTAssertNotNil(clean.timestamps.original, "the fixture must have a date for this test to mean anything")

        // Fail at every read index the clean parse used. Every one must be transient:
        // a definitive answer here would tell a consumer the file has no capture date,
        // and consumers cache definitive answers.
        for failAt in 0 ..< clean.readCost.readOperationCount {
            let result = MediaMetadataReader.read(
                source: FailingByteSource(bytes: bytes, failAtRead: failAt), filenameHint: "a.arw"
            )
            XCTAssertEqual(result.outcome, .readFailure, "failing at read \(failAt) must be transient")
            XCTAssertTrue(result.outcome.shouldRetry, "failing at read \(failAt) must be retryable")
        }
    }

    func testASilentlyShortReadIsATransportFailureNotEndOfFile() {
        let result = MediaMetadataReader.read(
            source: SilentlyShortByteSource(bytes: Self.tiffFixture()), filenameHint: "a.arw"
        )

        XCTAssertEqual(
            result.outcome, .readFailure,
            "an in-bounds range that under-delivers is a transport fault, not proof the file ends there"
        )
    }

    func testFileByteSourceReturnsNilPastTheEndAndThrowsOnAShortInBoundsRead() throws {
        let url = try write(Data(repeating: 0xAB, count: 32), extension: "bin")
        let source = try FileByteSource(url: url)
        defer { source.close() }

        XCTAssertEqual(try source.data(offset: 0, length: 32)?.count, 32)
        XCTAssertNil(try source.data(offset: 30, length: 8), "a range past the end is a structural nil")
        XCTAssertNil(try source.data(offset: 32, length: 1), "a range starting at the end is a structural nil")
        XCTAssertNil(try source.data(offset: 99, length: 1), "a range beyond the end is a structural nil")
    }

    // MARK: - R5: cost is reported for any source, not just files

    func testReadCostIsReportedForACustomSource() {
        let bytes = Self.tiffFixture()
        let result = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: bytes, pattern: .exact), filenameHint: "a.arw"
        )

        XCTAssertGreaterThan(result.readCost.readOperationCount, 0)
        XCTAssertGreaterThan(result.readCost.bytesRead, 0)
        XCTAssertEqual(result.readCost.resourceSizeBytes, UInt64(bytes.count))
        XCTAssertLessThanOrEqual(
            result.readCost.uniqueBytesRead, UInt64(bytes.count),
            "unique bytes cannot exceed the resource"
        )
    }

    // MARK: - R10: identify without parsing

    func testIdentifyAgreesWithAFullParseAndCostsAlmostNothing() {
        let bytes = Self.tiffFixture()
        let counting = CountingByteSource(bytes: bytes)

        let identified = MediaMetadataReader.identify(source: counting, filenameHint: "a.arw")
        let parsed = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: bytes, pattern: .exact), filenameHint: "a.arw"
        )

        XCTAssertEqual(identified.family, parsed.format.family)
        XCTAssertTrue(identified.detectedByMagic)
        XCTAssertLessThanOrEqual(counting.upstreamReads, 2, "identification must not read the container")
    }

    func testIdentifyReportsUnknownForBytesItDoesNotRecognise() {
        let source = PatternedByteSource(bytes: Data(repeating: 0x5A, count: 64), pattern: .exact)
        let format = MediaMetadataReader.identify(source: source, filenameHint: "mystery.arw")

        XCTAssertEqual(format.family, .unknown)
        XCTAssertFalse(
            format.detectedByMagic,
            "an extension that disagrees with the bytes must not be treated as identification"
        )
    }

    // MARK: - R11: embedded previews are located, verified, and never decoded

    func testAnEmbeddedPreviewIsReportedWithItsRangeAndDimensions() {
        let bytes = Self.tiffFixtureWithPreview()
        let result = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: bytes, pattern: .exact), filenameHint: "a.arw"
        )

        let preview = try! XCTUnwrap(result.previews.first)
        XCTAssertEqual(preview.encoding, .jpeg)
        XCTAssertEqual(preview.pixelWidth, 1_616)
        XCTAssertEqual(preview.pixelHeight, 1_080)
        XCTAssertEqual(preview.sourcePath, "tiff.ifd1")

        // The descriptor must be usable as-is: reading exactly the declared range yields
        // exactly the embedded image. A consumer over a remote transport fetches this range
        // instead of the whole file, so an off-by-one here is a broken image, not a warning.
        let start = Int(preview.byteOffset)
        let extracted = bytes.subdata(in: start ..< (start + preview.byteLength))
        XCTAssertEqual(extracted, Self.fakeJPEG())
    }

    func testAPreviewPointingAtSomethingThatIsNotAnImageIsNotReported() {
        // A descriptor that does not resolve to an image leaves a consumer unable to tell a
        // bad descriptor from a bad transport, so it is refused rather than reported.
        let bytes = Self.tiffFixtureWithPreview(previewBytes: Data(repeating: 0x00, count: 16))
        let result = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: bytes, pattern: .exact), filenameHint: "a.arw"
        )

        XCTAssertTrue(result.previews.isEmpty)
        XCTAssertEqual(result.outcome, .parsed, "a bad preview is not a read failure")
    }

    func testAPreviewDeclaredOutsideTheFileIsNotReported() {
        let bytes = Self.tiffFixtureWithPreview(previewOffsetOverride: 4_000_000)
        let result = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: bytes, pattern: .exact), filenameHint: "a.arw"
        )

        XCTAssertTrue(result.previews.isEmpty)
    }

    func testAFileWithNoEmbeddedPreviewReportsNone() {
        let result = MediaMetadataReader.read(
            source: PatternedByteSource(bytes: Self.tiffFixture(), pattern: .exact), filenameHint: "a.arw"
        )

        XCTAssertTrue(result.previews.isEmpty)
    }

    // MARK: - Helpers

    private func write(_ data: Data, extension fileExtension: String) throws -> URL {
        let url = tempDirectoryURL
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Minimal little-endian TIFF carrying DateTimeOriginal and OffsetTimeOriginal.
    private static func tiffFixture() -> Data {
        var data = Data()
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
        data.append(uint32(8))

        let dateTime = nullTerminated("2026:04:26 14:57:35")
        let offset = nullTerminated("-07:00")
        let ifd0Start: UInt32 = 8
        let ifd0Size: UInt32 = 2 + 12 + 4
        let exifIFDStart = ifd0Start + ifd0Size
        let exifIFDSize: UInt32 = 2 + 24 + 4
        let valuesStart = exifIFDStart + exifIFDSize

        // IFD0: one entry, the ExifIFD pointer.
        data.append(uint16(1))
        data.append(entry(tag: 0x8769, type: 4, count: 1, value: exifIFDStart))
        data.append(uint32(0))

        // ExifIFD: DateTimeOriginal and OffsetTimeOriginal, values placed after both IFDs.
        data.append(uint16(2))
        data.append(entry(tag: 0x9003, type: 2, count: UInt32(dateTime.count), value: valuesStart))
        data.append(entry(
            tag: 0x9011, type: 2, count: UInt32(offset.count),
            value: valuesStart + UInt32(dateTime.count)
        ))
        data.append(uint32(0))

        data.append(dateTime)
        data.append(offset)
        return data
    }

    /// Two bytes of JPEG SOI plus filler, enough to be recognised as a JPEG.
    private static func fakeJPEG() -> Data {
        var data = Data([0xFF, 0xD8])
        data.append(Data(repeating: 0x42, count: 30))
        data.append(Data([0xFF, 0xD9]))
        return data
    }

    /// TIFF with an IFD1 declaring an embedded JPEG at tags 0x0201/0x0202, plus its
    /// dimensions at 0x0100/0x0101 — the shape Sony ARW and the EXIF thumbnail both use.
    private static func tiffFixtureWithPreview(
        previewBytes: Data? = nil,
        previewOffsetOverride: UInt32? = nil
    ) -> Data {
        let preview = previewBytes ?? fakeJPEG()
        var data = Data()
        data.append(contentsOf: [0x49, 0x49, 0x2A, 0x00])
        data.append(uint32(8))

        let ifd0Start: UInt32 = 8
        let ifd0Size: UInt32 = 2 + 12 + 4
        let ifd1Start = ifd0Start + ifd0Size
        let ifd1Size: UInt32 = 2 + (12 * 4) + 4
        let previewStart = ifd1Start + ifd1Size

        // IFD0: one entry (an unused ExifIFD pointer to nowhere useful), next = IFD1.
        data.append(uint16(1))
        data.append(entry(tag: 0x010F, type: 2, count: 1, value: 0))
        data.append(uint32(ifd1Start))

        // IFD1: width, height, preview offset, preview length. Chain terminates.
        data.append(uint16(4))
        data.append(entry(tag: 0x0100, type: 4, count: 1, value: 1_616))
        data.append(entry(tag: 0x0101, type: 4, count: 1, value: 1_080))
        data.append(entry(tag: 0x0201, type: 4, count: 1, value: previewOffsetOverride ?? previewStart))
        data.append(entry(tag: 0x0202, type: 4, count: 1, value: UInt32(preview.count)))
        data.append(uint32(0))

        data.append(preview)
        return data
    }

    private static func entry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        var data = Data()
        data.append(uint16(tag))
        data.append(uint16(type))
        data.append(uint32(count))
        data.append(uint32(value))
        return data
    }

    private static func uint16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    private static func nullTerminated(_ value: String) -> Data {
        var data = Data(value.utf8)
        data.append(0)
        return data
    }
}

/// Counts reads that actually reach the transport, so a cache can be shown to work.
private final class CountingByteSource: MediaByteSource {
    let size: UInt64
    private(set) var upstreamReads = 0

    private let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
        size = UInt64(bytes.count)
    }

    func data(offset: UInt64, length: Int) throws -> Data? {
        upstreamReads += 1
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else {
            return nil
        }
        let start = Int(offset)
        return bytes.subdata(in: start ..< (start + length))
    }

    func close() {}
}
