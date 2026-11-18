# c11 on herdr-core: feature-by-feature map

Status: exploration notes, 2026-10-30. Read-only pass over `Sources/`, `CLI/`, `Resources/bin/` and the shell integration on `main`. Sources: `docs/c11v-herdr-core.md`, the Step 0 results in `docs/c11v-design.md`, the spike report (`git show spike/c11v-manual-io:spike/c11v/prototype.md`), and herdr-core source (`crates/herdr-core/src/` in the clone named in `BRIEF.md`).

## Summary

1. **Counts.** 43 features. 5 move to hc, 20 stay in c11, 16 need a c11 sidecar and 2 break (the socket gate and TCC). Rows 13, 21 and 34 also break for federated (`studio/t7`) terminals. 35 rows are VERIFIED and 8 INFERRED.
2. **tty and pid survive locally.** c11 never gets a tty or pid from Ghostty. The shell reports its tty over the socket (`report_tty`), hooks report the agent pid, and the kernel answers everything else, so local hc terminals keep every tty and pid feature. Two conditions: the socket must admit them, and c11 must re-register ttys after its own restart.
3. **Hardest: the socket gate (row 8).** Holders don't descend from c11. "Descends from a live hc terminal's pid" makes it work again, but hc lets any same-uid process drive any terminal. That makes `c11Only` a same-uid check.
4. **Hardest: restart semantics (rows 3, 7, 11, 35).** Restore would type `claude --resume` into an agent that is still running. Quit suspends live conversations. The tty never gets re-registered. Env frozen at spawn goes stale (`C11_PANEL_NUM`, `CMUX_PORT`).
5. **Hardest: the input guard and the doorbell (rows 20, 21).** They classify the composer from cell attributes and the cursor. That needs an attached local surface at hc's size; `terminal.read` cannot replace it.
6. **Hardest: manual-IO plumbing (rows 5, 18, 25, 31, 32).** That means a non-blocking `io_write_cb`, an output thread, FOCUS and FACTS frames, resize order, child exit, and splits inheriting `io_*`. The last three are needed on any daemon path. The typing hot paths do not change; `io_write_cb` becomes a new one.
7. **Sketch is wrong (1).** "`terminal.read` for the composer check" fails: plain text loses faint, italic and truecolor cells, the cursor and wraps. Also, `terminal.read` with history scrolls alternate-screen apps with injected wheel events.
8. **Sketch is wrong (2).** "`parent_panel_id` → hc `parent`" adds a kill coupling c11 never had and can't express browser or markdown children. "tty and pid features on every host" holds only for agent classification: ports, CPU, raw mode and process-group checks have no remote equivalent.
9. **Sketch is wrong (3).** "Stops `ps -t`" misses that the same sweep runs liveness decay, prompt-cache retention and model detection. "Keeps conversation resume" needs an hc-liveness gate. "OSC 7501 emitted by the wrappers" can't work, because each wrapper `exec`s its agent.
10. **Sketch is wrong (4).** The gate "descendant of a terminal c11 placed" restores function only, not security. It must also admit terminals that agents created before c11 placed them.

## Map

Paths are under `Sources/` unless they start with `CLI/`, `Resources/`, `ghostty/` or `hc:` (herdr-core `crates/herdr-core/src/`). "Remote" means a federated `machine/tN` terminal. "Any daemon path" marks a Ghostty manual-IO gap from Step 0 result 4 that applies to hc and to a home-built `c11d` alike. Notes (N1 and on) and Sections A to E follow the table.

