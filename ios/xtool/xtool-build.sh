#!/usr/bin/env bash
#
# xtool-build.sh — builds HuntingGame.ipa from ios/xtool's SwiftPM package using
# xtool (https://xtool.sh), for Linux (or Windows/WSL) machines without Xcode.
#
# Run this on a machine with NORMAL, unrestricted internet access — it downloads
# a multi-GB Xcode.xip from Apple and the Swift toolchain, neither of which the
# session that generated this script was able to reach.
#
# What this script does NOT do for you, because they require a human at a
# keyboard with your Apple ID:
#   - Downloading Xcode.xip: visit https://developer.apple.com/download/all/?q=Xcode
#     in your browser (log in with your Apple ID), download "Xcode 26", note the
#     saved path.
#   - `xtool setup`'s login prompt: you'll pick API Key (paid Apple Developer
#     Program membership) or Password (any Apple ID, but needs a live 2FA code
#     from your device) and enter your own credentials interactively.
#
# Everything else — installing xtool itself, building, packaging the .ipa — this
# script does for you.
#
# KNOWN LIMITATION: this package (ios/xtool/Package.swift) does NOT include the
# Apple Watch companion app or its widget extension. xtool's docs don't show any
# watchOS support (only iOS app + "app extension" products), so the Watch app
# was left out of this build path entirely. It's still fully present in the
# Xcode project at ios/HuntingGame — build that with build_ipa.sh on a Mac (or
# via Xcode directly) if you want the Watch app included.

set -euo pipefail

# The xtool AppImage normally mounts itself via FUSE, which isn't available in
# most containers/minimal servers (no /dev/fuse). This makes it extract to a
# temp dir and run from there instead — confirmed working where FUSE isn't.
export APPIMAGE_EXTRACT_AND_RUN=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XTOOL_BIN="${HOME}/.local/bin/xtool"
WEB_ROOT="/var/www/html"
IPA_NAME="HuntingGame.ipa"

log() { echo "==> $*"; }

# --- 1. Prerequisite checks -------------------------------------------------

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "You're on macOS — you don't need xtool here. Use ../../build_ipa.sh" \
       "with Xcode instead; it builds the full app including the Watch companion." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: Swift not found on PATH.

Install the Swift 6.3 toolchain for your Linux distribution from
https://swift.org/install/linux, then re-run this script.

(If you're on Windows, run this inside WSL — see
https://xtool.sh/documentation/xtool/installation-linux/ for the WSL/USBIPD
setup needed to install to a physical device over USB. That part isn't needed
just to build the .ipa.)
EOF
  exit 1
fi
log "Swift found: $(swift --version | head -1)"

if ! command -v usbmuxd >/dev/null 2>&1; then
  log "Note: usbmuxd not found. Not needed to build the .ipa, but you'll want" \
      "it (apt-get install usbmuxd) if you plan to use 'xtool install' to push" \
      "straight to a plugged-in device instead of sideloading via AltStore/SideStore."
fi

# --- 2. Install xtool itself -------------------------------------------------

if [[ ! -x "$XTOOL_BIN" ]]; then
  log "Downloading xtool AppImage..."
  mkdir -p "$(dirname "$XTOOL_BIN")"
  curl -fL "https://github.com/xtool-org/xtool/releases/latest/download/xtool-$(uname -m).AppImage" -o "$XTOOL_BIN"
  chmod +x "$XTOOL_BIN"
  case ":$PATH:" in
    *":${HOME}/.local/bin:"*) ;;
    *) log "Add this to your shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
else
  log "xtool already installed at $XTOOL_BIN ($("$XTOOL_BIN" --version))"
fi

# --- 3. Darwin SDK (no Apple ID login needed) -------------------------------
# `xtool setup` would also log in with your Apple ID here — but that's only
# actually required for a *signed* build (`--sign`) or installing to a
# device. This produces an unsigned .ipa (same as build_ipa.sh's Mac output,
# meant for AltStore/SideStore to sign on install), so we skip auth entirely
# and go straight to the SDK, via the same standalone `xtool sdk` subcommand.

if "$XTOOL_BIN" sdk status >/dev/null 2>&1; then
  log "Darwin SDK already installed."
else
  XIP_PATH="${1:-}"
  if [[ -z "$XIP_PATH" ]]; then
    for candidate in "$HOME"/Downloads/Xcode*.xip /tmp/Xcode*.xip "$SCRIPT_DIR"/Xcode.xip; do
      for f in $candidate; do
        [[ -f "$f" ]] && XIP_PATH="$f" && break 2
      done
    done
  fi
  if [[ -z "$XIP_PATH" || ! -f "$XIP_PATH" ]]; then
    cat >&2 <<'EOF'
