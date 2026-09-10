# RoomLens

A professional camera app for capturing rooms and interiors on iPhone and
iPad. RoomLens gives precise manual control over **exposure, focus, zoom, and
white balance**, and is built to work seamlessly with Apple's **Camera
Control** hardware button and the **AVFoundation** capture stack for smooth,
high-quality capture.

A **Room Scan** mode (ARKit + SceneKit) reconstructs a room's geometry —
plane detection plus LiDAR scene mesh where supported — alongside the primary
camera mode.

## Requirements

- Xcode with the iOS 26 SDK (or newer) installed
- iOS 26.0+ simulator or device — **iPhone 17 Pro** is the canonical
  simulator, since it has the Camera Control button
- [`xcbeautify`](https://github.com/cpisciotta/xcbeautify) for readable build
  output (`brew install xcbeautify`)

## Build

```sh
set -o pipefail && xcodebuild build -project RoomLens.xcodeproj -scheme RoomLens \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | xcbeautify
```

## Test

Unit tests use **Swift Testing**; UI tests use **XCTest**.

```sh
set -o pipefail && xcodebuild test -project RoomLens.xcodeproj -scheme RoomLens \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' | xcbeautify
```

## Run in the simulator

```sh
Scripts/sim.sh            # picks/boots a simulator, builds, installs, launches
Scripts/sim.sh --shot     # also saves a screenshot to build/last-shot.png
Scripts/sim.sh --device "iPhone 17 Pro"   # target a specific simulator
```

## Project structure

```
RoomLens/
├── RoomLensApp.swift        # App entry point
├── ContentView.swift        # Root view: mode switch (Camera / Room Scan)
├── RoomScanView.swift       # ARKit/SceneKit room-geometry capture
└── Capture/                 # AVFoundation capture stack
    ├── CaptureService.swift     # actor owning the AVCaptureSession
    ├── CameraModel.swift        # @Observable @MainActor model views talk to
    ├── CaptureState.swift       # Sendable capture state/reason types
    ├── CameraAuthorization.swift
    ├── CameraPreview.swift
    ├── CameraControlsView.swift
    └── CaptureControls.swift

RoomLensTests/       # Swift Testing unit tests
RoomLensUITests/     # XCTest UI tests
Scripts/             # sim.sh + shared agent hooks (Scripts/hooks/)
```

## Architecture

The capture layer is deliberately layered so session work stays off the main
actor:

- **`CaptureService`** is an `actor` — it *is* the dedicated session queue. It
  owns the `AVCaptureSession` and never vends it to callers, so UI code
  cannot mutate the session off-queue. All `lockForConfiguration()` work
  happens here.
- **`CameraModel`** is `@Observable @MainActor` and is the *only* type views
  talk to. It awaits the actor and publishes `CaptureState` back on the main
  actor.
- **`CameraAuthorizing`** is the test seam for camera permission. The
  simulator has no camera, so unit tests drive the denied / restricted /
  not-determined paths through a stub rather than triggering a real TCC
  prompt.

`ContentView` mediates between the two camera-owning subsystems: switching
into Room Scan mode stops the AVFoundation session before the ARKit
viewport starts, since both stacks want exclusive access to the camera.

## Contributing / agent instructions

Full conventions (Swift 6 concurrency rules, build/test details, hook
behavior, and files that require explicit approval before editing) live in
[`AGENTS.md`](AGENTS.md) — the single source of truth shared by Claude Code,
Cursor, and Codex.
