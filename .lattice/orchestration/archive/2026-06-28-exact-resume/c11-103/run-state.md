# Run state — C11-103 (state-dir migration merge)

**Started:** 2026-05-18
**Architect:** condensed into prior conversation (this orchestrator's earlier turns with the operator)
**Orchestrator:** agent:claude-opus-4-7 (this session, surface:7 "C11-103 Orch")
**Operator:** atin

## Configuration

| Setting | Value |
|---|---|
| Autonomy level | **Moderate** (default; operator engaged in this chat) |
| Concurrent delegator cap (N) | 1 (single-ticket run) |
| Master Validator | off (one delegator, one file, not worth the audit overhead) |
| Result Validator | off (the delegator's own code-review phase is the audit; second pass would be ceremony) |
| Ticket fidelity | already-Verbose (C11-103 description carries full SPEC + BUILDPLAN) |
| C11 detection | yes (`C11_SHELL_INTEGRATION=1`) |

## SPEC + BUILDPLAN sources

Phase 1 collapsed — the artifacts already exist:

- **SPEC** (the WHAT): Lattice ticket **C11-103** description (`lattice show C11-103`). Captures symptom, root cause, blast radius, fix shape, manual recovery path for the operator, test policy, and references.
- **BUILDPLAN** (the HOW): the "Option 2: per-file merge" approach scoped in the operator↔orchestrator conversation that produced the ticket. Recapped under `## Implementation plan` below so the delegator does not need to recover it.

## Lattice ticket

**C11-103** (`task_01KRYDY22SEHBN4YKVZKTVWSTQ`) — type=bug, priority=high, complexity=medium, tags=`persistence,migration,session-resume`.

## Implementation plan (for the delegator)

**File:** `Sources/Mailbox/MailboxLayout.swift`, `StateDirectoryMigration` (lines 180–221).

**Current shape:**
```swift
guard legacyExists, !currentExists else { return }
try fileManager.moveItem(at: legacyURL, to: currentURL)
try fileManager.createSymbolicLink(atPath: legacyURL.path, withDestinationPath: currentName)
```

The `else { return }` branch is the bug: when both `~/Library/Application Support/c11mux/` and `~/Library/Application Support/c11/` exist, the migration is a no-op and per-bundle-id session files orphan in the legacy dir.

**New shape:** replace the dir-level guard with a **per-entry merge**. Pseudocode:

```
if legacyURL does not exist: return                  // truly fresh install
ensure currentURL exists (createDirectory withIntermediates: true)
for each entry in shallow walk of legacyURL:
    if entry name == "workspaces" AND currentURL/workspaces exists:
        for each subdir in legacyURL/workspaces:
            if not present in currentURL/workspaces: moveItem
    else if entry not present in currentURL:
        moveItem(legacyURL/entry → currentURL/entry)
    else:
        leave alone (current wins on name collision; it's newer)
if legacyURL is now empty:
    removeItem(legacyURL)
    createSymbolicLink(atPath: legacyURL, withDestinationPath: currentName)  // preserves downgrade path
```

**Conflict policy:** on same-name collision (both dirs have `session-com.stage11.c11.json`, or both have `workspaces/<uuid>/`), keep the one in `c11/`. It was written by the post-rename build and is newer. Do NOT merge file contents.

**Atomicity:** `FileManager.moveItem` is atomic on the same volume. Both paths are under `~/Library/Application Support/`, same volume. Use best-effort error handling per entry — one `moveItem` failure should log + continue, not abort the whole merge.

**Concurrency:** the existing `didRun` guard prevents double-execution per process. No new concurrency work needed.

**Symlink:** only re-create the legacy→current symlink if the legacy dir is empty after merge (matches the existing "moved cleanly" branch's intent of preserving the downgrade window).

## Validation plan

See `validation-plan.md` (sibling file).

## Workspace panes (c11 refs — singleton-tab layout, no new panes)

- orchestrator: workspace:3 / pane:6 / surface:7 (this surface, "C11-103 Orch")
- delegate_view_area: pane:7 (already hosts C11-99 D1 ABD on surface:9; C11-103 delegator joins as a new tab)
- control_surface: none (single-ticket run; operator reads Lattice status directly. No browser pane spawned for the dashboard.)

## Decision log (append-only)

- 2026-05-18 — Architect + Phase 1/2 collapsed into operator↔orchestrator conversation that produced ticket C11-103. Approach (Option 2: per-file merge with `workspaces/<uuid>/` one-level recursion) agreed before this run-state was written.
- 2026-05-18 — Configured Moderate autonomy / N=1 / Master Validator off / Result Validator off. Rationale: single-file fix; the delegator's code-review phase is sufficient audit.
- 2026-05-18 — Delegator worktree: `code/c11-worktrees/c11-103-state-dir-merge` on branch `fix/c11-103-state-dir-merge`, anchored to `origin/main` @ `7cbc27d313`.
