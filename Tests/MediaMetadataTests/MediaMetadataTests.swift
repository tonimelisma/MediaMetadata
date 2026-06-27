import Foundation
import XCTest
@testable import MediaMetadata

final class MediaMetadataTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
    }

    func testRead_ReturnsDateTimeOriginalAndOffsetTimeOriginalFromLittleEndianTIFF() throws {
        let url = try writeFixture(
            rawTIFFCaptureDateFixture(
                timestamp: "2026:04:26 14:57:35",
                offset: "-07:00"
            ),
            extension: "arw"
        )

        let result = MediaMetadataReader.extract(url: url)

        XCTAssertEqual(result.identity.family, .tiff)
        XCTAssertTrue(result.identity.detectedByMagic)
        XCTAssertEqual(result.findings.first { $0.key == "DateTimeOriginal" }?.rawValue, "2026:04:26 14:57:35")
        XCTAssertEqual(result.findings.first { $0.key == "OffsetTimeOriginal" }?.rawValue, "-07:00")
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testRead_ParsesOffsetTimestampToAbsoluteInstant() throws {
        let url = try writeFixture(
            rawTIFFCaptureDateFixture(
                timestamp: "2026:04:26 14:57:35",
                offset: "-07:00"
            ),
            extension: "arw"
        )

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .original })

        XCTAssertEqual(timestamp.rawTimestamp, "2026:04:26 14:57:35")
        XCTAssertEqual(timestamp.offsetSeconds, -7 * 60 * 60)
        XCTAssertEqual(timestamp.authority, .localWithOffset)
        XCTAssertEqual(timestamp.instant, makeUTCDate(year: 2026, month: 4, day: 26, hour: 21, minute: 57, second: 35))
        XCTAssertEqual(timestamp.evidenceIDs.count, 2)
    }

    func testRead_TruncatedTIFFReturnsDiagnosticsWithoutCrashing() throws {
        let url = try writeFixture(Data([0x49, 0x49, 0x2A]), extension: "arw")

        let result = MediaMetadataReader.extract(url: url)

        XCTAssertEqual(result.identity.family, .unknown)
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertTrue(result.timestamps.isEmpty)
        XCTAssertEqual(result.diagnostics.first?.code, "truncatedHeader")
    }

    func testRead_TimestampWithoutOffsetHasNoAbsoluteInstant() throws {
        let url = try writeFixture(
            rawTIFFCaptureDateFixture(
                timestamp: "2026:04:26 14:57:35",
                offset: nil
            ),
            extension: "arw"
        )

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .original })

        XCTAssertNil(timestamp.offsetSeconds)
        XCTAssertNil(timestamp.instant)
        XCTAssertEqual(timestamp.authority, .localWithoutOffset)
    }

    func testRead_ParsesJPEGEXIFDateTimeOriginal() throws {
        let url = try writeFixture(
            jpegEXIFFixture(
                timestamp: "2026:04:27 08:45:43",
                offset: nil
            ),
            extension: "jpg"
        )

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .original })

        XCTAssertEqual(result.identity.family, .jpeg)
        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 27, hour: 8, minute: 45, second: 43))
        XCTAssertNil(timestamp.instant)
        XCTAssertEqual(timestamp.authority, .localWithoutOffset)
    }

    func testRead_ReportsReadTimingAndByteMetrics() throws {
        let fixture = jpegEXIFFixture(
            timestamp: "2026:04:27 08:45:43",
            offset: nil
        )
        let url = try writeFixture(fixture, extension: "jpg")

        let result = MediaMetadataReader.extract(url: url)

        XCTAssertEqual(result.readMetrics.parserName, "MediaMetadata.TIFFMetadataParser")
        XCTAssertGreaterThanOrEqual(result.readMetrics.parserElapsedMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(result.readMetrics.elapsedMilliseconds, result.readMetrics.parserElapsedMilliseconds)
        XCTAssertEqual(result.readMetrics.fileSizeBytes, UInt64(fixture.count))
        XCTAssertGreaterThan(result.readMetrics.readOperationCount, 0)
        XCTAssertEqual(result.readMetrics.failedReadOperationCount, 0)
        XCTAssertGreaterThan(result.readMetrics.byteRequestedCount, 0)
        XCTAssertEqual(result.readMetrics.byteReadCount, result.readMetrics.byteRequestedCount)
        XCTAssertGreaterThan(result.readMetrics.uniqueByteReadCount, 0)
        XCTAssertLessThanOrEqual(result.readMetrics.uniqueByteReadCount, result.readMetrics.byteReadCount)
        XCTAssertLessThanOrEqual(result.readMetrics.uniqueByteReadCount, result.readMetrics.fileSizeBytes)
        XCTAssertGreaterThan(result.readMetrics.largestReadLength, 0)
        XCTAssertGreaterThan(result.readMetrics.highestReadEndOffset, 0)
        XCTAssertGreaterThan(result.readMetrics.readCoveragePermille, 0)
    }

    func testRead_JPEGEXIFBatchesTIFFIFDEntryReads() throws {
        let fixture = jpegEXIFFixture(
            timestamp: "2026:04:27 08:45:43",
            offset: nil,
            extraIFD0EntryCount: 32,
            extraExifEntryCount: 32
        )
        let url = try writeFixture(fixture, extension: "jpg")

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .original })

        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 27, hour: 8, minute: 45, second: 43))
        XCTAssertEqual(result.readMetrics.parserName, "MediaMetadata.TIFFMetadataParser")
        XCTAssertLessThanOrEqual(result.readMetrics.readOperationCount, 12)
        XCTAssertFalse(result.readMetrics.readWholeFile)
        XCTAssertLessThan(result.readMetrics.uniqueByteReadCount, result.readMetrics.fileSizeBytes)
    }

    func testRead_ParsesAVIRiffInfoDateChunk() throws {
        let url = try writeFixture(
            aviRIFFInfoFixture(key: "ICRD", value: "2026:04:26 19:33:52"),
            extension: "avi"
        )

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .riff })

        XCTAssertEqual(result.identity.family, .riffAVI)
        XCTAssertEqual(result.findings.first { $0.key == "ICRD" }?.rawValue, "2026:04:26 19:33:52")
        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 52))
        XCTAssertNil(timestamp.instant)
        XCTAssertEqual(timestamp.authority, .localWithoutOffset)
    }

    func testRead_ParsesAVIRiffInfoDateChunkNestedInHeaderList() throws {
        let url = try writeFixture(
            aviRIFFNestedInfoFixture(key: "ICRD", value: "2026:04:26 19:33:52"),
            extension: "avi"
        )

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .riff })

        XCTAssertEqual(result.identity.family, .riffAVI)
        XCTAssertEqual(result.findings.first { $0.key == "ICRD" }?.rawValue, "2026:04:26 19:33:52")
        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 52))
        XCTAssertNil(timestamp.instant)
        XCTAssertEqual(timestamp.authority, .localWithoutOffset)
    }

    func testRead_AVIContinuesParsingSiblingMetadataAfterOverDeepRIFFList() throws {
        let url = try writeFixture(
            aviRIFFOverDeepListThenInfoFixture(key: "ICRD", value: "2026:04:26 19:33:52"),
            extension: "avi"
        )

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .riff })

        XCTAssertEqual(result.diagnostics.first { $0.code == "riffMetadataListDepthExceeded" }?.severity, .warning)
        XCTAssertEqual(result.findings.first { $0.key == "ICRD" }?.rawValue, "2026:04:26 19:33:52")
        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 52))
    }

    func testRead_AVIWithoutDateEmitsDiagnostic() throws {
        let url = try writeFixture(emptyAVIRIFFFixture(), extension: "avi")

        let result = MediaMetadataReader.extract(url: url)

        XCTAssertEqual(result.identity.family, .riffAVI)
        XCTAssertTrue(result.timestamps.isEmpty)
        XCTAssertEqual(result.diagnostics.first { $0.code == "aviMissingEmbeddedDate" }?.severity, .info)
    }

    func testRead_AVISkipsMediaPayloadListChunks() throws {
        let fixture = aviRIFFMoviPayloadFixture()
        let url = try writeFixture(fixture, extension: "avi")

        let result = MediaMetadataReader.extract(url: url)

        XCTAssertEqual(result.identity.family, .riffAVI)
        XCTAssertTrue(result.timestamps.isEmpty)
        XCTAssertNil(result.findings.first { $0.key == "ICRD" })
        XCTAssertEqual(result.diagnostics.first { $0.code == "aviMissingEmbeddedDate" }?.severity, .info)
        XCTAssertEqual(result.readMetrics.parserName, "MediaMetadata.RIFFMetadataParser")
        XCTAssertEqual(result.readMetrics.fileSizeBytes, UInt64(fixture.count))
        XCTAssertLessThan(result.readMetrics.uniqueByteReadCount, UInt64(fixture.count))
        XCTAssertFalse(result.readMetrics.readWholeFile)
        XCTAssertLessThan(result.readMetrics.readCoveragePermille, 10)
        XCTAssertLessThan(result.readMetrics.largestReadLength, 64)
    }

    func testRead_AVISkipsIrrelevantInfoPayloadsAndStopsAfterDate() throws {
        let fixture = aviRIFFInfoFixture(chunks: [
            (key: "INAM", payload: Data(repeating: 0x49, count: 4096)),
            (key: "ICRD", payload: nullTerminatedASCII("2026:04:26 19:33:52")),
            (key: "ISFT", payload: Data(repeating: 0x53, count: 4096)),
        ])
        let url = try writeFixture(fixture, extension: "avi")

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .riff })

        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 52))
        XCTAssertNil(result.findings.first { $0.key == "INAM" })
        XCTAssertNil(result.findings.first { $0.key == "ISFT" })
        XCTAssertFalse(result.readMetrics.readWholeFile)
        XCTAssertLessThan(result.readMetrics.uniqueByteReadCount, 512)
        XCTAssertLessThan(result.readMetrics.largestReadLength, 64)
    }

    func testRead_AVIContinuesAfterMalformedInfoDateUntilParseableTimestamp() throws {
        let fixture = aviRIFFInfoFixture(chunks: [
            (key: "ICRD", payload: nullTerminatedASCII("not a timestamp")),
            (key: "IDIT", payload: nullTerminatedASCII("2026:04:26 19:33:52")),
        ])
        let url = try writeFixture(fixture, extension: "avi")

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .riff })

        XCTAssertEqual(result.findings.first { $0.key == "ICRD" }?.rawValue, "not a timestamp")
        XCTAssertEqual(result.findings.first { $0.key == "IDIT" }?.rawValue, "2026:04:26 19:33:52")
        XCTAssertEqual(timestamp.rawTimestamp, "2026:04:26 19:33:52")
        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 52))
    }

    func testRead_ParsesQuickTimeMetadataDateAndLocation() throws {
        let url = try writeFixture(
            box(
                "moov",
                payload: mdtaMetaBox([
                    "com.apple.quicktime.creationdate": "2026-03-05T00:46:02Z",
                    "com.apple.quicktime.location.ISO6709": "+37.8931-122.0437/",
                ])
            ),
            extension: "mov"
        )

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .quickTimeCreationDate })
        let location = try XCTUnwrap(result.locations.first)

        XCTAssertEqual(result.identity.family, .isoBMFF)
        XCTAssertEqual(timestamp.authority, .absoluteInstant)
        XCTAssertEqual(timestamp.instant, makeUTCDate(year: 2026, month: 3, day: 5, hour: 0, minute: 46, second: 2))
        XCTAssertEqual(location.latitude, 37.8931, accuracy: 0.0001)
        XCTAssertEqual(location.longitude, -122.0437, accuracy: 0.0001)
    }

    func testRead_ParsesISOBMFFWhenSkipBoxPrecedesMetadata() throws {
        var data = box("skip", payload: Data([0x00, 0x01, 0x02, 0x03]))
        data.append(
            box(
                "moov",
                payload: mdtaMetaBox([
                    "com.apple.quicktime.creationdate": "2026-03-05T00:46:02Z",
                ])
            )
        )
        let url = try writeFixture(data, extension: "mov")

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .quickTimeCreationDate })

        XCTAssertEqual(result.identity.family, .isoBMFF)
        XCTAssertEqual(timestamp.instant, makeUTCDate(year: 2026, month: 3, day: 5, hour: 0, minute: 46, second: 2))
    }

    func testRead_ParsesISOBMFFWhenUUIDBoxPrecedesMetadata() throws {
        var uuidPayload = Data(repeating: 0x00, count: 16)
        uuidPayload.append(Data([0x01, 0x02, 0x03, 0x04]))
        var data = box("uuid", payload: uuidPayload)
        data.append(
            box(
                "moov",
                payload: mdtaMetaBox([
                    "com.apple.quicktime.creationdate": "2026-03-05T00:46:02Z",
                ])
            )
        )
        let url = try writeFixture(data, extension: "mov")

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .quickTimeCreationDate })

        XCTAssertEqual(result.identity.family, .isoBMFF)
        XCTAssertEqual(timestamp.instant, makeUTCDate(year: 2026, month: 3, day: 5, hour: 0, minute: 46, second: 2))
    }

    func testRead_ParsesISOBMFFWhenJunkBoxPrecedesMetadata() throws {
        var data = box("junk", payload: Data([0x00, 0x01, 0x02, 0x03]))
        data.append(
            box(
                "moov",
                payload: mdtaMetaBox([
                    "com.apple.quicktime.creationdate": "2026-03-05T00:46:02Z",
                ])
            )
        )
        let url = try writeFixture(data, extension: "mov")

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .quickTimeCreationDate })

        XCTAssertEqual(result.identity.family, .isoBMFF)
        XCTAssertEqual(timestamp.instant, makeUTCDate(year: 2026, month: 3, day: 5, hour: 0, minute: 46, second: 2))
    }

    func testRead_ISOBMFFSkipsIrrelevantMdtaPayloads() throws {
        let fixture = box(
            "moov",
            payload: mdtaMetaBoxPayloads([
                "com.example.large": Data(repeating: 0x41, count: 4096),
                "com.apple.quicktime.creationdate": Data("2026-03-05T00:46:02Z".utf8),
            ])
        )
        let url = try writeFixture(fixture, extension: "mov")

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .quickTimeCreationDate })

        XCTAssertEqual(timestamp.instant, makeUTCDate(year: 2026, month: 3, day: 5, hour: 0, minute: 46, second: 2))
        XCTAssertNil(result.findings.first { $0.key == "com.example.large" })
        XCTAssertFalse(result.readMetrics.readWholeFile)
        XCTAssertLessThan(result.readMetrics.uniqueByteReadCount, UInt64(fixture.count / 2))
        XCTAssertLessThan(result.readMetrics.largestReadLength, 128)
    }

    func testRead_MalformedHEIFItemLocationOffsetOverflowEmitsDiagnostic() throws {
        let url = try writeFixture(
            metaBox(children: [
                iinfBox(itemID: 1),
                ilocBox(
                    itemID: 1,
                    baseOffset: UInt64.max - 1,
                    extentOffset: 2,
                    extentLength: 10
                ),
            ]),
            extension: "heic"
        )

        let result = MediaMetadataReader.extract(url: url)

        XCTAssertEqual(result.identity.family, .heif)
        XCTAssertEqual(result.diagnostics.first { $0.code == "isoItemLocationExtentOverflow" }?.severity, .warning)
    }

    func testRead_MalformedHEIFUnreadableExtentRangeOverflowEmitsDiagnostic() throws {
        let url = try writeFixture(
            metaBox(children: [
                iinfBox(itemID: 1),
                ilocBox(
                    itemID: 1,
                    baseOffset: UInt64.max - 5,
                    extentOffset: 0,
                    extentLength: 10
                ),
            ]),
            extension: "heic"
        )

        let result = MediaMetadataReader.extract(url: url)

        XCTAssertEqual(result.identity.family, .heif)
        XCTAssertEqual(result.diagnostics.first { $0.code == "heifExifItemUnreadable" }?.severity, .warning)
    }

    func testRead_ParsesID3RecordingDate() throws {
        let url = try writeFixture(
            id3Fixture(frameID: "TDRC", value: "2026-04-26T19:33:52"),
            extension: "mp3"
        )

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .id3RecordingDate })

        XCTAssertEqual(result.identity.family, .id3)
        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 52))
        XCTAssertEqual(timestamp.authority, .localWithoutOffset)
    }

    func testRead_ParsesID3RecordingDateWithTimeZoneSuffixSeconds() throws {
        let url = try writeFixture(
            id3Fixture(frameID: "TDRC", value: "2026-04-26T19:33:52+02:00"),
            extension: "mp3"
        )

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .id3RecordingDate })

        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 52))
        XCTAssertEqual(timestamp.authority, .localWithoutOffset)
    }

    func testRead_RejectsMalformedDelimiterOnlyID3RecordingDateWithoutCrash() throws {
        let url = try writeFixture(
            id3Fixture(frameID: "TDRC", value: "-"),
            extension: "mp3"
        )

        let result = MediaMetadataReader.extract(url: url)

        XCTAssertEqual(result.identity.family, .id3)
        XCTAssertTrue(result.timestamps.isEmpty)
        XCTAssertEqual(result.findings.first { $0.key == "TDRC" }?.rawValue, "-")
    }

    func testRead_ID3ContinuesAfterMalformedRecordingDateToOriginalReleaseDate() throws {
        let fixture = id3Fixture(frames: [
            id3TextFrame(frameID: "TDRC", value: "-"),
            id3TextFrame(frameID: "TDOR", value: "2026-04-26T19:33:52"),
        ])
        let url = try writeFixture(fixture, extension: "mp3")

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .id3RecordingDate })

        XCTAssertEqual(result.findings.first { $0.key == "TDRC" }?.rawValue, "-")
        XCTAssertEqual(result.findings.first { $0.key == "TDOR" }?.rawValue, "2026-04-26T19:33:52")
        XCTAssertEqual(timestamp.rawTimestamp, "2026-04-26T19:33:52")
        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 52))
    }

    func testRead_ID3ContinuesAfterMalformedRecordingDateToLegacyDateFrames() throws {
        let fixture = id3Fixture(frames: [
            id3TextFrame(frameID: "TDRC", value: "-"),
            id3TextFrame(frameID: "TYER", value: "2026"),
            id3TextFrame(frameID: "TDAT", value: "2604"),
            id3TextFrame(frameID: "TIME", value: "1933"),
        ])
        let url = try writeFixture(fixture, extension: "mp3")

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .id3RecordingDate })

        XCTAssertEqual(result.findings.first { $0.key == "TDRC" }?.rawValue, "-")
        XCTAssertEqual(result.findings.first { $0.key == "TYER" }?.rawValue, "2026")
        XCTAssertEqual(timestamp.rawTimestamp, "2026 2604 1933")
        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 0))
    }

    func testRead_ID3SkipsIrrelevantPayloadsAndStopsAtRecordingDate() throws {
        let fixture = id3Fixture(frames: [
            id3Frame(frameID: "APIC", payload: Data(repeating: 0xAA, count: 4096)),
            id3TextFrame(frameID: "TDRC", value: "2026-04-26T19:33:52"),
            id3Frame(frameID: "TIT2", payload: Data(repeating: 0xBB, count: 4096)),
        ])
        let url = try writeFixture(fixture, extension: "mp3")

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .id3RecordingDate })

        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 52))
        XCTAssertNil(result.findings.first { $0.key == "APIC" })
        XCTAssertNil(result.findings.first { $0.key == "TIT2" })
        XCTAssertFalse(result.readMetrics.readWholeFile)
        XCTAssertLessThan(result.readMetrics.uniqueByteReadCount, 512)
        XCTAssertLessThan(result.readMetrics.largestReadLength, 64)
    }

    func testRead_ParsesWAVInfoDate() throws {
        let url = try writeFixture(
            wavRIFFInfoFixture(key: "ICRD", value: "2026:04:26 19:33:52"),
            extension: "wav"
        )

        let result = MediaMetadataReader.extract(url: url)
        let timestamp = try XCTUnwrap(result.timestamps.first { $0.role == .riff })

        XCTAssertEqual(result.identity.family, .riffWAV)
        XCTAssertEqual(timestamp.dateComponents, CaptureDateComponents(year: 2026, month: 4, day: 26, hour: 19, minute: 33, second: 52))
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    // MARK: - Public typed contract

    func testPublicRead_TIFFExposesTypedOriginalTimestamp() throws {
        let url = try writeFixture(
            rawTIFFCaptureDateFixture(timestamp: "2026:04:26 14:57:35", offset: "-07:00"),
            extension: "arw"
        )

        let result = MediaMetadataReader.read(url: url)

        XCTAssertEqual(result.outcome, .parsed)
        XCTAssertTrue(result.outcome.isDefinitive)
        XCTAssertFalse(result.outcome.shouldRetry)
        XCTAssertEqual(result.format.family, .tiff)
        let original = try XCTUnwrap(result.timestamps.original)
        XCTAssertEqual(
            [original.year, original.month, original.day, original.hour, original.minute, original.second],
            [2026, 4, 26, 14, 57, 35]
        )
        XCTAssertEqual(original.utcOffsetSeconds, -7 * 60 * 60)
        XCTAssertEqual(original.precision, .localWithOffset)
        XCTAssertEqual(original.instant, makeUTCDate(year: 2026, month: 4, day: 26, hour: 21, minute: 57, second: 35))
        XCTAssertEqual(result.timestamps.all.count, 3)
    }

    func testPublicRead_JPEGExposesTypedCamera() throws {
        let url = try writeFixture(
            jpegEXIFFixture(timestamp: "2026:04:26 14:57:35", offset: "-07:00"),
            extension: "jpg"
        )

        let result = MediaMetadataReader.read(url: url)

        XCTAssertEqual(result.outcome, .parsed)
        XCTAssertEqual(result.format.family, .jpeg)
        XCTAssertNotNil(result.timestamps.original?.instant)
    }

    func testPublicRead_MissingFileIsTransientReadFailure() {
        let url = tempDirectoryURL.appendingPathComponent("does-not-exist.arw")

        let result = MediaMetadataReader.read(url: url)

        XCTAssertEqual(result.outcome, .readFailure)
        XCTAssertTrue(result.outcome.shouldRetry)
        XCTAssertFalse(result.outcome.isDefinitive)
        XCTAssertEqual(result.format.family, .unknown)
    }

    func testPublicRead_UnknownSignatureIsDefinitiveUnsupported() throws {
        let url = try writeFixture(Data("not a media file at all".utf8), extension: "bin")

        let result = MediaMetadataReader.read(url: url)

        XCTAssertEqual(result.outcome, .unsupported)
        XCTAssertTrue(result.outcome.isDefinitive)
        XCTAssertFalse(result.outcome.shouldRetry)
        XCTAssertEqual(result.format.family, .unknown)
        XCTAssertNil(result.video)
        XCTAssertNil(result.camera)
    }

    private func writeFixture(_ data: Data, extension fileExtension: String) throws -> URL {
        let url = tempDirectoryURL.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func rawTIFFCaptureDateFixture(
        timestamp: String,
        offset: String?,
        extraIFD0EntryCount: Int = 0,
        extraExifEntryCount: Int = 0
    ) -> Data {
        let dateTime = nullTerminatedASCII(timestamp)
        let offsetTime = offset.map(nullTerminatedASCII)
        let ifd0Offset = 8
        let ifd0EntryCount = 2 + extraIFD0EntryCount
        let ifd0Size = 2 + ifd0EntryCount * 12 + 4
        let exifIFDOffset = ifd0Offset + ifd0Size
        let exifEntryCount = (offsetTime == nil ? 2 : 3) + extraExifEntryCount
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
        appendIgnoredLongEntries(to: &data, baseTag: 0xC000, count: extraIFD0EntryCount)
        data.append(littleEndianUInt32(0))

        data.append(littleEndianUInt16(UInt16(exifEntryCount)))
        data.append(tiffEntry(tag: 0x9003, type: 2, count: UInt32(dateTime.count), value: UInt32(originalDateOffset)))
        data.append(tiffEntry(tag: 0x9004, type: 2, count: UInt32(dateTime.count), value: UInt32(digitizedDateOffset)))
        if let offsetTime {
            data.append(tiffEntry(tag: 0x9011, type: 2, count: UInt32(offsetTime.count), value: UInt32(offsetTimeOffset)))
        }
        appendIgnoredLongEntries(to: &data, baseTag: 0xC800, count: extraExifEntryCount)
        data.append(littleEndianUInt32(0))

        data.append(dateTime)
        data.append(dateTime)
        data.append(dateTime)
        if let offsetTime {
            data.append(offsetTime)
        }
        return data
    }

    private func jpegEXIFFixture(
        timestamp: String,
        offset: String?,
        extraIFD0EntryCount: Int = 0,
        extraExifEntryCount: Int = 0
    ) -> Data {
        let tiff = rawTIFFCaptureDateFixture(
            timestamp: timestamp,
            offset: offset,
            extraIFD0EntryCount: extraIFD0EntryCount,
            extraExifEntryCount: extraExifEntryCount
        )
        var exifPayload = Data("Exif".utf8)
        exifPayload.append(contentsOf: [0x00, 0x00])
        exifPayload.append(tiff)

        var data = Data([0xFF, 0xD8])
        data.append(contentsOf: [0xFF, 0xE1])
        data.append(bigEndianUInt16(UInt16(exifPayload.count + 2)))
        data.append(exifPayload)
        data.append(contentsOf: [0xFF, 0xD9])
        return data
    }

    private func appendIgnoredLongEntries(to data: inout Data, baseTag: UInt16, count: Int) {
        for index in 0..<count {
            data.append(tiffEntry(tag: baseTag + UInt16(index), type: 4, count: 1, value: UInt32(index)))
        }
    }

    private func aviRIFFInfoFixture(key: String, value: String) -> Data {
        var valueData = Data(value.utf8)
        valueData.append(0)
        return aviRIFFInfoFixture(chunks: [(key: key, payload: valueData)])
    }

    private func aviRIFFInfoFixture(chunks: [(key: String, payload: Data)]) -> Data {
        var listPayload = Data("INFO".utf8)
        for chunk in chunks {
            listPayload.append(riffChunk(id: chunk.key, payload: chunk.payload))
        }
        let listChunk = riffChunk(id: "LIST", payload: listPayload)

        var data = Data("RIFF".utf8)
        data.append(littleEndianUInt32(UInt32(4 + listChunk.count)))
        data.append(Data("AVI ".utf8))
        data.append(listChunk)
        return data
    }

    private func aviRIFFNestedInfoFixture(key: String, value: String) -> Data {
        var valueData = Data(value.utf8)
        valueData.append(0)
        let infoChunk = riffChunk(id: key, payload: valueData)

        var infoListPayload = Data("INFO".utf8)
        infoListPayload.append(infoChunk)
        let infoListChunk = riffChunk(id: "LIST", payload: infoListPayload)

        var headerListPayload = Data("hdrl".utf8)
        headerListPayload.append(infoListChunk)
        let headerListChunk = riffChunk(id: "LIST", payload: headerListPayload)

        var data = Data("RIFF".utf8)
        data.append(littleEndianUInt32(UInt32(4 + headerListChunk.count)))
        data.append(Data("AVI ".utf8))
        data.append(headerListChunk)
        return data
    }

    private func aviRIFFOverDeepListThenInfoFixture(key: String, value: String) -> Data {
        var valueData = Data(value.utf8)
        valueData.append(0)
        let infoChunk = riffChunk(id: key, payload: valueData)

        var infoListPayload = Data("INFO".utf8)
        infoListPayload.append(infoChunk)
        let infoListChunk = riffChunk(id: "LIST", payload: infoListPayload)

        var overDeepPayload = Data("JUNK".utf8)
        overDeepPayload.append(Data([0xAA]))
        let overDeepListChunk = riffChunk(id: "LIST", payload: overDeepPayload)

        var deepestParsedPayload = Data("JUNK".utf8)
        deepestParsedPayload.append(overDeepListChunk)
        deepestParsedPayload.append(infoListChunk)
        var nestedListChunk = riffChunk(id: "LIST", payload: deepestParsedPayload)
        for _ in 0 ..< 15 {
            var payload = Data("JUNK".utf8)
            payload.append(nestedListChunk)
            nestedListChunk = riffChunk(id: "LIST", payload: payload)
        }

        var data = Data("RIFF".utf8)
        data.append(littleEndianUInt32(UInt32(4 + nestedListChunk.count)))
        data.append(Data("AVI ".utf8))
        data.append(nestedListChunk)
        return data
    }

    private func emptyAVIRIFFFixture() -> Data {
        var data = Data("RIFF".utf8)
        data.append(littleEndianUInt32(4))
        data.append(Data("AVI ".utf8))
        return data
    }

    private func aviRIFFMoviPayloadFixture() -> Data {
        var falseMetadataPayload = nullTerminatedASCII("2026:04:26 19:33:52")
        falseMetadataPayload.append(Data(repeating: 0x4D, count: 4096))
        let falseMetadataChunk = riffChunk(id: "ICRD", payload: falseMetadataPayload)

        var moviPayload = Data("movi".utf8)
        moviPayload.append(falseMetadataChunk)
        moviPayload.append(Data(repeating: 0xAA, count: 4096))
        let moviList = riffChunk(id: "LIST", payload: moviPayload)

        var data = Data("RIFF".utf8)
        data.append(littleEndianUInt32(UInt32(4 + moviList.count)))
        data.append(Data("AVI ".utf8))
        data.append(moviList)
        return data
    }

    private func wavRIFFInfoFixture(key: String, value: String) -> Data {
        var valueData = Data(value.utf8)
        valueData.append(0)
        let infoChunk = riffChunk(id: key, payload: valueData)

        var listPayload = Data("INFO".utf8)
        listPayload.append(infoChunk)
        let listChunk = riffChunk(id: "LIST", payload: listPayload)

        var data = Data("RIFF".utf8)
        data.append(littleEndianUInt32(UInt32(4 + listChunk.count)))
        data.append(Data("WAVE".utf8))
        data.append(listChunk)
        return data
    }

    private func id3Fixture(frameID: String, value: String) -> Data {
        id3Fixture(frames: [id3TextFrame(frameID: frameID, value: value)])
    }

    private func id3Fixture(frames: [Data]) -> Data {
        let tagBody = frames.reduce(into: Data()) { partialResult, frame in
            partialResult.append(frame)
        }
        var data = Data("ID3".utf8)
        data.append(contentsOf: [3, 0, 0])
        data.append(synchsafeUInt32(UInt32(tagBody.count)))
        data.append(tagBody)
        return data
    }

    private func id3TextFrame(frameID: String, value: String) -> Data {
        var payload = Data([3])
        payload.append(Data(value.utf8))
        return id3Frame(frameID: frameID, payload: payload)
    }

    private func id3Frame(frameID: String, payload: Data) -> Data {
        var frame = Data(frameID.utf8)
        frame.append(bigEndianUInt32(UInt32(payload.count)))
        frame.append(contentsOf: [0, 0])
        frame.append(payload)
        return frame
    }

    private func mdtaMetaBox(_ values: [String: String]) -> Data {
        mdtaMetaBoxPayloads(values.mapValues { Data($0.utf8) })
    }

    private func mdtaMetaBoxPayloads(_ values: [String: Data]) -> Data {
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
                    payload: dataBox(typeIndicator: 1, value: value)
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

    private func iinfBox(itemID: UInt16) -> Data {
        var entryPayload = Data([2, 0, 0, 0])
        entryPayload.append(bigEndianUInt16(itemID))
        entryPayload.append(bigEndianUInt16(0))
        entryPayload.append(Data("Exif".utf8))

        var payload = Data([0, 0, 0, 0])
        payload.append(bigEndianUInt16(1))
        payload.append(box("infe", payload: entryPayload))
        return box("iinf", payload: payload)
    }

    private func ilocBox(
        itemID: UInt16,
        baseOffset: UInt64,
        extentOffset: UInt64,
        extentLength: UInt64
    ) -> Data {
        var payload = Data([0, 0, 0, 0])
        payload.append(bigEndianUInt16(0x8880))
        payload.append(bigEndianUInt16(1))
        payload.append(bigEndianUInt16(itemID))
        payload.append(bigEndianUInt16(0))
        payload.append(bigEndianUInt64(baseOffset))
        payload.append(bigEndianUInt16(1))
        payload.append(bigEndianUInt64(extentOffset))
        payload.append(bigEndianUInt64(extentLength))
        return box("iloc", payload: payload)
    }

    private func handlerBox(handlerType: String) -> Data {
        var payload = Data([0, 0, 0, 0])
        payload.append(contentsOf: [0, 0, 0, 0])
        payload.append(Data(handlerType.utf8))
        payload.append(Data(repeating: 0, count: 12))
        return box("hdlr", payload: payload)
    }

    private func dataBox(typeIndicator: UInt32, value: Data) -> Data {
        var payload = bigEndianUInt32(typeIndicator)
        payload.append(bigEndianUInt32(0))
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

    private func riffChunk(id: String, payload: Data) -> Data {
        var data = Data(id.utf8)
        data.append(littleEndianUInt32(UInt32(payload.count)))
        data.append(payload)
        if payload.count % 2 == 1 {
            data.append(0)
        }
        return data
    }

    private func tiffEntry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        var data = littleEndianUInt16(tag)
        data.append(littleEndianUInt16(type))
        data.append(littleEndianUInt32(count))
        data.append(littleEndianUInt32(value))
        return data
    }

    private func nullTerminatedASCII(_ value: String) -> Data {
        var data = Data(value.utf8)
        data.append(0)
        return data
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

    private func bigEndianUInt16(_ value: UInt16) -> Data {
        Data([
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
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

    private func synchsafeUInt32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ])
    }

    private func makeUTCDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }
}
