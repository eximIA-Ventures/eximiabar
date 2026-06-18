#!/usr/bin/env bash
#
# generate_icon.sh — produce the exímIABar app icon (AppIcon.icns).  [EXB-4.2]
#
# ── Visual concept ─────────────────────────────────────────────────────────────
#   A macOS Big Sur+ squircle with depth:
#     • Dark vertical gradient background (#2D2D2D → #1A1A1A) — not flat.
#     • A terracota gauge arc (#CC7C5E) tracing ~70% of the circumference,
#       sweeping clockwise from ~8 o'clock to ~4 o'clock, leaving the gap at the
#       6 o'clock position — the visual metaphor for a rate-limit meter.
#     • The REAL eximIA brand symbol (Scripts/assets/eximia-simbolo.svg) centred,
#       recoloured to near-white (#F5F5F5), legible over the dark background.
#       The symbol is rasterised faithfully from its original SVG path data —
#       NEVER hand-redrawn.
#
# ── Toolchain (dependency-free — macOS built-ins only) ─────────────────────────
#   • swift + CoreGraphics  → render the 1024×1024 composition AND parse/draw the
#                             SVG symbol paths directly (no rsvg-convert/ImageMagick).
#   • sips                  → downscale to every iconset size + @2x variant.
#   • iconutil              → pack the iconset into AppIcon.icns.
#   No ImageMagick, Inkscape, Node.js, rsvg-convert, or Python deps required.
#
# ── Source of truth ────────────────────────────────────────────────────────────
#   SVG symbol : Scripts/assets/eximia-simbolo.svg
#                (copied from /…/JARVIS/LOGO/SVG/SIMBOLO.svg; viewBox 120.4×136.01)
#
# ── How to run ─────────────────────────────────────────────────────────────────
#   Scripts/generate_icon.sh          # regenerate AppIcon.icns from the SVG
#   make icon                         # same, via the Makefile target
#
# Idempotent: leaves no intermediate artefacts; the 1024 master + iconset dir are
# created under a temp dir and removed on completion. Re-running reproduces an
# identical icon (the composition is fully deterministic from the SVG).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RES_DIR="${ROOT}/Sources/ClaudeBar/Resources"
SVG_SRC="${SCRIPT_DIR}/assets/eximia-simbolo.svg"
ICNS_OUT="${RES_DIR}/AppIcon.icns"

# All intermediates live under a single temp dir so the script never litters the
# repo and is fully idempotent.
WORK_DIR="$(mktemp -d -t eximiabar-icon)"
MASTER_PNG="${WORK_DIR}/icon-1024.png"
ICONSET="${WORK_DIR}/AppIcon.iconset"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

mkdir -p "${RES_DIR}"

if [[ ! -f "${SVG_SRC}" ]]; then
  echo "FATAL: eximIA symbol SVG missing at ${SVG_SRC}" >&2
  exit 1
fi

# ── Step 1 — render the 1024×1024 master PNG via CoreGraphics ───────────────────
echo "==> Rendering 1024×1024 master (CoreGraphics) from ${SVG_SRC##*/}"
SWIFT_RENDER="${WORK_DIR}/render.swift"
cat > "${SWIFT_RENDER}" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

// ── Inputs ─────────────────────────────────────────────────────────────────────
let svgPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]
let size = 1024

// ── Minimal SVG path-data parser (covers M m L l H h V v C c S s Z z) ───────────
// Enough to render the eximIA symbol, whose two subpaths use M/m, L, C/c, S/s, Z.
struct SVGPathParser {
    let data: [Character]
    var i = 0
    init(_ s: String) { data = Array(s) }

    mutating func parse(into path: CGMutablePath) {
        var cur = CGPoint.zero          // current point
        var start = CGPoint.zero        // subpath start (for Z)
        var lastCtrl: CGPoint? = nil     // reflected control point for S/s
        var lastCmd: Character = " "

        while let cmd = nextCommand() {
            let relative = cmd.isLowercase
            switch Character(cmd.lowercased()) {
            case "m":
                let p = point(relative: relative, base: cur)
                cur = p; start = p; path.move(to: p)
                lastCtrl = nil
                // subsequent implicit pairs after M are treated as L
                while peekIsNumber() {
                    let q = point(relative: relative, base: cur)
                    cur = q; path.addLine(to: q)
                }
            case "l":
                while peekIsNumber() {
                    let p = point(relative: relative, base: cur)
                    cur = p; path.addLine(to: p)
                }
                lastCtrl = nil
            case "h":
                while peekIsNumber() {
                    let x = number()
                    cur = CGPoint(x: relative ? cur.x + x : x, y: cur.y)
                    path.addLine(to: cur)
                }
                lastCtrl = nil
            case "v":
                while peekIsNumber() {
                    let y = number()
                    cur = CGPoint(x: cur.x, y: relative ? cur.y + y : y)
                    path.addLine(to: cur)
                }
                lastCtrl = nil
            case "c":
                while peekIsNumber() {
                    let c1 = point(relative: relative, base: cur)
                    let c2 = point(relative: relative, base: cur)
                    let end = point(relative: relative, base: cur)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastCtrl = c2; cur = end
                }
            case "s":
                while peekIsNumber() {
                    // First control point is the reflection of the previous one.
                    let prevWasCubic = (lastCmd == "c" || lastCmd == "s" ||
                                        lastCmd == "C" || lastCmd == "S")
                    let c1: CGPoint
                    if let lc = lastCtrl, prevWasCubic {
                        c1 = CGPoint(x: 2*cur.x - lc.x, y: 2*cur.y - lc.y)
                    } else {
                        c1 = cur
                    }
                    let c2 = point(relative: relative, base: cur)
                    let end = point(relative: relative, base: cur)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    lastCtrl = c2; cur = end
                }
            case "z":
                path.closeSubpath(); cur = start; lastCtrl = nil
            default:
                break
            }
            lastCmd = cmd
        }
    }

