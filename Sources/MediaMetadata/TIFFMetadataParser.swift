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

    private enum TIFFType {
        static let ascii: UInt16 = 2
        static let long: UInt16 = 4
    }

    private enum Tag {
        static let tiffDateTime: UInt16 = 0x0132
        static let exifIFDPointer: UInt16 = 0x8769
        static let dateTimeOriginal: UInt16 = 0x9003
        static let dateTimeDigitized: UInt16 = 0x9004
        static let offsetTime: UInt16 = 0x9010
        static let offsetTimeOriginal: UInt16 = 0x9011
        static let offsetTimeDigitized: UInt16 = 0x9012
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

    mutating func parse() -> MediaMetadataResult {
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
            return MediaMetadataResult(identity: identity, findings: findings, timestamps: [], diagnostics: diagnostics)
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

        var dateTimeOriginal: RawField?
        var dateTimeDigitized: RawField?
        var offsetTime: RawField?
        var offsetTimeOriginal: RawField?
        var offsetTimeDigitized: RawField?

        if let exifPointerEntry = ifd0[Tag.exifIFDPointer],
           let exifOffset = longValue(from: exifPointerEntry),
           let exif = parseIFD(offset: UInt64(exifOffset), byteOrder: byteOrder, path: "tiff.ifd0.exif") {
            if let entry = exif[Tag.dateTimeOriginal],
               let ascii = asciiValue(from: entry) {
                dateTimeOriginal = appendFinding(
                    namespace: "exif",
                    key: "DateTimeOriginal",
                    value: ascii.value,
                    sourcePath: "tiff.ifd0.exif.DateTimeOriginal",
                    byteRange: ascii.byteRange
                )
            }
            if let entry = exif[Tag.dateTimeDigitized],
               let ascii = asciiValue(from: entry) {
                dateTimeDigitized = appendFinding(
                    namespace: "exif",
                    key: "DateTimeDigitized",
                    value: ascii.value,
                    sourcePath: "tiff.ifd0.exif.DateTimeDigitized",
                    byteRange: ascii.byteRange
                )
            }
            if let entry = exif[Tag.offsetTime],
               let ascii = asciiValue(from: entry) {
                offsetTime = appendFinding(
                    namespace: "exif",
                    key: "OffsetTime",
                    value: ascii.value,
                    sourcePath: "tiff.ifd0.exif.OffsetTime",
                    byteRange: ascii.byteRange
                )
            }
            if let entry = exif[Tag.offsetTimeOriginal],
               let ascii = asciiValue(from: entry) {
                offsetTimeOriginal = appendFinding(
                    namespace: "exif",
                    key: "OffsetTimeOriginal",
                    value: ascii.value,
                    sourcePath: "tiff.ifd0.exif.OffsetTimeOriginal",
                    byteRange: ascii.byteRange
                )
            }
            if let entry = exif[Tag.offsetTimeDigitized],
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

        return MediaMetadataResult(
            identity: identity,
            findings: findings,
            timestamps: timestamps,
            diagnostics: diagnostics
        )
    }

    private mutating func unsupportedResult(code: String, message: String) -> MediaMetadataResult {
        diagnostics.append(
            MetadataDiagnostic(
                severity: .info,
                code: code,
                message: message,
                parser: parserName,
                byteRange: nil
            )
        )
        return MediaMetadataResult(
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

    private func longValue(from entry: IFDEntry) -> UInt32? {
        guard entry.type == TIFFType.long,
              entry.count == 1 else {
            return nil
        }
        return entry.valueOrOffset
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
