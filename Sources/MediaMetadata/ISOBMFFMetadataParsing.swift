import Foundation

extension ISOBMFFMetadataParser {
    enum MetadataValue {
        case string(String)
        case signed(Int64)
        case unsigned(UInt64)
    }

    enum TimestampOffsetKind: Equatable {
        case none
        case utc
        case offset(Int)

        var secondsFromGMT: Int? {
            switch self {
            case .none:
                return nil
            case .utc:
                return 0
            case let .offset(seconds):
                return seconds
            }
        }
    }

    struct ParsedTimestamp {
        let instant: Date
        let localComponents: CaptureDateComponents
        let offsetKind: TimestampOffsetKind
    }

    struct SonyNRTMMetadata {
        let creationTimestamp: String?
        let timeZone: String?
        let manufacturer: String?
        let model: String?
        let serialNumber: String?
        let latitudeRef: String?
        let latitude: String?
        let longitudeRef: String?
        let longitude: String?
        let gpsDateStamp: String?
        let gpsTimeStamp: String?
    }

    struct ParsedLocation {
        let latitude: Double
        let longitude: Double
        let altitudeMeters: Double?
    }

    static func parseSonyNRTMXML(_ xml: String) -> SonyNRTMMetadata {
        SonyNRTMMetadata(
            creationTimestamp: firstMatch(in: xml, pattern: #"<CreationDate\s+value="([^"]+)""#, group: 1)
                ?? firstMatch(in: xml, pattern: #"<CreationDateValue>([^<]+)"#, group: 1),
            timeZone: firstSonyItem(named: "TimeZone", in: xml),
            manufacturer: firstMatch(in: xml, pattern: #"<Device[^>]*\bmanufacturer="([^"]+)""#, group: 1),
            model: firstMatch(in: xml, pattern: #"<Device[^>]*\bmodelName="([^"]+)""#, group: 1),
            serialNumber: firstMatch(in: xml, pattern: #"<Device[^>]*\bserialNo="([^"]+)""#, group: 1),
            latitudeRef: firstSonyItem(named: "LatitudeRef", in: xml),
            latitude: firstSonyItem(named: "Latitude", in: xml),
            longitudeRef: firstSonyItem(named: "LongitudeRef", in: xml),
            longitude: firstSonyItem(named: "Longitude", in: xml),
            gpsDateStamp: firstSonyItem(named: "DateStamp", in: xml),
            gpsTimeStamp: firstSonyItem(named: "TimeStamp", in: xml)
        )
    }

    static func extractXMLString(from data: Data) -> String? {
        guard let markerRange = data.range(of: Data("<?xml".utf8)) else {
            return nil
        }
        return String(data: data[markerRange.lowerBound...], encoding: .utf8)
    }

    static func parseTimestampWithOffset(_ rawValue: String) -> ParsedTimestamp? {
        let offsetKind = timestampOffsetKind(rawValue)
        guard offsetKind != .none else {
            return nil
        }
        let normalized = normalizedTimestamp(rawValue)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: normalized) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: normalized)
        }()
        guard let date else {
            return nil
        }
        return ParsedTimestamp(
            instant: date,
            localComponents: parseLocalTimestampComponents(rawValue) ?? CaptureDateComponents.utcComponents(from: date),
            offsetKind: offsetKind
        )
    }

    static func parseLocalTimestampComponents(_ rawValue: String) -> CaptureDateComponents? {
        let normalized = normalizedTimestamp(rawValue)
        let prefix = String(normalized.prefix(19))
        guard prefix.count >= 10 else {
            return nil
        }
        let dateTime = prefix.padding(toLength: 19, withPad: "T00:00:00", startingAt: 0)
        let yearStart = dateTime.startIndex
        let yearEnd = dateTime.index(yearStart, offsetBy: 4)
        let monthStart = dateTime.index(yearEnd, offsetBy: 1)
        let monthEnd = dateTime.index(monthStart, offsetBy: 2)
        let dayStart = dateTime.index(monthEnd, offsetBy: 1)
        let dayEnd = dateTime.index(dayStart, offsetBy: 2)
        let hourStart = dateTime.index(dayEnd, offsetBy: 1)
        let hourEnd = dateTime.index(hourStart, offsetBy: 2)
        let minuteStart = dateTime.index(hourEnd, offsetBy: 1)
        let minuteEnd = dateTime.index(minuteStart, offsetBy: 2)
        let secondStart = dateTime.index(minuteEnd, offsetBy: 1)
        let secondEnd = dateTime.index(secondStart, offsetBy: 2)
        guard dateTime[yearEnd] == "-",
              dateTime[monthEnd] == "-",
              dateTime[dayEnd] == "T",
              dateTime[hourEnd] == ":",
              dateTime[minuteEnd] == ":",
              let year = Int(dateTime[yearStart..<yearEnd]),
              let month = Int(dateTime[monthStart..<monthEnd]),
              let day = Int(dateTime[dayStart..<dayEnd]),
              let hour = Int(dateTime[hourStart..<hourEnd]),
              let minute = Int(dateTime[minuteStart..<minuteEnd]),
              let second = Int(dateTime[secondStart..<secondEnd]),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second) else {
            return nil
        }
        return CaptureDateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    static func parseGPSDateTime(dateStamp: String, timeStamp: String) -> Date? {
        let raw = "\(dateStamp.trimmingCharacters(in: .whitespacesAndNewlines)) \(timeStamp.trimmingCharacters(in: .whitespacesAndNewlines))"
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy:MM:dd HH:mm:ss.SSS", "yyyy:MM:dd HH:mm:ss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }

    static func parseLocation(from rawValue: String) -> ParsedLocation? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let location = parseSpaceSeparatedLocation(trimmed) {
            return location
        }
        return parseISO6709Location(trimmed)
    }

    static func parseDMSCoordinate(_ rawValue: String, ref: String) -> Double? {
        let separators = CharacterSet(charactersIn: ";, ")
        let parts = rawValue.components(separatedBy: separators).filter { !$0.isEmpty }
        guard parts.count == 3,
              let degrees = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        let decimal = degrees + (minutes / 60.0) + (seconds / 3600.0)
        switch ref.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "N", "E":
            return decimal
        case "S", "W":
            return -decimal
        default:
            return nil
        }
    }

