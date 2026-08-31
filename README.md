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
    .package(url: "https://github.com/tonimelisma/MediaMetadata.git", from: "0.5.0"),
]
```

Then add `MediaMetadata` to your target's dependencies.

### Requirements

Swift 6 language mode. The package is value types and synchronous parsing, so strict
concurrency costs it nothing — and it means the execution contract above is checked by the
compiler rather than promised in prose.

### Platforms

- macOS 13+
- iOS 16+
- tvOS 16+
- watchOS 9+
- visionOS 1+

The package depends only on `Foundation` and builds on Apple platforms and on
Linux.

## Reading from somewhere that is not a file

`read(url:)` is a convenience over `read(source:filenameHint:)`. Bytes that have no
file URL — a camera object reachable only over MTP, a zip member, an HTTP range
reader, an in-memory buffer — go through the source entry point instead.

```swift
let result = MediaMetadataReader.read(source: myByteSource, filenameHint: "DSC00001.arw")
print(result.readCost.readOperationCount, result.readCost.uniqueBytesRead)
```

Implementing `MediaByteSource` is three members, but one of them carries the contract
that matters:

```swift
public protocol MediaByteSource {
    var size: UInt64 { get }
    func data(offset: UInt64, length: Int) throws -> Data?
    func close()
}
```

A read has **three** outcomes, and conflating two of them is the mistake this shape
exists to prevent:

| Situation | Result |
| --- | --- |
| Fully in-bounds range, every byte delivered | `Data` of exactly `length` |
| Range extends past `size` | `nil` |
| Fully in-bounds range that did not deliver `length` bytes | `throw` |

`nil` means *the file ends there* — a structural fact a parser expects and handles.
Throwing means *the transport could not answer* — and anything thrown makes the result
`.readFailure`, so a caller retries instead of recording "this file has no capture
date" about a file nobody managed to read. Consumers cache definitive answers, so
getting this wrong writes a wrong answer that is never revisited.

### Execution contract

- Parsing is **synchronous**, and a source **may block the calling thread** for as long
  as the transport takes. Run parses off the main thread, and off any actor whose own
  progress the read depends on.
- A source is **confined to a single `read(source:)` call**. It must not escape that
  call, be stored beyond it, or be used concurrently. That confinement is what lets a
  conformance hold non-`Sendable` transport state without an unsafe escape hatch.

### Making remote reads affordable

A parse is directed but fine-grained: it reads a container's index, then reads individual
fields inside it. Measured on a 991-file corpus, that is 138 reads totalling 1,533 bytes
inside a single 100 KB region for HEIF, and 21 reads for 1,155 bytes inside 44 KB for TIFF.

**The package now buffers that internally**, so those collapse into one or two reads of your
source without you doing anything. `readCost` reports both numbers:

```swift
result.readCost.readOperationCount   // what the parsers asked for
result.readCost.transportReadCount   // what your source was actually asked to do
```

A large gap means the buffering is working. A ratio near 1 on a remote source means the
container's metadata is genuinely far apart, and that is the case for adding a second,
larger buffer sized to your own round-trip cost:

```swift
let cached = CachingByteSource(wrapping: mySlowSource, chunkSize: 128 * 1024)
let result = MediaMetadataReader.read(source: cached, filenameHint: name)
```

The chunk size is yours — it depends on latency and per-request overhead this package
cannot see. Local files need none of this; the internal buffer plus the page cache already
make them cheap.

### Embedded previews

RAW containers declare where their embedded JPEG lives. The package reports *where*, and
never the bytes:

```swift
if let preview = result.previews.first {   // largest first
    // fetch preview.byteOffset ..< +preview.byteLength through your own transport,
    // then decode it with whatever you like.
}
```

The declared range is verified before it is reported — its leading bytes must be the
codec's marker — so a descriptor is a checked fact rather than a claim. Decoding is
deliberately not offered: "generate thumbnails" and "decode pixels" are non-goals, and
doing either would mean linking a graphics framework.

This matters most where ImageIO cannot help: it refuses a truncated RAW outright, so a
consumer holding only a prefix of an ARW has no way to reach the preview without this.
HEIF needs nothing here — ImageIO parses a HEIF prefix happily.

### Identifying without parsing

```swift
let format = MediaMetadataReader.identify(source: source, filenameHint: name)
```

One read of at most 12 bytes. Useful for triaging a directory of unknown files, and for
confirming a transport returned the file you asked for before spending a parse on it.

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
// Use `captureLocalComponents` for capture-local naming; it is nil for absolute
// (UTC-anchored) timestamps so they cannot be mistaken for local wall clock.
if let original = result.timestamps.original {
    print(original.year, original.month, original.day, original.hour, original.minute, original.second)
    print(original.utcOffsetSeconds ?? -1, original.instant ?? .distantPast, original.precision)
    if let local = original.captureLocalComponents {
        print(local.year, local.month, local.day, local.hour, local.minute, local.second)
    }
}
if let gps = result.timestamps.gps {
    print(gps.instant ?? .distantPast) // UTC-anchored; captureLocalComponents is nil
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
| RIFF AVI | ✅ | ✅ | — | — | ✅ | `LIST.INFO` `ICRD` / `IDIT`; `avih`/`strh` duration, frame rate, codec |
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
