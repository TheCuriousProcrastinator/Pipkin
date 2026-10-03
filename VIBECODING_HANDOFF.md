# Pipkin - Vibe Coding Handoff

## Project

Pipkin is a native macOS picture-in-picture utility for mirroring an application window or selected screen region into an always-on-top floating window.

It began as a fork of the MIT-licensed `ljzxzxl/my-window-pip` project. The upstream MIT copyright and license must remain intact.

This is a personal utility, not a commercial or App Store product.

## Repository and local checkout

- GitHub: `TheCuriousProcrastinator/Pipkin`
- Local path: `/Users/alex/Documents/Vibe Coding/Pipkin`
- Default branch: `main`
- Upstream: `ljzxzxl/my-window-pip`
- macOS deployment target: 14+
- Current inherited version: `0.1.7`

## App identity

- App name: `Pipkin`
- Executable: `pipkin`
- Bundle ID: `com.thecuriousprocrastinator.Pipkin`
- Source directory: `Sources/pipkin`
- Tests: `Tests/PipkinTests`

Do not restore the upstream `MyWindowPip`, `my-window-pip`, or `com.ljzxzxl.mywindowpip` runtime identity.

## Language rule

Pipkin is English-only.

Never introduce Chinese, Japanese, Korean, or other CJK text into source code, comments, scripts, documentation, diagnostics, build output, or UI.

## Verified baseline

The initial Pipkin conversion passed local validation on the user's Mac before the first GitHub commit.

Verified:

- Swift tests pass.
- Pipkin builds locally.
- The freshly built Pipkin app launches.
- Basic picture-in-picture capture works.
- App identity is Pipkin.
- Menus, Settings, onboarding, permission UI, and build output are English.
- Update checking points to `TheCuriousProcrastinator/Pipkin`.
- GitHub Actions configuration is manual-only.
- No CJK characters remain in tracked text sources.

## Existing functionality

- Capture the frontmost macOS window.
- Choose a specific macOS window.
- Capture a selected screen region.
- Multiple simultaneous PiP windows.
- Always-on-top floating windows.
- Per-app frame-rate settings.
- Idle detection and automatic low-FPS mode.
- Zoom and pan.
- Window snapping.
- Auto-hide and click-through.
- Global hotkeys.
- Optional Enhanced mode using Accessibility permission.
- Exact source-window activation when Accessibility is granted.
- Chromium/Electron compatibility mode.
- Chrome background-repaint compatibility.
- Login item support.
- Screen Recording permission guidance.
- GitHub Releases update checker.
- Local rolling diagnostics.
- Unit tests and inherited smoke-test infrastructure.

## Permissions

Screen Recording is required for capture.

Accessibility is optional and is used for:

- exact source-window activation
- Enhanced mode
- event-tap based shortcuts

Do not expand permission requirements without a clear feature need.

## Build and validation

Fast local build:

    bash scripts/build-app.sh --fast

Tests:

    swift test

Local Mac validation is authoritative.

Development builds may use ad-hoc signing when the Pipkin signing identity is unavailable. Screen Recording permission may need to be granted again after such rebuilds.

## GitHub Actions policy

Automatic GitHub Actions are disabled.

The only workflow is manual using `workflow_dispatch`.

Do not add automatic triggers for:

- pushes
- pull requests
- tags
- releases

Normal development must not consume GitHub-hosted runner minutes.

## Updates

`Sources/pipkin/Updater.swift` points to:

`TheCuriousProcrastinator/Pipkin`

The inherited updater queries GitHub Releases and downloads a DMG plus an optional SHA256 asset.

Important: GitHub's `releases/latest` endpoint returns 404 until Pipkin has its first published GitHub Release. Creating the repository alone does not create a release.

Known security-hardening item: the inherited updater can continue if a valid SHA256 asset is unavailable.

## Distribution

No Pipkin release has been published yet.

Developer ID signing, notarization, and a final Pipkin release process have not been configured.

## Architecture

Pipkin is a native Swift/AppKit project using Apple frameworks including:

- AppKit
- ScreenCaptureKit
- AVFoundation
- CoreMedia
- CoreVideo
- CoreImage
- CoreGraphics
- Carbon

There are no third-party Swift package dependencies in the inherited codebase.

`SourceWindowActivator.swift` uses the private `_AXUIElementGetWindow` symbol when available and falls back when unavailable.

Chromium compatibility may relaunch compatible source apps with:

`--disable-backgrounding-occluded-windows`

## Potential future features

Feature gaps identified compared with Pipiri:

1. Quick Region Capture using `fn` plus double-click around the cursor.
2. Contrast enhancement.
3. Sharpness enhancement.
4. CLI control of an already-running Pipkin instance.

The likely next feature is Quick Region Capture.

## Development rules

Before changing code:

1. Fetch the repository.
2. Verify branch and expected HEAD.
3. Inspect `git status --short`.
4. Stop if unrelated local changes exist.
5. Inspect the current implementation.
6. Make the smallest reliable change.
7. Build and test locally.
8. Launch the freshly built app automatically.
9. Wait for explicit user validation for UI or interaction changes.
10. Only then commit and push the exact tested files.
11. Update this handoff with every meaningful development commit.

Do not use GitHub as the normal development validation loop.

## Next task

No code change is currently pending.

Candidate next development task: implement Pipiri-style Quick Region Capture using `fn` plus double-click around the cursor while preserving existing manual region capture.

Inspect the current region-selection, event-tap, hover, and hotkey implementations before designing it.

## Prompt for the next ChatGPT session

Read the full `VIBECODING_HANDOFF.md` first.

Treat it as historical context, but verify the current repository, branch, HEAD, version, workflow state, and relevant source files before making changes.

Never guess about implementation details that can be inspected.

Preserve existing working behavior.

Follow the local-validation-before-GitHub-write rule.

Keep Pipkin English-only and never introduce CJK characters.