| # | Feature | Today (file:line) | Class | What changes in c11 | Conf |
|---|---|---|---|---|---|
| 1 | Terminal spawn | `GhosttyTerminalView.swift:3577-3578, 3825`; `Panels/TerminalPanel.swift:216-241` | moves to hc | `terminal.run` (shell or argv, cwd, env, label `c11.panel=<uuid>`) owns the process. c11 builds a manual-IO surface and attaches. N1 | VERIFIED |
| 2 | "Has a surface" used to mean "process is live" | `Workspace.swift:669, 8319-8359`; `GhosttyTerminalView.swift:4641-4670`; `TerminalController.swift:4879`; `ContentView.swift:3191-3207` | c11 sidecar | Each check uses either the hc record `state` (liveness) or attachment (screen work). Background priming attaches instead of spawning. N1 | VERIFIED |
| 3 | Environment at spawn | `GhosttyTerminalView.swift:3640-3830` (ids 3654, `C11_PANEL_NUM` 3672, socket 3682, `CMUX_PORT` 3722, PATH 3739, ZDOTDIR 3778) | c11 sidecar | Pass the same map as `terminal.run` env, plus Exec's TERM, TERMINFO and GHOSTTY_* (any daemon path). Env now outlives c11: `C11_PANEL_NUM`, `CMUX_PORT` and possibly the socket path go stale. N2 | VERIFIED |
| 4 | Initial input, `--command`, typed launch lines | `GhosttyTerminalView.swift:3832-3842, 3895`; `ghostty/src/termio/Termio.zig:336-380`; `Panels/TerminalPanel.swift:102-175`; `SocketHandlers/SocketDispatch.swift:1514-1521` | c11 sidecar | Ghostty writes `initial_input` to `io_write_cb` when its IO thread starts, maybe before the attach exists. Deliver it through hc after `terminal.run`, never on reattach. Launch lines still type into the shell. | VERIFIED |
| 5 | Child exit closes the panel | `GhosttyTerminalView.swift:2193-2224, 4126-4129`; `WorkspaceManager.swift:3478-3507` | moves to hc | hc `finished` (exit code, signal) drives `closePanelAfterChildExited`, then `terminal.rm`. Ghostty still needs `ghostty_surface_child_exited` (any daemon path). Leave `keep` off for agent terminals. | VERIFIED |
| 6 | Close panel, workspace or window; confirm; Reopen Closed Panel | `GhosttyTerminalView.swift:3410-3431`; `Panels/TerminalPanel.swift:320-348`; `Workspace.swift:8702-8707, 11990-12004`; `WorkspaceManager.swift:1205, 4548` | c11 sidecar | Freeing a manual surface kills nothing, so every close path must call `terminal.kill` or start a grace timer. Reopen for terminals is new, timed by c11, and needs an orphan reaper. N3 | VERIFIED |
| 7 | Quit, crash, force-quit, Sparkle update | `AppDelegate.swift:3230-3289, 4611-4643, 11497-11530` | c11 sidecar | Processes survive by design. Stop suspending conversation refs of live hc terminals on Quit. Fix the dialog copy ("This will close all windows and workspaces."). Add Quit and End All Terminals. | VERIFIED |
| 8 | Socket access gate (`c11Only`) | `TerminalController.swift:1164-1180, 2216-2227, 2325-2354` | breaks | Holders don't descend from c11, so every call from an hc terminal is refused. Checking descent from a live hc terminal `pid` brings the calls back, but adds no security. Remote terminals can't reach the socket at all. N4 | VERIFIED |
| 9 | `identify`, `--panel self`, `caller_panel_id`, tty attribution | `CLI/CMUXCLI+Run.swift:586-618`; `CLI/CMUXCLI+Args.swift:88-96`; `CLI/CMUXCLI+Handles.swift:772-788`; `SocketHandlers/SocketDispatch.swift:203-209`; `TerminalController.swift:2437-2459` | stays in c11 | Identity comes from env and params, not ancestry, so env injected at `terminal.run` suffices. Terminals hc started without c11's env have no identity. §A | VERIFIED |
| 10 | Lineage: `parent_panel_id`, `c11 family`, mailbox `--to-parent` | `PanelLineage.swift:20-71`; `SocketHandlers/SocketDispatch.swift:1277, 1523`; `CLI/CMUXCLI+Mailbox.swift:440-466` | stays in c11 | The creator comes from env-derived `caller_panel_id`. There is no lifecycle coupling, and lineage covers browser and markdown panels and workspaces. Don't map it to hc `parent`, which ends children; mirror it only with `outlive_parent`. | VERIFIED |
| 11 | tty registration (`report_tty`) | `Resources/shell-integration/cmux-zsh-integration.zsh:193-205`; `TerminalController.swift:10026-10114`; `Workspace.swift:1447-1451` | c11 sidecar | The shell sends it once per shell. Only the handler arms AgentDetector, PortScanner and the CPU sampler; restore doesn't. On reattach, re-register, or derive the tty from hc `pid`. N5 | VERIFIED |
| 12 | Agent detection (`ps -t`), startup probe | `AgentDetector.swift:41-49, 91-131, 240-271`; `AgentStartupProbe.swift:35-76`; `SocketHandlers/SocketDispatch.swift:1729-1745` | moves to hc | Read `foreground {pid, name, argv}` and its events (about 2 Hz, any host). The classifier stays. Re-home the 10 s sweep's riders: liveness decay, prompt-cache retention, model detection. N6 | VERIFIED |
| 13 | Port scan, per-panel CPU and memory | `PortScanner.swift:124-218`; `TerminalPIDResolver.swift:25-77`; `PanelMetricsSampler.swift:162, 254` | stays in c11; breaks remote | A local hc PTY is a local tty: `ps -t`, `lsof` and `proc_pid_rusage` keep working once the tty is re-registered (row 11). hc has no port or usage data for `studio/t7`. | VERIFIED |
| 14 | Agent PIDs, stale-PID sweep | `Workspace.swift:330, 5375-5399`; `WorkspaceManager.swift:1353-1375`; `GhosttyTerminalView.swift:2387` | c11 sidecar | Restore clears `agentPIDs` ("a PID from a prior boot is meaningless"), which is false under hc. Re-seed from hooks or `foreground` on reattach; until then OSC notifications from a live Claude go unsuppressed. | VERIFIED |
| 15 | TCC, Full Disk Access probe | `FullDiskAccessProbe.swift:37-50`; `AppDelegate.swift:8238` | breaks | The probe tests c11.app, but the shells' grants belong to whoever started the hc core: launchd, c11, or an agent's `hc` call. That can change between runs. Needs the SMAppService test. | INFERRED |
| 16 | Operator keystrokes | `GhosttyTerminalView.swift:6214-6215, 6324-6387` | stays in c11 | Ghostty encodes locally (kitty flags, IME) and hands bytes to `io_write_cb`. c11's per-key bookkeeping stays on main, before the Ghostty call. | VERIFIED |
| 17 | Typing hot paths | `TerminalWindowPortal.swift:252-282`; `ContentView.swift:12037`; `GhosttyTerminalView.swift:4031-4064` | stays in c11 | No change. `io_write_cb` joins the list. §B | VERIFIED |
| 18 | Manual-IO threading | new code; `GhosttyTerminalView.swift:2028-2035, 2177-2404` | c11 sidecar | Add a non-blocking writer behind `io_write_cb`, an output thread for `process_output`, and reattach after a core restart. No existing c11 code runs on either thread. §C | INFERRED |
| 19 | Programmatic input: send, send-key, Feed answers, resume typing | `SocketHandlers/PanelHandlers.swift:1055-1180, 1251-1312`; `TerminalController.swift:7785-7860`; `GhosttyTerminalView.swift:4145-4210, 4385` | stays in c11 | Works through the attached surface; a detached panel attaches first, as today's background start does. `terminal.send` and `terminal.keys` behave differently (3 s idle wait, refusal while `blocked`). The input transaction orders c11's writers only. | VERIFIED |
| 20 | Input guard, `input-state` | `TerminalController.swift:4237-4305`; `ghostty.h:398-433`; `Feed/PromptInputClassifier.swift:56-76, 249-258`; `SocketHandlers/PanelHandlers.swift:1131-1146, 1395` | stays in c11 | Needs faint, italic and truecolor per cell, the cursor and soft-wrap rows. `terminal.read` gives plain text. Requires an attached surface at hc's size, else `unknown`. §E | VERIFIED |
| 21 | Mailbox doorbell, stdin delivery | `Workspace.swift:6314-6392, 6940-7010, 7279-7333`; `Mailbox/MailboxStdinBuffer.swift:501-596` | stays in c11; breaks remote | The composer read and the typing use the local surface. The kernel ownership check (process group, tty device, ICANON) works on local hc PTYs once the tty and agent pid are re-learned. Remote panels fail closed. §E | VERIFIED |
| 22 | Native mailbox bridge (Claude inbox) | `TerminalController.swift:2220-2227, 2412`; `Mailbox/MailboxNativeDoorbell.swift:83-112`; `Resources/bin/claude:249-257` | c11 sidecar | Needs the new gate (row 8). Its ancestry proof (the bridge descends from the agent that owns the tty) is kernel-local and still holds. No path from remote panels. | VERIFIED |
| 23 | Text box, paste, image paste, file drop | `TextBoxInput.swift:711-740`; `GhosttyTerminalView.swift:324-340, 1185-1205, 9202-9211` | stays in c11 | All write through the local surface, so nothing changes locally. For remote panels the paths are laptop paths: `terminal.put` the file and paste the remote path. | VERIFIED |
| 24 | Kitty keyboard, mouse, IME, OSC 52, bracketed paste | Ghostty-local (spike `prototype.md` §1); `GhosttyTerminalView.swift:1185-1215` | stays in c11 | Modes arrive in the raw stream and hc's first paint. The spike passed mouse, kitty and OSC 52 write; IME and OSC 52 read are unproven. Kitty images probably don't survive a reattach. N7 | INFERRED |
| 25 | Query replies, focus and in-band resize reports, theme colors | `hc:relay.rs:1-6, 161-180`; `hc:viewers.rs:17-26, 218-232`; `hc:attach.rs:16, 298-302` | c11 sidecar | hc answers DA1, CPR and OSC 10/11/12 from the viewer's FACTS: send theme colors and cell size, and resend them on a light/dark switch. Turn Ghostty's `CSI I`/`CSI O` into FOCUS frames, or programs get two reports. N7 | INFERRED |
| 26 | `read-screen` (`panel.read_text`), tmux `capture-pane` and `pipe-pane` | `SocketHandlers/PanelHandlers.swift:1595-1690`; `TerminalController.swift:4310-4363, 4447`; `CLI/CMUXCLI+TmuxCompat.swift:632-733` | moves to hc | `terminal.read` works unattached and remote. Not identical: active screen rather than the scrolled viewport, deeper history, and with `lines > 0` on an alternate-screen app it scrolls the app. §E | VERIFIED |
| 27 | Find overlay, scrollback depth, `clear-history` | `WorkspaceManager.swift:1452-1475`; `GhosttyTerminalView.swift:2303-2338`; `SocketHandlers/PanelHandlers.swift:1341-1380` | stays in c11 | Ghostty searches its own buffer: the attach's `history: N` (main screen only) plus output since. `clear-history` clears c11's copy only; history comes back on the next attach. | VERIFIED |
| 28 | Scrollback capture and replay at restore | `Workspace.swift:1084-1100, 1231-1240, 1345-1362`; `Panels/TerminalPanel.swift:372-376`; `TerminalController.swift:4507-4575`; `SessionPersistence.swift:997-1060` | c11 sidecar | `hasLiveProcess` is always true in manual mode, so capture continues, including a pasteboard VT export at every Quit. Skip capture and replay for live hc terminals, and keep one capture for a lost holder. N8, §D | VERIFIED |
| 29 | Title, OSC 7 cwd, git probe | `GhosttyTerminalView.swift:2339-2372`; `AppDelegate.swift:13842`; `WorkspaceManager.swift:1376-1395` | stays in c11 | Actions fire from the stream, and hc's first paint carries the title. Seed the starting cwd from the record (any daemon path). Ghostty drops OSC 7 from another host: use `foreground.cwd` and skip the local git probe for remote panels. | VERIFIED |
| 30 | Bell, OSC 9/777 notifications | `GhosttyTerminalView.swift:2255-2259, 2373-2404` | stays in c11 | Backend-independent while attached, lost while c11 is down. hc keeps `status` and `turn`, so c11 can work out "finished while you were away" on reattach. | INFERRED |
| 31 | Resize and geometry | `GhosttyTerminalView.swift:3976-4016`; `Workspace.swift:12434`; `WorkspaceManager.swift:5062` | c11 sidecar | Send RESIZE frames. Ordering them against Ghostty's reflow needs the resize hook (any daemon path; the vim defect). hc sizes the PTY from the last active viewer, so a second viewer fights or letterboxes. | INFERRED |
| 32 | Split cwd and config inheritance | `Workspace.swift:35-58, 10120-10157, 10313-10320`; `GhosttyTerminalView.swift:2718-2746`; `ghostty.h:505-507` | stays in c11 | The cwd rule stays, and the source cwd can come from `foreground.cwd`. `OwnedTerminalSurfaceConfig` copies `io_mode`, `io_write_cb` and `io_write_userdata` into splits: overwrite all three on every create (any daemon path). | VERIFIED |
| 33 | Panel sheet clocks (Active, Launched, Seen, touched, turn, tools, tokens, cache) | `TabSheetDetail.swift:474-539`; `TabActivitySignals.swift:12-40`; `Conversation/PanelActivity.swift:21-56`; `GhosttyTerminalView.swift:4105-4122` | stays in c11 | Viewer state plus transcript reads. Launched can take hc `created_ms`. touched and `PanelActivityTracker` never see input from other hc clients. A history replay under one screen stamps a false Active. | VERIFIED |
| 34 | Model detection, prompt cache | `AgentModelDetection.swift:1382-1415`; `AgentDetector.swift:115-129`; `PromptCacheReports.swift:75-99` | stays in c11; breaks remote | Reads transcripts in the local home by conversation ref and cwd, and reports arrive over the socket (row 8). For remote panels: `file.read on:` or nothing. | VERIFIED |
| 35 | Conversation resume, session-resume wrappers | `Workspace.swift:383-410, 525-583, 650-671, 777-949`; `Resources/bin/claude:54-56, 110-132, 182-205, 298-301` | c11 sidecar | Restore would type `claude --resume` into an agent that is still running. Skip resume while the hc terminal is live, and resume only fresh terminals. Wrappers choose hooks once, at launch. N9 | VERIFIED |
| 36 | `conversation capture-runtime` | `CLI/CMUXCLI+Conversation.swift:124-158`; `TerminalController.swift:4845-4886` | stays in c11 | Env identity (`C11_PANEL_ID`, `CODEX_THREAD_ID`) suffices. `surface_not_live` must read hc state (row 2), so hidden panels still accept captures. | VERIFIED |
| 37 | Lifecycle status (working, idle, blocked; shell state) | `Workspace.swift:8585-8590`; `AgentDetector.swift:102-112`; `Resources/shell-integration/cmux-zsh-integration.zsh:207-218` | c11 sidecar | Reported over the socket today. Map hc `status` and `turn` (OSC 7501), which survive c11 downtime, when programs emit them. The wrappers can't emit them. N10 | INFERRED |
| 38 | Events stream, journal | `Events/EventEmitter.swift:119, 332, 518`; `CLI/JournalCommand.swift:38-56`; `Journal/JournalCoordinator.swift:254, 285` | stays in c11 | Both describe c11's model. Journal appends spool on any socket failure and drain later; other agent verbs are lost while c11 is down. Map hc `created`, `lost`, `restarted` and `finished` into panel events. | VERIFIED |
| 39 | Flags, delegates | `AttentionModel.swift:31, 208-232` | stays in c11 | No process assumptions. The rule that releases a delegate whose owner "did not return during restore" should wait until agent-created terminals are placed. | VERIFIED |
| 40 | Session snapshot and restore | `Workspace.swift:1060-1100, 1336-1365, 1425-1451`; `SessionPersistence.swift:334, 425` | c11 sidecar | Record machine and address (or look up the label `c11.panel=<uuid>`). Attach instead of spawning; use a fresh terminal if it is gone. An older c11 restores a fresh shell and orphans the hc terminal. N11 | VERIFIED |
| 41 | Layout executor, plan capture, blueprints, default grid | `WorkspaceLayoutExecutor.swift:163, 292-330, 1150-1165`; `WorkspacePlanCapture.swift:244-248`; `c11App.swift:4159-4260`; `SocketHandlers/PaneHandlers.swift:519-526` | c11 sidecar | Create terminals with `terminal.run`, then send commands. Plan capture's `requestedWorkingDirectory` maps to the record's `cwd`. Swap placeholders start real processes, which must be killed rather than freed. | VERIFIED |
| 42 | AppleScript, tmux shim, debug verbs | `AppleScriptSupport.swift:457-470, 518-552`; `CLI/CMUXCLI+TmuxCompat.swift:877-887, 971-987`; `SocketHandlers/DebugHandlers.swift:315` | stays in c11 | Thin layers over panel verbs that inherit row 6's close and row 26's read semantics. `respawn-pane` could become `terminal.kill` plus `terminal.run`. | VERIFIED |
| 43 | Remote workspaces (`c11 ssh`) | `Workspace.swift:9643-9684, 10304-10311`; `WorkspaceManager.swift:1385-1393` | moves to hc | A remote terminal becomes `studio/t7` through `machine.add` and survives link drops, replacing a local `ssh -tt`. The browser proxy (`c11d-remote`) stays. "Remote" becomes a per-panel host, not a workspace setting. | INFERRED |

