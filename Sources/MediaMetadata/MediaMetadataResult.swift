import Foundation

/// The public result of reading a media file.
///
/// Every value is fully typed — the library has already performed all
/// byte-parsing. There are no raw metadata strings, no JSON, and no "best date"
/// selection: each capture/creation timestamp is exposed as its own named field
/// on ``timestamps``. The companion ``outcome`` tells a caller whether the result
/// is definitive (record it and move on) or transient (safe to retry).
public struct MediaMetadataResult: Equatable, Sendable {
    /// Definitive-vs-transient signal for the read.
    public let outcome: ReadOutcome
    /// Detected container family and brand.
    public let format: MediaFormat
    /// All capture/creation timestamps, each strongly typed and individually named.
    public let timestamps: CaptureTimestamps
    /// Every capture location the file embeds, each addressable by its source.
    public let locations: CaptureLocations
    /// Camera/device fields, when present.
    public let camera: Camera?
    /// Video specifics (duration, frame rate, codec), when the file is a movie.
    public let video: VideoInfo?
    /// What this read actually cost.
    public let readCost: ReadCost

    public init(
        outcome: ReadOutcome,
        format: MediaFormat,
        timestamps: CaptureTimestamps,
        locations: CaptureLocations = CaptureLocations(),
        camera: Camera? = nil,
        video: VideoInfo? = nil,
        readCost: ReadCost = ReadCost()
    ) {
        self.outcome = outcome
        self.format = format
        self.timestamps = timestamps
        self.locations = locations
        self.camera = camera
        self.video = video
        self.readCost = readCost
    }
}

/// What a parse cost the transport it read through.
///
/// Public because a consumer over anything but a local disk needs it and cannot derive it:
/// bytes may be metered, round trips may cost tens of milliseconds each, and a vendor whose
/// files need ten times the usual reads is otherwise invisible until someone measures by
/// hand. It is also how a consumer verifies its own caching actually works — a chunk cache
/// that is not being hit shows up here as an unchanged `readOperationCount`.
///
/// Counted by the package over every source, so the numbers mean the same thing for a
/// file, a network reader, or a test double.
public struct ReadCost: Equatable, Sendable {
    /// Range reads the parser issued.
    public let readOperationCount: Int
    /// Reads that returned nothing — a range past the end, or a failure.
    public let failedReadOperationCount: Int
    /// Bytes asked for across every read.
    public let bytesRequested: UInt64
    /// Bytes actually delivered, counting overlapping reads more than once.
    public let bytesRead: UInt64
    /// Distinct bytes of the resource touched, with overlaps merged. The honest answer to
    /// "how much of this file did we have to fetch".
    public let uniqueBytesRead: UInt64
    /// Highest offset any read reached. Tells a consumer whether a parse stayed near the
    /// head or had to reach the tail, which decides how to prefetch.
    public let highestOffsetTouched: UInt64
    /// Size the source reported.
    public let resourceSizeBytes: UInt64
    /// Wall time for the whole parse, including transport waits.
    public let elapsedMilliseconds: Int
    /// Whether the parse ended up touching the entire resource.
    public let readWholeResource: Bool

    public init(
        readOperationCount: Int = 0,
        failedReadOperationCount: Int = 0,
        bytesRequested: UInt64 = 0,
        bytesRead: UInt64 = 0,
        uniqueBytesRead: UInt64 = 0,
        highestOffsetTouched: UInt64 = 0,
        resourceSizeBytes: UInt64 = 0,
        elapsedMilliseconds: Int = 0,
        readWholeResource: Bool = false
    ) {
        self.readOperationCount = readOperationCount
        self.failedReadOperationCount = failedReadOperationCount
        self.bytesRequested = bytesRequested
        self.bytesRead = bytesRead
        self.uniqueBytesRead = uniqueBytesRead
        self.highestOffsetTouched = highestOffsetTouched
        self.resourceSizeBytes = resourceSizeBytes
        self.elapsedMilliseconds = elapsedMilliseconds
        self.readWholeResource = readWholeResource
    }
}

