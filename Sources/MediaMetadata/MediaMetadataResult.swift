import Foundation

/// The public result of reading a media file.
///
/// Every value is fully typed — the library has already performed all
/// byte-parsing. There are no raw metadata strings and no JSON. Each
/// capture/creation timestamp is exposed as its own named field on ``timestamps``;
/// the purpose-named selections there (``CaptureTimestamps/captureWallClock``,
/// ``CaptureTimestamps/captureInstant``) choose among them without hiding them. The
/// companion ``outcome`` tells a caller whether the result is definitive (record it
/// and move on) or transient (safe to retry).
public struct MediaMetadataResult: Equatable, Sendable {
    /// Definitive-vs-transient signal for the read.
    public let outcome: ReadOutcome
    /// Detected container family and brand.
    public let format: MediaFormat
    /// All capture/creation timestamps, each strongly typed and individually named.
    public let timestamps: CaptureTimestamps
    /// Every capture location the file embeds, each addressable by its source.
    public let locations: CaptureLocations
    /// The capturing device's identity (make, model, lens, serial), when the file names one.
    ///
    /// `nil` for a file that carries no device identity — a screen recording, an exported
    /// still — even when it has dimensions; those live on ``geometry``.
    public let camera: Camera?
    /// Stored pixel size and display orientation, for stills and video alike.
    public let geometry: PixelGeometry?
    /// Video specifics (duration, frame rate, codec), when the file is a movie.
    public let video: VideoInfo?
    /// What this read actually cost.
    public let readCost: ReadCost
    /// Images the container embeds, largest first — where they are, not their bytes.
    public let previews: [EmbeddedPreview]

    public init(
        outcome: ReadOutcome,
        format: MediaFormat,
        timestamps: CaptureTimestamps,
        locations: CaptureLocations = CaptureLocations(),
        camera: Camera? = nil,
        geometry: PixelGeometry? = nil,
        video: VideoInfo? = nil,
        readCost: ReadCost = ReadCost(),
        previews: [EmbeddedPreview] = []
    ) {
        self.outcome = outcome
        self.format = format
        self.timestamps = timestamps
        self.locations = locations
        self.camera = camera
        self.geometry = geometry
        self.video = video
        self.readCost = readCost
        self.previews = previews
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
    ///
    /// A directed parse is fine-grained — it reads an index, then individual fields inside
    /// it — so this is normally in the tens or low hundreds even when the bytes touched
    /// total a couple of kilobytes.
    public let readOperationCount: Int

    /// Reads that actually reached your source, after the package's internal buffering.
    ///
    /// The number that matters on a transport where a read costs a round trip. Compare it
    /// with ``readOperationCount``: a large gap means the buffering is doing its job, and a
    /// ratio near 1 on a remote source means it is not — usually because the container's
    /// metadata is scattered far apart, which is the case for wrapping the source in a
    /// ``CachingByteSource`` with a chunk size matched to your own latency.
    public let transportReadCount: Int
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
        transportReadCount: Int = 0,
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
        self.transportReadCount = transportReadCount
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
            camera: parsed.camera.flatMap(Camera.init),
            geometry: parsed.camera.flatMap(PixelGeometry.init),
            video: parsed.video.flatMap(VideoInfo.init),
            readCost: ReadCost(parsed.readMetrics),
            previews: parsed.previews.map(EmbeddedPreview.init)
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
    public enum Family: String, Equatable, Sendable, CaseIterable {
        case tiff
        case jpeg
        case heif
        case png
        /// WebP: a RIFF container whose form type is `WEBP`.
        case webp
        case gif
        case isoBMFF
        case riffAVI
        case riffWAV
        case id3
        case unknown
    }

    /// What the file holds, as opposed to how it is packaged.
    ///
    /// ``Family`` names the container, and one container can carry very different things:
    /// ISO BMFF is a movie in an MP4 and a still in an AVIF, and an M4A is audio. `Kind` is
    /// decided from the structure the parser saw — a video track makes a movie, a primary
    /// image item makes a still — and from the family only where the family settles it.
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case image
        case video
        case audio
        /// Not determinable from what was read — including an ISO BMFF file that was only
        /// identified (``MediaMetadataReader/identify(source:filenameHint:)``), not parsed.
        case unknown

        /// The kind a family implies on its own, or ``unknown`` when the family is a
        /// general-purpose container whose contents decide (ISO BMFF).
        init(family: Family) {
            switch family {
            case .tiff, .jpeg, .heif, .png, .webp, .gif:
                self = .image
            case .riffAVI:
                self = .video
            case .riffWAV, .id3:
                self = .audio
            case .isoBMFF, .unknown:
                self = .unknown
            }
        }
    }

