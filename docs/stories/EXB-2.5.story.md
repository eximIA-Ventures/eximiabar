# Story EXB-2.5: Distribution — GitHub Repo, Release v1.1.0, /Applications Install

**ID:** EXB-2.5
**Status:** Done
**Depends on:** EXB-2.1 through EXB-2.4 (all Onda 4 stories done), EXB-1.8 (Makefile + packaging pipeline)
**Epic:** EPIC-EXB
**Wave:** Onda 4 (v1.1.0)
**Executor:** @devops
**Quality gate:** @dev

---

## Story

**As a** developer releasing exímIABar v1.1.0,
**I want** to publish the app to a public GitHub repo, create a tagged release with the zip asset, update the Makefile to install to /Applications, and migrate the local installation from ~/Applications to /Applications,
**so that** the auto-updater (EXB-2.4) has a real release to check against and users can install from the canonical location.

---

## Acceptance Criteria

1. `Makefile` target `install` is changed to copy `dist/ExímIABar.app` to `/Applications/` (not `~/Applications/`). `uninstall` removes `/Applications/ExímIABar.app`. A new target `install-user` copies to `~/Applications/` as an explicit opt-in.
2. `Info.plist` `CFBundleShortVersionString` and `CFBundleVersion` are bumped to `1.1.0`.
3. `make build` runs clean (`swift build -c release`) producing `dist/ExímIABar.app` (universal, ad-hoc signed). Zero warnings.
4. The `.zip` asset is produced via `ditto -c -k --sequesterRsrc --keepParent dist/ExímIABar.app ExímIABar-1.1.0.zip`. This preserves codesignature, symlinks, and resource forks. `--keepParent` ensures the zip contains the `.app` as its root entry (required by the EXB-2.4 installer).
5. GitHub repo `eximIA-Ventures/eximiabar` is created as public via `gh repo create eximIA-Ventures/eximiabar --public --source=. --remote=origin --push`. If the repo already exists, skip creation and just push.
6. A git tag `v1.1.0` is created (`git tag v1.1.0`) and pushed (`git push origin v1.1.0`).
7. GitHub release `v1.1.0` is created via `gh release create v1.1.0 ExímIABar-1.1.0.zip --title "v1.1.0 — Onda 4" --notes "$(cat RELEASE_NOTES.md)"` with the zip as the single asset.
8. `RELEASE_NOTES.md` (temporary, not committed) or inline notes include: glassmorphism fix (EXB-2.1), language selector (EXB-2.2), local dashboard (EXB-2.3), auto-updater (EXB-2.4), /Applications install.
9. Migration: the currently running `ExímIABar.app` in `~/Applications/` (if present) is terminated (`pkill -x ClaudeBar`), removed (`rm -rf ~/Applications/ExímIABar.app`), and the new app is installed at `/Applications/` via `sudo cp -R dist/ExímIABar.app /Applications/` or `make install` (which may require sudo for `/Applications`). Confirm with `mdfind -name ExímIABar.app` and `pgrep ClaudeBar` after relaunch.
10. `README.md` is updated: installation section now shows `make install` (to `/Applications`) as the primary path, with a note about the `install-user` target for `~/Applications`. Add a "Releases" section with a link to `https://github.com/eximIA-Ventures/eximiabar/releases` and instructions for the auto-updater.
11. After release creation, the EXB-2.4 auto-updater's `UpdateChecker` is validated: it must successfully fetch `https://api.github.com/repos/eximIA-Ventures/eximiabar/releases/latest` and return the `v1.1.0` tag. (Manual smoke test — not an automated test.)
12. `swift test` passes with zero failures before pushing.

---

## Tasks

- [ ] **T1 — Bump version in Info.plist** (AC2)
  - [ ] `CFBundleShortVersionString` → `1.1.0`
  - [ ] `CFBundleVersion` → `1.1.0`

- [ ] **T2 — Update Makefile** (AC1)
  - [ ] `install`: `sudo cp -R dist/ExímIABar.app /Applications/`
  - [ ] `uninstall`: `sudo rm -rf /Applications/ExímIABar.app`
  - [ ] Add `install-user`: `cp -R dist/ExímIABar.app ~/Applications/` (no sudo)
  - [ ] Add note in Makefile comments: "install target requires write access to /Applications — run with sudo or ensure permissions"

- [ ] **T3 — Clean build + zip** (AC3, AC4)
  - [ ] `make build` — confirm zero warnings, `dist/ExímIABar.app` present
  - [ ] `ditto -c -k --sequesterRsrc --keepParent dist/ExímIABar.app ExímIABar-1.1.0.zip`
  - [ ] Verify zip: `unzip -l ExímIABar-1.1.0.zip | head` — should show `ExímIABar.app/` at root

