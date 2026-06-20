import Foundation

public enum MediaMetadataReader {
    public static func read(url: URL) -> MediaMetadataResult {
        let clock = ContinuousClock()
        let readStarted = clock.now
        do {
            let source = try FileByteSource(url: url)
            defer { source.close() }
            let result = read(url: url, source: source)
            return result.withReadMetrics(
                result.readMetrics.withSourceReadMetrics(
                    source.readMetricsSnapshot(),
                    fileSizeBytes: source.size,
                    elapsedMilliseconds: elapsedMilliseconds(readStarted.duration(to: clock.now))
                )
            )
        } catch {
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
                        severity: .warning,
                        code: "readFailed",
                        message: error.localizedDescription,
                        parser: "MediaMetadata.FileByteSource",
                        byteRange: nil
                    ),
                ],
                provenance: [
                    ParserProvenance(parser: "MediaMetadata.FileByteSource", status: .failed)
                ],
                readMetrics: MediaMetadataReadMetrics(
                    parserName: "MediaMetadata.FileByteSource",
                    fileSizeBytes: 0,
                    elapsedMilliseconds: elapsedMilliseconds(readStarted.duration(to: clock.now))
                )
            )
        }
    }

    private static func read(url: URL, source: FileByteSource) -> MediaMetadataResult {
        guard let magic = try? source.data(offset: 0, length: Int(min(source.size, 12))),
              !magic.isEmpty else {
            return measureParser("MediaMetadata.FormatProbe") {
                unsupportedResult(
                    url: url,
                    code: "truncatedHeader",
                    message: "The file is too short to identify.",
                    parser: "MediaMetadata.FormatProbe"
                )
            }
        }
        guard magic.count >= 4 else {
            return measureParser("MediaMetadata.FormatProbe") {
                unsupportedResult(
                    url: url,
                    code: "truncatedHeader",
                    message: "The file is too short to identify.",
                    parser: "MediaMetadata.FormatProbe"
                )
            }
        }

        if isTIFF(magic) {
            var parser = TIFFMetadataParser(source: source, url: url, baseOffset: 0, family: .tiff)
            return measureParser("MediaMetadata.TIFFMetadataParser") {
                parser.parse()
            }
        }

        if isJPEG(magic) {
            guard let exifOffset = jpegEXIFTIFFOffset(source: source) else {
                return measureParser("MediaMetadata.JPEGProbe") {
                    MediaMetadataResult(
                        identity: FormatIdentity(
                            family: .jpeg,
                            observedExtension: url.pathExtension.lowercased(),
                            detectedByMagic: true
                        ),
                        findings: [],
                        timestamps: [],
                        diagnostics: [
                            MetadataDiagnostic(
                                severity: .info,
                                code: "jpegMissingEXIF",
                                message: "The JPEG file does not contain an EXIF APP1 segment.",
                                parser: "MediaMetadata.JPEGProbe",
                                byteRange: nil
                            ),
                        ],
                        provenance: [
                            ParserProvenance(parser: "MediaMetadata.JPEGProbe", status: .parsed)
                        ]
                    )
                }
            }
            var parser = TIFFMetadataParser(source: source, url: url, baseOffset: exifOffset, family: .jpeg)
            return measureParser("MediaMetadata.TIFFMetadataParser") {
                parser.parse()
            }
        }

        if isRIFF(magic) {
            var parser = RIFFMetadataParser(source: source, url: url)
            return measureParser("MediaMetadata.RIFFMetadataParser") {
                parser.parse()
            }
        }

        if isISOBMFF(source: source, initialData: magic) {
            var parser = ISOBMFFMetadataParser(source: source, url: url)
            return measureParser("MediaMetadata.ISOBMFFMetadataParser") {
                parser.parse()
            }
        }

        if isID3(magic) {
            var parser = ID3MetadataParser(source: source, url: url)
            return measureParser("MediaMetadata.ID3MetadataParser") {
                parser.parse()
            }
        }

        return measureParser("MediaMetadata.FormatProbe") {
            unsupportedResult(
                url: url,
                code: "unsupportedFormat",
                message: "No metadata parser is registered for this file signature.",
                parser: "MediaMetadata.FormatProbe"
            )
        }
    }

    private static func measureParser(
        _ parserName: String,
        _ parse: () -> MediaMetadataResult
    ) -> MediaMetadataResult {
        let clock = ContinuousClock()
        let started = clock.now
        return parse().withReadMetrics(
            MediaMetadataReadMetrics(
                parserName: parserName,
                parserElapsedMilliseconds: elapsedMilliseconds(started.duration(to: clock.now))
            )
        )
    }

    private static func isTIFF(_ data: Data) -> Bool {
        guard data.count >= 4 else {
            return false
        }
        return (data[0] == 0x49 && data[1] == 0x49 && data[2] == 0x2A && data[3] == 0x00)
            || (data[0] == 0x4D && data[1] == 0x4D && data[2] == 0x00 && data[3] == 0x2A)
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8
    }

    private static func isRIFF(_ data: Data) -> Bool {
        guard data.count >= 12 else {
            return false
        }
        return Data(data[0..<4]) == Data("RIFF".utf8)
    }

    private static func isISOBMFF(source: FileByteSource, initialData: Data) -> Bool {
        guard initialData.count >= 8 else {
            return false
        }
        var cursor: UInt64 = 0
        var inspectedBoxCount = 0
        var sawValidBox = false
        while cursor + 8 <= source.size, inspectedBoxCount < 16 {
            guard let box = isoBoxProbe(source: source, offset: cursor, limit: source.size),
                  box.type.isLikelyISOBoxType else {
                return false
            }
            if box.end <= cursor {
                return false
            }
            sawValidBox = true
            cursor = box.end
            inspectedBoxCount += 1
        }
        return sawValidBox
    }

    private struct ISOBoxProbe {
        let type: String
        let end: UInt64
    }

    private static func isoBoxProbe(source: FileByteSource, offset: UInt64, limit: UInt64) -> ISOBoxProbe? {
        guard let headerEnd = adding(offset, 8),
              headerEnd <= limit,
              let header = try? source.data(offset: offset, length: 8),
              header.count == 8 else {
            return nil
        }

        let size32 = UInt32(header[0]) << 24
            | UInt32(header[1]) << 16
            | UInt32(header[2]) << 8
            | UInt32(header[3])
        let type = String(bytes: header[4..<8], encoding: .isoLatin1) ?? ""
        var size = UInt64(size32)
        var headerSize: UInt64 = 8
        if size32 == 1 {
            guard let extendedHeaderEnd = adding(offset, 16),
                  extendedHeaderEnd <= limit,
                  let extendedHeader = try? source.data(offset: offset, length: 16),
                  extendedHeader.count == 16 else {
                return nil
            }
            size = bigEndianUInt64(extendedHeader, offset: 8)
            headerSize = 16
        } else if size32 == 0 {
            size = limit - offset
        }

        guard size >= headerSize,
              let end = adding(offset, size),
              end <= limit else {
            return nil
        }
        return ISOBoxProbe(type: type, end: end)
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }

    private static func bigEndianUInt64(_ data: Data, offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func isID3(_ data: Data) -> Bool {
        data.count >= 3 && Data(data[0..<3]) == Data("ID3".utf8)
    }

    private static func jpegEXIFTIFFOffset(source: FileByteSource) -> UInt64? {
        var offset: UInt64 = 2
        while offset + 4 <= source.size {
            guard let markerData = try? source.data(offset: offset, length: 4),
                  markerData.count == 4,
                  markerData[0] == 0xFF else {
                return nil
            }

            let marker = markerData[1]
            if marker == 0xDA || marker == 0xD9 {
                return nil
            }
            let segmentLength = (UInt16(markerData[2]) << 8) | UInt16(markerData[3])
            guard segmentLength >= 2 else {
                return nil
            }

            let payloadOffset = offset + 4
            let payloadLength = Int(segmentLength - 2)
            if marker == 0xE1,
               payloadLength >= 6,
               let header = try? source.data(offset: payloadOffset, length: 6),
               header == Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
                return payloadOffset + 6
            }

            offset += 2 + UInt64(segmentLength)
        }
        return nil
    }

    private static func unsupportedResult(url: URL, code: String, message: String, parser: String) -> MediaMetadataResult {
        MediaMetadataResult(
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
                    code: code,
                    message: message,
                    parser: parser,
                    byteRange: nil
                ),
            ],
            provenance: [
                ParserProvenance(parser: parser, status: .unsupported)
            ]
        )
    }

    private static func elapsedMilliseconds(_ duration: Duration) -> Int {
        Int((Double(duration.components.seconds) * 1_000.0)
            + (Double(duration.components.attoseconds) / 1_000_000_000_000_000.0))
    }
}

