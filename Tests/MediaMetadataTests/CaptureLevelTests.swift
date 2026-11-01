import Foundation
@testable import MediaMetadata
import XCTest

/// An iPhone records gravity at capture in its Apple MakerNote (`AccelerationVector`). The
/// readings here are the ones measured in photos of a plumb door frame (iPhone 18 Pro), so
/// each expected turn is the one that frame needed.
final class CaptureLevelTests: XCTestCase {
    private var directory: URL!
    private let backCamera = "iPhone 18 Pro back triple camera 6.93mm f/1.48"
    private let frontCamera = "iPhone 18 Pro front camera 2.715mm f/1.9"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testABackCameraHeldUprightIsLevelledByItsRoll() throws {
        let leansRight = try read(gravity: (-0.2639, -0.9315, -0.3652), lens: backCamera)
        XCTAssertEqual(try XCTUnwrap(leansRight.levelingTurnDegrees), -15.82, accuracy: 0.01)
        let leansLeft = try read(gravity: (0.2877, -0.9382, -0.1702), lens: backCamera)
        XCTAssertEqual(try XCTUnwrap(leansLeft.levelingTurnDegrees), 17.05, accuracy: 0.01)
    }

    func testABackCameraHeldLandscapeIsLevelledByItsRollLessTheHold() throws {
        let leansLeft = try read(gravity: (-0.9992, -0.1923, -0.0908), lens: backCamera)
        XCTAssertEqual(try XCTUnwrap(leansLeft.levelingTurnDegrees), 10.89, accuracy: 0.01)
        let leansRight = try read(gravity: (-0.9781, 0.2626, -0.0273), lens: backCamera)
        XCTAssertEqual(try XCTUnwrap(leansRight.levelingTurnDegrees), -15.03, accuracy: 0.01)
    }

    func testAFrontCameraPictureLevelsNothingSinceItsMirroringIsUnrecorded() throws {
        XCTAssertNil(try read(gravity: (-0.1917, -0.9704, 0.1705), lens: frontCamera).levelingTurnDegrees)
    }

    func testAPictureNotKnownToBeFromABackCameraLevelsNothing() throws {
        XCTAssertNil(try read(gravity: (-0.2639, -0.9315, -0.3652), lens: nil).levelingTurnDegrees)
    }

    func testACameraPointingNearStraightDownLevelsNothing() throws {
        XCTAssertNil(try read(gravity: (0.3, -0.5, -0.81), lens: backCamera).levelingTurnDegrees)
    }

    func testAMirroredOrientationReversesTheTurn() throws {
        let mirrored = try read(gravity: (-0.2639, -0.9315, -0.3652), lens: backCamera, orientation: 2)
        XCTAssertEqual(try XCTUnwrap(mirrored.levelingTurnDegrees), 15.82, accuracy: 0.01)
    }

    func testTheReadingSitsBesideTheMakerNotesOtherValues() throws {
        let burst = "8A1C2B3D-4E5F-6071-8293-A4B5C6D7E8F9"
        let result = try read(gravity: (0.2877, -0.9382, -0.1702), lens: backCamera, burst: burst)
        XCTAssertEqual(result.burstIdentifier, burst)
        XCTAssertEqual(try XCTUnwrap(result.levelingTurnDegrees), 17.05, accuracy: 0.01)
    }

    func testAFileWithoutAReadingLevelsNothing() throws {
        let url = try write(jpeg(ifd0: [], exif: [ascii(0xA434, backCamera)]))
        XCTAssertNil(MediaMetadataReader.read(url: url).levelingTurnDegrees)
    }

    // MARK: - Fixtures

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let payload: Data
    }

    private func read(
        gravity: (Double, Double, Double),
        lens: String?,
        orientation: UInt16? = nil,
        burst: String? = nil
    ) throws -> MediaMetadataResult {
        var exif = [undefined(0x927C, appleMakerNote(gravity: gravity, burst: burst))]
        if let lens {
            exif.append(ascii(0xA434, lens))
        }
        let ifd0 = orientation.map { [Entry(tag: 0x0112, type: 3, count: 1, payload: be16($0))] } ?? []
        return MediaMetadataReader.read(url: try write(jpeg(ifd0: ifd0, exif: exif)))
    }

    private func ascii(_ tag: UInt16, _ text: String) -> Entry {
        let payload = Data(text.utf8) + Data([0])
        return Entry(tag: tag, type: 2, count: UInt32(payload.count), payload: payload)
    }

    private func undefined(_ tag: UInt16, _ data: Data) -> Entry {
        Entry(tag: tag, type: 7, count: UInt32(data.count), payload: data)
    }

    /// An Apple MakerNote holding the gravity reading (tag `0x0008`, three signed rationals
    /// over 10⁶) and optionally a burst identifier, value offsets counted from its start.
    private func appleMakerNote(gravity: (Double, Double, Double), burst: String?) -> Data {
        let headerLength = 14
        let entryCount = burst == nil ? 1 : 2
        let ifdLength = 2 + 12 * entryCount + 4
        var vector = Data()
        for component in [gravity.0, gravity.1, gravity.2] {
            vector += be32(UInt32(bitPattern: Int32((component * 1_000_000).rounded()))) + be32(1_000_000)
        }
        var note = Data("Apple iOS".utf8) + Data([0, 0, 1]) + Data("MM".utf8)
        note += be16(UInt16(entryCount))
        note += be16(0x0008) + be16(10) + be32(3) + be32(UInt32(headerLength + ifdLength))
        var values = vector
        if let burst {
            let text = Data(burst.utf8) + Data([0])
            note += be16(0x000B) + be16(2) + be32(UInt32(text.count))
                + be32(UInt32(headerLength + ifdLength + vector.count))
            values += text
        }
        note += be32(0)
        return note + values
    }

    /// A big-endian Exif TIFF in a JPEG: IFD0 holds `ifd0` and a pointer to an Exif IFD
    /// holding `exif`, each in tag order, values of more than four bytes placed after their
    /// IFD.
    private func jpeg(ifd0: [Entry], exif: [Entry]) -> Data {
        let pointer = Entry(tag: 0x8769, type: 4, count: 1, payload: Data())
        let ifd0Entries = (ifd0 + [pointer]).sorted { $0.tag < $1.tag }
        let exifIFDOffset = UInt32(8 + 2 + ifd0Entries.count * 12 + 4)
        var tiff = Data("MM".utf8) + be16(42) + be32(8)
        tiff += be16(UInt16(ifd0Entries.count))
        for entry in ifd0Entries {
            tiff += be16(entry.tag) + be16(entry.type) + be32(entry.count)
            let payload = entry.tag == 0x8769 ? be32(exifIFDOffset) : entry.payload
            tiff += payload + Data(repeating: 0, count: 4 - payload.count)
        }
        tiff += be32(0)

        let entries = exif.sorted { $0.tag < $1.tag }
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
