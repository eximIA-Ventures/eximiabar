# exímIABar

A macOS menu bar app that monitors your Claude usage and rate limits at a glance.

exímIABar lives in your menu bar, renders your current Claude rate-limit window as a
compact icon, and opens a popover with live utilization, pace, and local cost data.
It reads the same OAuth credentials your `claude` CLI uses — and never writes to them.

![menu bar screenshot placeholder](docs/screenshot.png)

> _Screenshot placeholder — replace `docs/screenshot.png` with a real capture of the
> menu bar icon + popover._

## Requirements

- macOS 14+ (Sonoma)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and logged in (`claude`)
- Swift 6.2 / Xcode 16+ (to build from source)

## Build & install

```bash
make build && make install
```

- `make build` produces a universal (arm64 + x86_64), ad-hoc-signed
  `dist/ExímIABar.app`.
- `make install` copies it to `~/Applications/`.

Because the app is ad-hoc signed (no Apple Developer ID), the first launch needs
a right-click → **Open** to clear Gatekeeper.

### Other make targets

| Target | Action |
|--------|--------|
| `make build` | Build the signed `.app` into `dist/` |
| `make install` | Copy to `~/Applications/` |
| `make uninstall` | Remove from `~/Applications/` |
| `make clean` | Remove `dist/` and `.build/` |
| `make test` | Run `swift test` |
| `make icon` | Regenerate `AppIcon.icns` |

## License

MIT — see [`LICENSE`](LICENSE).

exímIABar is a derivative work of [**CodexBar**](https://github.com/steipete/CodexBar)
by Peter Steinberger, used under the MIT License. It adapts CodexBar's Claude OAuth
pipeline and visual design into a Claude-only, freeze-free menu bar monitor.
