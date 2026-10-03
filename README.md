# Pipkin

## English
### Features

**Picture-in-Picture**
- Turn the frontmost window into a PiP with one hotkey (`⌃⌥P`), or pick a window from the menu bar list.
- Capture any screen region (`⌃⌥⇧P`); if the selection lands inside a window, a window stream is used instead, so it follows the window and keeps working when the window is covered.
- Multiple PiP windows at once, cascaded automatically; each source window or captured region remembers its own position, while width remains app-level.
- Drag a PiP near a screen edge or another PiP to snap it into place; adjacent PiPs join with no gap. Snapping never resizes the window; hold `Control` while dragging to bypass it temporarily.
- Floating, borderless, aspect-locked, visible on all Spaces and above full-screen apps — but below system pop-up menus, so menu bar utilities still open on top of it.

**Zoom & pan**
- `Cmd`-drag to zoom into a region, `Cmd`-scroll to change the factor (anchored at the pointer), `Cmd`-double-click to reset. Range 1×–20×.
- Scroll to pan when zoomed.
- Cropping happens on the capture side (`sourceRect`), so zooming keeps native pixels and stays sharp instead of interpolating a small image.

**Efficiency**
- Per-app frame rate: 1 / 5 / 10 / 15 / 30 / 60 fps; terminals and editors default to 5 fps.
- Idle detection drops to 1 fps when nothing changes and restores instantly when it does.
- Streaming pauses automatically when the PiP window is fully occluded or on an inactive Space.
- Frame rate, resolution and crop changes go through `SCStream.updateConfiguration` — no stream rebuild, no black frames.
- Chromium compatibility mode (off by default): some Chromium / Electron apps stop repainting once their window moves to another Space, so ScreenCaptureKit only sees the last frame. When enabled, Pipkin offers to relaunch the source app with Chromium's background-rendering switch. Relaunching quits the app, so it always asks first — only apps verified by this project can be relaunched automatically.

**Interaction**
- A dimmed overlay with an arrow points at the menu bar icon on first launch, so it is obvious the app is running in the background; replay it any time from *Show Getting Started*.
- Click a PiP window to switch straight to its source app (optional); with Accessibility granted it identifies the source by window ID and raises that exact window, restoring it if it was minimized. Titles refresh on demand when the top bar or a menu appears — no background polling.
- Auto-hide with click-through: the window fades out and pauses when the pointer moves over it — but the **top bar stays usable**: rest the pointer on the bar and the window returns to full opacity so you can click buttons, drag it by the bar, or open the right-click menu, while the video area stays click-through.
- While faded you can also hold `⌥` to peek at the whole window, or turn auto-hide off from the window's menu bar submenu. The faded opacity is configurable in 5% steps (default 35%).
- Hover overlay controls: pause, frame rate, reset zoom, auto-hide, idle detection, close. Icons highlight on hover and the description appears instantly above the icon.
- Source minimized → placeholder and automatic resume; source closed → notice, then auto-close; source app relaunched → reconnect by app + title.
- Update check via GitHub Releases: the menu shows your current version in grey next to *Check for Updates…*; downloads show a progress panel you can watch or cancel, the DMG is verified against the published SHA256, and on slow connections you can retry or switch to your browser with one click.

### Shortcuts

