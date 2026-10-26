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
    .package(url: "https://github.com/tonimelisma/MediaMetadata.git", from: "0.8.0"),
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

Previews are ordered **largest first by byte length**, because declared dimensions are
often absent — Sony's ARW omits them in exactly the directories that carry previews, so
`pixelWidth`/`pixelHeight` are frequently nil. **Do not require them**: pick by
`byteLength` and let the decode tell you the real size.

The range is bounds-checked but its bytes are **not** read to verify it. Doing so cost two
extra round trips per RAW file over MTP — ~130 s across a 991-item card — to prove
something you establish for free the moment you decode. A descriptor that does not decode
is a case you already handle.

Decoding is deliberately not offered: "generate thumbnails" and "decode pixels" are
non-goals, and doing either would mean linking a graphics framework.

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
import Foundation
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

// Detected container family (.tiff, .jpeg, .heif, .png, .webp, .gif, .isoBMFF,
// .riffWAV, .riffAVI, .id3, .unknown) and what it holds — decided from structure, so an AVIF is an
// .image and an MP4 is a .video even though both are ISO BMFF.
print(result.format.family, result.format.kind, result.format.brand ?? "")

// The file type a person would name — from the bytes, so a Sony RAW is .arw though
// its family is .tiff, and a QuickTime movie is .mov whatever its extension says.
// Before anything has read a file, MediaFileType(fileExtension:) labels it by name,
// folding spellings together (jpg/jpe/jpeg → .jpeg, heic/heif/hif → .heif).
if let type = result.format.fileType {
    print(type.displayName, result.format.isCameraRaw) // "ARW true"
}

// The two dates most callers want, each for its own purpose, with the role it came
// from. There is no single "best date": the local time a photo was taken (to name or
// folder it) and the instant it was taken (to sort it) are different questions.
if let wall = result.timestamps.captureWallClock,
   let local = wall.time.captureLocalComponents {
    print("taken", local.year, local.month, local.day, "per", wall.role) // e.g. .original
}
if let moment = result.timestamps.captureInstant, let instant = moment.time.instant {
    print("sort by", instant, "per", moment.role) // instant is always set on this selection
}

// Every capture/creation date is also its own strongly typed field, keyed by a
// stable Role for callers with their own policy. Each CaptureTime carries calendar fields, an optional
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
for (role, time) in result.timestamps.entries { print(role.rawValue, time.precision) }
let myOrder: [CaptureTimestamps.Role] = [.digitized, .original]
let mine = myOrder.lazy.compactMap { result.timestamps[$0] }.first

// Each capture location is its own named field by source — no array, no order,
// no single "best" pick. Pick the source you trust, or scan `entries`.
if let exif = result.locations.exifGPS {
    print(exif.latitude, exif.longitude, exif.altitudeMeters ?? 0)
}
if let quickTime = result.locations.quickTime { print(quickTime.latitude, quickTime.longitude) }
for (source, location) in result.locations.entries { print(source, location.latitude) }

// Device identity — nil when the file names no device.
if let camera = result.camera {
    print(camera.make ?? "", camera.model ?? "", camera.lensModel ?? "")
}

// Size and orientation, for stills and movies. pixelWidth/Height are the stored
// raster; the display size has already had the quarter-turn rule applied, so a
// portrait iPhone photo (or video) lays out as portrait.
if let geometry = result.geometry {
    print(geometry.pixelWidth ?? 0, geometry.pixelHeight ?? 0, geometry.orientation ?? Orientation.up)
    print(geometry.displayPixelWidth ?? 0, geometry.displayPixelHeight ?? 0)
}

// Video specifics.
if let video = result.video {
    print(video.durationSeconds ?? 0, video.frameRate ?? 0, video.codec?.identifier ?? "") // "hevc"
}