## Notes

**N1 (rows 1, 2).** Today the process starts when the surface does: when the view enters a window (`GhosttyTerminalView.swift:3578`), or when a background start forces it through an offscreen bootstrap window (4641-4670). "Has a surface" and "has a process" are therefore the same fact, and several checks rely on it:
- `isUntouchedShell` (`Workspace.swift:669`)
- the mailbox gate's `surfaceAttached` (`Workspace.swift:7293`)
- `LaunchPostBootSequence.isReady` (`Panels/TerminalPanel.swift:113-116`)
- capture-runtime (`TerminalController.swift:4879`)
- `hasLoadedTerminalSurface` and the workspace handoff (`Workspace.swift:8355-8359`; `ContentView.swift:3191-3207, 3530-3539`)

With hc each check must choose: process liveness from the record, screen work from attachment. Because hc keeps the screen, c11 can also stop feeding hidden panels and reattach on reveal. That trades a first-paint replay per reveal for memory and CPU across hundreds of terminals.

**N2 (row 3).** The env to pass is every managed key in `createSurface` (`GhosttyTerminalView.swift:3640-3800`), plus launch env such as `plan.env` (`SocketHandlers/SocketDispatch.swift:1527`). Exec adds TERM, TERMINFO, COLORTERM, TERM_PROGRAM and GHOSTTY_* on its own (any daemon path). Values frozen into a process that now outlives c11:
- **`C11_PANEL_NUM`.** It is the ordinal of a `panel:N` ref minted per app launch and never persisted (`TerminalController.swift:3137-3145, 3190-3193`). After a c11 restart, `panel:$C11_PANEL_NUM`, the form the c11 skill teaches, can name another panel.
- **`CMUX_PORT`.** It comes from `WorkspaceManager.nextPortOrdinal`, a static counter that resets every launch (`WorkspaceManager.swift:991, 1574`). New workspaces get ranges that surviving shells already hold.
- **`C11_SOCKET_PATH`.** It is whatever path the listener bound (`TerminalController.swift:704-709`). If a later launch falls back to another path (C11-155), surviving shells, wrappers and hooks dial a dead socket.
- **Terminals started without c11.** Anything started by an agent's `hc run` or by herdr-app has none of this env, so it has no identity, no wrappers and no shell integration.

