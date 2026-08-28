#!/usr/bin/env bash
#
# build_ipa.sh — CLI-only pipeline that generates a sideloadable, unsigned
# HuntingGame.ipa from the SwiftUI Xcode project, ready for AltStore,
# SideStore, TrollStore, or a developer-signed install via Xcode/ideviceinstaller.
#
# Requires: macOS + Xcode command line tools (xcodebuild), and XcodeGen
# (https://github.com/yonaskolb/XcodeGen) to materialize the .xcodeproj from
# ios/HuntingGame/project.yml. Install XcodeGen with `brew install xcodegen`.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="${ROOT_DIR}/ios/HuntingGame"
APP_NAME="HuntingGame"
SCHEME="HuntingGame"
CONFIGURATION="Release"
BUILD_DIR="${ROOT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
IPA_DIR="${BUILD_DIR}/IPA"

log() { echo "==> $*"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: build_ipa.sh must be run on macOS with Xcode installed (xcodebuild is unavailable on $(uname -s))." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: xcodebuild not found. Install Xcode and the command line tools (xcode-select --install)." >&2
  exit 1
fi

log "Cleaning previous builds..."
rm -rf "${BUILD_DIR}"
mkdir -p "${IPA_DIR}"

if [[ ! -d "${IOS_DIR}/${APP_NAME}.xcodeproj" ]]; then
  log "No .xcodeproj found — generating one from project.yml via XcodeGen..."
  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "ERROR: xcodegen not found. Install it with 'brew install xcodegen' or commit a prebuilt .xcodeproj." >&2
    exit 1
  fi
  (cd "${IOS_DIR}" && xcodegen generate)
fi

log "Archiving iOS application without code signing for sideloading..."
xcodebuild archive \
  -project "${IOS_DIR}/${APP_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -archivePath "${ARCHIVE_PATH}" \
  -destination "generic/platform=iOS" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED="NO" \
  CODE_SIGNING_REQUIRED="NO" \
  CODE_SIGN_IDENTITY="" \
  ONLY_ACTIVE_ARCH=NO

APP_BUNDLE="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
if [[ ! -d "${APP_BUNDLE}" ]]; then
  echo "ERROR: expected app bundle not found at ${APP_BUNDLE}" >&2
  exit 1
fi

log "Packaging into sideloadable Payload/ structure..."
mkdir -p "${IPA_DIR}/Payload"
cp -R "${APP_BUNDLE}" "${IPA_DIR}/Payload/"

log "Creating final ${APP_NAME}.ipa bundle..."
(
  cd "${IPA_DIR}"
  zip -qr "${APP_NAME}.ipa" Payload
  rm -rf Payload
)

echo "=========================================================================="
echo "SUCCESS: Sideloadable IPA generated at ${IPA_DIR}/${APP_NAME}.ipa"
echo "Ready for AltStore, SideStore, TrollStore, or direct developer deployment."
echo "Note: this IPA is unsigned. Sideloading tools (AltStore/SideStore) will"
echo "re-sign it with your Apple ID during installation; TrollStore installs"
echo "unsigned IPAs directly on supported devices."
echo "=========================================================================="