- [ ] **T4 — swift test gate** (AC12)
  - [ ] `swift test` — all tests green, zero failures

- [ ] **T5 — GitHub repo creation + push** (AC5)
  - [ ] `gh repo create eximIA-Ventures/eximiabar --public --source=. --remote=origin --push`
  - [ ] If repo exists: `git remote set-url origin https://github.com/eximIA-Ventures/eximiabar.git && git push -u origin main`

- [ ] **T6 — Tag + push** (AC6)
  - [ ] `git tag v1.1.0`
  - [ ] `git push origin v1.1.0`

- [ ] **T7 — GitHub release** (AC7, AC8)
  - [ ] Write release notes (inline or `RELEASE_NOTES.md`)
  - [ ] `gh release create v1.1.0 ExímIABar-1.1.0.zip --title "v1.1.0 — Onda 4" --notes "..."`
  - [ ] Confirm release visible at `https://github.com/eximIA-Ventures/eximiabar/releases`

- [ ] **T8 — Migrate local installation** (AC9)
  - [ ] `pkill -x ClaudeBar` (if running)
  - [ ] `rm -rf ~/Applications/ExímIABar.app` (if exists)
  - [ ] `sudo make install` → installs to `/Applications/`
  - [ ] `open /Applications/ExímIABar.app`
  - [ ] Verify: `pgrep ClaudeBar` returns PID; `mdfind -name ExímIABar.app` returns `/Applications/ExímIABar.app`

- [ ] **T9 — Update README.md** (AC10)
  - [ ] Update installation section: primary = `make install` → `/Applications/`; secondary = `make install-user` → `~/Applications/`
  - [ ] Add Releases section with GitHub releases link
  - [ ] Add note on auto-updater (Settings → About → Check for Updates)

- [ ] **T10 — Smoke test auto-updater API** (AC11)
  - [ ] Manually trigger `curl https://api.github.com/repos/eximIA-Ventures/eximiabar/releases/latest | jq .tag_name`
  - [ ] Confirm returns `"v1.1.0"`
  - [ ] (Optional) Open app → Settings → About → Check for Updates → confirm "up to date" since installed version == latest

---

## Dev Notes

### /Applications vs ~/Applications
`/Applications` is the canonical macOS location for apps. Installing there makes the app visible to all users and to Spotlight system-wide. It requires write access (admin or sudo on default macOS). `~/Applications` is a user-only fallback. The EXB-1.8 `make install` used `~/Applications` to avoid requiring sudo — this story changes the primary target to `/Applications` and adds `install-user` as the sudo-free opt-in.

### ditto zip command — why not zip/Zip
`ditto -c -k --sequesterRsrc --keepParent` is the Apple-recommended tool for archiving `.app` bundles. It preserves:
- Codesignature extended attributes
- Symlinks in frameworks
- Resource forks (`--sequesterRsrc`)
- The `.app` directory as the root entry (`--keepParent`), which the EXB-2.4 installer expects when doing `ditto -x -k`.

Plain `zip -r` can corrupt the codesignature. Do NOT use `zip`.

### git push to new repo
If the local repo has no remote `origin`:
```bash
gh repo create eximIA-Ventures/eximiabar --public --source=. --remote=origin --push
```
This creates the repo, sets `origin`, and pushes `main` in one command.

If `origin` already set:
```bash
git push -u origin main
git push origin v1.1.0
```

### sudo for /Applications
```bash
sudo cp -R dist/ExímIABar.app /Applications/
# Or:
sudo make install
```
The Makefile `install` target should not hardcode `sudo` in the rule (it may be run as root already). Print a message if the copy fails due to permissions:
```makefile
install: build
	@cp -R dist/ExímIABar.app /Applications/ 2>/dev/null || \
	  (echo "⚠ Permission denied. Try: sudo make install" && exit 1)
```

### Release notes template
```markdown
## v1.1.0 — Onda 4

### What's new
- **Glassmorphism**: popover and Settings window now show native macOS blur material
- **Language selector**: Settings → General → Language (System / English / Português (Brasil))
- **Local Dashboard**: Swift Charts graphs for cost and token usage (last 30 days)
- **Auto-updater**: Settings → About → Check for Updates — downloads and installs from GitHub Releases
- **Install location**: moved to /Applications for system-wide visibility

### Requirements
- macOS 14+ (Sonoma)
- Claude Code installed (for OAuth credentials)
- Swift 6.2 (to build from source)
```

