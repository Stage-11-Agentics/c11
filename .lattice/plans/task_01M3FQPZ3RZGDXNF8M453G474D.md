# C11-238: c11: workspace root directory governs every new surface (tabs, splits, agent button, CLI), visible and editable from the workspace

Every new surface created inside a workspace should start in that workspace's root directory. Today only the socket launch-agent rail honors Workspace.rootDirectory (precedence: explicit --cwd, workspace root, launching surface). The tab-bar agent button (launchDefaultAgentFromTabBar, default-agent launch), new terminal tab, every split, and CLI new-surface/split all inherit the focused shell's cwd via inheritedCwdForAgentLaunch / panelDirectories, so a workspace titled "c11" with root code/c11 launched a new agent in code/overwatch because one surface had cd'd there (observed 2026-09-26, workspace index 3: root_directory=code/c11, current_directory=code/overwatch).

Operator decisions (Atin, 2026-09-26):
1. Root is a workspace-level attribute; panes and splits are sub-attributes. Every rail snaps to the root: new terminal tab, split, tab-bar agent button, default-agent launch, launch-agent, CLI new-surface/split. Precedence everywhere: explicit cwd, then workspace root, then focused surface, then home. Reuse AgentLaunchWorkingDirectoryResolver.resolve as the single seam; delete per-rail precedence.
2. Root is visible and editable in the GUI: an info affordance on the workspace (sidebar row or title bar) that shows the root and lets the operator change or clear it, backed by the existing set-workspace-root socket verb. Show the focused surface's cwd only as a secondary line when it differs from the root, so drift is visible.
3. Auto-establish: a workspace created with a directory already gets it as root (TabManager.addWorkspace establishRootFromWorkingDirectory). A workspace created without one adopts its first terminal surface's reported cwd as root, so no workspace stays rootless. Session restore keeps the persisted root.
4. list-workspaces --json already reports root_directory; add root to `c11 tree` workspace lines and keep get/set symmetric (a get-workspace-root or equivalent read).

Acceptance: with a workspace whose root is A and a focused surface cd'd to B, a new tab, a split, the agent button, and `c11 launch-agent` without --cwd all start in A; `--cwd C` still wins; the info affordance shows A and changing it to D makes the next surface start in D; a workspace created from the sidebar with no directory acquires a root after its first shell reports a cwd. Unit tests on the resolver and on addWorkspace root establishment; smoke on the real packaged app per SMOKE convention.

---

## Plan (C11-238-Delegator-1, 2026-09-26)

Working against origin/main @ 188a61ed1 (re-recorded at implement time after fetch/rebase).

### Root cause

A new terminal surface gets its cwd from one of two places, neither of which knows about the workspace root:

- `Workspace.newTerminalSplit` has its own inline precedence closure: override, source panel reported cwd, source panel requested cwd, workspace `currentDirectory`.
- `Workspace.newTerminalSurface` passes the caller's `workingDirectory` straight to `TerminalPanel`. When that is nil, `TerminalSurface` never sets `surfaceConfig.working_directory`, so Ghostty's `ghostty_surface_inherited_config` (from `inheritedTerminalConfig(inPane:)`) copies the source surface's live pwd. That is the "inherit" behavior that put the agent in overwatch.

Only `launch-agent` (SocketDispatch) calls `AgentLaunchWorkingDirectoryResolver.resolve` with a workspace root.

### The seam (one rule, applied inside the two creation primitives)

Add to `Workspace`:

```swift
/// C11-238: the one cwd rule for every new terminal surface in this workspace.
func newSurfaceWorkingDirectory(explicit: String?, sourcePanelId: UUID? = nil) -> AgentLaunchWorkingDirectoryResolution {
    AgentLaunchWorkingDirectoryResolver.resolve(
        explicitCwd: explicit,
        workspaceRoot: rootDirectory,
        launchingSurfaceCwd: inheritedCwdForAgentLaunch(callerSurfaceId: sourcePanelId)
    )
}
```

`inheritedCwdForAgentLaunch` already walks source/focused panel reported cwd, then its requested cwd, then `currentDirectory` (which defaults to home at init), so tiers 3 and 4 (focused surface, home) are covered without a new copy.

Then:

- `newTerminalSplit(from:...workingDirectory:)`: delete the inline closure; use `newSurfaceWorkingDirectory(explicit: workingDirectory, sourcePanelId: panelId).path`. The `split.cwd` dlog keeps logging the resolved path plus the source tier.
- `newTerminalSurface(inPane:...workingDirectory:)`: resolve `newSurfaceWorkingDirectory(explicit: workingDirectory).path` (source = focused surface) and always pass a concrete path to `TerminalPanel`, so Ghostty's inherit never decides the cwd.
- `attemptAgentSurfaceLaunch` (tab-bar agent button, `default-agent launch` new-surface path, AppDelegate launches): resolve once, use the same path for `DefaultAgentProjectConfig.find(from:)` and pass it as `workingDirectory` to `newTerminalSurface`, so the project-config lookup and the shell agree. Delete `resolverCwdForAgentLaunch()` (only caller).

Because every rail funnels into those two primitives, this covers all of them without touching the ~40 call sites:

| Rail | Entry | Today's cwd source | After |
|---|---|---|---|
| New tab (Cmd+T, tab-bar +, empty-pane "New Terminal", tab context "new terminal to right") | `newTerminalSurfaceInFocusedPane`, `WorkspaceContentView.createTerminal`, MiscHandlers `new_terminal_right` → `newTerminalSurface(inPane:)` with nil cwd | Ghostty inherit from the pane's terminal | seam: root, else focused surface |
| Split (Cmd+D etc., drag-to-split, welcome/default grids) | `TabManager.newSplit`, c11App/AppDelegate/TabManager grids → `newTerminalSplit` | inline closure: source panel cwd | seam: root, else source panel |
| Tab-bar agent button / `default-agent launch` (new surface) | `attemptAgentSurfaceLaunch` → `newTerminalSurface` with nil cwd; config lookup from `resolverCwdForAgentLaunch` (focused panel) | Ghostty inherit; config from focused panel | seam path for both shell and config lookup |
| `c11 launch-agent` | SocketDispatch `agent.launch` | already `resolve(explicit, root, caller surface)` | unchanged (already the seam; passes explicit path down) |
| CLI `new-split` / `new-pane` (v2) | SurfaceHandlers `surface.split`, PaneHandlers `pane.create` → primitives with `cwdOverride` | override else split closure / Ghostty inherit | seam: `--cwd` wins, else root, else source |
| CLI `new-surface` (v2 `surface.create`) and v1 `new_split` / `new_surface` | primitives with nil cwd | Ghostty inherit / split closure | seam: root, else focused |
| Layout executor / blueprint (`WorkspaceLayoutExecutor`) | primitives with `spec.workingDirectory` | spec, else inherit | spec wins, else root |
| Session restore (`createPanel`) | `newTerminalSurface` with the snapshot's explicit cwd | snapshot | unchanged (explicit wins); restore placeholders get root and are closed |
| `default-agent launch --in-surface` | types into an existing shell | `resolveExistingSurface` | unchanged: not a new surface, and the existing shell owns its cwd |

`--cwd inherit` (CwdParamResolution `.inherit`) keeps meaning "no explicit cwd", which now resolves to the root. Docs point agents at `--cwd .` when they want their own current directory.

### Auto-establish (decision 3)

- Creation with a directory: unchanged (`addWorkspace` `establishRootFromWorkingDirectory`, `workspace.create --cwd/--root`).
- Creation without one: `Workspace` gets `private var adoptsFirstReportedDirectoryAsRoot: Bool`, true when init sees no root. New `Workspace.adoptReportedDirectoryAsRootIfNeeded(panelId:directory:)` sets the root from the first shell-reported cwd when the flag is armed, the reporting panel is the focused panel (or nothing is focused yet), and the workspace is not remote (`remoteConfiguration == nil`, whose reported cwd is a remote path). One-shot: the flag clears once adopted.
- Called from `TabManager.updateSurfaceDirectory`, the funnel for real shell reports (Ghostty `GHOSTTY_ACTION_PWD`, `report_pwd` v1/v2). Not from `Workspace.updatePanelDirectory`, which session restore and the git probe also call, so restoring panel metadata never counts as a report.
- `setRootDirectory` (socket `set-workspace-root`, GUI change/clear) disarms the flag, so an operator clear sticks for the session and new surfaces fall back to the focused surface.
- Session restore: the persisted root is applied without disarming when it is nil, so a pre-root snapshot's workspace adopts on its first focused report. Known edge, flagged: a root the operator cleared comes back after a restart (clear is not persisted as its own state). Adding a persisted "cleared" marker is cheap if plan review wants it.

