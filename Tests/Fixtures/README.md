# Real-Media Fixtures

This directory mirrors existing fixtures from three user-owned repositories.
The source-specific subdirectories are retained so duplicated fixtures and
their provenance remain explicit.

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

The four local-only media files are copied into a developer checkout when
available but ignored by Git here, matching their source repository policy.
Their ExifTool records remain committed when the source repository commits
them.

### `gomediaimport/`

- Source: `https://github.com/tonimelisma/gomediaimport.git`
- Imported from commit: `572fc4ba6a5065df8788bc116a1fb8d070a2ca72`
- Original path: `cmd/gomediaimport/testdata/`
- Contents: the three small video fixtures used by that command's tests.

These files duplicate the corresponding `videometa/` fixtures byte-for-byte.
They remain in a separate directory to preserve their source layout and make
future test migration auditable.

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
