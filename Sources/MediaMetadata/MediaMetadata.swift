import Foundation

public enum MediaMetadataReader {
    /// Reads media metadata from `url` and returns a fully typed, fixed field set.
    ///
    /// The library performs all byte-parsing: every date is a strongly typed
    /// ``CaptureTime`` exposed as its own named field (no "best date" resolution),
    /// locations and dimensions are numeric, and the result carries a
    /// definitive-vs-transient ``ReadOutcome``. The call never throws.
    public static func read(url: URL) -> MediaMetadataResult {
        MediaMetadataResult(extract(url: url))
    }

    /// Reads media metadata from any ``MediaByteSource``.
    ///
    /// The URL-based entry point is a convenience over this one. Bytes that have no file
    /// URL — a camera object reachable only over MTP, a zip member, an HTTP range reader,
    /// an in-memory buffer — come in here instead.
    ///
    /// - Parameters:
    ///   - source: where bytes come from. Read the ``MediaByteSource`` contract before
    ///     writing a conformance: the difference between returning nil and throwing is the
    ///     difference between "this file has no capture date" and "I could not read it",
    ///     and only the source can tell them apart.
    ///   - filenameHint: a filename or extension, used solely to report an observed
    ///     extension and to disambiguate diagnostics. Format detection reads magic bytes,
    ///     so this is advisory and may be omitted entirely.
    ///
    /// The call never throws, and it does not read the source after returning.
    public static func read(source: MediaByteSource, filenameHint: String? = nil) -> MediaMetadataResult {
        MediaMetadataResult(extract(source: source, fileExtension: normalizedExtension(filenameHint)))
    }

    /// Identifies a container from its first bytes, without parsing it.
    ///
    /// Costs one read of at most 12 bytes plus, for ISO-BMFF, a short box-header probe.
    /// Useful for triaging a directory of unknown files, and for confirming that a
    /// transport is returning the file it was asked for before spending a full parse on
    /// it — a range-capable device that answers with the wrong bytes is otherwise
    /// indistinguishable from a file with no metadata.
    public static func identify(source: MediaByteSource, filenameHint: String? = nil) -> MediaFormat {
        let fileExtension = normalizedExtension(filenameHint)
        guard let magic = try? source.data(offset: 0, length: Int(min(source.size, 12))),
              magic.count >= 4
        else {
            return MediaFormat(family: .unknown, fileExtension: fileExtension, detectedByMagic: false)
        }
        let family: MediaFormat.Family = if isTIFF(magic) {
            .tiff
        } else if isJPEG(magic) {
            .jpeg
        } else if isRIFF(magic) {
            .riffAVI
        } else if isISOBMFF(source: source, initialData: magic) {
            .isoBMFF
        } else if isID3(magic) {
            .id3
        } else {
            .unknown
        }
        return MediaFormat(family: family, fileExtension: fileExtension, detectedByMagic: family != .unknown)
    }

    /// Lower-cased extension from a filename hint. `nil`, a bare name, or an empty hint all
    /// yield an empty string, which is what the result reports as "no extension observed".
    /// How much the internal buffer fetches per miss.
    ///
    /// Sized to the region a still-image parse touches — measured at ~44 KB for TIFF and
    /// ~101 KB for HEIF — so a typical parse collapses to one or two transport reads. It is
    /// not a substitute for a consumer-side `CachingByteSource` on a high-latency transport,
    /// where a larger chunk sized to that transport's round-trip cost still pays; it is the
    /// floor below which no consumer should have to think about this at all.
    static let internalCoalesceChunkSize = 128 * 1024

    private static func normalizedExtension(_ hint: String?) -> String {
        guard let hint, !hint.isEmpty else {
            return ""
        }
        return (hint as NSString).pathExtension.lowercased()
    }

