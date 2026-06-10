#!/usr/bin/env bash
#
# package_app.sh — assemble the exímIABar .app bundle (EXB-1.6 stub; completed in S8).
#
# In this story (EXB-1.6) the script's load-bearing responsibility is the watchdog helper:
# it MUST copy `ClaudeBarWatchdog` into `Contents/Helpers/` and mark it executable (AC8).
# The remaining bundle assembly (signing, notarization, DMG) lands in EXB-1.8 (S8).
#
# Usage:  Scripts/package_app.sh [release|debug]
#
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT}/.build/${CONFIG}"
APP_NAME="exímIABar"
APP_BUNDLE="${ROOT}/build/${APP_NAME}.app"
EXECUTABLE="ClaudeBar"
WATCHDOG="ClaudeBarWatchdog"
INFO_PLIST="${ROOT}/Sources/ClaudeBar/Info.plist"

echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG" --product "$EXECUTABLE"
swift build -c "$CONFIG" --product "$WATCHDOG"

echo "==> Assembling bundle at ${APP_BUNDLE}"
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Helpers"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Main executable.
cp "${BUILD_DIR}/${EXECUTABLE}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE}"

# Info.plist (the bare executable already embeds it via -sectcreate; copy for Finder/Launch Services).
cp "${INFO_PLIST}" "${APP_BUNDLE}/Contents/Info.plist"

# AC8 — watchdog helper into Contents/Helpers with +x.
cp "${BUILD_DIR}/${WATCHDOG}" "${APP_BUNDLE}/Contents/Helpers/${WATCHDOG}"
chmod +x "${APP_BUNDLE}/Contents/Helpers/${WATCHDOG}"

echo "==> Verifying watchdog helper present and executable"
test -x "${APP_BUNDLE}/Contents/Helpers/${WATCHDOG}" \
  || { echo "FATAL: watchdog helper missing or not executable" >&2; exit 1; }

echo "==> Bundle structure:"
find "${APP_BUNDLE}" -maxdepth 3 -print

echo "==> Done. (Signing / notarization / DMG land in EXB-1.8.)"