    /// Container family detected from the file's bytes.
    public let family: Family
    /// What the file holds — still, movie or sound.
    public let kind: Kind
    /// Lower-cased file extension observed on the URL.
    public let fileExtension: String
    /// `true` when the family was confirmed by magic bytes (not just the extension).
    public let detectedByMagic: Bool
    /// Container brand when available (e.g. ISO BMFF major brand, `ID3v2.4`).
    public let brand: String?
    /// The file type the bytes identify — e.g. ``MediaFileType/arw`` for a Sony RAW, which
    /// is a TIFF by family. `nil` when the bytes do not settle it (an ISO BMFF file that was
    /// only identified, not parsed). Never taken from the extension when the bytes disagree.
    public let fileType: MediaFileType?

    /// `true` when the bytes identify camera RAW sensor data. A RAW is a still, so ``kind``
    /// is ``Kind/image``; this says which kind of still.
    public var isCameraRaw: Bool {
        fileType?.isCameraRaw ?? false
    }

    public init(
        family: Family,
        kind: Kind? = nil,
        fileExtension: String,
        detectedByMagic: Bool,
        brand: String? = nil,
        fileType: MediaFileType? = nil
    ) {
        var resolvedKind = kind ?? Kind(family: family)
        // A type the bytes named can settle a kind the family could not — a Fujifilm RAF the
        // library recognises but does not parse, an audio-only M4A brand — but a generic MP4
        // brand says nothing about whether the file holds pictures or only sound.
        if resolvedKind == .unknown, let fileType, fileType != .mp4 {
            resolvedKind = fileType.kind
        }
        self.family = family
        self.kind = resolvedKind
        self.fileExtension = fileExtension
        self.detectedByMagic = detectedByMagic
        self.brand = brand
        self.fileType = fileType
    }
}

/// The file type a user would name — JPEG, HEIF, ARW, MOV — one per format, not one per
/// spelling of its extension.
///
/// Two ways to get one, for two moments in a catalog's life:
/// - ``MediaFormat/fileType`` after a read, decided from the **bytes**: an ISO BMFF brand
///   (`qt  ` is a MOV, `crx ` a Canon CR3), or a TIFF that turns out to be camera RAW. It
///   wins over a misleading extension.
/// - ``init(fileExtension:)`` before any read, when all a scanner has is a name. It folds
///   spelling variants (`jpg`/`jpe`/`jpeg`, `tif`/`tiff`, `heic`/`heif`/`hif`) into one type.
///
/// ``rawValue`` is a stable lower-case identifier, safe to store. ``displayName`` is the
/// conventional upper-case label. Neither is ever derived from a framework's type system.
public enum MediaFileType: String, Equatable, Hashable, Sendable, CaseIterable {
    case jpeg
    /// HEIF in any of its spellings, including Apple's `.heic`.
    case heif
    case avif
    case png
    case webp
    case gif
    case tiff
    // Camera RAW.
    case dng
    case arw
    case cr2
    case cr3
    case nef
    case orf
    case rw2
    case raf
    case pef
    case srw
    /// Camera RAW sensor data (a colour-filter-array raster) from a vendor without a named
    /// case here.
    case otherRaw
    // Movies.
    case mov
    case mp4
    case m4v
    case threeGPP = "3gp"
    case avi
    // Sound.
    case m4a
    case mp3
    case wav

