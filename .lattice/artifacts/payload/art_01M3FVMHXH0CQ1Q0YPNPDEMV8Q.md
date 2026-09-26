Lattice-Reviewed-Commit: 6f5a38698fab7ab671f7077e5a9b4423a2b2ae4c
Lattice-Reviewed-Worktree: /Users/atin/Projects/Stage11/code/c11/c11-worktrees/c11-238-workspace-root
Lattice-Reviewed-Base: origin/main (0e37c3c8db5ced5c9f38b1525d04c37ff3aecaa6)
Lattice-Reviewed-Head: HEAD (6f5a38698fab7ab671f7077e5a9b4423a2b2ae4c)

Lattice-Reviewed-Commit: 6f5a38698fab7ab671f7077e5a9b4423a2b2ae4c
Lattice-Reviewed-Base: origin/main (0e37c3c8db5ced5c9f38b1525d04c37ff3aecaa6)

# Code Review: C11-238 (workspace root governs every new surface)

## 1. Verdict

**FAIL (implementation-level)**

The plan is sound and almost all of it is implemented well. One rail, `c11 launch-agent`, does not skip a missing root. Two docs written in this diff say it does, and when it happens the agent spawns in the app process's cwd. The fix is a few lines. Everything else can ship as is or be handled as follow-ups.

## 2. Summary

I reviewed the full diff (CLI, socket handlers, `Workspace`/`TabManager` creation primitives, session persistence, the new `WorkspaceRootEditor.swift`, localization, tests, docs, skills) against the plan and Amendment 1. I also read the surrounding source: `SocketDispatch` agent.launch, `terminalPanelForConfigInheritance`, `inheritedCwdForAgentLaunch`, the bonsplit split path, Ghostty's `Exec.zig` cwd handling, and session restore. The seam design is right: every `TerminalPanel(` construction in `Workspace.swift` goes through `newSurfaceWorkingDirectory`, so ~40 call sites are covered without touching them. Adoption, persistence and the GUI affordance all follow the Orchestrator's M3 ruling.

The main finding: the `launch-agent` rail still makes its own `resolve` call with the raw `rootDirectory`. The M2 missing-root skip therefore does not apply on the one rail whose reference doc now promises it.

Neither host test class (`WorkspaceRootDirectoryTests`) nor the build has run yet. There is no PR and no CI run, and I did not build locally, per repo policy for headless runs.

## 3. Issues

**[MAJOR] Sources/SocketHandlers/SocketDispatch.swift:1159 / :1190 — `launch-agent` bypasses the seam's missing-root skip; a deleted root spawns the agent in the app process's cwd**

`agent.launch` snapshots `fallbackWorkspace?.rootDirectory` raw and calls `AgentLaunchWorkingDirectoryResolver.resolve` itself. It never goes through `Workspace.newSurfaceWorkingDirectory`, which is where the `isExistingDirectory` check lives (Amendment 1, M2). If the root has been deleted (a pruned worktree is the usual case in the delegator workflow), this happens:

- `cwdResolution` = `(missingRoot, .workspaceRoot)`.
- `GitContextResolver` and `DefaultAgentProjectConfig.find(for:)` both run against a path that does not exist.
- `newTerminalSurface(workingDirectory: missingRoot)` treats that path as the *explicit* tier.
- `TerminalSurface` sets `surfaceConfig.working_directory`.
- Ghostty's `Exec.zig:932-968` finds the cwd inaccessible, logs "cannot access cwd, ignoring", and inherits the c11 process cwd. That is typically `/` for an app launched from Finder or the Dock.
- With `--new-workspace` and `source == .workspaceRoot`, the new workspace is also *rooted* at the missing path.

Every other rail falls back to the focused or source surface. Two docs added in this diff say `launch-agent` does the same:

- `docs/launch-agent-reference.md:126-127`: "the launching surface's cwd (the fallback for rootless workspaces, and for a root that no longer exists)".
- `skills/c11/references/api.md:215`: "the workspace root (skipped when that directory no longer exists)", listed as applying on every rail including `launch-agent`.

The installed skill copy is already synced, so agents are reading this claim today. This also leaves one per-rail precedence standing, which decision 1 asked to delete.

**Fix:** In the off-main section after the context gate, filter the root before resolving:

