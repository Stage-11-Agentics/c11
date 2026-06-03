# C11-107: C11-104 follow-up: restore-warmpath snapshot pre-paint for sidebar chips

Deferred from C11-104 (PR #181) as v2 deferral item I5, and from C11-106 plan-review M5.

## Problem

On workspace restore from a snapshot, c11 re-paints surfaces with their last known title, cwd, metadata, etc. But for the worktree + branch sidebar chips that landed in PR #181, `panelGitContexts` starts empty on restore — the chips are blank until the next probe completes (typically fast, but visible).

The v2 SPEC's AC19 specified the warm-path behavior: snapshotted `gitBranch` (and the new worktree-derived metadata) should paint initially, then the deriver runs in the background and updates the chip if the value has changed.

## Scope

- Touches `Workspace.swift` snapshot capture/restore code paths and `WorkspacePlanCapture.swift`.
- Decide what to snapshot: only `gitBranch` (current state) or also the `worktree` derived metadata.
- Decide TTL / staleness policy: do we paint snapshotted values forever-stale, or skip paint if snapshot is > N hours old?
- Tests: restore from a snapshot containing `branch`/`worktree` derived metadata; assert chip paints before deriver completes; assert deriver result overwrites if changed.

## References

- C11-104 (parent): task_01KRYWXX6ECSCVRGFTYYA594HK
- PR #181: https://github.com/Stage-11-Agentics/c11/pull/181
- C11-104 validation report AC19 (FAIL): .lattice/orchestration/c11-104/validation-report.md
- C11-106 plan-review pack M5: .lattice/orchestration/c11-106/c11-106-plan-review-pack-2026-05-19T0935/synthesis-action.md

## Out of scope

- The general 'derived metadata snapshot exclusion' policy is already in place per AC18 (derived keys are filtered from snapshot capture). This ticket is about the *exception* for git context on restore.
- Anything that would change the user-visible non-restore behavior of the chips.