**N3 (row 6).** `teardownSurface` frees the surface on the next main turn "so SIGHUP delivery is deterministic" (`GhosttyTerminalView.swift:3410-3431`): in exec mode, freeing is the kill. Freeing a manual surface signals nothing (spike desk-check). So each of these becomes a detach unless c11 calls `terminal.kill`:
- panel, workspace and window close
- AppleScript close (`AppleScriptSupport.swift:457-470`)
- swap placeholders (`SocketHandlers/PaneHandlers.swift:519-526`)
- any deinit

hc drops finished terminals a day after they end (`hc:terminals.rs:364-367`) but keeps live ones forever. A crash during a grace period therefore leaves live orphans, and the next launch must reap `c11.panel` labels that no snapshot panel claims. Reopen Closed Panel exists only for browsers today (`WorkspaceManager.swift:1205, 4548`).

Close confirmation uses the shell's reported state first, then Ghostty's prompt marks (`Workspace.swift:8702-8707`). After a reattach the state is unknown, and the first paint probably carries no OSC 133 marks, so every close asks until the next prompt. A better fallback is hc `foreground`: is the shell in front?

**N4 (row 8).** The gate admits a peer only if its ancestry reaches c11's pid (`TerminalController.swift:1164-1180, 2330-2338`). Holders descend from the hc core. If c11 spawned the core, they count only until c11 restarts; if the core detaches, they never count. Every call from an hc terminal is then refused with "only processes started inside c11", which covers shell-integration reports, hooks, wrapper calls and the native mailbox bridge. Journal appends survive, because the CLI spools on any error (`CLI/JournalCommand.swift:47-56`).

