//
//  CameraModel.swift
//  RoomLens
//
//  The main-actor view model that fronts the capture layer.
//

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
        state = await service.prepare()
    }

    /// Stops the session, e.g. when the capture view goes away.
    func stop() async {
        await service.stop()
        state = .idle
    }
}
