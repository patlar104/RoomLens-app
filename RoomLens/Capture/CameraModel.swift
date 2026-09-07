//
//  CameraModel.swift
//  RoomLens
//
//  The main-actor view model that fronts the capture layer.
//

import AVFoundation
import Observation

/// Bridges the off-main-actor `CaptureService` to SwiftUI.
///
/// `@Observable` per CLAUDE.md conventions. This is the *only* type the UI
/// talks to; views never see the CaptureService or AVFoundation directly,
/// which is what keeps session mutation off the main actor.
@Observable
@MainActor
final class CameraModel {
    /// Mirrors the capture session state for the UI to render.
    private(set) var state: CaptureState = .idle

    /// The session the preview renders.
    ///
    /// Created and owned here on the main actor, then handed to the capture
    /// actor to configure. `AVCaptureSession` is not `Sendable`, so it must
    /// not be returned *out* of the actor; passing it in once, at a known
    /// point, keeps a single owner and satisfies Swift 6.
    ///
    /// Only the actor mutates its configuration; the preview layer merely
    /// reads frames from it, which AVFoundation supports.
    nonisolated(unsafe) let previewSession = AVCaptureSession()

    private let service: CaptureService

    init(service: CaptureService = CaptureService()) {
        self.service = service
    }

    /// Prepares the capture session and publishes the result.
    ///
    /// Awaits the actor and assigns on the main actor, which is the
    /// "publish resulting state back to @MainActor" rule from CLAUDE.md.
    /// Callers should drive this from `.task`, which cancels on disappear;
    /// no free-standing `Task {}` is started here.
    func prepare() async {
        state = await service.prepare(session: previewSession)
    }

    /// Brings the camera back after the app returns to the foreground.
    ///
    /// Resumes the existing session when one is already configured, and falls
    /// back to a full `prepare()` otherwise. Reconfiguring an already-running
    /// session would fail, because its camera input is still attached.
    func resume() async {
        if await service.resume() {
            state = .running
        } else {
            await prepare()
        }
    }

    /// Stops the session, e.g. when the app leaves the foreground.
    func stop() async {
        await service.stop()
        state = .idle
    }
}