### Makefile target summary after this story
```
make build        — universal build → dist/ExímIABar.app
make install      — copy to /Applications/ (may need sudo)
make install-user — copy to ~/Applications/ (no sudo)
make uninstall    — remove /Applications/ExímIABar.app (may need sudo)
make clean        — remove dist/ and .build/
make test         — swift test
make icon         — regenerate AppIcon.icns
```

---

## Definition of Done

- [ ] `Info.plist` version = `1.1.0`
- [ ] Makefile `install` target points to `/Applications/`, `install-user` to `~/Applications/`
- [ ] `make build` clean, zero warnings
- [ ] `ExímIABar-1.1.0.zip` produced with correct ditto flags (`--keepParent`)
- [ ] `swift test` all green before push
- [ ] GitHub repo `eximIA-Ventures/eximiabar` exists and is public
- [ ] `git tag v1.1.0` and `git push origin v1.1.0` done
- [ ] GitHub release `v1.1.0` exists with `.zip` asset attached
- [ ] Old `~/Applications/ExímIABar.app` removed; app running from `/Applications/ExímIABar.app`
- [ ] `pgrep ClaudeBar` returns PID after migration
- [ ] `README.md` updated with new install path and Releases link
- [ ] Smoke test: `curl` to releases/latest returns `"v1.1.0"`

---

## Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-06-11 | 1.0 | Initial draft — Onda 4 (v1.1.0) | @sm River |
| 2026-06-11 | 1.1 | Executed: repo created, v1.1.0 released, /Applications migration. Status → Done | @devops Gage |

---

## Dev Agent Record (@devops Gage)

### Completion Notes
- **Makefile** (AC1): `install` → `/Applications` with permission-denied fallback message; added `install-user` → `~/Applications`; `uninstall` → `/Applications` with sudo hint.
- **Info.plist** (AC2): `CFBundleShortVersionString` + `CFBundleVersion` → `1.1.0`. About pane (`PreferencesAboutPane.swift`) and `UpdateViewModel.swift` read these from the bundle — bump suffices.
- **Build + zip** (AC3, AC4): `make build` clean (universal x86_64+arm64, ad-hoc signed, valid signature). Zip via `ditto -c -k --sequesterRsrc --keepParent` → `ExímIABar.app/` at root; codesignature survives round-trip extract.
- **Tests** (AC12): `swift test --no-parallel` → 175/175 green. NOTE: parallel runs flake on `policyProviderIsReadOnEveryLoadReachingKeychain` (race with `CredentialLoadOrderTests` over the real system keychain — passes 3/3 in isolation). Serial run is the deterministic gate.
- **Repo + push** (AC5): `eximIA-Ventures/eximiabar` created public; `origin` set; `main` pushed.
- **Tag + release** (AC6, AC7, AC8): `v1.1.0` tagged and pushed; release `exímIABar 1.1.0` created with the zip asset and full Onda-4 changelog + CodexBar attribution.
- **Migration** (AC9): old `~/Applications` copy removed; fixed build installed to `/Applications`; app launches and stays alive (`pgrep -x ClaudeBar` returns PID, running from `/Applications/ExímIABar.app/...`).
- **README** (AC10): `/Applications` as primary install path, Releases section, auto-updater note.
- **Auto-updater smoke** (AC11): `api.github.com/.../releases/latest` returns `"v1.1.0"`. Updater's asset picker is name-agnostic (first `.zip`, uses `browser_download_url`), so it is robust to GitHub's ASCII-normalization of the asset name.

### Critical Bug Found & Fixed (packaging — EXB-1.8 regression exposed by EXB-2.2)
- **Symptom:** the packaged `.app` fatal-crashed on launch: `Fatal error: unable to find bundle named ClaudeBar_ClaudeBar`.
- **Root cause:** `Scripts/package_app.sh` copied individual resources but never copied the SwiftPM resource bundle `ClaudeBar_ClaudeBar.bundle` (holding the `en`/`pt-BR` localizations from EXB-2.2). `Bundle.module` requires it at runtime via `Bundle.main.resourceURL`.
- **Fix:** added Step 5b to `package_app.sh` — copy `${BIN_PATH}/ClaudeBar_ClaudeBar.bundle` into `Contents/Resources/` before codesigning (so it is signed and survives the zip). Verified: app now launches without crash; localizations resolve.
- **Impact:** the first published zip was broken. Rebuilt, re-zipped, and replaced the release asset with the fixed build.

### Known Environment Limitations (not story defects)
- `mdfind` returns empty: the Spotlight index on `/` is **read-only** (`mdutil -s /`), so `/Applications` entries are not indexed on this machine. App is nonetheless installed, Launch-Services-registered, and running. Fixing Spotlight is out of scope for EXB-2.5.
