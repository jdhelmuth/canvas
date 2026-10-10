# Canvas Slideshow 1.0.4 (66)

## What's New

- Shuffle now works through every eligible photo before repeating, including photos shared across selected albums.
- Shuffle progress is saved across restarts, and temporarily unavailable photos remain queued for retry.
- Canvas now warns when a selected album is unavailable so missing albums cannot silently reduce your slideshow.

## Validation and distribution

Release includes the full-shuffle and missing-album fixes from `8c14ff6` and `22199f3`. The implementation passed 254 unit tests, signed Debug and unsigned Release device builds. Physical iPad diagnostics confirmed two stale album references; a narrowly scoped repair restored a 1,538-photo eligible queue, preserved other settings, and verified timer advancement and restart progress. A full physical cycle was not observed.

Final local release gates and App Store Connect evidence are recorded by the release task. Xcode Cloud's established Manual Public Release workflow produces the single App Store-eligible build for both the existing internal TestFlight group and App Review. No fresh-install or exhaustive TestFlight smoke test is claimed. The already-running physical development slideshow is preserved during submission.
