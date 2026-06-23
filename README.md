# MediaMetadata

A Swift-native, framework-neutral package for extracting provenance-preserving
metadata from media file bytes. Get raw evidence, normalized timestamp and
location candidates, and parser diagnostics without touching ImageIO,
AVFoundation, AppKit, or UIKit.

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
    .package(url: "https://github.com/tonimelisma/MediaMetadata.git", from: "0.1.0"),
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

// Detected container family, e.g. .tiff, .jpeg, .heif, .isoBMFF,
// .riffWAV, .riffAVI, .id3, or .unknown.
print(result.identity.family)

// Every parsed tag, with its namespace, key, raw value, parser, source path,
// and byte range when known.
for finding in result.findings where finding.key == "DateTimeOriginal" {
    print(finding.rawValue) // e.g. "2026:04:26 14:57:35"
}

// Capture-time candidates preserving how each was expressed.
for candidate in result.timestamps {
    print(candidate.role, candidate.rawTimestamp, candidate.instant ?? "no instant")
    if let offset = candidate.offsetSeconds {
        print("  offset seconds: \(offset)")
    }
}

// GPS / capture location candidates.
for location in result.locations {
    print(location.latitude, location.longitude, location.altitudeMeters ?? "no altitude")
}

// Non-fatal parse notes: truncated metadata, unsupported boxes, conflicting
// timestamps, missing embedded dates, etc.
for diagnostic in result.diagnostics {
    print(diagnostic.code, diagnostic.message)
}
```

Every call returns a complete result — the library never throws. When a file is
truncated, malformed, or unsupported, the result carries partial findings plus
diagnostics explaining what could not be parsed.

## Supported Formats

| Format | Detection | Timestamps | Location | Camera | Notes |
|---|---|---|---|---|---|
| TIFF / RAW | ✅ | ✅ | ✅ | ✅ | EXIF date, GPS, camera, lens, orientation, dimensions |
| JPEG (EXIF) | ✅ | ✅ | ✅ | ✅ | APP1 EXIF segment |
| HEIF / ISO BMFF | ✅ | ✅ | ✅ | ✅ | Embedded EXIF, QuickTime metadata, GoPro GPMF, Sony NRTM |
| RIFF AVI | ✅ | ✅ | — | — | `LIST.INFO` `ICRD` / `IDIT` |
| RIFF WAV | ✅ | ✅ | — | — | `LIST.INFO` `ICRD`, Broadcast Wave `bext` origination date |
| ID3v2 | ✅ | ✅ | — | — | `TDRC`, `TDOR`, legacy `TYER`/`TDAT`/`TIME` |
| PNG, WebP, Matroska, XMP | — | — | — | — | Not yet implemented |

## Design Philosophy

MediaMetadata answers one question:

> Given these bytes, what metadata claims can we prove are present, where is
> each claim stored, and how should a caller reason about it?

The library rejects framework-shaped shortcuts. It returns raw findings
alongside normalized candidates, preserves timestamp expression separately from
absolute instants, and never discards evidence to pick a single "best" value.

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