extension MediaMetadataResult {
    /// Projects the internal evidence graph into the public typed field set.
    init(_ parsed: ParsedMetadata) {
        self.init(
            outcome: ReadOutcome(parsed),
            format: MediaFormat(parsed.identity),
            timestamps: CaptureTimestamps(parsed.timestamps),
            locations: CaptureLocations(parsed.locations),
            camera: parsed.camera.map(Camera.init),
            video: parsed.video.flatMap(VideoInfo.init),
            readCost: ReadCost(parsed.readMetrics)
        )
    }
}

/// Whether a read produced a definitive result or hit a transient failure.
public enum ReadOutcome: String, Equatable, Sendable {
    /// Definitive: the file was understood and the fields are authoritative
    /// (they may legitimately be empty if the file embeds no metadata).
    case parsed
    /// Definitive: the signature/format is not handled. Record this and stop —
    /// retrying will not change the answer.
    case unsupported
    /// Transient: the bytes could not be opened or read (I/O error). Safe to retry.
    case readFailure

    /// `true` for ``parsed`` and ``unsupported`` — the answer will not change on retry.
    public var isDefinitive: Bool { self != .readFailure }
    /// `true` only for ``readFailure``.
    public var shouldRetry: Bool { self == .readFailure }
}

extension ReadOutcome {
    init(_ parsed: ParsedMetadata) {
        if parsed.provenance.contains(where: { $0.status == .failed }) {
            self = .readFailure
        } else if parsed.identity.family == .unknown {
            self = .unsupported
        } else {
            self = .parsed
        }
    }
}

/// Detected container identity.
public struct MediaFormat: Equatable, Sendable {
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

    /// Container family detected from the file's bytes.
    public let family: Family
    /// Lower-cased file extension observed on the URL.
    public let fileExtension: String
    /// `true` when the family was confirmed by magic bytes (not just the extension).
    public let detectedByMagic: Bool
    /// Container brand when available (e.g. ISO BMFF major brand, `ID3v2.4`).
    public let brand: String?

    public init(family: Family, fileExtension: String, detectedByMagic: Bool, brand: String? = nil) {
        self.family = family
        self.fileExtension = fileExtension
        self.detectedByMagic = detectedByMagic
        self.brand = brand
    }
}

extension MediaFormat {
    init(_ identity: FormatIdentity) {
        self.init(
            family: Family(rawValue: identity.family.rawValue) ?? .unknown,
            fileExtension: identity.observedExtension,
            detectedByMagic: identity.detectedByMagic,
            brand: identity.brand
        )
    }
}

/// Every capture/creation timestamp the file expresses, one per source, fully
/// typed. The library never collapses these into a single "best" value — the
/// caller decides which field is authoritative for its purpose.
///
/// Within each role, when multiple candidates exist, a local-authority candidate
/// (`localFloating` / `localWithOffset`) is preferred over a UTC-anchored
/// `absolute` one so a GoPro GPMF epoch cannot shadow an offset-bearing Apple
/// `com.apple.quicktime.creationdate` (or a derived GPMF local candidate).
public struct CaptureTimestamps: Equatable, Sendable {
    /// EXIF `DateTimeOriginal` (CIPA DC-008): local capture wall clock. Offset
    /// only via EXIF 2.31 `OffsetTimeOriginal`. Floating when no offset is present.
    public let original: CaptureTime?
    /// EXIF `DateTimeDigitized` (CIPA DC-008): local digitization wall clock.
    /// Offset only via EXIF 2.31 `OffsetTimeDigitized`.
    public let digitized: CaptureTime?
    /// TIFF IFD0 `DateTime`: local modification/creation wall clock; offset via
    /// EXIF 2.31 `OffsetTime` when present.
    public let tiffDateTime: CaptureTime?
    /// GPS date + time: UTC by specification (`GPSDateStamp` + `GPSTimeStamp`).
    public let gps: CaptureTime?
    /// QuickTime `com.apple.quicktime.creationdate` / Sony NRTM / GoPro GPMF
    /// creation date. Offset-bearing ISO-8601 strings are local capture time;
    /// bare `Z` is treated as UTC-anchored (encoder normalization, not a zone
    /// claim). A GPMF UTC epoch paired with a device `TimeZone` minutes field
    /// also yields a derived local-with-offset candidate.
    public let quickTimeCreation: CaptureTime?
    /// QuickTime `com.apple.quicktime.location.date`.
    public let quickTimeLocation: CaptureTime?
    /// QuickTime `©day` content-create date.
    public let quickTimeContentCreate: CaptureTime?
    /// ISO BMFF / QuickTime container `creation_time` (`mvhd`/`mdhd`/`tkhd`):
    /// UTC per specification. Cameras frequently violate the spec and write
    /// unmarked local time (ExifTool's `QuickTimeUTC` option exists for this),
    /// so this field is classified `absolute` and must not be used as
    /// capture-local naming input.
    public let containerCreation: CaptureTime?
    /// ID3v2 recording date (`TDRC`/`TDOR`/legacy frames).
    public let id3Recording: CaptureTime?
    /// Broadcast Wave `bext` origination date/time.
    public let waveOrigination: CaptureTime?
    /// RIFF AVI/WAV `LIST.INFO` `ICRD`/`IDIT` recording date.
    public let riffRecording: CaptureTime?

