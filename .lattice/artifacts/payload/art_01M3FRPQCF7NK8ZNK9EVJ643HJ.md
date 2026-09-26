# Plan Review: C11-238 (Claude)

Reviewed against the working tree at `0e37c3c8d` (origin/main `188a61ed1` + the C11-238 filing commit). Every claim below was checked against source; file:line references are to that tree.

## 1. Verdict

**FAIL (plan-level)**

The fix to the plan is small and targeted. The architecture (one seam, enforced inside the creation primitives) is right. But the plan's central claim, "every rail funnels into those two primitives," is false. The false claim leaves one acceptance criterion unmet, and the plan's validation would not catch it. Two further acceptance-relevant gaps (`--cwd` dropped or missing on two rails) and two unaddressed failure modes (stale root, `$HOME` adoption) should be settled before implementation starts.

## 2. Summary

The plan diagnoses the root cause correctly: Ghostty's inherited config decides the cwd in `newTerminalSurface`, and `newTerminalSplit` has its own inline closure. Enforcing `AgentLaunchWorkingDirectoryResolver.resolve` inside the primitives is the right lever. It also handles the adoption funnel, restore semantics, and the typing-path constraints with real care.

The key concern: at least three `TerminalPanel(...)` construction sites in `Workspace.swift` bypass both primitives. One of them is the per-pane tab-bar **split buttons**, one of the most-used GUI split affordances. After the change, those splits would still follow the drifted shell cwd. The socket and Cmd+D smoke would pass and never notice.

## 3. Issues

**[CRITICAL] The seam / rail table: tab-bar split buttons, drag-to-split repair, and last-panel replacement bypass both primitives**

Bonsplit's split toolbar buttons call `controller.splitPane(pane.id, orientation:)` directly (`vendor/bonsplit/.../TabBarView.swift:1299,1303,1622,1631`). That is a non-programmatic split. c11 does not implement `shouldSplitPane`, so it lands in `Workspace.splitTabBar(_:didSplitPane:newPane:orientation:)` (`Workspace.swift:12275`). Past the `isProgrammaticSplit` guard (`:12318`), the "autoCreate" branch builds `TerminalPanel(workspaceId:context:configTemplate:portOrdinal:)` with **no `workingDirectory`** (`:12424`). Ghostty's `newSurfaceOptions` then copies the source surface's live pwd (`ghostty/src/apprt/embedded.zig:965`). That is exactly the overwatch behavior this ticket exists to kill.

Two more sites bypass the primitives the same way:
- The drag-to-split placeholder repair (`Workspace.swift:12358`).
- `createReplacementTerminalPanel()` (`:10349`), used when the last panel in a workspace closes (`:12071`).

The acceptance line "a split … start[s] in A" fails for the tab-bar split button. The planned runtime validation drives only Cmd+D, which goes through `newTerminalSplit`, and socket verbs, so the gap would ship.

**Recommendation:**
- Route all three constructions through `newSurfaceWorkingDirectory(explicit: nil, sourcePanelId: <source>)`:
  - autoCreate: `sourcePanelId` (already computed at `:12402`).
  - placeholder repair: the original pane's terminal.
  - replacement: `focusedPanelId`, which may be nil, so the resolution falls to root, then `currentDirectory`.
- Add the rows to the rail table.
- State an invariant in the plan: every `TerminalPanel(` construction in `Workspace.swift` except `init` (`:6053`) resolves its cwd through the seam. Six sites exist today.
- Add a host-target test that calls `workspace.bonsplitController.splitPane(pane, orientation: .horizontal)` (non-programmatic) on a rooted workspace and asserts the auto-created panel's `requestedWorkingDirectory == root`.
- Add a real click on the tab-bar split button to the GUI smoke.

**[MAJOR] Rail table, `default-agent launch` row: `--cwd` is dropped on the new-surface path, and `new-surface` has no `--cwd` at all**

1. `default-agent launch` without `--in-surface` parses `cwdArg` (`TerminalController.swift:9262`), then calls `tab.launchAgentSurface(inPane:explicitAgent:source:)` without it (`:9362`). The flag has always been silently ignored on this path. Under the plan it lands in root A, so the "`--cwd C` still wins" acceptance fails on the agent-button CLI rail. The CLI also forwards `--cwd` unresolved (`CLI/c11.swift:11625,11702`), so `.` would not work there even if threaded.
2. `c11 new-surface` exposes no `--cwd` (`CLI/c11.swift:2457-2473`), and `surface.create` passes no cwd (`SurfaceHandlers.swift:427`). The plan says "Docs point agents at `--cwd .` when they want their own current directory," but that escape hatch does not exist for `new-surface`. Operator decision 1 ("explicit cwd, then workspace root…") names CLI new-surface explicitly.

