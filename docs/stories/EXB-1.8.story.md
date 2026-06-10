# Story EXB-1.8: Packaging + Polish

**ID:** EXB-1.8
**Status:** Ready
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

- [ ] **T1 — LICENSE**
  - [ ] Create `LICENSE` at repo root with MIT text (AC1)
  - [ ] Include both copyright lines: original CodexBar (Peter Steinberger) + this fork (exímIA)

- [ ] **T2 — Info.plist** (`Sources/ClaudeBar/Resources/Info.plist` or `ClaudeBar/Info.plist`)
  - [ ] Add all keys from AC3
  - [ ] `LSUIElement = YES` — critical for menu bar agent behavior
  - [ ] Reference `Package.swift` `linkerSettings` or resource declaration to include plist in bundle

- [ ] **T3 — App icon generation** (`Scripts/generate_icon.sh`)
  - [ ] Create `Scripts/generate_icon.sh`: generates `AppIcon.iconset/` with all required sizes (16, 32, 64, 128, 256, 512, 1024 px + @2x variants) using `sips -z <size> <size> source.png`
  - [ ] Run `iconutil -c icns AppIcon.iconset -o AppIcon.icns`
  - [ ] Place result in `Sources/ClaudeBar/Resources/AppIcon.icns`
  - [ ] Create source PNG: `Scripts/app-icon-source.png` (1024×1024, brand color `#CC7C5E` background, white "eB" or crab silhouette initials — simplest acceptable placeholder)
  - [ ] Add `AppIcon.icns` to `Package.swift` resources

- [ ] **T4 — package_app.sh** (`Scripts/package_app.sh`)
  - [ ] Implement all steps from AC2a–AC2h
  - [ ] Use `SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)` for path resolution
  - [ ] Universal build: `--arch arm64 --arch x86_64`
  - [ ] `mkdir -p dist/ExímIABar.app/Contents/{MacOS,Helpers,Resources}`
  - [ ] `codesign --force --sign - --deep --timestamp=none dist/ExímIABar.app`
  - [ ] Print summary: `echo "Built: dist/ExímIABar.app ($(du -sh dist/ExímIABar.app | cut -f1))"`

- [ ] **T5 — Makefile**
  - [ ] Implement all 5 targets from AC5
  - [ ] `make install`: `cp -R dist/ExímIABar.app ~/Applications/`
  - [ ] `make uninstall`: `rm -rf ~/Applications/ExímIABar.app`

- [ ] **T6 — Fix any build warnings**
  - [ ] Run `swift build -c release` and resolve all warnings
  - [ ] Common Swift 6 issues: missing `Sendable` conformances, MainActor isolation warnings, deprecated APIs

- [ ] **T7 — README.md**
  - [ ] Minimal README per AC10: description, requirements, `make build && make install` instructions, license section with CodexBar attribution

- [ ] **T8 — Final integration test**
  - [ ] `make build` succeeds on macOS 14+ / Xcode 16+
  - [ ] `make install` puts app in `~/Applications/`
  - [ ] Launch app → icon appears in menu bar within 3 s
  - [ ] Click icon → popover opens with live data (if Claude Code installed)
  - [ ] `swift test` — zero failures
  - [ ] `codesign -vvv dist/ExímIABar.app` — no error output

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

- [ ] `make build` runs end-to-end without error on macOS 14+ / Xcode 16+
- [ ] `dist/ExímIABar.app` produced, size < 15 MB
- [ ] `codesign -vvv dist/ExímIABar.app` exits 0
- [ ] `Contents/Helpers/ClaudeBarWatchdog` is executable Mach-O (verified by `file` command)
- [ ] `make install` → app in `~/Applications/ExímIABar.app`
- [ ] Launched app shows menu bar icon within 3 s on macOS 14
- [ ] `swift test` passes with zero failures
- [ ] `swift build -c release` zero warnings
- [ ] `LICENSE` file contains both copyright notices (CodexBar + exímIA)
- [ ] `README.md` contains attribution to CodexBar and build instructions

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-10 | 1.0 | Initial draft | @sm River |
| 2026-06-10 | 1.1 | Validated GO (8/10) — Status: Draft → Ready. No content changes required. | @po Pax |