public struct MediaMetadataResult: Equatable, Sendable {
    public let identity: FormatIdentity
    public let findings: [MetadataFinding]
    public let timestamps: [CaptureTimestampCandidate]
    public let locations: [CaptureLocationCandidate]
    public let camera: CameraMetadata?
    public let diagnostics: [MetadataDiagnostic]
    public let provenance: [ParserProvenance]
    public let readMetrics: MediaMetadataReadMetrics

    public init(
        identity: FormatIdentity,
        findings: [MetadataFinding],
        timestamps: [CaptureTimestampCandidate],
        locations: [CaptureLocationCandidate] = [],
        camera: CameraMetadata? = nil,
        diagnostics: [MetadataDiagnostic],
        provenance: [ParserProvenance] = [],
        readMetrics: MediaMetadataReadMetrics = .empty
    ) {
        self.identity = identity
        self.findings = findings
        self.timestamps = timestamps
        self.locations = locations
        self.camera = camera
        self.diagnostics = diagnostics
        self.provenance = provenance
        self.readMetrics = readMetrics
    }

    func withReadMetrics(_ readMetrics: MediaMetadataReadMetrics) -> MediaMetadataResult {
        MediaMetadataResult(
            identity: identity,
            findings: findings,
            timestamps: timestamps,
            locations: locations,
            camera: camera,
            diagnostics: diagnostics,
            provenance: provenance,
            readMetrics: readMetrics
        )
    }
}

