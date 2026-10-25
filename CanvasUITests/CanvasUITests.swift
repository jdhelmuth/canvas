import XCTest

final class CanvasUITests: XCTestCase {
    override func tearDownWithError() throws {
        // Finish app/process transitions while XCTest automation is still alive.
        // iOS 26.5 can crash SpringBoard when session invalidation races these
        // transitions; the host monitor independently detects any recurrence.
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        try super.tearDownWithError()
    }

    private func assertHomeReady(_ app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["settings"])
        let result = XCTWaiter.wait(for: [ready], timeout: 5)
        if result != .completed {
            print(app.debugDescription)
            let frame = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            frame.name = "Home dismissal failure"
            frame.lifetime = .keepAlways
            add(frame)
        }
        XCTAssertEqual(result, .completed)
    }

    func testPhysicalSlideshowCloseWithoutReset() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Physical-device exit check uses existing app data without reset.")
#else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-play"]
        app.launch()
        let slideshow = app.otherElements["Canvas slideshow"]
        XCTAssertTrue(slideshow.waitForExistence(timeout: 15))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let close = app.buttons["close-slideshow"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        // iOS 27.2 can retain a dismissed accessibility node. A hittable
        // Home control and the following Settings navigation prove dismissal.
        assertHomeReady(app)
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 5))
        app.staticTexts["Playback & Timing"].tap()
        let slider = app.sliders["Photo duration-slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        XCTAssertTrue(slider.isEnabled)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        assertHomeReady(app)
#endif
    }

    func testSlideshowCloseReturnsHomeAndAllowsSettingsEdits() {
        verifySlideshowExit(directLaunch: false)
    }

    func testDirectPlaybackLaunchCanExitWithoutRestarting() {
        verifySlideshowExit(directLaunch: true)
    }

    private func verifySlideshowExit(directLaunch: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-home"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-albums-empty-state"].waitForExistence(timeout: 5))
        app.buttons["choose-albums-empty-state"].tap()
        XCTAssertTrue(app.staticTexts["Landscapes"].waitForExistence(timeout: 5))
        app.staticTexts["Landscapes"].tap()
        app.buttons["Done"].tap()
        if directLaunch {
            app.terminate()
            app.launchArguments = ["--canvas-ui-play"]
            app.launch()
        } else {
            let start = app.descendants(matching: .any)["start-your-frame"].firstMatch
            XCTAssertTrue(start.waitForExistence(timeout: 5))
            start.tap()
        }
        let slideshow = app.otherElements["Canvas slideshow"]
        XCTAssertTrue(slideshow.waitForExistence(timeout: 10))
        let close = app.buttons["close-slideshow"]
        // Exercise the reported path: reveal hidden controls, then press X.
        if close.exists { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let playback = app.buttons["toggle-slideshow-playback"]
        XCTAssertTrue(playback.exists)
        let playbackLabel = playback.label
        playback.tap()
        XCTAssertNotEqual(playback.label, playbackLabel)
        XCTAssertTrue(close.exists, "Control buttons must not trigger the surface hide gesture")
        close.tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5), "X must return to the home screen")
        // iOS 27.2 can retain a dismissed accessibility node. A hittable
        // Home control and the following Settings navigation prove dismissal.
        assertHomeReady(app)
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 5))
        app.staticTexts["Playback & Timing"].tap()
        let slider = app.sliders["Photo duration-slider"]
        let value = app.buttons["Photo duration-value"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let before = value.label
        slider.adjust(toNormalizedSliderPosition: 0.25)
        XCTAssertNotEqual(value.label, before)
        let edited = value.label
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        // Foregrounding and home reappearance must not replay the launch request.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        assertHomeReady(app)
        app.buttons["settings"].tap()
        app.staticTexts["Playback & Timing"].tap()
        XCTAssertEqual(value.label, edited)
    }

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

        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        let nightDimmingToggle = app.switches["automatic-night-dimming-toggle"]
        for _ in 0..<5 where !nightDimmingToggle.exists { form.swipeUp() }
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

        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        let strokeGroup = app.staticTexts["Stroke"]
        for _ in 0..<5 where !strokeGroup.exists { form.swipeUp() }
        XCTAssertTrue(strokeGroup.waitForExistence(timeout: 3))
        strokeGroup.tap()

        let clockStrokeToggle = app.switches["clock-stroke-toggle"]
        let strokeToggle = app.switches["text-stroke-toggle"]
        for _ in 0..<5 where !clockStrokeToggle.exists || !strokeToggle.exists { form.swipeUp() }
        XCTAssertTrue(clockStrokeToggle.waitForExistence(timeout: 3))
        XCTAssertTrue(strokeToggle.waitForExistence(timeout: 3))
        let strokeControl = strokeToggle.descendants(matching: .switch).firstMatch
        XCTAssertTrue(strokeControl.exists)
        strokeControl.tap()
        let strokeSlider = app.sliders["Stroke thickness-slider"]
        for _ in 0..<5 where !strokeSlider.exists { form.swipeUp() }
        XCTAssertTrue(strokeSlider.waitForExistence(timeout: 3))
    }

    func testWeatherSettingsExposeRealCompactDataChoices() {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-weather-preview"]
        app.launch()
        let settings = app.buttons["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let settingsReady = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: settings)
        wait(for: [settingsReady], timeout: 5)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 3))
        app.staticTexts["Clock & Overlays"].tap()

        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        for _ in 0..<6 where !app.staticTexts["Weather & Visibility"].exists { form.swipeUp() }
        let weatherGroup = app.staticTexts["Weather & Visibility"]
        XCTAssertTrue(weatherGroup.waitForExistence(timeout: 3))
        weatherGroup.tap()

        let conditions = app.switches["weather-condition-toggle"]
        let airQuality = app.switches["weather-air-quality-toggle"]
        // Expansion may retain either the header or the last weather row.
        // Start from a known anchor, then use short drags so inertia cannot
        // skip the adjacent condition/AQI controls in a compact sheet.
        let visibility = form.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Visibility")).firstMatch
        for _ in 0..<12 where !visibility.exists { form.swipeDown() }
        XCTAssertTrue(visibility.exists)
        func advanceForm() {
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.1, thenDragTo: form.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ))
        }
        for _ in 0..<40 where !conditions.exists || !airQuality.exists { advanceForm() }
        XCTAssertTrue(conditions.waitForExistence(timeout: 3))
        XCTAssertTrue(airQuality.waitForExistence(timeout: 3))
        XCTAssertEqual(conditions.value as? String, "1")
        XCTAssertEqual(airQuality.value as? String, "1")
        let feelsLike = app.switches["Feels like"]
        let humidity = app.switches["Humidity"]
        let wind = app.switches["Wind"]
        let dewPointScale = app.switches["weather-scale-toggle"]
        let weatherSize = app.sliders["Weather size-slider"]
        // A compact sheet cannot expose every weather row simultaneously.
        // Verify each control in display order as it becomes visible.
        for control in [feelsLike, humidity, wind, dewPointScale, weatherSize] {
            for _ in 0..<20 where !control.exists { advanceForm() }
            XCTAssertTrue(control.waitForExistence(timeout: 3))
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Weather settings"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testWeatherWidgetIsPositionedToTheRightOfClock() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-weather-frame"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let landscape = NSPredicate { _, _ in window.frame.width > window.frame.height }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: window)], timeout: 5), .completed)

        let clock = app.otherElements["canvas.clock.overlay"]
        let weather = app.otherElements["canvas.weather.overlay"]
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        XCTAssertTrue(weather.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(weather.frame.minX, clock.frame.midX)
        XCTAssertLessThanOrEqual(weather.frame.maxX, window.frame.maxX)
        XCTAssertFalse(app.staticTexts["Last known"].exists)
        // SwiftUI exposes Link as a Link on iOS 27 and as a Button on iOS 26.
        let attribution = weather.descendants(matching: .any)["apple-weather-attribution-link"]
        XCTAssertTrue(attribution.waitForExistence(timeout: 3))
        XCTAssertEqual(attribution.label, "Apple Weather legal attribution and data sources")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Clock and weather overlay"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBatteryDateAndClockStayTogetherWithTallWeather() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--canvas-ui-reset", "--canvas-ui-weather-frame",
            "--canvas-ui-store-weather-station", "--canvas-ui-clock-group"
        ]
        app.launch()
        // Wait for the asynchronous full-screen presentation before rotating.
        XCTAssertTrue(app.otherElements["canvas.clock.overlay"].waitForExistence(timeout: 5))
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let window = app.windows.firstMatch
            let rotated = NSPredicate { _, _ in
                orientation == .portrait
                    ? window.frame.height > window.frame.width
                    : window.frame.width > window.frame.height
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: window)], timeout: 5), .completed)
            let clock = app.otherElements["canvas.clock.overlay"]
            let date = app.staticTexts["canvas.date.overlay"]
            let battery = app.descendants(matching: .any).matching(identifier: "canvas.battery.overlay").firstMatch
            let weather = app.otherElements["canvas.weather.overlay"]
            for element in [clock, date, battery, weather] {
                XCTAssertTrue(element.waitForExistence(timeout: 5))
            }
            // Check actual rendered adjacency, not only the ordering policy.
            XCTAssertEqual(date.frame.minY - battery.frame.maxY, 3, accuracy: 2)
            XCTAssertEqual(clock.frame.minY - date.frame.maxY, 3, accuracy: 2)
            XCTAssertGreaterThanOrEqual(clock.frame.minY, 0)
            XCTAssertLessThanOrEqual(weather.frame.maxY, window.frame.maxY)
            if orientation == .portrait {
                XCTAssertGreaterThan(weather.frame.minY, clock.frame.maxY)
            } else {
                XCTAssertGreaterThan(weather.frame.minX, clock.frame.maxX)
                XCTAssertGreaterThan(weather.frame.height, clock.frame.height + date.frame.height + battery.frame.height)
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Compact clock group - \(orientation == .portrait ? "portrait" : "landscape")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testConnectedStationShowsOnlyPWSConditionsEvenWithLegacyLocalForecast() {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-weather-frame", "--canvas-ui-store-weather-station"]
        app.launch()
        let weather = app.otherElements["canvas.weather.overlay"]
        XCTAssertTrue(weather.waitForExistence(timeout: 5))
        let conditions = weather.descendants(matching: .any).matching(identifier: "canvas.weather.conditions")
        XCTAssertEqual(conditions.count, 1)
        XCTAssertTrue(conditions.firstMatch.label.contains("59.4"))
        XCTAssertTrue(weather.staticTexts["Ambient station"].exists)
        XCTAssertFalse(weather.staticTexts["Near this iPad"].exists)
        XCTAssertFalse(weather.descendants(matching: .any)["apple-weather-attribution-link"].exists)
        XCTAssertTrue(weather.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Air quality index 32")).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "PWS is the only weather source"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDewPointScaleIsPositionedOnTheRightEdge() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--canvas-ui-reset",
            "--canvas-ui-weather-frame",
            "--canvas-ui-dew-point-scale"
        ]
        app.launch()

        let window = app.windows.firstMatch
        let scale = app.otherElements["canvas.weather.scale"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(scale.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(scale.frame.midX, window.frame.midX)
        XCTAssertLessThanOrEqual(scale.frame.maxX, window.frame.maxX)
        XCTAssertGreaterThan(scale.frame.height, window.frame.height * 0.25)
        XCTAssertLessThan(scale.frame.height, window.frame.height * 0.65)
    }

    func testFeelsLikeScaleStaysOnRightAndPersistsAcrossLaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-weather-frame", "--canvas-ui-feels-like-scale"]
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let window = app.windows.firstMatch
            let landscape = orientation == .landscapeLeft
            let rotated = NSPredicate { _, _ in landscape ? window.frame.width > window.frame.height : window.frame.height > window.frame.width }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: rotated, object: nil)], timeout: 5), .completed)
            let scale = app.otherElements["canvas.weather.scale"]
            XCTAssertTrue(scale.waitForExistence(timeout: 5))
            XCTAssertEqual(scale.label, "Feels like scale")
            XCTAssertTrue((scale.value as? String)?.contains("72") == true)
            XCTAssertGreaterThan(scale.frame.midX, window.frame.midX)
            XCTAssertLessThanOrEqual(scale.frame.maxX, window.frame.maxX)
            XCTAssertEqual(app.otherElements.matching(identifier: "canvas.weather.scale").count, 1)
            // Application screenshots can crop using stale portrait bounds
            // after rotation. Capture the full display for visual review.
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Feels like scale - \(landscape ? "landscape" : "portrait")"
            shot.lifetime = .keepAlways
            add(shot)
        }
        app.terminate()
        app.launchArguments = ["--canvas-ui-weather-frame"]
        app.launch()
        let scale = app.otherElements["canvas.weather.scale"]
        XCTAssertTrue(scale.waitForExistence(timeout: 5))
        XCTAssertEqual(scale.label, "Feels like scale")
    }

    func testWeatherScalePickerPersistsSelectedReading() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-weather-preview", "--canvas-ui-dew-point-scale"]
        app.launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        app.buttons["settings"].tap()
        XCTAssertTrue(app.navigationBars["Canvas settings"].waitForExistence(timeout: 5))
        app.staticTexts["Clock & Overlays"].tap()
        let form = app.collectionViews.firstMatch
        for _ in 0..<8 where !app.staticTexts["Weather & Visibility"].exists { form.swipeUp() }
        app.staticTexts["Weather & Visibility"].tap()
        let picker = app.buttons["weather-scale-metric"]
        for _ in 0..<35 where !picker.exists || !picker.isHittable {
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).press(forDuration: 0.1,
                thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        XCTAssertTrue(picker.isHittable)
        for title in ["Temperature", "Dew point", "Feels like"] {
            picker.tap()
            app.buttons[title].tap()
            XCTAssertEqual(picker.value as? String, title)
        }
        app.terminate()
        app.launchArguments = ["--canvas-ui-weather-frame"]
        app.launch()
        let scale = app.otherElements["canvas.weather.scale"]
        XCTAssertTrue(scale.waitForExistence(timeout: 5))
        XCTAssertEqual(scale.label, "Feels like scale")
    }

    func testWeatherWidgetIsBelowClockInPortrait() {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-weather-frame"]
        app.launch()

        let clock = app.otherElements["canvas.clock.overlay"]
        let weather = app.otherElements["canvas.weather.overlay"]
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        XCTAssertTrue(weather.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(weather.frame.minY, clock.frame.maxY)
        XCTAssertEqual(weather.frame.minX, clock.frame.minX, accuracy: 12)
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

    func testUnavailableAlbumSurvivesDoneRestartAndExplicitRemoval() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-minute-duration"]
        app.launch()
        for _ in 0..<2 {
            XCTAssertTrue(app.buttons["Manage albums"].waitForExistence(timeout: 5))
            app.buttons["Manage albums"].tap()
            XCTAssertTrue(app.navigationBars["Choose albums"].waitForExistence(timeout: 5))
            let missing = app.buttons["album-choice-ui-test-album"]
            XCTAssertTrue(missing.waitForExistence(timeout: 5))
            XCTAssertEqual(missing.value as? String, "Selected")
            app.buttons["Retry Photos"].tap()
            XCTAssertEqual(missing.value as? String, "Selected")
            app.buttons["Done"].tap()
            XCTAssertTrue(app.buttons["Manage albums"].waitForExistence(timeout: 5))
            app.terminate()
            app.launchArguments = []
            app.launch()
        }
        app.buttons["Manage albums"].tap()
        let missing = app.buttons["album-choice-ui-test-album"]
        XCTAssertTrue(missing.waitForExistence(timeout: 5))
        missing.tap()
        XCTAssertEqual(missing.value as? String, "Not selected")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.otherElements["empty-albums-state"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.otherElements["empty-albums-state"].waitForExistence(timeout: 5))
    }

    func testHomeUsesPersistedMinuteDuration() {
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-minute-duration"]
        app.launch()
        let duration = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "1 min photos")).firstMatch
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
    }

    func testGooglePhotosConnectionAndAlbumVisibilityPersistence() {
        // A failed toggle must stop here, rather than making the next tap
        // enable it and producing misleading failures for the opposite state.
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-home"]
        app.launch()
        XCTAssertTrue(app.buttons["Manage albums"].waitForExistence(timeout: 5))
        app.buttons["Manage albums"].tap()
        XCTAssertTrue(app.navigationBars["Choose albums"].waitForExistence(timeout: 3))
        let emptyAlbumToggle = app.switches["Show albums with 0 photos"]
        XCTAssertTrue(emptyAlbumToggle.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Included with Canvas"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Landscapes"].exists)
        XCTAssertTrue(app.staticTexts["Cityscapes"].exists)
        XCTAssertTrue(app.staticTexts["Abstract"].exists)
        func expectEmptyAlbums(_ value: String) {
            let expected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", value),
                object: emptyAlbumToggle
            )
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
        }
        func toggleEmptyAlbums(to value: String) {
            // SwiftUI exposes both the labelled row and its native switch.
            // The row's center is not the switch's tappable control on iPad.
            let control = emptyAlbumToggle.descendants(matching: .switch).firstMatch
            let ready = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true AND enabled == true"),
                object: control
            )
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            control.tap()
            expectEmptyAlbums(value)
        }
        XCTAssertEqual(emptyAlbumToggle.value as? String, "0")
        toggleEmptyAlbums(to: "1")
        app.navigationBars["Choose albums"].buttons["Done"].tap()
        app.terminate()
        // Relaunch without reset and verify the nondefault value: an off
        // value would also pass if persistence silently fell back to defaults.
        app.launchArguments = ["--canvas-ui-home"]
        app.launch()
        XCTAssertTrue(app.buttons["Manage albums"].waitForExistence(timeout: 5))
        app.buttons["Manage albums"].tap()
        XCTAssertTrue(app.navigationBars["Choose albums"].waitForExistence(timeout: 3))
        expectEmptyAlbums("1")
        toggleEmptyAlbums(to: "0")
        app.navigationBars["Choose albums"].buttons["Done"].tap()
        app.buttons["Manage albums"].tap()
        XCTAssertTrue(app.navigationBars["Choose albums"].waitForExistence(timeout: 3))
        expectEmptyAlbums("0")
        let albumList = app.collectionViews.firstMatch
        let googleImport = app.buttons["Add or refresh a Google album"]
        for _ in 0..<6 where !googleImport.exists { albumList.swipeUp() }
        XCTAssertTrue(googleImport.waitForExistence(timeout: 3))
        googleImport.tap()
        XCTAssertTrue(app.navigationBars["Google Photos"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Open Google Photos"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "no Google OAuth client")).firstMatch.exists)

        let contributorGuidance = app.staticTexts["google-shared-contributor-guidance"]
        let additiveGuidance = app.staticTexts["google-additive-picker-guidance"]
        let importForm = app.collectionViews.firstMatch
        for _ in 0..<6 where !contributorGuidance.exists || !additiveGuidance.exists { importForm.swipeUp() }
        XCTAssertTrue(contributorGuidance.waitForExistence(timeout: 3))
        XCTAssertTrue(additiveGuidance.waitForExistence(timeout: 3))
        XCTAssertTrue(contributorGuidance.label.contains("Save all"))
        XCTAssertTrue(additiveGuidance.label.contains("previously saved Canvas items stay"))
        XCTAssertTrue(additiveGuidance.label.contains("2,000 items"))

        let appleMirrorGuidance = app.staticTexts["google-apple-photos-mirror-guidance"]
        let fullAccessGuidance = app.staticTexts["google-apple-full-access-guidance"]
        for _ in 0..<8 where !appleMirrorGuidance.exists || !fullAccessGuidance.exists { importForm.swipeUp() }
        XCTAssertTrue(appleMirrorGuidance.waitForExistence(timeout: 3))
        XCTAssertTrue(fullAccessGuidance.waitForExistence(timeout: 3))
        XCTAssertTrue(appleMirrorGuidance.label.contains("All Photos"))
        XCTAssertTrue(appleMirrorGuidance.label.contains("never deletes or replaces Apple Photos assets"))
        XCTAssertTrue(fullAccessGuidance.label.contains("Full Access"))
        XCTAssertTrue(fullAccessGuidance.label.contains("no new Google selection is needed"))
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

        // On a landscape iPad, the form occupies only the lower half of the
        // settings sheet. Scroll that form rather than the preview behind it.
        let settingsForm = app.collectionViews.firstMatch
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 3))
        let weatherGroup = settingsForm.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Weather & Visibility")).firstMatch
        for _ in 0..<12 where !weatherGroup.exists { settingsForm.swipeUp() }
        XCTAssertTrue(weatherGroup.waitForExistence(timeout: 3))
        weatherGroup.tap()

        let weatherToggle = app.switches["Current weather (opt-in)"]
        for _ in 0..<4 where !weatherToggle.exists {
            settingsForm.swipeDown()
        }
        XCTAssertTrue(weatherToggle.waitForExistence(timeout: 5))
        guard weatherToggle.exists else { return }
        let wasEnabled = (weatherToggle.value as? String) == "1"
        defer {
            if !wasEnabled {
                for _ in 0..<8 where !weatherToggle.isHittable { settingsForm.swipeDown() }
                if weatherToggle.exists, (weatherToggle.value as? String) == "1" {
                    weatherToggle.tap()
                }
            }
        }
        if !wasEnabled {
            weatherToggle.tap()
            let allowWhileUsing = app.buttons["Allow While Using App"]
            if allowWhileUsing.waitForExistence(timeout: 5) { allowWhileUsing.tap() }
            let allowOnce = app.buttons["Allow Once"]
            if allowOnce.waitForExistence(timeout: 1) { allowOnce.tap() }
        }

        let status = settingsForm.descendants(matching: .any)
            .matching(identifier: "canvas.weather.status").firstMatch
        for _ in 0..<8 where !status.exists { settingsForm.swipeUp() }
        XCTAssertTrue(status.waitForExistence(timeout: 25))
        guard status.exists else { return }
        let isLive = NSPredicate(format: "label == %@", "Weather status: Weather live")
        expectation(for: isLive, evaluatedWith: status)
        waitForExpectations(timeout: 45)
    }

    func testGrantPhotosForStoreCapture() throws {
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/tmp/canvas-grant-photos.flag"),
            "Create /tmp/canvas-grant-photos.flag to tap the Photos permission sheet for store capture."
        )
        let app = XCUIApplication()
        app.launchArguments = [
            "--canvas-ui-reset",
            "--canvas-ui-home",
            "--canvas-ui-showcase",
            "--canvas-ui-request-photos"
        ]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowTitles = ["Allow Full Access", "Allow Access to All Photos"]
        var tapped = false
        for title in allowTitles {
            if app.buttons[title].waitForExistence(timeout: 6) {
                app.buttons[title].tap()
                tapped = true
                break
            }
            if springboard.buttons[title].waitForExistence(timeout: 2) {
                springboard.buttons[title].tap()
                tapped = true
                break
            }
        }
        XCTAssertTrue(tapped || app.buttons["start-your-frame"].waitForExistence(timeout: 8) || app.descendants(matching: .any)["start-your-frame"].waitForExistence(timeout: 2))
        sleep(2)
    }

    func testSlideshowLifecycleStress() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/tmp/canvas-lifecycle-stress.flag"),
            "Create /tmp/canvas-lifecycle-stress.flag to run the longer playback test."
        )
        let app = XCUIApplication()
        app.launchArguments = ["--canvas-ui-reset", "--canvas-ui-home"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-albums-empty-state"].waitForExistence(timeout: 5))
        app.buttons["choose-albums-empty-state"].tap()
        for title in ["Landscapes", "Cityscapes", "Abstract"] {
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
            app.staticTexts[title].tap()
        }
        app.buttons["Done"].tap()
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Start your frame")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        XCTAssertTrue(app.otherElements["Canvas slideshow"].waitForExistence(timeout: 10))
        // Two minutes of timer-driven playback, with screenshots retained for
        // visual confirmation that real media and transitions were exercised.
        for sample in 0..<6 {
            sleep(20)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertFalse(app.staticTexts["Choose an album with playable media to start Canvas."].exists)
            XCTAssertFalse(app.staticTexts["Unavailable"].exists)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Sustained slideshow \(sample)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        app.launchArguments = ["--canvas-ui-play"]
        for cycle in 0..<6 {
            XCUIDevice.shared.press(.home)
            let background = NSPredicate { _, _ in
                app.state == .runningBackground || app.state == .runningBackgroundSuspended
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: background, object: nil)], timeout: 5), .completed)
            sleep(2)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Relaunch \(cycle)")
        }
    }

}
