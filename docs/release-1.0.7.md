# Canvas Slideshow 1.0.7 (71)

Refresh successfully verified Photos cloud identities while local albums remain readable, preserving the last known identity on failures. Reconcile older preset metadata only with current local-object proof. Recover prior local identifiers only when a fresh cloud mapping verifies identity; never substitute an album by title. Continue foreground recovery at capped intervals beyond startup, pause in the background and refresh on return. Existing unavailable selections and shuffle progress stay saved.

The screenshot incident was reproduced on the existing iPad: one original selection was unresolved under Full Access; its later reconnected selection was readable. User confirms the Apple album was unchanged and reconnecting was a workaround after the error. The exact historical PhotoKit mapping event was not captured; duplicate records are not asserted to have caused the original failure. No deletion/recreation or external outage is established. No removal-only workaround is included.

Aggregate checks also reproduced an X-button hit-region failure on the current QA iPad runtime. The button now has an explicit 44-point hit shape and presenter-owned dismissal; focused verification reaches Home and edits settings. Weather tests now inject their permission fixture and wait for real navigation readiness, without changing production weather behavior.

Required checks: complete native/tooling suite on the exact final numbered source, simulator health through teardown, signed development build for upgrade validation, and existing release requirements/live number preflight. Distribution uses one Manual Public Release App Store-eligible build for TestFlight and App Review, with automatic release after approval. Preserve inherited screenshots and metadata except accurate release notes.

Limits: real identifier changes between observations, external iCloud outages, cross-device restore and a complete hours-long physical shuffle cycle cannot be guaranteed or exhaustively induced. Readable-but-empty PhotoKit results retain their existing membership semantics; this update does not fabricate asset membership or silently discard selections.
