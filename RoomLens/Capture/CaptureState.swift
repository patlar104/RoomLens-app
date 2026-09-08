//
//  CaptureState.swift
//  RoomLens
//
//  The state a capture session can be in, as observed by the UI.
//

import Foundation

/// Why the capture session is unavailable.
///
/// Modelled explicitly so the UI can give an accurate recovery affordance
/// instead of a generic error: only `.denied` and `.restricted` are terminal
/// from the app's point of view, and only `.denied` is fixable in Settings.
/// `nonisolated` because the project defaults to main-actor isolation, and
/// this type (and its `Equatable` conformance) must be usable from the
/// `CaptureService` actor and from tests, neither of which is on the main
/// actor. Without this, Swift 6 rejects even an `==` comparison.
nonisolated enum CaptureUnavailableReason: Equatable, Sendable {
    /// The user actively denied camera access. Recoverable via Settings.
    case denied
    /// Access is blocked by policy (parental controls, MDM). Not recoverable.
    case restricted
    /// No usable capture device, e.g. running in the simulator.
    case noCaptureDevice
    /// Session configuration failed.
    case configurationFailed(String)
    /// The running session failed at runtime (media services reset, hardware error).
    case sessionFailed(String)

    /// Whether sending the user to Settings could plausibly resolve this.
    var isResolvableInSettings: Bool {
        self == .denied
    }
}

/// Why a running session was interrupted by the system.
///
/// Mirrors the subset of `AVCaptureSession.InterruptionReason` that matters to
/// the UI, as a `Sendable` value so it can cross the actor boundary.
nonisolated enum CaptureInterruptionReason: Equatable, Sendable {
    /// Another app took the camera, or the app is not the active foreground app.
    case cameraInUseByAnotherClient
    /// The app is running multitasked and video is not available.
    case videoDeviceNotAvailableInBackground
    /// The device is unavailable for any other system reason.
    case unknown
}

/// The lifecycle of the capture session.
///
/// A single enum rather than a set of independent booleans, so impossible
/// combinations (running *and* unauthorized) are unrepresentable.
nonisolated enum CaptureState: Equatable, Sendable {
    /// Nothing has been attempted yet.
    case idle
    /// Authorization or session configuration is in flight.
    case preparing
    /// The session is configured and running.
    case running
    /// The session was configured and started, but the system paused it.
    ///
    /// Distinct from `.unavailable`: this recovers on its own when the
    /// interruption ends, so the UI must not offer a Settings affordance.
    case interrupted(CaptureInterruptionReason)
    /// The session cannot run.
    case unavailable(CaptureUnavailableReason)

    /// Whether the preview should be showing camera output.
    var isRunning: Bool {
        self == .running
    }
}