ERROR: No Darwin SDK installed and no Xcode.xip found.

Download one from https://developer.apple.com/download/all/?q=Xcode
(log in with your Apple ID in the browser first), then re-run:
  ./xtool-build.sh /path/to/Xcode.xip
EOF
    exit 1
  fi
  log "Installing the Darwin SDK from $XIP_PATH (runs once, takes a few minutes)..."
  "$XTOOL_BIN" sdk install "$XIP_PATH"
fi

# --- 4. Build ----------------------------------------------------------------

cd "$SCRIPT_DIR"
log "Building HuntingGame.ipa (this compiles the full app + widget extension)..."

BUILD_LOG="$(mktemp)"
trap 'rm -f "$BUILD_LOG"' EXIT
"$XTOOL_BIN" dev build --configuration release --ipa 2>&1 | tee "$BUILD_LOG"

# xtool prints "Wrote to <path>" as its last line on success.
IPA_PATH="$(grep '^Wrote to ' "$BUILD_LOG" | tail -1 | sed 's/^Wrote to //')"
if [[ -z "$IPA_PATH" || ! -f "$IPA_PATH" ]]; then
  echo "ERROR: build finished but couldn't find the .ipa xtool reported writing." >&2
  exit 1
fi

log "That .ipa is unsigned, same as build_ipa.sh's output — install it via" \
    "AltStore/SideStore (which re-sign on install) or TrollStore."
log "To instead produce a directly-installable ad-hoc signed .ipa tied to your" \
    "Apple ID (no re-signing needed), re-run with: $XTOOL_BIN dev build --configuration release --ipa --sign"

# --- 5. Publish to the web root ----------------------------------------------
# So it's downloadable straight off this server (e.g. https://your-domain/HuntingGame.ipa)
# instead of needing scp/rsync to get it off the box.

if [[ -d "$WEB_ROOT" ]]; then
  DEST="${WEB_ROOT}/${IPA_NAME}"
  if [[ -w "$WEB_ROOT" ]]; then
    cp "$IPA_PATH" "$DEST"
  elif command -v sudo >/dev/null 2>&1; then
    sudo cp "$IPA_PATH" "$DEST"
  else
    echo "ERROR: $WEB_ROOT isn't writable and sudo isn't available." \
         "The built .ipa is still at $IPA_PATH — copy it manually." >&2
    exit 1
  fi
  log "Copied to ${DEST} — reachable at http(s)://<this-server>/${IPA_NAME}"
  log "Note: that's a plain, unauthenticated static file. Anyone with the URL" \
      "can download it — fine for personal sideloading, but don't leave it up" \
      "if that's not what you want."
else
  log "Note: $WEB_ROOT doesn't exist on this machine, skipping publish step." \
      "Built .ipa is at $IPA_PATH"
fi

# --- 6. Publish to backend/dist-static + refresh the SideStore/AltStore source ---
# Served by the backend's own '/dist' express.static route (backend/src/server.ts) —
# same domain/TLS as api.lejacob.eu already, no separate vhost needed. This is a
# proper AltStore/SideStore *source*: add it once in the app's Sources tab and
# future rebuilds just show up as an update, instead of re-sending a raw IPA link
# every time.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIST_STATIC="$REPO_ROOT/backend/dist-static"
# docker compose creates this as root when it sets up the bind mount, so writing
# here may need sudo — same fallback as the web-root publish above.
SUDO=""
if ! mkdir -p "$DIST_STATIC" 2>/dev/null || [[ ! -w "$DIST_STATIC" ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    $SUDO mkdir -p "$DIST_STATIC"
  else
    echo "ERROR: $DIST_STATIC isn't writable and sudo isn't available." \
         "The built .ipa is still at $IPA_PATH — copy it manually." >&2
    exit 1
  fi
fi

$SUDO cp "$IPA_PATH" "$DIST_STATIC/$IPA_NAME"
$SUDO cp "$SCRIPT_DIR/icon.png" "$DIST_STATIC/icon.png"
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

log "SideStore source updated: $SOURCE_BASE_URL/dist/source.json"
log "Add that URL once under SideStore's Sources tab (+) — installs and every future" \
    "rebuild's update both come from there instead of a raw IPA link. Needs the" \
    "backend Node process running (and restarted at least once since it gained the" \
    "'/dist' static route) — set SOURCE_BASE_URL=... to override the domain."