**Recommendation:**
- Add `workingDirectory: String?` to `launchAgentSurface` / `attemptAgentSurfaceLaunch` as the explicit tier.
- Validate it with `CwdParamResolution` and `resolvePath` it CLI-side.
- Add `--cwd <path|inherit>` to `new-surface` / `surface.create`, mirroring `pane.create` (`PaneHandlers.swift:250`).
- Add both to the tests and the smoke.

**[MAJOR] The seam: a root that no longer exists silently sends every new surface to Ghostty's default directory**

`resolve` never checks that the root exists. Ghostty's `openDirAbsolute` fails with a `log.warn` and the shell spawns in the default directory (`embedded.zig:509ff`). In this ecosystem, workspaces rooted at git worktrees are routine, and those worktrees are pruned as a matter of hygiene. Auto-adopt makes worktree roots more common still.

Today a missing root affects only `launch-agent`. After this change, every tab and split in that workspace silently lands in `~`, with nothing in the UI saying why.

**Recommendation:** In `Workspace.newSurfaceWorkingDirectory`, skip the root tier when the directory no longer exists and fall through to tier 3. That costs one `stat` at surface creation, not on the typing path. Keep `resolve` pure by passing `nil` for the root, or add an injectable existence predicate. Emit a DEBUG `dlog`, and show "root missing" in the popover and in `get-workspace-root` so the operator can fix it.

**[MAJOR] Auto-establish: first-report adoption will commonly adopt `$HOME`, turning splits into "always open in ~"**

Two common cases start the first shell in `~` (`preferredWorkingDirectoryForNewTab` returns nil, `TabManager.swift:2345`):
- The first workspace on a fresh launch.
- Any workspace created while nothing is selected.

That shell reports `~` and the workspace adopts it as root. The operator then runs `cd ~/Projects/foo` and hits Cmd+D, and the split opens in `~`. Today it opens in `foo`. This regression hits the most common default flow, and the plan's risk notes do not name it. They cover only workspaces whose root was set deliberately.

**Recommendation:** Raise this with Atin as a numbered question before implementing. Suggested default: don't adopt `$HOME` or `/`, and stay armed until the first non-home focused report. If he wants the literal behavior, document it in the skill and the popover caption.

Related (minor, same question): a sidebar-created workspace starts in the *selected* workspace's focused cwd (`TabManager.swift:2348-2350`), then adopts it. In the motivating scenario that is `code/overwatch`, so drift gets cemented into the new workspace's root. Consider having `preferredWorkingDirectoryForNewTab` prefer the selected workspace's `rootDirectory`, which is decision 1's precedence applied to workspace creation.

**[MAJOR] Runtime validation: not on the packaged app, and not through the real GUI affordances**

The acceptance asks for "smoke on the real packaged app per SMOKE convention." The plan validates on a tagged Debug build, and mostly over the socket. It sends `default-agent launch` as the "agent button path" and `new-split` as the split path. Socket parity is exactly how the critical issue above would slip through.

**Recommendation:** Add a Release staging pass: `C11_QA_LAUNCH=fresh ./scripts/reloads.sh --tag c11-238`. Drive the real GUI (c11-computer-use) with an `pwd` oracle per new surface for:
- Tab-bar `+`
- Cmd+T
- Cmd+D
- The tab-bar split button
- The A button
- The "New Terminal to Right" context action

Also add a C11-238 line to the next release SMOKE checklist.

**[MINOR] `newTerminalSurface` sources tier 3 from the focused surface, not the target pane**

On rootless workspaces today, a new tab inherits from the target pane's terminal (`inheritedTerminalConfig(inPane:)`, `Workspace.swift:8768`). Under the plan, three cases would instead take the *focused* surface's cwd:
- `new-surface --pane P`
- "New Terminal to Right" in an unfocused pane (`:11052`)
- Background-workspace creation

**Recommendation:** Pass `sourcePanelId: terminalPanelForConfigInheritance(inPane: paneId)?.id` so tier 3 stays pane-local, matching the config-inheritance source.

**[MINOR] GUI affordance: the info button placed after the title text will jump**

`Text(titlebarText)` is variable-width, and `DraggableFolderIcon` is conditional (`ContentView.swift:2309-2317`). A button placed "right after the workspace title text" moves horizontally on every workspace switch and every agent-set title. That violates the "UI elements never jump" quality bar.

**Recommendation:** Give it a fixed slot. Options: after the `Spacer` at the trailing edge with a fixed frame, or a fixed-width leading slot.