    /// The type an extension conventionally names, or `nil` for one this table does not know.
    /// Case- and dot-insensitive: `"JPG"`, `".jpe"` and `"jpeg"` are all ``jpeg``.
    ///
    /// This is a naming convention, not a detection: use it to label a file nothing has read
    /// yet, and prefer ``MediaFormat/fileType`` once something has.
    public init?(fileExtension: String) {
        var key = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix(".") {
            key.removeFirst()
        }
        guard let type = Self.byExtension[key] else {
            return nil
        }
        self = type
    }

    /// The conventional label: `"JPEG"`, `"HEIF"`, `"ARW"`, `"3GP"`; `"RAW"` for ``otherRaw``.
    public var displayName: String {
        switch self {
        case .threeGPP: "3GP"
        case .otherRaw: "RAW"
        default: rawValue.uppercased()
        }
    }

    /// `true` for camera RAW formats — sensor data that must be developed to be viewed.
    public var isCameraRaw: Bool {
        switch self {
        case .dng, .arw, .cr2, .cr3, .nef, .orf, .rw2, .raf, .pef, .srw, .otherRaw: true
        default: false
        }
    }

    /// Still, movie or sound.
    public var kind: MediaFormat.Kind {
        switch self {
        case .mov, .mp4, .m4v, .threeGPP, .avi: .video
        case .m4a, .mp3, .wav: .audio
        default: .image
        }
    }

    private static let byExtension: [String: MediaFileType] = {
        var table: [String: MediaFileType] = [
            "jpg": .jpeg, "jpe": .jpeg, "jfif": .jpeg,
            "heic": .heif, "hif": .heif, "heics": .heif, "heifs": .heif,
            "avifs": .avif,
            "tif": .tiff,
            "qt": .mov,
            "3g2": .threeGPP,
        ]
        for type in allCases where type != .otherRaw && type != .threeGPP {
            table[type.rawValue] = type
        }
        table["3gp"] = .threeGPP
        return table
    }()
}

extension MediaFileType {
    /// The type the bytes already settled — a family that implies one, or an ISO BMFF brand.
    /// `nil` when the bytes alone do not say (an unparsed ISO BMFF file, an unknown family).
    init?(family: MediaFormat.Family, brand: String?, fileExtension: String) {
        switch family {
        case .jpeg:
            self = .jpeg
        case .tiff:
            self = .tiff
        case .png:
            self = .png
        case .webp:
            self = .webp
        case .gif:
            self = .gif
        case .riffAVI:
            self = .avi
        case .riffWAV:
            self = .wav
        case .id3:
            self = .mp3
        case .heif:
            // AVIF's major brand is usually `avif`; a generic MIAF brand (`mif1`) leaves the
            // codec unstated in the brand, and only then does the extension break the tie.
            if brand == "avif" || brand == "avis" || (brand == "mif1" && fileExtension == "avif") {
                self = .avif
            } else {
                self = .heif
            }
        case .isoBMFF:
            // ISO BMFF requires an `ftyp`; a parsed file without one is QuickTime from before
            // the MP4 family existed. (This initializer only runs after a parse — `identify`
            // reads no brand and decides its type separately.)
            guard let brand else {
                self = .mov
                return
            }
            switch brand {
            case "qt  ": self = .mov
            case "crx ": self = .cr3
            case "M4A ", "M4B ", "M4P ": self = .m4a
            case "M4V ", "M4VH", "M4VP": self = .m4v
            default:
                self = brand.hasPrefix("3g") ? .threeGPP : .mp4
            }
        case .unknown:
            return nil
        }
    }
}

extension MediaFormat {
    init(_ identity: FormatIdentity) {
        let family = Family(rawValue: identity.family.rawValue) ?? .unknown
        self.init(
            family: family,
            kind: identity.kind.flatMap { Kind(rawValue: $0.rawValue) },
            fileExtension: identity.observedExtension,
            detectedByMagic: identity.detectedByMagic,
            brand: identity.brand,
            // A parse has read enough to fall back on what the family and brand imply; a TIFF
            // parser that found RAW evidence has already said so in `identity.fileType`.
            fileType: identity.fileType.flatMap(MediaFileType.init(rawValue:))
                ?? MediaFileType(family: family, brand: identity.brand, fileExtension: identity.observedExtension)
        )
    }
}

