# MediaMetadata

A Swift-native, platform-neutral package for extracting metadata from media
files — provenance-preserving timestamp, location, and camera-identity evidence
from container bytes, not from framework dictionaries.

This document is the package contract: intent, public model principles, parser
architecture, and engineering guardrails.

## Installation

MediaMetadata is a Swift Package Manager library. Add it to an Xcode project via
**File → Add Package Dependencies…** and paste the repository URL, or add it to a
`Package.swift` manifest:

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

The package depends only on `Foundation` and contains no AppKit, UIKit, ImageIO,
or AVFoundation references, so it compiles on every Apple platform and on Linux.

## Usage

Reading metadata is a single call returning a value type:

```swift
import MediaMetadata

let result = MediaMetadataReader.read(url: url)

// The detected container family, e.g. .tiff, .jpeg, .heif, .isoBMFF,
// .riffWAV, .riffAVI, .id3, or .unknown.
let family = result.identity.family

// Every parsed tag, with its namespace, key, raw value, parser, container path,
// and byte range when known. Never a flattened Apple-style dictionary.
for finding in result.findings where finding.key == "DateTimeOriginal" {
    print(finding.rawValue) // e.g. "2026:04:26 14:57:35"
}

// All capture-time candidates, preserving how each was expressed:
//   .localWithOffset, .localWithoutOffset, or .absoluteInstant.
// The package never picks one and discards the rest; the consumer decides
// which candidate is authoritative.
for candidate in result.timestamps {
    print(candidate.role, candidate.rawTimestamp, candidate.instant ?? "no instant")
    if let offset = candidate.offsetSeconds {
        print("  offset seconds: \(offset)")
    }
}

// GPS / capture locations, kept as separate candidates with their own evidence.
for location in result.locations {
    print(location.latitude, location.longitude, location.altitudeMeters ?? "no altitude")
}

// Camera identity (make, model, lens, orientation, dimensions) when present.
if let camera = result.camera {
    print(camera.make ?? "unknown make", camera.model ?? "unknown model")
}

// Non-fatal parse notes: truncated metadata, unsupported box, conflicting
// timestamps, missing embedded AVI dates, etc. Parsers fail closed; partial
// results carry diagnostics instead of throwing.
for diagnostic in result.diagnostics {
    print(diagnostic.code)
}
```

Every file read returns a complete result — never a throw. When a container is
truncated, malformed, or unsupported, the result carries partial findings plus
diagnostics explaining what could not be parsed.

## Product Intent

The package answers one question:

> Given these bytes, what metadata claims can we prove are present, where is each
> claim stored, and how should a caller reason about it?

Typical consumers need metadata for chronology, sorting, duplicate diagnostics,
and audit logs. The package does not decode, thumbnail, transcode, or perform
digital asset management.

The package should be useful to any Swift consumer that must reason about media
metadata from raw bytes. Source-timestamp correctness matters more than broad
tag novelty.

The core design is intentionally not shaped by ImageIO or AVFoundation. The
package model starts from file bytes, container structure, metadata evidence, and
explicit provenance.

## Non-Goals

- Decode pixels, video frames, or audio samples.
- Generate thumbnails.
- Transcode or rewrite media.
- Become a universal forensic inspector.
- Decide consumer policy such as which timestamp is trusted for library-path
  naming.
- Depend on AppKit, SwiftUI, ImageIO, AVFoundation, or platform APIs in the core
  target.

## Package Shape

A small SwiftPM package with a single runtime parser target:

- `MediaMetadata`: platform-neutral parsers, byte readers, normalized models,
  diagnostics, and format detection.
- `MediaMetadataTestSupport`: test-only helpers for fixtures, golden files, and
  parser evidence reports.

## First-Principles Constraints

The package rejects framework-shaped shortcuts:

- Do not model metadata as one flattened properties dictionary.
- Do not use Apple key names as the canonical schema.
- Do not treat framework-detected format as truth.
- Do not collapse a timestamp expression into a bare `Date`.
- Do not interpret a missing framework value as proof that the file lacks the tag.
- Do not read system timezone or locale from core parsing code.
- Do not select one "best" timestamp while discarding the candidates that explain
  the choice.

The central abstraction is evidence. Normalized metadata is derived from
evidence, not substituted for it.

