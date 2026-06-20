import Foundation

private let id3ParserName = "MediaMetadata.ID3MetadataParser"
private let id3TimestampFrameIDs: Set<String> = ["TDRC", "TDOR", "TYER", "TDAT", "TIME"]

struct ID3MetadataParser {
    private let source: FileByteSource
    private let url: URL
    private var findings: [MetadataFinding] = []
    private var diagnostics: [MetadataDiagnostic] = []

    init(source: FileByteSource, url: URL) {
        self.source = source
        self.url = url
    }

    mutating func parse() -> MediaMetadataResult {
        guard let header = try? source.data(offset: 0, length: 10),
              header.count == 10,
              Data(header[0..<3]) == Data("ID3".utf8) else {
            return MediaMetadataResult(
                identity: FormatIdentity(
                    family: .unknown,
                    observedExtension: url.pathExtension.lowercased(),
                    detectedByMagic: false
                ),
                findings: [],
                timestamps: [],
                diagnostics: [
                    MetadataDiagnostic(
                        severity: .info,
                        code: "unsupportedID3",
                        message: "The file does not start with an ID3v2 header.",
                        parser: id3ParserName,
                        byteRange: nil
                    ),
                ],
                provenance: [
                    ParserProvenance(parser: id3ParserName, status: .unsupported)
                ]
            )
        }

        let majorVersion = header[3]
        let tagSize = synchsafeUInt32(header, offset: 6)
        guard tagSize <= 4 * 1_024 * 1_024 else {
            diagnostics.append(
                MetadataDiagnostic(
                    severity: .warning,
                    code: "id3TagTooLarge",
                    message: "ID3 tag exceeds the parser safety limit.",
                    parser: id3ParserName,
                    byteRange: 0..<UInt64(10 + tagSize)
                )
            )
            return result(majorVersion: majorVersion, timestamps: [])
        }

        parseFrames(startOffset: 10, endOffset: 10 + UInt64(tagSize), majorVersion: majorVersion)
        return result(majorVersion: majorVersion, timestamps: timestampCandidates())
    }

    private func result(majorVersion: UInt8, timestamps: [CaptureTimestampCandidate]) -> MediaMetadataResult {
        MediaMetadataResult(
            identity: FormatIdentity(
                family: .id3,
                observedExtension: url.pathExtension.lowercased(),
                detectedByMagic: true,
                brand: "ID3v2.\(majorVersion)"
            ),
            findings: findings,
            timestamps: timestamps,
            diagnostics: diagnostics,
            provenance: [
                ParserProvenance(parser: id3ParserName, status: .parsed)
            ]
        )
    }

    private mutating func parseFrames(startOffset: UInt64, endOffset: UInt64, majorVersion: UInt8) {
        var offset = startOffset
        while offset + 10 <= endOffset {
            guard let header = try? source.data(offset: offset, length: 10),
                  header.count == 10 else {
                diagnostics.append(
                    MetadataDiagnostic(
                        severity: .warning,
                        code: "id3TruncatedFrameHeader",
                        message: "Could not read an ID3 frame header.",
                        parser: id3ParserName,
                        byteRange: offset..<min(offset + 10, source.size)
                    )
                )
                return
            }
            guard header[0] != 0 else {
                return
            }
            let frameID = String(data: header[0..<4], encoding: .ascii) ?? ""
            let frameSize = majorVersion == 4 ? synchsafeUInt32(header, offset: 4) : bigEndianUInt32(header, offset: 4)
            let payloadOffset = offset + 10
            let payloadEnd = payloadOffset + UInt64(frameSize)
            guard frameSize > 0,
                  payloadEnd <= endOffset else {
                diagnostics.append(
                    MetadataDiagnostic(
                        severity: .warning,
                        code: "id3InvalidFrame",
                        message: "Could not read ID3 frame \(frameID).",
                        parser: id3ParserName,
                        byteRange: offset..<min(payloadEnd, source.size)
                    )
                )
                return
            }
            guard id3TimestampFrameIDs.contains(frameID) else {
                offset = payloadEnd
                continue
            }
            guard frameSize <= 1_048_576,
                  let payload = try? source.data(offset: payloadOffset, length: Int(frameSize)) else {
                diagnostics.append(
                    MetadataDiagnostic(
                        severity: .warning,
                        code: "id3InvalidFrame",
                        message: "Could not read ID3 frame \(frameID).",
                        parser: id3ParserName,
                        byteRange: offset..<min(payloadEnd, source.size)
                    )
                )
                return
            }
            if let value = textFrameValue(payload) {
                appendFinding(
                    namespace: "id3v2",
                    key: frameID,
                    value: value,
                    sourcePath: "id3.\(frameID)",
                    byteRange: payloadOffset..<payloadEnd
                )
                if frameID == "TDRC", CaptureDateComponents(id3Timestamp: value) != nil {
                    return
                }
            }
            offset = payloadEnd
        }
    }

