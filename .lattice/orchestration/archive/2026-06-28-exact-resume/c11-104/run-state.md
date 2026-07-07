# Run state — C11-104 (sidebar worktree+branch chips) — **v2 (post-trident-review)**

**Started:** 2026-05-18
**v2 issued:** 2026-05-19 — after the trident plan-review returned `revise-then-proceed`. v1 plan superseded; this file is the source of truth.
**Architect:** agent:claude-opus-4-7 (this session, surface:15 — currently wearing the Architect hat again after the trident pass)
**Operator:** atin

## Configuration (unchanged from v1)

| Setting | Value |
|---|---|
| Autonomy level | **Fully Autonomous** |
| Concurrent delegator cap (N) | 1 |
| Master Validator | off |
| Result Validator | **on** (Phase 4) |
| Closeout audit | on |
| Ticket fidelity | Verbose (Refined SPEC + decisions inside C11-104 description) |
| C11 detection | yes (`CMUX_SHELL_INTEGRATION=1`) |

## What changed from v1

The trident plan-review identified six blocker-level gaps (B1–B6) and surfaced ten operator-call items (S1–S10) + three evolutionary signals (E1–E3). Operator decisions on the operator-call items:

| Item | v1 implicit | v2 decided |
|---|---|---|
| **S2** integration map | Greenfield: build a parallel git pipeline | **Replace** the existing `verticalBranchDirectoryLines()` row; extend `TabManager`'s probe to populate richer state; preserve `@AppStorage("sidebarShowBranchDirectory")` key with renamed UI label |
| **S1** C+D bundle | Bundle | Stay bundled |
| **S3** palette | Delegator's call | Muted/desaturated 10-color palette aligned with c11 theme accents; ThemeKey-backed per Light/Dark slot |
| **S4** agent-readable | Unspecified | **Yes** via `c11 get-metadata --key worktree`/`--key branch`; writes with `source=derived` rejected |
| **B5** derived lifecycle | Unspecified | Internal-only writes; excluded from snapshots; resolver clears its own values when not-in-repo |
| **E1** reframe | Two chips | **Yes**: introduce `MetadataDeriver` protocol + `DerivationCoordinator` + `GitContext` value type. `GitContextDeriver` is the first implementation |

And the empirical findings:

- **S8 (OSC 7 in agent panes):** c11 doesn't use OSC 7 at all. The trigger is `report_pwd` over c11's socket, fired by zsh/bash `precmd` hooks. Inside agent panes precmd doesn't fire → `report_pwd` doesn't fire → `panelDirectories` is frozen at the agent's spawn cwd. **For the primary use case (agent spawned in a worktree, stays there) this is fine** — the initial probe fires on workspace setup with the spawn cwd, which is the worktree. The chip renders correctly at agent startup. Stale-on-internal-`cd` is a known limitation, documented, deferred.

## Existing infrastructure to extend (B1 integration map)

Surveyed 2026-05-19. Confirmed file:line:

| Piece | Location | Role |
|---|---|---|
| `Workspace.panelGitBranches: [UUID: SidebarGitBranchState]` | `Sources/Workspace.swift:5297` | Per-surface branch + isDirty |
| `Workspace.panelDirectories: [UUID: String]` | `Sources/Workspace.swift:5274` | Per-surface cwd |
| `SidebarGitBranchState` (branch + isDirty) | `Sources/Workspace.swift:4703-4706` | Value type — v2 extends this |
| `SidebarBranchOrdering.BranchDirectoryEntry` | `Sources/Workspace.swift:4833-4843` | Existing dedup row record |
| `Workspace.orderedUniqueBranchDirectoryEntries()` | `Sources/Workspace.swift:4984-5089` | Existing dedup + ordering — v2 supersedes |
| `Workspace.sidebarBranchDirectoryEntriesInDisplayOrder()` | `Sources/Workspace.swift:7176-7189` | Display-order public API — v2 supersedes |
| `TabManager.initialWorkspaceGitProbeDelays` | `Sources/TabManager.swift:858` | `[0, 0.5, 1.5, 3.0, 6.0, 10.0]` retry schedule |
| `TabManager.scheduleInitialWorkspaceGitMetadataRefresh()` | `Sources/TabManager.swift:1509-1521` | v2 extends to populate richer state |
| `TabManager.applyWorkspaceGitMetadataSnapshot()` | `Sources/TabManager.swift:1589-1641` | Result-handler with gen-token + expected-cwd guards (B4 pattern source) |
| `TabManager.initialWorkspaceGitMetadataSnapshot()` | `Sources/TabManager.swift:1694-1710` | The actual git work — runs `branch --show-current` + `status --porcelain` + `gh pr view` |
| `TabManager.initialWorkspaceGitProbeQueue` | `Sources/TabManager.swift:1008` | `userInitiated` off-main queue |
| `TabManager.updateSurfaceDirectory()` | `Sources/TabManager.swift:2337-2350` | Cwd-update entry (triggered by `report_pwd`) |
| `TerminalController.reportPwd()` | `Sources/TerminalController.swift:18136-18195` | Socket handler — receives shell `report_pwd` |
| `cmux-zsh-integration.zsh` / `cmux-bash-integration.bash` | `Resources/shell-integration/` | Shell-side `report_pwd` emission on precmd / chpwd |
| `verticalBranchDirectoryLines()` | `Sources/ContentView.swift:12364-12390` | Current sidebar render — v2 **replaces** with chip render |
| `@AppStorage("sidebarShowBranchDirectory")` | `Sources/c11App.swift:4435` | Default true — v2 preserves key, renames UI label |
| Settings UI label "Show Branch + Directory in Sidebar" | `Sources/c11App.swift:5405-5408` | v2 updates copy to reflect chip rendering |
| `AgentChip` / `AgentChipBadge` | `Sources/AgentChip.swift`, `Sources/AgentChipBadge.swift` | Existing chip primitives — v2 extends |

The delegator does NOT build a parallel pipeline. The delegator extends the existing one.

## Implementation plan v2 (for the delegator)

### Scope — three load-bearing changes

1. **New derivation seam.** Introduce a tiny abstraction in c11's metadata layer:
   - `protocol MetadataDeriver` — uniform interface (input: surface + cwd; output: derived KV updates).
   - `DerivationCoordinator` — runs derivers off-main, applies results via the existing generation-token + expected-cwd guard pattern from `TabManager`, holds a per-(surface, derivedKey) cache keyed against `(cwd, resolvedHeadMtime)`.
   - `GitContext` value type — `{ worktreeRoot: URL?, worktreeKind: .main|.linked|.bare|.notInRepo, branch: BranchState (named|detached|noBranch), submodule: SubmoduleContext?, colorSeed: String? }`.
   - `GitContextDeriver: MetadataDeriver` — the first concrete deriver. Wraps the work currently done in `TabManager.initialWorkspaceGitMetadataSnapshot()` plus the new linked-worktree + submodule detection. Returns a `GitContext`.

   The existing `TabManager.scheduleInitialWorkspaceGitMetadataRefresh` is rewired to call `DerivationCoordinator.runDerivers(for: surface, derivers: [GitContextDeriver])`. The legacy fields `panelGitBranches[surfaceId].branch/isDirty` become projections of `GitContext`, written by the coordinator.

   **Why this and not "just add a worktree property":** the trident pack's evolutionary reviewers converged on this: the cost of designing the seam now is hours; the cost of retrofitting it after the next deriver (host / SSH target, container, kubectl context, AWS profile) ships is real. Operator approved (E1 yes).