## Public Model Principles

Return both normalized values and raw evidence.

Recommended top-level concepts:

- `MediaMetadataResult`: detected format, evidence findings, normalized
  candidates, diagnostics, and parser provenance.
- `FormatIdentity`: container family, codec-ish hints when cheaply available,
  extension observed, and magic-byte detection result.
- `MetadataFinding`: namespace, key, raw value, parsed primitive value when
  available, parser, container path, and byte range when known.
- `CaptureTimestampCandidate`: original text, parsed absolute `Date`, optional
  offset seconds, optional timezone identifier, authority, source evidence IDs,
  and confidence.
- `CaptureLocationCandidate`: latitude, longitude, optional altitude, original
  text, source evidence IDs, and confidence.
- `CameraMetadata`: make, model, lens, serial-ish fields, orientation,
  dimensions.
- `MetadataDiagnostic`: non-fatal parse notes such as truncated metadata,
  unsupported box, offset out of bounds, conflicting timestamps, or missing
  embedded AVI dates.

Timestamp modeling preserves expression and meaning separately:

- local timestamp with explicit offset
- local timestamp without offset
- absolute UTC/container timestamp
- GPS timestamp
- GPS-localized capture timestamp
- filesystem timestamp evidence supplied by the consuming app when embedded
  metadata is unavailable

The package can rank candidates, but it never hides the candidate list. The
consumer decides which candidate is authoritative for naming and UI.

Illustrative shape:

```swift
struct MediaMetadataResult {
    let identity: FormatIdentity
    let findings: [MetadataFinding]
    let timestamps: [CaptureTimestampCandidate]
    let locations: [CaptureLocationCandidate]
    let camera: CameraMetadata?
    let diagnostics: [MetadataDiagnostic]
}
```

## Parser Architecture

Parser layers, deliberately boring:

1. `ByteSource`: safe random-access reads over file handles and in-memory data.
2. `FormatProbe`: magic-byte and container-structure detection.
3. `ContainerParser`: TIFF, JPEG, PNG, WebP, ISO BMFF, RIFF, ID3, Matroska later.
4. `MetadataInterpreter`: EXIF, GPS, XMP, QuickTime keys/user data, ID3 frames,
   Broadcast WAV fields later.
5. `Normalizer`: raw findings to typed timestamp/location/camera candidates while
   preserving provenance.
6. `Resolver`: optional ranking helpers for consumers that want a default
   ordering, but never the only source of truth.

Every parser fails closed. Invalid offsets, oversized counts, truncated files,
and unknown atom/box/tag types produce partial metadata plus diagnostics, not
crashes.

## Golden Fixtures

Golden fixture records are used only in development and tests, never at runtime.
Golden records validate selected package behavior; they do not shape the runtime
architecture.

For each real fixture:

- Store the media file only when licensing, size, and privacy allow it.
- Store a generated metadata record with the command captured outside package
  runtime code.
- Store an ordered golden record for fields where ordering or repeated groups
  matter.
- Compare normalized package output against a selected fixture subset, not every
  observable field.
- Keep fixture provenance: source device, app/camera model, acquisition date,
  privacy review, and why the fixture exists.

Synthetic fixtures cover malformed data, edge offsets, conflicting tags, and
small examples that would be hard to obtain from real cameras.

## Engineering Guardrails

- No unbounded reads of large RAW/video files.
- No parser force unwraps.
- Cap metadata payload sizes.
- Cap recursion/nesting.
- Check integer overflow before offset arithmetic.
- Keep unknown tags in raw output when cheap.
- Prefer partial success with diagnostics over throwing away a whole file.
- Make parser performance visible with timings, read operation counts, unique
  bytes read, file-size coverage, highest byte offset touched, and an explicit
  whole-file-read flag so scans can prove metadata parsing is not reading media
  payload bytes unnecessarily. Parser implementations batch contiguous metadata
  table reads (such as TIFF IFD entries), skip payload bytes for metadata keys
  or frames the consumer does not consume, and stop walking a container once the
  parser has found decisive timestamp/location evidence for chronology.
- Keep fixtures small unless a real camera sample is necessary.
- Require tests for every promoted timestamp authority.
- Runtime timestamp selection must use package evidence or filesystem mtime
  authority only.
