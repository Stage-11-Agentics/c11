# C11-103: State-dir migration leaves user on empty session when both c11/ and c11mux/ exist

## Symptom

After updating c11 to a release that includes PR #164 (ad3e8dd83, "Drop c11mux from active code paths"), Atin launched the updated prod build and got an empty workspace state. All previous workspaces (C11 improvements, gregorovitch, claude monitor, Mission and Refinement, Lattice, soundbot) vanished from the UI. Happened 2026-05-18 ~16:46.

## Root cause

`StateDirectoryMigration.ensureMigrated` in `Sources/Mailbox/MailboxLayout.swift:187-220` only performs the dir rename when the legacy path exists AND the new path does NOT:

```swift
let legacyExists = fileManager.fileExists(atPath: legacyURL.path)
let currentExists = fileManager.fileExists(atPath: currentURL.path)
guard legacyExists, !currentExists else { return }
```

The "co-existing (both exist, leave alone)" branch is the problem for anyone who has been running tagged debug builds (./scripts/reload.sh --tag <tag>) on the same machine. Those builds use the new state-dir code paths and pre-create ~/Library/Application Support/c11/ for their own session-com.stage11.c11.debug.<tag>.json files. By the time the prod release with the rename lands, the new dir already exists, the migration bails, and the prod build (bundle id com.stage11.c11) cannot find its session file, so it writes a fresh empty one and stomps the previous run's autosave path.

Atin's machine, 2026-05-18:

- ~/Library/Application Support/c11mux/session-com.stage11.c11.json: 22 KB, 6 workspaces (legacy, the real state)
- ~/Library/Application Support/c11/session-com.stage11.c11.json: 7 KB, fresh empty state from the post-update launch
- ~/Library/Application Support/c11/ had session-com.stage11.c11.debug.*.json going back to May 15 from tagged builds, which is what kept the migration from running

## Blast radius

Affects anyone who ran a c11 build using the new state-dir code (any tagged debug build, anyone on internal dogfooding builds) before the prod release with the migration landed. End users who never ran a debug build would have gotten a clean rename.

## Fix shape (sketch, let planning settle this)

The dir-level guard is too conservative. Options:

1. Per-file fallback. If the new dir exists but the bundle-id-specific session file is absent there, copy it from the legacy dir before first read. Same for the workspaces/<uuid>/ subdirs referenced by that snapshot.
2. Move-on-first-load. Have SessionPersistenceStore.load consult the legacy path when the new path returns nil, and migrate at that point.
3. Merge dirs. When both exist, walk the legacy dir and move any files not present in the new dir over.

(1) is probably cleanest: targeted, keyed on the actual artifact that matters, idempotent. (3) risks accidentally migrating stale debug-build state. Whatever shape lands, also migrate the workspaces/<uuid>/ directories referenced by the snapshot, not just the JSON.

## Recovery for Atin (NOT done, operator declined for now)

Operator chose to leave state untouched and file this ticket. Manual restore path when he is ready:

1. Quit c11.
2. cp ~/Library/Application\ Support/c11mux/session-com.stage11.c11.json ~/Library/Application\ Support/c11/session-com.stage11.c11.json
3. Move/copy the workspaces/<uuid>/ subdirs referenced by that snapshot from c11mux/workspaces/ to c11/workspaces/.
4. Relaunch c11.

## Test policy

Per c11 testing policy: don't add tests that grep source code for migration logic. Add a unit test in c11LogicTests against StateDirectoryMigration (or the per-file fallback) that builds the dual-dir state in a temp dir, runs the migration, and asserts the session file ends up readable from the new path. No host app needed for that.

## References

- Sources/Mailbox/MailboxLayout.swift:180-221 (the migration)
- Sources/SessionPersistence.swift:538-562 (defaultSnapshotFileURL, the consumer that lands on the empty file)
- ad3e8dd83 (feat(state-dir): migrate ~/Library/Application Support/c11mux to c11)
- 7e0e0b282 (Drop c11mux from active code paths: state-dir migration, theme rename, test fixes, PR #164)