2. **Sidebar chip render replaces the existing text-line render.** `verticalBranchDirectoryLines()` is retired. The new render produces:

   | Scenario | Chip layout |
   |---|---|
   | Not in git | nothing |
   | Main checkout, `main`/`master`/`trunk` | one chip: `branch: main` (dimmed via ThemeKey-backed opacity) |
   | Main checkout, feature branch | one chip: `branch: feature/foo` |
   | Linked worktree, any branch | two chips on one row: `● worktree: <basename>` + `branch: <name>` (`●` = colored dot, color from `colorSeed` hash) |
   | Detached HEAD | branch chip text is `(detached @ <short-sha>)` |
   | Worktree pointing at a deleted branch | branch chip text is `(no branch)`; resolver returns defined `.noBranch` state |
   | Submodule (cwd inside `<superproject>/<sub>/...`) | Row 1: outer worktree + branch chips per above. Row 2 (indented or `↳`-prefixed): `submodule: <name>` + `branch: <name-or-detached>` |
   | Dirty state | Branch chip suffix `*` (preserves existing `panelGitBranches[.].isDirty` signal — the trident pack flagged regression risk M4) |
   | Bare clone, cwd doesn't exist, resolver timeout | nothing |

3. **Existing toggle UI relabel + scope.** `@AppStorage("sidebarShowBranchDirectory")` key preserved (existing user prefs survive). Settings UI label updated. Single master toggle; no split per chip/per color.

### Critical correctness items (B2–B6 fixes)

