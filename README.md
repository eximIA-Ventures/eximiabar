# exímIABar

A macOS menu bar app that monitors your Claude usage and rate limits at a glance.

exímIABar lives in your menu bar, renders your current Claude rate-limit window as a
compact icon, and opens a popover with live utilization, pace, and local cost data.
It reads the same OAuth credentials your `claude` CLI uses — and never writes to them.

![menu bar screenshot placeholder](docs/screenshot.png)

> _Screenshot placeholder — replace `docs/screenshot.png` with a real capture of the
> menu bar icon + popover._

## Features

- **Live rate-limit meter** in the menu bar — session, weekly and (when reported) Opus windows.
- **Pace indicator and local cost breakdown** in the popover.
- **Multiple Claude accounts.** Accounts are captured automatically as you log in and kept
  in a read-only roster; an inline switcher in the popover lets you inspect any of them.
  Archived accounts show no live reading, and switching focus never changes the menu bar
  meter — it stays anchored to the account currently logged in.
- **Codex provider.** When `~/.codex/auth.json` is present, a Codex pane shows your session
  and weekly usage alongside Claude. No Codex login, no pane — and no error either.
- **Read-only by design.** Credentials are read from the same stores the `claude` and
  `codex` CLIs use, and never written to.

## Requirements

- macOS 14+ (Sonoma)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and logged in (`claude`)
- Swift 6.2 / Xcode 16+ (to build from source)

## Installation

### Homebrew (recommended)

The cleanest path — a versioned install with one-command uninstall:

```bash
brew tap eximia-ventures/tap https://github.com/eximIA-Ventures/homebrew-tap
brew install --cask eximiabar
```

To upgrade later: `brew upgrade --cask eximiabar`. To remove: `brew uninstall --cask eximiabar`.

### Build from source (`make install`)

Prefer to build locally from the source tree? See **[Build from source](#build-from-source)** below
(`make build && sudo make install`).

> **A note on `npm`:** `npm` does not apply to native macOS apps — exímIABar is a signed
> `.app` bundle, not a JavaScript package. Distribution is via Homebrew (above) or a direct
> [release download](#releases). There is no `npm install eximiabar`.

## Build from source

```bash
make build && sudo make install
```

- `make build` produces a universal (arm64 + x86_64), ad-hoc-signed
  `dist/ExímIABar.app`.
- `make install` copies it to **`/Applications/`** (the canonical, system-wide
  location — Spotlight indexes it for all users). Writing to `/Applications`
  needs admin rights, so run it with `sudo`.
- Prefer a per-user install? `make install-user` copies to `~/Applications/`
  with no `sudo`.

Because the app is ad-hoc signed (no Apple Developer ID), the first launch needs
a right-click → **Open** to clear Gatekeeper.

### Other make targets

| Target | Action |
|--------|--------|
| `make build` | Build the signed `.app` into `dist/` |
| `make install` | Copy to `/Applications/` (may need `sudo`) |
| `make install-user` | Copy to `~/Applications/` (no `sudo`) |
| `make uninstall` | Remove from `/Applications/` (may need `sudo`) |
| `make clean` | Remove `dist/` and `.build/` |
| `make test` | Run `swift test` |
| `make icon` | Regenerate `AppIcon.icns` |

## Releases

Pre-built, signed releases are published on GitHub:

- **[github.com/eximIA-Ventures/eximiabar/releases](https://github.com/eximIA-Ventures/eximiabar/releases)**

Each release ships a `ExímIABar-<version>.zip` you can unzip and drop into
`/Applications`.

### Auto-updater

exímIABar checks GitHub Releases for newer versions. Open the app and go to
**Settings → About → Check for Updates** to fetch and install the latest
release in place. No package manager required.

## License

MIT — see [`LICENSE`](LICENSE).

exímIABar is a derivative work of [**CodexBar**](https://github.com/steipete/CodexBar)
by Peter Steinberger, used under the MIT License. It adapts CodexBar's Claude OAuth
pipeline and visual design into a Claude-only, freeze-free menu bar monitor.