The replacement walks the peer's ancestry to the `pid` of any live terminal in c11's hc session, refreshing the pid set on `created`, `restarted` and `finished`. Its limits:
- Any same-uid process can `hc run` a terminal to become a "descendant", or `hc send` into an existing one. In practice this equals `allowAll` behind a 0600 socket.
- Daemonized descendants fail, as they do today.
- Terminals c11 has not placed yet must count too.
- Remote terminals can't reach the socket at all.

hc puts an `HC_SCOPE` token in each terminal's environment that even session-leaving descendants keep (`hc:sweep.rs:1-9`). It is internal record bookkeeping (`hc:terminals.rs:397`), and an environment can be forged.

**N5 (row 11).** The shell reports its tty once per shell (`_CMUX_TTY_REPORTED`, `cmux-zsh-integration.zsh:196-201`). Only the handler arms AgentDetector, PortScanner and the CPU sampler's pid provider (`TerminalController.swift:10046-10056, 10106-10112`). Restore copies the saved `ttyName` into `panelTTYNames` and does nothing else (`Workspace.swift:1447-1451`).

After a c11 restart over live hc shells, the result is: no agent detection, no ports, and CPU and memory shown as `—`. AgentDetector's sweep also cancels itself when it has no ttys (`AgentDetector.swift:94-101`), so liveness decay, prompt-cache retention and model detection stop as well. `report_shell_state` is sent only on change, so the shell state stays `.unknown` until the next prompt.

