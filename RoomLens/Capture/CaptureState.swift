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

    /// Whether sending the user to Settings could plausibly resolve this.
    var isResolvableInSettings: Bool {
        self == .denied
    }
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
    /// The session cannot run.
    case unavailable(CaptureUnavailableReason)

    /// Whether the preview should be showing camera output.
    var isRunning: Bool {
        self == .running
    }
}
