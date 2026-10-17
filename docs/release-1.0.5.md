# Canvas Slideshow 1.0.5 (68)

## What's New

- Choose Feels like, Temperature, or Dew point for the right-side weather scale.
- Temperature scales use a cold-to-hot range and your device's temperature units.
- Your scale choice is remembered. Existing saved choices are preserved.

## Validation and distribution

Implementation: 263 unit tests, 18 UI tests, and 30 tooling tests passed on the
dedicated Canvas iPad simulator running iOS 27.0; three opt-in UI tests skipped.
A focused full-display check verified the right-side Feels-like scale in portrait
and landscape and persistence after relaunch. Missing apparent temperature hides
the scale rather than substituting actual temperature. Precipitation remains in
the existing weather widgets.

The final release gate and provider evidence are retained by the release task.
Use one Manual Public Release Xcode Cloud build for both internal TestFlight and
App Review, with automatic release after approval. Physical fresh-install,
upgrade, and TestFlight smoke tests are unverified; the running iPad slideshow
and its saved settings are preserved during submission.