- **B2 cache key.** Cache invalidates against the **git-resolved HEAD path** (`git rev-parse --git-path HEAD`), not `<cwd>/.git/HEAD`. For linked worktrees the resolved HEAD is `<common-dir>/worktrees/<name>/HEAD`; for submodules `<sub>/.git` is a gitfile.
- **B3 submodule two-pass.** Detect via `--show-superproject-working-tree` (from inside cwd). If non-empty, run a separate full resolution against the superproject path for the outer row, and a separate resolution against original cwd for the inner row. Submodule display-name source: `.gitmodules` configured name → path-from-superproject-root → basename.
- **B4 stale-async.** Reuse `TabManager`'s gen-token + expected-cwd pattern. The `DerivationCoordinator` tags every deriver invocation with `(surfaceId, generation, expectedCwd)`. Before apply: surface still exists + generation matches + cwd unchanged. Otherwise drop result.
- **B5 derived policy.** (a) Socket writes with `source=derived` rejected with `invalid_source` from the socket protocol handler. (b) Snapshot capture excludes keys whose source is `derived` — restore re-derives. (c) Resolver issues an explicit clear (`derivedCoordinator.clear(surface:, keys: [.worktree, .branch])`) when the deriver returns `.notInRepo` or `.cwdMissing`.
- **B6 file paths.** Tests in `c11Tests/` directory with `c11LogicTests` target membership (the project convention). Resolver + coordinator code in a new file under `Sources/Metadata/` (delegator confirms exact location during plan phase; if `Sources/Metadata/` doesn't exist yet, follow existing convention and put it under `Sources/` flat). Chip render extends `Sources/AgentChip.swift` + `Sources/ContentView.swift` in place. Settings UI string in `Sources/c11App.swift:5405-5408`.

### Important items folded in (I1–I7 fixes)

- **I1 localization.** Every new user-facing string uses `String(localized: "key.name", defaultValue: "English")` against `Resources/Localizable.xcstrings`. After English is final, the delegator spawns a translator sub-agent in a fresh c11 surface to sync ja/uk/ko/zh-Hans/zh-Hant/ru.
- **I2 hot-path runtime check.** Add `dispatchPrecondition(condition: .notOnQueue(.main))` at the entry to `GitContextDeriver.derive()` and `DerivationCoordinator.runDerivers()` so a main-thread invocation crashes at runtime. Logic test in `c11Tests` (logic target) invokes from main → assertion fires.
- **I3 git-subprocess timeout.** Each `git` invocation runs with a 2s wall-clock timeout. On timeout: terminate the subprocess, return defined `.timeout` state, chip clears.
- **I4 workspace multi-surface render policy.** Sidebar chip row reflects: per-surface state, deduped across surfaces that share the same `(worktreeRoot, branch)`. Existing `orderedUniqueBranchDirectoryEntries()` dedup logic is the model — extend, don't fork.
- **I5 restore-window.** On workspace restore, walk all restored surfaces' last-known `currentDirectory`/`gitBranch` (from snapshot) and **paint the existing snapshot values as the chip's initial render** while the fresh deriver runs in the background. The deriver overwrites once results land. Avoids the "30-surface chips paint one-by-one over 2s" failure mode.
- **I6 stale-worktree.** Deriver detects "cwd no longer exists" or "resolved gitdir/HEAD missing" and returns defined `.stale` state. Chip clears (no strikethrough — keep it simple).
- **I7 branch-length.** No resolver-side length limit. View layer truncates with middle-ellipsis if chip display-width exceeded. Full branch name accessible via `c11 get-metadata --key branch` (S4) and chip tooltip.

### Mechanical items (M1–M6)

- **M1**: AC4 uses two specific known-distinct worktree paths chosen so the chosen hash maps to different palette indices. Test fixtures pin the inputs and the expected color indices.
- **M2**: Hot-path audit extends to `Sources/ContentView.swift` for `TabItemView`'s body. Any new field read by `TabItemView.body` flows through precomputed `let` parameters OR is added to the `==` Equatable function. `.equatable()` modifier preserved.
- **M3**: Drop the "30s coarse interval" cache invalidation entirely. Cache invalidates on cwd change OR resolved-HEAD mtime change OR explicit `c11 metadata refresh` socket command (delegator may add as a debugging affordance).
- **M4**: Dirty marker preserved as branch-chip suffix `*` (matches existing UX). PR-pill from `gh pr view` continues to render alongside the chips as it does today — the chip render replaces the text branch+dir line, not the PR pill.
- **M5**: Color hash input = `git rev-parse --show-toplevel` (symlinks resolved real path). Test fixtures use the git-resolved form.
- **M6**: Dimming = ThemeKey-backed opacity. Add `ThemeKey` entries `chipTextDimmedOpacityLight = 0.65` and `chipTextDimmedOpacityDark = 0.55`. Theme JSON can override.

### Evolutionary clear win (EW1)

`worktreeColor: Color?` is stored on `GitContext` (and thereby flows into `panelGitBranches`'s replacement state), not computed inside the chip view. Future consumers (Option E sidebar grouping, command-palette jump-to-worktree, etc.) read the same value.

## Validation plan

See `validation-plan.md` (v2, sibling file).

## Workspace panes (c11 refs) — unchanged from v1

- Architect+Orchestrator (this surface): window:1 / workspace:3 / pane:9 / surface:15 "C11-104 Orch" (wears Architect hat again during v2 revision; promotes back to Orch when v2 is shipped to the delegator).
- delegate_view_area: pane:7. Existing surface:16 (v1 delegator) is currently idle / blocked at the trident-review return.
- control_surface: none.

## Decision log (append-only)

- 2026-05-18 — v1 Architect ran 4-round Planning Interview. Decisions captured in v1 Refined SPEC.
- 2026-05-18 — v1 Phase 2 artifacts written; ticket transitioned backlog → planned; v1 delegator spawned on surface:16.
- 2026-05-18 — v1 delegator booted, ran plan phase, fired `lattice plan-review`.
- 2026-05-19 02:48 UTC — Trident plan-review returned `revise-then-proceed`. Status auto-moved to `needs_human`. Six blockers + ten operator-call items.
- 2026-05-19 — Architect (this session) ran v2 revision. Empirical survey confirmed: (a) c11 uses `report_pwd` socket, not OSC 7 — primary use case works via initial probe; (b) existing infrastructure to extend, not replace, mapped at file:line precision above.
- 2026-05-19 — Operator decisions for v2 captured: **replace** existing branch+directory row; **muted desaturated palette** with ThemeKey backing; derived chips **readable** via socket, not writable; **exclude from snapshots** + **resolver clears on not-in-repo**; **E1 reframe yes** (MetadataDeriver protocol + DerivationCoordinator); **S1 bundle stays**.
- 2026-05-19 — v2 plan: extend `TabManager` probe via `DerivationCoordinator` + `GitContextDeriver`; replace `verticalBranchDirectoryLines()` with chip render; preserve `@AppStorage("sidebarShowBranchDirectory")` key; rename UI label.
- Pending: kill v1 delegator surface:16 and re-spawn with v2 boot prompt; transition ticket `needs_human → planned`.
