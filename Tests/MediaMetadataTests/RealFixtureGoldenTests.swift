import Foundation
import XCTest
@testable import MediaMetadata

final class RealFixtureGoldenTests: XCTestCase {
    func testAllRealFixturesMatchExifToolDerivedGoldens() throws {
        let corpus = try loadCorpus()
        XCTAssertEqual(corpus.schemaVersion, 1)
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
        XCTAssertEqual(result.identity.family.rawValue, expected.identity.family, context)
        XCTAssertEqual(result.identity.observedExtension, expected.identity.extension, context)
        XCTAssertEqual(result.identity.brand, expected.identity.brand, context)
        XCTAssertTrue(result.identity.detectedByMagic, context)

        for finding in expected.findings {
            let matches = result.findings.filter {
                $0.namespace == finding.namespace
                    && $0.key == finding.key
                    && $0.rawValue == finding.rawValue
            }
            XCTAssertEqual(matches.count, finding.count ?? 1, "\(context): finding \(finding.namespace).\(finding.key)")
        }
        assertFindingIntegrity(result, fileSize: result.readMetrics.fileSizeBytes, context: context)
        try assertTimestamps(result.timestamps, expected: expected.timestamps, context: context)
        assertLocations(result.locations, expected: expected.locations, context: context)
        assertCamera(result.camera, expected: expected.camera, context: context)
        XCTAssertEqual(result.diagnostics.map(\.code), expected.diagnosticCodes, context)
        XCTAssertEqual(
            result.provenance.map { "\($0.parser):\($0.status.rawValue)" },
            expected.provenance,
            context
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value
        XCTAssertEqual(result.readMetrics.fileSizeBytes, fileSize, context)
        XCTAssertEqual(result.readMetrics.failedReadOperationCount, 0, context)
        XCTAssertFalse(result.readMetrics.readWholeFile, context)
        XCTAssertLessThanOrEqual(result.readMetrics.uniqueByteReadCount, result.readMetrics.fileSizeBytes, context)
        XCTAssertLessThanOrEqual(result.readMetrics.largestReadLength, 1_048_576, context)
    }

    private func assertFindingIntegrity(_ result: MediaMetadataResult, fileSize: UInt64, context: String) {
        for (index, finding) in result.findings.enumerated() {
            XCTAssertEqual(finding.id, index, context)
            if let range = finding.byteRange {
                XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound, context)
                XCTAssertLessThanOrEqual(range.upperBound, fileSize, "\(context): \(finding.sourcePath)")
            }
        }
        let validIDs = Set(result.findings.map(\.id))
        for timestamp in result.timestamps {
            XCTAssertFalse(timestamp.evidenceIDs.isEmpty, context)
            XCTAssertTrue(timestamp.evidenceIDs.allSatisfy(validIDs.contains), context)
        }
        for location in result.locations {
            XCTAssertFalse(location.evidenceIDs.isEmpty, context)
            XCTAssertTrue(location.evidenceIDs.allSatisfy(validIDs.contains), context)
        }
    }

    private func assertTimestamps(
        _ actual: [CaptureTimestampCandidate],
        expected: [GoldenTimestamp],
        context: String
    ) throws {
        XCTAssertEqual(actual.count, expected.reduce(0) { $0 + ($1.count ?? 1) }, context)
        for expectedTimestamp in expected {
            let expectedDate = try expectedTimestamp.instant.map(parseISO8601)
            let matches = actual.filter { timestamp in
                guard timestamp.role.rawValue == expectedTimestamp.role,
                      timestamp.rawTimestamp == expectedTimestamp.rawTimestamp,
                      timestamp.authority.rawValue == expectedTimestamp.authority,
                      timestamp.offsetSeconds == expectedTimestamp.offsetSeconds,
                      components(timestamp.dateComponents) == expectedTimestamp.components else {
                    return false
                }
                switch (timestamp.instant, expectedDate) {
                case (nil, nil):
                    return true
                case let (actualDate?, expectedDate?):
                    return abs(actualDate.timeIntervalSince(expectedDate)) < 0.001
                default:
                    return false
                }
            }
            XCTAssertEqual(matches.count, expectedTimestamp.count ?? 1, "\(context): timestamp \(expectedTimestamp.role)")
        }
    }

    private func assertLocations(
        _ actual: [CaptureLocationCandidate],
        expected: [GoldenLocation],
        context: String
    ) {
        XCTAssertEqual(actual.count, expected.count, context)
        for (actualLocation, expectedLocation) in zip(actual, expected) {
            XCTAssertEqual(actualLocation.latitude, expectedLocation.latitude, accuracy: 0.000_000_1, context)
            XCTAssertEqual(actualLocation.longitude, expectedLocation.longitude, accuracy: 0.000_000_1, context)
            assertOptionalDoubleEqual(
                actualLocation.altitudeMeters,
                expectedLocation.altitudeMeters,
                accuracy: 0.000_001,
                context
            )
            XCTAssertEqual(actualLocation.rawValue, expectedLocation.rawValue, context)
            XCTAssertEqual(actualLocation.source, expectedLocation.source, context)
        }
    }

    private func assertCamera(_ actual: CameraMetadata?, expected: GoldenCamera?, context: String) {
        XCTAssertEqual(actual?.make, expected?.make, context)
        XCTAssertEqual(actual?.model, expected?.model, context)
        XCTAssertEqual(actual?.lensModel, expected?.lensModel, context)
        XCTAssertEqual(actual?.serialNumber, expected?.serialNumber, context)
        XCTAssertEqual(actual?.orientation, expected?.orientation, context)
        XCTAssertEqual(actual?.pixelWidth, expected?.pixelWidth, context)
        XCTAssertEqual(actual?.pixelHeight, expected?.pixelHeight, context)
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

    private func components(_ value: CaptureDateComponents) -> [Int] {
        [value.year, value.month, value.day, value.hour, value.minute, value.second]
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
    let identity: GoldenIdentity
    let findings: [GoldenFinding]
    let timestamps: [GoldenTimestamp]
    let locations: [GoldenLocation]
    let camera: GoldenCamera?
    let diagnosticCodes: [String]
    let provenance: [String]
}

private struct GoldenIdentity: Decodable {
    let family: String
    let `extension`: String
    let brand: String?
}

private struct GoldenFinding: Decodable {
    let namespace: String
    let key: String
    let rawValue: String
    let count: Int?
}

private struct GoldenTimestamp: Decodable {
    let role: String
    let rawTimestamp: String
    let components: [Int]
    let instant: String?
    let offsetSeconds: Int?
    let authority: String
    let count: Int?
}

private struct GoldenLocation: Decodable {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double?
    let rawValue: String
    let source: String
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