### CLI symmetry (decision 4)

- New socket method `workspace.get_root` (params `workspace_id`) → `{workspace_id, workspace_ref, window_id, window_ref, root_directory, current_directory}`; registered next to `workspace.set_root` in the capabilities list.
- New CLI `c11 get-workspace-root [--workspace <id|ref|index>] [--json]`: text prints the root path, or `(none)`; defaults to `$C11_WORKSPACE_ID` like `set-workspace-root`. Usage text + help entry + the command list.
- `c11 tree`: `v2TreeWorkspaceNode` adds `root_directory`; `treeWorkspaceLabel` appends `root=<path>` (home abbreviated to `~`) when set.
- `set-workspace-root` help text: "New terminals, splits, and agent launches without --cwd start in this root."

### GUI affordance (decision 2)

Two entry points to one small editor, both backed by `Workspace.setRootDirectory` (the same call `workspace.set_root` makes):

1. **Title bar info button** (primary). In `ContentView.customTitlebar`, a fixed-size (16x16) borderless `info.circle` button right after the workspace title text; tooltip "Workspace root". Click opens a popover (`WorkspaceRootPopover`, `@ObservedObject workspace`):
   - Header "Workspace Root"; the root path in monospaced, selectable text, middle-truncated, or "No root set".
   - Secondary line "Focused surface: <cwd>", rendered only when it differs from the root, in a row whose height is always reserved (opacity toggle) so nothing jumps.
   - Caption: "New tabs, splits, and agents start here."
   - Buttons in a fixed row: "Change…" (non-modal `NSOpenPanel`, directories only, starts at the current root), "Use Focused Directory" (disabled when no drift), "Clear" (disabled when no root).
   The button view itself does not observe the workspace (only the popover content does), so the title bar gains no new invalidation on the typing path.
2. **Sidebar row context menu** (covers minimal mode, where the custom title bar is hidden): a "Workspace Root" submenu on the single clicked workspace with a disabled line showing the path (or "No Root Set"), "Change…", "Use Focused Directory", "Clear Workspace Root". `TabItemView` already observes `tab`, and the menu reads only `tab.rootDirectory` / `tab.currentDirectory`, so the `==` contract is untouched.

All strings via `String(localized:defaultValue:)`; translations for the six locales delegated to a sub-agent writing `Resources/Localizable.xcstrings`, checked with `jq` plus a token-survival check.

### Skill and docs

- `skills/c11/references/api.md`: the `--cwd` section and the launch-agent note state the one rule (explicit, root, source surface, home) for new-split/new-pane/new-surface/launch-agent/agent button; add `get-workspace-root`; note `tree` shows `root=`. Then `scripts/sync-installed-skills.sh c11`.
- `CLI/c11.swift` usage for `new-split`/`new-pane`/`set-workspace-root`/`get-workspace-root`.

### Tests

Pure (`c11Tests/DefaultAgentResolverTests.swift`, member of both test targets, runnable on c11-logic locally):
- whitespace-only explicit cwd and root fall through to the next tier; all-empty resolves to nil.

Workspace/TabManager (new `WorkspaceRootDirectoryTests` class in `c11Tests/WorkspaceUnitTests.swift`, host target, CI):
- root A + focused panel reported B: `newTerminalSplit` and `newTerminalSurface(inPane:)` produce panels whose `requestedWorkingDirectory == A`.
- explicit cwd C beats root A on both primitives.
- root cleared: split falls back to the source panel's cwd, new tab to the focused panel's cwd.
- `setRootDirectory(D)` then a new surface starts in D.
- `addWorkspace(workingDirectory: A)` → root A; with `rootDirectory: R` → R; `establishRootFromWorkingDirectory: false` → nil.
- rootless workspace: first focused `updateSurfaceDirectory` adopts; a second report does not move it; a non-focused panel's report does not adopt.
- clear after adoption is sticky (a later report does not re-adopt).
- snapshot round trip keeps the root; a restored rootless workspace adopts on its first report.
- The existing `WorkspaceSplitWorkingDirectoryTests` (rootless split inherits source requested cwd) stays green as the tier-3 check.

