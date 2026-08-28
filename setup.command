#!/usr/bin/env bash
#
# Double-click this file in Finder right after cloning the repo (or after
# Xcode's File > Clone Repository... finishes) to generate the Xcode project
# and open it automatically.
#
# Why this step exists at all: the .xcodeproj is generated from
# ios/HuntingGame/project.yml via XcodeGen rather than committed to git —
# committed .xcodeproj files are a well-known source of noisy, hard-to-review
# merge conflicts every time a file is added/removed. This script is the
# one-click stand-in for the "open a project" step that a committed
# .xcodeproj would normally give you for free.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="${ROOT_DIR}/ios/HuntingGame"
PROJECT_PATH="${IOS_DIR}/HuntingGame.xcodeproj"

echo "==> Hunting Game project setup"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script needs macOS + Xcode. Run it on your Mac after cloning the repo." >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> XcodeGen not found."
  if command -v brew >/dev/null 2>&1; then
    echo "==> Installing it via Homebrew (brew install xcodegen)..."
    brew install xcodegen
  else
    echo "Install Homebrew first (https://brew.sh), then run: brew install xcodegen" >&2
    echo "Or install XcodeGen another way — see https://github.com/yonaskolb/XcodeGen#installing" >&2
    exit 1
  fi
fi

CONFIG_XCCONFIG="${IOS_DIR}/Config.xcconfig"
NEEDS_TEAM_ID=0
if [[ ! -f "${CONFIG_XCCONFIG}" ]]; then
  echo "==> First run: creating Config.xcconfig from the template..."
  cp "${IOS_DIR}/Config.xcconfig.example" "${CONFIG_XCCONFIG}"
  NEEDS_TEAM_ID=1
fi

echo "==> Generating HuntingGame.xcodeproj from project.yml..."
(cd "${IOS_DIR}" && xcodegen generate)

echo "==> Opening in Xcode..."
open "${PROJECT_PATH}"

echo "=========================================================================="
if [[ "${NEEDS_TEAM_ID}" -eq 1 ]]; then
  echo "IMPORTANT: edit ios/HuntingGame/Config.xcconfig and set DEVELOPMENT_TEAM"
  echo "to your real Apple Developer Team ID (Xcode -> Settings -> Accounts, or"
  echo "https://developer.apple.com/account/#/membership), then re-run this"
  echo "script (or re-run 'xcodegen generate') to pick it up. Without this,"
  echo "Xcode will show no team selected and installs to a device will fail."
  echo ""
fi
echo "Once Xcode is open:"
echo "  1. Confirm each of the 4 targets (HuntingGame, HuntingGameWidgets,"
echo "     HuntingGameWatch, HuntingGameWatchWidgets) shows your team under"
echo "     Signing & Capabilities -> Automatically manage signing"
echo "  2. Plug in your iPhone, select it as the run destination, and hit Run"
echo "See README.md for the full walkthrough (backend, Watch app, sideloading)."
echo "=========================================================================="
