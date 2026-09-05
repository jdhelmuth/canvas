# Local checks and release integration

Run `git fetch origin main` and `python3 scripts/check-local.py --base origin/main`
before pushing changes. Install locked dependencies and required toolchains when
needed; never skip failed checks. Native checks require the existing project setup. Use `--plan` to inspect check selection.

For an exact, clean PR head, run `python3 scripts/check-local.py --merge-pr NUMBER`.
For integration of an already-built public release, add `--skip-cloud-build`.
It keeps local checks and exact head/base guards, and marks the actual squash
commit so Xcode Cloud does not create another build. For direct release pushes,
the final main commit must end with `[ci skip]` after local checks pass.

Use one App Store-eligible build for both TestFlight and App Review. Do not
increment the build number or trigger an internal build solely to submit,
merge already-built code, update release notes, or record release evidence.
Normal development merges continue to build automatically. See the release
runbook for the existing distribution and verification requirements.
