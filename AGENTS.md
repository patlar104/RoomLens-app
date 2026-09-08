# RoomLens

> This is the single source of truth for agent instructions in this repo.
> Claude Code reads it via `CLAUDE.md`, Codex and Cursor read `AGENTS.md`
> directly. Edit this file, not the copies.

## What this app is

RoomLens is a **professional camera app for capturing rooms and interiors** on
iPhone and iPad. It gives the user precise manual control over **exposure,
focus, zoom, and white balance**, and is designed to work seamlessly with
Apple's **Camera Control** hardware button and the **AVFoundation** capture
stack for smooth, high-quality capture.

Keep this domain in mind: the hard parts of this codebase are capture-session
lifecycle, device configuration locking, real-time control UI, and hardware
button integration — not generic app plumbing.

## Stack

- SwiftUI lifecycle (`RoomLensApp`), single app target `RoomLens`.
- **iOS 26.0** minimum deployment target (`IPHONEOS_DEPLOYMENT_TARGET = 26.0`),
  **Swift 6 language mode** (strict concurrency, `SWIFT_VERSION = 6.0`) with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Rationale: iOS 26 is the current
  shipping major; the Camera Control button API only needs iOS 18, so nothing
  here requires a newer floor, and 26.0 keeps a modern SwiftUI/concurrency
  baseline while still running on the locally installed simulator runtime.
  Lower to 18.0 only if broad device reach becomes a goal (would then need
  `@available` guards for iOS 26-only APIs).
- Unit tests: **Swift Testing** (`import Testing`, `@Test`, `#expect`,
  `#require`) in `RoomLensTests`.
- UI tests: **XCTest** in `RoomLensUITests`.
- No third-party dependencies. Do not add any without asking first.

## Build & test

Scheme is `RoomLens`. Canonical simulator is **iPhone 17 Pro** (has the Camera
Control button; runs on the installed iOS 26.5 runtime). Verify a concrete
device with `xcrun simctl list devices available` and fall back to any booted
iPhone on iOS 26.x. Building uses the latest installed SDK (currently iOS 27.0)
against the 26.0 deployment target — that is expected.

```
# Build
set -o pipefail && xcodebuild build -project RoomLens.xcodeproj -scheme RoomLens \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | xcbeautify

# Test (unit + UI) — verified working, ~2.5 min cold
set -o pipefail && xcodebuild test -project RoomLens.xcodeproj -scheme RoomLens \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | xcbeautify
```

`xcbeautify` (Homebrew, `/opt/homebrew/bin/xcbeautify`) formats the output.
Always prefix with `set -o pipefail` so a build/test failure is not masked by
the pipe. If you need the unfiltered log, drop the `| xcbeautify`.

To actually run the app in the simulator, use `Scripts/sim.sh` — it picks and
boots a usable iPhone simulator, builds, installs, and launches RoomLens.
`Scripts/sim.sh --shot` also saves a screenshot to `build/last-shot.png`;
`Scripts/sim.sh --device NAME` targets a specific simulator. This is the
canonical "see it run" path.

## Conventions

- SwiftUI only for UI. Prefer the `@Observable` macro over `ObservableObject`.
- Prefer `async`/`await` and structured concurrency over completion handlers
  and free-standing `Task {}`. Any `Task` started by a view must be cancelled
  when the view disappears.
- All AVFoundation capture-session setup and `AVCaptureDevice`
  `lockForConfiguration()` work runs off the main actor on a dedicated session
  queue; only publish resulting state back to `@MainActor`.
- New unit tests use Swift Testing, matching `RoomLensTests`.
- Any camera / photo-library / location access needs its `Info.plist` usage
  string **and** graceful handling of a denied authorization status.
- Formatting: `xcrun swift-format` (runs automatically via a post-edit hook).
  Match existing style.

## Capture architecture

The capture layer lives in `RoomLens/Capture/` and is deliberately layered so
session work stays off the main actor:

- `CaptureService` is an **`actor`** — it *is* the dedicated session queue. It
  owns the `AVCaptureSession` and never vends it to callers, so UI code cannot
  mutate the session off-queue. All `lockForConfiguration()` work belongs here.
- `CameraModel` is `@Observable @MainActor` and is the **only** type views
  talk to. It awaits the actor and publishes `CaptureState` back on the main
  actor.
