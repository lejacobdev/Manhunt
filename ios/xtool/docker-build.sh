#!/usr/bin/env bash
#
# docker-build.sh — runs xtool-build.sh inside a fresh Ubuntu 24.04 container
# instead of directly on the host. Use this when the host's glibc is too old
# for the prebuilt Swift toolchain and/or the xtool AppImage (e.g. Debian 11
# "bullseye", glibc 2.31 — both need up to glibc 2.35). Doesn't touch the
# host's own packages.
#
# If you already have a Swift toolchain installed via swiftly on the host
# (~/.local/share/swiftly/toolchains/<version>), this reuses it by bind-mount
# instead of re-downloading — the toolchain files themselves are fine, they
# just need a newer glibc than the host provides, which the container has.
#
# Usage: ./docker-build.sh
#
# Same interactive requirements as xtool-build.sh apply — you'll still need
# to answer the `xtool setup` prompts (Apple ID/2FA or API key, and the path
# to a downloaded Xcode.xip) live, inside the container's shell. If Xcode.xip
# lives outside this repo checkout, put it under this repo (or edit the -v
# lines below to mount wherever it actually is) so the container can see it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WEB_ROOT="/var/www/html"
IMAGE="ubuntu:24.04"
SWIFT_VERSION="6.3-RELEASE"
SWIFTLY_DIR="${HOME}/.local/share/swiftly"

mkdir -p "$WEB_ROOT"

VOLUME_ARGS=(
  -v "${REPO_ROOT}:/workspace"
  -v "${WEB_ROOT}:/var/www/html"
  -v xtool-local-bin:/root/.local/bin
)
if [[ -d "$SWIFTLY_DIR/toolchains" ]]; then
  echo "==> Reusing existing swiftly toolchains from $SWIFTLY_DIR"
  VOLUME_ARGS+=(-v "${SWIFTLY_DIR}:/root/.local/share/swiftly:ro")
else
  VOLUME_ARGS+=(-v xtool-swift-toolchain:/opt/swift)
fi

docker run -it --rm \
  "${VOLUME_ARGS[@]}" \
  -w /workspace/ios/xtool \
  -e SWIFT_VERSION="$SWIFT_VERSION" \
  "$IMAGE" \
  bash -c '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    # Prefer a swiftly-managed toolchain mounted from the host, if present;
    # otherwise fall back to downloading one straight from swift.org into the
    # container.
    SWIFTLY_TOOLCHAIN_BIN="$(find /root/.local/share/swiftly/toolchains -maxdepth 3 -type d -name bin 2>/dev/null | head -1)"

    # Kept deliberately minimal — Swift toolchains commonly need libpython/libncurses/etc
    # at runtime too, but exact package names drift across Ubuntu releases and a wrong
    # one here would fail this whole install. If `swift --version` below fails with a
    # missing .so, that error will say exactly which package to add.
    apt-get update -qq
    apt-get install -y -qq curl git ca-certificates usbmuxd 2>&1 | tail -5

    if [[ -n "$SWIFTLY_TOOLCHAIN_BIN" && -x "$SWIFTLY_TOOLCHAIN_BIN/swift" ]]; then
      export PATH="${SWIFTLY_TOOLCHAIN_BIN}:/root/.local/bin:$PATH"
    else
      export PATH="/opt/swift/usr/bin:/root/.local/bin:$PATH"
      if ! command -v swift >/dev/null 2>&1; then
        echo "==> Downloading Swift ${SWIFT_VERSION} for Ubuntu 24.04..."
        curl -fL \
          "https://download.swift.org/swift-${SWIFT_VERSION}/ubuntu2404/swift-${SWIFT_VERSION}/swift-${SWIFT_VERSION}-ubuntu24.04.tar.gz" \
          -o /tmp/swift.tar.gz
        tar xzf /tmp/swift.tar.gz -C /opt/swift --strip-components=1
        rm /tmp/swift.tar.gz
      fi
    fi

    swift --version
    exec ./xtool-build.sh
  '
