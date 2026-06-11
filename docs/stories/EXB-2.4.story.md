# Story EXB-2.4: Auto-Updater via GitHub Releases

**ID:** EXB-2.4
**Status:** InReview
**Depends on:** EXB-1.8 (bundle + Info.plist with CFBundleShortVersionString), EXB-1.5 (Settings/About pane)
**Epic:** EPIC-EXB
**Wave:** Onda 4 (v1.1.0)
**Executor:** @dev
**Quality gate:** @architect

---

## Story

**As a** user who installed exímIABar from a GitHub release,
**I want** the app to check for and install updates automatically,
**so that** I always have the latest version without manually re-downloading from GitHub.

---

## Acceptance Criteria

1. The About pane in Settings contains a "Check for Updates" button and a version label (`"Version 1.1.0"`). The button triggers an update check.
2. Update check: `GET https://api.github.com/repos/eximIA-Ventures/eximiabar/releases/latest` with `User-Agent: exímIABar/{version}` header. The check runs entirely off the main thread.
3. Version comparison: parse `tag_name` from the response (format `"v1.1.0"`), strip the leading `"v"`, compare with `CFBundleShortVersionString` using semver component comparison (`Int` per component: major, minor, patch). If remote > local → update available.
4. UI states for the update check flow (displayed in the About pane next to or below the button):
   - `checking` — spinner + `"Checking for updates…"` label
   - `upToDate` — `"You're up to date. (v{version})"` in secondary color
   - `available(version: String)` — `"Version {version} available."` + `"Download and Install"` button
   - `downloading` — `ProgressView(value: progress)` (determinate if Content-Length known, indeterminate otherwise) + `"Downloading {version}…"`
   - `installing` — spinner + `"Installing…"`
   - `error(message: String)` — error text in `systemRed` + `"Retry"` button
5. Download: use the first asset in `release.assets` whose `name` ends in `.zip`. Download to a temp directory (`FileManager.default.temporaryDirectory`) using `URLSession.shared.download(for:)` (async, off main thread).
6. Extract: run `ditto -x -k {zipPath} {extractDir}` via `Process` on a background thread (`Thread` + `CheckedContinuation` bridge — same pattern as `PTYRunner` in EXB-1.6). Validate that the extracted path contains `ExímIABar.app`.
7. Validate bundle: confirm `Contents/MacOS/ClaudeBar` exists and is executable in the extracted app. If invalid, show error state with `"Downloaded bundle is invalid."`.
8. Install: determine the currently running app path via `Bundle.main.bundleURL`. If the parent directory is writable:
   a. Remove the existing `.app` at that path.
   b. Move (or copy) the new `.app` into that directory.
   c. `chmod -R +x` on the new `.app` executable.
   d. Re-codesign ad-hoc: `codesign --force --sign - --deep --timestamp=none {newAppPath}` via `Process`.
9. Relaunch: after successful install, relaunch via a detached shell script that sleeps 1 second then opens the new `.app`:
   ```bash
   /bin/bash -c "sleep 1 && open -a '{newAppPath}'" &
   ```
   Then call `NSApp.terminate(nil)`.
10. Error cases that must be handled gracefully (show error state, no crash):
    - No network / DNS failure: show `"No network connection."`
    - GitHub API rate-limited (HTTP 403/429): show `"Rate limited. Try again later."`
    - Release has no `.zip` asset: show `"No downloadable asset found for this release."`
    - App running from a read-only location (e.g., `/Applications` without write access): show `"Cannot update: app location is not writable. Move the app to ~/Applications or run as admin."`
    - Extraction failure: show `"Failed to extract update."`
11. The entire update pipeline (check → download → extract → install → relaunch) runs off the main thread. The main thread is touched only to update the UI state (`@MainActor`).
12. `swift build` zero new warnings.

---

## Tasks