Fix on reattach: re-register the saved tty. For argv terminals without shell integration, read it from the record's `pid` (`proc_pidinfo` `e_tdev`, the same call as `TerminalController.swift:2437-2444`).

**N6 (row 12).** hc's `foreground` is the foreground process-group leader, which is the process `runPS` picks (pid equals tpgid, `AgentDetector.swift:262-266`). `name` and `argv` cover the classifier's inputs (`AgentDetector.swift:209-222, 324-380`). Only the `proc_pidpath` refinement and Kimi's session lookup by pid stay local-only. The startup probe can wait for a `foreground` event instead of polling the tty.

**N7 (rows 24, 25).** hc's screen answers DA1, cursor position and OSC 10/11/12 itself and strips them from viewer bytes (`hc:relay.rs:1-6, 161-180`). It answers from the active viewer's `display` facts: fg, bg, cursor color and cell size (`hc:viewers.rs:17-26`). The hc CLI gathers those by asking its outer terminal (`hc:attach.rs:16`). c11 must send them from its own theme and resend them when the light and dark slots switch; otherwise programs that pick colors from OSC 11 see hc's defaults.

Focus is the second trap. c11's Ghostty writes `CSI I`/`CSI O` to `io_write_cb` once a program sets mode 1004, and hc writes them again on a FOCUS frame (`hc:viewers.rs:218-232`). The hc CLI converts them into FOCUS frames (`hc:attach.rs:298-302`), and c11 must do the same. XTGETTCAP and in-band resize (mode 2048) reports still come from c11's Ghostty.

Kitty graphics: hc's screen takes the image commands and drops its own replies, and the viewer answers (`hc:relay.rs`, test `images_are_answered_by_viewers_only`). Images therefore show live but are probably missing after a reattach.

**N8 (row 28).** The path runs `shouldPersistScrollbackForSessionSnapshot` → `hasLiveProcess` → `!ghostty_surface_process_exited` (`Panels/TerminalPanel.swift:372-376`; `GhosttyTerminalView.swift:4126-4129`). In manual mode that stays true until the child-exit hook exists. Capture uses `write_screen_file:copy,vt`, which round-trips through the general pasteboard (`TerminalController.swift:4507-4545`), at every clean quit (`includeScrollback: true`, `AppDelegate.swift:4631-4643`).

Replay writes a temp file and hands it to the new shell as `CMUX_RESTORE_SCROLLBACK_FILE`, which the shell `cat`s (`Workspace.swift:1345-1362`; `cmux-zsh-integration.zsh:27-30`). The spike saw history printed twice. A reattach starts no shell, so the env is ignored, but the temp file is still written.

**N9 (row 35).** The restore path runs `scheduleAgentRestart` → `dispatchRestartCommands(..., idleShellRequired: false)` (`Workspace.swift:777-797`) → `submitResume` → `isUntouchedShell` (`Workspace.swift:650-671`). By design that function "also accepts an attached shell that has not reported its state yet". After a restart there has been no operator key, and the shell state is `.unknown` because it isn't persisted (`Workspace.swift:5346`). `resumeActionBeforeSubmission` only checks other panels for the same conversation (`Workspace.swift:677-695`). A reattached panel still running `claude` would therefore get `claude --resume <id>` pasted into its composer and submitted.

Quit also suspends every live conversation ref (`AppDelegate.swift:4631-4634`), which is what makes refs resumable. With hc:
- skip resume for live hc terminals and record a `reattached` outcome;
- keep refs alive on Quit;
- resume only fresh terminals, such as after a lost holder or a reboot.

Wrappers decide at launch (`IN_C11` from `CMUX_SURFACE_ID` plus a socket ping, `Resources/bin/claude:54-56, 110-132`) and then `exec`. An agent started while c11 was down runs its whole life without hooks.

