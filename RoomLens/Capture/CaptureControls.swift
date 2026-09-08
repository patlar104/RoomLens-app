//
//  CaptureControls.swift
//  RoomLens
//
//  Value types and pure math for manual camera controls.
//

import Foundation

/// A normalized point in camera coordinates.
///
/// Values are always intended to be in `[0, 1]`, where `(0.5, 0.5)` is the
/// centre of the frame. The type is value-based and `Sendable` so SwiftUI can
/// hand a requested focus point to the capture actor without carrying UIKit or
/// AVFoundation objects across the boundary.
nonisolated struct NormalizedFocusPoint: Equatable, Sendable {
    static let center = NormalizedFocusPoint(x: 0.5, y: 0.5)

    let x: Double
    let y: Double

    func clamped() -> NormalizedFocusPoint {
        NormalizedFocusPoint(
            x: CaptureControlMath.clampedFinite(x, lower: 0, upper: 1),
            y: CaptureControlMath.clampedFinite(y, lower: 0, upper: 1))
    }
}

/// A manual white-balance request.
///
/// `temperature` is measured in Kelvin. `tint` matches AVFoundation's green to
/// magenta axis. The clamp range is deliberately conservative for a room camera:
/// warm tungsten through cool daylight, with enough tint range to correct indoor
/// lighting casts without making the UI extreme.
nonisolated struct WhiteBalanceSetting: Equatable, Sendable {
    static let neutral = WhiteBalanceSetting(temperature: 5_000, tint: 0)

    let temperature: Double
    let tint: Double

    func clamped() -> WhiteBalanceSetting {
        WhiteBalanceSetting(
            temperature: CaptureControlMath.clampedFinite(
                temperature, lower: 2_500, upper: 7_500),
            tint: CaptureControlMath.clampedFinite(tint, lower: -50, upper: 50))
    }
}

/// Failures from applying a manual camera control.
nonisolated enum CaptureControlFailure: Error, Equatable, Sendable, LocalizedError {
    /// The capture session has not configured a device yet.
    case notConfigured
    /// The device does not support this control.
    case unsupported(String)
    /// `AVCaptureDevice.lockForConfiguration()` failed.
    case configurationLockFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "The camera is not configured yet."
        case .unsupported(let control):
            "This device does not support \(control)."
        case .configurationLockFailed(let detail):
            "Could not configure the camera. \(detail)"
        }
    }
}

/// Pure camera-control math that can be tested without camera hardware.
nonisolated enum CaptureControlMath {
    /// Clamps a finite value into a closed range.
    ///
    /// If the requested value is NaN or infinite, returns the lower bound. If
    /// the upper bound is accidentally lower than the lower bound, also returns
    /// the lower bound. That fail-closed behaviour prevents invalid user input
    /// from reaching AVFoundation.
    static func clampedFinite(_ requested: Double, lower: Double, upper: Double) -> Double {
        guard requested.isFinite else { return lower }
        guard upper >= lower else { return lower }
        return min(max(requested, lower), upper)
    }
}
