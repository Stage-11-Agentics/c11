# C11-40: New-workspace agent launch misses Enter + close-pane X dialog no-ops when terminal is busy

Two reliability bugs surfaced in c11 DEV staging-2026-05-14.

## Bug A — New Workspace dialog: 'Launch coding agent' types command but never submits

Reproduce:
1. File → New Workspace (⌘N)
2. Pick a two-column blueprint, working directory, leave 'Launch coding agent in initial pane' checked
3. Click Create

Observed: the initial terminal contains the literal text 'claude --dangerously-skip-permissions' at the shell prompt. No Enter has been pressed. The agent never starts.

Expected: command runs immediately, same as the 'A' tab-bar button.

Root cause (worktree: c11-worktrees/staging-2026-05-14 @ c163b9d45):
- 'A' button → Workspace.launchAgentSurface (Workspace.swift:11397) sends 'command + "\n"' to the terminal panel — correct.
- New Workspace dialog → AppDelegate.applyWorkspacePlanInPreferredMainWindow (AppDelegate.swift:5969-5976) injects the agent's shellCommand into SurfaceSpec.command, but does not append a newline. The Phase 0 parity rule in WorkspaceLayoutExecutor (WorkspaceLayoutExecutor.swift:201-267) delivers SurfaceSpec.command verbatim via terminalPanel.sendText, so no Enter is sent.
- AgentLauncherSettings.Kind.builtInCommand (c11App.swift:4032-4043) does not include a trailing newline (deliberate — the 'A' button adds it at the call site).

Fix: at the injection site append '\n' (or send-key enter after) to match the 'A' button. Single-line change in AppDelegate.swift around line 5974:

    injected.surfaces[idx].command = command + "\n"

Verify with all four supported agents (Claude Code, Codex, OpenCode, Kimi). Add a unit test on WorkspaceLayoutExecutor that the executor's sendText output for a workspace built through this code path ends in '\n'.

## Bug B — Close-pane X confirm clicks vanish when the pane's terminal is busy

Reproduce (most reliable on top-right or bottom-right of a 2x2 grid, both running an agent):
1. Launch a 2x2 grid workspace, run 'claude --dangerously-skip-permissions' (or any TUI that holds the PTY) in the top-right and bottom-right panes.
2. Click X on the top-right pane.
3. (Mode A) Confirmation dialog appears; click 'Close Entire Pane' → nothing happens, pane stays.
4. (Mode B) On subsequent X clicks in the same workspace, sometimes the confirmation dialog does not appear at all — X is a no-op.

Expected: clicking confirm always closes the pane. X always produces feedback (either dialog or close).

Root cause for Mode A (confirmed):
- Workspace.splitTabBar(_:didRequestClosePane:) (Workspace.swift:11426-11484) handles the dialog flow correctly for the 'only pane' branch (line 11473-11478): inserts every tab into forceCloseTabIds before calling closeTab, which bypasses the per-tab veto in shouldCloseTab.
- The multi-pane branch (line 11479-11482) does NOT pre-load forceCloseTabIds:

      guard self.bonsplitController.allPaneIds.contains(pane) else { return }
      _ = self.bonsplitController.closePane(pane)

- BonsplitController.closePane (vendor/bonsplit/.../BonsplitController.swift:588-607) consults the delegate via shouldClosePane before doing anything. Workspace.splitTabBar(_:shouldClosePane:) (Workspace.swift:11167-11181) walks every tab and vetoes (returns false) if any terminal panel reports panelNeedsConfirmClose === true (i.e., active process, not at idle prompt).
- Net effect: a pane whose terminal is busy (running claude/codex/etc.) can never be closed via the X confirm flow. Result is exactly what the user sees: dialog → Close Pane → nothing. Idle panes (e.g., top-left at prompt) are not vetoed and close fine.

Why top-right / bottom-right specifically: those are the panes the operator typically runs agents in, so their terminals are routinely busy. Top-left often hosts the orchestrator at idle prompt, which is why those Xs feel reliable.

Fix for Mode A: mirror the 'only pane' branch. Pre-load forceCloseTabIds for every tab in the pane before calling closePane:

    } else {
        guard self.bonsplitController.allPaneIds.contains(pane) else { return }
        for tab in self.bonsplitController.tabs(inPane: pane) {
            self.forceCloseTabIds.insert(tab.id)
        }
        _ = self.bonsplitController.closePane(pane)
    }

Note: shouldClosePane (line 11170-11171) already skips tabs whose ids are in forceCloseTabIds — pre-loading is the existing escape hatch.

Mode B (no dialog at all): not yet root-caused. Two hypotheses worth investigating:
1. The first vetoed close leaves stale state (pendingPaneClosePanelIds is removed in the veto branch but not in the success-then-veto-from-closePane path); subsequent clicks may be silently absorbed.
2. The AppKit-overlay anchor for the pane (PaneInteractionOverlayHostView → PaneCloseOverlayController) drifts on certain split-tree configurations, leaving the runtime active but the overlay unrendered. The synchronize() loop in PaneCloseOverlayController.swift:56-86 silently continues for any pane without a registered anchor.

After landing the Mode A fix, replay the reported scenario to see whether Mode B reproduces independently. If it does, instrument PaneInteractionRuntime.present and PaneCloseOverlayController.synchronize with debug logs and chase from there.

## Test plan
- Reproduce Bug A in tagged build, apply the one-line fix, rebuild via './scripts/reload.sh --tag c11-bugfix', confirm agent launches on first try with all four agent kinds.
- Reproduce Bug B Mode A by running a busy claude in a 2x2 quad pane, hit X, confirm dialog, observe veto; apply the forceCloseTabIds preload, confirm pane closes.
- After Mode A fix, attempt to reproduce Mode B (no dialog). If still reproducible, file follow-up scoped to overlay anchor lifecycle.
- Unit test: WorkspaceLayoutExecutor sendText receives command+'\n' when SurfaceSpec.command was injected via launchAgent path.
- No new tests against checked-in source text per Sources/CLAUDE.md test policy; verify observable runtime behavior.

## Files of interest
- Sources/AppDelegate.swift:5969-5976
- Sources/Workspace.swift:11167-11181, 11426-11484
- Sources/WorkspaceLayoutExecutor.swift:201-267
- Sources/c11App.swift:4032-4043
- vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift:588-607
