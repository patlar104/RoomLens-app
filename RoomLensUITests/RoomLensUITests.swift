//
//  RoomLensUITests.swift
//  RoomLensUITests
//
//  Created by patrick larocque on 2026-09-02.
//

import XCTest

final class RoomLensUITests: XCTestCase {

    override func setUpWithError() throws {
        // Stop immediately on failure so a broken launch does not cascade.
        continueAfterFailure = false
    }

    /// The app must resolve the capture state on launch and render a real
    /// screen rather than hanging on the spinner.
    ///
    /// The simulator has no capture device, so the correct outcome here is the
    /// "camera unavailable" screen. This is the end-to-end proof that
    /// ContentView -> CameraModel -> CaptureService is actually wired up: if
    /// the `.task` never ran, or the model never published state back to the
    /// main actor, the app would sit on "Preparing camera…" forever.
    @MainActor
    func testResolvesCaptureStateOnLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        let unavailable = app.staticTexts["Camera unavailable"]
        let ready = app.staticTexts["Camera ready"]

        // Whichever appears, the point is that the spinner resolves.
        let resolved = NSPredicate(format: "exists == true")
        expectation(for: resolved, evaluatedWith: unavailable, handler: nil)
        waitForExpectations(timeout: 10)

        XCTAssertTrue(
            unavailable.exists || ready.exists,
            "Capture state never resolved; the app is still preparing.")

        // On a device with no camera the user must not be told to open
        // Settings, since no setting would fix it.
        XCTAssertFalse(
            app.buttons["Open Settings"].exists,
            "Offered a Settings link for a simulator with no capture device.")
    }

    @MainActor
    func testRoomScanShowsUnsupportedMessageOnSimulator() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Room Scan"].tap()

        let unavailable = app.staticTexts["Room Scan unavailable"]
        let resolved = NSPredicate(format: "exists == true")
        expectation(for: resolved, evaluatedWith: unavailable, handler: nil)
        waitForExpectations(timeout: 10)

        XCTAssertTrue(unavailable.exists)
        XCTAssertFalse(
            app.buttons["Open Settings"].exists,
            "Offered a Settings link for simulator AR hardware that does not exist.")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