    // ── token helpers ──────────────────────────────────────────────────────────
    mutating func skipSeparators() {
        while i < data.count {
            let c = data[i]
            if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1 }
            else { break }
        }
    }
    mutating func nextCommand() -> Character? {
        skipSeparators()
        guard i < data.count else { return nil }
        let c = data[i]
        if c.isLetter { i += 1; return c }
        return nil
    }
    mutating func peekIsNumber() -> Bool {
        skipSeparators()
        guard i < data.count else { return false }
        let c = data[i]
        return c.isNumber || c == "-" || c == "+" || c == "."
    }
    mutating func number() -> CGFloat {
        skipSeparators()
        var s = ""
        var seenDot = false
        var seenExp = false
        while i < data.count {
            let c = data[i]
            if c == "-" || c == "+" {
                // sign allowed at start, or right after an exponent marker
                if s.isEmpty || s.hasSuffix("e") || s.hasSuffix("E") { s.append(c); i += 1; continue }
                break
            } else if c == "." {
                if seenDot { break }       // a second dot starts a new number (e.g. ".5.5")
                seenDot = true; s.append(c); i += 1
            } else if c == "e" || c == "E" {
                if seenExp { break }
                seenExp = true; s.append(c); i += 1
            } else if c.isNumber {
                s.append(c); i += 1
            } else {
                break
            }
        }
        return CGFloat(Double(s) ?? 0)
    }
    mutating func point(relative: Bool, base: CGPoint) -> CGPoint {
        let x = number(); let y = number()
        return relative ? CGPoint(x: base.x + x, y: base.y + y) : CGPoint(x: x, y: y)
    }
}

// ── Read the SVG, extract viewBox + path `d=` strings ───────────────────────────
let svg = try! String(contentsOfFile: svgPath, encoding: .utf8)

func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
    let range = NSRange(text.startIndex..., in: text)
    guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}
func allMatches(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return re.matches(in: text, range: range).compactMap { m in
        m.numberOfRanges > 1 ? Range(m.range(at: 1), in: text).map { String(text[$0]) } : nil
    }
}

let viewBox = firstMatch(#"viewBox\s*=\s*"([^"]+)""#, in: svg) ?? "0 0 120.4 136.01"
let vbParts = viewBox.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
let vbW = CGFloat(vbParts.count > 2 ? vbParts[2] : 120.4)
let vbH = CGFloat(vbParts.count > 3 ? vbParts[3] : 136.01)

let dStrings = allMatches(#"<path[^>]*\sd\s*=\s*"([^"]+)""#, in: svg)
guard !dStrings.isEmpty else { fatalError("no <path d=…> found in SVG") }

// Build one combined CGPath for the symbol in SVG (y-down) coordinates.
let symbolPathSVG = CGMutablePath()
for d in dStrings {
    var parser = SVGPathParser(d)
    parser.parse(into: symbolPathSVG)
}

// ── CoreGraphics canvas ─────────────────────────────────────────────────────────
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext") }
ctx.interpolationQuality = .high
ctx.setShouldAntialias(true)

let S = CGFloat(size)

// ── Background: dark squircle with vertical gradient (#2D2D2D → #1A1A1A) ────────
// macOS Big Sur app-icon grid: the rounded square sits inside the 1024 canvas with
// a uniform margin; corner radius ≈ 22.37% of the squircle side.
let bgInset: CGFloat = S * 0.085
let bgRect = CGRect(x: bgInset, y: bgInset, width: S - 2*bgInset, height: S - 2*bgInset)
let corner = bgRect.width * 0.2237
let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let cs = CGColorSpaceCreateDeviceRGB()
let topColor    = CGColor(colorSpace: cs, components: [0x2D/255.0, 0x2D/255.0, 0x2D/255.0, 1.0])!
let bottomColor = CGColor(colorSpace: cs, components: [0x1A/255.0, 0x1A/255.0, 0x1A/255.0, 1.0])!
let gradient = CGGradient(colorsSpace: cs, colors: [topColor, bottomColor] as CFArray, locations: [0, 1])!
// Top → bottom (canvas is y-up, so start at top edge).
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 0, y: bgRect.maxY),
                       end:   CGPoint(x: 0, y: bgRect.minY),
                       options: [])
