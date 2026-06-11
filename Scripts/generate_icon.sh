#!/usr/bin/env bash
#
# generate_icon.sh — produce the exímIABar app icon (AppIcon.icns).
#
# Dependency-free: uses only macOS system tooling (swift + CoreGraphics for the
# source PNG, sips for resizing, iconutil for the .icns container). No ImageMagick.
#
# Pipeline:
#   1. Render a 1024×1024 brand placeholder PNG (#CC7C5E background, white "eB").
#   2. Build AppIcon.iconset/ with every required size + @2x variant via sips.
#   3. iconutil -c icns → AppIcon.icns.
#   4. Place AppIcon.icns in Sources/ClaudeBar/Resources/.
#
# Usage:  Scripts/generate_icon.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RES_DIR="${ROOT}/Sources/ClaudeBar/Resources"
SOURCE_PNG="${SCRIPT_DIR}/app-icon-source.png"
ICONSET="${SCRIPT_DIR}/AppIcon.iconset"
ICNS_OUT="${RES_DIR}/AppIcon.icns"

mkdir -p "${RES_DIR}"

# ── Step 1 — render the 1024×1024 source PNG via CoreGraphics ───────────────────
# Generated only if missing, so a hand-tuned PNG committed to the repo wins.
if [[ ! -f "${SOURCE_PNG}" ]]; then
  echo "==> Rendering source PNG (CoreGraphics): ${SOURCE_PNG}"
  SWIFT_RENDER="$(mktemp -t eximiabar-icon).swift"
  cat > "${SWIFT_RENDER}" <<'SWIFT'
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments[1]

guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext") }

// Brand background #CC7C5E with rounded-rect mask (macOS app-icon squircle feel).
let bg = CGColor(red: 0xCC/255.0, green: 0x7C/255.0, blue: 0x5E/255.0, alpha: 1.0)
let inset: CGFloat = 80
let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - 2*inset, height: CGFloat(size) - 2*inset)
let path = CGPath(roundedRect: rect, cornerWidth: 180, cornerHeight: 180, transform: nil)
ctx.setFillColor(bg)
ctx.addPath(path)
ctx.fillPath()

// White "eB" centered.
let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ns
let text = "eB" as NSString
let font = NSFont.systemFont(ofSize: 440, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
]
let textSize = text.size(withAttributes: attrs)
let origin = CGPoint(
    x: (CGFloat(size) - textSize.width) / 2,
    y: (CGFloat(size) - textSize.height) / 2
)
text.draw(at: origin, withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()

guard let cgImage = ctx.makeImage() else { fatalError("makeImage") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! data.write(to: URL(fileURLWithPath: out))
SWIFT
  swift "${SWIFT_RENDER}" "${SOURCE_PNG}"
  rm -f "${SWIFT_RENDER}"
else
  echo "==> Using existing source PNG: ${SOURCE_PNG}"
fi

# ── Step 2 — build the iconset ─────────────────────────────────────────────────
echo "==> Building iconset"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

# size@scale → pixel dimension
gen() {
  local px="$1" name="$2"
  sips -z "${px}" "${px}" "${SOURCE_PNG}" --out "${ICONSET}/${name}" >/dev/null
}

gen 16   "icon_16x16.png"
gen 32   "icon_16x16@2x.png"
gen 32   "icon_32x32.png"
gen 64   "icon_32x32@2x.png"
gen 128  "icon_128x128.png"
gen 256  "icon_128x128@2x.png"
gen 256  "icon_256x256.png"
gen 512  "icon_256x256@2x.png"
gen 512  "icon_512x512.png"
gen 1024 "icon_512x512@2x.png"

# ── Step 3 — pack into .icns ───────────────────────────────────────────────────
echo "==> Packing AppIcon.icns"
iconutil -c icns "${ICONSET}" -o "${ICNS_OUT}"
rm -rf "${ICONSET}"

echo "==> Done. Icon at: ${ICNS_OUT} ($(du -h "${ICNS_OUT}" | cut -f1))"
