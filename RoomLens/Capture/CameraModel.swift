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

    /// Current UI-facing manual control values.
    private(set) var zoomFactor = 1.0
    private(set) var exposureBias = 0.0
    private(set) var focusPoint = NormalizedFocusPoint.center
    private(set) var whiteBalance = WhiteBalanceSetting.neutral
    private(set) var controlError: String?

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
        guard !Task.isCancelled else { return }
        let nextState = await service.prepare(session: previewSession)
        guard !Task.isCancelled else { return }
        state = nextState
        await reapplyControls()
    }

    /// Mirrors the capture layer's authoritative state for as long as the
    /// caller's task lives.
    ///
    /// The session can stop without the app asking (interruption, runtime
    /// error), so state must be observed, not inferred from the last call that
    /// happened to return. Drive this from a long-lived `.task`.
    func observeState() async {
        for await next in await service.stateUpdates() {
            if Task.isCancelled { return }
            state = next
        }
    }

    /// Re-applies the photographer's settings to freshly configured hardware.
    ///
    /// Control intent lives here, not in the controls view: the view is
    /// destroyed whenever capture stops, and re-creating it must not silently
    /// reset the camera to 1x, 0 EV, and 5000 K.
    private func reapplyControls() async {
        guard state.isRunning else { return }
        await setZoomFactor(zoomFactor)
        await setExposureBias(exposureBias)
        await setWhiteBalance(whiteBalance)
    }

    /// Brings the camera back after the app returns to the foreground.
    ///
    /// Resumes the existing session when one is already configured, and falls
    /// back to a full `prepare()` otherwise. Reconfiguring an already-running
    /// session would fail, because its camera input is still attached.
    func resume() async {
        guard !Task.isCancelled else { return }
        if await service.resume() {
            guard !Task.isCancelled else { return }
            state = .running
            await reapplyControls()
        } else {
            await prepare()
        }
    }

    /// Stops the session, e.g. when the app leaves the foreground.
    func stop() async {
        await service.stop()
        state = .idle
    }

    func setZoomFactor(_ requested: Double) async {
        do {
            zoomFactor = try await service.setZoomFactor(requested)
            controlError = nil
        } catch {
            controlError = error.localizedDescription
        }
    }

    func setFocusPoint(_ requested: NormalizedFocusPoint) async {
        do {
            focusPoint = try await service.setFocusPoint(requested)
            controlError = nil
        } catch {
            controlError = error.localizedDescription
        }
    }

    func setExposureBias(_ requested: Double) async {
        do {
            exposureBias = try await service.setExposureBias(requested)
            controlError = nil
        } catch {
            controlError = error.localizedDescription
        }
    }

    func setWhiteBalance(_ requested: WhiteBalanceSetting) async {
        do {
            whiteBalance = try await service.setWhiteBalance(requested)
            controlError = nil
        } catch {
            controlError = error.localizedDescription
        }
    }
}
