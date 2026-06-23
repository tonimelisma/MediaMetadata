#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
manifest="${script_dir}/fixture-bootstrap.tsv"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

file_size() {
  if stat -c '%s' "$1" >/dev/null 2>&1; then
    stat -c '%s' "$1"
  else
    stat -f '%z' "$1"
  fi
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

resolve_gopro_share() {
  python3 - "$1" <<'PY'
import json
import sys
import urllib.parse
import urllib.request

share_url = sys.argv[1]
collection_id = urllib.parse.urlparse(share_url).path.rstrip("/").split("/")[-1]
headers = {
    "Accept": "application/vnd.gopro.jk.media+json; version=2.0.0",
    "Content-Type": "application/json",
}

def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers)) as response:
        return json.load(response)

items = fetch(f"https://api.gopro.com/media/items/{collection_id}").get("items") or []
if not items:
    raise SystemExit("GoPro share page returned no media items")
medium_id = (items[0].get("medium") or {}).get("id")
if not medium_id:
    raise SystemExit("GoPro share item has no medium id")
embedded = fetch(f"https://api.gopro.com/media/{medium_id}/download").get("_embedded") or {}
for label in ("source", "baked_source"):
    for variation in embedded.get("variations") or []:
        if variation.get("available") and variation.get("label") == label and variation.get("url"):
            print(variation["url"])
            raise SystemExit(0)
for entry in embedded.get("files") or []:
    if entry.get("available") and entry.get("url"):
        print(entry["url"])
        raise SystemExit(0)
raise SystemExit("GoPro download API returned no usable URL")
PY
}

resolve_url() {
  case "$1" in
    direct) printf '%s\n' "$2" ;;
    gopro-share) resolve_gopro_share "$2" ;;
    *) die "unsupported fixture source kind: $1" ;;
  esac
}

verify_fixture() {
  local path="$1"
  local expected_size="$2"
  local expected_hash="$3"
  [[ -f "${path}" ]] || return 1
  [[ "$(file_size "${path}")" == "${expected_size}" ]] || return 1
  [[ "$(file_sha256 "${path}")" == "${expected_hash}" ]]
}

download_fixture() {
  local id="$1" target="$2" kind="$3" locator="$4" source_page="$5"
  local expected_type="$6" expected_size="$7" expected_hash="$8" description="$9"
  local absolute_target="${repo_root}/${target}"

  printf '\n[%s] %s\n' "${id}" "${description}"
  printf '  source: %s\n' "${source_page}"
  printf '  target: %s\n' "${target}"
  if verify_fixture "${absolute_target}" "${expected_size}" "${expected_hash}"; then
    printf '  status: already present and verified\n'
    return
  fi

  mkdir -p "$(dirname "${absolute_target}")"
  if [[ -f "${absolute_target}" && "$(file_size "${absolute_target}")" == "${expected_size}" ]]; then
    rm -f "${absolute_target}"
  fi
  local url
  url="$(resolve_url "${kind}" "${locator}")"
  curl -fL --retry 3 --retry-delay 2 --continue-at - --output "${absolute_target}" "${url}"

  if ! verify_fixture "${absolute_target}" "${expected_size}" "${expected_hash}"; then
    rm -f "${absolute_target}"
    die "download verification failed for ${target} (expected ${expected_type}, ${expected_size} bytes, SHA-256 ${expected_hash})"
  fi
  printf '  status: downloaded and verified\n'
}

if [[ "${1-}" == "--list" ]]; then
  awk -F '\t' 'NR > 1 { printf "%-34s %s\n", $1, $9 }' "${manifest}"
  exit 0
fi
[[ $# -eq 0 ]] || die "usage: Scripts/bootstrap-fixtures.sh [--list]"

while IFS=$'\t' read -r id target kind locator source_page content_type size sha256 description; do
  [[ "${id}" == "id" ]] && continue
  download_fixture "${id}" "${target}" "${kind}" "${locator}" "${source_page}" "${content_type}" "${size}" "${sha256}" "${description}"
done < "${manifest}"

printf '\nPublic fixture bootstrap complete. apple.mov remains a manual local prerequisite.\n'