    public init(
        original: CaptureTime? = nil,
        digitized: CaptureTime? = nil,
        tiffDateTime: CaptureTime? = nil,
        gps: CaptureTime? = nil,
        quickTimeCreation: CaptureTime? = nil,
        quickTimeLocation: CaptureTime? = nil,
        quickTimeContentCreate: CaptureTime? = nil,
        containerCreation: CaptureTime? = nil,
        id3Recording: CaptureTime? = nil,
        waveOrigination: CaptureTime? = nil,
        riffRecording: CaptureTime? = nil
    ) {
        self.original = original
        self.digitized = digitized
        self.tiffDateTime = tiffDateTime
        self.gps = gps
        self.quickTimeCreation = quickTimeCreation
        self.quickTimeLocation = quickTimeLocation
        self.quickTimeContentCreate = quickTimeContentCreate
        self.containerCreation = containerCreation
        self.id3Recording = id3Recording
        self.waveOrigination = waveOrigination
        self.riffRecording = riffRecording
    }

    /// All present timestamps in declared order, for callers that want to scan them.
    public var all: [CaptureTime] {
        [
            original, digitized, tiffDateTime, gps,
            quickTimeCreation, quickTimeLocation, quickTimeContentCreate, containerCreation,
            id3Recording, waveOrigination, riffRecording,
        ].compactMap { $0 }
    }
}

extension CaptureTimestamps {
    init(_ candidates: [CaptureTimestampCandidate]) {
        func preferred(_ role: CaptureTimestampCandidate.Role) -> CaptureTime? {
            let matching = candidates.filter { $0.role == role }
            guard !matching.isEmpty else {
                return nil
            }
            let selected = matching.first(where: { $0.authority == .localWithOffset })
                ?? matching.first(where: { $0.authority == .localWithoutOffset })
                ?? matching.first
            return selected.map(CaptureTime.init)
        }
        self.init(
            original: preferred(.original),
            digitized: preferred(.digitized),
            tiffDateTime: preferred(.tiff),
            gps: preferred(.gps),
            quickTimeCreation: preferred(.quickTimeCreationDate),
            quickTimeLocation: preferred(.quickTimeLocationDate),
            quickTimeContentCreate: preferred(.quickTimeContentCreateDate),
            containerCreation: preferred(.quickTimeContainerCreationDate),
            id3Recording: preferred(.id3RecordingDate),
            waveOrigination: preferred(.waveRecordingDate),
            riffRecording: preferred(.riff)
        )
    }
}