**[MINOR] Auto-establish: make Clear persist rather than leaving it as a known edge**

The plan flags that a cleared root comes back after restart. Worse, the workspace re-adopts whatever the focused surface's cwd is at relaunch. Clear is a first-class GUI action the operator asked for.

**Recommendation:** Persist the armed flag, e.g. `rootAdoptionArmed: Bool?` on `SessionWorkspaceSnapshot`. Nil in a legacy snapshot means armed when the root is nil. Include it in the autosave fingerprint beside `rootDirectory` (`TabManager.swift:5580`).

**[MINOR] GUI affordance: GUI root writes skip the validation the socket verb applies**

`workspace.set_root` validates through `CwdParamResolution`: absolute, exists, is a directory (`WorkspaceHandlers.swift:538-550`, `TerminalController.swift:42`). "Use Focused Directory" would call `setRootDirectory` directly. In a remote (SSH) workspace the focused cwd is a remote path.

**Recommendation:** Validate existence on the GUI paths, and disable "Use Focused Directory" when `remoteConfiguration != nil`.

**[MINOR] Skill and docs: the sweep is incomplete**

These still describe inherit-by-default behavior and need updating:
- `docs/launch-agent-reference.md:121-142` (the cwd order section).
- `skills/lattice-orchestrator/references/orchestrator.md:43`: "`new-surface --pane` inherits the pane's *last* shell cwd."
- `skills/c11/references/api.md:207,216`.
- The in-code CLI comments and help for `new-split` / `new-pane`: "inherit the parent surface's cwd" (`CLI/c11.swift:~2124,~2224`).

**Recommendation:** Update all of these, and run `scripts/sync-installed-skills.sh c11 lattice-orchestrator`, not just `c11`.

**[MINOR] Auto-establish: say explicitly what happens to `establishRootFromWorkingDirectory: false`**

`launch-agent --new-workspace` deliberately avoids rooting a workspace at an *inherited* cwd (`SocketDispatch.swift:1291`), and `workspace.create` passes `false` (`WorkspaceHandlers.swift:226`). Under the plan, both become "adopt the first report a moment later." That is consistent with decision 3, but it is a semantic change, and the plan doesn't say so.

**Recommendation:** State it and test it. Consider the simpler shape: root at creation from the resolved initial directory whenever one is known (`addWorkspace` almost always has one). Keep report-based adoption only for the nil case. That removes most of the armed-flag state, the restore-disarm special case, and the ordering races.

**[MINOR] The seam: tier 4 is not guaranteed, and a Ghostty config interaction goes unmentioned**

`resolve` returns `path: nil` when every tier is empty, so Ghostty's inherit still decides in that case. The plan says "always pass a concrete path"; add an explicit `NSHomeDirectory()` fallback in the wrapper so that holds.

Separately, always passing a concrete path means Ghostty's `window-inherit-working-directory` / `working-directory` config no longer applies to new tabs. Splits already ignore it. Note it as an accepted divergence under the "unopinionated about the terminal" principle.

## 4. Positive Observations

- **The root-cause analysis is accurate and verified.** The plan finds both mechanisms: the inline closure in `newTerminalSplit` (`Workspace.swift:8656-8674`) and the nil-cwd Ghostty inherit in `newTerminalSurface` (`:8773`). It also recognizes that the resolver already exists and is used only by `agent.launch`.
- **Putting enforcement inside the primitives, not at ~40 call sites, is the right altitude.** I checked every primitive caller that passes `workingDirectory:`. None passes a pre-resolved focused cwd as "explicit," so root precedence holds for everything that does funnel through.
- **The adoption funnel is chosen with precision.** Hooking `TabManager.updateSurfaceDirectory` rather than `Workspace.updatePanelDirectory` correctly excludes the git probe (`TabManager.swift:1715`) and restore writes. The shell-integration `report_pwd` path resolves the right TabManager through `tabManagerFor(tabId:)`, so multi-window workspaces adopt correctly.
- **Typing-path discipline.** `TabItemView`'s `==` contract is untouched, since the menu reads only through the already-observed `tab`. Observation is confined to the popover content. The seam runs only at creation.
- **Deleting `resolverCwdForAgentLaunch`** (single caller confirmed) and resolving once for both the shell cwd and the project-config lookup closes a real divergence between the two.
- **Honest risk flagging.** The cleared-root-after-restart edge, the remote exclusion, and the behavior change for inherit-reliant operators are all named. The rail table makes the blast radius reviewable, which is how its gaps were found.
- **CLI symmetry is right-sized.** `workspace.get_root`, `root_directory` on the tree node, and `root=` on text tree lines are additive and match decision 4 without over-building.
