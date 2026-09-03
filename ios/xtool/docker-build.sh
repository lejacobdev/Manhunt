#!/usr/bin/env bash
# docker-build.sh — build HuntingGame.ipa using xtool + Docker, unsigned.
#
# Modeled directly on a proven-working script from another project on this
# server (SingOpKoelsch-iOS/make-ipa.sh) — same base image (swift:6.2-jammy,
# which has all the runtime libs xtool/swift need already correctly set up),
# same SDK cache directory, same no-auth-needed approach.
#
# Key fact this fixes vs. earlier attempts: `xtool setup` always logs in with
# your Apple ID first, even though that's only actually required for a SIGNED
# build (`xtool dev build --sign`) or installing to a device. An unsigned
# build — what this script produces, same as build_ipa.sh's Mac output, meant
# for AltStore/SideStore to sign on install — needs no Apple ID login at all.
# This script never calls `xtool auth` / `xtool setup`.
#
# What you need:
#   1. Docker (already installed ✓)
#   2. Xcode.xip — only if the SDK isn't already cached from a previous build
#      (this server already has one at ~/.xtool-cache/ from another project,
#      so you likely don't need to provide this at all). If you do:
#      download from https://developer.apple.com/download/all/?q=Xcode
#      (log in with your Apple ID in the browser), then either drop it under
#      this directory or pass its path as an argument.
#
# Usage:
#   ./docker-build.sh [/path/to/Xcode.xip]
#
# The SDK is cached in ~/.xtool-cache/swiftpm/ (shared across projects on this
# server) — subsequent builds, including for other xtool projects here, skip
# extraction entirely.

set -euo pipefail

DOCKER_IMAGE="manhunt-xtool-builder"
CACHE_DIR="$HOME/.xtool-cache"
SDK_MARKER="$CACHE_DIR/.sdk_installed"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Unlike SingOpKoelsch, this package's Sources/* are symlinks pointing OUTSIDE
# PROJECT_DIR (up into ../HuntingGame/, to share code with the Xcode build) —
# so the container needs the whole repo mounted, not just ios/xtool, or those
# symlinks resolve to nothing and SwiftPM sees empty targets.
REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
WEB_ROOT="/var/www/html"
IPA_NAME="HuntingGame.ipa"
IPA_OUT="$PROJECT_DIR/build/ipa/$IPA_NAME"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; NC='\033[0m'
step() { echo -e "\n${YLW}▶  $*${NC}"; }
ok()   { echo -e "${GRN}✔  $*${NC}"; }
info() { echo -e "${CYN}   $*${NC}"; }
fail() { echo -e "${RED}✖  $*${NC}"; exit 1; }

mkdir -p "$CACHE_DIR/swiftpm"

# ── 1. Build Docker image (cached after first run) ──────────────────────────
step "Preparing Docker build environment..."
docker build -f "$PROJECT_DIR/Dockerfile.xtool" -t "$DOCKER_IMAGE" "$PROJECT_DIR" --quiet
ok "Docker image ready: $DOCKER_IMAGE"

# ── 2. SDK: reuse the cache if present, else extract from Xcode.xip ─────────
if [ -f "$SDK_MARKER" ]; then
    ok "SDK already cached at $CACHE_DIR/swiftpm/ — skipping extraction."
else
    XIP_PATH="${1:-}"
    if [ -z "$XIP_PATH" ]; then
        for candidate in ~/Downloads/Xcode*.xip /tmp/Xcode*.xip "$PROJECT_DIR/Xcode.xip"; do
            for f in $candidate; do
                [ -f "$f" ] && XIP_PATH="$f" && break 2
            done
        done
    fi
    if [ -z "$XIP_PATH" ] || [ ! -f "$XIP_PATH" ]; then
        echo ""
        fail "No cached SDK found and no Xcode.xip given. Download one from
  https://developer.apple.com/download/all/?q=Xcode (log in with your Apple
  ID in the browser), then run: ./docker-build.sh /path/to/Xcode.xip"
    fi
    XIP_PATH=$(realpath "$XIP_PATH")
    ok "Xcode.xip: $XIP_PATH  ($(du -sh "$XIP_PATH" | cut -f1))"

    step "Extracting the iOS SDK from Xcode.xip (runs once, takes a few minutes)..."
    docker run --rm \
        -v "$CACHE_DIR/swiftpm:/root/.swiftpm" \
        -v "$XIP_PATH:/Xcode.xip:ro" \
        "$DOCKER_IMAGE" \
        xtool sdk install /Xcode.xip

    touch "$SDK_MARKER"
    ok "SDK installed and cached at $CACHE_DIR/swiftpm/"
fi

# ── 3. Build the IPA (unsigned, no Apple ID needed) ──────────────────────────
step "Building $IPA_NAME..."
mkdir -p "$PROJECT_DIR/build/ipa"

docker run --rm \
    -v "$CACHE_DIR/swiftpm:/root/.swiftpm" \
    -v "$REPO_ROOT:/workspace" \
    "$DOCKER_IMAGE" \
    sh -c "cd /workspace/ios/xtool && xtool dev build --ipa -c release"

