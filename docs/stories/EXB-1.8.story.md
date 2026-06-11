# Story EXB-1.8: Packaging + Polish

**ID:** EXB-1.8
**Status:** Review
**Depends on:** EXB-1.1 through EXB-1.7 (all stories complete)
**Epic:** EPIC-EXB
**Executor:** @dev
**Quality gate:** @devops

---

## Story

**As a** developer releasing exímIABar,
**I want** a repeatable build script that produces a universal signed `.app` bundle with the watchdog helper embedded, a proper `Info.plist`, app icon, MIT-attributed `LICENSE`, and a `Makefile` for local install/uninstall,
**so that** anyone can clone the repo and produce a distributable app with one command.

---

## Acceptance Criteria

1. `LICENSE` file at repo root: MIT License text with copyright `"Copyright (c) 2024 Peter Steinberger"` for the CodexBar original AND `"Copyright (c) 2026 exímIA / Hugo Capitelli"` for this fork. Both notices required (MIT attribution rule).
2. `package_app.sh` script at `Scripts/package_app.sh`:
   a. Runs `swift build -c release --arch arm64 --arch x86_64` (universal binary)
   b. Creates `ExímIABar.app/Contents/MacOS/` structure
   c. Copies `ClaudeBar` executable → `Contents/MacOS/ClaudeBar`
   d. Copies `ClaudeBarWatchdog` executable → `Contents/Helpers/ClaudeBarWatchdog` (with `chmod +x`)
   e. Copies `Resources/ProviderIcon-claude.svg` (and any other bundle resources) → `Contents/Resources/`
   f. Writes `Contents/Info.plist` with required keys (see AC3)
   g. Runs ad-hoc codesign: `codesign --force --sign - --deep --timestamp=none ExímIABar.app`
   h. Outputs: `ExímIABar.app` in `dist/` directory
3. `Info.plist` keys (minimum required):
   ```xml
   CFBundleIdentifier      com.eximia.eximiabar
   CFBundleName            exímIABar
   CFBundleDisplayName     exímIABar
   CFBundleExecutable      ClaudeBar
   CFBundleVersion         1.0.0
   CFBundleShortVersionString  1.0.0
   LSUIElement             YES
   NSPrincipalClass        NSApplication
   CFBundlePackageType     APPL
   NSHumanReadableCopyright  Copyright © 2026 exímIA. Based on CodexBar (MIT) by Peter Steinberger.
   ```
4. App icon (`AppIcon.icns`): generate from a placeholder 1024×1024 PNG (can be a solid `#CC7C5E` square with `"CB"` text) using `sips` + `iconutil`. The script `Scripts/generate_icon.sh` produces `AppIcon.icns` and places it in the `Resources/` directory. `CFBundleIconFile = AppIcon` in `Info.plist`.
5. `Makefile` at repo root with targets:
   - `make build` — runs `package_app.sh`
   - `make install` — copies `dist/ExímIABar.app` to `~/Applications/`
   - `make uninstall` — removes `~/Applications/ExímIABar.app`
   - `make clean` — removes `dist/` and `.build/`
   - `make test` — runs `swift test`
6. `swift build -c release` must produce zero warnings for all targets.
7. The built `.app` launches on macOS 14+ (Sonoma) and shows the menu bar icon within 3 s of launch.
8. `codesign -vvv dist/ExímIABar.app` passes (ad-hoc signature is valid). Note: ad-hoc signing means no App Store distribution, no Gatekeeper pass without explicit user approval — this is acceptable for this release.
9. `Contents/Helpers/ClaudeBarWatchdog` is an executable Mach-O binary (verified by `file Contents/Helpers/ClaudeBarWatchdog` showing `Mach-O`).
10. README at `README.md` (minimal): project name, one-line description, requirements (macOS 14+, Claude Code installed, Swift 6.2), build instructions (`make build && make install`), license notice with link to original CodexBar.
11. After `make install`, the app can be launched from `/Applications/` or `~/Applications/` and registers as LSUIElement.
12. `swift test` (all test targets) passes with zero failures.

---

## Tasks

- [x] **T1 — LICENSE**
  - [x] Create `LICENSE` at repo root with MIT text (AC1)
  - [x] Include both copyright lines: original CodexBar (Peter Steinberger) + this fork (exímIA)

- [x] **T2 — Info.plist** (`Sources/ClaudeBar/Info.plist`)
  - [x] Add all keys from AC3 (added `CFBundleExecutable`, `CFBundleIconFile`; bumped versions to `1.0.0`; copyright string per AC3)
  - [x] `LSUIElement = YES` — critical for menu bar agent behavior (already present; verified)
  - [x] `Package.swift` already embeds the plist via `-sectcreate __TEXT,__info_plist` (bare-exe agent); `package_app.sh` also copies it to `Contents/Info.plist`

