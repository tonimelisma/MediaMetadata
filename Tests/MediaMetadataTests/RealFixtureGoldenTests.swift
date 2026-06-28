import Foundation
import XCTest
@testable import MediaMetadata

final class RealFixtureGoldenTests: XCTestCase {
    func testAllRealFixturesMatchExifToolDerivedGoldens() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 2)
        XCTAssertEqual(corpus.fixtures.count, 16)

        for fixture in corpus.fixtures {
            try assertFixture(fixture)
        }
    }

    private func assertFixture(_ expected: GoldenFixture) throws {
        let url = Self.fixturesURL.appendingPathComponent(expected.path)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Missing required local fixture \(expected.path). Run Scripts/check-local-fixtures.sh."
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try assertExifToolRecord(at: URL(fileURLWithPath: url.path + ".exiftool.json"), fixture: expected.path)
        try assertExifToolRecord(at: URL(fileURLWithPath: url.path + ".exiftool.ordered.json"), fixture: expected.path)

        let result = MediaMetadataReader.read(url: url)
        let context = "fixture \(expected.path)"

        // Public typed contract.
        XCTAssertEqual(result.outcome.rawValue, expected.outcome, context)
        XCTAssertEqual(result.format.family.rawValue, expected.format.family, context)
        XCTAssertEqual(result.format.fileExtension, expected.format.extension, context)
        XCTAssertEqual(result.format.brand, expected.format.brand, context)
        XCTAssertEqual(result.format.detectedByMagic, expected.format.detectedByMagic, context)

        try assertTimestamps(result.timestamps, expected: expected.timestamps, context: context)
        assertLocations(result.locations, expected: expected.locations, context: context)
        assertCamera(result.camera, expected: expected.camera, context: context)
        assertVideo(result.video, expected: expected.video, context: context)

        // Read-metrics guardrails remain enforced through the internal evidence graph.
        let parsed = MediaMetadataReader.extract(url: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value
        XCTAssertEqual(parsed.readMetrics.fileSizeBytes, fileSize, context)
        XCTAssertEqual(parsed.readMetrics.failedReadOperationCount, 0, context)
        XCTAssertFalse(parsed.readMetrics.readWholeFile, context)
        XCTAssertLessThanOrEqual(parsed.readMetrics.uniqueByteReadCount, parsed.readMetrics.fileSizeBytes, context)
        XCTAssertLessThanOrEqual(parsed.readMetrics.largestReadLength, 1_048_576, context)
    }

    private func assertTimestamps(
        _ actual: CaptureTimestamps,
        expected: GoldenTimestamps,
        context: String
    ) throws {
        let fields: [(String, GoldenTime?, CaptureTime?)] = [
            ("original", expected.original, actual.original),
            ("digitized", expected.digitized, actual.digitized),
            ("tiffDateTime", expected.tiffDateTime, actual.tiffDateTime),
            ("gps", expected.gps, actual.gps),
            ("quickTimeCreation", expected.quickTimeCreation, actual.quickTimeCreation),
            ("quickTimeLocation", expected.quickTimeLocation, actual.quickTimeLocation),
            ("quickTimeContentCreate", expected.quickTimeContentCreate, actual.quickTimeContentCreate),
            ("containerCreation", expected.containerCreation, actual.containerCreation),
            ("id3Recording", expected.id3Recording, actual.id3Recording),
            ("waveOrigination", expected.waveOrigination, actual.waveOrigination),
            ("riffRecording", expected.riffRecording, actual.riffRecording),
        ]
        for (name, expectedTime, actualTime) in fields {
            try assertTime(expectedTime, actualTime, field: name, context: context)
        }
    }

    private func assertTime(
        _ expected: GoldenTime?,
        _ actual: CaptureTime?,
        field: String,
        context: String
    ) throws {
        switch (expected, actual) {
        case (nil, nil):
            return
        case let (expected?, actual?):
            XCTAssertEqual(
                [actual.year, actual.month, actual.day, actual.hour, actual.minute, actual.second],
                expected.components,
                "\(context): \(field) components"
            )
            XCTAssertEqual(actual.utcOffsetSeconds, expected.offsetSeconds, "\(context): \(field) offset")
            XCTAssertEqual(actual.precision.rawValue, expected.precision, "\(context): \(field) precision")
            let expectedInstant = try expected.instant.map(parseISO8601)
            switch (actual.instant, expectedInstant) {
            case (nil, nil):
                break
            case let (actualInstant?, expectedInstant?):
                XCTAssertEqual(actualInstant.timeIntervalSince(expectedInstant), 0, accuracy: 0.001, "\(context): \(field) instant")
            default:
                XCTFail("\(context): \(field) instant presence mismatch")
            }
        default:
            XCTFail("\(context): \(field) presence mismatch (expected \(expected != nil), got \(actual != nil))")
        }
    }

    private func assertLocations(_ actual: CaptureLocations, expected: GoldenLocations, context: String) {
        let fields: [(String, GoldenLocation?, GeoLocation?)] = [
            ("exifGPS", expected.exifGPS, actual.exifGPS),
            ("quickTime", expected.quickTime, actual.quickTime),
            ("sonyNRTM", expected.sonyNRTM, actual.sonyNRTM),
        ]
        for (name, expectedLocation, actualLocation) in fields {
            assertLocation(expectedLocation, actualLocation, field: name, context: context)
        }
    }

    private func assertLocation(_ expected: GoldenLocation?, _ actual: GeoLocation?, field: String, context: String) {
        switch (expected, actual) {
        case (nil, nil):
            return
        case let (expected?, actual?):
            XCTAssertEqual(actual.latitude, expected.latitude, accuracy: 0.000_000_1, "\(context): \(field) latitude")
            XCTAssertEqual(actual.longitude, expected.longitude, accuracy: 0.000_000_1, "\(context): \(field) longitude")
            assertOptionalDoubleEqual(actual.altitudeMeters, expected.altitudeMeters, accuracy: 0.000_001, "\(context): \(field) altitude")
        default:
            XCTFail("\(context): \(field) location presence mismatch (expected \(expected != nil), got \(actual != nil))")
        }
    }

    private func assertCamera(_ actual: Camera?, expected: GoldenCamera?, context: String) {
        XCTAssertEqual(actual?.make, expected?.make, context)
        XCTAssertEqual(actual?.model, expected?.model, context)
        XCTAssertEqual(actual?.lensModel, expected?.lensModel, context)
        XCTAssertEqual(actual?.serialNumber, expected?.serialNumber, context)
        XCTAssertEqual(actual?.orientation?.rawValue, expected?.orientation, context)
        XCTAssertEqual(actual?.pixelWidth, expected?.pixelWidth, context)
        XCTAssertEqual(actual?.pixelHeight, expected?.pixelHeight, context)
    }

    private func assertVideo(_ actual: VideoInfo?, expected: GoldenVideo?, context: String) {
        switch (expected, actual) {
        case (nil, nil):
            return
        case let (expected?, actual?):
            assertOptionalDoubleEqual(actual.durationSeconds, expected.durationSeconds, accuracy: 0.01, "\(context): duration")
            assertOptionalDoubleEqual(actual.frameRate, expected.frameRate, accuracy: 0.05, "\(context): frameRate")
            XCTAssertEqual(actual.codec.map(Self.codecString), expected.codec, "\(context): codec")
        default:
            XCTFail("\(context): video presence mismatch")
        }
    }

    private static func codecString(_ codec: VideoCodec) -> String {
        switch codec {
        case .h264: return "h264"
        case .hevc: return "hevc"
        case .proRes: return "proRes"
        case .av1: return "av1"
        case .vp9: return "vp9"
        case .motionJPEG: return "motionJPEG"
        case let .other(fourCC): return "other:\(fourCC)"
        }
    }

    private func assertExifToolRecord(at url: URL, fixture: String) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Missing ExifTool record for \(fixture)")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object?["fixture"] as? String, fixture)
        XCTAssertFalse((object?["exifToolVersion"] as? String ?? "").isEmpty)
    }

    private func loadCorpus() throws -> GoldenCorpus {
        let url = Self.fixturesURL.appendingPathComponent("metadata-golden.json")
        return try JSONDecoder().decode(GoldenCorpus.self, from: Data(contentsOf: url))
    }

    private func parseISO8601(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? standard.date(from: value) else {
            throw GoldenTestError.invalidDate(value)
        }
        return date
    }

    private static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
}

