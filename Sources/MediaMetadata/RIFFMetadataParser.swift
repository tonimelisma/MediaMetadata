import Foundation

private let riffParserName = "MediaMetadata.RIFFMetadataParser"
private let maxRIFFMetadataListDepth = 16
private let timestampInfoChunkIDs: Set<String> = ["ICRD", "IDIT", "TDT"]

struct RIFFMetadataParser {
    private let source: FileByteSource
    private let url: URL
    private var findings: [MetadataFinding] = []
    private var diagnostics: [MetadataDiagnostic] = []

    init(source: FileByteSource, url: URL) {
        self.source = source
        self.url = url
    }

    mutating func parse() -> MediaMetadataResult {
        guard let header = try? source.data(offset: 0, length: 12),
              header.count == 12,
              Data(header[0..<4]) == Data("RIFF".utf8) else {
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
                        code: "unsupportedRIFF",
                        message: "The file is not a RIFF container.",
                        parser: riffParserName,
                        byteRange: nil
                    ),
                ],
                provenance: [
                    ParserProvenance(parser: riffParserName, status: .unsupported)
                ]
            )
        }

        let formType = ascii(header[8..<12])
        let family: FormatIdentity.Family
        switch formType {
        case "AVI ":
            family = .riffAVI
        case "WAVE":
            family = .riffWAV
        default:
            family = .unknown
        }
        let identity = FormatIdentity(
            family: family,
            observedExtension: url.pathExtension.lowercased(),
            detectedByMagic: true,
            brand: formType
        )

        _ = parseMetadataChunks(startOffset: 12, endOffset: source.size, path: "riff", depth: 0)
        let timestamps = findings.compactMap(timestampCandidate)
        if timestamps.isEmpty, family == .riffAVI {
            diagnostics.append(
                MetadataDiagnostic(
                    severity: .info,
                    code: "aviMissingEmbeddedDate",
                    message: "The AVI file did not contain an embedded date/time metadata chunk.",
                    parser: riffParserName,
                    byteRange: nil
                )
            )
        }
        return MediaMetadataResult(
            identity: identity,
            findings: findings,
            timestamps: timestamps,
            diagnostics: diagnostics,
            provenance: [
                ParserProvenance(parser: riffParserName, status: .parsed)
            ]
        )
    }

    @discardableResult
    private mutating func parseMetadataChunks(startOffset: UInt64, endOffset: UInt64, path: String, depth: Int) -> Bool {
        var offset = startOffset
        while let headerEnd = adding(offset, 8), headerEnd <= endOffset {
            guard let header = try? source.data(offset: offset, length: 8),
                  header.count == 8 else {
                diagnostics.append(
                    MetadataDiagnostic(
                        severity: .warning,
                        code: "riffTruncatedChunkHeader",
                        message: "Could not read RIFF chunk header.",
                        parser: riffParserName,
                        byteRange: offset..<(min(offset + 8, source.size))
                    )
                )
                return false
            }

            let chunkID = ascii(header[0..<4])
            let chunkSize = UInt64(littleEndianUInt32(header, offset: 4))
            let computedPayloadOffset = adding(offset, 8)
            let computedPayloadEnd = computedPayloadOffset.flatMap { adding($0, chunkSize) }
            guard let payloadOffset = computedPayloadOffset,
                  let payloadEnd = computedPayloadEnd,
                  payloadEnd <= endOffset else {
                diagnostics.append(
                    MetadataDiagnostic(
                        severity: .warning,
                        code: "riffChunkExceedsContainer",
                        message: "RIFF chunk \(chunkID) exceeds the parent container.",
                        parser: riffParserName,
                        byteRange: offset..<(min(computedPayloadEnd ?? source.size, source.size))
                    )
                )
                return false
            }

            if chunkID == "LIST",
               chunkSize >= 4,
               let listTypeData = try? source.data(offset: payloadOffset, length: 4),
               listTypeData.count == 4 {
                let listType = ascii(listTypeData[0..<4])
                if listType == "INFO" {
                    if parseINFOChunks(startOffset: payloadOffset + 4, endOffset: payloadEnd, path: "\(path).LIST.INFO") {
                        return true
                    }
                } else if listType != "movi" {
                    if depth >= maxRIFFMetadataListDepth {
                        diagnostics.append(
                            MetadataDiagnostic(
                                severity: .warning,
                                code: "riffMetadataListDepthExceeded",
                                message: "RIFF metadata list nesting exceeded the parser limit.",
                                parser: riffParserName,
                                byteRange: payloadOffset..<payloadEnd
                            )
                        )
                    } else {
                        if parseMetadataChunks(
                            startOffset: payloadOffset + 4,
                            endOffset: payloadEnd,
                            path: "\(path).LIST.\(listType)",
                            depth: depth + 1
                        ) {
                            return true
                        }
                    }
                }
            } else if chunkID == "bext" {
                if parseBroadcastWaveChunk(startOffset: payloadOffset, endOffset: payloadEnd, path: "\(path).bext") {
                    return true
                }
            }

            guard let nextOffset = adding(payloadEnd, chunkSize % 2) else {
                return false
            }
            offset = nextOffset
        }
        return false
    }

    @discardableResult
    private mutating func parseBroadcastWaveChunk(startOffset: UInt64, endOffset: UInt64, path: String) -> Bool {
        let minimumLength: UInt64 = 256 + 32 + 32 + 10 + 8
        guard endOffset >= startOffset + minimumLength,
              let dateData = try? source.data(offset: startOffset + 256 + 32 + 32, length: 10),
              let timeData = try? source.data(offset: startOffset + 256 + 32 + 32 + 10, length: 8) else {
            return false
        }
        let date = String(data: dateData.prefix { $0 != 0 }, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let time = String(data: timeData.prefix { $0 != 0 }, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !date.isEmpty, !time.isEmpty else {
            return false
        }
        appendFinding(
            namespace: "riff.bext",
            key: "OriginationDateTime",
            value: "\(date) \(time)",
            sourcePath: "\(path).OriginationDateTime",
            byteRange: (startOffset + 256 + 32 + 32)..<(startOffset + 256 + 32 + 32 + 10 + 8)
        )
        return true
    }

    @discardableResult
    private mutating func parseINFOChunks(startOffset: UInt64, endOffset: UInt64, path: String) -> Bool {
        var offset = startOffset
        while let headerEnd = adding(offset, 8), headerEnd <= endOffset {
            guard let header = try? source.data(offset: offset, length: 8),
                  header.count == 8 else {
                return false
            }
            let key = ascii(header[0..<4])
            let size = UInt64(littleEndianUInt32(header, offset: 4))
            let computedValueOffset = adding(offset, 8)
            let computedValueEnd = computedValueOffset.flatMap { adding($0, size) }
            guard let valueOffset = computedValueOffset,
                  let valueEnd = computedValueEnd,
                  valueEnd <= endOffset,
                  size <= 4096 else {
                diagnostics.append(
                    MetadataDiagnostic(
                        severity: .warning,
                        code: "riffInvalidINFOChunk",
                        message: "Could not read AVI INFO chunk \(key).",
                        parser: riffParserName,
                        byteRange: offset..<(min(computedValueEnd ?? source.size, source.size))
                    )
                )
                return false
            }
            if !timestampInfoChunkIDs.contains(key) {
                guard let nextOffset = adding(valueEnd, size % 2) else {
                    return false
                }
                offset = nextOffset
                continue
            }
            guard let valueData = try? source.data(offset: valueOffset, length: Int(size)) else {
                diagnostics.append(
                    MetadataDiagnostic(
                        severity: .warning,
                        code: "riffInvalidINFOChunk",
                        message: "Could not read AVI INFO chunk \(key).",
                        parser: riffParserName,
                        byteRange: offset..<(min(computedValueEnd ?? source.size, source.size))
                    )
                )
                return false
            }
            let trimmed = valueData.prefix { $0 != 0 }
            if let value = String(data: Data(trimmed), encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty {
                appendFinding(
                    namespace: "riff.info",
                    key: key,
                    value: value,
                    sourcePath: "\(path).\(key)",
                    byteRange: valueOffset..<valueEnd
                )
                if CaptureDateComponents(riffTimestamp: value) != nil {
                    return true
                }
            }
            guard let nextOffset = adding(valueEnd, size % 2) else {
                return false
            }
            offset = nextOffset
        }
        return false
    }

    private mutating func appendFinding(
        namespace: String,
        key: String,
        value: String,
        sourcePath: String,
        byteRange: Range<UInt64>
    ) {
        findings.append(
            MetadataFinding(
                id: findings.count,
                namespace: namespace,
                key: key,
                rawValue: value,
                parser: riffParserName,
                sourcePath: sourcePath,
                byteRange: byteRange
            )
        )
    }

    private func timestampCandidate(from finding: MetadataFinding) -> CaptureTimestampCandidate? {
        guard timestampInfoChunkIDs.contains(finding.key) || finding.key == "OriginationDateTime",
              let components = CaptureDateComponents(riffTimestamp: finding.rawValue) else {
            return nil
        }
        let role: CaptureTimestampCandidate.Role = finding.namespace == "riff.bext" ? .waveRecordingDate : .riff
        return CaptureTimestampCandidate(
            role: role,
            rawTimestamp: finding.rawValue,
            dateComponents: components,
            instant: nil,
            offsetSeconds: nil,
            authority: .localWithoutOffset,
            evidenceIDs: [finding.id]
        )
    }

    private func ascii(_ data: Data.SubSequence) -> String {
        String(data: Data(data), encoding: .ascii) ?? ""
    }

    private func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }

    private func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private extension CaptureDateComponents {
    init?(riffTimestamp: String) {
        let trimmed = riffTimestamp.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: "-", with: ":")
        if let exifStyle = CaptureDateComponents(exifStyleTimestamp: normalized) {
            self = exifStyle
            return
        }
        if let yearOnly = CaptureDateComponents(yearOnlyTimestamp: trimmed) {
            self = yearOnly
            return
        }
        return nil
    }

    init?(exifStyleTimestamp: String) {
        guard exifStyleTimestamp.count >= 19 else {
            return nil
        }
        let prefix = String(exifStyleTimestamp.prefix(19))
        let yearStart = prefix.startIndex
        let yearEnd = prefix.index(yearStart, offsetBy: 4)
        let monthStart = prefix.index(yearEnd, offsetBy: 1)
        let monthEnd = prefix.index(monthStart, offsetBy: 2)
        let dayStart = prefix.index(monthEnd, offsetBy: 1)
        let dayEnd = prefix.index(dayStart, offsetBy: 2)
        let hourStart = prefix.index(dayEnd, offsetBy: 1)
        let hourEnd = prefix.index(hourStart, offsetBy: 2)
        let minuteStart = prefix.index(hourEnd, offsetBy: 1)
        let minuteEnd = prefix.index(minuteStart, offsetBy: 2)
        let secondStart = prefix.index(minuteEnd, offsetBy: 1)

        guard prefix[yearEnd] == ":",
              prefix[monthEnd] == ":",
              prefix[dayEnd] == " ",
              prefix[hourEnd] == ":",
              prefix[minuteEnd] == ":",
              let year = Int(prefix[yearStart..<yearEnd]),
              let month = Int(prefix[monthStart..<monthEnd]),
              let day = Int(prefix[dayStart..<dayEnd]),
              let hour = Int(prefix[hourStart..<hourEnd]),
              let minute = Int(prefix[minuteStart..<minuteEnd]),
              let second = Int(prefix[secondStart...]),
              (1...12).contains(month),
              (1...31).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second) else {
            return nil
        }
        self.init(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    }

    init?(yearOnlyTimestamp: String) {
        guard yearOnlyTimestamp.count == 4,
              let year = Int(yearOnlyTimestamp) else {
            return nil
        }
        self.init(year: year, month: 1, day: 1, hour: 0, minute: 0, second: 0)
    }
}