    /// Internal entry point that produces the full evidence graph
    /// (findings, candidates, provenance, diagnostics, read metrics). The public
    /// ``read(url:)`` maps this into the typed field set; tests exercise it directly.
    static func extract(url: URL) -> ParsedMetadata {
        let clock = ContinuousClock()
        let readStarted = clock.now
        let fileExtension = url.pathExtension.lowercased()
        do {
            let source = try FileByteSource(url: url)
            return extract(source: source, fileExtension: fileExtension, readStarted: readStarted, clock: clock)
        } catch {
            return openFailureResult(
                fileExtension: fileExtension,
                error: error,
                elapsedMilliseconds: elapsedMilliseconds(readStarted.duration(to: clock.now))
            )
        }
    }

    static func extract(source: MediaByteSource, fileExtension: String) -> ParsedMetadata {
        let clock = ContinuousClock()
        return extract(source: source, fileExtension: fileExtension, readStarted: clock.now, clock: clock)
    }

    /// Runs one parse and attaches what it cost.
    ///
    /// Every source is wrapped in `MeteredByteSource` first, which does two things no
    /// conformance should have to: it counts the reads, so metrics mean the same thing for
    /// a file and for a network reader, and it latches the first read failure.
    ///
    /// The latch is what makes `.readFailure` reachable. Parsers read defensively with
    /// `try?` because containers legitimately point at ranges that are not there, so a
    /// thrown transport error would otherwise be indistinguishable from a range past the
    /// end of the file — and the parse would report a confident "no metadata present" for
    /// a file it never managed to read. Consumers cache definitive answers, so that is a
    /// durable wrong answer, not a transient one.
    private static func extract(
        source: MediaByteSource,
        fileExtension: String,
        readStarted: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> ParsedMetadata {
        // Layered so each level answers one question, and so the scattered-read pattern is
        // paid for once here rather than by every consumer that has to work around it.
        //
        // A parse is directed but *fine-grained*: it reads a container's index, then reads
        // individual fields inside it — 138 reads totalling 1,533 bytes inside a single
        // 100 KB region for HEIF, 21 reads for 1,155 bytes for TIFF. On a local file the
        // page cache hides that. On anything remote it is the entire cost, and leaving it
        // to consumers meant every remote consumer reinventing the same buffer.
        //
        // Bottom to top: the transport, a counter for what the transport was actually made
        // to do, a coalescing buffer, and a counter for what the parsers asked. Both counts
        // reach `ReadCost`, so "is the buffering working" is a number rather than an
        // inference.
        let transport = TransportCountingByteSource(wrapping: source)
        let coalesced = CachingByteSource(wrapping: transport, chunkSize: internalCoalesceChunkSize)
        let metered = MeteredByteSource(wrapping: coalesced)
        defer { metered.close() }
        var result = parse(source: metered, fileExtension: fileExtension)
        if let failure = metered.readFailure {
            result = result.markingReadFailure(failure)
        }
        return result.withReadMetrics(
            result.readMetrics.withSourceReadMetrics(
                metered.readMetricsSnapshot(transportReadCount: transport.transportReadCount),
                fileSizeBytes: metered.size,
                elapsedMilliseconds: elapsedMilliseconds(readStarted.duration(to: clock.now))
            )
        )
    }

    private static func openFailureResult(
        fileExtension: String,
        error: Error,
        elapsedMilliseconds: Int
    ) -> ParsedMetadata {
        ParsedMetadata(
            identity: FormatIdentity(
                family: .unknown,
                observedExtension: fileExtension,
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
                elapsedMilliseconds: elapsedMilliseconds
            )
        )
    }

    private static func parse(source: MediaByteSource, fileExtension: String) -> ParsedMetadata {
        guard let magic = try? source.data(offset: 0, length: Int(min(source.size, 12))),
              !magic.isEmpty
        else {
            return measureParser("MediaMetadata.FormatProbe") {
                unsupportedResult(
                    fileExtension: fileExtension,
                    code: "truncatedHeader",
                    message: "The file is too short to identify.",
                    parser: "MediaMetadata.FormatProbe"
                )
            }
        }
        guard magic.count >= 4 else {
            return measureParser("MediaMetadata.FormatProbe") {
                unsupportedResult(
                    fileExtension: fileExtension,
                    code: "truncatedHeader",
                    message: "The file is too short to identify.",
                    parser: "MediaMetadata.FormatProbe"
                )
            }
        }

        if isTIFF(magic) {
            var parser = TIFFMetadataParser(source: source, fileExtension: fileExtension, baseOffset: 0, family: .tiff)
            return measureParser("MediaMetadata.TIFFMetadataParser") {
                parser.parse()
            }
        }

        if isJPEG(magic) {
            guard let exifOffset = jpegEXIFTIFFOffset(source: source) else {
                return measureParser("MediaMetadata.JPEGProbe") {
                    ParsedMetadata(
                        identity: FormatIdentity(
                            family: .jpeg,
                            observedExtension: fileExtension,
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
            var parser = TIFFMetadataParser(
                source: source, fileExtension: fileExtension, baseOffset: exifOffset, family: .jpeg
            )
            return measureParser("MediaMetadata.TIFFMetadataParser") {
                parser.parse()
            }
        }

        if isRIFF(magic) {
            var parser = RIFFMetadataParser(source: source, fileExtension: fileExtension)
            return measureParser("MediaMetadata.RIFFMetadataParser") {
                parser.parse()
            }
        }

        if isISOBMFF(source: source, initialData: magic) {
            var parser = ISOBMFFMetadataParser(source: source, fileExtension: fileExtension)
            return measureParser("MediaMetadata.ISOBMFFMetadataParser") {
                parser.parse()
            }
        }

        if isID3(magic) {
            var parser = ID3MetadataParser(source: source, fileExtension: fileExtension)
            return measureParser("MediaMetadata.ID3MetadataParser") {
                parser.parse()
            }
        }

        return measureParser("MediaMetadata.FormatProbe") {
            unsupportedResult(
                fileExtension: fileExtension,
                code: "unsupportedFormat",
                message: "No metadata parser is registered for this file signature.",
                parser: "MediaMetadata.FormatProbe"
            )
        }
    }

    private static func measureParser(
        _ parserName: String,
        _ parse: () -> ParsedMetadata
    ) -> ParsedMetadata {
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

    private static func isISOBMFF(source: MediaByteSource, initialData: Data) -> Bool {
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

    private static func isoBoxProbe(source: MediaByteSource, offset: UInt64, limit: UInt64) -> ISOBoxProbe? {
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

    private static func jpegEXIFTIFFOffset(source: MediaByteSource) -> UInt64? {
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

    private static func unsupportedResult(
        fileExtension: String,
        code: String,
        message: String,
        parser: String
    ) -> ParsedMetadata {
        ParsedMetadata(
            identity: FormatIdentity(
                family: .unknown,
                observedExtension: fileExtension,
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

struct ParsedMetadata: Equatable, Sendable {
    let identity: FormatIdentity
    let findings: [MetadataFinding]
    let timestamps: [CaptureTimestampCandidate]
    let locations: [CaptureLocationCandidate]
    let camera: CameraMetadata?
    let diagnostics: [MetadataDiagnostic]
    let provenance: [ParserProvenance]
    let video: RawVideoInfo?
    let readMetrics: MediaMetadataReadMetrics
    let previews: [RawEmbeddedPreview]

    init(
        identity: FormatIdentity,
        findings: [MetadataFinding],
        timestamps: [CaptureTimestampCandidate],
        locations: [CaptureLocationCandidate] = [],
        camera: CameraMetadata? = nil,
        diagnostics: [MetadataDiagnostic],
        provenance: [ParserProvenance] = [],
        video: RawVideoInfo? = nil,
        readMetrics: MediaMetadataReadMetrics = .empty,
        previews: [RawEmbeddedPreview] = []
    ) {
        self.identity = identity
        self.findings = findings
        self.timestamps = timestamps
        self.locations = locations
        self.camera = camera
        self.diagnostics = diagnostics
        self.provenance = provenance
        self.video = video
        self.readMetrics = readMetrics
        self.previews = previews
    }

    /// Records that a read failed during this parse, which makes the outcome
    /// `.readFailure` instead of a definitive answer.
    ///
    /// Adds a failed `ParserProvenance` entry rather than a flag, because that is already
    /// how `ReadOutcome` is derived and a second mechanism answering the same question
    /// would be one too many. The diagnostic carries the underlying error so a consumer
    /// can tell a disconnected device from a truncated file without inspecting types.
    func markingReadFailure(_ error: Error) -> ParsedMetadata {
        ParsedMetadata(
            identity: identity,
            findings: findings,
            timestamps: timestamps,
            locations: locations,
            camera: camera,
            diagnostics: diagnostics + [
                MetadataDiagnostic(
                    severity: .warning,
                    code: "sourceReadFailed",
                    message: String(describing: error),
                    parser: "MediaMetadata.MediaByteSource",
                    byteRange: nil
                ),
            ],
            provenance: provenance + [
                ParserProvenance(parser: "MediaMetadata.MediaByteSource", status: .failed),
            ],
            video: video,
            readMetrics: readMetrics,
            previews: previews
        )
    }

    func withReadMetrics(_ readMetrics: MediaMetadataReadMetrics) -> ParsedMetadata {
        ParsedMetadata(
            identity: identity,
            findings: findings,
            timestamps: timestamps,
            locations: locations,
            camera: camera,
            diagnostics: diagnostics,
            provenance: provenance,
            video: video,
            readMetrics: readMetrics,
            previews: previews
        )
    }
}

/// Internal, parser-side video facts (movie duration, per-track frame rate, and
/// the first video sample-entry four-character code). Mapped into the public
/// ``VideoInfo`` by ``MediaMetadataResult``.
struct RawVideoInfo: Equatable, Sendable {
    var durationSeconds: Double?
    var frameRate: Double?
    var codecFourCC: String?

    var isEmpty: Bool {
        durationSeconds == nil && frameRate == nil && codecFourCC == nil
    }
}

struct MediaMetadataReadMetrics: Equatable, Sendable {
    struct SourceReadMetrics: Equatable, Sendable {
        let readOperationCount: Int
        let transportReadCount: Int
        let failedReadOperationCount: Int
        let byteRequestedCount: UInt64
        let byteReadCount: UInt64
        let uniqueByteReadCount: UInt64
        let largestReadLength: Int
        let highestReadEndOffset: UInt64

        init(
            readOperationCount: Int = 0,
            transportReadCount: Int = 0,
            failedReadOperationCount: Int = 0,
            byteRequestedCount: UInt64 = 0,
            byteReadCount: UInt64 = 0,
            uniqueByteReadCount: UInt64 = 0,
            largestReadLength: Int = 0,
            highestReadEndOffset: UInt64 = 0
        ) {
            self.readOperationCount = readOperationCount
            self.transportReadCount = transportReadCount
            self.failedReadOperationCount = failedReadOperationCount
            self.byteRequestedCount = byteRequestedCount
            self.byteReadCount = byteReadCount
            self.uniqueByteReadCount = uniqueByteReadCount
            self.largestReadLength = largestReadLength
            self.highestReadEndOffset = highestReadEndOffset
        }
    }

    static let empty = MediaMetadataReadMetrics()

    let parserName: String
    let parserElapsedMilliseconds: Int
    let fileSizeBytes: UInt64
    let elapsedMilliseconds: Int
    let readOperationCount: Int
    let transportReadCount: Int
    let failedReadOperationCount: Int
    let byteRequestedCount: UInt64
    let byteReadCount: UInt64
    let uniqueByteReadCount: UInt64
    let largestReadLength: Int
    let highestReadEndOffset: UInt64
    let readCoveragePermille: Int
    let readWholeFile: Bool

    init(
        parserName: String = "",
        parserElapsedMilliseconds: Int = 0,
        fileSizeBytes: UInt64 = 0,
        elapsedMilliseconds: Int = 0,
        readOperationCount: Int = 0,
        transportReadCount: Int = 0,
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
        self.transportReadCount = transportReadCount
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
            transportReadCount: sourceMetrics.transportReadCount,
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

struct FormatIdentity: Equatable, Sendable {
    enum Family: String, Equatable, Sendable {
        case tiff
        case jpeg
        case heif
        case isoBMFF
        case riffAVI
        case riffWAV
        case id3
        case unknown
    }

    let family: Family
    let observedExtension: String
    let detectedByMagic: Bool
    let brand: String?

    init(family: Family, observedExtension: String, detectedByMagic: Bool, brand: String? = nil) {
        self.family = family
        self.observedExtension = observedExtension
        self.detectedByMagic = detectedByMagic
        self.brand = brand
    }
}

struct MetadataFinding: Equatable, Sendable, Identifiable {
    let id: Int
    let namespace: String
    let key: String
    let rawValue: String
    let parser: String
    let sourcePath: String
    let byteRange: Range<UInt64>?

    init(
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

struct CaptureTimestampCandidate: Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
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

    enum Authority: String, Equatable, Sendable {
        case localWithOffset
        case localWithoutOffset
        case absoluteInstant
    }

    let role: Role
    let rawTimestamp: String
    let dateComponents: CaptureDateComponents
    let instant: Date?
    let offsetSeconds: Int?
    let authority: Authority
    let evidenceIDs: [Int]

    init(
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

/// Complete wall-clock date-time components (`year`…`second`).
///
/// Every emitted ``CaptureTime`` carries a full set of these components. Use
/// ``CaptureTime/captureLocalComponents`` when you need them only for
/// capture-local naming — that accessor returns `nil` for UTC-anchored
/// (``CaptureTime/Precision/absolute``) timestamps.
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

    static func utcComponents(from date: Date) -> CaptureDateComponents {
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

    /// Local wall-clock components recovered from a UTC instant plus a known
    /// device offset (seconds east of UTC).
    static func localComponents(from instant: Date, offsetSeconds: Int) -> CaptureDateComponents {
        utcComponents(from: instant.addingTimeInterval(TimeInterval(offsetSeconds)))
    }
}

struct CaptureLocationCandidate: Equatable, Sendable {
    /// Which metadata block a location was read from. Mirrors the public
    /// ``LocationSource`` (same raw values) so the projection is a 1:1 mapping.
    enum Origin: String, Equatable, Sendable {
        case exifGPS
        case quickTime
        case sonyNRTM
    }

    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double?
    let rawValue: String
    let source: String
    let origin: Origin
    let evidenceIDs: [Int]

    init(
        latitude: Double,
        longitude: Double,
        altitudeMeters: Double?,
        rawValue: String,
        source: String,
        origin: Origin,
        evidenceIDs: [Int]
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.rawValue = rawValue
        self.source = source
        self.origin = origin
        self.evidenceIDs = evidenceIDs
    }
}

struct CameraMetadata: Equatable, Sendable {
    let make: String?
    let model: String?
    let lensModel: String?
    let serialNumber: String?
    let orientation: Int?
    let pixelWidth: Int?
    let pixelHeight: Int?

    init(
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

struct ParserProvenance: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case parsed
        case unsupported
        case failed
    }

    let parser: String
    let status: Status

    init(parser: String, status: Status) {
        self.parser = parser
        self.status = status
    }
}

struct MetadataDiagnostic: Equatable, Sendable {
    enum Severity: String, Equatable, Sendable {
        case info
        case warning
    }

    let severity: Severity
    let code: String
    let message: String
    let parser: String
    let byteRange: Range<UInt64>?

    init(
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


/// An embedded image a container declares, verified to start with its codec's marker.
///
/// Internal evidence; ``EmbeddedPreview`` is the public projection.
struct RawEmbeddedPreview: Equatable, Sendable {
    let byteOffset: UInt64
    let byteLength: Int
    let pixelWidth: Int?
    let pixelHeight: Int?
    let encoding: String
    let sourcePath: String
}
