//
//  CaptureService.swift
//  RoomLens
//
//  The capture-session boundary.
//
//  ARCHITECTURE
//  ------------
//  This is an `actor`, not a `@MainActor` type. CLAUDE.md requires that all
//  AVCaptureSession setup and every `lockForConfiguration()` call happen off
//  the main actor: those calls block, and doing them on the main thread is the
//  classic source of dropped frames and UI hangs in a camera app. The actor
//  *is* the "dedicated session queue" — it serialises session mutation without
//  a manual DispatchQueue.
//
//  The project sets SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so types here
//  would default to the main actor; declaring this as an `actor` opts out
//  deliberately. Under Swift 6 language mode, that boundary is now compiler
//  enforced rather than a convention.
//
//  Only `Sendable` value types cross the boundary back to the UI, which is why
//  `CaptureState` is a plain enum rather than a reference to session objects.
//

import AVFoundation

/// Owns the AVCaptureSession and all device configuration.
///
/// Deliberately does *not* vend the `AVCaptureSession` to callers: handing it
/// to the main actor would let UI code mutate it off the session queue, which
/// is the exact race this type exists to prevent. The preview layer will be
/// connected through a dedicated, explicitly-isolated accessor when the
/// preview is built.
actor CaptureService {
    private let authorization: CameraAuthorizing

    /// Non-nil only once configuration has succeeded.
    private var session: AVCaptureSession?

    private(set) var state: CaptureState = .idle

    /// - Parameter authorization: injected so tests can drive denied,
    ///   restricted, and not-determined paths without touching TCC.
    init(authorization: CameraAuthorizing = SystemCameraAuthorization()) {
        self.authorization = authorization
    }

    /// Resolves camera authorization and, if granted, configures the session.
    ///
    /// Safe to call repeatedly: returns the existing state when already
    /// running, so a view's `.task` re-firing cannot start a second session.
    @discardableResult
    func prepare() async -> CaptureState {
        if case .running = state { return state }

        state = .preparing

        guard await resolveAuthorization() else { return state }

        return configureSession()
    }

    /// Maps authorization status onto capture state.
    /// Returns whether the caller may proceed to configure the session.
    private func resolveAuthorization() async -> Bool {
        switch authorization.status {
        case .authorized:
            return true

        case .notDetermined:
            // The only state permitted to prompt.
            guard await authorization.requestAccess() else {
                state = .unavailable(.denied)
                return false
            }
            return true

        case .denied:
            state = .unavailable(.denied)
            return false

        case .restricted:
            state = .unavailable(.restricted)
            return false

        @unknown default:
            // Fail closed: an unrecognised status must never be treated as
            // permission to open the camera.
            state = .unavailable(.restricted)
            return false
        }
    }

    /// Builds the capture session.
    ///
    /// Skeleton: it establishes the video input and the correct
    /// begin/commitConfiguration bracketing. Manual exposure, focus, zoom, and
    /// white-balance control land here, inside `lockForConfiguration()`.
    private func configureSession() -> CaptureState {
        // No camera in the simulator. Reported distinctly from a denial so the
        // UI does not tell a simulator user to open Settings.
        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back)
        else {
            state = .unavailable(.noCaptureDevice)
            return state
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        // Always balanced, including on the failure paths below.
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                state = .unavailable(.configurationFailed("cannot add camera input"))
                return state
            }
            session.addInput(input)
        } catch {
            state = .unavailable(.configurationFailed(error.localizedDescription))
            return state
        }

        self.session = session
        state = .running
        return state
    }

    /// Stops the running session, if any.
    func stop() {
        session?.stopRunning()
        state = .idle
    }
}