// Subtle inner top highlight for depth.
let highlight = CGGradient(colorsSpace: cs,
    colors: [CGColor(colorSpace: cs, components: [1, 1, 1, 0.06])!,
             CGColor(colorSpace: cs, components: [1, 1, 1, 0.0])!] as CFArray,
    locations: [0, 1])!
ctx.drawRadialGradient(highlight,
    startCenter: CGPoint(x: bgRect.midX, y: bgRect.maxY), startRadius: 0,
    endCenter:   CGPoint(x: bgRect.midX, y: bgRect.maxY), endRadius: bgRect.width * 0.9,
    options: [])
ctx.restoreGState()

// ── Gauge arc (#CC7C5E), ~70% of the circumference, gap at 6 o'clock ────────────
// In CoreGraphics (y-up) angles go counter-clockwise. 6 o'clock = -90° (pointing
// down). We want a gap centred on 6 o'clock spanning ~30% (≈108°), so the arc
// covers from -90°-126° … wrapping … to -90°+126°. Drawn as a single sweep from
// the left-bottom (~8 o'clock) clockwise over the top to the right-bottom (~4
// o'clock).  start = 234° (8 o'clock-ish), end = -54° (4 o'clock-ish), clockwise.
let arcCenter = CGPoint(x: bgRect.midX, y: bgRect.midY)
let arcRadius = bgRect.width * 0.355
let arcWidth  = bgRect.width * 0.055
let terracota = CGColor(colorSpace: cs, components: [0xCC/255.0, 0x7C/255.0, 0x5E/255.0, 1.0])!

func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }
let startAngle = deg(234)   // ~8 o'clock
let endAngle   = deg(-54)   // ~4 o'clock (i.e. 306°), swept clockwise across the top

ctx.saveGState()
ctx.setLineCap(.round)
ctx.setLineWidth(arcWidth)
ctx.setStrokeColor(terracota)
let arcPath = CGMutablePath()
arcPath.addArc(center: arcCenter, radius: arcRadius,
               startAngle: startAngle, endAngle: endAngle, clockwise: true)
ctx.addPath(arcPath)
ctx.strokePath()
ctx.restoreGState()

// ── eximIA symbol, recoloured #F5F5F5, centred ──────────────────────────────────
// Fit the symbol into a centred box, preserving aspect ratio. The symbol sits
// inside the gauge ring, so it occupies a moderate fraction of the icon.
let symbolBoxFraction: CGFloat = 0.40
let boxSide = bgRect.width * symbolBoxFraction
let scale = min(boxSide / vbW, boxSide / vbH)
let drawW = vbW * scale
let drawH = vbH * scale

// SVG is y-down; flip to y-up and translate so the symbol is centred on the icon.
var transform = CGAffineTransform.identity
transform = transform.translatedBy(x: bgRect.midX - drawW/2, y: bgRect.midY + drawH/2)
transform = transform.scaledBy(x: scale, y: -scale)   // flip Y
guard let symbolPath = symbolPathSVG.copy(using: &transform) else { fatalError("symbol transform") }

ctx.saveGState()
let symbolColor = CGColor(colorSpace: cs, components: [0xF5/255.0, 0xF5/255.0, 0xF5/255.0, 1.0])!
ctx.setFillColor(symbolColor)
ctx.addPath(symbolPath)
ctx.fillPath(using: .winding)
ctx.restoreGState()

// ── Write PNG ───────────────────────────────────────────────────────────────────
guard let cgImage = ctx.makeImage() else { fatalError("makeImage") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try! png.write(to: URL(fileURLWithPath: outPath))
SWIFT

swift "${SWIFT_RENDER}" "${SVG_SRC}" "${MASTER_PNG}"

# ── Step 2 — build the iconset (all required sizes + @2x variants) ──────────────
echo "==> Building iconset"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

# size@scale → pixel dimension. sips downscales the 1024 master with high quality.
gen() {
  local px="$1" name="$2"
  sips -z "${px}" "${px}" "${MASTER_PNG}" --out "${ICONSET}/${name}" >/dev/null
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

echo "==> Done. Icon at: ${ICNS_OUT} ($(du -h "${ICNS_OUT}" | cut -f1))"
