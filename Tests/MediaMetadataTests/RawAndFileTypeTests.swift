import Foundation
import XCTest
@testable import MediaMetadata

/// Camera RAW recognised from bytes, canonical file types, audio-only roles, and the
/// per-family extraction revision (0.7.1).
final class RawAndFileTypeTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - TIFF-based RAW, decided from IFD0

    func testDNGVersionMakesADNGWhoeverMadeTheCamera() throws {
        let format = try readTIFF(entries: [entry(Tag.dngVersion, type: 1, count: 4, value: 0x0000_0401)], make: "Canon")
        XCTAssertEqual(format.fileType, .dng)
        XCTAssertTrue(format.isCameraRaw)
        XCTAssertEqual(format.kind, .image)
        XCTAssertEqual(format.family, .tiff)
    }

    func testCR2SignatureMakesACR2() throws {
        let format = try readTIFF(entries: [], make: "Canon", cr2Signature: true)
        XCTAssertEqual(format.fileType, .cr2)
    }

    func testColourFilterArrayInIFD0IsRawNamedByVendor() throws {
        let cfa = entry(Tag.photometric, type: 3, count: 1, value: 32803)
        XCTAssertEqual(try readTIFF(entries: [cfa], make: "RICOH IMAGING COMPANY, LTD.  ").fileType, .pef)
        XCTAssertEqual(try readTIFF(entries: [cfa], make: "Hasselblad").fileType, .otherRaw)
        XCTAssertEqual(try readTIFF(entries: [cfa], make: nil).fileType, .otherRaw)
    }

    func testCameraMakeWithSubIFDsIsRaw() throws {
        let subIFDs = entry(Tag.subIFDs, type: 4, count: 1, value: 0)
        XCTAssertEqual(try readTIFF(entries: [subIFDs], make: "SONY").fileType, .arw)
        XCTAssertEqual(try readTIFF(entries: [subIFDs], make: "NIKON CORPORATION").fileType, .nef)
    }

    func testTIFFExportedFromARawKeepsItsMakeButIsNotRaw() throws {
        // An export carries the camera's Make but has an RGB raster and no SubIFDs.
        let rgb = entry(Tag.photometric, type: 3, count: 1, value: 2)
        let format = try readTIFF(entries: [rgb], make: "SONY")
        XCTAssertEqual(format.fileType, .tiff)
        XCTAssertFalse(format.isCameraRaw)
        XCTAssertEqual(format.kind, .image)
    }

    func testRawClassificationNeverFollowsTheSubIFD() throws {
        // Real ARWs put the raw SubIFD just past the first 128 KB. Point this one at 200 KB
        // and require the parse never to go there: classifying must not cost a round trip.
        let subIFDOffset: UInt32 = 200_000
        let url = try write(
            tiffBytes(entries: [entry(Tag.subIFDs, type: 4, count: 1, value: subIFDOffset)], make: "SONY", paddedTo: 210_000),
            extension: "arw"
        )
        let result = MediaMetadataReader.read(url: url)
        XCTAssertEqual(result.format.fileType, .arw)
        XCTAssertLessThan(result.readCost.highestOffsetTouched, UInt64(subIFDOffset))
    }

    func testEmbeddedExifTIFFIsNeverClassifiedAsRaw() throws {
        // A JPEG's Exif block is a TIFF too; only a top-level TIFF can be a RAW.
        let url = try write(jpegWrapping(tiffBytes(entries: [entry(Tag.subIFDs, type: 4, count: 1, value: 0)], make: "SONY")), extension: "jpg")
        let format = MediaMetadataReader.read(url: url).format
        XCTAssertEqual(format.fileType, .jpeg)
        XCTAssertFalse(format.isCameraRaw)
    }

    // MARK: - RAW in other containers

    func testCR3IsAStillNotAMovie() throws {
        // CR3 stores its raster, preview and thumbnail as `vide` tracks.
        let trak = box("trak", box("tkhd", Data(repeating: 0, count: 84)) + box("mdia", handler("vide")))
        let result = MediaMetadataReader.read(url: try write(ftyp("crx ") + box("moov", trak), extension: "cr3"))
        XCTAssertEqual(result.format.family, .isoBMFF)
        XCTAssertEqual(result.format.fileType, .cr3)
        XCTAssertEqual(result.format.kind, .image)
        XCTAssertTrue(result.format.isCameraRaw)
    }

    func testUnparsedRawFormatsAreRecognisedButStayUnsupported() throws {
        let signatures: [(MediaFileType, Data)] = [
            (.raf, Data("FUJIFILMCCD-RAW 0201".utf8)),
            (.orf, Data([0x49, 0x49, 0x52, 0x4F, 0x08, 0, 0, 0])),
            (.orf, Data([0x4D, 0x4D, 0x4F, 0x52, 0, 0, 0, 0x08])),
            (.rw2, Data([0x49, 0x49, 0x55, 0x00, 0x08, 0, 0, 0])),
        ]
        for (expected, header) in signatures {
            let bytes = header + Data(repeating: 0, count: 64)
            let url = try write(bytes, extension: expected.rawValue)
            let result = MediaMetadataReader.read(url: url)
            XCTAssertEqual(result.outcome, .unsupported, "\(expected)")
            XCTAssertEqual(result.format.family, .unknown, "\(expected)")
            XCTAssertEqual(result.format.fileType, expected)
            XCTAssertEqual(result.format.kind, .image, "\(expected)")
            let identified = MediaMetadataReader.identify(source: try FileByteSource(url: url), filenameHint: url.lastPathComponent)
            XCTAssertEqual(identified.fileType, expected, "identify agrees for \(expected)")
            XCTAssertEqual(identified.kind, .image)
        }
    }

    func testIdentifySaysOnlyWhatTwelveBytesProve() throws {
        // Without IFD0 a TIFF might be an ARW, so identify names no type…
        let plain = try write(tiffBytes(entries: [], make: "SONY"), extension: "arw")
        XCTAssertNil(MediaMetadataReader.identify(source: try FileByteSource(url: plain)).fileType)
        // …except a CR2, whose signature is in the header.
        let cr2 = try write(tiffBytes(entries: [], make: "Canon", cr2Signature: true), extension: "cr2")
        XCTAssertEqual(MediaMetadataReader.identify(source: try FileByteSource(url: cr2)).fileType, .cr2)
    }

    // MARK: - File types

    func testBrandNamesTheISOFileType() throws {
        func type(_ brand: String, track handlerType: String = "vide") throws -> MediaFormat {
            let trak = box("trak", box("tkhd", Data(repeating: 0, count: 84)) + box("mdia", handler(handlerType)))
            return MediaMetadataReader.read(url: try write(ftyp(brand) + box("moov", trak), extension: "bin")).format
        }
        XCTAssertEqual(try type("qt  ").fileType, .mov)
        XCTAssertEqual(try type("mp42").fileType, .mp4)
        XCTAssertEqual(try type("isom").fileType, .mp4)
        XCTAssertEqual(try type("3gp4").fileType, .threeGPP)
        XCTAssertEqual(try type("M4V ").fileType, .m4v)
        let audio = try type("M4A ", track: "soun")
        XCTAssertEqual(audio.fileType, .m4a)
        XCTAssertEqual(audio.kind, .audio)
    }

    func testBytesWinOverAMisleadingExtension() throws {
        let url = try write(ftyp("qt  ") + box("moov", Data()), extension: "mp4")
        XCTAssertEqual(MediaMetadataReader.read(url: url).format.fileType, .mov)
    }

    func testExtensionsFoldIntoOneTypePerFormat() {
        XCTAssertEqual(MediaFileType(fileExtension: "jpg"), .jpeg)
        XCTAssertEqual(MediaFileType(fileExtension: "JPE"), .jpeg)
        XCTAssertEqual(MediaFileType(fileExtension: ".jpeg"), .jpeg)
        XCTAssertEqual(MediaFileType(fileExtension: "tif"), .tiff)
        XCTAssertEqual(MediaFileType(fileExtension: "TIFF"), .tiff)
        XCTAssertEqual(MediaFileType(fileExtension: "heic"), .heif)
        XCTAssertEqual(MediaFileType(fileExtension: "HIF"), .heif)
        XCTAssertEqual(MediaFileType(fileExtension: "heif"), .heif)
        XCTAssertEqual(MediaFileType(fileExtension: "avif"), .avif)
        XCTAssertEqual(MediaFileType(fileExtension: "3gp"), .threeGPP)
        XCTAssertEqual(MediaFileType(fileExtension: "ARW"), .arw)
        XCTAssertNil(MediaFileType(fileExtension: "raw"), "too ambiguous to name")
        XCTAssertNil(MediaFileType(fileExtension: "otherRaw"), "not an extension")
        XCTAssertNil(MediaFileType(fileExtension: ""))
    }

    func testDisplayNamesAndRawValuesAreStable() {
        XCTAssertEqual(MediaFileType.jpeg.displayName, "JPEG")
        XCTAssertEqual(MediaFileType.heif.displayName, "HEIF")
        XCTAssertEqual(MediaFileType.threeGPP.displayName, "3GP")
        XCTAssertEqual(MediaFileType.threeGPP.rawValue, "3gp")
        XCTAssertEqual(MediaFileType.otherRaw.displayName, "RAW")
        for type in MediaFileType.allCases {
            XCTAssertEqual(MediaFileType(rawValue: type.rawValue), type)
        }
    }

    func testFileTypeKindsAndRawFlags() {
        XCTAssertEqual(MediaFileType.allCases.filter(\.isCameraRaw),
                       [.dng, .arw, .cr2, .cr3, .nef, .orf, .rw2, .raf, .pef, .srw, .otherRaw])
        XCTAssertEqual(MediaFileType.mov.kind, .video)
        XCTAssertEqual(MediaFileType.wav.kind, .audio)
        XCTAssertEqual(MediaFileType.arw.kind, .image)
    }

    // MARK: - Roles and revisions

    func testOnlySoundFileRolesAreAudioOnly() {
        XCTAssertEqual(CaptureTimestamps.Role.allCases.filter(\.isAudioOnly), [.id3Recording, .waveOrigination])
        XCTAssertFalse(CaptureTimestamps.Role.riffRecording.isAudioOnly, "RIFF also carries AVI video")
    }

    func testRevisionsMoveOnlyForTheFamiliesThatChanged() {
        XCTAssertEqual(MediaMetadataReader.extractionRevision(for: .tiff), 0)
        XCTAssertEqual(MediaMetadataReader.extractionRevision(for: .jpeg), 0)
        XCTAssertEqual(MediaMetadataReader.extractionRevision(for: .heif), 1)
        XCTAssertEqual(MediaMetadataReader.extractionRevision(for: .isoBMFF), 2)
        XCTAssertEqual(MediaMetadataReader.extractionRevision(for: .unknown), 1)
        XCTAssertEqual(
            MediaMetadataReader.extractionRevision,
            MediaFormat.Family.allCases.map(MediaMetadataReader.extractionRevision(for:)).max()
        )
    }

    // MARK: - Fixtures

    private enum Tag {
        static let make: UInt16 = 0x010F
        static let photometric: UInt16 = 0x0106
        static let subIFDs: UInt16 = 0x014A
        static let dngVersion: UInt16 = 0xC612
    }

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let value: UInt32
    }

    private func entry(_ tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Entry {
        Entry(tag: tag, type: type, count: count, value: value)
    }

    private func readTIFF(entries: [Entry], make: String?, cr2Signature: Bool = false) throws -> MediaFormat {
        let url = try write(tiffBytes(entries: entries, make: make, cr2Signature: cr2Signature), extension: "tif")
        return MediaMetadataReader.read(url: url).format
    }

    /// A little-endian TIFF with one IFD; `make` is appended after it as ASCII.
    private func tiffBytes(entries: [Entry], make: String?, cr2Signature: Bool = false, paddedTo size: Int? = nil) -> Data {
        let ifd0Offset: Int = cr2Signature ? 16 : 8
        var all = entries
        let makeBytes = make.map { Data(($0 + "\u{0}").utf8) }
        let entryCount: Int = all.count + (makeBytes == nil ? 0 : 1)
        let afterIFD: Int = ifd0Offset + 2 + 12 * entryCount + 4
        if let makeBytes {
            all.append(entry(Tag.make, type: 2, count: UInt32(makeBytes.count), value: UInt32(afterIFD)))
        }
        all.sort { $0.tag < $1.tag }

        var data = Data("II".utf8) + le16(42) + le32(UInt32(ifd0Offset))
        if cr2Signature {
            data += Data([0x43, 0x52, 0x02, 0x00]) + le32(0)
        }
        data += le16(UInt16(all.count))
        for item in all {
            data += le16(item.tag) + le16(item.type) + le32(item.count) + le32(item.value)
        }
        data += le32(0)
        if let makeBytes {
            data += makeBytes
        }
        if let size, data.count < size {
            data += Data(repeating: 0, count: size - data.count)
        }
        return data
    }

    /// SOI, an APP1 `Exif\0\0` segment wrapping `tiff`, then EOI.
    private func jpegWrapping(_ tiff: Data) -> Data {
        let payload = Data("Exif".utf8) + Data([0, 0]) + tiff
        let length = UInt16(payload.count + 2)
        return Data([0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)]) + payload + Data([0xFF, 0xD9])
    }

    private func handler(_ type: String) -> Data {
        box("hdlr", Data(repeating: 0, count: 8) + Data(type.utf8) + Data(repeating: 0, count: 12))
    }

    private func ftyp(_ brand: String) -> Data {
        box("ftyp", Data(brand.utf8) + be32(0) + Data(brand.utf8))
    }

    private func box(_ type: String, _ payload: Data) -> Data {
        be32(UInt32(8 + payload.count)) + Data(type.utf8) + payload
    }

    private func be32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    private func le16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }

    private func write(_ data: Data, extension fileExtension: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }
}