# ── 4. Locate and move the IPA ────────────────────────────────────────────────
FOUND=$(find "$PROJECT_DIR/xtool" "$PROJECT_DIR/.build" -name "*.ipa" 2>/dev/null | head -1 || true)
[ -z "$FOUND" ] && FOUND=$(find "$PROJECT_DIR/build" -name "*.ipa" 2>/dev/null | grep -v "$IPA_OUT" | head -1 || true)
[ -z "$FOUND" ] && fail "IPA not found after build — see output above for errors."
[ "$FOUND" != "$IPA_OUT" ] && mv "$FOUND" "$IPA_OUT"

IPA_SIZE=$(du -sh "$IPA_OUT" | cut -f1)
ok "IPA built: $IPA_OUT ($IPA_SIZE)"

# ── 5. Publish to the web root ────────────────────────────────────────────────
if [ -d "$WEB_ROOT" ]; then
    DEST="$WEB_ROOT/$IPA_NAME"
    if [ -w "$WEB_ROOT" ]; then
        cp "$IPA_OUT" "$DEST"
    elif command -v sudo >/dev/null 2>&1; then
        sudo cp "$IPA_OUT" "$DEST"
    else
        fail "$WEB_ROOT isn't writable and sudo isn't available. IPA is at $IPA_OUT"
    fi
    ok "Copied to $DEST — reachable at http(s)://<this-server>/$IPA_NAME"
    info "That's a plain, unauthenticated static file — fine for personal use,"
    info "just don't leave it up if you don't want it downloadable by anyone with the URL."
else
    info "$WEB_ROOT doesn't exist here — IPA is at $IPA_OUT"
fi

# ── 6. Publish to backend/dist-static + refresh the SideStore/AltStore source ──
# Served by the backend's own '/dist' express.static route (backend/src/server.ts) —
# same domain/TLS as api.lejacob.eu already, no separate vhost needed. This is a
# proper AltStore/SideStore *source*: add it once in the app's Sources tab and
# future rebuilds just show up as an update, instead of re-sending a raw IPA link
# every time.
DIST_STATIC="$REPO_ROOT/backend/dist-static"
# docker compose creates this as root when it sets up the bind mount, so writing
# here may need sudo — same fallback as the web-root publish above.
SUDO=""
if ! mkdir -p "$DIST_STATIC" 2>/dev/null || [ ! -w "$DIST_STATIC" ]; then
    command -v sudo >/dev/null 2>&1 || fail "$DIST_STATIC isn't writable and sudo isn't available. IPA is at $IPA_OUT"
    SUDO="sudo"
    $SUDO mkdir -p "$DIST_STATIC"
fi

$SUDO cp "$IPA_OUT" "$DIST_STATIC/$IPA_NAME"
$SUDO cp "$PROJECT_DIR/icon.png" "$DIST_STATIC/icon.png"
IPA_BYTES=$(stat -c%s "$DIST_STATIC/$IPA_NAME" 2>/dev/null || stat -f%z "$DIST_STATIC/$IPA_NAME")
VERSION_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Keep in sync with ios/HuntingGame/project.yml's CFBundleShortVersionString.
APP_VERSION="1.0.0"
SOURCE_BASE_URL="${SOURCE_BASE_URL:-https://api.lejacob.eu}"

$SUDO tee "$DIST_STATIC/source.json" >/dev/null <<JSON
{
  "name": "Hunting Game",
  "identifier": "eu.lejacob.huntinggame.source",
  "apps": [
    {
      "name": "Hunting Game",
      "bundleIdentifier": "com.huntinggame.app",
      "developerName": "lejacob.eu",
      "localizedDescription": "GPS manhunt: hunters vs. runners with live radar, power-ups, and squad play.",
      "iconURL": "$SOURCE_BASE_URL/dist/icon.png",
      "versions": [
        {
          "version": "$APP_VERSION",
          "date": "$VERSION_DATE",
          "downloadURL": "$SOURCE_BASE_URL/dist/$IPA_NAME",
          "size": $IPA_BYTES,
          "minOSVersion": "16.2"
        }
      ]
    }
  ]
}
JSON

ok "SideStore source updated: $SOURCE_BASE_URL/dist/source.json"
info "Add that URL once under SideStore's Sources tab (+) — installs and every future"
info "rebuild's update both come from there instead of a raw IPA link. Needs the"
info "backend Node process running (and restarted at least once since it gained the"
info "'/dist' static route) — set SOURCE_BASE_URL=... to override the domain."

echo ""
echo -e "${GRN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GRN}║  ✅  $IPA_NAME ready! ($IPA_SIZE)${NC}"
echo -e "${YLW}║  ⚠️  Watch app requires a Mac build (build_ipa.sh via Xcode) —${NC}"
echo -e "${YLW}║     xtool has no documented watchOS support, so it isn't in${NC}"
echo -e "${YLW}║     this build.${NC}"
echo -e "${GRN}║${NC}"
echo -e "${GRN}║  Install via AltStore/SideStore (re-sign on install) or TrollStore.${NC}"
echo -e "${GRN}╚══════════════════════════════════════════════════════════════╝${NC}"
