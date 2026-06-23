import Foundation
import XCTest
@testable import MediaMetadata

final class MetadataParityUnitTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testRead_EmptyISOKeysBoxDoesNotCrash() throws {
        let keysPayload = Data(repeating: 0, count: 8)
        let fixture = box("moov", payload: metaBox(children: [
            handlerBox(handlerType: "mdta"),
            box("keys", payload: keysPayload),
            box("ilst", payload: Data()),
        ]))

        let result = MediaMetadataReader.read(url: try write(fixture, extension: "mov"))

        XCTAssertEqual(result.identity.family, .isoBMFF)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testRead_ParsesQuickTimeCameraKeysAndTrackDimensions() throws {
        let metadata = metaBox(values: [
            "com.apple.quicktime.camera.lens_model": "Prime Lens",
            "com.apple.quicktime.make": "Example Camera Co.",
            "com.apple.quicktime.model": "Example One",
        ])
        var track = trackHeader(width: 1_920, height: 1_080)
        track.append(metadata)
        let fixture = box("moov", payload: box("trak", payload: track))

        let result = MediaMetadataReader.read(url: try write(fixture, extension: "mov"))

        XCTAssertEqual(result.camera?.make, "Example Camera Co.")
        XCTAssertEqual(result.camera?.model, "Example One")
        XCTAssertEqual(result.camera?.lensModel, "Prime Lens")
        XCTAssertEqual(result.camera?.pixelWidth, 1_920)
        XCTAssertEqual(result.camera?.pixelHeight, 1_080)
    }