- [x] **T3 — App icon generation** (`Scripts/generate_icon.sh`)
  - [x] Created `Scripts/generate_icon.sh`: builds `AppIcon.iconset/` with all required sizes (16/32/64/128/256/512/1024 + @2x) via `sips`
  - [x] Runs `iconutil -c icns AppIcon.iconset -o AppIcon.icns`
  - [x] Places result in `Sources/ClaudeBar/Resources/AppIcon.icns`
  - [x] Source PNG `Scripts/app-icon-source.png` (1024×1024, `#CC7C5E`, white "eB") — rendered dependency-free via inline CoreGraphics (no ImageMagick on host)
  - [x] Added `AppIcon.icns` to `Package.swift` resources

- [x] **T4 — package_app.sh** (`Scripts/package_app.sh`)
  - [x] Implements all steps AC2a–AC2h
  - [x] `SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` path resolution
  - [x] Universal build: `--arch arm64 --arch x86_64` (SwiftPM emits a fat binary at `--show-bin-path`; `lipo`-fuse fallback kept defensively)
  - [x] `mkdir -p dist/ExímIABar.app/Contents/{MacOS,Helpers,Resources}`
  - [x] `codesign --force --sign - --deep --timestamp=none` (helper signed inside-out first)
  - [x] Prints `Built: dist/ExímIABar.app (4.4M)`

- [x] **T5 — Makefile**
  - [x] All 5 targets (build/install/uninstall/clean/test) + `icon`, `help`
  - [x] `make install`: `cp -R dist/ExímIABar.app ~/Applications/` (with `mkdir -p`)
  - [x] `make uninstall`: `rm -rf ~/Applications/ExímIABar.app`

- [x] **T6 — Fix any build warnings**
  - [x] `swift build -c release` — zero warnings, zero errors (confirmed before and after resource change)

- [x] **T7 — README.md**
  - [x] Minimal README per AC10: description, requirements, `make build && make install`, license section with CodexBar attribution + screenshot placeholder

- [x] **T8 — Final integration test**
  - [x] `make build` succeeds on macOS 26.3 / Xcode 26.2 (cold build ~14s)
  - [x] `make install` puts app in `~/Applications/` (verified) → `make uninstall` removes it
  - [x] Launch verified: `open` → `pgrep -lx ClaudeBar` found PID alive after 5s → `pkill` clean (see Dev Agent Record)
  - [ ] Click icon → popover live data — requires interactive GUI session; deferred to @qa manual check
  - [x] `swift test` — 130 tests, zero failures (no regression)
  - [x] `codesign -vvv dist/ExímIABar.app` — exit 0, "satisfies its Designated Requirement"

---

## Dev Notes

### Universal binary build
`swift build -c release --arch arm64 --arch x86_64` produces two separate binaries. To make a universal (fat) binary:
```bash
lipo -create \
  .build/arm64-apple-macosx/release/ClaudeBar \
  .build/x86_64-apple-macosx/release/ClaudeBar \
  -output dist/ExímIABar.app/Contents/MacOS/ClaudeBar
```
Same for `ClaudeBarWatchdog`.

### SwiftPM + Info.plist
SwiftPM does not auto-generate `Info.plist`. Include it as a resource in `Package.swift`:
```swift
.executableTarget(
    name: "ClaudeBar",
    resources: [
        .copy("Resources/Info.plist"),
        .copy("Resources/AppIcon.icns"),
        .copy("Resources/ProviderIcon-claude.svg"),
    ]
)
```
When building with `swift build`, the resource bundle is placed next to the binary. For the final `.app`, `package_app.sh` copies the plist to `Contents/Info.plist` (not `Contents/Resources/Info.plist`).

### Ad-hoc codesigning
Ad-hoc sign = `-` as identity. No Apple Developer account needed.
```bash
codesign --force --sign - --deep --timestamp=none ExímIABar.app
# Verify:
codesign -vvv ExímIABar.app
```
Users must right-click → Open on first launch (Gatekeeper policy for ad-hoc apps).

### Watchdog binary in bundle
The helper must be in `Contents/Helpers/` (not `Contents/MacOS/`) for sandboxed-style conventions. The main app launches it via:
```swift
Bundle.main.url(forAuxiliaryExecutable: "ClaudeBarWatchdog")
// → Contents/MacOS/../Helpers/ClaudeBarWatchdog
```
In `package_app.sh`, ensure `chmod +x` on the watchdog binary.

### App icon placeholder
The icon does not need to be polished for P0/P1. A 1024×1024 PNG with:
- Background: `#CC7C5E` (brand color)
- White text: `eB` centered in SF-like font, or simply a white crab outline
Generate with ImageMagick if available:
```bash
convert -size 1024x1024 xc:'#CC7C5E' \
  -font Helvetica-Bold -pointsize 400 -fill white \
  -gravity center -annotate 0 "eB" \
  Scripts/app-icon-source.png
```
Or commit a pre-made PNG.

