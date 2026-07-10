import Foundation
import XCTest
@testable import MediaMetadata

/// Pins the capture-local wall-clock contract (plan 0055 §4.5 items 1–5).
final class CaptureLocalContractTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - Item 1: wall-clock completeness

    func testContract_FloatingEXIFHasCompleteLocalComponents() throws {
        let result = MediaMetadataReader.read(url: try write(
            tiffCaptureDate(timestamp: "2026:04:26 14:57:35", offset: nil),
            extension: "arw"
        ))
        let original = try XCTUnwrap(result.timestamps.original)

        XCTAssertEqual(original.precision, .localFloating)
        XCTAssertNil(original.utcOffsetSeconds)
        XCTAssertNil(original.instant)
        assertCompleteComponents(original, year: 2026, month: 4, day: 26, hour: 14, minute: 57, second: 35)
        XCTAssertEqual(
            original.captureLocalComponents,
            CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 14, minute: 57, second: 35)
        )
    }

    func testContract_OffsetBearingEXIFHasCompleteLocalComponents() throws {
        let result = MediaMetadataReader.read(url: try write(
            tiffCaptureDate(timestamp: "2026:04:26 14:57:35", offset: "-07:00"),
            extension: "arw"
        ))
        let original = try XCTUnwrap(result.timestamps.original)

        XCTAssertEqual(original.precision, .localWithOffset)
        XCTAssertEqual(original.utcOffsetSeconds, -7 * 60 * 60)
        XCTAssertNotNil(original.instant)
        assertCompleteComponents(original, year: 2026, month: 4, day: 26, hour: 14, minute: 57, second: 35)
        XCTAssertEqual(
            original.captureLocalComponents,
            CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 14, minute: 57, second: 35)
        )
    }

    func testContract_GPSAnchoredIsAbsoluteWithCompleteUTCComponents() throws {
        let result = MediaMetadataReader.read(url: try write(tiffCameraGPSFixture(), extension: "tiff"))
        let gps = try XCTUnwrap(result.timestamps.gps)

        XCTAssertEqual(gps.precision, .absolute)
        XCTAssertEqual(gps.utcOffsetSeconds, 0)
        XCTAssertNotNil(gps.instant)
        assertCompleteComponents(gps, year: 2026, month: 6, day: 23, hour: 12, minute: 34, second: 56)
        XCTAssertNil(gps.captureLocalComponents)
    }

    func testContract_QuickTimeUTCEpochIsAbsolute() throws {
        let result = MediaMetadataReader.read(url: try write(
            box("moov", payload: mdtaMetaBox([
                "com.apple.quicktime.creationdate": "2026-03-05T00:46:02Z",
            ])),
            extension: "mov"
        ))
        let creation = try XCTUnwrap(result.timestamps.quickTimeCreation)

        XCTAssertEqual(creation.precision, .absolute)
        XCTAssertEqual(creation.utcOffsetSeconds, 0)
        assertCompleteComponents(creation, year: 2026, month: 3, day: 5, hour: 0, minute: 46, second: 2)
        XCTAssertNil(creation.captureLocalComponents)
    }

    func testContract_ExplicitPlusZeroOffsetRemainsLocalWithOffset() throws {
        let result = MediaMetadataReader.read(url: try write(
            box("moov", payload: mdtaMetaBox([
                "com.apple.quicktime.creationdate": "2026-03-05T00:46:02+0000",
            ])),
            extension: "mov"
        ))
        let creation = try XCTUnwrap(result.timestamps.quickTimeCreation)

        XCTAssertEqual(creation.precision, .localWithOffset)
        XCTAssertEqual(creation.utcOffsetSeconds, 0)
        XCTAssertEqual(
            creation.captureLocalComponents,
            CaptureDateComponents(year: 2026, month: 3, day: 5, hour: 0, minute: 46, second: 2)
        )
    }

    // MARK: - Item 2: captureLocalComponents accessor

    func testCaptureLocalComponents_NilForAbsolute_PresentForLocal() {
        let absolute = CaptureTime(
            year: 2023, month: 8, day: 30, hour: 13, minute: 0, second: 31,
            utcOffsetSeconds: 0, instant: Date(timeIntervalSince1970: 1_693_400_431), precision: .absolute
        )
        let floating = CaptureTime(
            year: 2026, month: 4, day: 26, hour: 14, minute: 57, second: 35,
            utcOffsetSeconds: nil, instant: nil, precision: .localFloating
        )
        let offset = CaptureTime(
            year: 2026, month: 4, day: 26, hour: 14, minute: 57, second: 35,
            utcOffsetSeconds: -25_200, instant: Date(), precision: .localWithOffset
        )

        XCTAssertNil(absolute.captureLocalComponents)
        XCTAssertEqual(
            floating.captureLocalComponents,
            CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 14, minute: 57, second: 35)
        )
        XCTAssertEqual(
            offset.captureLocalComponents,
            CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 14, minute: 57, second: 35)
        )
    }

    // MARK: - Item 3: local-preferring role selection

    func testRoleSelection_PrefersLocalAuthorityOverEarlierAbsolute() throws {
        // GPMF absolute epoch is recorded before the Apple offset-bearing key.
        var udta = Data()
        udta.append(box("GPMF", payload: gpmfRecords([
            gpmfCDAT(epoch: 1_693_400_431),
        ])))
        udta.append(mdtaMetaBox([
            "com.apple.quicktime.creationdate": "2023-08-30T18:30:31+05:30",
        ]))
        let url = try write(
            box("moov", payload: box("udta", payload: udta)),
            extension: "mp4"
        )

        let internalCandidates = MediaMetadataReader.extract(url: url)
            .timestamps.filter { $0.role == .quickTimeCreationDate }
        XCTAssertGreaterThanOrEqual(internalCandidates.count, 2)
        XCTAssertEqual(internalCandidates.first?.authority, .absoluteInstant)

        let creation = try XCTUnwrap(MediaMetadataReader.read(url: url).timestamps.quickTimeCreation)
        XCTAssertEqual(creation.precision, .localWithOffset)
        XCTAssertEqual(creation.utcOffsetSeconds, 5 * 60 * 60 + 30 * 60)
        XCTAssertEqual(
            creation.captureLocalComponents,
            CaptureDateComponents(year: 2023, month: 8, day: 30, hour: 18, minute: 30, second: 31)
        )
    }

    // MARK: - Item 4: GPMF UTC + TimeZone → derived localWithOffset

    func testGoProGPMF_DerivesLocalWithOffsetFromEpochAndTimeZone() throws {
        let epoch: UInt64 = 1_693_400_431 // 2023-08-30 13:00:31 UTC
        let minutes = 330 // +05:30
        let fixture = box("moov", payload: box("udta", payload: box("GPMF", payload: gpmfRecords([
            gpmfCDAT(epoch: epoch),
            gpmfTZON(minutes: Int16(minutes)),
        ]))))
        let url = try write(fixture, extension: "mp4")

        let parsed = MediaMetadataReader.extract(url: url)
        let roleCandidates = parsed.timestamps.filter { $0.role == .quickTimeCreationDate }
        XCTAssertEqual(roleCandidates.count, 2)
        XCTAssertEqual(roleCandidates[0].authority, .absoluteInstant)
        XCTAssertEqual(roleCandidates[1].authority, .localWithOffset)
        XCTAssertEqual(roleCandidates[1].offsetSeconds, minutes * 60)
        XCTAssertEqual(
            roleCandidates[1].dateComponents,
            CaptureDateComponents(year: 2023, month: 8, day: 30, hour: 18, minute: 30, second: 31)
        )
        XCTAssertEqual(roleCandidates[1].evidenceIDs.count, 2)
        XCTAssertEqual(roleCandidates[0].instant, roleCandidates[1].instant)

        let publicCreation = try XCTUnwrap(MediaMetadataReader.read(url: url).timestamps.quickTimeCreation)
        XCTAssertEqual(publicCreation.precision, .localWithOffset)
        XCTAssertEqual(publicCreation.utcOffsetSeconds, minutes * 60)
        XCTAssertEqual(
            publicCreation.captureLocalComponents,
            CaptureDateComponents(year: 2023, month: 8, day: 30, hour: 18, minute: 30, second: 31)
        )
        XCTAssertEqual(publicCreation.instant, Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    func testGoProGPMF_EpochAloneStaysAbsolute() throws {
        let result = MediaMetadataReader.read(url: try write(
            box("moov", payload: box("udta", payload: box("GPMF", payload: gpmfRecords([
                gpmfCDAT(epoch: 1_693_400_431),
            ])))),
            extension: "mp4"
        ))
        let creation = try XCTUnwrap(result.timestamps.quickTimeCreation)

        XCTAssertEqual(creation.precision, .absolute)
        XCTAssertNil(creation.captureLocalComponents)
        assertCompleteComponents(creation, year: 2023, month: 8, day: 30, hour: 13, minute: 0, second: 31)
    }

    // MARK: - Helpers

    private func assertCompleteComponents(
        _ time: CaptureTime,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(time.year, year, file: file, line: line)
        XCTAssertEqual(time.month, month, file: file, line: line)
        XCTAssertEqual(time.day, day, file: file, line: line)
        XCTAssertEqual(time.hour, hour, file: file, line: line)
        XCTAssertEqual(time.minute, minute, file: file, line: line)
        XCTAssertEqual(time.second, second, file: file, line: line)
    }

    private func write(_ data: Data, extension fileExtension: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func tiffCaptureDate(timestamp: String, offset: String?) -> Data {
        let dateTime = nullTerminatedASCII(timestamp)
        let offsetTime = offset.map(nullTerminatedASCII)
        let ifd0Offset = 8
        let ifd0EntryCount = 2
        let ifd0Size = 2 + ifd0EntryCount * 12 + 4
        let exifIFDOffset = ifd0Offset + ifd0Size
        let exifEntryCount = offsetTime == nil ? 2 : 3
        let exifIFDSize = 2 + exifEntryCount * 12 + 4
        let tiffDateOffset = exifIFDOffset + exifIFDSize
        let originalDateOffset = tiffDateOffset + dateTime.count
        let digitizedDateOffset = originalDateOffset + dateTime.count
        let offsetTimeOffset = digitizedDateOffset + dateTime.count

        var data = Data("II".utf8)
        data.append(littleEndianUInt16(42))
        data.append(littleEndianUInt32(UInt32(ifd0Offset)))

        data.append(littleEndianUInt16(UInt16(ifd0EntryCount)))
        data.append(tiffEntry(tag: 0x0132, type: 2, count: UInt32(dateTime.count), value: UInt32(tiffDateOffset)))
        data.append(tiffEntry(tag: 0x8769, type: 4, count: 1, value: UInt32(exifIFDOffset)))
        data.append(littleEndianUInt32(0))

        data.append(littleEndianUInt16(UInt16(exifEntryCount)))
        data.append(tiffEntry(tag: 0x9003, type: 2, count: UInt32(dateTime.count), value: UInt32(originalDateOffset)))
        data.append(tiffEntry(tag: 0x9004, type: 2, count: UInt32(dateTime.count), value: UInt32(digitizedDateOffset)))
        if let offsetTime {
            data.append(tiffEntry(tag: 0x9011, type: 2, count: UInt32(offsetTime.count), value: UInt32(offsetTimeOffset)))
        }
        data.append(littleEndianUInt32(0))

        data.append(dateTime)
        data.append(dateTime)
        data.append(dateTime)
        if let offsetTime {
            data.append(offsetTime)
        }
        return data
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

    private func gpmfRecords(_ records: [Data]) -> Data {
        records.reduce(into: Data()) { $0.append($1) }
    }

    private func gpmfCDAT(epoch: UInt64) -> Data {
        gpmfRecord(tag: "CDAT", type: 0x4A, size: 8, count: 1, payload: bigEndianUInt64(epoch))
    }

    private func gpmfTZON(minutes: Int16) -> Data {
        gpmfRecord(tag: "TZON", type: 0x73, size: 2, count: 1, payload: bigEndianUInt16(UInt16(bitPattern: minutes)))
    }

    private func gpmfRecord(tag: String, type: UInt8, size: UInt8, count: UInt16, payload: Data) -> Data {
        var data = Data(tag.utf8)
        data.append(type)
        data.append(size)
        data.append(bigEndianUInt16(count))
        data.append(payload)
        while data.count % 4 != 0 {
            data.append(0)
        }
        return data
    }

    private func mdtaMetaBox(_ values: [String: String]) -> Data {
        let orderedKeys = values.keys.sorted()
        var keysPayload = Data([0, 0, 0, 0])
        keysPayload.append(bigEndianUInt32(UInt32(orderedKeys.count)))
        for key in orderedKeys {
            let keyData = Data(key.utf8)
            keysPayload.append(bigEndianUInt32(UInt32(8 + keyData.count)))
            keysPayload.append(Data("mdta".utf8))
            keysPayload.append(keyData)
        }

        var ilstPayload = Data()
        for (offset, key) in orderedKeys.enumerated() {
            guard let value = values[key] else {
                continue
            }
            ilstPayload.append(
                box(
                    typeBytes: Array(bigEndianUInt32(UInt32(offset + 1))),
                    payload: dataBox(typeIndicator: 1, value: Data(value.utf8))
                )
            )
        }

        return metaBox(children: [
            handlerBox(handlerType: "mdta"),
            box("keys", payload: keysPayload),
            box("ilst", payload: ilstPayload),
        ])
    }

    private func metaBox(children: [Data]) -> Data {
        var payload = Data([0, 0, 0, 0])
        for child in children {
            payload.append(child)
        }
        return box("meta", payload: payload)
    }

    private func handlerBox(handlerType: String) -> Data {
        var payload = Data(repeating: 0, count: 8)
        payload.append(Data(handlerType.utf8))
        payload.append(Data(repeating: 0, count: 12))
        return box("hdlr", payload: payload)
    }

    private func dataBox(typeIndicator: UInt32, value: Data) -> Data {
        var payload = bigEndianUInt32(typeIndicator)
        payload.append(contentsOf: [0, 0, 0, 0])
        payload.append(value)
        return box("data", payload: payload)
    }

    private func box(_ type: String, payload: Data) -> Data {
        box(typeBytes: Array(type.utf8), payload: payload)
    }

    private func box(typeBytes: [UInt8], payload: Data) -> Data {
        var data = bigEndianUInt32(UInt32(8 + payload.count))
        data.append(contentsOf: typeBytes)
        data.append(payload)
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

    private func nullTerminatedASCII(_ value: String) -> Data {
        var data = Data(value.utf8)
        data.append(0)
        return data
    }

    private func littleEndianUInt16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private func littleEndianUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    private func bigEndianUInt16(_ value: UInt16) -> Data {
        Data([UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
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
}
