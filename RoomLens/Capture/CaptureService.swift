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

    /// Reports whether this hardware has a usable capture device.
    ///
    /// Deliberately a `Bool` probe rather than a device factory:
    /// `AVCaptureDevice` has no public initializer, so a seam returning a
    /// device could never be given a non-nil value in a test. A probe lets
    /// tests simulate "camera present" and exercise the authorization matrix,
    /// which is the behaviour that actually needs covering.
    private let hasCaptureDevice: @Sendable () -> Bool

    /// Non-nil only once configuration has succeeded.
    private var session: AVCaptureSession?

    /// The configured camera device.
    ///
    /// This never crosses the actor boundary. All focus, zoom, exposure, and
    /// white-balance mutation goes through this actor and is wrapped in
    /// `lockForConfiguration()`.
    private var configuredDevice: AVCaptureDevice?

    private(set) var state: CaptureState = .idle

    /// Monotonically identifies the latest lifecycle intent.
    ///
    /// `prepare()` suspends while authorization is requested. Actors are
    /// reentrant across suspension points, so `stop()` or a newer `prepare()` can
    /// run before the original authorization request completes. This token lets
    /// the resumed operation prove it is still the latest request before it
    /// configures or starts AVFoundation.
    private var lifecycleGeneration = 0

    /// The caller's latest desired running state.
    ///
    /// Generation alone distinguishes old work from new work; this flag records
    /// whether the newest lifecycle request still wants capture to be running.
    private var wantsRunning = false

    /// Continuations for `stateUpdates()`.
    ///
    /// The session can change state without anybody asking (interruption,
    /// media-services reset), so state cannot be delivered by return value
    /// alone. Every observer gets the authoritative stream.
    private var stateObservers: [UUID: AsyncStream<CaptureState>.Continuation] = [:]

    /// Live `NotificationCenter` observation tasks for the configured session.
    private var sessionObservationTasks: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - authorization: injected so tests can drive denied, restricted, and
    ///     not-determined paths without touching TCC.
    ///   - hasCaptureDevice: injected so tests can simulate camera hardware
    ///     being present or absent.
    init(
        authorization: CameraAuthorizing = SystemCameraAuthorization(),
        hasCaptureDevice: @escaping @Sendable () -> Bool = {
            CaptureService.defaultDevice() != nil
        }
    ) {
        self.authorization = authorization
        self.hasCaptureDevice = hasCaptureDevice
    }

    deinit {
        for task in sessionObservationTasks {
            task.cancel()
        }
        for continuation in stateObservers.values {
            continuation.finish()
        }
    }

    /// The authoritative state stream.
    ///
    /// Yields the current state immediately, then every subsequent change,
    /// including ones the app never requested (interruption, runtime error,
    /// recovery). The UI must render this rather than assuming that a
    /// successful `prepare()` means the camera stays live.
    func stateUpdates() -> AsyncStream<CaptureState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CaptureState>.makeStream()
        stateObservers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        stateObservers.removeValue(forKey: id)
    }

    /// Single funnel for every state change, so no path can publish silently.
    private func publish(_ next: CaptureState) {
        state = next
        for continuation in stateObservers.values {
            continuation.yield(next)
        }
    }

    /// The back wide-angle camera RoomLens captures with.
    private static func defaultDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Resolves camera authorization and, if granted, configures the session.
    ///
    /// - Parameter session: the caller-owned session to configure and start.
    ///   Passed in rather than created here because `AVCaptureSession` is not
    ///   `Sendable` and the preview layer (on the main actor) must reference
    ///   the same object.
    ///
    ///   The caller holds it as `nonisolated(unsafe)`. The compiler cannot
    ///   prove that is safe, but AVFoundation documents `AVCaptureSession` as
    ///   safe to use from multiple threads, and the invariant here is stricter
    ///   still: only this actor mutates its configuration, while the main
    ///   actor only attaches it to a preview layer for reading. Do not add
    ///   configuration calls outside this type.
    ///
    /// Safe to call repeatedly: returns the existing state when already
    /// running, so a view's `.task` re-firing cannot start a second session.
    @discardableResult
    func prepare(session: AVCaptureSession) async -> CaptureState {
        guard !Task.isCancelled else { return state }

        let generation = beginStartRequest()

        if case .running = state { return state }

        publish(.preparing)

        // Hardware availability is resolved BEFORE authorization, on purpose.
        // Prompting for camera access on a device that has no camera (the
        // simulator) is pointless, and the refusal would be mapped onto
        // `.denied` — showing an "Open Settings" button that cannot possibly
        // fix anything. Reported as `.noCaptureDevice` instead.
        guard hasCaptureDevice() else {
            guard shouldContinueStart(generation) else {
                return abortObsoleteStart(generation)
            }
            publish(.unavailable(.noCaptureDevice))
            return state
        }

        guard await resolveAuthorization(for: generation) else {
            guard shouldContinueStart(generation) else {
                return abortObsoleteStart(generation)
            }
            return state
        }
        guard shouldContinueStart(generation) else {
            return abortObsoleteStart(generation)
        }

        return configureSession(session)
    }

    private func beginStartRequest() -> Int {
        lifecycleGeneration += 1
        wantsRunning = true
        return lifecycleGeneration
    }

    private func shouldContinueStart(_ generation: Int) -> Bool {
        wantsRunning && lifecycleGeneration == generation && !Task.isCancelled
    }

    private func abortObsoleteStart(_ generation: Int) -> CaptureState {
        if lifecycleGeneration == generation {
            wantsRunning = false
            lifecycleGeneration += 1
        }

        if case .preparing = state {
            publish(.idle)
        }

        return state
    }

    /// Maps authorization status onto capture state.
    /// Returns whether the caller may proceed to configure the session.
    private func resolveAuthorization(for generation: Int) async -> Bool {
        switch authorization.status {
        case .authorized:
            return shouldContinueStart(generation)

        case .notDetermined:
            // The only state permitted to prompt.
            guard await authorization.requestAccess() else {
                guard shouldContinueStart(generation) else {
                    _ = abortObsoleteStart(generation)
                    return false
                }
                publish(.unavailable(.denied))
                return false
            }
            return shouldContinueStart(generation)

        case .denied:
            guard shouldContinueStart(generation) else {
                _ = abortObsoleteStart(generation)
                return false
            }
            publish(.unavailable(.denied))
            return false

        case .restricted:
            guard shouldContinueStart(generation) else {
                _ = abortObsoleteStart(generation)
                return false
            }
            publish(.unavailable(.restricted))
            return false

        @unknown default:
            // Fail closed: an unrecognised status must never be treated as
            // permission to open the camera.
            guard shouldContinueStart(generation) else {
                _ = abortObsoleteStart(generation)
                return false
            }
            publish(.unavailable(.restricted))
            return false
        }
    }

    /// Removes any inputs this service previously attached.
    ///
    /// The session outlives a stop/start cycle (the main actor owns it for the
    /// preview layer), so its camera input is still attached on the next
    /// `prepare()`. Without clearing it, `canAddInput` refuses the second
    /// input and configuration fails with "cannot add camera input".
    ///
    /// Static and `nonisolated` so it can be unit-tested directly on a bare
    /// `AVCaptureSession`, with no camera hardware involved.
    nonisolated static func detachExistingInputs(from session: AVCaptureSession) {
        for input in session.inputs {
            session.removeInput(input)
        }
    }

    /// Builds the capture session.
    ///
    /// Skeleton: it establishes the video input and the correct
    /// begin/commitConfiguration bracketing. Manual exposure, focus, zoom, and
    /// white-balance control land here, inside `lockForConfiguration()`.
    private func configureSession(_ session: AVCaptureSession) -> CaptureState {
        // Re-resolved here rather than passed in, so the probe above stays a
        // cheap, fakeable availability check. A device that vanished between
        // the probe and here is a genuine `.noCaptureDevice`.
        guard let device = Self.defaultDevice() else {
            publish(.unavailable(.noCaptureDevice))
            return state
        }

        // Configuration is bracketed in its own scope so that
        // `commitConfiguration()` provably runs BEFORE `startRunning()`.
        // A `defer` at function scope would fire only at return, i.e. after
        // startRunning(), which means starting mid-configuration.
        let configured: CaptureState? = {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.sessionPreset = .photo

            // The session may already carry an input from a previous
            // prepare()/stop() cycle; canAddInput would refuse a second one.
            Self.detachExistingInputs(from: session)

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    return .unavailable(.configurationFailed("cannot add camera input"))
                }
                session.addInput(input)
            } catch {
                return .unavailable(.configurationFailed(error.localizedDescription))
            }
            return nil  // nil == configured successfully
        }()

        if let failure = configured {
            publish(failure)
            return state
        }

        self.session = session
        configuredDevice = device

        // Runtime errors and interruptions are asynchronous and unsolicited.
        // Observing them before startRunning() guarantees no event that fires
        // during startup is missed.
        observeSessionEvents(session)

        // Blocks until the session is live, which is exactly why it belongs on
        // this actor and never on the main actor. Without this call the session
        // is fully configured but produces no frames: the preview stays black
        // and `.running` would be a lie.
        session.startRunning()

        // Ask the session rather than assuming. `startRunning()` can fail (a
        // runtime error, or the camera already claimed by another client), and
        // publishing `.running` regardless is exactly how the UI ends up
        // showing a frozen black preview it believes is live.
        publish(
            session.isRunning
                ? .running
                : .unavailable(.sessionFailed("the camera did not start")))
        return state
    }

    /// Subscribes to the session's runtime-error and interruption notifications.
    ///
    /// AVFoundation posts these on an arbitrary thread; each task hops back
    /// onto this actor before touching state, so session state stays
    /// serialized with every other lifecycle operation.
    private func observeSessionEvents(_ session: AVCaptureSession) {
        cancelSessionObservation()

        let center = NotificationCenter.default
        let runtimeErrors = center.notifications(named: .AVCaptureSessionRuntimeError, object: session)
        let interruptions = center.notifications(named: .AVCaptureSessionWasInterrupted, object: session)
        let interruptionsEnded = center.notifications(
            named: .AVCaptureSessionInterruptionEnded, object: session)

        // `Notification` is not `Sendable`, so each payload is reduced to a
        // value type inside the notification's own task before it is handed
        // back to the actor.
        sessionObservationTasks = [
            Task { [weak self] in
                for await notification in runtimeErrors {
                    if Task.isCancelled { return }
                    let detail =
                        (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
                        .localizedDescription ?? "the camera stopped unexpectedly"
                    await self?.handleRuntimeError(detail)
                }
            },
            Task { [weak self] in
                for await notification in interruptions {
                    if Task.isCancelled { return }
                    let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                    let reason = Self.interruptionReason(raw)
                    await self?.handleInterruption(reason)
                }
            },
            Task { [weak self] in
                for await _ in interruptionsEnded {
                    if Task.isCancelled { return }
                    await self?.handleInterruptionEnded()
                }
            },
        ]
    }

    private func cancelSessionObservation() {
        for task in sessionObservationTasks {
            task.cancel()
        }
        sessionObservationTasks = []
    }

    private nonisolated static func interruptionReason(_ raw: Int?) -> CaptureInterruptionReason {
        guard let raw, let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return .unknown
        }

        switch reason {
        case .videoDeviceInUseByAnotherClient:
            return .cameraInUseByAnotherClient
        case .videoDeviceNotAvailableInBackground,
            .videoDeviceNotAvailableWithMultipleForegroundApps,
            .videoDeviceNotAvailableDueToSystemPressure:
            return .videoDeviceNotAvailableInBackground
        default:
            return .unknown
        }
    }

    /// A runtime error means the session is no longer producing frames.
    func handleRuntimeError(_ detail: String) {
        guard wantsRunning else { return }
        publish(.unavailable(.sessionFailed(detail)))
    }

    func handleInterruption(_ reason: CaptureInterruptionReason) {
        guard wantsRunning else { return }
        publish(.interrupted(reason))
    }

    /// The system released the camera again, so restart and report the truth.
    func handleInterruptionEnded() {
        guard wantsRunning, let session else { return }

        if !session.isRunning {
            session.startRunning()
        }

        publish(
            session.isRunning
                ? .running
                : .unavailable(.sessionFailed("the camera did not resume after an interruption")))
    }

    /// Stops the session but keeps its configuration.
    ///
    /// The session object is retained deliberately: it is owned by the main
    /// actor for the preview layer, and its inputs stay attached. Resuming is
    /// therefore `startRunning()` again rather than a full reconfigure, which
    /// would try to add a second input to an already-configured session and
    /// fail with "cannot add camera input".
    func stop() {
        lifecycleGeneration += 1
        wantsRunning = false
        cancelSessionObservation()
        session?.stopRunning()
        publish(.idle)
    }

    /// Applies a manual zoom factor and returns the clamped value actually used.
    @discardableResult
    func setZoomFactor(_ requested: Double) throws -> Double {
        try configureDevice { device in
            let maximum = min(
                Double(device.activeFormat.videoMaxZoomFactor),
                Double(device.maxAvailableVideoZoomFactor))
            let applied = CaptureControlMath.clampedFinite(
                requested, lower: Double(device.minAvailableVideoZoomFactor), upper: maximum)
            device.videoZoomFactor = applied
            return applied
        }
    }

    /// Applies a focus point in normalized camera coordinates.
    @discardableResult
    func setFocusPoint(_ requested: NormalizedFocusPoint) throws -> NormalizedFocusPoint {
        let applied = requested.clamped()
        return try configureDevice { device in
            guard device.isFocusPointOfInterestSupported else {
                throw CaptureControlFailure.unsupported("manual focus point")
            }

            device.focusPointOfInterest = CGPoint(x: applied.x, y: applied.y)

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            } else if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            } else {
                throw CaptureControlFailure.unsupported("manual focus mode")
            }

            return applied
        }
    }

    /// Applies exposure compensation and returns the clamped bias actually used.
    @discardableResult
    func setExposureBias(_ requested: Double) throws -> Double {
        try configureDevice { device in
            let applied = CaptureControlMath.clampedFinite(
                requested,
                lower: Double(device.minExposureTargetBias),
                upper: Double(device.maxExposureTargetBias))
            device.setExposureTargetBias(Float(applied), completionHandler: nil)
            return applied
        }
    }

    /// Applies a locked white balance and returns the clamped setting used.
    @discardableResult
    func setWhiteBalance(_ requested: WhiteBalanceSetting) throws -> WhiteBalanceSetting {
        let applied = requested.clamped()
        return try configureDevice { device in
            guard device.isWhiteBalanceModeSupported(.locked) else {
                throw CaptureControlFailure.unsupported("locked white balance")
            }

            let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: Float(applied.temperature),
                tint: Float(applied.tint))
            let rawGains = device.deviceWhiteBalanceGains(for: values)
            let gains = Self.normalizedWhiteBalanceGains(
                rawGains, maximum: device.maxWhiteBalanceGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            return applied
        }
    }

    /// Serializes and brackets every `AVCaptureDevice` configuration mutation.
    private func configureDevice<T>(_ body: (AVCaptureDevice) throws -> T) throws -> T {
        guard let configuredDevice else {
            throw CaptureControlFailure.notConfigured
        }

        do {
            try configuredDevice.lockForConfiguration()
            defer { configuredDevice.unlockForConfiguration() }
            return try body(configuredDevice)
        } catch let failure as CaptureControlFailure {
            throw failure
        } catch {
            throw CaptureControlFailure.configurationLockFailed(error.localizedDescription)
        }
    }

    /// AVFoundation rejects gains outside `[1, maxWhiteBalanceGain]`.
    private nonisolated static func normalizedWhiteBalanceGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        maximum: Float
    ) -> AVCaptureDevice.WhiteBalanceGains {
        func clamp(_ value: Float) -> Float {
            min(max(value, 1), maximum)
        }

        return AVCaptureDevice.WhiteBalanceGains(
            redGain: clamp(gains.redGain),
            greenGain: clamp(gains.greenGain),
            blueGain: clamp(gains.blueGain))
    }

    /// Resumes a previously configured session, e.g. on returning to the
    /// foreground. Returns false when there is nothing configured to resume,
    /// so the caller knows a full `prepare()` is required.
    @discardableResult
    func resume() -> Bool {
        guard !Task.isCancelled else { return false }

        lifecycleGeneration += 1
        wantsRunning = true

        guard let session else { return false }

        // Observation is torn down by stop(), so re-establish it before the
        // session goes live again.
        observeSessionEvents(session)

        if !session.isRunning {
            session.startRunning()
        }

        // Same rule as configureSession: report what the session actually did.
        // A resume can fail when another app holds the camera.
        publish(
            session.isRunning
                ? .running
                : .unavailable(.sessionFailed("the camera did not resume")))
        return true
    }
}