```swift
let usableRoot = workspaceRoot.flatMap { Workspace.isExistingDirectory($0) ? $0 : nil }
```

Then pass `usableRoot` to `resolve`. The stat already runs off-main there, so this adds no main-thread work. Better still, expose a small shared helper (for example `Workspace.usableRoot(_:)`) that both `newSurfaceWorkingDirectory` and SocketDispatch call, so the rule exists in one place. Add a host or tests_v2 case: root deleted, then `launch-agent` without `--cwd` lands in the caller surface's cwd.

---

**[MINOR] Sources/Workspace.swift:8891 — `newSurfaceWorkingDirectory` stats the root on main even when an explicit cwd wins**

`usableRoot` is computed before `resolve`, so every creation with an explicit cwd still runs `FileManager.fileExists` on main. That includes session restore (one call per restored terminal), `WorkspaceLayoutExecutor` specs, `--cwd` rails, and the agent-button path's second resolution inside `newTerminalSurface`. The result is thrown away. If the root sits on an unmounted or sleeping network volume, that stat can block the main thread for seconds during restore.

**Fix:** Return early when `explicit` trims to a non-empty string, and only stat the root when the root tier can actually win.

---

**[MINOR] Sources/SocketHandlers/WorkspaceHandlers.swift:577-600 — `workspace.get_root` runs a filesystem stat inside `v2MainSync` with no justification comment**

`rootDirectoryExists` calls `FileManager.fileExists` on main. The socket threading policy says new commands default to off-main, and any main-thread execution needs an explicit reason in a comment.

**Fix:** Read `rootDirectory`, `rootAdoptionArmed`, `currentDirectory`, the ids and the refs inside `v2MainSync`. Compute `root_exists` after returning off-main. Add a one-line comment explaining why the snapshot needs main.

---

**[MINOR] c11Tests/WorkspaceUnitTests.swift:902 — the ticket's headline rail (tab-bar agent button) has no regression test; the new socket surfaces have none either**

The bug in the ticket description came from the A button (`attemptAgentSurfaceLaunch`). The tests cover `newTerminalSplit`, `newTerminalSurface`, the tab-bar split button, adoption, and restore. Nothing drives `launchAgentSurface(inPane:)` or `attemptAgentSurfaceLaunch` on a drifted, rooted workspace. `createReplacementTerminalPanel`, `workspace.get_root`, `surface.create cwd`, and the `tree` `root=` line are also untested.

**Fix:** Add a host test that calls `workspace.launchAgentSurface(inPane:)` on a `makeDriftedWorkspace` fixture and asserts the new panel's `requestedWorkingDirectory == root`. Add a second case with `workingDirectory: explicit`. If feasible, add a tests_v2 case against a tagged socket for `workspace.get_root` (`root_exists` / `root_adoption_armed`) and `surface.create --cwd`.

---

**[MINOR] Sources/TabManager.swift:2346 (with :1396-1403) — a new sidebar workspace can turn the previous workspace's drift into a permanent root**

`addWorkspace()` with no directory still starts its first shell in the selected workspace's *focused* cwd (`preferredWorkingDirectoryForNewTab`). Adoption now makes that cwd the new workspace's permanent root on the first report.

Take the motivating scenario: root `code/c11`, focused shell `cd`'d to `code/overwatch`. Creating a new workspace from the sidebar now roots it at `code/overwatch`. Before C11-238 that drift was temporary; now it sticks. The plan flagged this as a follow-up (M3), and it may be what the operator wants. It is more consequential now than when it was flagged.

**Fix (operator call):** Have `preferredWorkingDirectoryForNewTab` prefer the selected workspace's root, when it exists, over its focused cwd. Otherwise, record the current behavior as our assumption in the completion comment.

---

**[MINOR] Sources/WorkspaceRootEditor.swift:34 — sidebar "Use Focused Directory" can be enabled while the action does nothing**

`mayUseFocusedDirectory` compares the raw focused path with the standardized root. A trailing slash or `..` segment reads as drift, and so does a focused directory that has been deleted. The menu item is enabled, then `useFocusedDirectory` re-validates through `canUseFocusedDirectory` and silently does nothing.

**Fix:** Standardize `focused` before comparing. `NSString.standardizingPath` is string-only, so it is still cheap enough for `TabItemView.body`. The deleted-directory case can stay as a no-op.

