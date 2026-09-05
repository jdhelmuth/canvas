# Release runbook

Canvas releases are gated by `release/release-requirements.json`, the scripts in `scripts/`, and Xcode Cloud's `ci_scripts/`.

## One-time Xcode Cloud setup

- Use the shared `Canvas` scheme and its Release Archive action.
- Select Xcode 26.6 or a newer stable release and a compatible stable macOS image. Do not use beta or RC images for distribution.
- Keep automatic signing enabled and verify that the `com.johnhelmuth.canvas` App ID has WeatherKit configured in both **App Capabilities** and **App Services**.
- Add `ASC_APP_ID` as the numeric App Store Connect app ID.
- Add `ASC_ISSUER_ID`, `ASC_KEY_ID`, and `ASC_PRIVATE_KEY` as secret environment variables. The private key is the complete contents of the App Store Connect API `.p8` key.
- Grant the API key only the App Manager access needed to read build metadata.
- Set Xcode Cloud's **Next Build Number** higher than the latest uploaded build. The archive gate independently queries App Store Connect and blocks collisions.
- The gates use Python 3 standard-library JSON/HTTP handling plus tools in the Xcode image; they do not install Homebrew packages and do not require `jq`.

Apple's upload baseline is currently Xcode 26 and the iOS 26 SDK. Check [Apple's Upcoming Requirements](https://developer.apple.com/news/upcoming-requirements/) before every release in case the baseline has changed.

## Release procedure

1. Update `MARKETING_VERSION` in `project.yml` when starting a new App Store version, then run `xcodegen generate` and commit the regenerated project.
2. Run `scripts/validate_release_requirements.sh` on a Mac with the intended release Xcode selected.
3. Export the App Store Connect variables listed above and run `scripts/app_store_build_preflight.sh [candidate-build-number]`. It checks every uploaded build for the same iOS marketing version and fails unless the candidate is strictly greater.
4. In Xcode Cloud, set **Next Build Number** to at least the value reported by the preflight. Run the Archive workflow.
5. Confirm the post-build archive verification passes, including bundle/version metadata and the privacy manifest.
6. Distribute to an internal TestFlight group and complete the smoke test below before external testing or App Review.
7. Record the release commit, Xcode version, SDK version, marketing/build version, release notes, and smoke-test result in the release or PR.

If App Store Connect cannot be queried, do not guess or upload. Restore the credentials or verify the latest build directly in App Store Connect, then rerun the gate.

## TestFlight smoke test

Test both a fresh install and an upgrade from the previous public build on a supported iPad.

- Complete onboarding with Full Photos access, then repeat with Limited Photos access.
- Select regular/smart/shared albums; start, pause, resume, swipe, shuffle, and rotate the slideshow.
- Favorite and unfavorite a photo and confirm only the explicit favorite state changes in Photos.
- Exercise a video, Live Photo, and an iCloud-backed item.
- Import a small Google Picker selection, confirm local playback, and with Full Access confirm a verified Canvas-owned Apple Photos album copy. Limited Access must leave that Apple copy pending.
- Verify settings, weekday schedules, local audio, Apple Weather or Ambient station overlays, AQI opt-in, denied-permission states, and offline behavior.
- Confirm version/build in Settings or TestFlight matches the archived version/build.
- Review the App Privacy answers, privacy policy, support link, export-compliance answer, screenshots, and release notes.

## Release notes template

```text
Canvas Slideshow <version> (<build>)

What's new
- <user-visible improvement>

Fixed
- <user-visible fix>

Known limitations
- <only actionable, material limitations>

Verified
- Fresh install: <device / iPadOS>
- Upgrade: <from version / device / iPadOS>
- TestFlight smoke test: <pass / date / tester>
```

## Rollback

An App Store binary cannot be replaced with a lower build number. For a TestFlight problem, stop distribution and expire or remove the affected build from tester groups. For a released problem, pause a phased release if available, restore the last known-good source commit, apply only required compatibility fixes, assign a new higher marketing/build version, rerun every gate, and submit the replacement. Never roll back user data formats unless backward compatibility has been explicitly tested.

## One distribution build per public release

Use a single VALID, APP_STORE_ELIGIBLE build from **Manual Public Release**
(`D16A6CAA-A322-4221-9514-9176789B9154`) for both internal TestFlight and App Review.
Assign that exact build to the existing internal group (`e4cea94c-30af-456c-94df-862210490408`),
verify the group assignment, and select the same build for submission.
Submission is an App Store Connect action on an existing build, not a reason
to start another archive or increment the build number.

The **Default** workflow stays automatic for ordinary development merges and
produces INTERNAL_ONLY builds. Those cannot be submitted to App Review. Start
one public archive when a release needs a new eligible binary; reuse an existing
eligible build when it already contains the exact release code.

For an already-built release, integrate the exact, clean PR head with:

```sh
python3 scripts/check-local.py --merge-pr NUMBER --skip-cloud-build
```

This runs local checks, verifies the PR head and base have not moved, and adds
`[ci skip]` to the actual squash commit. A marker only on a feature-branch
commit does not survive an unmarked squash merge. For an authorized direct
push, end the final main commit message with `[ci skip]` after validation.
Preserve any existing website deployment marker separately.

Reserve the next live build number once before the public archive, and keep
that number when integrating already-built code. Do not create a newer internal
build merely to submit, merge, update release notes, or close out a release.
Do not toggle Default off and on around releases; use the commit marker.
Do not remove newer TestFlight builds that contain intentional development work.

After integration, read back Xcode Cloud runs to confirm the marked commit did
not start another build, and verify the submitted build ID matches the release
build assigned to TestFlight. Existing App Review submissions remain unchanged
unless the user explicitly requests a replacement.

Apple documents the skip directive in [Get the most out of Xcode Cloud](https://developer.apple.com/videos/play/wwdc2022/110374/).