    private func timestampCandidates() -> [CaptureTimestampCandidate] {
        if let recordingTime = finding(key: "TDRC"),
           let candidate = timestampCandidate(from: recordingTime) {
            return [candidate]
        }
        if let originalReleaseTime = finding(key: "TDOR"),
           let candidate = timestampCandidate(from: originalReleaseTime) {
            return [candidate]
        }
        if let year = finding(key: "TYER") {
            let day = finding(key: "TDAT")
            let time = finding(key: "TIME")
            let rawValue = [year.rawValue, day?.rawValue, time?.rawValue].compactMap { $0 }.joined(separator: " ")
            if let components = CaptureDateComponents(id3LegacyDate: year.rawValue, day: day?.rawValue, time: time?.rawValue) {
                return [
                    CaptureTimestampCandidate(
                        role: .id3RecordingDate,
                        rawTimestamp: rawValue,
                        dateComponents: components,
                        instant: nil,
                        offsetSeconds: nil,
                        authority: .localWithoutOffset,
                        evidenceIDs: [year.id] + [day?.id, time?.id].compactMap { $0 }
                    ),
                ]
            }
        }
        return []
    }

    private func timestampCandidate(from finding: MetadataFinding) -> CaptureTimestampCandidate? {
        guard let components = CaptureDateComponents(id3Timestamp: finding.rawValue) else {
            return nil
        }
        return CaptureTimestampCandidate(
            role: .id3RecordingDate,
            rawTimestamp: finding.rawValue,
            dateComponents: components,
            instant: nil,
            offsetSeconds: nil,
            authority: .localWithoutOffset,
            evidenceIDs: [finding.id]
        )
    }

    private func finding(key: String) -> MetadataFinding? {
        findings.first { $0.key == key }
    }

    private mutating func appendFinding(
        namespace: String,
        key: String,
        value: String,
        sourcePath: String,
        byteRange: Range<UInt64>?
    ) {
        findings.append(
            MetadataFinding(
                id: findings.count,
                namespace: namespace,
                key: key,
                rawValue: value,
                parser: id3ParserName,
                sourcePath: sourcePath,
                byteRange: byteRange
            )
        )
    }

    private func textFrameValue(_ payload: Data) -> String? {
        guard let encoding = payload.first else {
            return nil
        }
        let body = payload.dropFirst()
        let value: String?
        switch encoding {
        case 0:
            value = String(data: body, encoding: .isoLatin1)
        case 1:
            value = String(data: body, encoding: .utf16)
        case 2:
            value = String(data: body, encoding: .utf16BigEndian)
        case 3:
            value = String(data: body, encoding: .utf8)
        default:
            value = String(data: body, encoding: .utf8)
        }
        return value?
            .trimmingCharacters(in: .controlCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func synchsafeUInt32(_ data: Data, offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 21)
            | (UInt32(data[offset + 1]) << 14)
            | (UInt32(data[offset + 2]) << 7)
            | UInt32(data[offset + 3])
    }

    private func bigEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}

private extension CaptureDateComponents {
    init?(id3Timestamp: String) {
        let trimmed = id3Timestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: "T", with: " ")
        let parts = normalized.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else {
            return nil
        }
        let date = parts[0]
        let time = parts.count > 1 ? parts[1] : nil
        let dateParts = date.split(separator: "-").map(String.init)
        guard let firstDatePart = dateParts.first,
              let year = Int(firstDatePart) else {
            return nil
        }
        let month = dateParts.count > 1 ? Int(dateParts[1]) ?? 1 : 1
        let day = dateParts.count > 2 ? Int(dateParts[2]) ?? 1 : 1
        let timeParts = time.map(Self.stripTimeZoneSuffix)?.split(separator: ":").map(String.init) ?? []
        let hour = timeParts.count > 0 ? Int(timeParts[0]) ?? 0 : 0
        let minute = timeParts.count > 1 ? Int(timeParts[1]) ?? 0 : 0
        let second = timeParts.count > 2 ? Int(timeParts[2].prefix(while: { $0.isNumber })) ?? 0 : 0
        guard (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second) else {
            return nil
        }
        self.init(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    private static func stripTimeZoneSuffix(_ time: String) -> String {
        var value = time
        if value.hasSuffix("Z") || value.hasSuffix("z") {
            value.removeLast()
        }
        guard value.count > 1 else {
            return value
        }
        let searchStart = value.index(after: value.startIndex)
        if let offsetStart = value[searchStart...].firstIndex(where: { $0 == "+" || $0 == "-" }) {
            return String(value[..<offsetStart])
        }
        return value
    }

    init?(id3LegacyDate year: String, day: String?, time: String?) {
        guard year.count == 4, let parsedYear = Int(year) else {
            return nil
        }
        let parsedMonth: Int
        let parsedDay: Int
        if let day, day.count == 4 {
            let monthEnd = day.index(day.startIndex, offsetBy: 2)
            parsedDay = Int(day[..<monthEnd]) ?? 1
            parsedMonth = Int(day[monthEnd...]) ?? 1
        } else {
            parsedMonth = 1
            parsedDay = 1
        }
        let parsedHour: Int
        let parsedMinute: Int
        if let time, time.count == 4 {
            let hourEnd = time.index(time.startIndex, offsetBy: 2)
            parsedHour = Int(time[..<hourEnd]) ?? 0
            parsedMinute = Int(time[hourEnd...]) ?? 0
        } else {
            parsedHour = 0
            parsedMinute = 0
        }
        guard (1...12).contains(parsedMonth),
              (1...31).contains(parsedDay),
              (0...23).contains(parsedHour),
              (0...59).contains(parsedMinute) else {
            return nil
        }
        self.init(year: parsedYear, month: parsedMonth, day: parsedDay, hour: parsedHour, minute: parsedMinute, second: 0)
    }
}