Local loop: only `-only-testing:c11LogicTests/DefaultAgentResolverTests` on c11-logic through the build lock after the tagged build warms the cache (Orchestrator addendum); Workspace-constructing tests run in CI.

### Runtime validation (tagged build `c11-238`, `launch-tagged-automation.sh c11-238 --qa fresh`)

Over the tagged socket: create workspace with root A, `cd` a surface to B, then `new-surface`, `new-split`, `default-agent launch` (agent button path), `launch-agent` without `--cwd`; read `pwd` via `send` + `read-screen` on each: all A. `new-split --cwd C` → C. `set-workspace-root D` → next split D; `--clear` → next split B (focused). New workspace with no dir → `get-workspace-root` non-empty after first prompt. `get-workspace-root`, `tree` root line. GUI: screenshot the title bar info button, popover showing A plus drift line B, and the sidebar context submenu (c11-computer-use). Session restore: quit/relaunch with `--qa resume` and confirm the root persists.

### Risk notes

- Behavior change for operators who relied on split-inherits-shell-cwd: intended by the ticket. The escape hatches are `--cwd .` for agents and clearing the root in the GUI.
- Remote (SSH) workspaces: no auto-adopt; an explicit root still applies.
- No new work on the typing path: the seam runs only at surface creation, and the title bar button does not observe the workspace.

---

## Amendment 1: plan-review triage (art_01M3FRPQCF7NK8ZNK9EVJ643HJ, verdict FAIL plan-level)

