#!/usr/bin/env bash
#
# package_app.sh — assemble the distributable exímIABar .app bundle (EXB-1.8).
#
# Produces a universal (arm64 + x86_64) ad-hoc-signed .app in dist/:
#
#   dist/ExímIABar.app/Contents/
#     ├── Info.plist                     (LSUIElement agent — from Sources/ClaudeBar/Info.plist)
#     ├── MacOS/ClaudeBar                (universal main executable)
#     ├── Helpers/ClaudeBarWatchdog      (universal watchdog helper, +x)
#     └── Resources/
#         ├── AppIcon.icns               (CFBundleIconFile = AppIcon)
#         └── ProviderIcon-claude.svg
#
# Usage:  Scripts/package_app.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="ExímIABar"
DIST_DIR="${ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
EXECUTABLE="ClaudeBar"
WATCHDOG="ClaudeBarWatchdog"
INFO_PLIST="${ROOT}/Sources/ClaudeBar/Info.plist"
RES_DIR="${ROOT}/Sources/ClaudeBar/Resources"

# ── Step 0 — ensure the app icon exists ────────────────────────────────────────
if [[ ! -f "${RES_DIR}/AppIcon.icns" ]]; then
  echo "==> AppIcon.icns missing — generating"
  "${SCRIPT_DIR}/generate_icon.sh"
fi

# ── Step 1 — universal release build (AC2a) ────────────────────────────────────
echo "==> Building universal release (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

# Resolve a universal binary for a given product. SwiftPM emits a fat binary at
# BIN_PATH when building with two --arch flags; if a toolchain ever stops doing
# so, fall back to lipo-ing the per-arch release outputs.
resolve_universal() {
  local product="$1" dest="$2"
  local fat="${BIN_PATH}/${product}"
  if lipo -info "${fat}" 2>/dev/null | grep -q "arm64" && \
     lipo -info "${fat}" 2>/dev/null | grep -q "x86_64"; then
    cp "${fat}" "${dest}"
  else
    echo "==> ${product}: SwiftPM output not universal — fusing with lipo"
    lipo -create \
      "${ROOT}/.build/arm64-apple-macosx/release/${product}" \
      "${ROOT}/.build/x86_64-apple-macosx/release/${product}" \
      -output "${dest}"
  fi
}

# ── Step 2 — assemble the bundle skeleton (AC2b) ───────────────────────────────
echo "==> Assembling bundle at ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Helpers"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# ── Step 3 — main executable (AC2c) ────────────────────────────────────────────
resolve_universal "${EXECUTABLE}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE}"

# ── Step 4 — watchdog helper (AC2d / AC9) ──────────────────────────────────────
resolve_universal "${WATCHDOG}" "${APP_BUNDLE}/Contents/Helpers/${WATCHDOG}"
chmod +x "${APP_BUNDLE}/Contents/Helpers/${WATCHDOG}"

# ── Step 5 — bundle resources (AC2e) ───────────────────────────────────────────
cp "${RES_DIR}/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "${RES_DIR}/ProviderIcon-claude.svg" "${APP_BUNDLE}/Contents/Resources/ProviderIcon-claude.svg"

# ── Step 6 — Info.plist (AC2f) ─────────────────────────────────────────────────
# Goes to Contents/Info.plist (NOT Contents/Resources/Info.plist).
cp "${INFO_PLIST}" "${APP_BUNDLE}/Contents/Info.plist"

# ── Step 7 — ad-hoc codesign (AC2g) ────────────────────────────────────────────
# Sign helpers first (inside-out), then the bundle. --deep is convenient here;
# the nested helper is the only inner Mach-O, so an explicit pass keeps it valid.
echo "==> Ad-hoc codesigning"
codesign --force --sign - --timestamp=none "${APP_BUNDLE}/Contents/Helpers/${WATCHDOG}"
codesign --force --sign - --deep --timestamp=none "${APP_BUNDLE}"

echo "==> Verifying signature"
codesign -vvv "${APP_BUNDLE}"

# ── Step 8 — sanity checks ─────────────────────────────────────────────────────
test -x "${APP_BUNDLE}/Contents/Helpers/${WATCHDOG}" \
  || { echo "FATAL: watchdog helper missing or not executable" >&2; exit 1; }
file "${APP_BUNDLE}/Contents/Helpers/${WATCHDOG}" | grep -q "Mach-O" \
  || { echo "FATAL: watchdog helper is not a Mach-O binary" >&2; exit 1; }

# ── Step 9 — summary (AC2h) ────────────────────────────────────────────────────
echo "==> Bundle structure:"
find "${APP_BUNDLE}" -maxdepth 3 -print | sed "s|${DIST_DIR}/||"
echo "Built: dist/${APP_NAME}.app ($(du -sh "${APP_BUNDLE}" | cut -f1))"