    static func decodeMetadataValue(typeIndicator: UInt32, data: Data) -> MetadataValue? {
        switch typeIndicator {
        case 1, 7:
            return decodeString(data).map(MetadataValue.string)
        case 2:
            return String(data: data, encoding: .utf16BigEndian).map { .string(cleanString($0)) }
        case 21, 23, 25, 27:
            return .signed(readSignedInteger(from: data))
        case 22, 24, 26, 28:
            return .unsigned(readUnsignedInteger(from: data))
        default:
            return decodeString(data).map(MetadataValue.string)
        }
    }

    static func decodeString(_ data: Data) -> String? {
        if let string = String(data: data, encoding: .utf8) {
            return cleanString(string)
        }
        if let string = String(data: data, encoding: .utf16BigEndian) {
            return cleanString(string)
        }
        if let string = String(data: data, encoding: .isoLatin1) {
            return cleanString(string)
        }
        return nil
    }

    static func quickTimeDate(seconds: UInt64) -> Date? {
        guard seconds > 0 else {
            return nil
        }
        return Date(timeInterval: TimeInterval(seconds), since: quickTimeEpoch)
    }

    private static func firstSonyItem(named name: String, in xml: String) -> String? {
        firstMatch(in: xml, pattern: #"<Item\s+name="\#(name)"\s+value="([^"]+)""#, group: 1)
    }

    private static func timestampOffsetKind(_ rawValue: String) -> TimestampOffsetKind {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased().hasSuffix("Z") {
            return .utc
        }
        if let suffixRange = trimmed.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression),
           let seconds = parseTimeZoneSecondsFromGMT(String(trimmed[suffixRange])) {
            return .offset(seconds)
        }
        if let suffixRange = trimmed.range(of: #"[+-]\d{4}$"#, options: .regularExpression),
           let seconds = parseTimeZoneSecondsFromGMT(String(trimmed[suffixRange])) {
            return .offset(seconds)
        }
        return .none
    }

    private static func normalizedTimestamp(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 10 {
            let start = value.startIndex
            let fourth = value.index(start, offsetBy: 4)
            let seventh = value.index(start, offsetBy: 7)
            if value[fourth] == ":", value[seventh] == ":" {
                value.replaceSubrange(seventh...seventh, with: "-")
                value.replaceSubrange(fourth...fourth, with: "-")
            }
        }
        if let space = value.firstIndex(of: " "), !value[..<space].contains("T") {
            value.replaceSubrange(space...space, with: "T")
        }
        if value.count == 10 {
            value.append("T00:00:00")
        }
        if let suffix = value.range(of: #"[+-]\d{4}$"#, options: .regularExpression) {
            let rawSuffix = String(value[suffix])
            let sign = rawSuffix.prefix(1)
            let hours = rawSuffix.dropFirst().prefix(2)
            let minutes = rawSuffix.suffix(2)
            value.replaceSubrange(suffix, with: "\(sign)\(hours):\(minutes)")
        }
        return value
    }

    private static func parseTimeZoneSecondsFromGMT(_ rawValue: String) -> Int? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.uppercased() == "Z" {
            return 0
        }
        if trimmed.count == 6,
           let sign = trimmed.first,
           sign == "+" || sign == "-",
           trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)] == ":",
           let hours = Int(trimmed[trimmed.index(after: trimmed.startIndex)..<trimmed.index(trimmed.startIndex, offsetBy: 3)]),
           let minutes = Int(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)...]) {
            let totalSeconds = ((hours * 60) + minutes) * 60
            return sign == "-" ? -totalSeconds : totalSeconds
        }
        if trimmed.count == 5, let first = trimmed.first, first == "+" || first == "-" {
            let sign = first == "-" ? -1 : 1
            let digits = trimmed.dropFirst()
            guard let hours = Int(digits.prefix(2)),
                  let minutes = Int(digits.suffix(2)) else {
                return nil
            }
            return sign * ((hours * 60) + minutes) * 60
        }
        if let numeric = Int(trimmed) {
            if abs(numeric) <= 14 * 60 {
                return numeric * 60
            }
            if abs(numeric) <= 14 * 60 * 60 {
                return numeric
            }
        }
        return nil
    }

    private static func parseSpaceSeparatedLocation(_ rawValue: String) -> ParsedLocation? {
        let parts = rawValue.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard parts.count >= 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]) else {
            return nil
        }
        let altitude = parts.count >= 3 ? Double(parts[2]) : nil
        return ParsedLocation(latitude: latitude, longitude: longitude, altitudeMeters: altitude)
    }

    private static func parseISO6709Location(_ rawValue: String) -> ParsedLocation? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else {
            return nil
        }

        var parts: [String] = []
        var start = trimmed.startIndex
        var index = trimmed.index(after: start)
        while index < trimmed.endIndex {
            if trimmed[index] == "+" || trimmed[index] == "-" {
                parts.append(String(trimmed[start..<index]))
                start = index
            }
            index = trimmed.index(after: index)
        }
        parts.append(String(trimmed[start..<trimmed.endIndex]))

        guard parts.count >= 2,
              let latitude = Double(parts[0]),
              let longitude = Double(parts[1]) else {
            return nil
        }
        let altitude = parts.count >= 3 ? Double(parts[2]) : nil
        return ParsedLocation(latitude: latitude, longitude: longitude, altitudeMeters: altitude)
    }

    private static func cleanString(_ rawValue: String) -> String {
        let scalars = rawValue.unicodeScalars.filter { scalar in
            scalar.value == 9 || scalar.value >= 32
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .controlCharacters)
    }

    private static func readUnsignedInteger(from data: Data) -> UInt64 {
        data.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func readSignedInteger(from data: Data) -> Int64 {
        guard let first = data.first else {
            return 0
        }
        var value: Int64 = first & 0x80 == 0 ? 0 : -1
        for byte in data.prefix(8) {
            value = (value << 8) | Int64(byte)
        }
        return value
    }

    private static func firstMatch(in string: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range),
              let matchRange = Range(match.range(at: group), in: string) else {
            return nil
        }
        return String(string[matchRange])
    }
}