| # | Finding | Call | Change |
|---|---|---|---|
| C1 | Tab-bar split buttons (`splitTabBar(_:didSplitPane:...)` autoCreate), drag-to-split placeholder repair, and `createReplacementTerminalPanel` build `TerminalPanel` with no cwd | Accept | All three resolve through the seam. Invariant: every `TerminalPanel(` construction in `Workspace.swift` except `init`'s first panel resolves its cwd through `newSurfaceWorkingDirectory`. Six sites today: init, `newTerminalSplit`, `newTerminalSurface`, replacement, placeholder repair, autoCreate. Host test drives a non-programmatic `bonsplitController.splitPane` on a rooted workspace. GUI smoke clicks the tab-bar split button. |
| M1 | `default-agent launch` (new-surface path) parses `--cwd` and drops it; `new-surface` has no `--cwd` | Accept | `launchAgentSurface` / `attemptAgentSurfaceLaunch` gain `workingDirectory:` as the explicit tier; the socket path validates it with `CwdParamResolution`; the CLI `resolvePath`s `--cwd` for both default-agent paths. `new-surface` / `surface.create` gain `--cwd <path|inherit>` mirroring `pane.create`. |
| M2 | A root that no longer exists silently lands new surfaces in Ghostty's default dir | Accept | `newSurfaceWorkingDirectory` skips the root tier when it is not an existing directory (one `stat` at creation), falls to tier 3, DEBUG `dlog`. `resolve` stays pure (root passed as nil). Popover and `get-workspace-root` report `root_exists`. |
| M3 | First-report adoption commonly adopts `$HOME` | Accept as our assumption (sent to Orchestrator) | Adoption skips `$HOME` and `/`, stays armed until the first other cwd the focused shell reports. Documented in skill and popover caption. The related "new sidebar workspace starts in the selected workspace's drifted cwd" is left alone (workspace creation, not a surface inside a workspace); noted as a follow-up option in the completion comment. |
| M4 | Validation not on packaged app / not via real GUI rails | Partly accept | Runtime proof stays as the Orchestrator specified (tagged build via `launch-tagged-automation.sh c11-238 --qa fresh`). Add GUI-driven `pwd` oracles through c11-computer-use for tab-bar `+`, Cmd+T, Cmd+D, the tab-bar split button, and the A button. Release staging pass is the release's job; a C11-238 line goes on the release SMOKE checklist if one exists in the repo. |
| m1 | Tier 3 for `newTerminalSurface` should be pane-local | Accept | Source = focused panel when it is in the target pane, else `terminalPanelForConfigInheritance(inPane:)`. |
| m2 | Info button after variable-width title will jump | Accept | Trailing-edge fixed-size slot after the `Spacer`. |
| m3 | Clear should persist | Accept | `SessionWorkspaceSnapshot.rootAdoptionArmed: Bool?` (nil in legacy = armed iff root nil), included in the autosave fingerprint beside `rootDirectory`. |
| m4 | GUI writes skip socket validation; remote focused cwd | Accept | GUI paths validate existing directory; "Use Focused Directory" disabled for remote workspaces. |
| m5 | Docs sweep incomplete | Accept | Also `docs/launch-agent-reference.md` cwd section, `docs/socket-api-reference.md` (`workspace.get_root`), `skills/lattice-orchestrator/references/orchestrator.md:43`, CLI help for new-split/new-pane/new-surface. Sync `c11` and `lattice-orchestrator`. |
| m6 | `establishRootFromWorkingDirectory: false` semantics change | Accept | Stated here: those workspaces (`launch-agent --new-workspace` with an inherited cwd, `workspace.create` with no cwd/root) now adopt their first non-home focused report. Tested. Keeping report-based adoption (the operator's wording) over rooting at creation. |
| m7 | Tier 4 not guaranteed; Ghostty working-directory config | Accept | Wrapper falls back to home when every tier is empty, so a concrete path always reaches `TerminalPanel`. Accepted divergence: Ghostty's `working-directory` / `window-inherit-working-directory` no longer decide new-tab cwd inside a workspace (splits already ignored them); c11 owns in-workspace placement, which is surface-level, not tenant config. |

Revised seam signature:

```swift
func newSurfaceWorkingDirectory(explicit: String?, sourcePanelId: UUID?) -> AgentLaunchWorkingDirectoryResolution
// root tier only when rootDirectory is an existing directory; home when every tier is empty
```

**M3 ruling (Orchestrator, 2026-09-26, approved):** auto-adopt skips `$HOME` and `/`, is armed only while `rootDirectory` is nil, and disarms the moment a root is set by any path (explicit `set-workspace-root`, the GUI affordance, creation with a directory, or restore of a persisted root). An operator who wants `~` as root sets it explicitly; auto-adopt never overrides a set root. A Clear disarms too (persisted via `rootAdoptionArmed`).

---

## Amendment 2: code-review triage (art_01M3FVMHXH0CQ1Q0YPNPDEMV8Q, verdict FAIL implementation-level)

| # | Finding | Call | Change |
|---|---|---|---|
| M1 | `launch-agent` resolves with the raw root, so a deleted root spawns the agent in the app process cwd | Accept | `Workspace.usableRootDirectory(_:)` (nonisolated, existing-directory check) is the one missing-root rule; `newSurfaceWorkingDirectory` and SocketDispatch `agent.launch` (off-main, after the context gate) both use it. Pure test on the helper; tagged-build check: delete the root, `launch-agent` without `--cwd` lands in the caller surface cwd. |
| m1 | Root stat on main even when an explicit cwd wins | Accept | Early return on a non-empty explicit cwd before the root stat. |
| m2 | `workspace.get_root` stats inside `v2MainSync` | Accept | Snapshot on main, `root_exists` computed off-main, comment says why the snapshot needs main. |
| m3 | No regression test for the agent-button rail; replacement panel untested | Accept (adapted) | `Workspace.agentLaunchWorkingDirectory(inPane:explicit:)` is the side-effect-free resolution the A button uses, tested on a drifted rooted workspace (root and explicit cases). Full `attemptAgentSurfaceLaunch` stays untested in unit tests on purpose: it reads the operator's config stores and writes launch stats. The real click passed on the tagged build. Replacement panel: closing a workspace's last panel yields a replacement in the root. tests_v2 socket cases not added; the equivalent socket checks are in the validation evidence. |
| m4 | New sidebar workspace can turn the old workspace's drift into its root | Orchestrator decision, below | `preferredWorkingDirectoryForNewTab` prefers the selected workspace's usable root. |
| m5 | Sidebar "Use Focused Directory" enabled on non-standardized drift | Accept | Standardize the focused path (string-only) before the compare. |
| m6 | Dead `?? home` fallback | Accept | `newSurfaceWorkingDirectory` returns a non-optional path. |
| m7 | Validation evidence not on the ticket | Accept | Attached with `--role validation` at the validate phase. |

**m4 ruling (Orchestrator, 2026-09-26), under the ticket's rule that drift never becomes a root:** a new sidebar workspace created without a directory starts in the selected workspace's ROOT, falling back to the selected workspace's focused cwd only when that workspace has no root, then home. Whatever it starts in is what auto-adopt sees (still skipping `~` and `/`).
