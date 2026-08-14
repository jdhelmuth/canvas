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

    func testAutomaticNightDimmingControlsSurface() {
        let app = XCUIApplication(); app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-home"]; app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 3))
        app.staticTexts["Schedule & Power"].tap()

        let nightDimmingToggle = app.switches["automatic-night-dimming-toggle"]
        for _ in 0..<5 where !nightDimmingToggle.exists { app.swipeUp() }
        XCTAssertTrue(nightDimmingToggle.waitForExistence(timeout: 3))
        XCTAssertEqual(nightDimmingToggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["Dim from"].exists)
        XCTAssertTrue(app.staticTexts["Return to normal"].exists)
    }

    func testClockOverlayStrokeControlsSurface() {
        let app = XCUIApplication(); app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-home"]; app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 3))
        app.staticTexts["Clock & Overlays"].tap()

        let strokeGroup = app.staticTexts["Stroke"]
        for _ in 0..<5 where !strokeGroup.exists { app.swipeUp() }
        XCTAssertTrue(strokeGroup.waitForExistence(timeout: 3))
        strokeGroup.tap()

        let clockStrokeToggle = app.switches["clock-stroke-toggle"]
        let strokeToggle = app.switches["text-stroke-toggle"]
        for _ in 0..<5 where !clockStrokeToggle.exists || !strokeToggle.exists { app.swipeUp() }
        XCTAssertTrue(clockStrokeToggle.waitForExistence(timeout: 3))
        XCTAssertTrue(strokeToggle.waitForExistence(timeout: 3))
        let strokeControl = strokeToggle.descendants(matching: .switch).firstMatch
        XCTAssertTrue(strokeControl.exists)
        strokeControl.tap()
        let strokeSlider = app.sliders["Stroke thickness-slider"]
        for _ in 0..<5 where !strokeSlider.exists { app.swipeUp() }
        XCTAssertTrue(strokeSlider.waitForExistence(timeout: 3))
    }

    func testWeatherSettingsExposeRealCompactDataChoices() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-weather-preview"]
        app.launch()
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 3))
        app.staticTexts["Clock & Overlays"].tap()

        for _ in 0..<6 where !app.staticTexts["Weather & Visibility"].exists { app.swipeUp() }
        let weatherGroup = app.staticTexts["Weather & Visibility"]
        XCTAssertTrue(weatherGroup.waitForExistence(timeout: 3))
        weatherGroup.tap()

        let conditions = app.switches["weather-condition-toggle"]
        let airQuality = app.switches["weather-air-quality-toggle"]
        // Expanding the group can preserve the list near its lower rows. Return
        // to the start of the weather choices before checking the defaults.
        for _ in 0..<5 where !conditions.exists || !airQuality.exists { app.swipeDown() }
        XCTAssertTrue(conditions.waitForExistence(timeout: 3))
        XCTAssertTrue(airQuality.waitForExistence(timeout: 3))
        XCTAssertEqual(conditions.value as? String, "1")
        XCTAssertEqual(airQuality.value as? String, "1")
        let feelsLike = app.switches["Feels like"]
        let humidity = app.switches["Humidity"]
        let wind = app.switches["Wind"]
        app.swipeUp()
        let weatherSize = app.sliders["Weather size-slider"]
        XCTAssertTrue(weatherSize.waitForExistence(timeout: 3))
        XCTAssertTrue(feelsLike.waitForExistence(timeout: 3))
        XCTAssertTrue(humidity.waitForExistence(timeout: 3))
        XCTAssertTrue(wind.waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Weather settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWeatherWidgetIsPositionedToTheRightOfClock() {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-weather-frame"]
        app.launch()

        let clock = app.otherElements["canvas.clock.overlay"]
        let weather = app.otherElements["canvas.weather.overlay"]
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        XCTAssertTrue(weather.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(weather.frame.minX, clock.frame.midX)
        XCTAssertLessThanOrEqual(weather.frame.maxX, app.windows.firstMatch.frame.maxX)
        XCTAssertFalse(app.staticTexts["Last known"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Clock and weather overlay"
        attachment.lifetime = .keepAlways
        add(attachment)
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
        let emptyAlbumToggle = app.switches["Show albums with 0 photos"]
        XCTAssertTrue(emptyAlbumToggle.waitForExistence(timeout: 3))
        let emptyAlbumControl = emptyAlbumToggle.descendants(matching: .switch).firstMatch
        XCTAssertTrue(emptyAlbumControl.exists)
        XCTAssertEqual(emptyAlbumToggle.value as? String, "0")
        emptyAlbumControl.tap()
        let enabledExpectation = expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: emptyAlbumToggle)
        wait(for: [enabledExpectation], timeout: 2)
        XCTAssertEqual(emptyAlbumToggle.value as? String, "1")
        emptyAlbumControl.tap()
        let disabledExpectation = expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: emptyAlbumToggle)
        wait(for: [disabledExpectation], timeout: 2)
        XCTAssertEqual(emptyAlbumToggle.value as? String, "0")
        app.buttons["Add or refresh a Google album"].tap()
        XCTAssertTrue(app.navigationBars["Google Photos"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Open Google Photos"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "no Google OAuth client")).firstMatch.exists)
    }

    func testPhysicalWeatherOverlayUsesLiveWeatherKit() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CANVAS_PHYSICAL_WEATHER_TEST"] == "1",
            "Runs only on a connected physical iPad with location and network access."
        )

        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-home"]
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 3))
        app.staticTexts["Clock & Overlays"].tap()

        let weatherToggle = app.switches["Current weather (opt-in)"]
        for _ in 0..<4 where !weatherToggle.exists {
            app.swipeUp()
        }
        XCTAssertTrue(weatherToggle.waitForExistence(timeout: 5))
        let wasEnabled = (weatherToggle.value as? String) == "1"
        if !wasEnabled {
            weatherToggle.tap()
            let allowWhileUsing = app.buttons["Allow While Using App"]
            if allowWhileUsing.waitForExistence(timeout: 5) { allowWhileUsing.tap() }
            let allowOnce = app.buttons["Allow Once"]
            if allowOnce.waitForExistence(timeout: 1) { allowOnce.tap() }
        }

        let status = app.staticTexts["canvas.weather.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 25))
        XCTAssertEqual(status.label, "Weather status: Weather live")

        if !wasEnabled { weatherToggle.tap() }
    }
}
