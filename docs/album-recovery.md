# Selected album recovery

Canvas stores a Photos cloud identifier when a selected Apple album resolves
under Full Access. It keeps the current local identifier for normal lookups and
records explicit repairs locally so an old preset can recover after relaunch.
No photo or album membership is changed by this process.

The same resolution snapshot supplies warnings and playback. A selected
collection omitted by catalog enumeration is checked directly. A stale local
identifier can recover through a successful, unique cloud mapping to a compatible
collection. Names alone never substitute an album; ambiguous or failed mappings
remain unavailable. Limited access permits only currently accessible direct
lookups, not cloud recovery or explicit reconnect. Revoked access clears the
readable snapshot and refreshes playback.

Unavailable references stay saved. The picker displays them and retains them on
Done unless explicitly unchecked. Reconnect requires choosing a replacement
album; it does not modify Photos. A first local settings backup precedes automatic
identity migration. Unreadable recovery history is preserved rather than replaced.

Catalog refreshes retry unresolved references after 1, 3 and 8 seconds, then wait
for a Photos change, foreground refresh or Retry Photos. There is no unlimited
polling. An unavailable album is not an exhausted shuffle cycle: accessible photos
can finish once, but the durable seen set is retained while Canvas waits. Returning
assets enter the same cycle; no repeat begins solely because the library shrank.

## Validation

- `AlbumRecoveryTests`: cloud identity migration, successive ID changes, failed
  and ambiguous mappings, collection/source mismatch, permissions, old presets,
  restart, partial catalogs, picker drafts and settings backup.
- `FullShuffleTests`: 1,307 unique photos with overlapping inputs, load failures,
  timer edits, suspension/relaunch, cycle boundaries and an unavailable album that
  returns after the accessible subset was exhausted and the process restarted.
- `testUnavailableAlbumSurvivesDoneRestartAndExplicitRemoval`: repeated picker
  Done/relaunch, Retry Photos, explicit removal and persistence after relaunch.
- Run `python3 scripts/check-local.py --all --simulator-id <Canvas simulator>` for
  all native/tooling checks and simulator health observation through teardown.

The Debug-only `--canvas-album-diagnostics` launch option writes a local,
metadata-only report in the app's Documents directory. It reports fresh read/write
Photos authorization, direct collection lookups, filtered counts, durable identity
coverage and the warning state. Reports contain private identifiers; keep them
outside source control. It neither requests access nor writes to Photos. The
existing explicit repair flag rejects nonunique same-name/type mappings and
requires Full Access; it is a support operation, not automatic name matching.