**N10 (row 37).** The wrapper's last act is `exec "$REAL_CLAUDE"` (`Resources/bin/claude:298-301`), so it can't report anything during the session. Turn edges come from hooks over the socket. A hook could emit OSC 7501 only by writing to the controlling tty while Claude's TUI is drawing on it. Interleaving there is a risk (INFERRED).

**N11 (row 40).** Swift's `Codable` ignores unknown keys, so an older c11 reads a new snapshot and restores the panel as a fresh shell, as rule 5 of `docs/c11v-design.md` asks. The hc terminal keeps running unseen until something reaps it. hc's `keep` replaces a lost program with the machine's shell "in place" (`hc:terminals.rs:20-23`). That gives "fresh shell at the last cwd after a reboot" for free, but `keep` must stay off for terminals that should end when c11 closes them.

## A. Callers identified by tty or ancestry

| Feature | Identifies the caller by | With env set at `terminal.run` plus a gate on descent from the record `pid` | Enough? |
|---|---|---|---|
| Socket gate, `c11Only` | Peer pid ancestry up to c11 (`TerminalController.swift:2330-2338`) | Ancestry up to any live terminal `pid` in c11's session | For function yes, locally. Not as security (N4). No for remote. |
| `identify` | Env `C11_PANEL_ID`, `C11_WORKSPACE_ID` sent as `caller` (`CLI/CMUXCLI+Run.swift:586-618`) | Env injected | Yes, once the gate admits. `C11_WORKSPACE_ID` goes stale when a panel moves, as today. |
| `--panel self`, `--workspace self` | Env (`CLI/CMUXCLI+Handles.swift:772-788`) | Env injected | Yes. `panel:$C11_PANEL_NUM` does not survive a c11 restart (N2). |
| `caller_panel_id` (lineage, flags, launch) | Env sent as a param (`SocketHandlers/SocketDispatch.swift:203-209`) | Env injected | Yes. |
| Mailbox `--to-parent` | Env plus `panel.family` (`CLI/CMUXCLI+Mailbox.swift:440-466`) | Env injected | Yes. |
| `conversation capture-runtime` | Env plus `surface != nil` (`TerminalController.swift:4879`) | Env plus the hc record `state` | Yes, after the liveness change. |
| Native mailbox bridge | Peer ancestry to the agent pid, which owns the panel tty (`Mailbox/MailboxNativeDoorbell.swift:83-112`) | Unchanged | Yes, locally: kernel facts. No for remote. |
| Doorbell ownership | Registered agent pid; process group equals the tty's foreground group; tty device equals the panel tty; ICANON off (`Mailbox/MailboxStdinBuffer.swift:528-596`) | Needs the re-learned tty and agent pid (rows 11, 14) | Yes, locally. No for remote: hc gives the leader pid, not termios or the tty. |
| `workspace.switch_blocked` attribution | Peer tty device matched against `panelTTYNames` (`TerminalController.swift:2437-2459`) | Needs the re-learned tty | Yes, locally. |

## B. Typing hot paths

None of the three changes.
- `WindowTerminalHostView.hitTest` (`TerminalWindowPortal.swift:252-282`) routes pointer events over AppKit views and does no terminal I/O.
- `WorkspaceRowView` (`ContentView.swift:12037`) compares precomputed values. A host badge would add one `let` and one `==` term.
- `TerminalSurface.forceRefresh` (`GhosttyTerminalView.swift:4031-4064`) reasserts the display id and calls `ghostty_surface_refresh` on the local renderer. The spike's stale frame after resize may call for one refresh after a RESIZE frame, which is not per keystroke.

The new per-keystroke cost is `io_write_cb` on Ghostty's IO thread. It takes the same rules: no allocation, no lock beyond a bounded queue, no main.

## C. Threading under manual IO

**What reaches `io_write_cb`:**
- keystrokes
- programmatic text (send, doorbell, text box, resume, drop and paste)
- `initial_input` when the IO thread starts (`ghostty/src/termio/Termio.zig:336-380`)
- mouse and kitty encodings
- focus and mode-2048 reports
- OSC 52 read replies
- any query hc did not answer

It runs on the IO thread, sometimes under the renderer lock. It must enqueue and return: no `ghostty_surface_*` call, no hop to main, no per-byte allocation. c11's per-input bookkeeping (`lastOperatorKeyAt`, `PanelActivityTracker`, input transactions, `emitPanelInputSent`) already runs on main before the Ghostty call and stays there.

**Output side:** a reader thread feeds `ghostty_surface_process_output` in bounded chunks, never from main and never from inside `io_write_cb`. The userdata must outlive `ghostty_surface_free`, which joins the IO thread. No existing c11 code sits on either thread.

**Actions caused by output** (title, pwd, bell, notification, scrollbar, color) are delivered by Ghostty on the app thread (INFERRED). c11's handlers already hop to main asynchronously (`GhosttyTerminalView.swift:2177-2404`). `performOnMain` falls back to `DispatchQueue.main.sync` when called off main (`GhosttyTerminalView.swift:2028-2035`), so it must never be reachable from the reader thread.

