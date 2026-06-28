# MediaMetadata Architecture

This document is the package design contract: intent, public model principles,
parser architecture, fixture policy, and engineering guardrails. It is preserved
here so the README can stay focused on consumers.

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
evidence, not substituted for it. This evidence model is **internal**: the public
contract is a fixed, fully typed field set derived from it.

## Public Model Principles

The library does all byte-parsing and returns a fixed, strongly-typed field set.
Callers never see raw metadata strings, JSON, or a candidate list — and the
library never resolves a single "best date." Each capture/creation timestamp is
exposed as its own named, typed field.

Public top-level shape (`Sources/MediaMetadata/MediaMetadataResult.swift`):

```swift
public struct MediaMetadataResult {
    let outcome: ReadOutcome          // .parsed / .unsupported (definitive) | .readFailure (transient)
    let format: MediaFormat           // family, extension, brand, magic-byte detection
    let timestamps: CaptureTimestamps // one named CaptureTime? per source (original, gps, containerCreation, …)
    let locations: [GeoLocation]      // every embedded location, each tagged with a LocationSource (no best-pick)
    let camera: Camera?               // make/model/lens/serial (text), Orientation enum, Int dimensions
    let video: VideoInfo?             // durationSeconds, frameRate, VideoCodec
}
```

- `ReadOutcome` is the definitive-vs-transient signal: `.parsed`/`.unsupported`
  are definitive (`isDefinitive == true` — record and stop); `.readFailure` is
  transient (`shouldRetry == true` — the bytes could not be read).
- `CaptureTime` carries calendar fields, an optional `utcOffsetSeconds`, an
  absolute `instant` when computable, and a `precision`
  (`localWithOffset` / `localFloating` / `absolute`) — expression and meaning
  preserved separately, never collapsed to a bare `Date`.
- `VideoCodec` is an enum (`h264`, `hevc`, `proRes`, …) with an `.other(fourCC:)`
  fallback so the open-ended codec set stays lossless yet typed.

The internal evidence graph still exists and is the source of truth for the typed
projection. It is reachable in-process via `MediaMetadataReader.extract(url:)`
(internal, exercised by tests) and is **not** part of the public surface:

- `ParsedMetadata`: detected format, evidence findings, normalized candidates,
  diagnostics, parser provenance, raw video facts, and read metrics.
- `MetadataFinding`: namespace, key, raw value, parser, container path, and byte
  range when known.
- `CaptureTimestampCandidate`: original text, parsed `Date`, offset, authority,
  and source evidence IDs.
- `CaptureLocationCandidate`, `CameraMetadata`, `MetadataDiagnostic`,
  `ParserProvenance`, `MediaMetadataReadMetrics`.

The internal model never hides the candidate list; the public projection buckets
each candidate into its named field (first wins) without discarding the evidence
that produced it.

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

The canonical local corpus contains 16 media files. Byte-identical imports are
deduplicated before test wiring. Twelve files are committed; three public
DJI/GoPro samples are downloaded from recorded sources and verified by size and
SHA-256; one legacy `apple.mov` fixture remains a manual rights-reviewed local
prerequisite. Local golden runs require the full corpus and fail when it is
incomplete. CI must not acquire the corpus implicitly.

ExifTool evidence is stored in both grouped numeric JSON and ordered group/tag
form. Generation fixes locale and timezone, records the tool version and exact
arguments, and must be deterministic. A separate reviewed semantic manifest
maps only relevant evidence into `FormatIdentity`, findings, timestamp and
location candidates, `CameraMetadata`, diagnostics, provenance, and bounded
read expectations. Regenerating raw ExifTool output never silently rewrites the
semantic contract.

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
