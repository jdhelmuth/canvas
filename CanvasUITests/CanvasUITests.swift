import XCTest

final class CanvasUITests: XCTestCase {
    func testOnboardingFirstScreen() {
        let app = XCUIApplication(); app.launchArguments = ["--canvas-ui-reset"]; app.launch()
        XCTAssertTrue(app.staticTexts["Canvas"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 3))
    }

    func testHomeAndSettingsSurface() {
        let app = XCUIApplication(); app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-home"]; app.launch()
        XCTAssertTrue(app.staticTexts["Canvas"].waitForExistence(timeout: 5))
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Albums & Filters"].exists)
    }

    func testEmptyHomeStateIsCenteredAndActionable() {
        let app = XCUIApplication(); app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-home"]; app.launch()
        let emptyState = app.otherElements["empty-albums-state"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["choose-albums-empty-state"].exists)

        let window = app.windows.firstMatch
        XCTAssertEqual(emptyState.frame.midX, window.frame.midX, accuracy: 8)
        XCTAssertGreaterThan(emptyState.frame.midY, window.frame.height * 0.35)
        XCTAssertLessThan(emptyState.frame.midY, window.frame.height * 0.72)
    }

    func testOnboardingSelectedAlbumContinuesAndCompletes() {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-onboarding-album"]
        app.launch()

        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Family favorites"].waitForExistence(timeout: 3))

        app.buttons["Continue"].tap()
        XCTAssertFalse(app.navigationBars["Choose albums"].exists)
        XCTAssertTrue(app.buttons["Start Canvas"].waitForExistence(timeout: 3))

        app.buttons["Start Canvas"].tap()
        XCTAssertTrue(app.staticTexts["Your quiet gallery"].waitForExistence(timeout: 3))
    }

    func testPhotoDurationLabelUpdatesWhileDragging() {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-home"]
        app.launch()
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 3))
        app.staticTexts["Playback & Timing"].tap()

        let slider = app.sliders["Photo duration-slider"]
        let label = app.buttons["Photo duration-value"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        XCTAssertTrue(label.waitForExistence(timeout: 3))
        XCTAssertEqual(label.label, "10 sec")
        slider.adjust(toNormalizedSliderPosition: 0.25)
        XCTAssertNotEqual(label.label, "10 sec")
    }

    func testInlineTransitionSliderValueUpdatesWhileDragging() {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-home"]
        app.launch()
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 3))
        app.staticTexts["Transitions & Layout"].tap()

        let slider = app.sliders["Transition duration-slider"]
        let value = app.staticTexts["Transition duration-value"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        XCTAssertTrue(value.waitForExistence(timeout: 3))
        let initial = value.label
        slider.adjust(toNormalizedSliderPosition: 0.75)
        XCTAssertNotEqual(value.label, initial)
    }

    func testHomeUsesPersistedMinuteDuration() {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-minute-duration"]
        app.launch()
        let duration = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 min photos")).firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
    }

    func testGooglePhotosConnectionEntryIsConfigured() {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-home"]
        app.launch()
        XCTAssertTrue(app.buttons["Manage albums"].waitForExistence(timeout: 5))
        app.buttons["Manage albums"].tap()
        XCTAssertTrue(app.navigationBars["Choose albums"].waitForExistence(timeout: 3))
        app.buttons["Add or refresh a Google album"].tap()
        XCTAssertTrue(app.navigationBars["Google Photos"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Open Google Photos"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "no Google OAuth client")).firstMatch.exists)
    }
}
