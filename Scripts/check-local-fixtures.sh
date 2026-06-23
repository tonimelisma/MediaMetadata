#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixtures="${repo_root}/Tests/Fixtures"

required_committed=(
  "otos-catalog-state-robustness/Media/ios-heic-offset-date.heic"
  "otos-catalog-state-robustness/Media/jpeg-exif-offset-date.jpg"
  "otos-catalog-state-robustness/Media/mov-no-embedded-capture-date.mov"
  "otos-catalog-state-robustness/Media/mp4-no-embedded-capture-date.mp4"
  "videometa/IMG_5179.MOV"
  "videometa/exiftool_quicktime.mov"
  "videometa/google.mp4"
  "videometa/minimal.mp4"
  "videometa/nonfaststart.mp4"
  "videometa/sony_a6700.mp4"
  "videometa/with_audio.mp4"
  "videometa/with_gps.mp4"
)

for fixture in "${required_committed[@]}"; do
  [[ -f "${fixtures}/${fixture}" ]] || { printf 'error: missing committed fixture %s\n' "${fixture}" >&2; exit 1; }
done

"${repo_root}/Scripts/bootstrap-fixtures.sh"

apple_fixture="${fixtures}/videometa/apple.mov"
if [[ ! -f "${apple_fixture}" ]]; then
  printf 'error: missing manual local fixture Tests/Fixtures/videometa/apple.mov\n' >&2
  printf 'Copy the existing rights-reviewed local fixture into that path before running tests.\n' >&2
  exit 1
fi

printf 'All 16 required local fixtures are present.\n'
