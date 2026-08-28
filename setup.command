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

echo "==> Generating HuntingGame.xcodeproj from project.yml..."
(cd "${IOS_DIR}" && xcodegen generate)

echo "==> Opening in Xcode..."
open "${PROJECT_PATH}"

echo "=========================================================================="
echo "Done. Once Xcode opens:"
echo "  1. Select the HuntingGame target -> Signing & Capabilities"
echo "  2. Check 'Automatically manage signing' and pick your personal team"
echo "  3. Plug in your iPhone, select it as the run destination, and hit Run"
echo "See README.md for the full walkthrough (backend, Watch app, sideloading)."
echo "=========================================================================="
