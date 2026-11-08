# Canvas Slideshow 1.0.10 (81)

## Changes

Retains the eight frame-experience refinements from PR #22 and the identifier-only album recovery from PR #23. This replacement fixes three regressions found in release review:

- Deliberate album identity refreshes revalidate cloud mappings, including for albums that still resolve locally. Membership-only changes retain their content-only fast path.
- A degraded PhotoKit fallback remains visible without entering the final-image cache, allowing a later visit to retry high-quality loading.
- Caption and location migrations preserve legacy choices once. New settings and presets keep filename and coordinate overlays off unless explicitly enabled, including after relaunch.

## Release preparation

Live App Store Connect preflight on November 8, 2026 verified public 1.0.9 (76), pending 1.0.10 (78), and highest uploaded 1.0.10 build 80. Candidate 81 passed the repository build-number preflight. Xcode Cloud's Manual Public Release workflow produces the single App Store-eligible build intended for both the existing Internal TestFlight group and App Review.

Existing public release settings, screenshots, privacy identity, and user data are preserved. The pending submission will be replaced with the validated candidate.

## Validation

New regression coverage exercises cloud cache refresh before a local-ID change, preview fallback cache avoidance and later HQ reuse, and settings/preset persistence across migration and relaunch. Full native and tooling results and provider release evidence are recorded in the release PR after completion. Physical-device, fresh-install/upgrade, iCloud, APNs, and multi-day playback coverage are not claimed from simulator evidence.
