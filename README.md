# MediaMetadata

A Swift-native, platform-neutral package for extracting metadata from media
files — provenance-preserving timestamp, location, and camera-identity evidence
from container bytes, not from framework dictionaries.

This document is the package contract: intent, public model principles, parser
architecture, format roadmap, and engineering guardrails.

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

## Format Roadmap

### Phase 0: Repo And Contract

- Define public result models and diagnostics.
- Add byte readers, fixture tooling, CI on macOS and Linux, and golden-record
  comparison scripts.
- Add a tiny CLI for local inspection, e.g. `media-metadata inspect file`.

### Phase 1: TIFF And EXIF Core

- Direct TIFF/IFD EXIF timestamp and offset parsing. **Status:** exists.
- Generalize into a direct TIFF/IFD reader that can parse EXIF and GPS IFDs.
  **Status:** EXIF timestamp IFD parsing exists; GPS IFD parsing remains future
  work.
- Cover `tiff`, `tif`, `dng`, and TIFF-like RAW cases where EXIF IFDs are
  directly reachable.
- Preserve the Sony ARW `OffsetTimeOriginal` case that motivated native package
  work.

This is the first implementation phase because it starts from bytes, fixes a
real correctness issue, and avoids inheriting framework-shaped metadata APIs.

### Phase 2: ISO BMFF Core

- Shared ISO BMFF box reader.
- MP4/MOV parser behind that box reader. **Status:** exists.
- QuickTime creation dates, Apple keys, user data, GPS ISO 6709, Sony NRTM XML,
  and Sony USMT timezone data. **Status:** native ISO BMFF parsing covers these
  timestamp, location, and timezone evidence surfaces.
- HEIF/HEIC/HIF/AVCI/AVCS EXIF item extraction on the same box-walking
  foundation. **Status:** native HEIF item-info/item-location EXIF extraction
  feeds the shared TIFF/EXIF parser.

HEIF/HEIC and MP4/MOV share infrastructure. They differ in metadata
conventions, but both need disciplined box walking and item/property resolution.

### Phase 3: Still Image Containers

- JPEG APP1 EXIF extraction. **Status:** exists; reuses the TIFF parser at the
  EXIF TIFF base offset.
- PNG `eXIf` extraction.
- WebP `EXIF` extraction.
- Basic dimensions/orientation when available from metadata, without decoding
  image content.

### Phase 4: Audio And RIFF

- MP3 ID3v2 timestamp, artist/album/title, and recording-date fields.
  **Status:** ID3v2 recording-date timestamp fields such as `TDRC` and older
  `TYER`/`TDAT`/`TIME` parse into timestamp candidates.
- WAV/RIFF and Broadcast WAV metadata. **Status:** WAV `LIST/INFO` and Broadcast
  WAV origination date/time parse into timestamp candidates.
- AVI RIFF/INFO timestamp extraction. **Status:** AVI `LIST/INFO` date chunks
  such as `ICRD` and `IDIT` are parsed into local-without-offset timestamp
  candidates, AVI media payload lists such as `LIST/movi` are skipped instead of
  scanned as metadata, and AVI files without embedded date chunks emit an
  `aviMissingEmbeddedDate` diagnostic.
- AAC container handling where it overlaps ISO BMFF.

### Phase 5: Broader Containers

- Matroska/WebM.
- ASF/WMV if real fixtures justify it.
- Cinema/camera-specific formats such as BRAW, R3D, and ARI are fixture-driven
  research items, not early promises.

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

## Open Questions

- Should the package ship a tagged 1.0 immediately, or stay on `main` until a
  second consumer validates the public model?
- What is the minimum normalized schema before the model is considered stable?
- How much raw tag surface is useful before it becomes an unbounded inspector?
- Should fixture files live in Git LFS, release assets, or a bootstrap script?
