import Foundation

private let parserName = "MediaMetadata.TIFFMetadataParser"

struct TIFFMetadataParser {
    private enum ByteOrder {
        case littleEndian
        case bigEndian

        func uint16(_ data: Data, offset: Int = 0) -> UInt16? {
            guard offset >= 0, offset + 1 < data.count else {
                return nil
            }
            switch self {
            case .littleEndian:
                return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            case .bigEndian:
                return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
            }
        }

        func uint32(_ data: Data, offset: Int = 0) -> UInt32? {
            guard offset >= 0, offset + 3 < data.count else {
                return nil
            }
            switch self {
            case .littleEndian:
                return UInt32(data[offset])
                    | (UInt32(data[offset + 1]) << 8)
                    | (UInt32(data[offset + 2]) << 16)
                    | (UInt32(data[offset + 3]) << 24)
            case .bigEndian:
                return (UInt32(data[offset]) << 24)
                    | (UInt32(data[offset + 1]) << 16)
                    | (UInt32(data[offset + 2]) << 8)
                    | UInt32(data[offset + 3])
            }
        }
    }

    private struct IFDEntry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let valueOrOffset: UInt32
        let valueField: Data
        let valueFieldOffset: UInt64
    }

    private struct RawField {
        let value: String
        let findingID: Int
    }

    private struct ASCIIValue {
        let value: String
        let byteRange: Range<UInt64>?
    }

    private struct NumericValue {
        let value: UInt64
        let byteRange: Range<UInt64>?
    }

    private struct NumericField {
        let value: UInt64
        let findingID: Int
    }

    private struct RationalValues {
        let values: [Double]
        let byteRange: Range<UInt64>?
    }

    private struct RationalField {
        let values: [Double]
        let rawValue: String
        let findingID: Int
    }

    private enum TIFFType {
        static let byte: UInt16 = 1
        static let ascii: UInt16 = 2
        static let short: UInt16 = 3
        static let long: UInt16 = 4
        static let rational: UInt16 = 5
    }

    private enum Tag {
        static let make: UInt16 = 0x010F
        static let model: UInt16 = 0x0110
        static let orientation: UInt16 = 0x0112
        static let tiffDateTime: UInt16 = 0x0132
        static let exifIFDPointer: UInt16 = 0x8769
        static let gpsIFDPointer: UInt16 = 0x8825
        static let dateTimeOriginal: UInt16 = 0x9003
        static let dateTimeDigitized: UInt16 = 0x9004
        static let offsetTime: UInt16 = 0x9010
        static let offsetTimeOriginal: UInt16 = 0x9011
        static let offsetTimeDigitized: UInt16 = 0x9012
        static let pixelWidth: UInt16 = 0xA002
        static let pixelHeight: UInt16 = 0xA003
        static let bodySerialNumber: UInt16 = 0xA431
        static let lensModel: UInt16 = 0xA434
    }

    private enum GPSTag {
        static let latitudeRef: UInt16 = 0x0001
        static let latitude: UInt16 = 0x0002
        static let longitudeRef: UInt16 = 0x0003
        static let longitude: UInt16 = 0x0004
        static let altitudeRef: UInt16 = 0x0005
        static let altitude: UInt16 = 0x0006
        static let timeStamp: UInt16 = 0x0007
        static let dateStamp: UInt16 = 0x001D
    }

    private let source: FileByteSource
    private let url: URL
    private let baseOffset: UInt64
    private let family: FormatIdentity.Family
    private var diagnostics: [MetadataDiagnostic] = []
    private var findings: [MetadataFinding] = []

    init(source: FileByteSource, url: URL, baseOffset: UInt64 = 0, family: FormatIdentity.Family = .tiff) {
        self.source = source
        self.url = url
        self.baseOffset = baseOffset
        self.family = family
    }

    mutating func parse() -> ParsedMetadata {
        let identity = FormatIdentity(
            family: family,
            observedExtension: url.pathExtension.lowercased(),
            detectedByMagic: true
        )

        guard let header = data(relativeOffset: 0, length: 8),
              header.count == 8 else {
            return unsupportedResult(code: "truncatedHeader", message: "The file is too short to contain a TIFF header.")
        }

        let byteOrder: ByteOrder
        switch (header[0], header[1]) {
        case (0x49, 0x49):
            byteOrder = .littleEndian
        case (0x4D, 0x4D):
            byteOrder = .bigEndian
        default:
            return unsupportedResult(code: "unsupportedFormat", message: "The file does not start with a TIFF byte-order marker.")
        }

        guard byteOrder.uint16(header, offset: 2) == 42,
              let ifd0Offset = byteOrder.uint32(header, offset: 4) else {
            return unsupportedResult(code: "invalidTIFFHeader", message: "The file does not contain a valid TIFF header.")
        }

        guard let ifd0 = parseIFD(offset: UInt64(ifd0Offset), byteOrder: byteOrder, path: "tiff.ifd0") else {
            return ParsedMetadata(identity: identity, findings: findings, timestamps: [], diagnostics: diagnostics)
        }

        var tiffDateTime: RawField?
        if let entry = ifd0[Tag.tiffDateTime],
           let ascii = asciiValue(from: entry) {
            tiffDateTime = appendFinding(
                namespace: "tiff",
                key: "DateTime",
                value: ascii.value,
                sourcePath: "tiff.ifd0.DateTime",
                byteRange: ascii.byteRange
            )
        }

        var exif: [UInt16: IFDEntry]?
        var dateTimeOriginal: RawField?
        var dateTimeDigitized: RawField?
        var offsetTime: RawField?
        var offsetTimeOriginal: RawField?
        var offsetTimeDigitized: RawField?

        if let exifPointerEntry = ifd0[Tag.exifIFDPointer],
           let exifOffset = longValue(from: exifPointerEntry),
           let parsedEXIF = parseIFD(offset: UInt64(exifOffset), byteOrder: byteOrder, path: "tiff.ifd0.exif") {
            exif = parsedEXIF
            if let entry = parsedEXIF[Tag.dateTimeOriginal],
               let ascii = asciiValue(from: entry) {
                dateTimeOriginal = appendFinding(
                    namespace: "exif",
                    key: "DateTimeOriginal",
                    value: ascii.value,
                    sourcePath: "tiff.ifd0.exif.DateTimeOriginal",
                    byteRange: ascii.byteRange
                )
            }
            if let entry = parsedEXIF[Tag.dateTimeDigitized],
               let ascii = asciiValue(from: entry) {
                dateTimeDigitized = appendFinding(
                    namespace: "exif",
                    key: "DateTimeDigitized",
                    value: ascii.value,
                    sourcePath: "tiff.ifd0.exif.DateTimeDigitized",
                    byteRange: ascii.byteRange
                )
            }
            if let entry = parsedEXIF[Tag.offsetTime],
               let ascii = asciiValue(from: entry) {
                offsetTime = appendFinding(
                    namespace: "exif",
                    key: "OffsetTime",
                    value: ascii.value,
                    sourcePath: "tiff.ifd0.exif.OffsetTime",
                    byteRange: ascii.byteRange
                )
            }
            if let entry = parsedEXIF[Tag.offsetTimeOriginal],
               let ascii = asciiValue(from: entry) {
                offsetTimeOriginal = appendFinding(
                    namespace: "exif",
                    key: "OffsetTimeOriginal",
                    value: ascii.value,
                    sourcePath: "tiff.ifd0.exif.OffsetTimeOriginal",
                    byteRange: ascii.byteRange
                )
            }
            if let entry = parsedEXIF[Tag.offsetTimeDigitized],
               let ascii = asciiValue(from: entry) {
                offsetTimeDigitized = appendFinding(
                    namespace: "exif",
                    key: "OffsetTimeDigitized",
                    value: ascii.value,
                    sourcePath: "tiff.ifd0.exif.OffsetTimeDigitized",
                    byteRange: ascii.byteRange
                )
            }
        }

        let timestamps = [
            timestampCandidate(role: .original, timestamp: dateTimeOriginal, offset: offsetTimeOriginal ?? offsetTime),
            timestampCandidate(role: .digitized, timestamp: dateTimeDigitized, offset: offsetTimeDigitized ?? offsetTime),
            timestampCandidate(role: .tiff, timestamp: tiffDateTime, offset: offsetTime),
        ].compactMap { $0 }

        let camera = parseCameraMetadata(ifd0: ifd0, exif: exif, byteOrder: byteOrder)
        let gps = parseGPSMetadata(ifd0: ifd0, byteOrder: byteOrder)

        return ParsedMetadata(
            identity: identity,
            findings: findings,
            timestamps: timestamps + [gps.timestamp].compactMap { $0 },
            locations: [gps.location].compactMap { $0 },
            camera: camera,
            diagnostics: diagnostics,
            provenance: [ParserProvenance(parser: parserName, status: .parsed)]
        )
    }

    private mutating func parseCameraMetadata(
        ifd0: [UInt16: IFDEntry],
        exif: [UInt16: IFDEntry]?,
        byteOrder: ByteOrder
    ) -> CameraMetadata? {
        let make = appendASCIIField(ifd0[Tag.make], namespace: "tiff", key: "Make", path: "tiff.ifd0.Make")
        let model = appendASCIIField(ifd0[Tag.model], namespace: "tiff", key: "Model", path: "tiff.ifd0.Model")
        let orientation = appendNumericField(
            ifd0[Tag.orientation],
            byteOrder: byteOrder,
            namespace: "tiff",
            key: "Orientation",
            path: "tiff.ifd0.Orientation"
        )
        let lensModel = appendASCIIField(exif?[Tag.lensModel], namespace: "exif", key: "LensModel", path: "tiff.ifd0.exif.LensModel")
        let serialNumber = appendASCIIField(
            exif?[Tag.bodySerialNumber],
            namespace: "exif",
            key: "BodySerialNumber",
            path: "tiff.ifd0.exif.BodySerialNumber"
        )
        let pixelWidth = appendNumericField(
            exif?[Tag.pixelWidth],
            byteOrder: byteOrder,
            namespace: "exif",
            key: "PixelXDimension",
            path: "tiff.ifd0.exif.PixelXDimension"
        )
        let pixelHeight = appendNumericField(
            exif?[Tag.pixelHeight],
            byteOrder: byteOrder,
            namespace: "exif",
            key: "PixelYDimension",
            path: "tiff.ifd0.exif.PixelYDimension"
        )

        guard make != nil || model != nil || lensModel != nil || serialNumber != nil
            || orientation != nil || pixelWidth != nil || pixelHeight != nil else {
            return nil
        }
        return CameraMetadata(
            make: make?.value,
            model: model?.value,
            lensModel: lensModel?.value,
            serialNumber: serialNumber?.value,
            orientation: orientation.flatMap { Int(exactly: $0.value) },
            pixelWidth: pixelWidth.flatMap { Int(exactly: $0.value) },
            pixelHeight: pixelHeight.flatMap { Int(exactly: $0.value) }
        )
    }

    private mutating func parseGPSMetadata(
        ifd0: [UInt16: IFDEntry],
        byteOrder: ByteOrder
    ) -> (location: CaptureLocationCandidate?, timestamp: CaptureTimestampCandidate?) {
        guard let pointer = ifd0[Tag.gpsIFDPointer],
              let offset = longValue(from: pointer),
              let gps = parseIFD(offset: UInt64(offset), byteOrder: byteOrder, path: "tiff.ifd0.gps") else {
            return (nil, nil)
        }

        let latitudeRef = appendASCIIField(gps[GPSTag.latitudeRef], namespace: "gps", key: "GPSLatitudeRef", path: "tiff.ifd0.gps.GPSLatitudeRef")
        let latitude = appendRationalField(gps[GPSTag.latitude], byteOrder: byteOrder, key: "GPSLatitude")
        let longitudeRef = appendASCIIField(gps[GPSTag.longitudeRef], namespace: "gps", key: "GPSLongitudeRef", path: "tiff.ifd0.gps.GPSLongitudeRef")
        let longitude = appendRationalField(gps[GPSTag.longitude], byteOrder: byteOrder, key: "GPSLongitude")
        let altitudeRef = appendNumericField(gps[GPSTag.altitudeRef], byteOrder: byteOrder, namespace: "gps", key: "GPSAltitudeRef", path: "tiff.ifd0.gps.GPSAltitudeRef")
        let altitude = appendRationalField(gps[GPSTag.altitude], byteOrder: byteOrder, key: "GPSAltitude")
        let dateStamp = appendASCIIField(gps[GPSTag.dateStamp], namespace: "gps", key: "GPSDateStamp", path: "tiff.ifd0.gps.GPSDateStamp")
        let timeStamp = appendRationalField(gps[GPSTag.timeStamp], byteOrder: byteOrder, key: "GPSTimeStamp")

        let location = gpsLocation(
            latitudeRef: latitudeRef,
            latitude: latitude,
            longitudeRef: longitudeRef,
            longitude: longitude,
            altitudeRef: altitudeRef,
            altitude: altitude
        )
        return (location, gpsTimestamp(dateStamp: dateStamp, timeStamp: timeStamp))
    }

    private mutating func unsupportedResult(code: String, message: String) -> ParsedMetadata {
        diagnostics.append(
            MetadataDiagnostic(
                severity: .info,
                code: code,
                message: message,
                parser: parserName,
                byteRange: nil
            )
        )
        return ParsedMetadata(
            identity: FormatIdentity(
                family: .unknown,
                observedExtension: url.pathExtension.lowercased(),
                detectedByMagic: false
            ),
            findings: [],
            timestamps: [],
            diagnostics: diagnostics
        )
    }

    private mutating func parseIFD(offset: UInt64, byteOrder: ByteOrder, path: String) -> [UInt16: IFDEntry]? {
        guard let countData = data(relativeOffset: offset, length: 2),
              let entryCount = byteOrder.uint16(countData) else {
            appendDiagnostic(code: "truncatedIFD", message: "Could not read IFD entry count at \(path).", byteRange: absoluteRange(offset..<(offset + 2)))
            return nil
        }

        guard entryCount <= 4096 else {
            appendDiagnostic(code: "ifdEntryLimitExceeded", message: "IFD entry count at \(path) exceeds the safety limit.", byteRange: absoluteRange(offset..<(offset + 2)))
            return nil
        }

        let entriesByteCount = Int(entryCount) * 12
        let entriesData: Data
        if entriesByteCount == 0 {
            entriesData = Data()
        } else if let data = data(relativeOffset: offset + 2, length: entriesByteCount),
                  data.count == entriesByteCount {
            entriesData = data
        } else {
            appendDiagnostic(
                code: "truncatedIFDEntry",
                message: "Could not read IFD entries at \(path).",
                byteRange: absoluteRange((offset + 2)..<(offset + 2 + UInt64(entriesByteCount)))
            )
            return nil
        }

        var entries: [UInt16: IFDEntry] = [:]
        for index in 0..<Int(entryCount) {
            let entryOffsetInTable = index * 12
            let entryOffset = offset + 2 + UInt64(entryOffsetInTable)
            let entryData = entriesData.subdata(in: entryOffsetInTable..<(entryOffsetInTable + 12))
            guard
                  let tag = byteOrder.uint16(entryData, offset: 0),
                  let type = byteOrder.uint16(entryData, offset: 2),
                  let count = byteOrder.uint32(entryData, offset: 4),
                  let valueOrOffset = byteOrder.uint32(entryData, offset: 8) else {
                appendDiagnostic(code: "truncatedIFDEntry", message: "Could not parse IFD entry \(index) at \(path).", byteRange: absoluteRange(entryOffset..<(entryOffset + 12)))
                return nil
            }

            entries[tag] = IFDEntry(
                tag: tag,
                type: type,
                count: count,
                valueOrOffset: valueOrOffset,
                valueField: entryData.subdata(in: 8..<12),
                valueFieldOffset: baseOffset + entryOffset + 8
            )
        }
        return entries
    }

    private func asciiValue(from entry: IFDEntry) -> ASCIIValue? {
        guard entry.type == TIFFType.ascii,
              entry.count > 0,
              entry.count <= 4096 else {
            return nil
        }

        let byteCount = Int(entry.count)
        let bytes: Data?
        let byteRange: Range<UInt64>?
        if byteCount <= 4 {
            bytes = entry.valueField.subdata(in: 0..<byteCount)
            byteRange = entry.valueFieldOffset..<(entry.valueFieldOffset + UInt64(byteCount))
        } else {
            let offset = UInt64(entry.valueOrOffset)
            bytes = data(relativeOffset: offset, length: byteCount)
            byteRange = absoluteRange(offset..<(offset + UInt64(byteCount)))
        }

        guard let bytes else {
            return nil
        }

        let trimmedBytes = bytes.prefix { $0 != 0 }
        guard let value = String(data: Data(trimmedBytes), encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            return nil
        }
        return ASCIIValue(value: value, byteRange: byteRange)
    }

    private func numericValue(from entry: IFDEntry, byteOrder: ByteOrder) -> NumericValue? {
        switch (entry.type, entry.count) {
        case (TIFFType.byte, 1):
            return NumericValue(
                value: UInt64(entry.valueField[0]),
                byteRange: entry.valueFieldOffset..<(entry.valueFieldOffset + 1)
            )
        case (TIFFType.short, 1):
            guard let value = byteOrder.uint16(entry.valueField) else {
                return nil
            }
            return NumericValue(
                value: UInt64(value),
                byteRange: entry.valueFieldOffset..<(entry.valueFieldOffset + 2)
            )
        case (TIFFType.long, 1):
            return NumericValue(
                value: UInt64(entry.valueOrOffset),
                byteRange: entry.valueFieldOffset..<(entry.valueFieldOffset + 4)
            )
        default:
            return nil
        }
    }

    private func rationalValues(from entry: IFDEntry, byteOrder: ByteOrder) -> RationalValues? {
        guard entry.type == TIFFType.rational,
              entry.count > 0,
              entry.count <= 16 else {
            return nil
        }
        let byteCount = Int(entry.count) * 8
        let offset = UInt64(entry.valueOrOffset)
        guard let bytes = data(relativeOffset: offset, length: byteCount),
              bytes.count == byteCount else {
            return nil
        }

        var values: [Double] = []
        values.reserveCapacity(Int(entry.count))
        for index in 0..<Int(entry.count) {
            let valueOffset = index * 8
            guard let numerator = byteOrder.uint32(bytes, offset: valueOffset),
                  let denominator = byteOrder.uint32(bytes, offset: valueOffset + 4),
                  denominator != 0 else {
                return nil
            }
            values.append(Double(numerator) / Double(denominator))
        }
        return RationalValues(
            values: values,
            byteRange: absoluteRange(offset..<(offset + UInt64(byteCount)))
        )
    }

    private func longValue(from entry: IFDEntry) -> UInt32? {
        guard entry.type == TIFFType.long,
              entry.count == 1 else {
            return nil
        }
        return entry.valueOrOffset
    }

    private mutating func appendASCIIField(
        _ entry: IFDEntry?,
        namespace: String,
        key: String,
        path: String
    ) -> RawField? {
        guard let entry,
              let ascii = asciiValue(from: entry) else {
            return nil
        }
        return appendFinding(namespace: namespace, key: key, value: ascii.value, sourcePath: path, byteRange: ascii.byteRange)
    }

    private mutating func appendNumericField(
        _ entry: IFDEntry?,
        byteOrder: ByteOrder,
        namespace: String,
        key: String,
        path: String
    ) -> NumericField? {
        guard let entry,
              let numeric = numericValue(from: entry, byteOrder: byteOrder) else {
            return nil
        }
        let finding = appendFinding(
            namespace: namespace,
            key: key,
            value: String(numeric.value),
            sourcePath: path,
            byteRange: numeric.byteRange
        )
        return NumericField(value: numeric.value, findingID: finding.findingID)
    }

    private mutating func appendRationalField(
        _ entry: IFDEntry?,
        byteOrder: ByteOrder,
        key: String
    ) -> RationalField? {
        guard let entry,
              let rationals = rationalValues(from: entry, byteOrder: byteOrder) else {
            return nil
        }
        let rawValue = rationals.values.map(Self.decimalString).joined(separator: " ")
        let finding = appendFinding(
            namespace: "gps",
            key: key,
            value: rawValue,
            sourcePath: "tiff.ifd0.gps.\(key)",
            byteRange: rationals.byteRange
        )
        return RationalField(values: rationals.values, rawValue: rawValue, findingID: finding.findingID)
    }

    private func gpsLocation(
        latitudeRef: RawField?,
        latitude: RationalField?,
        longitudeRef: RawField?,
        longitude: RationalField?,
        altitudeRef: NumericField?,
        altitude: RationalField?
    ) -> CaptureLocationCandidate? {
        guard let latitudeRef,
              let latitude,
              latitude.values.count == 3,
              let longitudeRef,
              let longitude,
              longitude.values.count == 3 else {
            return nil
        }
        let latitudeDirection = latitudeRef.value.uppercased()
        let longitudeDirection = longitudeRef.value.uppercased()
        guard ["N", "S"].contains(latitudeDirection),
              ["E", "W"].contains(longitudeDirection) else {
            return nil
        }
        let latitudeSign = latitudeDirection == "S" ? -1.0 : 1.0
        let longitudeSign = longitudeDirection == "W" ? -1.0 : 1.0
        let parsedLatitude = latitudeSign * Self.decimalDegrees(latitude.values)
        let parsedLongitude = longitudeSign * Self.decimalDegrees(longitude.values)
        let parsedAltitude = altitude.flatMap { field -> Double? in
            guard field.values.count == 1 else {
                return nil
            }
            switch altitudeRef?.value {
            case nil, 0:
                return field.values[0]
            case 1:
                return -field.values[0]
            default:
                return nil
            }
        }

        var evidenceIDs = [latitudeRef.findingID, latitude.findingID, longitudeRef.findingID, longitude.findingID]
        if let altitudeRef {
            evidenceIDs.append(altitudeRef.findingID)
        }
        if let altitude {
            evidenceIDs.append(altitude.findingID)
        }
        let rawValue = "\(latitudeRef.value) \(latitude.rawValue) \(longitudeRef.value) \(longitude.rawValue)"
        return CaptureLocationCandidate(
            latitude: parsedLatitude,
            longitude: parsedLongitude,
            altitudeMeters: parsedAltitude,
            rawValue: rawValue,
            source: "tiff.gps",
            origin: .exifGPS,
            evidenceIDs: evidenceIDs
        )
    }

    private func gpsTimestamp(
        dateStamp: RawField?,
        timeStamp: RationalField?
    ) -> CaptureTimestampCandidate? {
        guard let dateStamp,
              let timeStamp,
              timeStamp.values.count == 3,
              let date = Self.gpsDate(dateStamp.value, time: timeStamp.values) else {
            return nil
        }
        let components = CaptureDateComponents.utcComponents(from: date)
        return CaptureTimestampCandidate(
            role: .gps,
            rawTimestamp: "\(dateStamp.value) \(timeStamp.rawValue)",
            dateComponents: components,
            instant: date,
            offsetSeconds: 0,
            authority: .absoluteInstant,
            evidenceIDs: [dateStamp.findingID, timeStamp.findingID]
        )
    }

    private static func decimalDegrees(_ values: [Double]) -> Double {
        values[0] + values[1] / 60.0 + values[2] / 3_600.0
    }

    private static func decimalString(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int64(value))
        }
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func gpsDate(_ dateStamp: String, time: [Double]) -> Date? {
        let dateParts = dateStamp.split(separator: ":").compactMap { Int($0) }
        guard dateParts.count == 3,
              time.count == 3,
              time[0] >= 0, time[0] < 24,
              time[1] >= 0, time[1] < 60,
              time[2] >= 0, time[2] < 60,
              time[0].rounded(.down) == time[0],
              time[1].rounded(.down) == time[1] else {
            return nil
        }
        let seconds = Int(time[2].rounded(.down))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let date = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: dateParts[0],
            month: dateParts[1],
            day: dateParts[2],
            hour: Int(time[0]),
            minute: Int(time[1]),
            second: seconds
        )) else {
            return nil
        }
        return date.addingTimeInterval(time[2] - Double(seconds))
    }

    private mutating func appendFinding(
        namespace: String,
        key: String,
        value: String,
        sourcePath: String,
        byteRange: Range<UInt64>?
    ) -> RawField {
        let findingID = findings.count
        findings.append(
            MetadataFinding(
                id: findingID,
                namespace: namespace,
                key: key,
                rawValue: value,
                parser: parserName,
                sourcePath: sourcePath,
                byteRange: byteRange
            )
        )
        return RawField(value: value, findingID: findingID)
    }

    private func timestampCandidate(
        role: CaptureTimestampCandidate.Role,
        timestamp: RawField?,
        offset: RawField?
    ) -> CaptureTimestampCandidate? {
        guard let timestamp,
              let components = CaptureDateComponents(exifTimestamp: timestamp.value) else {
            return nil
        }

        let offsetSeconds = offset.flatMap { Self.offsetSeconds(from: $0.value) }
        let instant = offsetSeconds.flatMap { components.date(offsetSeconds: $0) }
        var evidenceIDs = [timestamp.findingID]
        if let offset {
            evidenceIDs.append(offset.findingID)
        }

        return CaptureTimestampCandidate(
            role: role,
            rawTimestamp: timestamp.value,
            dateComponents: components,
            instant: instant,
            offsetSeconds: offsetSeconds,
            authority: offsetSeconds == nil ? .localWithoutOffset : .localWithOffset,
            evidenceIDs: evidenceIDs
        )
    }

    private mutating func appendDiagnostic(code: String, message: String, byteRange: Range<UInt64>?) {
        diagnostics.append(
            MetadataDiagnostic(
                severity: .warning,
                code: code,
                message: message,
                parser: parserName,
                byteRange: byteRange
            )
        )
    }

    private func data(relativeOffset: UInt64, length: Int) -> Data? {
        try? source.data(offset: baseOffset + relativeOffset, length: length)
    }

    private func absoluteRange(_ range: Range<UInt64>) -> Range<UInt64> {
        (baseOffset + range.lowerBound)..<(baseOffset + range.upperBound)
    }

    private static func offsetSeconds(from rawValue: String) -> Int? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased() == "Z" {
            return 0
        }

        guard trimmed.count == 6,
              let sign = trimmed.first,
              sign == "+" || sign == "-",
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)] == ":" else {
            return nil
        }

        let hourStart = trimmed.index(after: trimmed.startIndex)
        let hourEnd = trimmed.index(hourStart, offsetBy: 2)
        let minuteStart = trimmed.index(hourEnd, offsetBy: 1)
        guard let hours = Int(trimmed[hourStart..<hourEnd]),
              let minutes = Int(trimmed[minuteStart...]),
              hours <= 23,
              minutes <= 59 else {
            return nil
        }

        let totalSeconds = ((hours * 60) + minutes) * 60
        return sign == "-" ? -totalSeconds : totalSeconds
    }
}

