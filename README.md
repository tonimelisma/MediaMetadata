# MediaMetadata

A Swift-native, framework-neutral package for extracting media metadata from
file bytes. The library does all the byte-parsing and hands back a fixed,
strongly-typed field set — typed dates, location, camera, and video facts, plus a
definitive-vs-transient outcome — without touching ImageIO, AVFoundation, AppKit,
or UIKit.

> **Active Development** — MediaMetadata is under active development. APIs,
> supported formats, and data models may evolve. Issues, suggestions, and pull
> requests are welcome.

## Installation

MediaMetadata is distributed as a Swift Package Manager library.

### Xcode

Add it via **File → Add Package Dependencies…** and paste the repository URL:

```
https://github.com/tonimelisma/MediaMetadata.git
```

### Package.swift

```swift
dependencies: [
    .package(url: "https://github.com/tonimelisma/MediaMetadata.git", from: "0.2.0"),
]
```

Then add `MediaMetadata` to your target's dependencies.

### Platforms

- macOS 13+
- iOS 16+
- tvOS 16+
- watchOS 9+
- visionOS 1+

The package depends only on `Foundation` and builds on Apple platforms and on
Linux.

## Quick Start

```swift
import MediaMetadata

let result = MediaMetadataReader.read(url: url)

// Definitive vs transient. Record `.parsed`/`.unsupported` and move on;
// `.readFailure` means the bytes could not be read — safe to retry.
switch result.outcome {
case .parsed, .unsupported:
    print("definitive:", result.outcome.isDefinitive) // true
case .readFailure:
    print("retry:", result.outcome.shouldRetry)        // true
}

// Detected container family, e.g. .tiff, .jpeg, .heif, .isoBMFF,
// .riffWAV, .riffAVI, .id3, or .unknown.
print(result.format.family, result.format.brand ?? "")

// Every capture/creation date is its own strongly typed field — no raw strings,
// no "best date" guess. Each CaptureTime carries calendar fields, an optional
// UTC offset, an absolute `instant` when one can be computed, and a `precision`.
if let original = result.timestamps.original {
    print(original.year, original.month, original.day, original.hour, original.minute, original.second)
    print(original.utcOffsetSeconds ?? -1, original.instant ?? .distantPast, original.precision)
}
if let gps = result.timestamps.gps {
    print(gps.instant ?? .distantPast) // UTC-anchored
}
// Other named fields: digitized, tiffDateTime, containerCreation, quickTimeCreation,
// quickTimeLocation, quickTimeContentCreate, id3Recording, waveOrigination, riffRecording.

// Each capture location is its own named field by source — no array, no order,
// no single "best" pick. Pick the source you trust, or scan `all`.
if let exif = result.locations.exifGPS {
    print(exif.latitude, exif.longitude, exif.altitudeMeters ?? 0)
}
if let quickTime = result.locations.quickTime { print(quickTime.latitude, quickTime.longitude) }
for location in result.locations.all { print(location.latitude, location.longitude) }

// Camera/device. Identity stays text; orientation is an enum, dimensions are Int.
if let camera = result.camera {
    print(camera.make ?? "", camera.model ?? "", camera.orientation ?? .up)
    print(camera.pixelWidth ?? 0, camera.pixelHeight ?? 0)
}

// Video specifics.
if let video = result.video {
    print(video.durationSeconds ?? 0, video.frameRate ?? 0, video.codec ?? .other(fourCC: "????"))
}
```

Every call returns a complete, fully typed result — the library performs all
byte-parsing itself and never throws, never hands back raw metadata strings or
JSON. When a file cannot be read the result is `.readFailure` (retry); when its
signature is not handled it is `.unsupported` (definitive); otherwise it is
`.parsed` with the typed fields populated.

## Supported Formats

| Format | Detection | Timestamps | Location | Camera | Video | Notes |
|---|---|---|---|---|---|---|
| TIFF / RAW | ✅ | ✅ | ✅ | ✅ | — | EXIF date, GPS, camera, lens, orientation, dimensions |
| JPEG (EXIF) | ✅ | ✅ | ✅ | ✅ | — | APP1 EXIF segment |
| HEIF | ✅ | ✅ | ✅ | ✅ | — | Embedded EXIF item |
| ISO BMFF (MP4 / MOV) | ✅ | ✅ | ✅ | ✅ | ✅ | QuickTime metadata, GoPro GPMF, Sony NRTM; duration, frame rate, codec |
| RIFF AVI | ✅ | ✅ | — | — | — | `LIST.INFO` `ICRD` / `IDIT` |
| RIFF WAV | ✅ | ✅ | — | — | — | `LIST.INFO` `ICRD`, Broadcast Wave `bext` origination date |
| ID3v2 | ✅ | ✅ | — | — | — | `TDRC`, `TDOR`, legacy `TYER`/`TDAT`/`TIME` |
| PNG, WebP, Matroska, XMP | — | — | — | — | — | Not yet implemented |

## Design Philosophy

MediaMetadata answers one question:

> Given these bytes, what metadata claims can we prove are present, where is
> each claim stored, and how should a caller reason about it?

The library rejects framework-shaped shortcuts. Internally it builds a full
evidence graph — every finding with its byte range, provenance, and the candidate
list behind each value — and derives the public typed field set from it. Callers
consume only that typed field set: each timestamp is its own named, strongly typed
field (the library never collapses them into one "best" value), and timestamp
expression is preserved separately from absolute instants.

For the full architecture, product intent, parser design, fixture policy, and
engineering guardrails, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Development

```sh
Scripts/check-local-fixtures.sh
swift build
swift test
```

Tests use synthetic fixtures for malformed inputs and parser edge cases, plus a
required 16-file local corpus for ExifTool-backed semantic golden coverage. The
fixture check downloads three public samples when absent and requires the
rights-reviewed local `apple.mov`; it is intentionally a local prerequisite,
not a CI bootstrap step. See [Tests/Fixtures/README.md](Tests/Fixtures/README.md)
for provenance, privacy notes, and golden regeneration instructions.

## Contributing

Issues, suggestions, and pull requests are welcome. Please keep the existing
architectural principles in mind; see [ARCHITECTURE.md](ARCHITECTURE.md) for
details.

## License

MIT
