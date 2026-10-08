# Pipkin - Vibe Coding Handoff

## Shared Vibe Coding workflow rules (2026-10-08)

### Documentation-only handoff exception
- When the user explicitly requests a documentation-only update, ChatGPT may edit the existing root `VIBECODING_HANDOFF.md` directly through GitHub without requiring a Mac build or a local checkout step.
- First inspect the actual repository, target branch, and existing handoff. Change only the handoff, preserve historical project context, and verify the resulting GitHub file and commit. Do not use this exception for application code, tests, scripts, configuration, workflows, version/build changes, release assets, or other build-affecting files.
- Before the next local development change, fetch the remote branch and reconcile the updated handoff with the local checkout. Never overwrite or silently reset unrelated local changes.
- The normal rule remains: validate the exact executable/build-affecting changes in the real Mac checkout before committing or pushing those changes. Include a current handoff with every meaningful validated development commit.

### Temporary worktrees, releases, and logs
- Create temporary Git worktrees under `/Users/alex/Desktop/tmp/<project>-...` using a project-specific name.
- Put release working folders, temporary release artifacts, staging directories, and build/release logs under `/Users/alex/Desktop/tmp/<project>-release-...`.
- Do not create disposable worktrees inside `/Users/alex/Documents/Vibe Coding`.
- Do not place release artifacts or logs directly on the Desktop root.
- After a successful verified release, remove temporary worktrees and temporary release artifacts when safe. Do not remove active worktrees, uncommitted work, published assets, or permanent project files.
- Retain failure logs only when useful for debugging; remove unnecessary temporary logs.
- These instructions govern future operations and take precedence over historical temporary-path examples elsewhere in this handoff.

### Low-overhead development defaults
- Use ChatGPT plus GitHub inspection and Mac-local Terminal scripts by default; do not use Codex, ChatGPT Work, separately billed API agents, or GitHub Actions runners unless explicitly requested.
- Prefer existing project scripts. Give one local command block to apply, build, test, and launch an executable change, then a separate commit/push block only after required validation is confirmed.
- Documentation-only updates under the exception above do not require a rebuild.

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
- Current version: `0.1.8`

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

Release `0.1.8` build `2` was built and validated locally before publication. Swift tests passed, the universal Intel and Apple Silicon app was packaged into verified DMG and ZIP artifacts, and the updater's pre-release 404 behavior was manually validated.

The initial Pipkin conversion passed local validation on the user's Mac before the first GitHub commit.

The production Pipkin icon was also locally validated and embedded through the existing `AppIcon.icns` build pipeline. The source master is `Resources/AppIcon.png` at 1024 x 1024.

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

The live update feed is GitHub's `releases/latest` endpoint. Release `v0.1.8` is the first published Pipkin release. A Pipkin `0.1.8` installation should report that it is up to date.

Known security-hardening item: the inherited updater can continue if a valid SHA256 asset is unavailable.

## Distribution

Current published release:

- Version: `0.1.8`
- Build: `2`
- Tag: `v0.1.8`
- Release source: GitHub Releases
- Assets: DMG, DMG SHA256, ZIP, and ZIP SHA256
- Local ZIP: `/Users/alex/Downloads/Pipkin-0.1.8.zip`
- Signing state: `code-signed`
- Apple notarization is not configured for this personal utility.
- Local Mac validation is authoritative.
- GitHub Actions are not used for release validation or publication.

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

Quick Region Capture remains the next development feature.

An uncommitted local implementation exists separately in the original Pipkin checkout and was intentionally excluded from release `0.1.8`. Continue its local validation before any GitHub write.

## Prompt for the next ChatGPT session

Read the full `VIBECODING_HANDOFF.md` first.

Treat it as historical context, but verify the current repository, branch, HEAD, version, workflow state, and relevant source files before making changes.

Never guess about implementation details that can be inspected.

Preserve existing working behavior.

Follow the local-validation-before-GitHub-write rule.

Keep Pipkin English-only and never introduce CJK characters.
