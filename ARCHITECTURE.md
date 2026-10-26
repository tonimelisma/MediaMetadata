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

## Consumer Boundary

The Non-Goals above say what the package will not do. This section says how to decide,
for a capability nobody has classified yet, which side of the line it falls on — and how
to keep the package useful to consumers it has never met.

**The package owns: "what do these bytes say, and what did it cost to find out?"**
Container indexes, where metadata lives, tag semantics, timestamp expression (UTC offset,
precision, floating versus absolute), format identity, embedded-resource *locations*,
byte-range accounting, and the definitive-versus-transient outcome. Every one of these is
derivable from bytes alone. None of them needs to know who is asking.

**The consumer owns: "which of those claims do I trust, and what did the bytes cost me?"**
Which timestamp wins for a given purpose, any derivation from other facts, dedupe and
identity, transport lifecycle, sessions, retries, deadlines, concurrency, thread policy,
cache sizing, and persistence schema.

**The seam is:** a byte range in, bytes out, plus an honest failure channel. Anything that
needs more than that from the consumer is probably consumer policy in disguise.

### The rule

> Every change must be justifiable to a second consumer who has never heard of the
> requesting application.

Not "would the requesting app benefit" — would a CLI date-extraction tool, a Linux ingest
service, or an unrelated gallery application benefit. Name that consumer in the issue. If
the only justification that can be written is "my app needs it", the capability belongs in
that app.

This rule has teeth in both directions. It rejects consumer policy arriving as a feature
request, and it also rejects *refusing* a genuinely general capability merely because one
consumer happens to be asking first.

### Two worked examples

**Caching is the package's, sizing is the consumer's.** A parse may issue many small reads
inside one region — measured at 138 reads over 1.5 KB for HEIF. That pattern is the
package's own, so mitigating it is the package's job, and it does so on both levels: an
internal buffer collapses a parse into one or two reads of whatever source it was given,
and `CachingByteSource` is offered for consumers whose transport wants a larger chunk than
the internal one. But the *chunk size* depends on transport latency the package cannot see,
so that is a parameter the consumer supplies.

Owning the mechanism and not the number is the correct split. Refusing the mechanism — which
an earlier draft did, on the grounds that sizing is a transport concern — would have made
every remote consumer reinvent a buffer for a read pattern they did not choose. `ReadCost`
reports both counts so the split stays honest: what the parsers asked for, and what the
source was actually made to do.

**Embedded previews are located here and decoded there.** Finding a RAW file's embedded
JPEG means walking the IFD chain — squarely this package's competence, and duplicated in
every consumer that has to do it alone. But "generate thumbnails" and "decode pixels" are
Non-Goals, and decoding would drag in a graphics framework. So the package reports a
*descriptor* — byte offset, length, declared dimensions, encoding — and the consumer reads
that range through its own transport and decodes with whatever it likes. Both Non-Goals
hold, the dependency rule holds, and the container knowledge lives where it belongs.

### The dependency rule that keeps this honest

The core target imports `Foundation` and nothing else. That is true today — every source
file, no exceptions — and it is what makes the package usable on Linux, in a CLI, in a
server, and in tests without a display. It is also the constraint that forces the right
answer whenever a "just use the system framework for this one case" shortcut appears: if a
capability cannot be expressed in `Foundation` over bytes, it is almost certainly the
consumer's half of the seam.

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
  the choice. Selections are purpose-named (a wall clock for naming, an instant for
  ordering), report the role they chose, and sit beside every named field.

The central abstraction is evidence. Normalized metadata is derived from
evidence, not substituted for it. This evidence model is **internal**: the public
contract is a fixed, fully typed field set derived from it.

## Public Model Principles

The library does all byte-parsing and returns a fixed, strongly-typed field set.
Callers never see raw metadata strings, JSON, or a candidate list. Each
capture/creation timestamp is exposed as its own named, typed field.

The library is also opinionated where its format knowledge is the hard part, and
it is explicit about it. "Which date is best" has no single answer — *what local
time was this taken* (naming) and *what instant was this taken* (ordering) differ
on the same file — so there is no `bestDate`. There are two purpose-named
selections, `captureWallClock` and `captureInstant`, each returning the role it
chose, with its precedence published as a constant. They are the Resolver layer
below: a default a consumer can take or ignore, never the only source of truth.
The same rule applies to geometry: the library knows that EXIF orientations 5–8
turn the picture a quarter, so it reports the display size rather than leaving
every consumer to rediscover that.

Public top-level shape (`Sources/MediaMetadata/MediaMetadataResult.swift`):

