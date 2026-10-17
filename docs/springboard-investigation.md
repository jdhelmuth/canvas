# Canvas simulator SpringBoard failure — October 11, 2026

## Confirmed cause

Incident `BC89A6CD-7926-4CC7-BC37-47E2BF6BE697` belongs to the dedicated
Canvas simulator, `C02D7BA6-FB18-4447-814B-571FF8AAD784`. It occurred on
October 10 at 21:10:36.750 EDT, after the UI suite passed at 21:10:36.538.
Xcode nevertheless returned `TEST SUCCEEDED` at 21:10:36.936.

The faulting thread is inside Apple's `XCTAutomationSupport`, in
`__66-[XCTAutomationSession initWithAccessibilityFramework:dataSource:]_block_invoke + 192`.
The framework's UUID is `711229F6-7A68-3A82-A27A-0439C2E1D62A` (iOS 26.5,
build 24901), exactly matching the installed simulator runtime binary.
At offset `0x2b964`, the instruction is `ldr x0, [x19, #0x20]`; the crash
registers have `x19 = 0` and the fault address is `0x20`. Immediately before
this, the block loads a weak reference, retains it, and enters synchronization
without testing for nil. This is a nil dereference in Apple's automation
session invalidation, not an unsymbolicated Canvas stack frame.

The device log shows XCTest tearing down its session at 21:10:36.580,
Canvas exiting normally via SIGTERM at .581, automation being disabled at
.582, and SpringBoard invalidating automation connections at .585. SpringBoard
restarted from PID 80636 to 64469. There is no Canvas crash or evidence of an
out-of-memory termination in this report.

The separately installed Xcode 27.0 framework (arm64 UUID
`2AFDDABB-38F9-38F3-B805-AC3B60BDF165`) contains a nil branch before accessing
that field in the same block. It is **not** the binary used by this simulator.
At the time of this investigation, only iOS 26.5 was installed as a simulator runtime. Do not replace,
inject, or patch Apple's private frameworks. A compatible runtime containing
the corrected implementation must be validated separately before claiming the
underlying Apple defect is resolved.

The October 1 incident was different: a missing main CADisplay after a failed
simulator boot. Its startup health gate remains useful, but does not detect a
restart at the end of an otherwise successful test session.

## Project remedies

- Explicitly terminate Canvas and wait for its exit and SpringBoard foreground
  state in UI-test teardown, while the XCTest automation session is still alive.
  This separates app exit from session invalidation. It is a mitigation, not a
  proof that Apple's weak-reference race cannot recur.
- Require an explicit simulator UUID for local native checks. Do not silently
  select another app's booted iPad or automatically boot/recover a device.
- Hold a per-device lock across the local check and its teardown observation.
  This coordinates participating Canvas checkouts; raw external tools still
  require human/agent ownership coordination.
- Sample SpringBoard's PID throughout tests and for ten seconds afterward,
  check the display before and after, and fail on any missing or changed PID.
  A later healthy restart never clears an earlier failure.
- Save machine-readable evidence in `.git/simulator-checks.json`, including on
  failure. Clear stale `.git/local-checks.json` success before a new check.

Run native checks on the already healthy dedicated device:

```sh
python3 scripts/check-local.py --platform ios --simulator-id <Canvas-UUID>
```

Do not suppress crash reporting, erase devices, restart shared CoreSimulator
services, or retry until green after a monitor failure. Preserve the failed
run and inspect its report. A successful Xcode exit alone is insufficient.

No production app code, release version, photo data, album membership, physical
iPad state, or App Store submission is changed by these remedies.

## Playback and lifecycle exercise

The opt-in `testSlideshowLifecycleStress` captures six slideshow frames over two
minutes, then performs six Home/background, activation, termination, and relaunch
cycles. It selects the existing Landscapes, Cityscapes, and Abstract bundled albums
through the app UI, without accessing or changing the Photos library. Before
using it, back up simulator app settings;
UI tests deliberately reset test settings. Enable it with
`/tmp/canvas-lifecycle-stress.flag`, run the monitored native checks, then remove
that flag and restore the simulator settings. Do not run it on the physical iPad.

Initial checks also exposed a persistent orientation problem: both the unchanged
baseline test and two layout tests stayed in portrait, and the simulator Home
screen did not reflow on rotation. One targeted shutdown/start of the Canvas
simulator, with its preview stopped and data preserved, restored orientation
changes. This was performed between recorded runs, not by the validation script,
and does not repair the separate XCTest framework defect.

## Validation results

- 257 unit tests passed, including the existing full-shuffle tests with more
  than 1,300 assets, overlapping albums, restart, and load-failure cases.
- All 16 ordinary UI tests passed after the scoped orientation recovery. Two
  pre-existing opt-in tests were skipped. The full suite retained SpringBoard
  PID 64425 through 315 monitor samples and the ten-second teardown tail.
- 27 Python tooling tests passed: 16 local-check/monitor tests and 11 release
  helper tests. Coverage includes a restart after a successful command,
  transient PID failures, unhealthy displays, overlapping device ownership,
  propagation of test failures, and removal of stale success records.