private extension CaptureDateComponents {
    init?(exifTimestamp: String) {
        guard exifTimestamp.count == 19 else {
            return nil
        }

        let yearStart = exifTimestamp.startIndex
        let yearEnd = exifTimestamp.index(yearStart, offsetBy: 4)
        let monthStart = exifTimestamp.index(yearEnd, offsetBy: 1)
        let monthEnd = exifTimestamp.index(monthStart, offsetBy: 2)
        let dayStart = exifTimestamp.index(monthEnd, offsetBy: 1)
        let dayEnd = exifTimestamp.index(dayStart, offsetBy: 2)
        let hourStart = exifTimestamp.index(dayEnd, offsetBy: 1)
        let hourEnd = exifTimestamp.index(hourStart, offsetBy: 2)
        let minuteStart = exifTimestamp.index(hourEnd, offsetBy: 1)
        let minuteEnd = exifTimestamp.index(minuteStart, offsetBy: 2)
        let secondStart = exifTimestamp.index(minuteEnd, offsetBy: 1)

        guard exifTimestamp[yearEnd] == ":",
              exifTimestamp[monthEnd] == ":",
              exifTimestamp[dayEnd] == " ",
              exifTimestamp[hourEnd] == ":",
              exifTimestamp[minuteEnd] == ":",
              let year = Int(exifTimestamp[yearStart..<yearEnd]),
              let month = Int(exifTimestamp[monthStart..<monthEnd]),
              let day = Int(exifTimestamp[dayStart..<dayEnd]),
              let hour = Int(exifTimestamp[hourStart..<hourEnd]),
              let minute = Int(exifTimestamp[minuteStart..<minuteEnd]),
              let second = Int(exifTimestamp[secondStart...]),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second) else {
            return nil
        }

        self.init(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    func date(offsetSeconds: Int) -> Date? {
        guard let timeZone = TimeZone(secondsFromGMT: offsetSeconds) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))
    }
}