- `CameraAuthorizing` is the test seam. The simulator has no camera and unit
  tests must never trigger a TCC prompt, so every authorization decision is
  injected. `RoomLensTests` drives the denied / restricted / not-determined
  paths through a stub.
- `CaptureState` / `CaptureUnavailableReason` are `nonisolated Sendable` value
  types. Because the project defaults to main-actor isolation, types crossing
  the actor boundary must be marked `nonisolated` explicitly — including their
  `Equatable` conformances, or Swift 6 rejects even an `==` comparison.

Only `.denied` is resolvable in Settings; `.restricted` and `.noCaptureDevice`
must not offer that affordance.

## Do not touch without explicit approval

- `RoomLens.xcodeproj/project.pbxproj`
- Signing settings, `DEVELOPMENT_TEAM`, bundle identifier
- Deployment target / Swift language version

## Shared working directory

Several agents may share this one checkout. Never restore a tracked file from
an ad-hoc `/tmp` backup — use `git checkout -- <file>` or `git restore`, which
are authoritative and concurrency-safe. Avoid `git reset --hard`,
`git clean -f`, and `git push --force` for the same reason. A hook enforces
this (see below) and will block the unsafe forms.

## Subagents

- `build-test` — builds and runs the suites, fixes failures minimally. Auto-run
  after Swift changes.
- `swiftui-reviewer` — read-only review of Swift/SwiftUI diffs, including
  capture-session and concurrency correctness.

Defined once per host: `.claude/agents/` (Claude Code markdown), `.cursor/agents/`
(Cursor markdown), and `.codex/agents/` (Codex custom-agent TOML). Keep the
instructions aligned across those copies.

Codex agent files are **not** `config.toml`. Required top-level keys are
`name`, `description`, and `developer_instructions` (optional:
`nickname_candidates`, plus any session `config.toml` key such as `model` or
`sandbox_mode`). Point each file at `.codex/agent.schema.json` with
`#:schema ../agent.schema.json`. Do **not** associate them with
`https://developers.openai.com/codex/config-schema.json` or the Taplo config
schema — Even Better TOML then rejects those three keys as additional
properties. `.taplo.toml` and `.vscode/settings.json` already bind
`.codex/agents/*.toml` to the agent schema; `config.toml` uses the official
Codex config schema.

## Automated hooks

The hook scripts live in `Scripts/hooks/` and are shared by every host, wired
up in `.claude/settings.json`, `.cursor/hooks.json`, and `.codex/config.toml`.
They are host-neutral: `Scripts/hooks/_common.sh` normalizes the differing
payload shapes, so add new hooks there rather than assuming one host's JSON.

**Never add `.codex/hooks.json`.** Codex loads that file *and* `.codex/config.toml`
and warns that this layer should have a single representation. Hooks for Codex
belong only in `config.toml`.

| Script | When | Effect |
| --- | --- | --- |
| `format-swift.sh` | after a file edit | `swift-format --in-place` on the edited Swift file |
| `guard-shared-checkout.sh` | before a shell command | blocks `/tmp`-backup restores and destructive git |
| `lint-gate.sh` | before `git commit` | blocks the commit if staged Swift fails `swift-format lint` |
| `build-gate.sh` | end of turn | rebuilds if Swift changed; makes the agent fix a broken build |

Cursor needs "Include third-party Plugins, Skills, and other configs" **off**
for this repo, or it will load `.claude/settings.json` in addition to
`.cursor/hooks.json` and run every hook twice.

## Editor settings vs personal overrides

`.vscode/` is gitignored except the shared files that make Codex TOML
validate in Cursor/VS Code: `.vscode/settings.json` (Even Better TOML schema
associations) and `.vscode/extensions.json` (recommends `tamasfe.even-better-toml`).
Do not dump personal Remote-SSH prefs into the committed settings file.

`.cursor/settings.local.json` is **not** loaded as editor/workspace settings.
It is a Claude-style hooks override name, not a Cursor overlay on
`.vscode/settings.json`. Putting `remote.*` or TOML schema keys there has no
effect.

Personal editor overlay that *does* load:

- **Open folder:** User settings
  (`~/Library/Application Support/Cursor/User/settings.json`) apply
  `remote.downloadExtensionsLocally` and `remote.localPortHost`.
- **Project-local file:** gitignored `RoomLens.local.code-workspace`. Open it
  with File → Open Workspace from File. Workspace `"settings"` override
  folder settings. Opening the folder alone ignores this file.
