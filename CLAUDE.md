# RoomLens

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
  Swift 5.0. Rationale: iOS 26 is the current shipping major; the Camera Control
  button API only needs iOS 18, so nothing here requires a newer floor, and 26.0
  keeps a modern SwiftUI/concurrency baseline while still running on the locally
  installed simulator runtime. Lower to 18.0 only if broad device reach becomes
  a goal (would then need `@available` guards for iOS 26-only APIs).
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
canonical "see it run" path and what the `run` skill should use.

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
- Formatting: `xcrun swift-format` (runs automatically via a PostToolUse hook
  on save). Match existing style.

## Do not touch without explicit approval

- `RoomLens.xcodeproj/project.pbxproj`
- Signing settings, `DEVELOPMENT_TEAM`, bundle identifier
- Deployment target / Swift language version

## Subagents

- `build-test` — builds and runs the suites, fixes failures minimally. Auto-run
  after Swift changes.
- `swiftui-reviewer` — read-only review of Swift/SwiftUI diffs, including
  capture-session and concurrency correctness.