// Persisting results? Store the revision of the row's family beside it. A lower stored
// number means a re-read *may* now give a different answer — not that one is due: re-read
// when the bytes are cheap to reach (a local file), and remember that re-reading a cloud
// placeholder or a remote file means downloading it.
print(MediaMetadataReader.extractionRevision(for: result.format.family))
```

Every call returns a complete, fully typed result — the library performs all
byte-parsing itself and never throws, never hands back raw metadata strings or
JSON. When a file cannot be read the result is `.readFailure` (retry); when its
signature is not handled it is `.unsupported` (definitive); otherwise it is
`.parsed` with the typed fields populated.

## Migrating from 0.6

0.7.0 reshapes the result around what callers actually do with it. The changes a
compiler will point at:

| 0.6 | 0.7 |
|---|---|
| `result.camera?.orientation` / `pixelWidth` / `pixelHeight` | `result.geometry?.orientation` / `pixelWidth` / `pixelHeight` |
| `result.camera` non-nil for any file with dimensions | `result.camera` is identity only, `nil` when no device is named |
| `Camera(make:…orientation:pixelWidth:pixelHeight:)` | `Camera(make:model:lensModel:serialNumber:)` + `PixelGeometry(…)` |
| `String(describing: codec)` | `codec.identifier` (round-trips via `VideoCodec(identifier:)`) |

Behaviour that changes for the same bytes. Each family's
`extractionRevision(for:)` records which of these apply to it, so a consumer can
re-read just the affected rows, and only where their bytes are already at hand:

- Movies report orientation from their track matrix, so portrait phone videos are
  `.right` with a portrait display size; an unrotated movie is `.up`, not `nil`.
- AVIF (and other MIAF brands) report the `.heif` family rather than `.isoBMFF`.
- `format.kind` is new; prefer it to inferring still/movie from the family.

0.7.1 adds `format.fileType` and `isCameraRaw` (camera RAW recognised from the
bytes, without reading past what a parse already reads), `MediaFileType(fileExtension:)`,
`Role.isAudioOnly`, and per-family revisions. Canon CR3 is now a still rather than a
movie, and Fujifilm RAF, Olympus ORF and Panasonic RW2 are recognised as stills (they
remain unsupported for metadata). `fileType` is a new field, so no revision moves for
it: rows from before it can be labelled with `MediaFileType(fileExtension:)` until they
are next read, and only TIFF-family rows need their bytes to tell a RAW from a TIFF.

## Migrating to 0.8

0.8.0 reads PNG, WebP and GIF from their bytes. Each is a family of its own —
`MediaFormat.Family` gains `.png`, `.webp` and `.gif` — so an exhaustive `switch` over
`Family` no longer compiles until it handles them (or adds a `default`). All three are
`.image`, with `fileType` `.png`, `.webp` and `.gif`.

Behaviour that changes for the same bytes: these files were `.unknown` and
`.unsupported` with no `fileType`; they are now `.parsed`, with the stored size from the
container header (PNG `IHDR`, WebP `VP8X`/`VP8 `/`VP8L`, GIF logical screen) and, for
PNG `eXIf` and WebP `EXIF`, orientation, dates, camera and GPS. That is why
`extractionRevision(for: .unknown)` rises to 2: a stored `.unknown` row may now read as
one of the new families. The new families start at revision 0.

`identify(source:filenameHint:)` now decides RIFF by its form type: `AVI ` is
`.riffAVI`, `WAVE` is `.riffWAV`, `WEBP` is `.webp`, and any other form type is
`.unknown` (previously every RIFF file identified as `.riffAVI`). Because the form type
proves the type, `identify` now also reports `fileType` `.avi` and `.wav`. A full read of
AVI and WAV is unchanged.


## Supported Formats

| Format | Detection | Timestamps | Location | Camera | Video | Notes |
|---|---|---|---|---|---|---|
| TIFF / RAW | ✅ | ✅ | ✅ | ✅ | — | EXIF date, GPS, camera, lens, orientation, dimensions, embedded previews; DNG, CR2, ARW, NEF, PEF, SRW recognised from IFD0 |
| CR3 | ✅ | — | — | — | — | Recognised from its `crx ` brand as a still; metadata not yet parsed |
| RAF, ORF, RW2 | ✅ | — | — | — | — | Recognised from their signature as stills; reported `.unsupported` |
| JPEG (EXIF) | ✅ | ✅ | ✅ | ✅ | — | APP1 EXIF segment |
| HEIF / AVIF | ✅ | ✅ | ✅ | ✅ | — | Embedded EXIF item; orientation from `irot`/`imir`; stored size from `ispe` |
| PNG | ✅ | ✅ | ✅ | ✅ | — | Size from `IHDR`; Exif from an `eXIf` chunk before `IDAT` (one after it is not read: the specification forbids it, and reaching it means walking the image data) |
| WebP | ✅ | ✅ | ✅ | ✅ | — | Size from the `VP8X` canvas or the `VP8 `/`VP8L` bitstream header; Exif from the `EXIF` chunk |
| GIF | ✅ | — | — | — | — | Logical screen size; GIF has no standard capture date |
| ISO BMFF (MP4 / MOV) | ✅ | ✅ | ✅ | ✅ | ✅ | QuickTime metadata, GoPro GPMF, Sony NRTM; duration, frame rate, codec; rotation from the track matrix |
| RIFF AVI | ✅ | ✅ | — | — | ✅ | `LIST.INFO` `ICRD` / `IDIT`; `avih`/`strh` duration, frame rate, codec |
| RIFF WAV | ✅ | ✅ | — | — | — | `LIST.INFO` `ICRD`, Broadcast Wave `bext` origination date |
| ID3v2 | ✅ | ✅ | — | — | — | `TDRC`, `TDOR`, legacy `TYER`/`TDAT`/`TIME` |
| Matroska, XMP | — | — | — | — | — | Not yet implemented |

## Design Philosophy

MediaMetadata answers one question:

> Given these bytes, what metadata claims can we prove are present, where is
> each claim stored, and how should a caller reason about it?

The library rejects framework-shaped shortcuts. Internally it builds a full
evidence graph — every finding with its byte range, provenance, and the candidate
list behind each value — and derives the public typed field set from it. Callers
consume only that typed field set: each timestamp is its own named, strongly typed
field, and timestamp expression is preserved separately from absolute instants.
Where format knowledge is what makes a choice right — which dates are capture
clocks, what orientation does to dimensions — the library makes it, names the
purpose, and shows its working (the chosen role) rather than hiding the evidence.

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
