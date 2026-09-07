//
//  RoomLensTests.swift
//  RoomLensTests
//
//  Created by patrick larocque on 2026-09-02.
//

import AVFoundation
import Testing

@testable import RoomLens

/// Test double for camera authorization.
///
/// This is the seam that makes the capture layer testable at all: the
/// simulator has no camera and unit tests must never trigger a TCC prompt,
/// so every authorization decision is driven through here.
///
/// `nonisolated` to match the protocol: the capture actor consumes it off the
/// main actor.
private nonisolated struct StubAuthorization: CameraAuthorizing {
    let status: AVAuthorizationStatus
    let grantsAccess: Bool
    /// Records whether the (prompting) request path was taken.
    let didRequest: @Sendable () -> Void

    init(
        status: AVAuthorizationStatus,
        grantsAccess: Bool = false,
        didRequest: @escaping @Sendable () -> Void = {}
    ) {
        self.status = status
        self.grantsAccess = grantsAccess
        self.didRequest = didRequest
    }

    func requestAccess() async -> Bool {
        didRequest()
        return grantsAccess
    }
}

@Suite("Capture authorization")
struct CaptureAuthorizationTests {

    @Test("A denied user is reported as denied, and is never re-prompted")
    func deniedIsNotPrompted() async throws {
        // If this fires, the app is nagging a user who already said no.
        let prompted = Prompted()
        let service = CaptureService(
            authorization: StubAuthorization(
                status: .denied,
                didRequest: { prompted.mark() }
            ),
            hasCaptureDevice: { true }
        )

        let state = await service.prepare(session: AVCaptureSession())

        #expect(state == .unavailable(.denied))
        #expect(prompted.value == false)
    }

    @Test("Restricted access is distinct from denial")
    func restrictedIsDistinct() async throws {
        let service = CaptureService(
            authorization: StubAuthorization(status: .restricted),
            hasCaptureDevice: { true })

        let state = await service.prepare(session: AVCaptureSession())

        #expect(state == .unavailable(.restricted))
        // Sending a restricted user to Settings would be a dead end.
        #expect(!CaptureUnavailableReason.restricted.isResolvableInSettings)
    }

    @Test("Declining the prompt yields denied")
    func notDeterminedThenDeclined() async throws {
        let service = CaptureService(
            authorization: StubAuthorization(status: .notDetermined, grantsAccess: false),
            hasCaptureDevice: { true })

        let state = await service.prepare(session: AVCaptureSession())

        #expect(state == .unavailable(.denied))
    }

    @Test("Only .notDetermined is allowed to prompt")
    func onlyNotDeterminedPrompts() async throws {
        let prompted = Prompted()
        let service = CaptureService(
            authorization: StubAuthorization(
                status: .notDetermined,
                grantsAccess: true,
                didRequest: { prompted.mark() }
            ),
            hasCaptureDevice: { true }
        )

        _ = await service.prepare(session: AVCaptureSession())

        #expect(prompted.value == true)
    }

    @Test("Granted access proceeds past authorization to configuration")
    func grantedProceedsToConfiguration() async throws {
        let service = CaptureService(
            authorization: StubAuthorization(status: .authorized),
            hasCaptureDevice: { true })

        let state = await service.prepare(session: AVCaptureSession())

        // An authorized user must never be misreported as denied or
        // restricted. On the simulator the real device lookup inside
        // configuration still fails, so the run ends at .noCaptureDevice or
        // .running depending on hardware — either proves authorization passed.
        #expect(state != .unavailable(.denied))
        #expect(state != .unavailable(.restricted))
    }

    @Test("No camera reports .noCaptureDevice and never prompts for access")
    func noCameraDoesNotPrompt() async throws {
        // Regression test for a bug found by running the app: on the
        // simulator the status is .notDetermined, requestAccess() returns
        // false, and that was mapped to .denied — offering an "Open Settings"
        // button to a user whose device has no camera at all.
        let prompted = Prompted()
        let service = CaptureService(
            authorization: StubAuthorization(
                status: .notDetermined,
                grantsAccess: false,
                didRequest: { prompted.mark() }
            ),
            hasCaptureDevice: { false }
        )

        let state = await service.prepare(session: AVCaptureSession())

        #expect(state == .unavailable(.noCaptureDevice))
        // Never prompt for a camera that does not exist.
        #expect(prompted.value == false)
        // And never offer a Settings link that cannot fix anything.
        #expect(!CaptureUnavailableReason.noCaptureDevice.isResolvableInSettings)
    }
}

@Suite("Capture lifecycle")
struct CaptureLifecycleTests {

    @Test("Resuming an unconfigured service reports that it cannot resume")
    func resumeWithoutConfiguration() async throws {
        // Nothing has been prepared, so there is no session to restart and
        // the caller must fall back to a full prepare().
        let service = CaptureService(
            authorization: StubAuthorization(status: .authorized),
            hasCaptureDevice: { true })

        let didResume = await service.resume()

        #expect(didResume == false)
    }

    @Test("Stopping then preparing again does not re-add the camera input")
    func stopThenPrepareIsClean() async throws {
        // Regression guard for the background/foreground cycle: stop() must
        // not leave the service in a state where the next prepare() tries to
        // add a second input to an already-configured session, which fails
        // with "cannot add camera input".
        let service = CaptureService(
            authorization: StubAuthorization(status: .authorized),
            hasCaptureDevice: { true })
        // Held the same way CameraModel holds it: one long-lived session
        // shared with the (main-actor) preview layer.
        nonisolated(unsafe) let session = AVCaptureSession()

        _ = await service.prepare(session: session)
        await service.stop()
        let state = await service.prepare(session: session)

        // On the simulator configuration ends at .noCaptureDevice; on real
        // hardware it reaches .running. Either is fine — what must never
        // happen is a configuration failure from duplicate inputs.
        if case .unavailable(.configurationFailed(let detail)) = state {
            Issue.record("second prepare() failed to configure: \(detail)")
        }
    }

    @Test("Stopping returns to idle")
    func stopReturnsToIdle() async throws {
        let service = CaptureService(
            authorization: StubAuthorization(status: .authorized),
            hasCaptureDevice: { true })

        _ = await service.prepare(session: AVCaptureSession())
        await service.stop()
        let state = await service.state

        #expect(state == .idle)
    }
}

@Suite("Capture state")
struct CaptureStateTests {

    @Test("Only denial is resolvable in Settings")
    func onlyDenialIsResolvable() {
        #expect(CaptureUnavailableReason.denied.isResolvableInSettings)
        #expect(!CaptureUnavailableReason.restricted.isResolvableInSettings)
        #expect(!CaptureUnavailableReason.noCaptureDevice.isResolvableInSettings)
        #expect(!CaptureUnavailableReason.configurationFailed("x").isResolvableInSettings)
    }

    @Test("isRunning reflects the running case only")
    func isRunning() {
        #expect(CaptureState.running.isRunning)
        #expect(!CaptureState.idle.isRunning)
        #expect(!CaptureState.preparing.isRunning)
        #expect(!CaptureState.unavailable(.denied).isRunning)
    }
}

/// Minimal thread-safe flag, so the stub's callback stays `Sendable` under
/// Swift 6 without pulling in a full mocking library.
private final class Prompted: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func mark() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
