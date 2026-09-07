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
            )
        )

        let state = await service.prepare()

        #expect(state == .unavailable(.denied))
        #expect(prompted.value == false)
    }

    @Test("Restricted access is distinct from denial")
    func restrictedIsDistinct() async throws {
        let service = CaptureService(
            authorization: StubAuthorization(status: .restricted))

        let state = await service.prepare()

        #expect(state == .unavailable(.restricted))
        // Sending a restricted user to Settings would be a dead end.
        #expect(!CaptureUnavailableReason.restricted.isResolvableInSettings)
    }

    @Test("Declining the prompt yields denied")
    func notDeterminedThenDeclined() async throws {
        let service = CaptureService(
            authorization: StubAuthorization(status: .notDetermined, grantsAccess: false))

        let state = await service.prepare()

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
            )
        )

        _ = await service.prepare()

        #expect(prompted.value == true)
    }

    @Test("Granted access proceeds past authorization to configuration")
    func grantedProceedsToConfiguration() async throws {
        let service = CaptureService(
            authorization: StubAuthorization(status: .authorized))

        let state = await service.prepare()

        // The simulator has no capture device, so a granted run must reach
        // configuration and fail there — never at authorization. This is what
        // proves an authorized user is not misreported as denied.
        #expect(state != .unavailable(.denied))
        #expect(state != .unavailable(.restricted))
        #expect(state == .unavailable(.noCaptureDevice) || state == .running)
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