- [x] **T1 — UpdateChecker actor** (`Sources/ClaudeBarCore/Updater/UpdateChecker.swift` — see Deviation #1)
  - [x] `actor UpdateChecker`
  - [x] `struct ReleaseInfo { version: String; downloadURL: URL; assetName: String }`
  - [x] `func checkForUpdates(currentVersion:) async throws -> UpdateCheckResult` (enum: `.upToDate` / `.available(ReleaseInfo)`)
  - [x] GitHub API call with `User-Agent: exímIABar/{version}` header
  - [x] Semver comparison (AC3) — `SemanticVersion.isNewer(remote:than:)`
  - [x] Handle HTTP 403/429 (→ `.rateLimited`), no-asset (→ `.noAsset`), network (→ `.noNetwork`) cases

- [x] **T2 — Updater pipeline actor** (`Sources/ClaudeBar/Updater/AppUpdater.swift`)
  - [x] `actor AppUpdater`
  - [x] `func downloadAndInstall(release:onProgress:) async throws`
  - [x] Step 1: download zip to temp dir (URLSession async download; indeterminate progress per Dev Notes)
  - [x] Step 2: extract via `ditto` subprocess (PTYRunner-style `Thread` + `CheckedContinuation`)
  - [x] Step 3: validate bundle (AC7) — `Contents/MacOS/ClaudeBar` exists + executable
  - [x] Step 4: determine install path + write check (AC8) — pre-flight before download
  - [x] Step 5: remove old, move new, chmod, re-codesign ad-hoc (AC8d)
  - [x] Step 6: detached relaunch script + `NSApp.terminate` (AC9)

- [x] **T3 — UpdateState + ViewModel** (`Sources/ClaudeBar/Updater/UpdateViewModel.swift`)
  - [x] `enum UpdateState: Equatable` — idle / checking / upToDate / available(version) / downloading(Double) / installing / error(message)
  - [x] `@MainActor final class UpdateViewModel: ObservableObject { @Published var state: UpdateState }`
  - [x] Methods: `checkForUpdates()`, `downloadAndInstall(release:)`, `installPendingRelease()` — drive the actor pipeline, publish state on main thread

- [x] **T4 — About pane UI update** (`Sources/ClaudeBar/Updater/UpdateSectionView.swift` embedded in `PreferencesAboutPane.swift`)
  - [x] Add `UpdateViewModel` as `@StateObject` in `PreferencesAboutPane`
  - [x] "Check for Updates" button (AC1)
  - [x] State-driven UI: spinner / label / progress bar / error text per AC4 states
  - [x] "Download and Install" button (appears only in `.available` state)

- [x] **T5 — Writable path check** (AC8 / AC10 — read-only location)
  - [x] `FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)` — `AppUpdater.parentIsWritable(of:)`
  - [x] Show specific error message if not writable (`update.error.not_writable`)

- [x] **T6 — Build clean** (AC12)
  - [x] `swift build` zero new warnings (debug + `-c release`)
  - [x] `swift test` zero regressions — 175 tests pass (145 baseline + 30 new: semver, checker, view model)

---

## Dev Notes

### GitHub Releases API
```
GET https://api.github.com/repos/eximIA-Ventures/eximiabar/releases/latest
Accept: application/vnd.github+json
User-Agent: exímIABar/1.1.0
```
Response shape (relevant fields):
```json
{
  "tag_name": "v1.1.0",
  "assets": [
    { "name": "ExímIABar-1.1.0.zip", "browser_download_url": "https://github.com/.../ExímIABar-1.1.0.zip" }
  ]
}
```

### Semver comparison
```swift
func isNewer(remote: String, local: String) -> Bool {
    func components(_ v: String) -> [Int] {
        v.split(separator: ".").compactMap { Int($0) }
    }
    let r = components(remote), l = components(local)
    for (rv, lv) in zip(r, l) {
        if rv != lv { return rv > lv }
    }
    return r.count > l.count
}
```

### ditto extraction (PTYRunner-style)
```swift
// Thread + CheckedContinuation bridge (same pattern as CLISession in EXB-1.6)
func extract(zipURL: URL, to destURL: URL) async throws {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zipURL.path, destURL.path]
            do {
                try p.run(); p.waitUntilExit()
                if p.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: UpdateError.extractionFailed)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
```

### URLSession async download with progress
```swift
let (tempURL, response) = try await URLSession.shared.download(from: downloadURL)
// Progress: use URLSession delegate if determinate progress is needed,
// or treat as indeterminate (simpler, acceptable for typical release sizes < 20MB).
```

### Relaunch script
The 1-second sleep gives the current process time to terminate cleanly before the new instance opens:
```swift
let newPath = installedAppURL.path
let script = "/bin/bash -c \"sleep 1 && open -a '\(newPath)'\" &"
Process.launchedProcess(launchPath: "/bin/bash", arguments: ["-c", script])
NSApp.terminate(nil)
```

### Anti-freeze invariants
- `URLSession.shared.download(from:)` is already async — call from `Task.detached` or actor method.
- `Process.waitUntilExit()` is blocking — MUST run on a background `Thread` (CheckedContinuation bridge), never on MainActor or Swift cooperative thread pool.
- All UI updates via `await MainActor.run { viewModel.state = ... }`.

### Source tree additions
```
Sources/ClaudeBar/Updater/
  UpdateChecker.swift
  AppUpdater.swift
  UpdateViewModel.swift
```

---

## Definition of Done

- [x] "Check for Updates" button present in About pane
- [x] All 5 UI states (checking / upToDate / available / downloading / installing / error) render correctly
- [x] Update check correctly identifies a newer semver tag from the GitHub API (unit-tested against fixtures)
- [x] Download + extract + validate + install pipeline completes without main-thread blocking (actor + dedicated-thread subprocess bridge)
- [x] Read-only location detected and error shown with clear instruction
- [ ] App relaunches successfully after install (manual test — deferred to EXB-2.5 with a real release; no repo/release exists yet)
- [x] `swift build` zero new warnings
- [x] `swift test` zero regressions

---

## Dev Agent Record

**Agent:** @dev (Dex) · **Mode:** YOLO · **Date:** 2026-06-11

### File List

**New — `ClaudeBarCore` (UI-free, testable):**
- `Sources/ClaudeBarCore/Updater/UpdateChecker.swift` — `actor UpdateChecker`, `ReleaseInfo`, `UpdateCheckResult`, `UpdateError`, GitHub release decode (AC2/AC3/AC5/AC10)
- `Sources/ClaudeBarCore/Updater/SemanticVersion.swift` — component-wise semver comparison (AC3)

**New — `ClaudeBar` (app target):**
- `Sources/ClaudeBar/Updater/AppUpdater.swift` — `actor AppUpdater`: download → `ditto` extract → validate → install → codesign → relaunch (AC5–AC9), dedicated-thread subprocess bridge
- `Sources/ClaudeBar/Updater/UpdateViewModel.swift` — `@MainActor` `UpdateViewModel` + `UpdateState` enum, error→message mapping (AC4/AC10)
- `Sources/ClaudeBar/Updater/UpdateSectionView.swift` — state-driven About-pane UI (AC1/AC4)

**Modified:**
- `Sources/ClaudeBar/Settings/PreferencesAboutPane.swift` — embed `UpdateSectionView`; corrected repo URL casing to `eximIA-Ventures`
- `Sources/ClaudeBar/Resources/en.lproj/Localizable.strings` — 18 `update.*` keys
- `Sources/ClaudeBar/Resources/pt-BR.lproj/Localizable.strings` — 18 `update.*` keys (full pt-BR localization)

**New — tests:**
- `Tests/ClaudeBarCoreTests/SemanticVersionTests.swift` — 8 tests (AC3)
- `Tests/ClaudeBarCoreTests/UpdateCheckerTests.swift` — 14 tests (parse, decision, HTTP/network mapping)
- `Tests/ClaudeBarCoreTests/Fixtures/GitHubReleaseFixtures.swift` — canned releases/latest payloads
- `Tests/ClaudeBarTests/UpdateViewModelTests.swift` — 7 tests (state machine + localized errors)
- `Tests/ClaudeBarTests/UpdateStubTransport.swift` — app-target `HTTPTransport` stub

### Justified Deviations

1. **`UpdateChecker` + `SemanticVersion` placed in `ClaudeBarCore`, not `ClaudeBar/Updater/`** (Dev Notes source tree). Reason: the existing `HTTPTransport`/`StubTransport` test seam lives in Core, and AC3 semver + AC2/AC10 network-error mapping are pure, UI-free logic that belong in the no-UI library — mirroring how `UsageFetcher` (network) lives in Core while its UI lives in the app target. The download/install pipeline + UI stay in `ClaudeBar/Updater/` per the story. This makes the network/version logic unit-testable without AppKit.
2. **GitHub endpoint is a configurable constant** (`UpdateChecker.defaultLatestReleaseURL`, injectable via `init`) per the spawn brief's "URL as a configurable constant; tests use fixtures." The live flow is validated for real in EXB-2.5.
3. **Relaunch uses `Process()` + `process.run()`** instead of the deprecated `Process.launchedProcess(launchPath:arguments:)` shown in Dev Notes. Functionally identical detached `bash -c "sleep 1 && open -a …"`, avoids a deprecation warning (AC12 zero-warnings).
4. **Download progress is indeterminate** (`URLSession.download(from:)` exposes no fraction). Dev Notes explicitly permit this ("treat as indeterminate, simpler, acceptable for < 20 MB"). The UI renders a determinate bar if a fraction ever arrives, indeterminate otherwise (AC4).
5. **Version label reads `CFBundleShortVersionString` dynamically** (currently `1.0.0`), not a hardcoded `"Version 1.1.0"`. @devops bumps the version to `1.1.0` in EXB-2.5 (its AC2); the literal in AC1 is the expected runtime value *after* that bump. Hardcoding would break the existing dynamic About-pane version display and contradict AC3.

### IDS Decisions

- **REUSE** `HTTPTransport`/`HTTPClient` for the GitHub call (already async, header-aware, test-seamed).
- **ADAPT** the `Thread` + single-resume `CheckedContinuation` subprocess bridge from `ClaudePTYRunner` for `ditto`/`chmod`/`codesign` (simpler — `Process`, no PTY). < 30% surface, no existing consumers touched.
- **REUSE** the `L()` localization helper + `.lproj` strings pattern for all UI text.
- **CREATE** `SemanticVersion` (no prior semver code), `UpdateChecker`/`AppUpdater`/`UpdateViewModel`/`UpdateSectionView` (new capability — auto-update), `UpdateError` (new error domain).

### Validation

- `swift build` — Build complete, zero warnings (debug + `-c release`).
- `swift test` — `Test run with 175 tests in 24 suites passed` (145 baseline + 30 new, zero regressions).
- AC11 anti-freeze: `UpdateChecker`/`AppUpdater` are actors (off-main); subprocesses run on a dedicated `Thread` bridged by `CheckedContinuation`; `URLSession.download` is async; UI mutations are `@MainActor`-only. No `Data(contentsOf:)`/sync parse on main.

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-11 | 1.0 | Initial draft — Onda 4 (v1.1.0) | @sm River |
| 2026-06-11 | 1.1 | Implemented all 12 ACs — UpdateChecker (Core) + AppUpdater/UpdateViewModel/UpdateSectionView (app), 18 i18n keys ×2, 30 new tests. Status Draft → InReview. | @dev Dex |