### MIT License text
```
MIT License

Copyright (c) 2024 Peter Steinberger (CodexBar — https://github.com/PSPDFKit-labs/codexbar)
Copyright (c) 2026 exímIA / Hugo Capitelli (exímIABar)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Swift 6 common warning patterns to fix
1. `@Sendable` missing on closures passed to `Task.detached`
2. Actor isolation violations: accessing `@MainActor` vars from non-isolated context
3. `Transferable` / `Sendable` conformances for model types shared across actors
4. `Deprecated` APIs: `NSWorkspace.open(_:)` for URL opening is fine; check for any macOS 14 deprecations

---

## Definition of Done

- [x] `make build` runs end-to-end without error on macOS 26.3 / Xcode 26.2 (≥ macOS 14 / Xcode 16)
- [x] `dist/ExímIABar.app` produced, size **4.4 MB** (< 15 MB)
- [x] `codesign -vvv dist/ExímIABar.app` exits 0 ("valid on disk", "satisfies its Designated Requirement")
- [x] `Contents/Helpers/ClaudeBarWatchdog` is executable Mach-O universal (x86_64 + arm64), verified by `file`
- [x] `make install` → app in `~/Applications/ExímIABar.app` (verified, then uninstalled)
- [x] Launched app shows as menu bar agent (`pgrep` PID alive 5 s after `open`; LSUIElement true)
- [x] `swift test` passes with zero failures (130 tests, 18 suites)
- [x] `swift build -c release` zero warnings
- [x] `LICENSE` file contains both copyright notices (2024 Peter Steinberger + 2026 exímIA / Hugo Capitelli)
- [x] `README.md` contains attribution to CodexBar and build instructions

---

## Dev Agent Record

**Agent:** @dev (Dex) · **Date:** 2026-06-11 · **Status:** Review

### File List

**Created**
- `Scripts/generate_icon.sh` — dependency-free icon pipeline (CoreGraphics source render → sips iconset → iconutil .icns)
- `Scripts/app-icon-source.png` — 1024×1024 `#CC7C5E` "eB" placeholder (generated, committed)
- `Sources/ClaudeBar/Resources/AppIcon.icns` — packed icon (committed)
- `Makefile` — build / icon / install / uninstall / clean / test / help targets
- `README.md` — description, requirements, `make build && make install`, CodexBar attribution, screenshot placeholder

**Modified**
- `LICENSE` — dual MIT attribution per AC1 (2024 Peter Steinberger / CodexBar + 2026 exímIA / Hugo Capitelli)
- `Sources/ClaudeBar/Info.plist` — added `CFBundleExecutable`, `CFBundleIconFile=AppIcon`; versions → `1.0.0`; copyright string per AC3
- `Scripts/package_app.sh` — completed from EXB-1.6 stub: universal build, `dist/` output, resources, ad-hoc codesign, verification, summary
- `Package.swift` — added `Resources/AppIcon.icns` to `ClaudeBar` target resources
- `.gitignore` — added `dist/`

### Evidence

```
# Final bundle
Built: dist/ExímIABar.app (4.4M)

# codesign (AC8)
$ codesign -vvv dist/ExímIABar.app
dist/ExímIABar.app: valid on disk
dist/ExímIABar.app: satisfies its Designated Requirement
$ codesign --verify --deep --strict dist/ExímIABar.app   # exit 0

# Universal binaries
ClaudeBar:          x86_64 arm64
ClaudeBarWatchdog:  Mach-O universal binary [x86_64] [arm64]   (AC9)

# Launch test (open → 5s → pgrep → pkill)
$ open dist/ExímIABar.app          # exit 0
$ sleep 5; pgrep -lx ClaudeBar     # 11936 ClaudeBar  (alive)
$ pkill -x ClaudeBar               # cleanly terminated

# Regression guard
$ swift test                       # 130 tests, 18 suites — 0 failures
$ swift build -c release           # 0 warnings, 0 errors
```

### Completion Notes / Decisions

- **[AUTO-DECISION]** Icon source PNG generation → CoreGraphics inline Swift, not ImageMagick (host has no `convert`/`magick`; `sips`+`iconutil` are system tooling). Keeps the pipeline clone-and-build with zero external deps.
- **[AUTO-DECISION]** CodexBar URL → `github.com/steipete/CodexBar` (canonical, confirmed in reference README) rather than the stale `PSPDFKit-labs` URL in the story Dev Notes. Copyright year follows AC1 literally (`2024 Peter Steinberger`).
- **[AUTO-DECISION]** Universal binary sourced from SwiftPM's own fat output at `--show-bin-path` (modern toolchains fuse automatically); explicit `lipo` retained as a defensive fallback per Dev Notes.
- **[AUTO-DECISION]** `make install` adds `mkdir -p ~/Applications` (folder absent by default on fresh macOS) and removes any prior copy before `cp -R`.
- Codesign order: helper signed inside-out first, then `--deep` on the bundle — keeps the nested Mach-O signature valid.
- T8 "click icon → popover live data" left unchecked: requires an interactive GUI session; deferred to @qa manual verification.

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (8/10) — Status: Draft → Ready. No content changes required. | @po Pax |
| 2026-06-11 | 1.2 | Implemented all tasks T1–T8. Packaging pipeline complete, app launches, 130 tests green. Status: Ready → Review. | @dev Dex |