- The corrected bundled-photo stress test passed separately: two minutes of
  actual timed playback from a 31-photo pool, six background/activation/
  termination/relaunch cycles, and six retained screenshots. A checkpoint
  recorded 14 distinct displayed photos during the run. The first and last
  screenshots visibly contain different photos. Its 152 monitor samples
  retained SpringBoard PID 64425.
- Three additional independent XCTest sessions each ran the exact final
  weather layout test from the original incident. All passed with stable
  SpringBoard PID 64425 through 20, 19, and 18 samples respectively.
- Outside XCTest, device logs confirm Canvas PID 93254 suspended at
  15:21:22.757 EDT on October 11 and returned to Running/Foreground at
  15:21:59.600. Direct activation returned that same PID. The initial standalone
  observer reached its bounded deadline during setup; this subsequent
  same-process resume was verified from logs and a final health check.
- No new Canvas/SpringBoard incident for this simulator appeared in the final
  crash inventory. Original simulator preferences were restored and compared
  with their backup. Photos permission remained denied. A location permission
  prompt encountered during standalone testing was left unanswered.

The initial stress fixture displayed an empty frame because Photos access was
denied; that run is not counted as photo-playback coverage. The corrected test
selects bundled albums and rejects empty/unavailable playback. Its first setup
attempt also exposed a Start-button selector mismatch; the selector was fixed
to match the observed UI before the successful run. Production app sources and
version 1.0.4 (67) remain unchanged.

Local evidence is retained outside the repository under
`../springboard-investigation/` (relative to the repository root):

| Evidence | File |
| --- | --- |
| Full suite and 27 tooling checks | `final-checks.log`, `full-suite-health.json` |
| Corrected real-photo stress run | `verified-0.log`, `verified-0.json`, `verified-0.xcresult` |
| Independent teardown runs | `verified-sessions.log`, `verified-1.json` through `verified-3.json` |
| Photo frames and checkpoint | `playback-frames/manifest.json`, `playback-checkpoint.json` |
| Same-process suspension/resume | `direct-background.log`, `direct-resume.log` |
| Final state | `settings-restoration.json`, `final-health.json`, `final-crash-inventory.json` |
| Exact framework instructions | `nil-reference-evidence.txt` |

These are bounded checks, not a long unattended soak or proof that Apple's
runtime race is eliminated. The unmodified single-test baseline did not
reproduce the crash, so the mitigation's prevention rate cannot be quantified.
A compatible simulator runtime containing the nil guard, followed by these
same checks, remains the next step for the underlying Apple framework defect.

## October 17 recurrence and runtime gate

Incident `2ECF770E-5365-4D06-83AB-29C683F52A01` occurred at
17:43:21.5704 EDT on October 17, on the same dedicated Canvas simulator.
The visible Problem Reporter window points to this new report. SpringBoard
1.0 (50), PID 52372, again faulted at `0x20` with `x19 = 0` in the same
`XCTAutomationSession` block at +192. The loaded iOS 26.5 (24901)
`XCTAutomationSupport` UUID remains `711229F6-7A68-3A82-A27A-0439C2E1D62A`.
Logs place UI-test runner connection invalidation at 17:43:21.341 and
"Automation Mode has been disabled" at .349, immediately before the fault.
This is a new recurrence of Apple's simulator defect, distinct from the
CuePilot app entitlement issue and from physical-device operation.

The existing monitor correctly failed the focused run when SpringBoard
changed from PID 52372 to 68606. App teardown ordering is therefore not a
sufficient remedy for this runtime. Restarting the device restores operation
but leaves the faulty framework installed.

Local native checks now inspect the selected device's runtime and the UUID of
its actual `XCTAutomationSupport` binary before running XCTest. They reject
the confirmed faulty binary, rather than trusting the version of Xcode's
separate framework. Missing or unidentifiable runtime evidence also blocks
the run. Different binaries still require the existing display/PID checks
and post-session observation; an unknown UUID alone does not prove safety.
No reporting suppression, private framework patching, or device erasure is
part of this change.

Apple's iOS 27.0 runtime (24A434) was subsequently installed through
`xcodebuild -downloadPlatform`. Its actual automation framework UUID is
`14BC2A20-5679-339C-BA39-69C8AB78B5CA`. Disassembly of the same block shows
`objc_loadWeakRetained`, followed by `cbz x8, 0x2ad28` at offset `0x2aae8`,
before the field access at `0x2aaf8`. This closes the demonstrated nil access
path; the old runtime has no such branch. The canonical Canvas device was
upgraded with `simctl upgrade`, preserving its UUID and data, after a full
stopped-device backup verified 12,741 file hashes (3,813,252,455 bytes).

The first iOS 27 regression exposed a test compatibility issue: SwiftUI's
weather attribution is now reported as accessibility type `Link`, while the
old test queried only `Button`. A diagnostic hierarchy confirmed the original
identifier and expected label were both present. The test now queries the
identifier across element types, preserving the existence and label checks;
the negative attribution assertion uses the same lookup. Production UI is
unchanged. The initial failed assertion and diagnostic run are retained and
are not counted as successful UI tests; SpringBoard stayed stable through
both teardowns.