private enum GoldenTestError: Error {
    case invalidDate(String)
}

private struct GoldenCorpus: Decodable {
    let schemaVersion: Int
    let fixtures: [GoldenFixture]
}

private struct GoldenFixture: Decodable {
    let path: String
    let outcome: String
    let format: GoldenFormat
    let timestamps: GoldenTimestamps
    let locations: GoldenLocations
    let camera: GoldenCamera?
    let video: GoldenVideo?
}

private struct GoldenFormat: Decodable {
    let family: String
    let `extension`: String
    let brand: String?
    let detectedByMagic: Bool
}

private struct GoldenTimestamps: Decodable {
    let original: GoldenTime?
    let digitized: GoldenTime?
    let tiffDateTime: GoldenTime?
    let gps: GoldenTime?
    let quickTimeCreation: GoldenTime?
    let quickTimeLocation: GoldenTime?
    let quickTimeContentCreate: GoldenTime?
    let containerCreation: GoldenTime?
    let id3Recording: GoldenTime?
    let waveOrigination: GoldenTime?
    let riffRecording: GoldenTime?
}

private struct GoldenTime: Decodable {
    let components: [Int]
    let instant: String?
    let offsetSeconds: Int?
    let precision: String
}

private struct GoldenLocations: Decodable {
    let exifGPS: GoldenLocation?
    let quickTime: GoldenLocation?
    let sonyNRTM: GoldenLocation?
}

private struct GoldenLocation: Decodable {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double?
}

private struct GoldenCamera: Decodable {
    let make: String?
    let model: String?
    let lensModel: String?
    let serialNumber: String?
    let orientation: Int?
    let pixelWidth: Int?
    let pixelHeight: Int?
}

private struct GoldenVideo: Decodable {
    let durationSeconds: Double?
    let frameRate: Double?
    let codec: String?
}

private extension XCTestCase {
    func assertOptionalDoubleEqual(
        _ expression1: Double?,
        _ expression2: Double?,
        accuracy: Double,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (expression1, expression2) {
        case (nil, nil):
            return
        case let (lhs?, rhs?):
            XCTAssertEqual(lhs, rhs, accuracy: accuracy, message, file: file, line: line)
        default:
            XCTFail(message, file: file, line: line)
        }
    }
}