/// A single capture/creation timestamp with its wall-clock fields, its UTC offset
/// (when the file expresses one), and an absolute ``instant`` (when it can be
/// computed). The library has already parsed the source bytes into these values.
///
/// ## Wall-clock completeness
/// Every `CaptureTime` carries complete `year`…`second` components, a
/// ``precision``, and ``utcOffsetSeconds`` when known. Calendar consumers that
/// need the capture-local wall clock must use ``captureLocalComponents`` (or the
/// component fields only after checking precision) — never assume UTC components
/// are local.
///
/// ## Per-source semantics
/// - EXIF `DateTimeOriginal` / `DateTimeDigitized`: local capture time (CIPA
///   DC-008); offset only via EXIF 2.31 `OffsetTime*`.
/// - QuickTime/ISO BMFF container `creation_time`: UTC per spec, but often
///   violated by cameras writing unmarked local time — classified ``absolute``.
/// - GPS timestamps: UTC.
/// - Bare `Z`-suffixed strings: UTC-anchored normalization idiom, not a claim
///   that capture happened in UTC+0 — classified ``absolute``.
/// - Explicit `±hhmm` offsets (including `+0000`): affirmative zone claims —
///   classified ``localWithOffset``.
/// - PTP DateTime strings (when supplied by a caller upstream): local device
///   time with an optional `Z`/`±hhmm` suffix (ISO 15740 §5.3.4.1).
///
/// ``instant`` is `nil` for ``Precision/localFloating`` by design.
public struct CaptureTime: Equatable, Sendable {
    /// How precisely the source pins the moment in time.
    public enum Precision: String, Equatable, Sendable {
        /// Wall-clock plus a known UTC offset — ``instant`` is exact.
        case localWithOffset
        /// Wall-clock only, no offset in the file — ``instant`` is `nil`.
        case localFloating
        /// UTC-anchored at the source (GPS, container epoch, bare `Z`) —
        /// ``instant`` is exact; offset is 0. Not usable as capture-local naming
        /// input — see ``captureLocalComponents``.
        case absolute
    }

    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int
    /// Offset from UTC in seconds, or `nil` when the timestamp is floating.
    public let utcOffsetSeconds: Int?
    /// Absolute instant when one can be computed (offset known, or UTC-anchored source).
    /// Always `nil` for ``Precision/localFloating``.
    public let instant: Date?
    /// Expression precision of the timestamp.
    public let precision: Precision

    public init(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
        utcOffsetSeconds: Int?,
        instant: Date?,
        precision: Precision
    ) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.utcOffsetSeconds = utcOffsetSeconds
        self.instant = instant
        self.precision = precision
    }

    /// Wall-clock components for capture-local naming, or `nil` when this
    /// timestamp is UTC-anchored (``Precision/absolute``).
    ///
    /// Returns components only for ``Precision/localFloating`` and
    /// ``Precision/localWithOffset``. A UTC-anchored timestamp without a local
    /// offset is not the time "when and where the item was captured" and must
    /// be structurally unusable for calendar naming.
    public var captureLocalComponents: CaptureDateComponents? {
        switch precision {
        case .localFloating, .localWithOffset:
            return CaptureDateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute,
                second: second
            )
        case .absolute:
            return nil
        }
    }
}

extension CaptureTime {
    init(_ candidate: CaptureTimestampCandidate) {
        let components = candidate.dateComponents
        let precision: Precision
        switch candidate.authority {
        case .localWithOffset:
            precision = .localWithOffset
        case .localWithoutOffset:
            precision = .localFloating
        case .absoluteInstant:
            precision = .absolute
        }
        self.init(
            year: components.year,
            month: components.month,
            day: components.day,
            hour: components.hour,
            minute: components.minute,
            second: components.second,
            utcOffsetSeconds: candidate.offsetSeconds,
            instant: candidate.instant,
            precision: precision
        )
    }
}

/// Every capture location the file embeds, each exposed as its own named field.
/// The library applies no ordering, dedup, or "primary" preference — a caller
/// picks the source it trusts. Each field is `nil` when that source is absent.
public struct CaptureLocations: Equatable, Sendable {
    /// TIFF/EXIF GPS IFD (also HEIF embedded EXIF).
    public let exifGPS: GeoLocation?
    /// QuickTime / ISO BMFF location (`ISO6709`, `©xyz`, or `gpsCoordinates`).
    public let quickTime: GeoLocation?
    /// Sony NRTM XML GPS.
    public let sonyNRTM: GeoLocation?

    public init(exifGPS: GeoLocation? = nil, quickTime: GeoLocation? = nil, sonyNRTM: GeoLocation? = nil) {
        self.exifGPS = exifGPS
        self.quickTime = quickTime
        self.sonyNRTM = sonyNRTM
    }

    /// All present locations, for callers that want to scan rather than name a
    /// source. The order is field-declaration order and carries no preference.
    public var all: [GeoLocation] {
        [exifGPS, quickTime, sonyNRTM].compactMap { $0 }
    }
}

