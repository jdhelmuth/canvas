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

## Validation checkpoint

The 263 unit tests passed, including distinct cold/hot apparent readings,
provider precision, legacy Celsius snapshots, localized units, missing data,
range clamping, settings restart persistence, and legacy selection compatibility.
The settings UI test passed switching through all three options and retaining
Feels like after relaunch. Portrait appearance was visually reviewed.

Full aggregate and final landscape verification are pending coordinated simulator
diagnosis. The first focused session encountered the known iOS 26.5 Apple
XCTAutomationSupport teardown crash: incident
2ECF770E-5365-4D06-83AB-29C683F52A01, October 17 at 17:43:21 Eastern,
EXC_BAD_ACCESS at 0x20 in the automation-session block at +192 with x19 = 0.
The monitor rejected that session. Subsequent rotation was stuck; one scoped,
data-preserving simulator restart was completed. The aggregate rerun passed all
263 unit tests before UI testing was interrupted for the separately assigned
crash investigation. That interrupted aggregate is not a passing result.

Evidence is retained locally in ../weather-scale-evidence. No crash reporting was
disabled, and the report was not dismissed. No physical device was touched.

## Release scope

This is an app behavior change and needs a new app release or separately approved
device installation to reach the installed app. Existing approvals for 1.0.4 (67)
and the prior simulator-tooling merge do not authorize releasing this feature.
Version/build remain unchanged during implementation. No merge, distribution
build, App Store submission, or physical installation is included in this task.
The requested personal Feels-like selection will be left in the prepared simulator
setup once validation and simulator ownership are available again; the physical
app's selection is unchanged.
