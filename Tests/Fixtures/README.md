# Real-Media Fixtures

This directory consolidates fixtures from three user-owned repositories. The
source-specific subdirectories preserve provenance, while byte-identical copies
are stored only once.

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
| `apple.mov` | Legacy local fixture; origin not documented in the source fixture record | Local-only fixture |

Known metadata sensitivity is intentional in this corpus: the smartphone and
GPS fixtures retain location-related metadata, and some ExifTool records retain
camera or lens serial fields. These values already exist in the source fixture
repository and are preserved so the records remain valid comparison evidence.
Do not treat these fixtures as anonymized media.

The four local-only media files are ignored by Git here, matching their source
repository policy. The DJI and GoPro files have public download records in
`Scripts/fixture-bootstrap.tsv`; `apple.mov` is a manual local prerequisite
because its source is not documented well enough for redistribution.

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

## Privacy and Licensing Record

This import copies files already maintained by the user in existing fixture
repositories. It does not add media acquired from a new source. The Otos files
carry an explicit rights-clean statement. The `videometa` files retain the
published acquisition information above; the committed files were already
versioned in that source repository. No independent visual privacy or licensing
review was performed during this mechanical import.

Before adding another real-media fixture, document its source device or app,
acquisition date or source link, rights to redistribute it, privacy review, and
the parser behavior it is intended to cover.

## Local Corpus Requirement

Real-fixture and golden tests require all 16 canonical media files. Prepare a
developer checkout with:

```sh
Scripts/check-local-fixtures.sh
```

That command verifies the 12 committed fixtures, downloads and SHA-256 verifies
the three public DJI/GoPro fixtures when absent, and fails with instructions if
the manual `videometa/apple.mov` prerequisite is missing. Tests do not skip an
incomplete corpus. CI must not download or bootstrap these files implicitly.

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