public struct MediaMetadataReadMetrics: Equatable, Sendable {
    public struct SourceReadMetrics: Equatable, Sendable {
        public let readOperationCount: Int
        public let failedReadOperationCount: Int
        public let byteRequestedCount: UInt64
        public let byteReadCount: UInt64
        public let uniqueByteReadCount: UInt64
        public let largestReadLength: Int
        public let highestReadEndOffset: UInt64

        public init(
            readOperationCount: Int = 0,
            failedReadOperationCount: Int = 0,
            byteRequestedCount: UInt64 = 0,
            byteReadCount: UInt64 = 0,
            uniqueByteReadCount: UInt64 = 0,
            largestReadLength: Int = 0,
            highestReadEndOffset: UInt64 = 0
        ) {
            self.readOperationCount = readOperationCount
            self.failedReadOperationCount = failedReadOperationCount
            self.byteRequestedCount = byteRequestedCount
            self.byteReadCount = byteReadCount
            self.uniqueByteReadCount = uniqueByteReadCount
            self.largestReadLength = largestReadLength
            self.highestReadEndOffset = highestReadEndOffset
        }
    }

    public static let empty = MediaMetadataReadMetrics()

    public let parserName: String
    public let parserElapsedMilliseconds: Int
    public let fileSizeBytes: UInt64
    public let elapsedMilliseconds: Int
    public let readOperationCount: Int
    public let failedReadOperationCount: Int
    public let byteRequestedCount: UInt64
    public let byteReadCount: UInt64
    public let uniqueByteReadCount: UInt64
    public let largestReadLength: Int
    public let highestReadEndOffset: UInt64
    public let readCoveragePermille: Int
    public let readWholeFile: Bool

    public init(
        parserName: String = "",
        parserElapsedMilliseconds: Int = 0,
        fileSizeBytes: UInt64 = 0,
        elapsedMilliseconds: Int = 0,
        readOperationCount: Int = 0,
        failedReadOperationCount: Int = 0,
        byteRequestedCount: UInt64 = 0,
        byteReadCount: UInt64 = 0,
        uniqueByteReadCount: UInt64 = 0,
        largestReadLength: Int = 0,
        highestReadEndOffset: UInt64 = 0
    ) {
        self.parserName = parserName
        self.parserElapsedMilliseconds = parserElapsedMilliseconds
        self.fileSizeBytes = fileSizeBytes
        self.elapsedMilliseconds = elapsedMilliseconds
        self.readOperationCount = readOperationCount
        self.failedReadOperationCount = failedReadOperationCount
        self.byteRequestedCount = byteRequestedCount
        self.byteReadCount = byteReadCount
        self.uniqueByteReadCount = uniqueByteReadCount
        self.largestReadLength = largestReadLength
        self.highestReadEndOffset = highestReadEndOffset
        self.readCoveragePermille = Self.coveragePermille(uniqueByteReadCount: uniqueByteReadCount, fileSizeBytes: fileSizeBytes)
        self.readWholeFile = fileSizeBytes > 0 && uniqueByteReadCount >= fileSizeBytes
    }

    func withSourceReadMetrics(
        _ sourceMetrics: SourceReadMetrics,
        fileSizeBytes: UInt64,
        elapsedMilliseconds: Int
    ) -> MediaMetadataReadMetrics {
        MediaMetadataReadMetrics(
            parserName: parserName,
            parserElapsedMilliseconds: parserElapsedMilliseconds,
            fileSizeBytes: fileSizeBytes,
            elapsedMilliseconds: elapsedMilliseconds,
            readOperationCount: sourceMetrics.readOperationCount,
            failedReadOperationCount: sourceMetrics.failedReadOperationCount,
            byteRequestedCount: sourceMetrics.byteRequestedCount,
            byteReadCount: sourceMetrics.byteReadCount,
            uniqueByteReadCount: sourceMetrics.uniqueByteReadCount,
            largestReadLength: sourceMetrics.largestReadLength,
            highestReadEndOffset: sourceMetrics.highestReadEndOffset
        )
    }