/// Every capture/creation timestamp the file expresses, one per source, fully
/// typed.
///
/// There is no single "best date", because there is no single question: *what local
/// time was this taken* (for naming) and *what instant was this taken* (for ordering)
/// have different right answers from the same file. Each has its own selection —
/// ``captureWallClock`` and ``captureInstant`` — which reports the role it chose and
/// leaves every field here intact, so a caller with a different policy walks
/// ``entries`` or subscripts by ``Role`` instead.
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

    /// Names each field of ``CaptureTimestamps``, so a caller can hold, persist or rank a
    /// source without restating the field list.
    ///
    /// Raw values are the field names and are stable: they are safe to store. The cases
    /// are declared in field order.
    public enum Role: String, Equatable, Hashable, Sendable, CaseIterable {
        case original
        case digitized
        case tiffDateTime
        case gps
        case quickTimeCreation
        case quickTimeLocation
        case quickTimeContentCreate
        case containerCreation
        case id3Recording
        case waveOrigination
        case riffRecording

        /// `true` for roles only sound files carry (ID3 tags, Broadcast Wave), so a consumer
        /// that catalogs pictures and movies can drop them without naming them.
        /// ``riffRecording`` is not one: RIFF also carries AVI video.
        public var isAudioOnly: Bool {
            switch self {
            case .id3Recording, .waveOrigination: true
            default: false
            }
        }
    }

    /// The timestamp a role names, or `nil` when the file does not express it.
    ///
    /// The library still picks no winner: this lets a caller walk its own precedence —
    /// `[.original, .digitized, .quickTimeCreation].lazy.compactMap { timestamps[$0] }` —
    /// rather than re-deriving which field is which.
    public subscript(role: Role) -> CaptureTime? {
        switch role {
        case .original: original
        case .digitized: digitized
        case .tiffDateTime: tiffDateTime
        case .gps: gps
        case .quickTimeCreation: quickTimeCreation
        case .quickTimeLocation: quickTimeLocation
        case .quickTimeContentCreate: quickTimeContentCreate
        case .containerCreation: containerCreation
        case .id3Recording: id3Recording
        case .waveOrigination: waveOrigination
        case .riffRecording: riffRecording
        }
    }

    /// Every present timestamp with the role it came from, in field order.
    public var entries: [(role: Role, time: CaptureTime)] {
        Role.allCases.compactMap { role in self[role].map { (role, $0) } }
    }

    /// The timestamps `entries` lists, put back by role: the inverse of ``entries``, so a
    /// caller that stored them can ask this value's own selections (``captureWallClock``,
    /// ``captureInstant``) again rather than restating them. A role given more than once
    /// keeps its first entry.
    public init(entries: [(role: Role, time: CaptureTime)]) {
        var byRole: [Role: CaptureTime] = [:]
        for entry in entries where byRole[entry.role] == nil {
            byRole[entry.role] = entry.time
        }
        self.init(
            original: byRole[.original],
            digitized: byRole[.digitized],
            tiffDateTime: byRole[.tiffDateTime],
            gps: byRole[.gps],
            quickTimeCreation: byRole[.quickTimeCreation],
            quickTimeLocation: byRole[.quickTimeLocation],
            quickTimeContentCreate: byRole[.quickTimeContentCreate],
            containerCreation: byRole[.containerCreation],
            id3Recording: byRole[.id3Recording],
            waveOrigination: byRole[.waveOrigination],
            riffRecording: byRole[.riffRecording]
        )
    }

    /// All present timestamps in declared order, for callers that want to scan them.
    /// ``entries`` carries the same values with their roles attached.
    public var all: [CaptureTime] {
        entries.map(\.time)
    }
}

