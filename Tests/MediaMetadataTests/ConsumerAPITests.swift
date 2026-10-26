import Foundation
import XCTest
@testable import MediaMetadata

/// The consumer-facing affordances added in 0.7.0: display geometry (including movie track
/// rotation), structural media kind, typed timestamp roles and location sources, the
/// purpose-named timestamp selections, and stable codec identifiers.
final class ConsumerAPITests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - Movie track rotation

    func testIdentityTrackMatrixReportsUpright() throws {
        let geometry = try XCTUnwrap(try readMovie(matrix: .identity).geometry)
        XCTAssertEqual(geometry.orientation, .up)
        XCTAssertEqual(geometry.displayPixelWidth, 1920)
        XCTAssertEqual(geometry.displayPixelHeight, 1080)
    }

    func testPortraitPhoneMatrixReportsRightAndSwapsDisplaySize() throws {
        // The iPhone portrait matrix (ExifTool "Rotation 90"): a=0 b=1 c=-1 d=0.
        let geometry = try XCTUnwrap(try readMovie(matrix: TrackMatrix(a: 0, b: 1, c: -1, d: 0)).geometry)
        XCTAssertEqual(geometry.orientation, .right)
        XCTAssertEqual(geometry.pixelWidth, 1920, "stored size stays as encoded")
        XCTAssertEqual(geometry.pixelHeight, 1080)
        XCTAssertEqual(geometry.displayPixelWidth, 1080)
        XCTAssertEqual(geometry.displayPixelHeight, 1920)
    }

    func testUpsideDownMatrixReportsDown() throws {
        let geometry = try XCTUnwrap(try readMovie(matrix: TrackMatrix(a: -1, b: 0, c: 0, d: -1)).geometry)
        XCTAssertEqual(geometry.orientation, .down)
        XCTAssertEqual(geometry.displayPixelWidth, 1920)
    }

    func testRotation270MatrixReportsLeft() throws {
        let geometry = try XCTUnwrap(try readMovie(matrix: TrackMatrix(a: 0, b: -1, c: 1, d: 0)).geometry)
        XCTAssertEqual(geometry.orientation, .left)
        XCTAssertEqual(geometry.displayPixelWidth, 1080)
    }

    func testMirroredMatrixReportsUpMirrored() throws {
        let geometry = try XCTUnwrap(try readMovie(matrix: TrackMatrix(a: -1, b: 0, c: 0, d: 1)).geometry)
        XCTAssertEqual(geometry.orientation, .upMirrored)
    }

    func testScaledOrSkewedMatrixReportsNoOrientation() throws {
        // A 2x scale has no EXIF equivalent; reporting the nearest one would mislead.
        let scaled = try XCTUnwrap(try readMovie(matrix: TrackMatrix(rawA: 0x0002_0000, b: 0, c: 0, rawD: 0x0002_0000)).geometry)
        XCTAssertNil(scaled.orientation)
        XCTAssertEqual(scaled.pixelWidth, 1920, "dimensions still reported")
        XCTAssertEqual(scaled.displayPixelWidth, 1920, "absent orientation is treated as upright")
    }

    // MARK: - Media kind

    func testVideoTrackMakesAMovie() throws {
        let result = try readMovie(matrix: .identity)
        XCTAssertEqual(result.format.family, .isoBMFF)
        XCTAssertEqual(result.format.kind, .video)
        XCTAssertNil(result.camera, "no device identity in this file")
    }

    func testSoundOnlyTrackIsAudio() throws {
        let trak = box("trak", payload: trackHeader(matrix: .identity, width: 0, height: 0) + box("mdia", payload: handlerBox("soun")))
        let result = MediaMetadataReader.read(url: try write(ftyp("M4A ") + box("moov", payload: trak), "m4a"))
        XCTAssertEqual(result.format.kind, .audio)
        XCTAssertNil(result.geometry)
    }

    func testImageSequenceTrackIsAStill() throws {
        let trak = box("trak", payload: trackHeader(matrix: .identity, width: 640, height: 480) + box("mdia", payload: handlerBox("pict")))
        let result = MediaMetadataReader.read(url: try write(ftyp("msf1") + box("moov", payload: trak), "heics"))
        XCTAssertEqual(result.format.kind, .image)
    }

    func testAVIFIsAHEIFStill() throws {
        // AVIF is HEIF with an AV1 codec: same family, and a still, never a movie.
        let meta = box("meta", payload: Data([0, 0, 0, 0]) + box("pitm", payload: Data([0, 0, 0, 0, 0, 1])))
        let result = MediaMetadataReader.read(url: try write(ftyp("avif") + meta, "avif"))
        XCTAssertEqual(result.format.family, .heif)
        XCTAssertEqual(result.format.brand, "avif")
        XCTAssertEqual(result.format.kind, .image)
    }

    func testIdentifyCannotTellWhatAnISOFileHolds() throws {
        let url = try write(ftyp("isom") + box("free", payload: Data()), "mp4")
        let format = MediaMetadataReader.identify(source: try FileByteSource(url: url), filenameHint: url.lastPathComponent)
        XCTAssertEqual(format.family, .isoBMFF)
        XCTAssertEqual(format.kind, .unknown, "identify reads magic only; ISO contents decide the kind")
    }

    func testFamilyImpliesKindWhereItCan() {
        XCTAssertEqual(MediaFormat(family: .jpeg, fileExtension: "jpg", detectedByMagic: true).kind, .image)
        XCTAssertEqual(MediaFormat(family: .riffAVI, fileExtension: "avi", detectedByMagic: true).kind, .video)
        XCTAssertEqual(MediaFormat(family: .riffWAV, fileExtension: "wav", detectedByMagic: true).kind, .audio)
        XCTAssertEqual(MediaFormat(family: .isoBMFF, fileExtension: "mp4", detectedByMagic: true).kind, .unknown)
    }

    // MARK: - Orientation and geometry

    func testSwapsDimensionsExactlyForQuarterTurns() {
        XCTAssertEqual(Orientation.allCases.filter(\.swapsDimensions), [.leftMirrored, .right, .rightMirrored, .left])
        XCTAssertEqual(Orientation.allCases.filter(\.isMirrored), [.upMirrored, .downMirrored, .leftMirrored, .rightMirrored])
    }

    func testGeometryDisplaySizeFollowsOrientation() {
        XCTAssertEqual(PixelGeometry(pixelWidth: 4032, pixelHeight: 3024, orientation: .right).displayPixelWidth, 3024)
        XCTAssertEqual(PixelGeometry(pixelWidth: 4032, pixelHeight: 3024, orientation: .right).displayPixelHeight, 4032)
        XCTAssertEqual(PixelGeometry(pixelWidth: 4032, pixelHeight: 3024, orientation: .down).displayPixelWidth, 4032)
        XCTAssertEqual(PixelGeometry(pixelWidth: 4032, pixelHeight: 3024).displayPixelWidth, 4032)
    }

    // MARK: - Roles and sources

    func testRolesNameEveryFieldAndRoundTripTheirRawValues() {
        let time = floating(2026, 1, 2, 3, 4, 5)
        let timestamps = CaptureTimestamps(original: time, gps: absolute(1_700_000_000), riffRecording: time)
        XCTAssertEqual(timestamps.entries.map(\.role), [.original, .gps, .riffRecording])
        XCTAssertEqual(timestamps[.original], time)
        XCTAssertNil(timestamps[.digitized])
        XCTAssertEqual(timestamps.all.count, 3)
        for role in CaptureTimestamps.Role.allCases {
            XCTAssertEqual(CaptureTimestamps.Role(rawValue: role.rawValue), role)
        }
        XCTAssertEqual(CaptureTimestamps.Role.allCases.count, 11, "one role per CaptureTimestamps field")
    }

    func testLocationSourcesNameEveryField() {
        let here = GeoLocation(latitude: 60.17, longitude: 24.94)
        let locations = CaptureLocations(exifGPS: nil, quickTime: here, sonyNRTM: nil)
        XCTAssertEqual(locations.entries.map(\.source), [.quickTime])
        XCTAssertEqual(locations[.quickTime], here)
        XCTAssertEqual(CaptureLocations.Source.allCases.map(\.rawValue), ["exifGPS", "quickTime", "sonyNRTM"])
    }

    // MARK: - Selections

    func testWallClockPrefersTheCameraClockAndInstantSkipsAFloatingOne() throws {
        // A floating Exif original pins the local wall clock but not the instant, which
        // then comes from the next role that has one.
        let timestamps = CaptureTimestamps(
            original: floating(2026, 4, 25, 14, 51, 34),
            quickTimeCreation: withOffset(2026, 4, 25, 14, 51, 34, offset: -25_200)
        )
        XCTAssertEqual(timestamps.captureWallClock?.role, .original)
        XCTAssertEqual(timestamps.captureInstant?.role, .quickTimeCreation)
    }

    func testAbsoluteOnlyTimestampsNeverBecomeAWallClock() {
        let timestamps = CaptureTimestamps(gps: absolute(1_700_000_000), containerCreation: absolute(1_700_000_100))
        XCTAssertNil(timestamps.captureWallClock, "UTC-anchored values say nothing about the capture zone")
        XCTAssertEqual(timestamps.captureInstant?.role, .gps, "GPS qualifies; container creation is excluded")
    }

    func testContainerCreationAloneSelectsNothing() {
        let timestamps = CaptureTimestamps(containerCreation: absolute(1_700_000_000))
        XCTAssertNil(timestamps.captureWallClock)
        XCTAssertNil(timestamps.captureInstant)
        XCTAssertNotNil(timestamps.containerCreation, "still available to a caller that accepts it")
    }

    func testTIFFModificationTimeIsNotACaptureTime() {
        let timestamps = CaptureTimestamps(tiffDateTime: floating(2026, 1, 1, 0, 0, 0))
        XCTAssertNil(timestamps.captureWallClock)
    }

    func testPrecedenceListsOnlyNameCaptureRoles() {
        XCTAssertFalse(CaptureTimestamps.wallClockPrecedence.contains(.containerCreation))
        XCTAssertFalse(CaptureTimestamps.wallClockPrecedence.contains(.gps))
        XCTAssertFalse(CaptureTimestamps.instantPrecedence.contains(.containerCreation))
        XCTAssertEqual(CaptureTimestamps.wallClockPrecedence.first, .original)
    }

    // MARK: - Codec identifiers and revision

    func testCodecIdentifiersAreStableAndRoundTrip() {
        let codecs: [VideoCodec] = [.h264, .hevc, .proRes, .av1, .vp9, .motionJPEG, .other(fourCC: "mp4v")]
        XCTAssertEqual(codecs.map(\.identifier), ["h264", "hevc", "proRes", "av1", "vp9", "motionJPEG", "other:mp4v"])
        XCTAssertEqual(codecs.map { VideoCodec(identifier: $0.identifier) }, codecs)
        XCTAssertEqual(String(describing: VideoCodec.other(fourCC: "mp4v")), "other:mp4v")
        XCTAssertNil(VideoCodec(identifier: "betamax"))
    }

    func testExtractionRevisionIsPublishedAndPositive() {
        XCTAssertGreaterThanOrEqual(MediaMetadataReader.extractionRevision, 1)
    }

    // MARK: - Fixtures

    private struct TrackMatrix {
        static let identity = TrackMatrix(a: 1, b: 0, c: 0, d: 1)
        let a: Int32
        let b: Int32
        let c: Int32
        let d: Int32

        init(a: Int32, b: Int32, c: Int32, d: Int32) {
            self.a = a << 16
            self.b = b << 16
            self.c = c << 16
            self.d = d << 16
        }

        init(rawA: Int32, b: Int32, c: Int32, rawD: Int32) {
            self.a = rawA
            self.b = b << 16
            self.c = c << 16
            self.d = rawD
        }
    }

    /// A one-track movie: `ftyp`, then `moov/trak` with a version-0 `tkhd` and a video handler.
    private func readMovie(matrix: TrackMatrix) throws -> MediaMetadataResult {
        let trak = box("trak", payload: trackHeader(matrix: matrix, width: 1920, height: 1080) + box("mdia", payload: handlerBox("vide")))
        return MediaMetadataReader.read(url: try write(ftyp("qt  ") + box("moov", payload: trak), "mov"))
    }

    /// Version-0 `tkhd`: 40 bytes of header fields, the 36-byte matrix, then 16.16 width/height.
    private func trackHeader(matrix: TrackMatrix, width: UInt32, height: UInt32) -> Data {
        var payload = Data(repeating: 0, count: 40)
        for value in [matrix.a, matrix.b, 0, matrix.c, matrix.d, 0, 0, 0, 0x4000_0000] as [Int32] {
            payload.append(bigEndian(UInt32(bitPattern: value)))
        }
        payload.append(bigEndian(width << 16))
        payload.append(bigEndian(height << 16))
        return box("tkhd", payload: payload)
    }

    private func handlerBox(_ handler: String) -> Data {
        var payload = Data(repeating: 0, count: 8)
        payload.append(Data(handler.utf8))
        payload.append(Data(repeating: 0, count: 12))
        return box("hdlr", payload: payload)
    }

    private func ftyp(_ brand: String) -> Data {
        box("ftyp", payload: Data(brand.utf8) + bigEndian(0) + Data(brand.utf8))
    }

    private func box(_ type: String, payload: Data) -> Data {
        bigEndian(UInt32(8 + payload.count)) + Data(type.utf8) + payload
    }

    private func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private func write(_ data: Data, _ fileExtension: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func floating(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> CaptureTime {
        CaptureTime(year: y, month: mo, day: d, hour: h, minute: mi, second: s, utcOffsetSeconds: nil, instant: nil, precision: .localFloating)
    }

    private func withOffset(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, offset: Int) -> CaptureTime {
        var components = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        components.timeZone = TimeZone(secondsFromGMT: offset)
        let instant = Calendar(identifier: .gregorian).date(from: components)
        return CaptureTime(year: y, month: mo, day: d, hour: h, minute: mi, second: s, utcOffsetSeconds: offset, instant: instant, precision: .localWithOffset)
    }

    private func absolute(_ seconds: TimeInterval) -> CaptureTime {
        CaptureTime(year: 2023, month: 11, day: 14, hour: 22, minute: 13, second: 20, utcOffsetSeconds: 0, instant: Date(timeIntervalSince1970: seconds), precision: .absolute)
    }
}
