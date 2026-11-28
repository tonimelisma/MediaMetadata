# Requirements

What MediaMetadata does today, one EARS sentence each. "The reader" is
`MediaMetadataReader`; "a result" is the `MediaMetadataResult` it returns. Each requirement is
`[verified]` by the tests tagged `Validates: <ID>` in `Tests/MediaMetadataTests/` (or the script
named), or `unverified:` with the reason. IDs are stable and never reused. Future work lives in
GitHub issues.

## Platform and boundary

- **MM-001** The core target `Sources/MediaMetadata` shall import `Foundation` and no other
  module, as `script/check-platform-neutral` checks in `script/verify` and CI.
  ([ADR 0001](adr/0001-foundation-only-core.md)) [verified]
- **MM-048** The package shall build and pass its tests on macOS and on Linux, in Swift 6
  language mode.
  unverified: a property of the build, not a test; CI's macOS and Linux jobs build and test on
  every pull request, and `Package.swift` sets the language mode.
- **MM-049** A byte source passed to `read(source:filenameHint:)` shall be used only during that
  call and on the calling thread.
  unverified: a contract the library keeps by construction (synchronous parsing, no stored
  source); no test can observe a source escaping.

## Outcomes and failure handling

- **MM-002** If a source throws while a file is being read, or the file cannot be opened, then
  the reader shall return `.readFailure` (`shouldRetry == true`), never `.parsed` with empty
  fields. ([ADR 0004](adr/0004-definitive-versus-transient-outcomes.md)) [verified]
- **MM-003** If a source delivers fewer bytes than asked for a range inside its size, then the
  reader shall treat the read as a transport failure; a range past the size returns `nil` (the
  file ends), and a zero-length read is satisfied. [verified]
- **MM-004** When the bytes carry no recognised signature, including an empty file, the reader
  shall return `.unsupported`, which is definitive. [verified]
- **MM-005** The reader shall return byte-identical results whatever read granularity a source
  uses, and its internal buffering shall not change any result. [verified]
- **MM-006** If a file is malformed, truncated, nested too deep or random, then the parsers shall
  return what they could read plus diagnostics, without crashing. [verified]
- **MM-007** When given a byte source, the reader shall return the same result as for the same
  bytes read from a file URL; the filename hint shall set only the reported extension. [verified]

## Read cost

- **MM-008** The reader shall report each read's cost: timing, the parsers' read count, the
  source's transport read count and the unique bytes read. [verified]
- **MM-009** The reader shall collapse a parse's many small reads into few transport reads, and
  batch contiguous metadata tables such as TIFF IFD entries. [verified]
- **MM-010** Where a consumer wraps a source in `CachingByteSource`, the reader shall fetch
  through it in the consumer's chunk size. ([ADR 0005](adr/0005-mechanism-here-policy-in-the-consumer.md)) [verified]
- **MM-011** The parsers shall skip media payloads and metadata they do not report (AVI `movi`
  lists, unused INFO and ID3 frames, unused QuickTime `mdta` values), and stop once the decisive
  evidence is found. [verified]

## Format identity

- **MM-012** When asked to identify a file, the reader shall read at most 12 bytes and report
  only what they prove, agreeing with a full parse. [verified]
- **MM-013** The reader shall decide a RIFF file's family from its form type: `AVI ` is AVI,
  `WAVE` is WAV, `WEBP` is WebP, any other is unknown. [verified]
- **MM-014** The reader shall name the file type from the bytes (an ISO brand, a signature),
  never from the extension. [verified]
- **MM-015** The reader shall recognise DNG, CR2, ARW, NEF, PEF and SRW from IFD0 evidence alone,
  never following a SubIFD, and never classify a TIFF embedded in Exif as RAW. [verified]
- **MM-016** The reader shall report CR3 as a still, and recognise RAF, ORF and RW2 as stills
  that stay `.unsupported`. [verified]
- **MM-017** `MediaFileType(fileExtension:)` shall fold each format's extension spellings into
  one type with stable display names and raw values. [verified]
- **MM-018** The reader shall decide a file's kind from its structure: a video track makes a
  movie, a primary image item or image-sequence track a still, a sound-only file audio.
  [verified]

## Timestamps

- **MM-019** When a TIFF, JPEG or RAW file has Exif `DateTimeOriginal` with `OffsetTimeOriginal`,
  the reader shall report it as `timestamps.original` with complete local components, the UTC
  offset and the absolute instant. ([ADR 0003](adr/0003-timestamp-expression-apart-from-instants.md)) [verified]
- **MM-020** When a timestamp has no UTC offset, the reader shall report it as `localFloating`,
  with local components and no instant. [verified]
- **MM-021** The reader shall report GPS and QuickTime UTC epoch times as `absolute`, whose
  `captureLocalComponents` is `nil`, and keep an explicit `+00:00` offset as `localWithOffset`.
  [verified]
- **MM-022** Within one timestamp role, the reader shall prefer a capture-local candidate over a
  UTC-anchored one. [verified]