// MARK: - Opinionated selections

extension CaptureTimestamps {
    /// A timestamp the library chose for a stated purpose, and the role it came from — so
    /// a choice is always explainable and every other field stays available beside it.
    public struct Selection: Equatable, Sendable {
        public let role: Role
        public let time: CaptureTime
    }

    /// Roles consulted for ``captureWallClock``, most trustworthy first.
    ///
    /// Camera clocks first (Exif original, then digitized), then the movie's own capture
    /// date, then container-specific recording dates. Deliberately absent: TIFF `DateTime`
    /// (a modification time, rewritten by editors), the QuickTime location fix time, GPS
    /// (UTC by specification), and the container `creation_time` (often unmarked local time
    /// that claims to be UTC). Only candidates with capture-local components qualify, so a
    /// UTC-anchored value can never become a local wall clock.
    public static let wallClockPrecedence: [Role] = [
        .original, .digitized, .quickTimeCreation, .quickTimeContentCreate,
        .riffRecording, .waveOrigination, .id3Recording,
    ]

    /// Roles consulted for ``captureInstant``, most trustworthy first.
    ///
    /// The same camera-clock order as ``wallClockPrecedence``, so when the wall clock's
    /// role also pins an instant the two answers agree, then GPS, whose UTC is exact but is
    /// the time of the position fix. The container `creation_time` is excluded for the
    /// reason given there; it stays on ``containerCreation`` for a caller that accepts it.
    public static let instantPrecedence: [Role] = [
        .original, .digitized, .quickTimeCreation, .quickTimeContentCreate,
        .gps, .riffRecording, .waveOrigination, .id3Recording,
    ]

    /// The local wall clock when and where the item was captured: what to name, folder and
    /// label it by ("taken 14:51 on 25 April").
    ///
    /// The first role in ``wallClockPrecedence`` whose time has
    /// ``CaptureTime/captureLocalComponents`` — a floating or offset-bearing local time.
    /// `nil` when the file records none, which is an answer, not a failure: absent a local
    /// clock, any wall clock would be a guess about the capture zone.
    public var captureWallClock: Selection? {
        Self.wallClockPrecedence.lazy
            .compactMap { role in self[role].map { Selection(role: role, time: $0) } }
            .first { $0.time.captureLocalComponents != nil }
    }

