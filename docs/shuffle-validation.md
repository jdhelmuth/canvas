# Complete photo shuffle

## Diagnosis

Base: `87791f0`, Canvas 1.0.3 (65), from the existing local Canvas repository.

There is no 1,000-photo enumeration limit. `PhotoLibraryService` enumerates every
PhotoKit fetch result with `fetchLimit = 0`, deduplicating overlapping selected
albums by asset identifier. Apple documents zero as unlimited:
https://developer.apple.com/documentation/photos/phfetchoptions/fetchlimit
Google Picker import follows all next-page tokens; its page size of 100 is not a
total limit. The image cache holds at most 48 decoded images and prefetch loads
four; neither bounds the queue. iCloud image requests allow network access.

The previous playback implementation could lose coverage in three ways:

- Each new PlayerView/session built a fresh shuffle with no saved cycle progress.
- Selection/filter/layout/recent-avoidance edits rebuilt the queue and relocated
  the current photo into that new order, without tracking which IDs were unseen.
- Failed primaries and companion tiles were advanced past without recording them
  as pending. Repeats could therefore begin while some eligible photos had never
  appeared. Cancelled PhotoKit callbacks also left continuations unresolved;
  stopping caching did not cancel the actual request.

These are code-level causes and reproducible regressions. The exact trigger on
John's physical iPad has not been observed directly, and Photos permission or
filters may independently restrict which assets are eligible.

## Behavior

Shuffle now checkpoints ordered IDs, displayed IDs, and the outgoing group on
local storage after committing a visible frame. Closing/reopening or relaunching
resumes at an unseen photo. Suspension gates playback and cancelled/stale results
do not consume a photo. Timer edits preserve coverage. Selection, filter, layout,
and album membership changes retain surviving progress and add new eligible IDs.
Removed and re-added IDs remain seen until that cycle completes.

Only successfully displayed tiles count. Failed preloads never count, failed
companions receive another turn, and unavailable cloud photos remain pending.
After all currently loadable unseen photos appear, Canvas retains the last frame
and retries the remaining photos every 30 seconds instead of repeating seen ones.
Each PhotoKit request has a 60-second timeout and finishes/cancels exactly once.
A permanently unavailable eligible photo must become available or be excluded
from Canvas before a new full cycle can begin. No Photos library writes were
added; user photos and album membership are untouched.

A completed cycle respects Repeat and Reshuffle each loop. The next shuffled
cycle moves outgoing tiles to the end to avoid an immediate repeat where enough
other photos exist. Explicit Back navigation still replays history by design.
One-photo/all-visible small libraries necessarily repeat at the next cycle.

## Verification

Automated playback tests use synthetic media metadata and injected image loaders:

- 1,307 unique photos with overlapping album lists: complete coverage before
  repeat, rebuilding model/persistence after 504 photos, timer edits, suspension,
  and provider refresh.
- 1,308 photos in four-photo groups: complete tile coverage and outgoing-group
  avoidance with per-loop reshuffle enabled.
- Failed primary cloud loads across restart; failed companions retried before any
  new cycle; refresh while recovering does not reload a seen photo.
- Selection/layout/membership edits; removal/readdition; temporary empty provider
  result; no-repeat completion; suspension during an unfinished load.
- Unlimited PhotoKit fetch options; callback/cancellation races complete once.
- Failed destinations never enter Back/Next history before they appear.

Large PhotoKit libraries, live iCloud network interruptions, and physical-iPad
fresh-install/upgrade testing remain outside this simulator verification. Existing
Photos filters, limited-library permission, and PhotoKit's default burst handling
continue to determine eligibility. An abrupt kill before iPadOS flushes its latest
UserDefaults write can lose the most recent checkpoint; normal relaunch resumes
persisted progress.

Build and exact test results are recorded in the task's verification artifacts.
The source/build version remains 1.0.3 (65); this is a local unsigned development
candidate, not a newly published release. Device installation needs a signed build;
TestFlight/App Store distribution requires separate approval.

## Recorded results (October 10, 2026)

- Final native unit run: **248 tests passed**, zero failures, including 16 new
  shuffle/request-lifecycle regressions. Xcode 27.0 (27A266a), dedicated Canvas
  iPad simulator `C02D7BA6-FB18-4447-814B-571FF8AAD784`, iOS 26.5.
- Initial repository full gate: 243 unit tests passed at that point; UI: **14 passed,
  two failed, two opt-in tests skipped**. The two failures are
  `testOnboardingFirstScreen` and `testOnboardingSelectedAlbumContinuesAndCompletes`:
  Continue was missing because the app showed Home. Both reproduce on untouched
  baseline `87791f0` with the same device and toolchain. Investigation found stale
  Canvas preferences in the simulator's global preferences directory, outside the
  app sandbox. They survived the test reset and supplied completed-onboarding
  settings. Backing up/removing that external test residue made both tests pass.
  No assertions or product onboarding behavior were changed.
- A subsequent unit run initially failed the existing weather permission test
  because UI tests had denied location. Restoring only Canvas's simulator location
  permission to its initial undetermined state yielded a clean unit pass.
- Tooling gate: **19 tests passed** (eight local-check tests, 11 release-helper tests).
- Final unsigned iPad Release build: **BUILD SUCCEEDED**; bundle metadata is
  1.0.3 (65). Simulator Debug build also passed.
- Original repository working files remain unchanged, including the pre-existing
  `.gitignore` edit and untracked agent/tool directories. Development used an
  isolated local clone of that repository, not a replacement application.
- Real simulator process check with all 31 bundled photos: terminated after six
  displayed photos, relaunched without resetting settings, then observed eight
  displayed IDs. The original order and seen set survived; the resumed frame
  contained only previously unseen IDs. Before/after JSON checkpoints are saved
  with the task artifacts. This exercised the production configuration and image
  loader, in addition to the large synthetic unit scenarios.

- Clean full repository rerun: **246 unit tests, 16 UI tests, and 19 tooling
  tests passed**, with two opt-in UI tests skipped. After the final two boundary
  and completed-cycle restore refinements, all **248 unit tests** and the unsigned
  Release build were rerun successfully. No UI assertions were changed.

Reproduce the repository gate with:

```sh
python3 scripts/check-local.py --all --simulator-id C02D7BA6-FB18-4447-814B-571FF8AAD784
```

The existing weather permission test assumes undetermined location permission;
UI tests may deny it. Reset only Canvas's permission on the dedicated simulator
before starting the unit suite if needed. Do not reset a physical iPad.
- Final simulator preferences were restored byte-for-value from the pre-UI-test
  backup, and Canvas's location permission returned to undetermined. The final
  app launch and screenshot were verified on the dedicated Canvas device.
- Interactive mirror is running at http://localhost:3202. Codex queued its browser
  tab for this task. In-app browser automation is unavailable in this delegated
  environment, so browser-stream pixels could not be independently verified;
  the native simulator screenshot and health checks passed.
