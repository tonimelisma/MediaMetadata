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
    /// Capture location, when the file embeds coordinates.
    public let location: GeoLocation?
    /// Camera/device fields, when present.
    public let camera: Camera?
    /// Video specifics (duration, frame rate, codec), when the file is a movie.
    public let video: VideoInfo?

    public init(
        outcome: ReadOutcome,
        format: MediaFormat,
        timestamps: CaptureTimestamps,
        location: GeoLocation? = nil,
        camera: Camera? = nil,
        video: VideoInfo? = nil
    ) {
        self.outcome = outcome
        self.format = format
        self.timestamps = timestamps
        self.location = location
        self.camera = camera
        self.video = video
    }
}

extension MediaMetadataResult {
    /// Projects the internal evidence graph into the public typed field set.
    init(_ parsed: ParsedMetadata) {
        self.init(
            outcome: ReadOutcome(parsed),
            format: MediaFormat(parsed.identity),
            timestamps: CaptureTimestamps(parsed.timestamps),
            location: parsed.locations.first.map(GeoLocation.init),
            camera: parsed.camera.map(Camera.init),
            video: parsed.video.flatMap(VideoInfo.init)
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
public struct CaptureTimestamps: Equatable, Sendable {
    /// EXIF `DateTimeOriginal` (with `OffsetTimeOriginal` when present).
    public let original: CaptureTime?
    /// EXIF `DateTimeDigitized` (with `OffsetTimeDigitized` when present).
    public let digitized: CaptureTime?
    /// TIFF IFD0 `DateTime`.
    public let tiffDateTime: CaptureTime?
    /// GPS date + time, anchored to UTC.
    public let gps: CaptureTime?
    /// QuickTime `com.apple.quicktime.creationdate` / Sony NRTM / GoPro GPMF creation date.
    public let quickTimeCreation: CaptureTime?
    /// QuickTime `com.apple.quicktime.location.date`.
    public let quickTimeLocation: CaptureTime?
    /// QuickTime `©day` content-create date.
    public let quickTimeContentCreate: CaptureTime?
    /// ISO BMFF container creation date (`mvhd`/`mdhd`/`tkhd`), anchored to UTC.
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
        func first(_ role: CaptureTimestampCandidate.Role) -> CaptureTime? {
            candidates.first { $0.role == role }.map(CaptureTime.init)
        }
        self.init(
            original: first(.original),
            digitized: first(.digitized),
            tiffDateTime: first(.tiff),
            gps: first(.gps),
            quickTimeCreation: first(.quickTimeCreationDate),
            quickTimeLocation: first(.quickTimeLocationDate),
            quickTimeContentCreate: first(.quickTimeContentCreateDate),
            containerCreation: first(.quickTimeContainerCreationDate),
            id3Recording: first(.id3RecordingDate),
            waveOrigination: first(.waveRecordingDate),
            riffRecording: first(.riff)
        )
    }
}

/// A single capture/creation timestamp with its wall-clock fields, its UTC offset
/// (when the file expresses one), and an absolute ``instant`` (when it can be
/// computed). The library has already parsed the source bytes into these values.
public struct CaptureTime: Equatable, Sendable {
    /// How precisely the source pins the moment in time.
    public enum Precision: String, Equatable, Sendable {
        /// Wall-clock plus a known UTC offset — ``instant`` is exact.
        case localWithOffset
        /// Wall-clock only, no offset in the file — ``instant`` is `nil`.
        case localFloating
        /// UTC-anchored at the source (GPS, container epoch) — ``instant`` is exact, offset 0.
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
        case "jpeg", "mjpa", "mjpb":
            self = .motionJPEG
        default:
            self = .other(fourCC: raw)
        }
    }
}