extension CaptureLocations {
    init(_ candidates: [CaptureLocationCandidate]) {
        func first(_ origin: CaptureLocationCandidate.Origin) -> GeoLocation? {
            candidates.first { $0.origin == origin }.map(GeoLocation.init)
        }
        self.init(
            exifGPS: first(.exifGPS),
            quickTime: first(.quickTime),
            sonyNRTM: first(.sonyNRTM)
        )
    }
}

/// A capture location in decimal degrees.
public struct GeoLocation: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitudeMeters: Double?

    public init(latitude: Double, longitude: Double, altitudeMeters: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
    }
}

extension GeoLocation {
    init(_ candidate: CaptureLocationCandidate) {
        self.init(
            latitude: candidate.latitude,
            longitude: candidate.longitude,
            altitudeMeters: candidate.altitudeMeters
        )
    }
}

/// Camera/device fields. Identity values are terminal free-text and stay `String`;
/// everything that can be typed is (``orientation`` is an enum, dimensions are `Int`).
public struct Camera: Equatable, Sendable {
    public let make: String?
    public let model: String?
    public let lensModel: String?
    public let serialNumber: String?
    public let orientation: Orientation?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        make: String? = nil,
        model: String? = nil,
        lensModel: String? = nil,
        serialNumber: String? = nil,
        orientation: Orientation? = nil,
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

/// EXIF orientation (TIFF tag 0x0112) as an enum.
public enum Orientation: Int, Equatable, Sendable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8
}

extension Camera {
    init(_ camera: CameraMetadata) {
        self.init(
            make: camera.make,
            model: camera.model,
            lensModel: camera.lensModel,
            serialNumber: camera.serialNumber,
            orientation: camera.orientation.flatMap(Orientation.init(rawValue:)),
            pixelWidth: camera.pixelWidth,
            pixelHeight: camera.pixelHeight
        )
    }
}

/// Video specifics extracted from the container.
public struct VideoInfo: Equatable, Sendable {
    /// Movie duration in seconds (from the movie header).
    public let durationSeconds: Double?
    /// Video-track frame rate in frames per second, when it can be computed.
    public let frameRate: Double?
    /// Video codec of the first video track, when identifiable.
    public let codec: VideoCodec?

    public init(durationSeconds: Double? = nil, frameRate: Double? = nil, codec: VideoCodec? = nil) {
        self.durationSeconds = durationSeconds
        self.frameRate = frameRate
        self.codec = codec
    }
}

extension VideoInfo {
    init?(_ raw: RawVideoInfo) {
        guard !raw.isEmpty else {
            return nil
        }
        self.init(
            durationSeconds: raw.durationSeconds,
            frameRate: raw.frameRate,
            codec: raw.codecFourCC.map(VideoCodec.init(fourCC:))
        )
    }
}

/// A video codec, identified from the sample-entry four-character code.
public enum VideoCodec: Equatable, Sendable {
    case h264
    case hevc
    case proRes
    case av1
    case vp9
    case motionJPEG
    /// Any codec not in the known set; carries the original four-character code.
    case other(fourCC: String)

    init(fourCC raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "avc1", "avc3":
            self = .h264
        case "hvc1", "hev1":
            self = .hevc
        case "ap4h", "apch", "apcn", "apcs", "apco", "ap4x", "aprn", "aprh":
            self = .proRes
        case "av01":
            self = .av1
        case "vp09":
            self = .vp9
        case "jpeg", "mjpa", "mjpb", "mjpg":
            self = .motionJPEG
        default:
            self = .other(fourCC: raw)
        }
    }
}


extension ReadCost {
    /// Projects the internal read metrics into the public cost view.
    init(_ metrics: MediaMetadataReadMetrics) {
        self.init(
            readOperationCount: metrics.readOperationCount,
            failedReadOperationCount: metrics.failedReadOperationCount,
            bytesRequested: metrics.byteRequestedCount,
            bytesRead: metrics.byteReadCount,
            uniqueBytesRead: metrics.uniqueByteReadCount,
            highestOffsetTouched: metrics.highestReadEndOffset,
            resourceSizeBytes: metrics.fileSizeBytes,
            elapsedMilliseconds: metrics.elapsedMilliseconds,
            readWholeResource: metrics.readWholeFile
        )
    }
}