```swift
public struct MediaMetadataResult {
    let outcome: ReadOutcome          // .parsed / .unsupported (definitive) | .readFailure (transient)
    let format: MediaFormat           // family, kind, fileType (incl. camera RAW, from bytes), extension, brand
    let timestamps: CaptureTimestamps // one named CaptureTime? per source, typed Role keys, + captureWallClock / captureInstant
    let locations: CaptureLocations   // one named GeoLocation? per source, typed Source keys — no order, no best-pick
    let camera: Camera?               // device identity only: make/model/lens/serial (text); nil when the file names none
    let geometry: PixelGeometry?      // stored pixel size + Orientation (Exif, HEIF irot/imir, or track matrix) + display size
    let video: VideoInfo?             // durationSeconds, frameRate, VideoCodec
}
```

`MediaMetadataReader.extractionRevision(for:)` is kept per container family and
rises when re-reading the same bytes would change a value already reported, so a
consumer that persists results can find rows a re-read may improve instead of
writing a migration per parser fix. It is per family because the consumer pays for a
re-read in transport, not CPU: a single global number made every JPEG look stale
for a HEIF fix, and for a cloud library a re-read is a download. New fields do not
move it; the library reports when a re-read would help, and the consumer decides
when it is worth the bytes.

`MediaFormat.fileType` names the type from the bytes (an ISO brand, RAW evidence in
a TIFF's IFD0), never from the extension; `MediaFileType(fileExtension:)` is the
separate, explicitly name-based answer for a file nothing has read. RAW
classification reads nothing beyond what a parse already reads — real ARWs keep
their raw SubIFD just past the first 128 KB, and following it would cost a
transport round trip per file.

- `ReadOutcome` is the definitive-vs-transient signal: `.parsed`/`.unsupported`
  are definitive (`isDefinitive == true` — record and stop); `.readFailure` is
  transient (`shouldRetry == true` — the bytes could not be read).
- `CaptureTime` carries calendar fields, an optional `utcOffsetSeconds`, an
  absolute `instant` when computable, and a `precision`
  (`localWithOffset` / `localFloating` / `absolute`) — expression and meaning
  preserved separately, never collapsed to a bare `Date`. Every emitted
  `CaptureTime` has complete `year`…`second` components. Use
  `captureLocalComponents` for capture-local naming; it returns `nil` for
  `absolute` so UTC wall clocks cannot be mistaken for local capture time.
- `VideoCodec` is an enum (`h264`, `hevc`, `proRes`, …) with an `.other(fourCC:)`
  fallback so the open-ended codec set stays lossless yet typed. `identifier` is a
  stable, round-trippable string for storage.
- `PixelGeometry` reports the **stored** raster size (how Exif, HEIF `ispe` and a
  track header all record it) plus `Orientation`; `displayPixelWidth/Height` apply
  the quarter-turn rule. A movie's orientation comes from its track matrix, and only
  an exact rotation/mirror is translated — a scale or skew reports `nil`.
- `MediaFormat.Kind` is decided structurally: a video track makes a movie, a
  primary image item or image-sequence track makes a still, a sound-only file is
  audio. The family alone cannot say — ISO BMFF is an MP4, an AVIF and an M4A.

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
each candidate into its named field. Within a role, a local-authority candidate
(`localWithOffset` / `localWithoutOffset`) is preferred over a UTC-anchored
`absoluteInstant` so an absolute epoch cannot shadow capture-local evidence.

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
- **Swift 6 language mode.** The package is value types and synchronous parsing, so strict
  concurrency costs nothing here — and it makes the execution contract compiler-checked for
  consumers rather than a convention stated in prose.
- **The core target imports `Foundation` and nothing else.** No graphics,
  media, or UI framework; no third-party dependency. This is the constraint
  that keeps the package usable on Linux, in a CLI, on a server, and in tests
  without a display — and the one that forces the right answer whenever a
  "just use the system framework for this one case" shortcut appears. See
  Consumer Boundary.
- **Parsing must not depend on read granularity.** A source may satisfy reads
  a byte at a time or in oversized chunks; results must be byte-identical
  either way. Every parser family carries a test that proves it.
- **A failure must never be reported as definitive.** A read that could not be
  satisfied for reasons outside the file's own structure is `.readFailure`,
  never `.parsed` with empty fields. Consumers cache definitive answers, so
  misreporting a transport failure corrupts durable state.

## Roadmap

- **EXIF sub-second components** (`SubSecTimeOriginal` / `SubSecTimeDigitized`):
  exposing fractional seconds would reduce same-second naming collisions for
  consumers. Deferred; not required for the current capture-local contract.
