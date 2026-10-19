# Canvas Slideshow 1.0.6 (69)

Selected Apple Photos albums now retain recoverable cloud identities and identifier history. If Photos changes a local album identifier, Canvas can reconnect a uniquely identified album while preserving slideshow progress. Temporarily unavailable albums stay selected, with accurate status and explicit retry, reconnect, and removal controls.

Shuffle progress remains intact while albums are unavailable. Playback waits at the end of the available photos instead of starting repeats before the missing albums return. A nonrepeating slideshow resumes unseen photos when an album becomes available again.

Validation before release numbering: 276 unit tests, 19 UI tests passed with 3 opt-in capture tests skipped, and 30 tooling tests passed on the dedicated Canvas iPad simulator. Coverage includes a 1,307-asset partial-library cycle, restart, overlapping albums, recovery, settings migration, and selection persistence. The final numbered source must pass the complete repository checks before upload.

A development-signed upgrade was installed on an iPad Pro 11-inch (3rd generation), iPadOS 27.2 beta. All selected albums resolved; the unique eligible queue and prior progress survived timer advancement and process restart. Unrelated settings and protected document files were verified unchanged. Private device evidence stays local.

Limits: a complete hours-long physical cycle, a future real PhotoKit identifier change, cross-device restore, an induced iCloud outage, and a fresh-install/TestFlight smoke matrix were not exercised. No direct physical screen capture was available. Automated tests cover the corresponding state transitions where practical.

Distribution: one App Store-eligible Manual Public Release build for internal TestFlight and App Review. Preserve automatic release after approval. Version 1.0.5 (68) was already live at release preparation; no pending submission requires withdrawal.