    func testRead_ParsesTIFFCameraGPSAndFractionalGPSTimestamp() throws {
        let result = MediaMetadataReader.read(url: try write(tiffCameraGPSFixture(), extension: "tiff"))

        XCTAssertEqual(result.camera?.make, "Example")
        XCTAssertEqual(result.camera?.model, "Camera One")
        XCTAssertEqual(result.camera?.lensModel, "Prime Lens")
        XCTAssertEqual(result.camera?.serialNumber, "12345")
        XCTAssertEqual(result.camera?.orientation, 6)
        XCTAssertEqual(result.camera?.pixelWidth, 4_000)
        XCTAssertEqual(result.camera?.pixelHeight, 3_000)
        let location = try XCTUnwrap(result.locations.first)
        XCTAssertEqual(location.latitude, 37.808_333_333_333, accuracy: 0.000_000_001)
        XCTAssertEqual(location.longitude, -122.404_166_666_667, accuracy: 0.000_000_001)
        XCTAssertEqual(location.altitudeMeters, 7.5)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .gps })
        XCTAssertEqual(timestamp.rawTimestamp, "2026:06:23 12 34 56.78")
        let instant = try XCTUnwrap(timestamp.instant)
        XCTAssertEqual(instant.timeIntervalSince1970, 1_782_218_096.78, accuracy: 0.001)
        XCTAssertEqual(timestamp.evidenceIDs.count, 2)
        XCTAssertEqual(result.provenance.first?.status, .parsed)
    }

    func testRead_MalformedGoProGPMFReturnsDiagnostic() throws {
        var malformed = Data("CDAT".utf8)
        malformed.append(contentsOf: [0x4A, 8, 0, 2])
        malformed.append(bigEndianUInt64(1_693_400_431))
        let fixture = box("moov", payload: box("udta", payload: box("GPMF", payload: malformed)))

        let result = MediaMetadataReader.read(url: try write(fixture, extension: "mp4"))

        XCTAssertEqual(result.diagnostics.first?.code, "goproGPMFMalformed")
        XCTAssertTrue(result.timestamps.isEmpty)
    }

    func testSonyNRTMParserExtractsDeviceIdentity() {
        let metadata = ISOBMFFMetadataParser.parseSonyNRTMXML(
            #"<NonRealTimeMeta><Device manufacturer="Sony" modelName="ILCE-6700" serialNo="12345"/></NonRealTimeMeta>"#
        )

        XCTAssertEqual(metadata.manufacturer, "Sony")
        XCTAssertEqual(metadata.model, "ILCE-6700")
        XCTAssertEqual(metadata.serialNumber, "12345")
    }

    private func write(_ data: Data, extension fileExtension: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func trackHeader(width: UInt32, height: UInt32) -> Data {
        var payload = Data(repeating: 0, count: 84)
        payload.replaceSubrange(76..<80, with: bigEndianUInt32(width << 16))
        payload.replaceSubrange(80..<84, with: bigEndianUInt32(height << 16))
        return box("tkhd", payload: payload)
    }

    private func tiffCameraGPSFixture() -> Data {
        let ifd0Offset: UInt32 = 8
        let exifOffset: UInt32 = 74
        let gpsOffset: UInt32 = 128
        let makeOffset: UInt32 = 230
        let modelOffset: UInt32 = 238
        let lensOffset: UInt32 = 249
        let serialOffset: UInt32 = 260
        let latitudeOffset: UInt32 = 266
        let longitudeOffset: UInt32 = 290
        let altitudeOffset: UInt32 = 314
        let timeOffset: UInt32 = 322
        let dateOffset: UInt32 = 346

        var data = Data("II".utf8)
        data.append(littleEndianUInt16(42))
        data.append(littleEndianUInt32(ifd0Offset))

        data.append(littleEndianUInt16(5))
        data.append(tiffEntry(tag: 0x010F, type: 2, count: 8, value: makeOffset))
        data.append(tiffEntry(tag: 0x0110, type: 2, count: 11, value: modelOffset))
        data.append(tiffEntry(tag: 0x0112, type: 3, count: 1, value: 6))
        data.append(tiffEntry(tag: 0x8769, type: 4, count: 1, value: exifOffset))
        data.append(tiffEntry(tag: 0x8825, type: 4, count: 1, value: gpsOffset))
        data.append(littleEndianUInt32(0))

        data.append(littleEndianUInt16(4))
        data.append(tiffEntry(tag: 0xA002, type: 4, count: 1, value: 4_000))
        data.append(tiffEntry(tag: 0xA003, type: 4, count: 1, value: 3_000))
        data.append(tiffEntry(tag: 0xA431, type: 2, count: 6, value: serialOffset))
        data.append(tiffEntry(tag: 0xA434, type: 2, count: 11, value: lensOffset))
        data.append(littleEndianUInt32(0))

        data.append(littleEndianUInt16(8))
        data.append(tiffEntry(tag: 0x0001, type: 2, count: 2, value: 0x4E))
        data.append(tiffEntry(tag: 0x0002, type: 5, count: 3, value: latitudeOffset))
        data.append(tiffEntry(tag: 0x0003, type: 2, count: 2, value: 0x57))
        data.append(tiffEntry(tag: 0x0004, type: 5, count: 3, value: longitudeOffset))
        data.append(tiffEntry(tag: 0x0005, type: 1, count: 1, value: 0))
        data.append(tiffEntry(tag: 0x0006, type: 5, count: 1, value: altitudeOffset))
        data.append(tiffEntry(tag: 0x0007, type: 5, count: 3, value: timeOffset))
        data.append(tiffEntry(tag: 0x001D, type: 2, count: 11, value: dateOffset))
        data.append(littleEndianUInt32(0))

        data.append(Data("Example\0Camera One\0Prime Lens\012345\0".utf8))
        data.append(rationals([(37, 1), (48, 1), (30, 1)]))
        data.append(rationals([(122, 1), (24, 1), (15, 1)]))
        data.append(rationals([(15, 2)]))
        data.append(rationals([(12, 1), (34, 1), (5_678, 100)]))
        data.append(Data("2026:06:23\0".utf8))
        return data
    }

    private func tiffEntry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        var data = littleEndianUInt16(tag)
        data.append(littleEndianUInt16(type))
        data.append(littleEndianUInt32(count))
        data.append(littleEndianUInt32(value))
        return data
    }

    private func rationals(_ values: [(UInt32, UInt32)]) -> Data {
        var data = Data()
        for (numerator, denominator) in values {
            data.append(littleEndianUInt32(numerator))
            data.append(littleEndianUInt32(denominator))
        }
        return data
    }

    private func metaBox(values: [String: String]) -> Data {
        let orderedKeys = values.keys.sorted()
        var keysPayload = Data(repeating: 0, count: 4)
        keysPayload.append(bigEndianUInt32(UInt32(orderedKeys.count)))
        for key in orderedKeys {
            let keyData = Data(key.utf8)
            keysPayload.append(bigEndianUInt32(UInt32(keyData.count + 8)))
            keysPayload.append(Data("mdta".utf8))
            keysPayload.append(keyData)
        }

        var itemList = Data()
        for (index, key) in orderedKeys.enumerated() {
            guard let value = values[key] else {
                continue
            }
            itemList.append(box(typeBytes: Array(bigEndianUInt32(UInt32(index + 1))), payload: dataBox(value)))
        }
        return metaBox(children: [handlerBox(handlerType: "mdta"), box("keys", payload: keysPayload), box("ilst", payload: itemList)])
    }

    private func metaBox(children: [Data]) -> Data {
        var payload = Data(repeating: 0, count: 4)
        children.forEach { payload.append($0) }
        return box("meta", payload: payload)
    }

    private func handlerBox(handlerType: String) -> Data {
        var payload = Data(repeating: 0, count: 8)
        payload.append(Data(handlerType.utf8))
        payload.append(Data(repeating: 0, count: 12))
        return box("hdlr", payload: payload)
    }

    private func dataBox(_ value: String) -> Data {
        var payload = bigEndianUInt32(1)
        payload.append(bigEndianUInt32(0))
        payload.append(Data(value.utf8))
        return box("data", payload: payload)
    }

    private func box(_ type: String, payload: Data) -> Data {
        box(typeBytes: Array(type.utf8), payload: payload)
    }

    private func box(typeBytes: [UInt8], payload: Data) -> Data {
        var data = bigEndianUInt32(UInt32(payload.count + 8))
        data.append(contentsOf: typeBytes)
        data.append(payload)
        return data
    }

    private func bigEndianUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    private func bigEndianUInt64(_ value: UInt64) -> Data {
        Data([
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    private func littleEndianUInt16(_ value: UInt16) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
        ])
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }
}