---

**[MINOR] Sources/Workspace.swift:12678 — dead fallback**

`newSurfaceWorkingDirectory(...).path ?? FileManager.default.homeDirectoryForCurrentUser.path` can never take the `??` branch, because the wrapper already guarantees a non-nil path.

**Fix:** Drop the `??`, or have the wrapper return a non-optional path, since its contract promises one.

---

**[MINOR] Process — runtime and GUI validation evidence is not on the ticket yet**

Amendment 1 M4 promised GUI-driven `pwd` oracles through c11-computer-use for tab-bar `+`, Cmd+T, Cmd+D, the tab-bar split button and the A button, plus popover and submenu screenshots. The HEAD commit message says "from tagged-build validation", but the only artifact on C11-238 is the plan review. Also, the installed `c11` and `lattice-orchestrator` skill copies are already synced from this unmerged branch. Agents on this machine are reading about `get-workspace-root` and `new-surface --cwd` while the prod binary does not have them yet. The orchestrator reference still keeps the `cd <worktree> &&` prefix, so it degrades safely.

**Fix:** Attach the tagged-build oracle output and screenshots to the ticket before merge.

## 4. Positive Observations

- **Seam placement.** The rule lives inside the creation primitives: `newTerminalSplit`, `newTerminalSurface`, the replacement panel, drag-to-split placeholder repair, and the bonsplit auto-create. That covers every rail without touching roughly 40 call sites. The inline split closure is gone, and `resolverCwdForAgentLaunch` is deleted with no remaining callers.
- **Agent-button coherence.** `attemptAgentSurfaceLaunch` resolves once and uses the same path for `DefaultAgentProjectConfig.find(from:)` and for the shell, so config lookup and cwd can no longer disagree. This is the actual root cause of the observed overwatch misfire.
- **Ordering.** The tier-3 source is resolved before `inheritedTerminalConfig`, which records the inheritance source as a side effect, and the comment explains why. Always passing a concrete path removes Ghostty's hidden inherit decision; the m7 divergence is documented.
- **Adoption semantics.** Adoption is one-shot, only counts the focused panel, skips remote workspaces, `$HOME` and `/`, and is disarmed by every explicit set or clear. It is hooked only on the real report funnel (`TabManager.updateSurfaceDirectory`), not on `updatePanelDirectory`, so restore and git-probe writes never adopt. It also works across windows, because the shell-integration `report_pwd` path resolves the right `TabManager`.
- **Persistence.** `rootAdoptionArmed: Bool?` decodes legacy snapshots as "armed iff root is nil", a clear survives restart (m3), and the flag is included in the autosave fingerprint.
- **GUI discipline.** The title-bar button has a fixed 18×18 trailing slot, does not observe the workspace, and stays in place (opacity 0) when there is no workspace. The popover reserves the drift row and the two-line caption so nothing jumps. The sidebar menu reads only the already-observed `tab` with string-only checks, so the `TabItemView` `==` contract and the typing path are untouched. `NSOpenPanel.begin` is non-modal, so there is no `runModal` hazard.
- **CLI and docs symmetry.** `get-workspace-root` mirrors `set-workspace-root` (option parsing, env default, `resolveWorkspaceId`). `new-surface --cwd` mirrors `pane.create` through `v2ResolveCwdParam`. `default-agent launch --cwd` now resolves relative to the CLI, and `inherit` is no longer forwarded as a literal `cd inherit`. The `tree` `root=` line uses tilde abbreviation. Usage text, help, the method list and the skill all agree.
- **Localization.** All 16 new keys carry all six locales, the xcstrings file is valid JSON (checked with `jq`), and `%@` survives in every translation of `workspaceRoot.focusedSurface`.
- **Tests.** The tests exercise real primitives, including a genuinely non-programmatic `bonsplitController.splitPane` for the C1 tab-bar split path. They use real temp directories (the missing-root test deletes one), cover the explicit-over-root and changed-then-cleared transitions, and round-trip the three restore states (rooted, cleared, pending) through `sessionSnapshot` and `restoreSessionSnapshot`, which preserve workspace ids. The fixture APIs I checked (`addWorkspace` parameter order, `updateSurfaceDirectory`, bonsplit `splitPane` returning a new empty pane so auto-create fires) match the source.
