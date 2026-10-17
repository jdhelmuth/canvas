# Selectable right-side weather scale

The existing right-edge scale now supports Dew point, Temperature, and Feels like.
The choice is saved with overlay settings and presets. New settings prefer Feels
like; legacy saved settings retain their existing dew-point scale until changed.
Visibility uses the existing saved key, avoiding an unrelated settings migration.

Temperature and feels-like use a cold-to-hot gradient from -20°F to 120°F.
The marker clamps at the endpoints while its numeric label retains the actual
reading. Dew point keeps the existing comfort bands. Tick and marker labels use
the device's existing localized temperature formatter. WeatherKit supplies its
actual and apparent temperature measurements; Ambient supplies tempF and
apparentTempF. Raw values are persisted for positioning, with compatibility
parsing for older cached snapshots. Missing or nonfinite selected readings hide
the scale; actual temperature never substitutes for missing feels-like data.

The player and settings preview share the same scale. Precipitation chance and
next-hour information remain in the existing weather details. No additional
vertical precipitation scale or duplicate weather widget is introduced.

## Validation

The complete iOS 27 run at `f24597a` passed 263 unit tests, 18 UI tests,
and 30 tooling tests; three opt-in UI tests were skipped. Coverage includes
provider precision, distinct actual/apparent temperatures, cold/hot readings,
localized units, legacy Celsius snapshots, missing/nonfinite values, range
clamping, settings restart persistence, and legacy selection compatibility.
The settings UI test switches through all three readings and retains Feels like
after relaunch. Portrait and landscape were visually reviewed from full-display
captures; application-only screenshots can incorrectly crop stale portrait bounds
after rotation, so this test now captures XCUIScreen.main instead.

The first iOS 26.5 session was rejected after the confirmed Apple automation
teardown crash. The dedicated Canvas simulator was upgraded in place, with a
verified data backup, to iOS 27.0 build 24A434. Its corrected automation binary
and unchanged SpringBoard PID were verified through the successful suite and
focused visual test teardown. See springboard-investigation.md. Failed and
interrupted earlier runs remain recorded as failures, not passing evidence.

Evidence is retained in ../weather-scale-evidence and the runtime repair task's
evidence directory. No crash reporting was disabled or reports dismissed.
No physical-device fresh-install, upgrade, or TestFlight smoke test is claimed.

## Release

The authorized release is 1.0.5 (68), using one App Store-eligible Xcode Cloud
build for internal TestFlight and App Review. Provider readback determines actual
build and submission status; local validation alone is not a public release.
Existing users retain their saved choice. The requested personal Feels-like
selection is applied only to the prepared simulator settings; the running physical
slideshow is preserved until the App Store update is installed and selected there.
