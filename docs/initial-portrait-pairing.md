# First-render portrait pairing

Base: recovery commit `1f928744d68adf1a9161d57266f2fcc909e11c5b`, TestFlight 1.0.11 (83).

The first frame could differ from the frame reconstructed after a swipe:

- The primary image's degraded preview was published alone, even when its intended group contained a second portrait. Fill framing therefore treated the preview as a complete single slide.
- Group selection used provider dimensions only. Missing dimensions could leave an actual portrait unpaired even after its image decoded.
- A library refresh preserved a frame when its identifiers survived, without checking whether updated dimensions changed the group.
- A failed companion request published the primary as a finished single and had no retry while that slide remained visible.

The player now uses decoded display dimensions, resolves a compatible immediate neighbor before publishing a group, and withholds a primary-only preview when companions are expected. It does not search past an intervening incompatible photo, video, or Live Photo. Explicit single layouts and ordinary landscape-fill framing retain their existing rules.

A failed companion leaves its primary visible in temporary fit framing, rather than cropping a portrait into the missing pair's full-screen space. The companion retries on the existing 30-second recovery cadence, reusing the primary image and elapsed time. Successful recovery repairs the group in place. Pause/power gates suspend retries; generation and identity checks reject results after navigation, rotation, or closure. Repeated library notifications do not postpone an already scheduled retry. Only displayed photos enter the shuffle seen set.

Dimension changes reconcile the current group without reconnecting albums or resetting the queue, settings, or persisted shuffle cycle. The recovery changes from build 83 remain included.

## Evidence

Deterministic tests observe every published frame, not just the final settled image. They cover an early preview, missing and late dimensions, transient companion failure, pause/navigation cancellation, repeated refreshes, intentional singles, and timer advancement past the complete pair. The first three regressions and the late-dimensions regression failed on the unchanged build-83 playback implementation.

A DEBUG-simulator-only fixture creates two labeled portrait images and an adjacent landscape image in a disposable Photos album. It supplies missing metadata and an early preview, then exercises the production player and renderer. A diagnostic records the very first frame's group size. On the build-83 player, this UI test recorded `firstGroup=1` and failed its two-photo assertion in both Fit and Fill Zoom modes. The late-metadata test also demonstrated that swiping away and back constructed the pair that the refresh had failed to repair. The corrected scenario also checks next/back, rotation, foreground, and relaunch. Cleanup targets only receipt-recorded fixture identifiers.

Validation logs, XCTest result paths, simulator health reports, and synthetic screenshots are retained outside the repository in the task's `Canvas-portrait-pairing-evidence` directory. The final aggregate and release receipts establish the exact candidate and results; a local test or archive does not establish TestFlight availability.

## Limits and distribution

These tests reproduce app defects with controlled provider delays. They do not establish which delay occurred on John's physical iPad or validate live iCloud propagation. No personal Photos library, physical device, or installed TestFlight app was changed. iPhone Duo runtime testing requires an explicit exception to the current one-simulator-per-app rule; another app's device is not used.

The combined candidate is for the existing internal TestFlight group. App Store review remains withdrawn pending John's confirmation of both fixes. Public source publication requires approval for this additional diff; the recovery-only publication approval does not cover it. Canvas's established distribution workflow is Xcode Cloud.
