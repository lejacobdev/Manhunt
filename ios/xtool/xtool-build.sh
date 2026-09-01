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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XTOOL_BIN="${HOME}/.local/bin/xtool"

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

# --- 3. Auth + Darwin SDK (interactive) -------------------------------------

log "Running 'xtool setup' — this is interactive. You'll be asked to log in" \
    "with your Apple ID (API key or password+2FA), then for the path to the" \
    "Xcode.xip you downloaded from developer.apple.com."
"$XTOOL_BIN" setup

# --- 4. Build ----------------------------------------------------------------

cd "$SCRIPT_DIR"
log "Building HuntingGame.ipa (this compiles the full app + widget extension)..."
"$XTOOL_BIN" dev build --configuration release --ipa

log "Done. See the 'Wrote to ...' path above for the .ipa location."
log "That .ipa is unsigned, same as build_ipa.sh's output — install it via" \
    "AltStore/SideStore (which re-sign on install) or TrollStore."
log "To instead produce a directly-installable ad-hoc signed .ipa tied to your" \
    "Apple ID (no re-signing needed), re-run with: $XTOOL_BIN dev build --configuration release --ipa --sign"
