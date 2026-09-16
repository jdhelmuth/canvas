# Canvas reliability fixes

September 15, 2026. Addresses the 16 findings from the audit of commit
`5c70bda58f877d207e7b8fd546bedea37a2de8cf`. The initial implementation retained
version 1.0 (61); release preparation subsequently advanced to 1.0.1 (62).

## Changes

| Finding | Resolution | Regression evidence |
|---|---|---|
| 1. Slideshow work survives dismissal | Explicit teardown cancels and invalidates playback, loading, retries, and queued reloads. Timer suspension does not retain the model. | Late-load rejection, deallocation, and no advancement after stop tests. |
| 2. An unavailable image stalls playback | Bounded skip attempts keep the last good frame; all-unavailable queues retry after a delay and respect playback gates. Nonrepeating recovery resumes at the failed destination. | Missing-first, all-failed, recovery, blocked-retry, and nonrepeating tests. |
| 3. Shared assets can identify the wrong Apple album | Collection ownership requires its persisted identifier or a durable creation receipt. An asset filename or album title cannot authorize adoption. Missing collections fail closed. | Shared-asset deletion, marker-only rejection, receipt restart/rename, corruption, and failed-creation cleanup tests. |
| 4. Same-ID photo changes leave stale decoded images | Apple cache identity includes modification date and library revision; local Google cache identity includes its content hash. | Actual same-ID image replacement and cache identity tests. |
| 5. Weather crosses station/account boundaries | Provider, hashed account identity, and station identify requests/cache; configuration changes invalidate old publication. Cached location is checked separately. | Delayed provider/configuration race and cache isolation tests. |
| 6. Weather reuses an old iPad location | Foregrounding reacquires location; normal refresh uses a 15-minute age policy. Initial unchanged OS authorization callbacks do not queue duplicate requests. | Location-age and injected-location callback regressions. |
| 7. Old weather/AQI looks current | Weather shows observation time and cached/stale state. AQI has its own checked time and expires after two hours, including during uninterrupted display. | Freshness labels, AQI expiry, and cache tests. |
| 8. Station timestamps govern unrelated data | Station measurements, local forecast, and AQI retain independent timestamps and update independently. Missing station timestamps remain unknown. | Unchanged/missing station timestamp with fresh local data tests. |
| 9. Remote station and local forecast are mixed | The overlay separates “Ambient station” from “Near this iPad.” Local forecast fields no longer fill station measurements. | Provider separation and merge tests; no station-coordinate assumption. |
| 10. Navigation scales quadratically | Pair selection checks adjacent items; group traversal is linear without repeated suffix copies. | Existing navigation tests, mixed-boundary regression, and matched before/after benchmark. |
| 11. Audio ignores schedule/power restrictions | Audio shares effective presentation, scene, schedule, power, and user-playback permission. Interruption recovery respects that permission. | Gate, pause/interruption, stale completion, sequential playlist, and shuffle tests. |
| 12. Hidden-items option is ineffective | PhotoKit fetch options explicitly receive the hidden-items setting. | Fetch-option regression. |
| 13. Date filters exclude boundary-day photos | Start/end refer to full calendar days, with a next-day exclusive upper bound. Reversed ranges normalize; unknown capture dates are excluded only while filtering by date. | Inclusive bounds, DST, reversed range, and missing date tests. |
| 14. Audio imports overwrite existing files | Unique internal names, staged validation, and atomic moves preserve existing tracks. Ordered relative references survive container relocation; errors are visible and copying runs off the main actor. | Name collision, long filename, copy/validation failure, order, and legacy-path tests. |
| 15. Release preflight succeeds without credentials | Missing required App Store Connect credentials fail the preflight. | Entrypoint and CLI exit-status regressions. |
| 16. Release-helper changes skip relevant checks | Script and non-documentation release configuration changes select the tools checks. Native checks accept an explicit dedicated simulator. | Scope classifier regressions. |

## Additional repairs

- Local imported images use ImageIO downsampling with EXIF orientation. A 2,200 × 2,200 bundled image used 19,360,000 decoded bytes at full size versus 1,960,000 bytes at a 700-pixel target (about 90% less). The 1,800-pixel target used 12,960,000 bytes (about 33% less). These are decoded-image measurements, not whole-process memory measurements.
- Ambient local forecast enrichment uses a separate 15-minute cache without refreshing the original observation timestamp.
- Unreadable settings preserve a recovery copy and surface a notice. Future-schema settings cannot be overwritten by this version. An unreadable Google album index no longer prunes saved album selections.
- Background audio plays an entire nonrepeating playlist once and visits each shuffled track once per cycle.
- Privacy documentation describes the Ambient credential/station proxy and separate iPad-local weather. README documents selecting a dedicated test simulator.

## Performance verification

The old and new navigation algorithms ran in the same optimized Swift executable
with equivalent automatic-layout portrait queues. All 20,480 comparison cases
produced identical navigation results.

| Items | Before | After |
|---:|---:|---:|
| 20,000 | 70.0 ms | 1.60 ms |
| 50,000 | 468 ms | 2.90 ms |
| 100,000 | 1,928 ms | 13.4 ms |

These measurements establish algorithmic improvement on the development Mac;
they are not iPad frame-rate measurements. Settings graph persistence remains an
unmeasured profiling candidate, so no debounce or persistence rewrite was added.

## Validation boundaries

The full local check gate passed on the dedicated iOS 26.5 iPad simulator:
219 unit tests, 14 UI tests, and 19 Python tooling tests passed. Two opt-in UI
tests were skipped: live physical-iPad WeatherKit and store-capture permission
setup. A separate unsigned generic-iOS Release build also succeeded. Existing
Xcode headermap/App Intents metadata warnings do not affect these results.
The current app was also exercised through its live interactive preview: choosing
the bundled Landscapes album, starting playback, automatic photo advancement,
and showing playback controls.

Deterministic provider and PhotoKit-policy tests cover failure and race cases.
The follow-up release pass also verified live weather for the connected iPad's
configured provider using development build 1.0.1 (62), with existing settings
preserved. The test was repaired to scroll the landscape settings form, expand
the weather section, and handle iPadOS 27 accessibility element types.
Real-account Google-to-Apple mirroring, Apple cloud downloads/hidden assets, and
the full fresh-install/upgrade TestFlight checklist remain release gates before
App Review. Xcode Cloud build 62 is valid, App Store eligible, and available to
the existing internal TestFlight group. App Review submission is still pending;
see `release/1.0.1.md` for the provider evidence and the subsequent simulator
infrastructure limitation while validating test-only corrections.
