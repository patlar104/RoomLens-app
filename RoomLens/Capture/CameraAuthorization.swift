//
//  CameraAuthorization.swift
//  RoomLens
//
//  Authorization seam for camera access.
//
//  AVCaptureDevice.authorizationStatus / requestAccess cannot be driven from a
//  test: the simulator has no camera, and the TCC prompt is a system UI that
//  unit tests must never trigger. Everything that needs to *decide* something
//  based on authorization therefore talks to this protocol instead of touching
//  AVFoundation directly, so denial handling is testable without hardware.
//

import AVFoundation

/// The subset of camera authorization the app depends on.
///
/// `Sendable` because implementations are consumed from the capture actor,
/// off the main actor.
///
/// The members are explicitly `nonisolated`: the project builds with
/// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so without this the protocol
/// requirements would be main-actor isolated and `CaptureService` (an actor)
/// could not call them. Swift 6 language mode rejects that at compile time.
protocol CameraAuthorizing: Sendable {
    /// The current authorization status, without prompting.
    nonisolated var status: AVAuthorizationStatus { get }

    /// Requests access, prompting only when the status is `.notDetermined`.
    /// Returns whether access is granted.
    nonisolated func requestAccess() async -> Bool
}

/// The real implementation, backed by `AVCaptureDevice`.
///
/// `nonisolated` so it can be used from the capture actor. It holds no state,
/// and the underlying AVFoundation calls are themselves thread-safe.
nonisolated struct SystemCameraAuthorization: CameraAuthorizing {
    var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    func requestAccess() async -> Bool {
        // Only `.notDetermined` may prompt. Calling requestAccess in any other
        // state is a no-op that returns the existing decision, but branching
        // here keeps the "never prompt twice" rule explicit and testable.
        guard status == .notDetermined else {
            return status == .authorized
        }
        return await AVCaptureDevice.requestAccess(for: .video)
    }
}
