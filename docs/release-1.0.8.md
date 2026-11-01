# Canvas Slideshow 1.0.8 (73)

Universal iPhone and iPad support. The app target is `TARGETED_DEVICE_FAMILY` 1,2. Compact-width Home, onboarding, slideshow chrome, and overlay bounds use size-class and viewport metrics rather than iPad-only safe-area assumptions. iPhone orientations are portrait plus landscape; iPad still allows upside-down. Launch screen generation is unchanged.

**Build number:** 73 is the next integer after App Store Connect’s verified live 1.0.7 (72) and previously uploaded 71. **Re-check App Store Connect before any upload.** Uploaded-but-unused builds still occupy the number.

This PR does not archive, upload, or submit. iPhone 6.9" App Store screenshots are not generated in this repository (no fastlane snapshot lane). Capture them on an iPhone 16 Pro Max / 6.9" simulator before submission.

Required checks: iPhone and iPad simulator builds, existing tests on a Mac with Xcode, ASC live build preflight, and one App Store-eligible binary for TestFlight and App Review.