    /// The absolute moment of capture: what to sort, deduplicate, or compare across zones by.
    ///
    /// The first role in ``instantPrecedence`` whose time has an ``CaptureTime/instant``.
    /// This can be a different role from ``captureWallClock``: a floating Exif original pins
    /// the wall clock but not the instant, which then comes from a later role if one has it.
    public var captureInstant: Selection? {
        Self.instantPrecedence.lazy
            .compactMap { role in self[role].map { Selection(role: role, time: $0) } }
            .first { $0.time.instant != nil }
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

    /// Names each field of ``CaptureLocations``. Raw values are the field names and are
    /// stable, so they are safe to store.
    public enum Source: String, Equatable, Hashable, Sendable, CaseIterable {
        case exifGPS
        case quickTime
        case sonyNRTM
    }

    /// The location a source reports, or `nil` when the file does not carry it.
    public subscript(source: Source) -> GeoLocation? {
        switch source {
        case .exifGPS: exifGPS
        case .quickTime: quickTime
        case .sonyNRTM: sonyNRTM
        }
    }

    /// Every present location with its source, in field order (which carries no preference).
    public var entries: [(source: Source, location: GeoLocation)] {
        Source.allCases.compactMap { source in self[source].map { (source, $0) } }
    }

    /// All present locations, for callers that want to scan rather than name a
    /// source. The order is field-declaration order and carries no preference.
    public var all: [GeoLocation] {
        entries.map(\.location)
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

/// The capturing device's identity. These values are terminal free text and stay `String`.
public struct Camera: Equatable, Sendable {
    public let make: String?
    public let model: String?
    public let lensModel: String?
    public let serialNumber: String?

    public init(
        make: String? = nil,
        model: String? = nil,
        lensModel: String? = nil,
        serialNumber: String? = nil
    ) {
        self.make = make
        self.model = model
        self.lensModel = lensModel
        self.serialNumber = serialNumber
    }
}

extension Camera {
    /// `nil` when the file names no device at all.
    init?(_ camera: CameraMetadata) {
        guard camera.make != nil || camera.model != nil
            || camera.lensModel != nil || camera.serialNumber != nil else {
            return nil
        }
        self.init(
            make: camera.make,
            model: camera.model,
            lensModel: camera.lensModel,
            serialNumber: camera.serialNumber
        )
    }
}

/// How big the picture is and which way up it goes — for a still or a movie.
///
/// ``pixelWidth`` and ``pixelHeight`` are the **stored** size, before ``orientation`` is
/// applied, which is how every source records them: Exif, HEIF `ispe`, and a QuickTime
/// track header all describe the encoded raster. The display size is one rule away from
/// that, and ``displayPixelWidth``/``displayPixelHeight`` apply it so a consumer laying out
/// a grid does not have to.
///
/// ``orientation`` comes from whichever source the container uses: the Exif tag, HEIF
/// `irot`/`imir` transform properties (which take precedence, as HEIF readers apply them),
/// or a movie track's transformation matrix. `nil` means the file says nothing about it,
/// which is different from ``Orientation/up`` — a movie whose track matrix is the
/// identity *does* say it is upright.
public struct PixelGeometry: Equatable, Sendable {
    /// Stored (encoded) width in pixels.
    public let pixelWidth: Int?
    /// Stored (encoded) height in pixels.
    public let pixelHeight: Int?
    /// How the stored raster must be transformed for display.
    public let orientation: Orientation?

    public init(pixelWidth: Int? = nil, pixelHeight: Int? = nil, orientation: Orientation? = nil) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
    }

    /// Width as displayed: the stored height when ``orientation`` turns the picture a
    /// quarter, otherwise the stored width. An absent orientation is treated as upright.
    public var displayPixelWidth: Int? {
        (orientation?.swapsDimensions ?? false) ? pixelHeight : pixelWidth
    }

    /// Height as displayed; see ``displayPixelWidth``.
    public var displayPixelHeight: Int? {
        (orientation?.swapsDimensions ?? false) ? pixelWidth : pixelHeight
    }
}

extension PixelGeometry {
    /// `nil` when the file states neither a size nor an orientation.
    init?(_ camera: CameraMetadata) {
        guard camera.pixelWidth != nil || camera.pixelHeight != nil || camera.orientation != nil else {
            return nil
        }
        self.init(
            pixelWidth: camera.pixelWidth,
            pixelHeight: camera.pixelHeight,
            orientation: camera.orientation.flatMap(Orientation.init(rawValue:))
        )
    }
}

/// Display orientation, expressed in the vocabulary of the Exif `Orientation` tag
/// (TIFF 0x0112): how the stored raster must be rotated and/or mirrored to be shown upright.
///
/// The Exif encoding is the lingua franca every image API understands (ImageIO's
/// `kCGImagePropertyOrientation`, `UIImage.Orientation` after mapping, libheif), so
/// orientation from other sources — HEIF transform properties, a movie track matrix — is
/// translated into it rather than given a vocabulary of its own.
public enum Orientation: Int, Equatable, Sendable, CaseIterable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8

    /// `true` for the four orientations (5–8) that turn the picture a quarter, so the
    /// displayed width is the stored height and vice versa.
    public var swapsDimensions: Bool {
        rawValue >= 5
    }

    /// `true` for the four orientations that include a mirror (2, 4, 5, 7).
    public var isMirrored: Bool {
        switch self {
        case .upMirrored, .downMirrored, .leftMirrored, .rightMirrored: true
        case .up, .down, .left, .right: false
        }
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
public enum VideoCodec: Equatable, Hashable, Sendable, CustomStringConvertible {
    case h264
    case hevc
    case proRes
    case av1
    case vp9
    case motionJPEG
    /// Any codec not in the known set; carries the original four-character code.
    case other(fourCC: String)

    /// A stable string for storing or logging the codec, round-trippable through
    /// ``init(identifier:)``: the case name for a known codec (`"h264"`, `"proRes"`, …) and
    /// `"other:"` plus the four-character code otherwise. Prefer this to
    /// `String(describing:)`, whose spelling for ``other(fourCC:)`` is not a promise.
    public var identifier: String {
        switch self {
        case .h264: "h264"
        case .hevc: "hevc"
        case .proRes: "proRes"
        case .av1: "av1"
        case .vp9: "vp9"
        case .motionJPEG: "motionJPEG"
        case let .other(fourCC): "other:\(fourCC)"
        }
    }

    /// Rebuilds a codec from ``identifier``, or returns `nil` for a string it never produces.
    public init?(identifier: String) {
        switch identifier {
        case "h264": self = .h264
        case "hevc": self = .hevc
        case "proRes": self = .proRes
        case "av1": self = .av1
        case "vp9": self = .vp9
        case "motionJPEG": self = .motionJPEG
        default:
            guard identifier.hasPrefix("other:") else {
                return nil
            }
            self = .other(fourCC: String(identifier.dropFirst("other:".count)))
        }
    }

    /// Same as ``identifier``.
    public var description: String {
        identifier
    }

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
            transportReadCount: metrics.transportReadCount,
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


/// Where an embedded image lives inside the container — never its bytes.
///
/// Extracting the JPEG a RAW file embeds is one of the most common things anyone does with
/// these containers, and finding it means walking the IFD chain: format knowledge, which is
/// this package's job, and which every consumer would otherwise reimplement. Decoding it is
/// not: "generate thumbnails" and "decode pixels" are non-goals, and decoding would drag in
/// a graphics framework this package deliberately does not link.
///
/// So the answer is a descriptor. A consumer reads ``byteOffset``/``byteLength`` through its
/// own transport — which may be the thing that makes this worth doing at all, since one
/// ranged read of a few hundred kilobytes can replace a multi-megabyte download — and
/// decodes with whatever it likes.
///
/// The range is bounds-checked against the resource size, which is free, but its bytes are
/// **not** read: over a high-latency transport each preview sits far from the metadata
/// region, so confirming a marker would cost a round trip per preview to prove something
/// the consumer establishes anyway the moment it decodes the bytes it fetched. Treat a
/// descriptor as a declaration and let the decoder be the check. For the same reason the
/// declared dimensions are often absent (Sony's ARW omits them); previews are ordered by
/// byte length, which is always known and tracks image size closely.
public struct EmbeddedPreview: Equatable, Sendable {
    /// Encoding the container declares for the embedded image.
    public enum Encoding: Equatable, Sendable {
        case jpeg
        case other(String)
    }

    /// Absolute offset of the image within the resource.
    public let byteOffset: UInt64
    /// Length of the image in bytes.
    public let byteLength: Int
    /// Declared width, when the container states one.
    public let pixelWidth: Int?
    /// Declared height, when the container states one.
    public let pixelHeight: Int?
    /// What the container says the bytes at ``byteOffset`` are.
    public let encoding: Encoding
    /// Where in the container this preview was declared, e.g. `tiff.ifd1`.
    public let sourcePath: String

    public init(
        byteOffset: UInt64,
        byteLength: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        encoding: Encoding = .jpeg,
        sourcePath: String = ""
    ) {
        self.byteOffset = byteOffset
        self.byteLength = byteLength
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.encoding = encoding
        self.sourcePath = sourcePath
    }
}

extension EmbeddedPreview {
    init(_ raw: RawEmbeddedPreview) {
        self.init(
            byteOffset: raw.byteOffset,
            byteLength: raw.byteLength,
            pixelWidth: raw.pixelWidth,
            pixelHeight: raw.pixelHeight,
            encoding: raw.encoding == "jpeg" ? .jpeg : .other(raw.encoding),
            sourcePath: raw.sourcePath
        )
    }
}
