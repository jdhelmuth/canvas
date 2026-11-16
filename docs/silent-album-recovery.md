# Silent album recovery after TestFlight 82

## Reproduced defects

Baseline source: `95c55cdb0e2d40b7cd5ec6ca36fce8fd4f47f677`, 1.0.11 (82).
John confirmed the affected TestFlight build. His physical iCloud/library state
was not inspected or changed. The following are reproduced app defects, not a
claim that his device has the exact synthetic identity history used below.

- An exact, readable local album was rejected when the selected reference and
  an older preset had different saved cloud identifiers and cloud mapping was
  temporarily unavailable. The retry loop ran, but repeated the same rejection.
- Saved photo identifiers were fetched once on launch. If that fetch and the
  album lookup were temporarily empty, subsequent recovery retried collections
  but never the saved photo identifiers independently.
- PlayerView unconditionally rendered album warnings above an already usable
  frame. The checking phase becoming a settled warning did not remove it.
  A separate image-download recovery banner could also cover a usable frame.

The new UI regression uses two real, disposable PhotoKit albums sharing three
synthetic photos. It inserts four more photos while injecting unavailable album
reads, with conflicting historical cloud metadata for the same local album.
It waits through the real checking backoff and then restores only the Photos
read boundary, without calling refresh, reconnect, or foreground recovery.

On the baseline, both Checking and the settled unavailable banner covered the
same valid slide; restoration failed to recover the seven-photo queue within
45 seconds. Two focused baseline tests also failed: exact-local identity with
missing cloud mapping, and independent cached-asset restoration after restart.
Screenshots and logs contain only generated test imagery.

## Corrected behavior

- A readable exact local identifier proves continuity even if cloud mapping is
  missing. Conflicting identifiers cannot choose a different album; names never
  establish identity. Current selection metadata takes precedence over stale
  preset metadata when cloud lookup cannot supply a new value.
- Foreground recovery retries missing saved asset IDs under Full Photos access.
  Newly readable assets advance the library revision so playback updates even
  without a new Photos notification. The existing capped retry/backoff and
  suspension lifecycle remain in use.
- Recovery does not place status over a usable slide. Settings retains accurate
  unresolved-album and permission feedback. Playback with no usable frame still
  explains unavailable selections, permissions, empty content or load errors.
- The existing queue and cycle reconciliation retains the current frame and
  seen set, deduplicates overlapping album additions, and does not start another
  shuffle cycle while selected membership remains unresolved.

No Photos writes, permission expansion, name-based reconnection, settings reset,
or shuffle-state reset is part of production recovery. The UI fixture performs
receipt-scoped writes only in opt-in DEBUG simulator builds. Fake cloud values
never reach PhotoKit, including on the fixture's next launch or cleanup.

## Release gate and limitations

Build 82 was withdrawn with explicit approval: its review is COMPLETE and
1.0.11 is DEVELOPER_REJECTED. TestFlight 82 and public 1.0.10 were preserved.
The replacement is intended for the existing internal TestFlight group first.
App Review remains held until the reported recurrence is confirmed resolved;
controlled simulator gaps are not physical or cross-device iCloud proof.

The canonical Canvas iPad simulator is used; ClimateIQ's Duo simulator is not.
Separate iPhone Duo runtime coverage requires the documented simulator exception.
An iPhone/iPad device-family build checks compilation, not that missing runtime
coverage. No personal iPad installation or Photos modification is performed.

When all album and photo identity evidence is unavailable, Canvas cannot infer
which same-named album is intended. It retains the saved selection and retries.
Actual permission loss or confirmed deletion still invalidates readable state.
Network/iCloud outages and first launch without cached membership cannot be
made equivalent to a successful sync by hiding a message or waiting a timeout.

## Final-source validation, 2026-11-16

Build 83 source passed 348 unit tests, 28 UI tests and 30 tooling tests.
The full XCTest result contains 380 cases: 376 passed, zero failed and four
existing guarded skips (store-capture grant, physical exit, physical WeatherKit,
extended lifecycle stress). Both real-Photos album addition UI scenarios ran.

The wait connection and parent check runner were interrupted near the end.
The original Xcode process continued without a duplicate run, completed all
tests successfully, and produced the authoritative Passed xcresult. The health
monitor was reattached through teardown; SpringBoard retained its original PID
and the final display/health checks passed. The interruption means there is no
continuous aggregate-monitor report; the focused run has its complete healthy
report, and the aggregate has before/after plus reattached teardown evidence.

The simulator's pre-test Documents/preferences and denied Photos authorization
are restored after receipt-owned fixture cleanup. No physical-device testing,
installation, personal Photos changes, or separate Duo run is claimed.
