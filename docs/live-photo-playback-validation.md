# Live Photo playback follow-up

Baseline: release commit `9f3be7f87798223c4ea719f1a22fbda51ff1407e`, 1.0.4 (66).
Work is isolated on `fix/live-photo-framing`. No release metadata or App Store submission was changed.

## Confirmed cause

The bridge tracked only whether playback was active. After PhotoKit reported completion, the next SwiftUI update called `startPlayback` again, even with Loop Live Photos disabled. The slideshow publishes progress every 100 ms. A read-only physical-iPad diagnostic reproduced four starts in one 12-second presentation with looping off (including a deliberate pause/resume). The outgoing transition layer could also create and start another Live Photo view.

This was not an additional app-level scale transform. The native view bounds stayed stable before, during, and after playback. The saved Fill setting deliberately crops a portrait photo when filling a landscape iPad; automatic layouts present Live Photos individually. Natural camera movement and PhotoKit's still-to-motion rendering remain part of the source Live Photo.

## Change

- Track ready, playing, stopping, and completed states for each presented asset.
- Keep completed nonlooping clips still through subsequent updates and pause/resume.
- Wait for PhotoKit's stop callback before restarting an interrupted clip.
- Start only after a Live Photo is loaded; ignore degraded, cancelled, failed, duplicate, and stale deliveries.
- Give each asset its own view identity and explicit viewport. Only the incoming frame may play; an outgoing frame does not start another clip.
- Disable PhotoKit's default long-press playback gesture so it cannot bypass the slideshow lifecycle.

## Physical iPad evidence

Tested the existing iPad Pro 11-inch (3rd generation), iPadOS 27.2 beta, using existing development signing and an in-place install. No uninstall, Photos asset edits, album changes, settings writes, or shuffle reset.

The opt-in DEBUG launch argument `--canvas-live-photo-check` uses existing selected albums to display one portrait and one landscape Live Photo in Fit and Fill, in landscape and portrait-shaped viewports: eight cases, 40 snapshots. It does not create a playback queue or save settings. Its local results are in the app's `Documents/live-photo-check`; never launch it as a normal slideshow mode.

All eight cases reached completed state and remained there through subsequent updates. The longer portrait clip exercised interruption and resume before completion; the shorter landscape clip exercised pause/resume after completion without replay. Before-motion and after-completion pixels were identical in all eight cases, excluding the diagnostic label. Native motion was visibly rendered between them. This confirms stable final framing, not pixel identity throughout camera motion.

The fresh preinstall/postdiagnostic settings and shuffle checkpoint were byte-identical. After normal slideshow resumption, seen count advanced from 211 to 213 with original queue order and all earlier seen IDs preserved. Saved Live Photos remained disabled, Fill remained selected, and the three selected albums were unchanged.

Supporting evidence is stored outside the repository in `../live-photo-check/`: `final-diagnostics/fixed-events.txt`, `framing-comparison.json`, `data-preservation.json`, build/test logs, install results, and private local snapshots. The full app container was backed up before installing.

## Validation and limits

Three additional regression tests cover completion across repeated updates, interruption ordering, loop toggles, and duplicate completion callbacks. The existing stale-request test remains. Required local checks passed: 257 unit tests and 16 UI tests, with two unrelated opt-in UI tests skipped (physical WeatherKit and store-capture authorization). Both the signed device Debug build and unsigned generic-iOS Release build succeeded. The simulator's prior preferences were restored and its live Canvas preview verified after the suite.

Physical testing used two real assets with 3:4 and 4:3 aspect ratios. Portrait-shaped viewport testing did not physically rotate the iPad. Not exhaustively tested: every Live Photo, edited/square/wide Live Photos, prolonged iCloud failures, or other iPadOS versions. Screen recording was unsupported by this device; snapshots and native playback callbacks provide the evidence. Explicit continuous looping is covered by state-machine tests, not a physical long-duration loop run.

The local development build is installed and the saved slideshow resumed. Public 1.0.4 (66) remains untouched; including this follow-up in an App Store release requires separate approval.
