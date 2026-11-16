import XCTest

final class AlbumAdditionUITests: XCTestCase {
    private func wait(_ condition: @escaping () -> Bool, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout), .completed, file: file, line: line)
    }
    private func state(_ app: XCUIApplication) -> [String: String] {
        let label = app.staticTexts["fixture-player-state"].label
        return Dictionary(label.split(separator: ";").compactMap { item in
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { first, _ in first })
    }
    private func clean(_ app: XCUIApplication) {
        app.buttons["fixture-cleanup"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            // Query the system alert before querying the occluded app. Asking
            // XCTest for the app tree behind a second Photos alert can block.
            if springboard.alerts.buttons["Delete"].exists { springboard.alerts.buttons["Delete"].tap() }
            else if springboard.alerts.buttons["Allow"].exists { springboard.alerts.buttons["Allow"].tap() }
            else if app.staticTexts["fixture-status"].label == "Cleaned" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertEqual(app.staticTexts["fixture-status"].label, "Cleaned")
    }
    func testRealAlbumBatchAdditionPreservesRunningPlayerThroughGapForegroundAndRestart() {
        continueAfterFailure = false
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // A stopped prior fixture run may have left a system confirmation.
        if springboard.alerts.buttons["Don’t Allow"].exists { springboard.alerts.buttons["Don’t Allow"].tap() }
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-simulator-cleanup"]
        app.launch()
        XCTAssertTrue(app.buttons["fixture-cleanup"].waitForExistence(timeout: 10))
        clean(app)
        app.terminate()
        app.launchArguments = ["--canvas-simulator-album-additions"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture-player-state"].waitForExistence(timeout: 15))
        wait { self.state(app)["queue"] == "3" && self.state(app)["frame"] != "none" }
        let initial = state(app)
        app.buttons["fixture-add"].tap()
        wait { app.staticTexts["fixture-status"].label == "Gap active" }
        wait { self.state(app)["warning"] == "0" }
        XCTAssertGreaterThanOrEqual(Int(state(app)["queue"] ?? "0") ?? 0, 3)
        XCTAssertEqual(state(app)["frame"], initial["frame"])
        XCTAssertEqual(state(app)["seen"], initial["seen"])
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "Synthetic album additions during catalog gap"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCUIDevice.shared.press(.home)
        app.activate()
        wait { self.state(app)["frame"] == initial["frame"] }
        XCTAssertEqual(state(app)["warning"], "0")
        app.buttons["fixture-recover"].tap()
        wait { self.state(app)["queue"] == "7" }
        XCTAssertEqual(state(app)["frame"], initial["frame"])
        XCTAssertEqual(state(app)["seen"], initial["seen"])
        app.terminate()
        app.launch()
        wait { self.state(app)["queue"] == "7" && self.state(app)["frame"] != "none" }
        XCTAssertEqual(state(app)["warning"], "0")
        // Restart resumes the persisted cycle; it must not reset to one seen.
        XCTAssertGreaterThanOrEqual(Int(state(app)["seen"] ?? "0") ?? 0, Int(initial["seen"] ?? "0") ?? 0)
        clean(app)
        app.terminate()
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
    }
    func testCheckingThenSettledGapStaysSilentAndAutomaticallyReconnectsExactAlbum() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-simulator-cleanup"]
        app.launch()
        XCTAssertTrue(app.buttons["fixture-cleanup"].waitForExistence(timeout: 10)); clean(app)
        app.terminate()
        app.launchArguments = ["--canvas-simulator-album-additions", "--canvas-simulator-stuck-recovery"]
        app.launch()
        XCTAssertTrue(app.staticTexts["fixture-player-state"].waitForExistence(timeout: 15))
        wait { self.state(app)["queue"] == "3" && self.state(app)["frame"] != "none" }
        let original = state(app)
        let checking = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        checking.name = "Synthetic recovery checking phase"; checking.lifetime = .keepAlways; add(checking)
        app.buttons["fixture-add"].tap()
        wait { app.staticTexts["fixture-status"].label == "Gap active" }
        wait({ self.state(app)["checking"] == "0" }, timeout: 20)
        let settled = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        settled.name = "Synthetic recovery settled phase"; settled.lifetime = .keepAlways; add(settled)
        XCTAssertEqual(state(app)["frame"], original["frame"])
        XCTAssertEqual(state(app)["seen"], original["seen"])
        XCTAssertEqual(state(app)["settingsWarning"], "1")
        XCTAssertEqual(state(app)["warning"], "0", "Recoverable gaps must not overlay an existing slide")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Selected albums are not currently available")).firstMatch.exists)
        // This changes only the fake Photos read boundary. No reconnect,
        // retry button, foreground event, or service refresh is invoked.
        app.buttons["fixture-restore-reads"].tap()
        wait({ self.state(app)["queue"] == "7" && self.state(app)["resolved"] == "1" }, timeout: 45)
        XCTAssertEqual(state(app)["frame"], original["frame"])
        XCTAssertEqual(state(app)["seen"], original["seen"])
        XCTAssertEqual(state(app)["settingsWarning"], "0")
        XCUIDevice.shared.press(.home); app.activate()
        wait { self.state(app)["queue"] == "7" }
        XCTAssertEqual(state(app)["warning"], "0")
        app.terminate(); app.launch()
        wait { self.state(app)["queue"] == "7" && self.state(app)["frame"] != "none" }
        XCTAssertEqual(state(app)["warning"], "0")
        XCTAssertEqual(state(app)["settingsWarning"], "0")
        XCTAssertGreaterThanOrEqual(Int(state(app)["seen"] ?? "0") ?? 0, Int(original["seen"] ?? "0") ?? 0)
        clean(app); app.terminate()
    }

}
