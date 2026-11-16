# Album additions without losing playback

## Shipped behavior reproduced

Baseline: public 1.0.10 (81), commit `420f86e`.

A simulator regression starts a real PhotoKit album with three synthetic photos,
loads the playback model, inserts a fourth photo, then injects a temporary catalog
and collection-lookup gap. The shipped implementation reduced the queue from
three photos to zero, discarded its displayed frame, and consumed additional
shuffle entries when the collection returned. Its retained “playable” state held
only an album identifier: `assets(for:)` immediately fetched that same identifier
again. It did not retain the verified member fetch or observe its change details.

A second defect appeared in the real PlayerView UI scenario: AppStore reconciles
an album's updated photo count into saved selection metadata. Playback compared
the entire AlbumReference and treated the new count as a changed selection,
forcing a new frame. The UI regression failed at recovery until this comparison
was changed to effective source/collection identity (including proven aliases).

The reported physical-device trigger is consistent with these defects, but the
simulator does not reproduce iCloud service propagation. The catalog gap is an
explicit injected failure; the album creation and insertions are real PhotoKit
operations on disposable simulator-only fixtures. No user's Photos content is
used in test evidence.

## Recovery behavior

- Retain selected-album member fetches, collection objects, and PHAsset metadata.
  Apply incremental member changes directly and serialize observer callbacks.
- Add unique members immediately. Missing, empty, or shrinking fresh reads keep
  the last verified members pending instead of emptying the playback queue.
- Confirm incremental removals and collection deletion explicitly. A nonempty
  shrinking refetch remains pending until Photos provides explicit removal
  evidence. Repeated partial reads are not treated as proof of deletion just
  because an arbitrary timeout elapsed.
- Persist metadata-only membership alongside existing identity history. On
  restart, fetch only the saved asset IDs still accessible under Full Access.
  Permission-scope changes discard retained readable state; no permission is
  requested or broadened automatically. Unreadable persistence is not overwritten.
- Keep honest availability/recovery feedback in Settings. The player suppresses
  transient catalog warnings only when verified playable members are retained;
  permission loss, confirmed deletion, and no verified playable snapshot still
  surface as unavailable. Recovery retries continue for unresolved membership.
- Metadata/count/name changes do not rebuild the displayed frame. The durable
  shuffle cycle continues to append unique additions and retains its seen set.
  An exhausted partial cycle holds its final frame rather than repeating early;
  recovery keeps that frame until its timer or navigation advances it.

No title-only matching, Photos mutation, selection deletion, or settings reset is
part of production recovery. The opt-in Photos-writing fixture is compiled only
in DEBUG simulator builds, never in a physical-device or release build.

## Verification

Focused regression suite: real PhotoKit insertion + missing and empty reads,
restored service, permission-state transitions, unchanged frame/seen set;
metadata snapshot ordering, explicit deletion/removals, repeated partial reads,
identity migration, overlapping 1,804-photo restoration; 1,805-photo cycle with
additions, restart, pending failed-download identity, and boundary avoidance.

`AlbumAdditionUITests` runs the real PlayerView with three synthetic photos,
inserts four into the selected album during a read gap, checks no warning or
frame/seen-set change, backgrounds/foregrounds, recovers to seven, relaunches,
and deletes only exact receipt-owned fixture objects through PhotoKit with the
system confirmations handled by XCTest. The global simulator health monitor
observes the run and teardown independently.

Run the full repository checks using the dedicated Canvas simulator:

```
python3 scripts/check-local.py --base origin/main --simulator-id <Canvas-UUID>
```

The real-Photos integration test requires Photos authorization on that simulator.
It deliberately skips on physical devices. Save and restore the simulator's app
state/authorization around these integration/UI checks; do not use a real library.

## Limits

There is no guarantee that iCloud is available or that image data can download.
A verified cached asset may still need a network download; existing load-failure
recovery keeps that asset unconsumed. A first launch without any verified cache
cannot invent unavailable membership. When an album becomes truly empty while
Canvas is not observing, missing membership alone is indistinguishable from a
sync gap: the cache remains pending until a subsequent explicit membership change
or complete read, Settings explains recovery, and the cycle cannot prematurely
repeat. The first post-restart member fetch is observed so a subsequent real
membership change can resolve that ambiguity. Physical-device and
cross-device iCloud behavior require separately authorized real-device validation.

## Local final validation, 2026-11-16

On the dedicated Canvas iPad simulator (iOS 27.2, 24B114), the final aggregate
passed 345 unit tests, 27 UI tests, and 30 tooling tests. Four existing UI tests
were skipped by their opt-in/physical-device guards: store-capture Photos grant,
physical exit, physical live WeatherKit, and extended lifecycle stress. The
new actual-Photos album-addition scenario ran and passed. SpringBoard remained
stable through teardown (456 monitor samples, no health errors).

An unsigned Release build for device families iPhone and iPad also succeeded.
The version remains 1.0.10 (81); this is a local development artifact, not a new
public release. No physical-device installation, upload, submission, merge,
or push was performed. Separate Duo runtime coverage remains pending the
required temporary-simulator exception; the existing Duo belongs to ClimateIQ.
