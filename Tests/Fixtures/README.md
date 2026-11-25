# Real-Media Fixtures

This directory consolidates fixtures from three user-owned repositories, one
user-owned photo collection, and one permissively licensed third-party project.
The source-specific subdirectories preserve provenance, while byte-identical
copies are stored only once.

These are development and test inputs only. They are not SwiftPM resources and
are not included in the `MediaMetadata` runtime target.

## Sources

### `videometa/`

- Source: `https://github.com/tonimelisma/videometa.git`
- Imported from commit: `4c1c973b28aeab3ad2251f98798e172bb5647043`
- Original path: `testdata/`
- Contents: committed validation media, ExifTool grouped JSON records, ExifTool
  ordered JSON records, and locally available bootstrap media.

The source repository documents these real-media origins:

| Fixture | Origin | Repository policy |
|---|---|---|
| `IMG_5179.MOV` | iPhone 15 Pro original recording | Committed validation fixture |
| `google.mp4` | Pixel 9 Pro original recording | Committed validation fixture |
| `sony_a6700.mp4` | Sony A6700 original recording | Committed validation fixture |
| `gopro_action.mp4` | [GoPro HERO12 shared clip](https://gopro.com/v/8GodrO3G8bNK4) | Bootstrap/local-only fixture |
| `dji_inspire3_car_4k120_rec709.mov` | [DJI Inspire 3 sample](https://www.dji.com/inspire-3/samples) | Bootstrap/local-only fixture |
| `dji_ronin4d_4k_prores4444_25fps.mov` | [DJI Ronin 4D sample](https://www.dji.com/ronin-4d/samples) | Bootstrap/local-only fixture |

Known metadata sensitivity is intentional in this corpus: the smartphone and
GPS fixtures retain location-related metadata, and some ExifTool records retain
camera or lens serial fields. These values already exist in the source fixture
repository and are preserved so the records remain valid comparison evidence.
Do not treat these fixtures as anonymized media.

The three local-only media files are ignored by Git here, matching their source
repository policy, and have public download records in
`Scripts/fixture-bootstrap.tsv`.

The source repository also has a legacy `apple.mov` whose origin is not
documented well enough to redistribute it. It is not part of this corpus;
`nom-exif/meta.mov` covers the same iPhone QuickTime metadata.

### `gomediaimport/`

- Source: `https://github.com/tonimelisma/gomediaimport.git`
- Imported from commit: `572fc4ba6a5065df8788bc116a1fb8d070a2ca72`
- Original path: `cmd/gomediaimport/testdata/`
- Contents: the three small video fixtures used by that command's tests.

These files duplicate the corresponding `videometa/` fixtures byte-for-byte.
The duplicate copies are intentionally omitted; the canonical files live under
`videometa/`.

### `otos-catalog-state-robustness/`

- Source: `https://github.com/tonimelisma/Otos.git`
- Imported from commit: `14d35bf94f67bacb20cd844613bde9f04bca1989`
- Original path: `OtosTests/Fixtures/`
- Contents: rights-clean JPEG, HEIC, MP4, and MOV metadata fixtures plus the
  source fixture README.

The source README records these files as user-provided and rights-clean. It
also prohibits fixtures with sensitive subjects, locations, or private
metadata.

### `nom-exif/`

- Source: `https://github.com/mindeng/nom-exif.git`
- Imported from commit: `fe72efc28d45c11979895bb57da7495f2ff616a4`
  (the file was added in `d6c6d93`, 2024-02-15)
- Original path: `testdata/meta.mov`
- SHA-256: `f5fa5c0b0b920f3280bc8ad01c407506d2c52ef9ca3490f48b90eca7f36aac6d`
- License: MIT, Copyright (c) 2024 Min Deng; the full text is in
  `nom-exif/LICENSE`, which must stay next to the file.
- Contents: a 0.5 s, 720×1280 H.264 iPhone X recording (iOS 12.1.2) with the
  Apple `Keys` metadata an iPhone writes: `Make`, `Model`, `Software`,
  `CreationDate` with its UTC offset, and ISO 6709 `GPSCoordinates`. It locks
  the iPhone QuickTime capture date, offset, location and camera path that the
  undistributable `apple.mov` used to cover. It has no lens model, and its
  container `CreateDate` (2024) postdates its capture `CreationDate` (2019)
  because it was re-saved after capture.
- Privacy review: the picture is a mountain lake landscape with no people,
  and its location is a public scenic area. The file is already published in
  the source repository.

### `sofian-kuvat/`

- Source: user-owned family photos under
  `~/Desktop/OneDrive/Perheen kuvat/Sofian kuvat/`
- Contents: a header-only Motion-JPEG AVI extract used to lock AVI duration,
  frame rate, codec, and dimensions. See `sofian-kuvat/README.md` for the
  privacy and provenance record.

## Privacy and Licensing Record

Apart from `nom-exif/`, this import copies files already maintained by the user
in existing fixture repositories. `nom-exif/meta.mov` is third-party media
redistributed under its MIT license, as recorded above. The Otos files
carry an explicit rights-clean statement. The `videometa` files retain the
published acquisition information above; the committed files were already
versioned in that source repository. No independent visual privacy or licensing
review of the user-owned files was performed during this mechanical import.

Before adding another real-media fixture, document its source device or app,
acquisition date or source link, rights to redistribute it, privacy review, and
the parser behavior it is intended to cover.

## Full Corpus

The golden corpus has 17 canonical media files: 14 committed and three public
DJI/GoPro samples too large to commit. The golden test checks every file that
is present and skips an absent one with a `warning: skipping absent local
fixture` line, so a clean checkout (CI, a cloud session) checks the 14
committed files. Fetch the other three for full coverage with:

```sh
Scripts/check-local-fixtures.sh
```

That command verifies the 14 committed fixtures and downloads and SHA-256
verifies the three public DJI/GoPro fixtures when absent. CI must not download or
bootstrap these files implicitly.

Use `Scripts/bootstrap-fixtures.sh --list` to inspect the public download set.

## Golden Records

Every canonical fixture has two ExifTool evidence records:

- `*.exiftool.json`: grouped numeric JSON, retaining duplicate tags.
- `*.exiftool.ordered.json`: group and tag order, including repeated fields.

`metadata-golden.json` is the reviewed semantic contract for the public
`MediaMetadataResult` model. Tests compare identity, selected findings,
timestamp authorities, locations, camera metadata, diagnostics, provenance,
and bounded-read metrics. They intentionally do not require parity with every
ExifTool field.

Regenerate the raw evidence records with ExifTool installed:

```sh
Scripts/check-local-fixtures.sh
Scripts/generate-fixture-goldens.swift
```

The generator fixes locale and timezone, records the ExifTool version and exact
arguments, and emits stable sorted JSON. Review `metadata-golden.json` by hand
when deliberately promoting newly parsed evidence; it is not overwritten by
the generator.