    private static func coveragePermille(uniqueByteReadCount: UInt64, fileSizeBytes: UInt64) -> Int {
        guard fileSizeBytes > 0 else {
            return 0
        }
        let ratio = Double(uniqueByteReadCount) / Double(fileSizeBytes)
        return Int(min(1_000.0, (ratio * 1_000.0).rounded(.down)))
    }
}

public struct FormatIdentity: Equatable, Sendable {
    public enum Family: String, Equatable, Sendable {
        case tiff
        case jpeg
        case heif
        case isoBMFF
        case riffAVI
        case riffWAV
        case id3
        case unknown
    }

    public let family: Family
    public let observedExtension: String
    public let detectedByMagic: Bool
    public let brand: String?

    public init(family: Family, observedExtension: String, detectedByMagic: Bool, brand: String? = nil) {
        self.family = family
        self.observedExtension = observedExtension
        self.detectedByMagic = detectedByMagic
        self.brand = brand
    }
}

public struct MetadataFinding: Equatable, Sendable, Identifiable {
    public let id: Int
    public let namespace: String
    public let key: String
    public let rawValue: String
    public let parser: String
    public let sourcePath: String
    public let byteRange: Range<UInt64>?

    public init(
        id: Int,
        namespace: String,
        key: String,
        rawValue: String,
        parser: String,
        sourcePath: String,
        byteRange: Range<UInt64>?
    ) {
        self.id = id
        self.namespace = namespace
        self.key = key
        self.rawValue = rawValue
        self.parser = parser
        self.sourcePath = sourcePath
        self.byteRange = byteRange
    }
}

public struct CaptureTimestampCandidate: Equatable, Sendable {
    public enum Role: String, Equatable, Sendable {
        case original
        case digitized
        case tiff
        case riff
        case quickTimeCreationDate
        case quickTimeLocationDate
        case quickTimeContentCreateDate
        case quickTimeContainerCreationDate
        case gps
        case id3RecordingDate
        case waveRecordingDate
    }

    public enum Authority: String, Equatable, Sendable {
        case localWithOffset
        case localWithoutOffset
        case absoluteInstant
    }

    public let role: Role
    public let rawTimestamp: String
    public let dateComponents: CaptureDateComponents
    public let instant: Date?
    public let offsetSeconds: Int?
    public let authority: Authority
    public let evidenceIDs: [Int]

    public init(
        role: Role,
        rawTimestamp: String,
        dateComponents: CaptureDateComponents,
        instant: Date?,
        offsetSeconds: Int?,
        authority: Authority,
        evidenceIDs: [Int]
    ) {
        self.role = role
        self.rawTimestamp = rawTimestamp
        self.dateComponents = dateComponents
        self.instant = instant
        self.offsetSeconds = offsetSeconds
        self.authority = authority
        self.evidenceIDs = evidenceIDs
    }
}

public struct CaptureDateComponents: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int

    public init(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    public static func utcComponents(from date: Date) -> CaptureDateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return CaptureDateComponents(
            year: components.year ?? 1,
            month: components.month ?? 1,
            day: components.day ?? 1,
            hour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: components.second ?? 0
        )
    }
}

public struct CaptureLocationCandidate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitudeMeters: Double?
    public let rawValue: String
    public let source: String
    public let evidenceIDs: [Int]

    public init(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double?,
        rawValue: String,
        source: String,
        evidenceIDs: [Int]
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.rawValue = rawValue
        self.source = source
        self.evidenceIDs = evidenceIDs
    }
}

public struct CameraMetadata: Equatable, Sendable {
    public let make: String?
    public let model: String?
    public let lensModel: String?
    public let serialNumber: String?
    public let orientation: Int?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        make: String? = nil,
        model: String? = nil,
        lensModel: String? = nil,
        serialNumber: String? = nil,
        orientation: Int? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.make = make
        self.model = model
        self.lensModel = lensModel
        self.serialNumber = serialNumber
        self.orientation = orientation
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct ParserProvenance: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case parsed
        case unsupported
        case failed
    }

    public let parser: String
    public let status: Status

    public init(parser: String, status: Status) {
        self.parser = parser
        self.status = status
    }
}

public struct MetadataDiagnostic: Equatable, Sendable {
    public enum Severity: String, Equatable, Sendable {
        case info
        case warning
    }

    public let severity: Severity
    public let code: String
    public let message: String
    public let parser: String
    public let byteRange: Range<UInt64>?

    public init(
        severity: Severity,
        code: String,
        message: String,
        parser: String,
        byteRange: Range<UInt64>?
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.parser = parser
        self.byteRange = byteRange
    }
}
