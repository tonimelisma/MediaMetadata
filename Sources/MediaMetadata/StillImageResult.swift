import Foundation

/// Assembles the result of a still-image container whose own header states the raster
/// size and whose Exif, when it has any, is an embedded TIFF structure — PNG `eXIf`,
/// WebP `EXIF`. GIF uses it for the size alone.
///
/// The container's header is the size source, not Exif `PixelXDimension`/`PixelYDimension`:
/// the header describes the raster actually stored, while Exif dimensions are carried over
/// from whatever the file was made from and go stale when it is resized or cropped. Exif
/// still supplies everything a header cannot — orientation, dates, device, GPS.
struct StillImageResult {
    struct Size: Equatable {
        let width: Int
        let height: Int
    }

    let family: FormatIdentity.Family
    let fileExtension: String
    let parser: String
    private(set) var findings: [MetadataFinding] = []
    private(set) var diagnostics: [MetadataDiagnostic] = []
    /// The stored raster size from the container's header, once read.
    var size: Size?
    /// The embedded Exif TIFF, parsed at its absolute offset.
    private var embedded: ParsedMetadata?

    init(family: FormatIdentity.Family, fileExtension: String, parser: String) {
        self.family = family
        self.fileExtension = fileExtension
        self.parser = parser
    }

    var hasEmbeddedExif: Bool {
        embedded != nil
    }

    mutating func appendFinding(namespace: String, key: String, value: String, sourcePath: String, byteRange: Range<UInt64>?) {
        findings.append(
            MetadataFinding(
                id: findings.count,
                namespace: namespace,
                key: key,
                rawValue: value,
                parser: parser,
                sourcePath: sourcePath,
                byteRange: byteRange
            )
        )
    }

    mutating func appendDiagnostic(severity: MetadataDiagnostic.Severity = .warning, code: String, message: String, byteRange: Range<UInt64>?) {
        diagnostics.append(
            MetadataDiagnostic(severity: severity, code: code, message: message, parser: parser, byteRange: byteRange)
        )
    }

    /// Parses the Exif payload of a chunk that spans `payload`, which holds a TIFF header
    /// either directly (as the PNG and WebP specifications say) or after the `Exif\0\0`
    /// prefix some writers copy over from JPEG. Returns `false` when neither is there.
    mutating func parseEmbeddedExif(source: MediaByteSource, payload: Range<UInt64>) -> Bool {
        guard let tiffOffset = Self.exifTIFFOffset(source: source, payload: payload) else {
            return false
        }
        var tiff = TIFFMetadataParser(source: source, fileExtension: fileExtension, baseOffset: tiffOffset, family: family)
        embedded = tiff.parse()
        return true
    }

    private static func exifTIFFOffset(source: MediaByteSource, payload: Range<UInt64>) -> UInt64? {
        let probeLength = Int(min(payload.upperBound - payload.lowerBound, 10))
        guard probeLength >= 4,
              let probe = try? source.data(offset: payload.lowerBound, length: probeLength),
              probe.count == probeLength else {
            return nil
        }
        let bytes = Array(probe)
        if isTIFFHeader(bytes[0..<4]) {
            return payload.lowerBound
        }
        if bytes.count >= 10,
           bytes[0..<6].elementsEqual([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]),
           isTIFFHeader(bytes[6..<10]) {
            return payload.lowerBound + 6
        }
        return nil
    }

    private static func isTIFFHeader(_ bytes: ArraySlice<UInt8>) -> Bool {
        bytes.elementsEqual([0x49, 0x49, 0x2A, 0x00]) || bytes.elementsEqual([0x4D, 0x4D, 0x00, 0x2A])
    }

    /// The parsed result: this container's findings first, then the embedded TIFF's,
    /// renumbered so every evidence ID still points at its own finding.
    func build() -> ParsedMetadata {
        let idOffset = findings.count
        let tiff = embedded
        let tiffFindings = (tiff?.findings ?? []).map { finding in
            MetadataFinding(
                id: idOffset + finding.id,
                namespace: finding.namespace,
                key: finding.key,
                rawValue: finding.rawValue,
                parser: finding.parser,
                sourcePath: finding.sourcePath,
                byteRange: finding.byteRange
            )
        }
        let timestamps = (tiff?.timestamps ?? []).map { timestamp in
            CaptureTimestampCandidate(
                role: timestamp.role,
                rawTimestamp: timestamp.rawTimestamp,
                dateComponents: timestamp.dateComponents,
                instant: timestamp.instant,
                offsetSeconds: timestamp.offsetSeconds,
                authority: timestamp.authority,
                evidenceIDs: timestamp.evidenceIDs.map { idOffset + $0 }
            )
        }
        let locations = (tiff?.locations ?? []).map { location in
            CaptureLocationCandidate(
                latitude: location.latitude,
                longitude: location.longitude,
                altitudeMeters: location.altitudeMeters,
                rawValue: location.rawValue,
                source: location.source,
                origin: location.origin,
                evidenceIDs: location.evidenceIDs.map { idOffset + $0 }
            )
        }
        return ParsedMetadata(
            identity: FormatIdentity(family: family, observedExtension: fileExtension, detectedByMagic: true),
            findings: findings + tiffFindings,
            timestamps: timestamps,
            locations: locations,
            camera: camera(exif: tiff?.camera),
            diagnostics: diagnostics + (tiff?.diagnostics ?? []),
            provenance: [ParserProvenance(parser: parser, status: .parsed)],
            previews: tiff?.previews ?? []
        )
    }

    private func camera(exif: CameraMetadata?) -> CameraMetadata? {
        let exifSize = exif.flatMap { exif in
            exif.pixelWidth.flatMap { width in exif.pixelHeight.map { Size(width: width, height: $0) } }
        }
        let resolvedSize = size ?? exifSize
        guard exif != nil || resolvedSize != nil else {
            return nil
        }
        return CameraMetadata(
            make: exif?.make,
            model: exif?.model,
            lensModel: exif?.lensModel,
            serialNumber: exif?.serialNumber,
            orientation: exif?.orientation,
            pixelWidth: resolvedSize?.width,
            pixelHeight: resolvedSize?.height
        )
    }
}
