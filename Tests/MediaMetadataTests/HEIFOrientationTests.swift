import Foundation
import XCTest
@testable import MediaMetadata

/// Orientation from HEIF/AVIF transform properties (`irot`/`imir`), which carry the
/// displayed orientation of rotated images that have no Exif `Orientation` tag.
///
/// The rotation table, the mirror axis semantics, and the combined cases were verified
/// against Apple ImageIO by patching real HEICs in place: `irot` angles 0/1/2/3 report
/// orientations 1/8/3/6; `imir` axis 0/1 report 4/2; and ImageIO applies the properties
/// in the order `ipma` lists them (e.g. mirror-then-rotate `imir` axis 1 + `irot` 3 → 7).
final class HEIFOrientationTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - irot alone

    func testIrotAngle0ReportsUp() throws {
        try assertOrientation(.up, forTransformOnly: [irotBox(angle: 0)])
    }

    func testIrotAngle1ReportsLeft() throws {
        try assertOrientation(.left, forTransformOnly: [irotBox(angle: 1)])
    }

    func testIrotAngle2ReportsDown() throws {
        try assertOrientation(.down, forTransformOnly: [irotBox(angle: 2)])
    }

    func testIrotAngle3ReportsRight() throws {
        try assertOrientation(.right, forTransformOnly: [irotBox(angle: 3)])
    }

    // MARK: - imir alone (axis semantics pinned to ImageIO / ISO/IEC 23008-12:2022)

    func testImirAxis0ReportsDownMirrored() throws {
        try assertOrientation(.downMirrored, forTransformOnly: [imirBox(axis: 0)])
    }

    func testImirAxis1ReportsUpMirrored() throws {
        try assertOrientation(.upMirrored, forTransformOnly: [imirBox(axis: 1)])
    }

    // MARK: - imir combined with irot, in ipma order

    func testMirrorAxis0ThenRotate3ReportsLeftMirrored() throws {
        // Applied in ipma order: imir axis 0, then irot angle 3 → EXIF 5 (ImageIO-verified).
        try assertOrientation(.leftMirrored, forTransformOnly: [imirBox(axis: 0), irotBox(angle: 3)])
    }

    func testMirrorAxis1ThenRotate3ReportsRightMirrored() throws {
        // Applied in ipma order: imir axis 1, then irot angle 3 → EXIF 7 (ImageIO-verified).
        // Also exercises the 15-bit (large) property-index association form.
        try assertOrientation(
            .rightMirrored,
            forTransformOnly: [imirBox(axis: 1), irotBox(angle: 3)],
            largeIndexForm: true
        )
    }

    // MARK: - Precedence against the Exif Orientation tag

    func testTransformWinsOverConflictingExifOrientation() throws {
        // Primary item has irot angle 3 (→ right / 6) and an Exif Orientation of 1.
        // The transform decides; the Exif tag is ignored. Identity fields survive.
        let fixture = heifFixture(
            majorBrand: "heic",
            properties: [irotBox(angle: 3)],
            primaryAssociations: [1],
            exif: ExifImage(orientation: 1, make: "ACME")
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "heic"))

        XCTAssertEqual(result.format.family, .heif)
        XCTAssertEqual(result.geometry?.orientation, .right)
        XCTAssertEqual(result.camera?.make, "ACME")
    }

    func testExifOrientationKeptWhenNoTransformProperty() throws {
        // No irot/imir on the primary item: today's Exif behaviour is preserved,
        // including iPhone HEICs that carry Orientation 6 in Exif.
        let fixture = heifFixture(
            majorBrand: "heic",
            properties: [ispeBox(width: 4032, height: 3024)],
            primaryAssociations: [1],
            exif: ExifImage(orientation: 6, make: "Apple")
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "heic"))

        XCTAssertEqual(result.geometry?.orientation, .right)
        XCTAssertEqual(result.camera?.make, "Apple")
    }

    // MARK: - Scoping and robustness

    func testTransformOnNonPrimaryItemIsIgnored() throws {
        // Primary item 1 carries only an ispe; the irot is associated with item 2.
        // A transform on a non-primary item must not set the orientation.
        let fixture = heifFixture(
            majorBrand: "heic",
            primaryItemID: 1,
            properties: [ispeBox(width: 100, height: 100), irotBox(angle: 1)],
            associations: [(1, [1]), (2, [2])],
            exif: nil
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "heic"))

        XCTAssertEqual(result.format.family, .heif)
        XCTAssertNil(result.geometry?.orientation)
    }

    func testTruncatedIrotBoxProducesNoOrientationAndNoCrash() throws {
        // An irot box whose declared size (9) overruns its ipco container, with the
        // payload byte missing. The box is dropped; no orientation, no crash.
        var truncatedIrot = bigEndianUInt32(9)
        truncatedIrot.append(Data("irot".utf8))
        let fixture = heifFixture(
            majorBrand: "heic",
            properties: [truncatedIrot],
            primaryAssociations: [1],
            exif: nil
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "heic"))

        XCTAssertEqual(result.outcome, .parsed)
        XCTAssertNil(result.geometry?.orientation)
    }

    // MARK: - AVIF uses the same container

    func testAVIFIrotIsRead() throws {
        // AVIF reuses the ISO BMFF meta/iprp machinery, so the same code path applies.
        let fixture = heifFixture(
            majorBrand: "avif",
            properties: [irotBox(angle: 1)],
            primaryAssociations: [1],
            exif: nil
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "avif"))

        XCTAssertEqual(result.format.brand, "avif")
        XCTAssertEqual(result.geometry?.orientation, .left)
    }

    // MARK: - Stored dimensions from ispe

    func testPrimaryIspeProvidesStoredDimensionsWithoutExif() throws {
        // A HEIF with no embedded Exif still has stored dimensions in the primary ispe.
        let fixture = heifFixture(
            majorBrand: "heic",
            properties: [ispeBox(width: 6192, height: 4128)],
            primaryAssociations: [1],
            exif: nil
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "heic"))

        XCTAssertEqual(result.geometry?.pixelWidth, 6192)
        XCTAssertEqual(result.geometry?.pixelHeight, 4128)
    }

    func testAVIFIspeProvidesStoredDimensions() throws {
        let fixture = heifFixture(
            majorBrand: "avif",
            properties: [ispeBox(width: 1920, height: 1080)],
            primaryAssociations: [1],
            exif: nil
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "avif"))

        XCTAssertEqual(result.geometry?.pixelWidth, 1920)
        XCTAssertEqual(result.geometry?.pixelHeight, 1080)
    }

    func testIspeOnNonPrimaryItemIsIgnored() throws {
        // ispe at property index 1 is associated only with item 2; the primary (item 1)
        // has no properties, so no stored dimensions are reported.
        let fixture = heifFixture(
            majorBrand: "heic",
            primaryItemID: 1,
            properties: [ispeBox(width: 640, height: 480)],
            associations: [(1, []), (2, [1])],
            exif: nil
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "heic"))

        XCTAssertNil(result.geometry?.pixelWidth)
        XCTAssertNil(result.geometry?.pixelHeight)
    }

    func testRotatedHeifWithoutExifHasOrientationAndStoredDimensions() throws {
        // The Sony ILCE-6700 shape: irot but no Exif Orientation. Orientation comes from
        // the transform; dimensions come from ispe, kept as stored (unrotated).
        let fixture = heifFixture(
            majorBrand: "heic",
            properties: [ispeBox(width: 6192, height: 4128), irotBox(angle: 3)],
            primaryAssociations: [1, 2],
            exif: nil
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "heic"))

        XCTAssertEqual(result.geometry?.orientation, .right)
        XCTAssertEqual(result.geometry?.pixelWidth, 6192)
        XCTAssertEqual(result.geometry?.pixelHeight, 4128)
    }

    func testExifPixelDimensionsPreferredOverIspe() throws {
        // When both are present the Exif PixelXDimension wins, so files with embedded Exif
        // are unchanged; ispe only fills the gap when Exif carries no dimensions.
        let fixture = heifFixture(
            majorBrand: "heic",
            properties: [ispeBox(width: 100, height: 200)],
            primaryAssociations: [1],
            exif: ExifImage(orientation: 1, make: "ACME", pixelDimensions: (4032, 3024))
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "heic"))

        XCTAssertEqual(result.geometry?.pixelWidth, 4032)
        XCTAssertEqual(result.geometry?.pixelHeight, 3024)
    }

    // MARK: - Fixture assembly

    /// Asserts the orientation for a primary item that carries exactly the given
    /// transform property boxes (associated in the order listed), with no Exif.
    private func assertOrientation(
        _ expected: Orientation,
        forTransformOnly properties: [Data],
        largeIndexForm: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = heifFixture(
            majorBrand: "heic",
            properties: properties,
            primaryAssociations: Array(1...properties.count),
            exif: nil,
            largeIndexForm: largeIndexForm
        )
        let result = MediaMetadataReader.read(url: try write(fixture, extension: "heic"))
        XCTAssertEqual(result.geometry?.orientation, expected, file: file, line: line)
    }

    private struct ExifImage {
        let orientation: UInt16
        let make: String
        var pixelDimensions: (width: UInt32, height: UInt32)? = nil
    }

    /// Builds a minimal HEIF/AVIF file: `ftyp`, then `meta` holding `pitm`, the property
    /// container (`iprp`/`ipco`/`ipma`), and — when `exif` is set — an Exif item whose
    /// `iloc` points at a TIFF payload appended after `meta`.
    private func heifFixture(
        majorBrand: String,
        primaryItemID: UInt16 = 1,
        properties: [Data],
        primaryAssociations: [Int]? = nil,
        associations: [(item: UInt16, indices: [Int])]? = nil,
        exif: ExifImage?,
        largeIndexForm: Bool = false
    ) -> Data {
        let exifItemID: UInt16 = 2
        let resolvedAssociations = associations
            ?? [(primaryItemID, primaryAssociations ?? [])]
        let ipco = box("ipco", payload: properties.reduce(Data(), +))
        let ipma = ipmaBox(entries: resolvedAssociations, largeIndexForm: largeIndexForm)
        let iprp = box("iprp", payload: ipco + ipma)

        let ftyp = ftypBox(majorBrand: majorBrand)
        let exifPayload = exif.map {
            exifItemPayload(orientation: $0.orientation, make: $0.make, pixelDimensions: $0.pixelDimensions)
        }

        func assembleMeta(exifBaseOffset: UInt64) -> Data {
            var children = [pitmBox(itemID: primaryItemID)]
            if exifPayload != nil {
                children.append(iinfBox(exifItemID: exifItemID))
                children.append(
                    ilocBox(
                        itemID: exifItemID,
                        baseOffset: exifBaseOffset,
                        extentOffset: 0,
                        extentLength: UInt64(exifPayload!.count)
                    )
                )
            }
            children.append(iprp)
            return metaBox(children: children)
        }

        guard let exifPayload else {
            return ftyp + assembleMeta(exifBaseOffset: 0)
        }
        // The Exif payload lives inside an `mdat` box (raw trailing bytes would break the
        // top-level box chain). The base-offset field is fixed-width, so meta's size does
        // not depend on its value: measure once, then point the extent into the mdat.
        let mdat = box("mdat", payload: exifPayload)
        let metaSize = assembleMeta(exifBaseOffset: 0).count
        let exifOffset = UInt64(ftyp.count + metaSize + 8)
        return ftyp + assembleMeta(exifBaseOffset: exifOffset) + mdat
    }

    private func ftypBox(majorBrand: String) -> Data {
        var payload = Data(majorBrand.utf8)
        payload.append(bigEndianUInt32(0))
        payload.append(Data(majorBrand.utf8))
        return box("ftyp", payload: payload)
    }

    private func metaBox(children: [Data]) -> Data {
        var payload = Data([0, 0, 0, 0])
        children.forEach { payload.append($0) }
        return box("meta", payload: payload)
    }

    private func pitmBox(itemID: UInt16) -> Data {
        var payload = Data([0, 0, 0, 0])
        payload.append(bigEndianUInt16(itemID))
        return box("pitm", payload: payload)
    }

    private func irotBox(angle: UInt8) -> Data {
        box("irot", payload: Data([angle & 0x03]))
    }

    private func imirBox(axis: UInt8) -> Data {
        box("imir", payload: Data([axis & 0x01]))
    }

    private func ispeBox(width: UInt32, height: UInt32) -> Data {
        var payload = Data([0, 0, 0, 0])
        payload.append(bigEndianUInt32(width))
        payload.append(bigEndianUInt32(height))
        return box("ispe", payload: payload)
    }

    private func ipmaBox(entries: [(item: UInt16, indices: [Int])], largeIndexForm: Bool) -> Data {
        var payload = Data([0, 0, 0, largeIndexForm ? 1 : 0])
        payload.append(bigEndianUInt32(UInt32(entries.count)))
        for entry in entries {
            payload.append(bigEndianUInt16(entry.item))
            payload.append(UInt8(entry.indices.count))
            for index in entry.indices {
                if largeIndexForm {
                    // Essential bit set in the high bit of the 15-bit index.
                    payload.append(bigEndianUInt16(0x8000 | UInt16(index)))
                } else {
                    payload.append(UInt8(0x80 | (index & 0x7F)))
                }
            }
        }
        return box("ipma", payload: payload)
    }

    private func iinfBox(exifItemID: UInt16) -> Data {
        var entryPayload = Data([2, 0, 0, 0])
        entryPayload.append(bigEndianUInt16(exifItemID))
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

    /// `Exif\0\0` prefix plus a little-endian TIFF carrying an Orientation tag and Make,
    /// and — when `pixelDimensions` is set — an Exif sub-IFD with PixelX/YDimension.
    private func exifItemPayload(
        orientation: UInt16,
        make: String,
        pixelDimensions: (width: UInt32, height: UInt32)? = nil
    ) -> Data {
        let makeBytes = Data((make + "\u{0}").utf8)
        let hasDimensions = pixelDimensions != nil
        // Offsets are computed in Int (concrete type) to keep the Linux 6.0 type-checker
        // fast. ifd0 holds Make + Orientation, plus an Exif-IFD pointer when dimensions
        // are present; the Exif sub-IFD (2 entries) then precedes the Make string.
        let ifd0EntryCount: Int = hasDimensions ? 3 : 2
        let afterIFD0: Int = 8 + 2 + 12 * ifd0EntryCount + 4
        let exifIFDSize: Int = 2 + 12 * 2 + 4
        let makeOffset: Int = hasDimensions ? afterIFD0 + exifIFDSize : afterIFD0

        var tiff = Data("II".utf8)
        tiff.append(littleEndianUInt16(42))
        tiff.append(littleEndianUInt32(8))
        tiff.append(littleEndianUInt16(UInt16(ifd0EntryCount)))
        tiff.append(tiffEntry(tag: 0x010F, type: 2, count: UInt32(makeBytes.count), value: UInt32(makeOffset)))
        tiff.append(tiffEntry(tag: 0x0112, type: 3, count: 1, value: UInt32(orientation)))
        if hasDimensions {
            tiff.append(tiffEntry(tag: 0x8769, type: 4, count: 1, value: UInt32(afterIFD0)))
        }
        tiff.append(littleEndianUInt32(0))
        if let dimensions = pixelDimensions {
            tiff.append(littleEndianUInt16(2))
            tiff.append(tiffEntry(tag: 0xA002, type: 4, count: 1, value: dimensions.width))
            tiff.append(tiffEntry(tag: 0xA003, type: 4, count: 1, value: dimensions.height))
            tiff.append(littleEndianUInt32(0))
        }
        tiff.append(makeBytes)

        var payload = Data("Exif".utf8)
        payload.append(contentsOf: [0, 0])
        payload.append(tiff)
        return payload
    }

    private func tiffEntry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        var data = littleEndianUInt16(tag)
        data.append(littleEndianUInt16(type))
        data.append(littleEndianUInt32(count))
        data.append(littleEndianUInt32(value))
        return data
    }

    private func box(_ type: String, payload: Data) -> Data {
        var data = bigEndianUInt32(UInt32(8 + payload.count))
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    private func write(_ data: Data, extension fileExtension: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try data.write(to: url, options: .atomic)
        return url
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
        Data((0..<8).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) })
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
}
