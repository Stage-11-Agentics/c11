# Independent audit of the bug-sweep ledger (Fable)

2026-10-01. Read-only. Sources: ledger `LEDGER.md` / `LEDGER.tsv` (368 rows, verified at c11 `d63b937f`), c11 `origin/main` (`0ff8887e`, 36 commits ahead of the ledger's head, including the C11-248 Surface/Panel → Tab renames), cmux `upstream/main` (`920ff39f`), c11 Ghostty `26c3e499e`, the manaflow Ghostty fork for the cited fix commits. Every c11 line number below is on `origin/main` unless marked "ledger line". Ledger line numbers no longer map: the rename moved almost every cited line, so each fix ticket must relocate its target before it starts.

Rulings applied: everything ships in 1.0 (no point releases), GPU reclaim only on a clear bug, no sidebar rewrite, sizes are relative (S/M/L).

## 1. Verdict in five lines

1. **30 must do, 111 nice to have, 223 not a priority, 4 rejected** (already fixed on `origin/main`: B009, B051, B073, B081).
2. Spot-checked 40 shared-confirmed rows: 32 held, 3 overturned, 5 downgraded. The verifiers read code accurately; their main error is severity inflation, and the ledger did not account for the 36 commits that landed after its head.
3. **The single most important fix is the Ghostty shared-mailbox trap**, as one submodule bump: bounded drain (B065), non-parking producer pushes (B010 and the 08-25 root), latest-value focus and visibility publication (B031), atomic paste (B013), the write-pool fix (B047), and the bounded child shutdown (B062). One patch set retires six must rows and closes every known door into the 2026-08-25 freeze.
4. The second cluster is the cold-terminal start path (B003, B087), which is the most likely root of C11-130, C11-169 and C11-235.
5. Of the known c11 problems, main-thread congestion (C11-197, C11-202, C11-205) has the most rows pointing at it, but most are S fixes to specific producers (B030, B056, B061, B012), not the sidebar. Measure the sidebar as D21 says; do not start there.

## 2. Spot-check results

Checked 40 shared-confirmed rows, weighted to high severity and to the Grok batches (`input-b`, `render`, `sidebar`, `socket-layout-perf`, `perf-supplement`: 22 of the 40). Method: read the upstream diff or commit, then located the same logic on `origin/main` by grep (the ledger's lines are stale after C11-248).

**Held (32):** B001, B002, B003, B005, B006, B007, B010, B012, B013, B016, B019, B023, B024, B027, B029, B030, B031, B033, B042, B044, B056, B058, B059, B060, B061, B062, B064, B065, B086, B087, B189, B205.

Notable confirmations:
- B002: `sendKeyEvent` still forces `unshifted_codepoint = 0` and sends press only, `Sources/TerminalController.swift:6584-6606`; the ctrl table at `:6829-6832` carries no text.
- B003: `guard headlessStartupWindow == nil else { return }` at `Sources/GhosttyTerminalView.swift:2930`; the only release is when the view reaches a real window, `:2964-2970`.
- B005: `enforceSingleInstance` terminates and then force-terminates every process with the bundle id, `Sources/AppDelegate.swift:13136-13146`. `isTerminated` is read immediately after `terminate()`, so the force path is the normal path.
- B007: every v2 command runs `v2MainSync { v2RefreshKnownRefs() }` at `Sources/SocketHandlers/SocketDispatch.swift:972`; the walk at `Sources/TerminalController.swift:2632-2650` has no restore guard.
- B010: the autosave timer is a main-queue `DispatchSourceTimer`, `Sources/AppDelegate.swift:4151-4160`; the path `Sources/Workspace.swift:821` → `Sources/Tabs/TerminalTab.swift:296` → `Sources/GhosttyTerminalView.swift:3960` → `ghostty/src/Surface.zig:967-969` locks `renderer_state.mutex`.
- B013: `completeClipboardPaste` queues one `writeReq` per encoded vector, `ghostty/src/Surface.zig:6318-6323`, so fence, payload and fence are separate IO messages.
- B023: the zsh HEAD watch is `while true; do sleep 1 ... done &!` with no parent check, `Resources/shell-integration/cmux-zsh-integration.zsh:502-512`.
- B024: `Dictionary(uniqueKeysWithValues:)` over snapshot panels at `Sources/Workspace.swift:275`.
- B062: `killCommand` loops `killpg(SIGHUP)` → `waitpid(WNOHANG)` → sleep 10 ms with no deadline or SIGKILL escalation, `ghostty/src/termio/Exec.zig:1161-1185`.
- B065: `while (self.mailbox.pop())` at `ghostty/src/App.zig:238-239`.
- B086: `v2SurfaceReadText` runs the whole read and base64 encode inside `Task { @MainActor }` and the socket worker waits on a semaphore with no timeout, `Sources/SocketHandlers/SurfaceHandlers.swift:1111-1176`.
- Ghostty rows: all 92 cited Ghostty fix commits exist in the local manaflow fork and none is an ancestor of c11's Ghostty head (checked with `merge-base --is-ancestor`). The Ghostty batches are structurally sound.

**Overturned (3), all already fixed on `origin/main`:**
- **B009** (blank `--workspace` on close-surface closes the focused surface). `close-tab` now calls `rejectEmptyTargetFlags` first, `CLI/c11.swift:2627`, which throws on an empty `--window`, `--workspace`, `--area` or `--tab` (`:11881-11889`). Landed with the close-safety work (#469, #472).
- **B051** (quit from the app switcher bypasses Warn Before Quit). `applicationShouldTerminate` now runs `QuitConfirmationPolicy.shouldConfirm` and presents the confirmation sheet on every quit path, `Sources/AppDelegate.swift:3087-3112` (#456 "Confirm every quit").
- **B081** (`closePanel` fallback closes an unrelated tab). The fallback is now gated on `targetIsActive` (the target is the focused panel or the first responder) before it touches the focused pane's selected tab, `Sources/Workspace.swift:8829-8832`.

**Downgraded (5), mechanism present but severity or scope wrong:**
- **B032** (focus broadcast re-entrancy, 426 s hang upstream). The synchronous post inside the selection mutation is still there, `Sources/Workspace.swift:11329-11336`, but the re-entering half is gone: the ContentView observer at `Sources/ContentView.swift:2623-2629` no longer calls `focusTab`, and none of the other eight observers (`Sources/WorkspaceManager.swift:1154-1163` marks read; six in `AppDelegate.swift`) mutates focus. No cycle exists on `origin/main`. Nice to have as hygiene (defer and coalesce the post), not a must.
- **B046** (one snapshot file, no history). `origin/main` archives the previous session file to `session-history/` before the first overwrite of each process and keeps 10 copies, `Sources/SessionPersistence.swift:566, 586-631` (#467). A poorer relaunch no longer erases the layout permanently. What is missing is the hold-back of poorer writes and a restore-from-history picker. Nice to have.
- **B066** (unresolvable explicit socket targets fall back to the focused pane). Destructive verbs now fail closed through `v2RejectUnresolvedTargetRefs`, `Sources/TerminalController.swift:2717`, wired at `Sources/SocketHandlers/SurfaceHandlers.swift:40` (close) and `:1066` (clear). Split (`:316`) and `read_text` (`:1137`) still fall back. Downgrade high → med; nice to have.
- **B026** (`GhosttyApp.shared` re-entered during `ghostty_app_new`). The shape is real: `static let shared = GhosttyApp()` at `Sources/GhosttyTerminalView.swift:862`, `action_cb` calls `GhosttyApp.shared.handleAction` at `:1074-1076`, and `ghostty_app_new` runs inside that init at `:1173`. But c11 launches thousands of times without tripping it, so today's Ghostty fires no action during app creation. Not a priority until the Ghostty bump, and then a one-line guard.
- **B017** (close shortcut targets a stale event window). `mainWindowForShortcutEvent` prefers `event.window` over the key window, `Sources/AppDelegate.swift:6633-6645`. A keyboard event's window is the key window at dispatch time; the stale case needs a queued event across a window change. Rated high; it is low.

Also rejected: **B073** (shared-probable, nested quit modals). `pendingQuitConfirmation` serializes repeated quit requests onto one sheet and answers with `.terminateLater`, `Sources/AppDelegate.swift:3093-3106`. Inferred fixed by #456.

**Pattern in the errors.** Both Grok and Codex verifiers read the code they cite correctly. The overturns all come from one cause: the ledger was verified against `d63b937f` and `origin/main` moved 36 commits, including the close-safety and quit-confirmation PRs. The downgrades come from rating a mechanism "high" when its trigger is rare or its re-entering half is gone. Before any ticket is cut from this ledger, the writer should diff the cited logic against `origin/main`, not trust the ledger line.

## 3. Must do

Size is relative. Risk column: **TL** = touches a typing-latency path (CLAUDE.md hot paths), **DL** = can introduce a new deadlock if done wrong, **SM** = Ghostty submodule bump (fork branch, push first, checksum cycle).

| Ledger id | Bug | Cluster | Why must | Size | Risk |
|---|---|---|---|---|---|
| B065 | Ghostty drains the app mailbox without bound on main (`ghostty/src/App.zig:238`) | C1 mailbox trap | Input starvation under many streaming agents; keeps the trap in B010 armed | S | SM, TL (tick timing changes; soak with 30 streaming panes) |
| B010 | Autosave `needs_confirm_quit` takes `renderer_state.mutex` on main every 8 s while a reader may be parked on the full mailbox | C1 | A second door into the 08-25 deadlock, with no close involved; plausible 07-28 cause (inferred) | M | DL (the app half is S: read `ghostty_surface_process_exited`; the Ghostty half is the non-parking push) |
| B031 | Focus and visibility push `.forever` into the renderer mailbox (`ghostty/src/Surface.zig:3336, 3352`) | C1 | Third door: main parks if the renderer thread is stalled behind the same mutex chain | M | SM, DL (must be latest-value publication, never `.instant` drop) |
| B013 | Bracketed paste is three IO messages; a terminal reply can land inside | C1 | Every `c11 send` into Claude Code is exposed; the TUI then swallows Enter and Ctrl+C | S | SM |
| B047 | Write-request pool requires in-order return; out-of-order drops bytes from large sends | C1 (same bump) | Grok measured 1.6 to 1.8 KB dropped per first burst: multi-line briefs to agents arrive truncated | M | SM (MemoryPool cherry-pick) |
| B072 | libxev pops the queued write on `WouldBlock` | C1 (same bump) | Same symptom as B047 for large sends and pastes; probable, verify in the same ticket | M | SM |
| B204 | `Surface.setSelection` use-after-free | C1 (same bump) | Crash; a clean Ghostty cherry-pick | S | SM |
| B062 | Surface close waits forever for a child that ignores SIGHUP (`Exec.zig:1161-1185`) | C3 child lifecycle | A hang on close with no recovery; frequent tab close is the profile | M | SM, DL (bounded wait then SIGKILL; must not kill intended survivors) |
| B022 | Descendants and foreground jobs survive surface shutdown | C3 | Unbounded orphan growth over days with 40 agents that spawn subprocesses; 16 GB users | M | SM (port with the later safety constraints, per ledger note) |
| B003 | Cold terminal loses its bootstrap window and never gets a PTY (`GhosttyTerminalView.swift:2930`) | C2 cold start | Very likely root of C11-130, C11-169, C11-235; queued `send` never flushes | M | DL (re-adopt parked hosts; portal code) |
| B087 | `read_text` on a never-shown terminal returns an error instead of starting it (`TerminalController.swift:3454`) | C2 | Read half of the same incidents; Overwatch reads cold tabs constantly | S | none (reuse the send-path helper) |
| B012 | Pending background loads raise the mount cap with no ceiling (`ContentView.swift:3043`; `workspace.create` passes `eagerLoadTerminal: !focus`, `SocketDispatch.swift:1303`) | C5 congestion | An orchestrator creating 20 unfocused workspaces mounts 20 live SwiftUI trees at once | S | none |
| B030 | One main-queue `tick()` per Ghostty wakeup, scrollbar posted inline (`GhosttyTerminalView.swift:1069, 2161`) | C5 | Direct feeder of the minutes-deep main queue in C11-197/202/205 | S | TL (coalesce, do not delay the first tick) |
| B061 | Spinner-only titles are published as real title changes (`:2219-2235`) | C5 | Forty agents means a steady main-queue metadata write stream | S | none |
| B056 | Every `NSWindow.didUpdateNotification` re-arms a full-window layout flush over all windows (`Workspace.swift:10137, 10238`) | C5 | Profiled 254 to 512 ms hangs upstream per scroll tick | S | DL-lite: port the bounded retry and backoff with it or repairs strand |
| B059 | Sidebar body re-walks every workspace and tab with store reads (`ContentView.swift:8535-8600`) | C5 | The path in the 62-minute stall. **Gated by D21: measure first; snapshot isolation only if the measurement convicts it; no rewrite** | L | TL (TabItemView Equatable contract) |
| B086 | `read_text` formats scrollback on main and holds a worker on a semaphore with no timeout (`SurfaceHandlers.swift:1111-1176`) | C5 and C1 | Heavy `read-screen` traffic; also takes `renderer_state.mutex` on main (Ghostty `dumpText`, `Surface.zig:1921`), another door into C1 | M | DL (snapshot on main, format off main) |
| B007 | A v2 command during restore walks the half-built tree on main (`SocketDispatch.swift:972`) | C4 restore safety | Crash at launch when restored agents' wrappers ping at once | S | none (readiness guard) |
| B246 | Restored terminals start before the socket listens | C4 | Same window as B007: restore-time CLI calls fail; fix together as one "socket readiness" ticket | M | none |
| B005 | A second copy of the app force-kills the running fleet (`AppDelegate.swift:13136-13146`) | C4 | Fleet loss with no save; one stray `open` is enough | S | none (yield to the older instance, or ask) |
| B024 | Duplicate panel ids trap restore (`Workspace.swift:275`) | C4 | One bad snapshot blocks recovery of the whole fleet | S | none |
| B019 | `closeWorkspace` tears down before checking membership (`WorkspaceManager.swift:2624-2636`) | C4 | Cross-manager close kills another window's agents | S | none |
| B058 | Short refs restart at 1 after relaunch (`TerminalController.swift:2504-2516`) | C6 ref safety | A cached `tab:292` sends to or closes the wrong restored agent. This is grab-list 4.2 (D15); one ticket, not two | M | none |
| B002 | `send-key ctrl+c` is keycode plus Ctrl with no text or release; Kitty-protocol TUIs drop it | C6 | An orchestrator cannot interrupt Claude Code or Codex | S | TL-adjacent (key encoding; test both TUIs) |
| B028 | Every Claude Stop reads and parses the whole transcript | C9 hooks | Cost grows with multi-day sessions, per turn, per agent | S | none |
| B023 | Disowned shell watchers outlive the shell; HEAD watch loops forever (zsh `:502-512`) | C8 shell hygiene | Hundreds of orphans and multi-GB RSS over days | S | none |
| B094 | Branch reporter runs `git status --porcelain` and takes `index.lock` while agents run git | C8 | Agent commits fail with index.lock errors; correctness, not perf | S | none |
| B074 | Replacement WKWebView built inside `webViewWebContentProcessDidTerminate` | C7 browser | About 1,900 host crashes in one cmux release on macOS 26; Atin is on macOS 26; a host crash takes every terminal | M | none |
| B044 | Notification records and unread state vanish on restart | Journal | Days-long restore loses who was waiting. **Delivered by workstream 1 (event journal), not a separate ticket** | M | none |
| B200 | Sparkle 2.8.1 helper exposed to macOS 26 install rejection | Release | If updates fail on macOS 26, 1.0 cannot reach existing users; cheap bump; verify the update path on a tagged build | S | none |

## 4. Clusters

**C1. The Ghostty shared-mailbox trap.** One 64-slot `BlockingQueue(App.Message)` drained only by main, with producers that push `.forever` from the PTY read thread while holding `renderer_state.mutex`. Every main-thread call that takes that mutex is a door: `Surface.deinit` (08-25 root), autosave `needs_confirm_quit` (B010), focus and visibility pushes into the sibling renderer queue (B031), and `read_text` (`dumpText`, missed by the sweep). Rows: B010, B065, B031, B013, B047, B072, B204, and the app half of B086. **Retiring fix:** one Ghostty submodule bump carrying bounded drain (`2258bea96`, `188d31a97`), non-parking or abortable producer pushes plus a larger mailbox (c11's own plan A and B), latest-value lifecycle publication (`ca21db1bb`), atomic paste (`f27772d10`), `setSelection` fix (`ab82b8ab7`), MemoryPool (`e0ef934f7`), and the Exec.zig child-shutdown commits (B062, B022, B021). Eight must rows and three nice rows in one bump. Offer the mailbox pieces to `ghostty-org/ghostty` (D23).

**C2. Cold terminal start.** A never-shown terminal can lose its bootstrap window and never spawn (B003); reads do not start it (B087); closed runtimes can be recreated (B068); readiness is published before queued input flushes (B257); background terminals start with wrong focus (B175). **Retiring fix:** re-adopt parked hosts into the bootstrap window (B003) and route `read_text` through the same start-and-wait helper `send_text` already uses (B087). Four rows.

**C3. Child process lifecycle in termio.** Unbounded SIGHUP loop (B062), descendants survive (B022), dead PTY spin and reaping gaps (B021). Same bump as C1. Three rows.

**C4. Restore and persistence safety.** Socket during restore (B007, B246), second instance kills the fleet (B005, B025), duplicate ids (B024), wrong-manager close (B019), self-open suppresses restore (B004), snapshot history (B046, half done), phantom windows (B355), lifetime leaks after restore (B069, B075, B077). **Retiring fixes:** a restore-readiness flag the socket checks (B007 + B246), and an instance policy that yields instead of killing (B005 + B025).

**C5. Main-thread congestion (C11-197, C11-202, C11-205).** Producers: ticks (B030), titles (B061, B258, B096, B165), layout flushes (B056, B067, B049, B014, B198), mount cap (B012), socket per-command main work (B007 walk, B205, B086), sidebar body (B059, B029, B060, B016, B043, B126, B130, B188), hit-testing (B127), hooks (B027). **Retiring approach:** fix the four S producers first (B030, B056, B061, B012), then measure the sidebar on a tagged build with 40 workspaces before touching it (D21). About 20 rows; the S producers alone retire the ones with measured upstream numbers.

**C6. Socket targeting and ref safety.** Ordinal refs after restart (B058), `send-key` chords (B002), remaining focused-pane fallbacks on split and read (B066), `send-key` dropping extra keys (B266), window and workspace routing (B156, B137, B157). **Retiring fix:** generation-stamped refs (grab-list 4.2) plus applying `v2RejectUnresolvedTargetRefs` to the non-destructive verbs too.

**C7. Browser lifecycle and automation.** Termination-callback swap (B074), forced layout (B014, B049), inspector and popup WebKit traps (B113, B162, B120), portal slot retention (B222), hidden WebViews (B140), automation correctness (B078, B079, B080, B211). One browser track, mostly S; B074 is the only must.

**C8. Shell-integration process hygiene.** Orphan watchers (B023, B155), index.lock (B094), git in non-repos (B181), `gh` polling (B125, B185, B253), `lsof` scans (B150), fork per send (B182). **Retiring fix:** one pass over the zsh and bash integration files; two must rows, the rest nice.

**C9. Claude wrapper and hooks.** Per-event CLI spawn (B027), whole-transcript Stop (B028), wrapper exec loop (B064), hook routing fallbacks (B106, B141, B157), status edge cases (B192, B234, B088, B219). **Retiring approach:** fold the spool and bounded-tail ideas into Journal phase 1 so the journal does not multiply the per-event cost; B028 is the one must because it grows with session length today.

## 5. Build order for the must-dos

Waves, not days. Each wave can run as parallel tickets; the order inside a wave is by dependency.

**Wave 0, before anything else.** Relocate: every ticket re-finds its target on `origin/main` after C11-248. Builds and soaks on Atlas (C11-216, D26).

**Wave 1, independent S fixes with no latency risk (parallel, 10 tickets):** B087, B012, B061, B007+B246, B005, B024, B019, B023, B094, B028, B200. Reason: each is a day-sized change in one file, none touches a hot path, and together they remove the crash-at-launch, fleet-kill, orphan-growth and index.lock classes before the risky work starts. B200 first among them because the update path must be validated on a tagged build early.

**Wave 2, the Ghostty bump (one ticket, one submodule change):** B065, B010 (Ghostty half), B031, B013, B047, B072, B204, B062, B022, plus B021 and the pure-crash rows as nice if they cherry-pick clean. Reason: one rebuild, one checksum cycle, and this closes C1 and C3 together. **Risk: TL and DL.** A bounded drain changes tick cadence; latest-value publication must never drop the final visible=true; the bounded child wait must escalate to SIGKILL without killing processes the operator meant to keep. Gate: a soak on Atlas with 30 streaming panes, surface churn every few seconds, autosave running, and a child that traps SIGHUP. Measure typing latency before and after.

**Wave 3, app half of the trap and the cold path:** B010 (app half: snapshot path reads `process_exited`, S), B086 (snapshot on main, format off main, and stop taking the renderer mutex on main for reads), B003. Reason: B010's app half is independent of the bump and should land even if the bump slips; B086 and B003 are the two M items that most affect Overwatch-style fleets. **Risk: DL** on B086 (a torn read if the snapshot is not taken on main) and on B003 (portal reparenting).

**Wave 4, congestion producers and ref safety:** B030, B056, B002, B058. Reason: B030 and B002 touch key and tick paths (TL), so they go after the bump has settled and the latency baseline is known. B056 must carry the bounded retry and backoff. B058 is grab-list 4.2 and changes the wire contract agents rely on; land it with the skill update in the same PR.

**Wave 5, measured and browser:** B059 (measure on a 40-workspace tagged build; snapshot isolation only if convicted, per D21), B074 (defer the WebView swap out of the termination callback), B044 (arrives with Journal phase 1). Reason: B059 is L and gated; B074 is M and independent; B044 is owned by another workstream.

## 6. Nice to have

| Ledger id | Bug | Cluster | Size | Note |
|---|---|---|---|---|
| B032 | Focus broadcast posted synchronously mid-mutation | C5 | S | Downgraded; no re-entering observer on `origin/main`. Defer and coalesce as hygiene |
| B046 | Poorer relaunch can still autosave over the layout; history exists | C4 | M | Add the poorer-write hold-back and a restore-from-history picker |
| B066 | Split and `read_text` still fall back to the focused pane on an unresolvable explicit ref | C6 | S | Apply `v2RejectUnresolvedTargetRefs` to the remaining verbs |
| B006 | Socket await pumps the main run loop when the caller is on main | C5 | M | Narrowed: eval/wait/download.wait already run on the worker. Cap `timeout_ms` and refuse never-loaded WebViews |
| B027 | Each Claude hook event spawns the full CLI | C9 | M | Design constraint for Journal phases 1 and 2: spool, not spawn |
| B064 | Two bundle wrapper dirs in PATH exec each other | C9 | S | Real for an operator running prod and a tagged build; add a reentry guard |
| B025 | Instance enforcement kills helpers with the same bundle id | C4 | S | Fix with B005 |
| B004 | LaunchServices self-open suppresses restore | C4 | S | Recoverable now that history is archived |
| B011 | JSON encoding overflows the worker stack at ~150 nested splits | C4 | S | Not the profile; cheap |
| B355 | Phantom 0-workspace windows at restore | C4 | S | Pair with B046 |
| B069, B075, B077 | Lifetimes after window close, restore swap, reentrant create | C4 | M each | Inferred crashes; do with a leak soak, not blind |
| B068, B175, B257 | Closed runtime recreated; background focus wrong; readiness before flush | C2 | M, M, M | Fold into the B003 ticket if the same code |
| B021 | Dead PTY spin and reaping gaps | C3 | S | Same bump as Wave 2 if it applies clean |
| B015, B020, B034, B036, B037, B045, B166 | Ghostty panics and loops in pins, compaction, graphemes, hyperlink reflow, preedit, font discovery, shaped cells | Ghostty crash set | S each | Cherry-pick in the bump where clean; crash in a terminal is fleet loss, but each trigger is narrow |
| B033 | Ghostty callbacks mutate view state off main | C5 | S | On c11's Ghostty, color and config changes arrive on main via the app mailbox (`stream_handler.zig:1251`); scrollbar may not (`renderer/generic.zig:1293`). Becomes required with the bump |
| B042 | New-workspace config copies C pointers without owning strings | C4 | S | Deferred surface creation (`GhosttyTerminalView.swift:2731`) makes the UAF plausible under churn |
| B001 | Closure-bearing `DispatchWorkItem` in `@State` chains (`ContentView.swift:1492, 1496, 1517`) | C5 | S | Upstream saw a stack overflow; move to a reference coordinator |
| B018 | Closed windows retain SwiftUI content | memory | M | Few windows in practice |
| B029, B060, B016, B130, B188 | Sidebar GeometryReader per row; `LazyVStack` recursion; ring change rebinds portal; `onDrop` per row; `@AppStorage` per row | C5 sidebar | S, S, S, S, M | Do after the D21 measurement points at the sidebar; each is small |
| B043, B126 | Notification churn invalidates the sidebar and rebuilds rows | C5 | M, S | Same gate |
| B258, B096, B165 | Title churn: window title, unbounded stored titles, palette rebuilds | C5 | S, S, M | Fold into the B061 ticket |
| B067, B049, B014, B198 | Layout follow-up flushes every window; portal bind syncs layout in a SwiftUI turn; browser forced layout; divider overlay redraw | C5 | S, M, M, S | B067 with B056; the rest after measurement |
| B127, B187 | Divider hit-test walks the view tree per pointer move; resizer tracking on every mouse move | C5 | M, S | Pointer-only paths; moderate |
| B205 | v2 `system.ping` and `capabilities` walk main first | C5 | S | Add to the worker list |
| B189 | Socket reply is one unchecked `write` (`TerminalController.swift:1957, 1971`) | C6 | S | Loop until written, bounded; truncated JSON for large reads otherwise |
| B266 | `send-key` keeps only the first key | C6 | S | Agents send chords |
| B156, B137, B157, B141, B106 | Routing to the active window or focused pane instead of the caller's | C6 | S each | Policy violations (socket focus policy) |
| B190 | Socket window focus raises or unminimizes a window | C6 | S | Violates the focus policy in CLAUDE.md |
| B093, B214 | AppKit and Ghostty focus disagree; stranded first responder holds typed input | focus | M, M | Visible to the operator; moderate |
| B114 | Closing an unfocused pane moves focus to its sibling | focus | S | Bonsplit port |
| B210, B151, B091, B084 | Intermediate PTY sizes on reveal garble TUIs; SIGWINCH per pixel; blank until refocus | pty/render | M, M, S, S | `read-screen` returns garbage during reveals |
| B145 | Incoming output pulls an explicit scrollback position back to the bottom | scroll | S | Constant with streaming agents when reading history |
| B176 | Restored scrollback replays the old theme's OSC 10/11 | session | S | White-on-white after a theme change |
| B173, B088, B219, B240, B245, B247, B248 | Restore details: titles, never-used sessions, exited agents, duplicate ids, stale portal geometry, writer ownership, drifted cwd | C4 | S to M | Pair with D14 restore-on-the-right-account work |
| B071 | Old window geometry survives a schema change | C4 | S | 1.0 is a schema change |
| B050, B244 | Quit waits on telemetry that waits on main; no quit deadline | quit | S, S | A wedged quit loses the save |
| B094's neighbours: B181, B182, B150, B125, B185, B155, B183 | git in non-repos; fork per send; `lsof`; `gh` polling per shell and per workspace; nested watchers; PATH bypass | C8 | S to M | One shell-integration pass |
| B108, B110, B146 | Wrapper flag conflicts and allowlist | C9 | S | Fix with D14 |
| B192, B218, B234 | Attention state wrong after subagent completion, answered ring, late notification | Journal | S, M, S | Journal phase 1 inputs |
| B194 | Synchronous prompt hooks can outlive the hook deadline | C9 | M | Journal phase 2 |
| B140 | Hidden browser panes keep WKWebViews | memory | M | Browser memory after C1, in the spirit of D22 |
| B222, B113, B162, B120, B216 | Browser portal slot retention; inspector-open close crash; popup handler never called; download URL trap; stale portal after switch | C7 | S each | Browser track |
| B078, B079, B080, B211 | `cookies clear --url` wipes the profile; React inputs; `state load` into the old document; CSP eval | C7 automation | S, S, M, M | The c11-browser skill depends on these |
| B123, B213 | Agent-started dev servers never become ports; badges stick | ports | M, M | Sidebar ports are an agent-native signal |
| B136 | `os_log` object per log line in Ghostty | CPU | M | Same bump if clean |
| B178 | Screenshot paste PNG-encodes up to 10 MB before the terminal can read | paste | M | Operator pastes screenshots to agents |
| B180, B193 | Autosave writes unchanged defaults; resign-active snapshots all sessions synchronously | C4/C5 | S, S | Cheap |
| B128, B148 | Precise scroll doubled for mice; keys before runtime beep | input | S, S | Cheap |
| B215 | Wedged `usernoted` blocks main in `UNUserNotificationCenter.add` | notifications | M | Rare but a hard main block |
| B236 | Losing a main-window context makes terminals unreachable through routes | socket | M | Multi-window |
| B160 | Pane lookup reads every tab model and subscribes portals to title changes | C5 | S | After measurement |
| B083 | `NSColor.darken` raises on catalog colors | theme | S | Crash on a theme edge |
| B097 | Background prime starts a surface for every idle terminal pane | C2/C5 | S | Pair with B012 |
| B343 | Markdown-surface links do not open | markdown | S | Markdown tabs are a core primitive |
| B089 | A replacement terminal host is rejected until its area is 20% larger or the old host disappears | C2 portal | M | Same-size pane moves leave the old host; pair with B003 |

## 7. Not a priority

223 rows. Grouped; every id listed once.

- **Already-decided out (ruling):** B035 (GPU reclaim; only on a clear bug).
- **Launch-time or OS-version edge cases that c11 does not trip today:** B026 (`GhosttyApp.shared` re-entry; c11 launches fine), B076 (macOS 27 SF Symbol sizing; OS not shipped), B082 (`setlocale` comma locale), B220 (Rosetta launch), B346 (Sentry/locale race), B297, B330.
- **Rare trigger, rated too high:** B017 (stale event window on close), B038 (initial split ratios), B039 (link regex retry budget), B041 (malformed Kitty graphics leak), B054 (resize allocation failure), B057 (search after resize UAF), B338 (extreme drag coordinate overflow), B052, B053, B055, B063, B121, B122, B135, B101, B139, B239, B230 (Ghostty internals with narrow triggers; take only if they ride the bump for free).
- **IME, non-Latin and non-US input (Atin types English):** B008, B070, B105, B117, B118, B119, B143, B144, B154, B191, B206, B223, B289, B294, B295, B302, B305, B306, B309, B322, B323, B336, B339, B340, B341, B349, B351, B354, B362, B363, B276, B344.
- **Clipboard and paste edge cases:** B040, B048, B112, B153, B203, B296, B300, B331, B284.
- **Bash integration (zsh is the shell here):** B098, B099, B100, B275. zsh cosmetics: B092, B131, B207, B293, B299, B320, B357, B358, B313, B314, B138, B152, B085, B278.
- **Updater polish (the Sparkle bump in the must list covers the real risk):** B103, B104, B111, B298, B361, B367.
- **Cosmetic layout, chrome and window placement:** B090, B095, B102, B147, B172, B177, B179, B184, B186, B202, B212, B226, B241, B249, B252, B254, B256, B259, B260, B261, B263, B264, B279, B292, B301, B310, B321, B329, B332, B334, B345, B365, B366.
- **Keyboard and menu minutiae:** B115, B116, B129 (CLAUDE.md already treats `forceRefresh` per key as deliberate), B132, B134, B149, B196, B197, B201, B208, B224, B225, B227, B228, B233, B235, B237, B242, B262, B268, B269, B270, B271, B280, B281, B282, B283, B285, B286, B291, B307, B308, B318, B326, B368, B353, B364.
- **Notifications and sidebar small items:** B124, B133, B163, B265, B303, B348, B253, B174, B243.
- **Socket and CLI corner cases without data risk:** B159, B169, B170, B199, B209, B217, B274, B328, B337, B350, B360, B312, B304.
- **Browser low-value or watch-only:** B158, B164, B232, B250, B251 (L, watch), B267, B272, B277, B287, B324, B325, B335, B342, B347, B352, B359, B255.
- **Theme and config:** B171, B195, B229, B311, B316, B317, B319, B356, B273, B327.
- **Hooks noise:** B107, B109, B231, B315.
- **Other:** B142, B161, B167, B168, B221, B238, B290, B288, B333.

## 8. Rejected

- **B009.** Already fixed on `origin/main`: `CLI/c11.swift:2627` rejects an empty `--workspace` on `close-tab` (`rejectEmptyTargetFlags`, `:11881`).
- **B051.** Already fixed: `applicationShouldTerminate` confirms every quit when Warn Before Quit is on, `Sources/AppDelegate.swift:3087-3112` (#456).
- **B073.** Already fixed (inferred): a single `pendingQuitConfirmation` sheet serializes repeated quit requests, `Sources/AppDelegate.swift:3093-3106`.
- **B081.** Already fixed: the `closeTab` fallback requires the target to be the focused panel or first responder, `Sources/Workspace.swift:8829-8832`.

## 9. What the sweep missed

1. **The ledger is stale against `origin/main`.** 36 commits landed after `d63b937f`, including C11-248 (Surface/Panel → Tab renames across `Sources/`, 27k insertions), the close-safety PR (#469), quit confirmation (#456) and session history (#467). Three of my 40 spot-checks were already fixed and every cited line moved. Any ticket cut from the ledger must re-verify on `origin/main` first. The same rename landing days before a hang-fix wave is itself a risk: the hot-path rules in CLAUDE.md name functions by their old names.
2. **`read_text` is a door into the mailbox trap.** `ghostty_surface_read_text` → `dumpText` locks `renderer_state.mutex` (`ghostty/src/Surface.zig:1916-1922`) and c11 calls it on main inside `Task { @MainActor }` (`Sources/SocketHandlers/SurfaceHandlers.swift:1122-1150`) while a socket worker waits on a semaphore with no timeout (`:1175`). Under 40 agents polling `read-screen`, this is the most frequent main-thread mutex take in the app, more frequent than autosave. The sweep filed B086 as a formatting-cost issue; it is also a deadlock door, and the semaphore means a wedged main pins socket workers one by one.
3. **`v2RefreshKnownRefs` on every v2 command** (`SocketDispatch.swift:972`) walks every window, workspace, pane and panel on main. With heavy agent traffic that is a per-command O(panels) main-thread tax that no cmux PR points at because cmux moved refs to a registry. Fix with B007: refresh incrementally on create and close, not per command.
4. **Eighteen `.forever` pushes in `Surface.zig`** (lines 927 through 5971), not just the two the sweep names. Any of them taken on main while the queue is full is a hang. The Ghostty bump should change the push policy, not patch two call sites.
5. **`read_text` and split still fall back to the focused pane** (`SurfaceHandlers.swift:316, 1137`) after #469 fixed the destructive verbs. An orchestrator asking about `tab:99` that died reads the operator's current screen and acts on it. The sweep's B066 predates the partial fix and does not call out the residue.
6. **The socket reply path is a single unchecked `write`** (`TerminalController.swift:1957, 1971`, B189). Combined with multi-hundred-KB `read_text` replies, agents can receive truncated JSON with no error. Worth a bounded write loop regardless of the ledger's med rating.
7. **Instance policy is kill-first** (`AppDelegate.swift:13136-13146`). Beyond B005, Sparkle's own relaunch and any `open -a c11` from a script path through this. The policy should be "the newer process yields" with a visible reason, which also matters for the Atlas-hosted c11 guests (C11-244).
8. **No evidence yet that the sidebar is the stall.** Every sidebar row (B059 and friends) is "pattern present"; the only measured hang stacks c11 has are the 08-25 `Surface.deinit` join and the 08-12 browser await pump. D21 is right: instrument `hang.log` with the top SwiftUI frame on a 40-workspace tagged build before spending an L on it.