- **MM-023** When a GoPro GPMF record carries a UTC epoch and a time zone, the reader shall derive
  a `localWithOffset` time; an epoch alone stays `absolute`. [verified]
- **MM-024** The reader shall offer two purpose-named selections, `captureWallClock` (naming,
  days, timeline order) and `captureInstant` (comparison across zones), each with the role it
  chose and a published precedence; absolute-only times never become a wall clock, and container
  creation or TIFF modification time is never a capture time. ([ADR 0002](adr/0002-evidence-first-model-typed-public-projection.md)) [verified]
- **MM-025** Timestamp roles shall round-trip through their raw values, and `CaptureTimestamps`
  rebuilt from stored entries shall make the same selections. [verified]
- **MM-026** When Exif carries `SubSecTime*` digits, the reader shall report them on their own
  role as written (padding dropped), for JPEG, TIFF, HEIF and PNG. [verified]
- **MM-027** The reader shall report AVI `LIST.INFO` `ICRD`/`IDIT` dates (also nested in the
  header list) and WAV `LIST.INFO` dates, moving past malformed ones. [verified]
- **MM-028** The reader shall report ID3v2 `TDRC`, then `TDOR`, then legacy `TYER`/`TDAT`/`TIME`
  dates, moving past malformed ones. [verified]
- **MM-050** When a WAV file has a Broadcast Wave `bext` chunk, the reader shall report its
  origination date and time as `timestamps.waveOrigination`.
  unverified: implemented in the RIFF parser but no test covers it yet (issue #32).
- **MM-029** The reader shall report QuickTime metadata dates and locations in MP4/MOV files,
  whatever `skip`, `uuid` or unknown boxes precede them. [verified]

## Location, camera, geometry

- **MM-030** The reader shall report each capture location as its own field by source (Exif GPS,
  QuickTime, Sony NRTM), with no order and no single pick. [verified]
- **MM-031** The reader shall report camera identity (make, model, lens, serial) from Exif,
  QuickTime keys and Sony NRTM, and `nil` when the file names no device. [verified]
- **MM-032** The reader shall report a movie's orientation from its track matrix, translating only
  exact rotations and mirrors; a scaled or skewed matrix reports `nil`. [verified]
- **MM-033** The reader shall report a HEIF or AVIF primary item's orientation from `irot`/`imir`,
  which wins over Exif orientation; transforms on other items are ignored. [verified]
- **MM-034** The reader shall report the stored pixel size (Exif, HEIF `ispe`, track header) and a
  display size with quarter turns applied. [verified]

## Still-image containers

- **MM-035** The reader shall identify and read PNG, GIF and WebP from their bytes, taking the
  stored size from the container header (`IHDR`, `VP8X`/`VP8 `/`VP8L`, the logical screen) over
  Exif dimensions. [verified]
- **MM-036** The reader shall read the Exif of a PNG `eXIf` chunk before `IDAT` and of a WebP
  `EXIF` chunk, and read neither past the image data nor when the canvas says there is none.
  [verified]
- **MM-037** If a still is truncated or its Exif is broken, then the reader shall keep the
  container's family and whatever size it read. [verified]

## Video, exposure and maker notes

- **MM-038** The reader shall report an AVI's duration, frame rate and codec from `avih`/`strh`.
  [verified]
- **MM-039** Video codec identifiers shall be stable strings that round-trip through
  `VideoCodec(identifier:)`. [verified]
- **MM-040** The reader shall report a still's Exif exposure (shutter as written, f-number, ISO,
  bias, focal length, flash, program, metering, white balance) for JPEG, TIFF, RAW, HEIF, PNG and
  WebP, omitting unknown values. [verified]
- **MM-041** The reader shall report Apple's content identifier from a still's MakerNote and a
  movie's QuickTime key, and none for other vendors or a truncated MakerNote. [verified]
- **MM-042** The reader shall report Apple's burst identifier for a burst frame, and none
  outside a burst. [verified]
- **MM-043** The reader shall report the levelling turn of an iPhone back-camera picture from its
  gravity reading, and none for front-camera pictures, unknown cameras or a near-vertical camera.
  [verified]
- **MM-044** The reader shall report a Sony continuous-drive frame's sequence number, and none for
  a single shot, a bracket or another maker's file. [verified]
- **MM-045** The reader shall report a RAW file's embedded previews as byte ranges, largest
  first, bounds-checked but never read. ([ADR 0005](adr/0005-mechanism-here-policy-in-the-consumer.md)) [verified]

## Persistence and the real-media corpus

- **MM-046** `extractionRevision(for:)` shall rise per container family whenever re-reading the
  same bytes would report anything different, including a newly reported field.
  ([ADR 0005](adr/0005-mechanism-here-policy-in-the-consumer.md)) [verified]
- **MM-047** The reader's output for every real fixture present shall match the reviewed goldens
  in `Tests/Fixtures/metadata-golden.json`; an absent downloadable fixture is skipped and an
  absent committed one fails. [verified]