| Action | Default | Notes |
|---|---|---|
| PiP frontmost window | `⌃⌥P` | configurable |
| Capture region | `⌃⌥⇧P` | configurable |
| Close all | `⌃⌥\` | configurable |
| Grab a whole window | `⌥`-click | while selecting a region |
| Cancel selection | `⎋` or right-click | while selecting a region |
| Zoom | `Cmd`-drag / `Cmd`-scroll | pointer over PiP |
| Reset zoom | `Cmd`-double-click | pointer over PiP |
| Pan | scroll | when zoomed |
| Switch to the source window | click the PiP | can be disabled in Settings |
| Peek at a faded window | hold `⌥`, or rest the pointer on the top bar | while auto-hide has faded it |

Enhanced mode (optional, requires Accessibility) adds `fn`+`P` / `fn`+`⇧`+`P` hotkeys and hover keys: `=` / `-` zoom, `F` frame rate, `D` idle detection, tap `fn` to hide/show, `⌫` to close. It is off by default, only intercepts those keys, and everything else passes through untouched.

### Permissions

| Permission | Required | Purpose |
|---|---|---|
| Screen & System Audio Recording | **yes** | ScreenCaptureKit window capture |
| Accessibility | optional | exact source-window switching; Enhanced mode (fn hotkeys, hover keys) |

The system prompt appears on first launch and the app registers itself under *System Settings → Privacy & Security → Screen & System Audio Recording*, so you just flip the switch — no need to add it manually with the "+" button. macOS only applies the grant after a restart; the guide dialog has a "Relaunch app" button for that.

Release builds from v0.1.4 on are signed with a stable identity, so the grant **survives app updates**. If you are upgrading from v0.1.3 or earlier, macOS may ask once more because the old build left a stale record: click **Reset permission record** in the guide dialog, relaunch, and allow — later updates will keep it. Also drag the app into `/Applications` before running it; launching from the DMG or Downloads folder makes macOS randomise the path, which confuses the grant.

Frames stay in local memory and VRAM: no pixels are written to disk, uploaded, or reported. Only warnings and
renderer incident snapshots (window title, capture configuration and renderer state — never frame contents) are
written to `~/Library/Logs/Pipkin/Pipkin.log`; normal operation writes nothing at all. It rotates at
2 MB, keeps one previous file, and is never uploaded. The app makes no network requests other than update checks.

### Download

Grab the DMG from the [Releases page](https://github.com/ljzxzxl/pipkin/releases). One universal build covers both Apple Silicon and Intel Macs.

### Installing / first launch

Release builds are **signed with a self-signed certificate** (not notarized), so Gatekeeper blocks the first launch. Either:

```bash
xattr -cr /Applications/Pipkin.app
```

or right-click the app in Finder, choose "Open", then confirm.

Install it into `/Applications` and launch from there. A stable identity plus a stable path is what keeps the Screen Recording grant alive across updates; if the grant is nevertheless requested again, `bash scripts/reset-permission.sh` (or the in-app **Reset permission record** button) clears the stale TCC records.

### Frame rate guide

| Use case | Suggested |
|---|---|
| Terminals, logs, build output | 1–5 fps |
| AI agent progress, CI, dashboards | 5–15 fps |
| Chat, community feeds | 10–15 fps |
| Video, animation | 30–60 fps |

### Measured usage

Intel i5, macOS 26.5, 1920×1080@2x main display, capturing a 1920×993 window into a 640pt-wide PiP:

| Scenario | CPU | Resident memory |
|---|---|---|
| 1 stream · 1 fps | 0.1–0.4% (occasional 3% spike) | ~62 MB |
| 1 stream · 30 fps (low-motion content) | 1.5–2.0% | ~62 MB |
| 3 streams · 15 fps · 70 s | 1.8–2.6% | 62.1 → 62.3 MB (no upward trend) |

About 55 MB of that is the AppKit/ScreenCaptureKit baseline and is independent of the number of PiP windows.

### Build from source

Only the Xcode Command Line Tools are needed — full Xcode is not required.

```bash
bash scripts/build-app.sh              # build/Pipkin.app (x86_64 + arm64)
bash scripts/build-app.sh --fast       # current architecture only
bash scripts/build-app.sh --debug      # DEBUG logging + geometry self-checks
bash scripts/build-app.sh --install    # also install to /Applications
bash packaging/make-dmg.sh             # dist/Pipkin-<version>.dmg + SHA256
swift test                             # deterministic renderer recovery + window snapping tests (needs full Xcode)
```

Built-in self-tests (no UI, useful after any change):

```bash
./build/Pipkin.app/Contents/MacOS/pipkin --selftest         # permissions + capture path
./build/Pipkin.app/Contents/MacOS/pipkin --smoke 10         # one PiP session end to end
./build/Pipkin.app/Contents/MacOS/pipkin --smoke-autohide   # auto-hide fade / restore
./build/Pipkin.app/Contents/MacOS/pipkin --smoke-bar        # top-bar hot zone
./build/Pipkin.app/Contents/MacOS/pipkin --smoke-onboarding # first-launch overlay
./build/Pipkin.app/Contents/MacOS/pipkin --smoke-activate   # exact source window + on-demand title
./build/Pipkin.app/Contents/MacOS/pipkin --smoke-mc         # Mission Control geometry regression
./build/Pipkin.app/Contents/MacOS/pipkin --smoke-renderer   # renderer stall detection + recovery escalation
./build/Pipkin.app/Contents/MacOS/pipkin --smoke-level      # window level stays below system pop-up menus
./build/Pipkin.app/Contents/MacOS/pipkin --smoke-update     # real download + SHA256 check
```

Pull requests and pushes to `main` run the warning-free build and unit tests on macOS 14 (GitHub runners ship a
full Xcode). Pushing a `v*` tag (matching `VERSION`) builds the universal binary with `scripts/build-app.sh`,
verifies the signature and publishes a GitHub Release — the release path deliberately does not depend on XCTest.

### Repository layout

| Path | Purpose |
|---|---|
| `Sources/pipkin/` | All Swift sources: capture layer (`CaptureEngine`, `ShareableContentStore`, `FrameGate`, `IdleDetector`), presentation layer (`PiPWindowController`, `PiPContentView`, overlay views), session layer (`PiPSession`, `SessionStore`), input layer (hotkeys, event tap, hover monitor, region selection) and foundation (`Models`, `Geo`, `Preferences`, `Permissions`, `Updater`) |
| `Tests/PipkinTests/` | Deterministic unit tests for renderer recovery and window snapping |
| `Resources/` | `Info.plist` and the 1024×1024 icon source |
| `scripts/build-app.sh` | Builds both architectures with `swiftc`, assembles the `.app`, generates `AppIcon.icns`, signs with the fixed identity |
| `scripts/reset-permission.sh` | Resets this app's Screen Recording / Accessibility TCC records |
| `scripts/ci-import-cert.sh` | CI only: imports the signing certificate from Secrets into a temporary keychain |
| `packaging/make-dmg.sh` | Produces the DMG and its SHA256 |
| `docs/` | App icon and the [ONBOARDING](docs/ONBOARDING.md) handover doc (architecture, conventions, pitfalls) |
| `.github/workflows/ci.yml` | Builds with warnings as errors and runs unit tests on pull requests and `main` |
| `.github/workflows/release.yml` | Verifies tag vs `VERSION`, builds, publishes the Release |

### Notes

- Requires macOS 14+ so that `SCStream.updateConfiguration` can retune frame rate, resolution and crop smoothly; there is no 12.3–13 compatibility path.
- `fn` combinations and hover keys need an event tap, so they live in the optional Accessibility-gated enhanced mode. Everything else works with Screen Recording alone.
- While a source window is minimized the system produces no frames, so a placeholder is shown until it comes back — a macOS limitation, not a bug. Clicking the PiP un-minimizes the source window when Accessibility is granted.
- While Mission Control is open macOS scales every window down, so the PiP picture may briefly shrink; it returns to the full window as soon as you leave the overview.
- "Reset zoom" in the top bar refers to the **content zoom factor**, not the window size; it stays disabled until you zoom in with `Cmd`-drag or `Cmd`-scroll.
- Launch at login uses `SMAppService`, which can fail for ad-hoc signed apps; the app then points you to System Settings.
- Not implemented yet: audio follow, image filters such as contrast enhancement, and command-line control of a running instance. Hooks for all three are already in place.

### License

[MIT](LICENSE). Inspired by [Pipiri](https://lowtechguys.com/pipiri/); this is an independent implementation and contains none of its code.