**Main-thread stalls:** when the app mailbox is full, `process_output` waits on main, so a main-thread hang freezes every attached terminal's display. Unlike exec mode, the programs keep running. A core crash ends every attach stream; c11 reattaches after `restarted` and resends size and FACTS.

## D. Scrollback

- **Nothing depends on scrollback c11 restored itself**, beyond its presence. Find and `read-screen` read whatever is in Ghostty's buffer, and replayed text looks the same to them as attach history.
- **`hasLiveProcess` has one consumer:** the snapshot capture (`Workspace.swift:1084`). It is always true in manual mode (N8).
- **`restoredTerminalScrollbackByPanelId`** is a fallback for the next snapshot when a restored panel never went live (`Workspace.swift:1231-1240`).
- **`ScrollbackGrowthTracker`** treats a jump from empty history larger than one screen as a new baseline (`TabActivitySignals.swift:12-40`). Attach history stamps Active only when it is shorter than a screen.
- **Depth becomes a per-attach choice.** `history: N` covers the main screen only, and hc flags full-screen apps whose history the app keeps to itself.

## E. read-screen, input-state and the doorbell: `terminal.read` or the local surface

The two copies hold the same VT state only while c11's surface is attached, current and at hc's size. The local copy lags hc by one stream hop.

| Read | Local Ghostty surface (today) | hc `terminal.read` | Same result? |
|---|---|---|---|
| `read-screen`, default | The viewport, including the operator's scroll position (`TerminalController.swift:4447`) | The active screen | Same text when the panel isn't scrolled back. Differs when it is. |
| `read-screen --scrollback` or `--lines N` | Screen, history and active area from Ghostty's buffer (`TerminalController.swift:4310-4363`): attach history plus output since | Screen plus N lines from hc's model. On an alternate-screen app with `lines > 0`, hc scrolls the app with wheel events to stitch history (`hc:api.rs:334-341`; `hc:stitch.rs:166-170`) | Same for main-screen programs within both depths. Read deeper with hc. Pass `lines: 0`, or read locally, for alternate-screen apps. |
| Unattached panel | Waits up to 2 s and forces a surface (`SocketHandlers/PanelHandlers.swift:1640`) | Works | hc is better for hidden and remote panels. |
| `input-state`, send guard, doorbell composer | `ghostty_surface_try_read_prompt_region` and `_bottom`: rows with soft-wrap flags; cells with faint, italic and truecolor fg/bg; cursor x/y (`ghostty.h:398-433`) | Plain text rows | No. Claude's faint suggestion, Grok's italic one (`Feed/PromptInputClassifier.swift:56-60, 249-258`), Codex's colored composer and the cursor all vanish. A suggestion then reads as a draft, which blocks sends, or a draft reads as empty, which is unsafe. |
| Doorbell ownership | Kernel: process group, tty device, ICANON | `foreground.pid` only | Partly. Keep the kernel check locally; remote fails closed. |
| hc's own send guard | None | `terminal.send` waits for about 3 s with nobody typing, refuses `blocked` unless `force`, and supports an `if` status precondition | Turn-based, not composer-based. It complements c11's guard; it doesn't replace it. |

## Where `docs/c11v-herdr-core.md` is wrong or incomplete

1. **Line 58, "`terminal.read` for the composer check".** The classifier needs cell attributes, the cursor and wrap flags (§E). It must stay on the local surface, or hc must add a cell read. `terminal.read` with history also scrolls alternate-screen apps.
2. **Line 53, "`parent_panel_id`, lineage → hc's `parent`".** c11 lineage records only who created a panel. Closing a panel closes no children (`PanelLineage.swift:47-71`). Lineage also spans browser and markdown panels and workspaces, which hc can't represent. Keep lineage in c11; mirror it only with `outlive_parent`.
3. **Line 57, "Agent detection, tty and pid features → … on every host".** Only detection moves. Ports, CPU and memory, ICANON and process-group ownership have no hc field. Locally they keep working through the kernel once ttys are re-registered (row 11).
4. **Line 67, "Stops `ps -t` detection".** The same 10 s sweep drives liveness decay, prompt-cache retention and model detection (`AgentDetector.swift:102-129`). Those three need a new timer.
5. **Line 67, the gate becomes "the peer is a descendant of a terminal c11 placed".** That restores function but not security, because hc has no per-client auth. The gate must also admit terminals c11 has not placed yet (N4).
6. **Line 65, "Keeps … conversation resume".** Without an hc-liveness gate, restore types `claude --resume` into live agents, and Quit keeps suspending refs (N9).
7. **Line 55, "OSC 7501, emitted by c11's session-resume wrappers".** The wrappers `exec` their agent and are gone; only hooks remain (N10).
8. **Line 67, "Stops: restoring scrollback for hc terminals".** Right for a reattach. Keep one capture as the fallback for a lost holder (reboot), or accept losing history then.
9. **Lines 49-50, identity through the label.** Correct, but the sketch misses that env frozen at spawn goes stale across c11 restarts: `C11_PANEL_NUM`, `CMUX_PORT` and possibly the socket path (N2).
