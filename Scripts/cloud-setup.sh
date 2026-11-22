#!/usr/bin/env bash
#
# SessionStart hook for Claude Code cloud sessions (claude.ai/code).
#
# Cloud VMs are Ubuntu 24.04 x86_64 without Swift. This installs the same Swift
# release CI's Linux job uses (`container: swift:6.0`, i.e. 6.0.3) from the
# swift.org tarball, verifies its signature, and puts it on PATH. Anywhere
# else (`CLAUDE_CODE_REMOTE` unset, e.g. on Toni's Mac) it exits at once.
#
# Idempotent: a second run finds the toolchain and only re-exports PATH.
# Override the version with SWIFT_VERSION=x.y.z when CI moves.

set -euo pipefail

[[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]] || exit 0

swift_version="${SWIFT_VERSION:-6.0.3}"
install_root="/opt/swift-${swift_version}"
swift_bin="${install_root}/usr/bin"

log() { printf '[cloud-setup] %s\n' "$*" >&2; }
trap 'log "failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

if [[ "$(id -u)" -eq 0 ]]; then
    sudo_cmd=()
else
    sudo_cmd=(sudo)
fi

# Make the toolchain visible to every later shell in the session.
publish_path() {
    if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
        printf 'export PATH="%s:$PATH"\n' "${swift_bin}" >> "${CLAUDE_ENV_FILE}"
    fi
    printf 'export PATH="%s:$PATH"\n' "${swift_bin}" \
        | "${sudo_cmd[@]}" tee /etc/profile.d/swift.sh >/dev/null
    for tool in swift swiftc; do
        "${sudo_cmd[@]}" ln -sf "${swift_bin}/${tool}" "/usr/local/bin/${tool}"
    done
}

if "${swift_bin}/swift" --version 2>/dev/null | grep -q "Swift version ${swift_version} "; then
    publish_path
    log "Swift ${swift_version} already installed"
    exit 0
fi

source /etc/os-release
if [[ "${ID}" != "ubuntu" || "${VERSION_ID}" != "24.04" || "$(uname -m)" != "x86_64" ]]; then
    log "expected Ubuntu 24.04 x86_64, found ${ID} ${VERSION_ID} $(uname -m); skipping"
    exit 0
fi

log "installing Swift ${swift_version} build dependencies"
export DEBIAN_FRONTEND=noninteractive
"${sudo_cmd[@]}" apt-get update -qq
# Dependency list from swift.org's Ubuntu 24.04 install instructions.
"${sudo_cmd[@]}" apt-get install -y -qq --no-install-recommends \
    binutils ca-certificates curl git gnupg2 libc6-dev libcurl4-openssl-dev \
    libedit2 libgcc-13-dev libncurses-dev libpython3-dev libsqlite3-0 \
    libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev \
    >/dev/null

name="swift-${swift_version}-RELEASE-ubuntu24.04"
url="https://download.swift.org/swift-${swift_version}-release/ubuntu2404/swift-${swift_version}-RELEASE/${name}.tar.gz"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# fetch URL DEST [EXPECT]: download, retrying until DEST starts with EXPECT.
fetch() {
    local attempt
    for attempt in 1 2 3; do
        if curl -fsSL --retry 3 -o "$2" "$1" \
            && { [[ -z "${3:-}" ]] || head -c 64 "$2" | grep -q -- "$3"; }; then
            return 0
        fi
        log "fetch ${1} attempt ${attempt} failed ($(wc -c < "$2" 2>/dev/null || echo 0) bytes)"
        sleep 2
    done
    return 1
}

log "downloading ${url}"
fetch "${url}" "${work}/swift.tar.gz"
fetch "${url}.sig" "${work}/swift.tar.gz.sig"
fetch "https://www.swift.org/keys/all-keys.asc" "${work}/keys.asc" "BEGIN PGP PUBLIC KEY"

export GNUPGHOME="${work}/gnupg"
mkdir -m 700 "${GNUPGHOME}"
log "importing $(wc -c < "${work}/keys.asc")-byte key file"
gpg --batch --quiet --import "${work}/keys.asc"
gpg --batch --quiet --verify "${work}/swift.tar.gz.sig" "${work}/swift.tar.gz"
log "signature verified"

"${sudo_cmd[@]}" mkdir -p "${install_root}"
"${sudo_cmd[@]}" tar -xzf "${work}/swift.tar.gz" -C "${install_root}" --strip-components=1

publish_path
"${swift_bin}/swift" --version >&2
log "Swift ${swift_version} ready"
