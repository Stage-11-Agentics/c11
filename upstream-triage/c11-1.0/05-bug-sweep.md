# 05 · Upstream bug-fix sweep

**Needs you:**

1. **Finish the verification on Bravo?** The account spend limit killed 10 of 11 verifier agents mid-run. I verified the highest-severity items myself, and the browser batch finished. About 1,400 shared-code candidates are still triaged but not verified, 187 of them with crash, hang or leak in the title.
   - Yes: relaunch the fan-out on Bravo with the saved prompt (`05-bug-sweep-data/verifier-prompt.md`). About 10 agents, a few hours. The table grows, and the top ten will probably not move much.
   - No: this report is the record. The unverified list stays as a backlog for the build phase to check ticket by ticket.
2. **Fix the 2026-08-25 deadlock root in the same Ghostty bump?** cmux has not fixed it. Its Ghostty still has the 64-slot shared mailbox and the blocking `.forever` pushes. Two of my top three findings are more triggers of the same trap.
   - Yes: one submodule change carries the cmux fixes (bounded drain, atomic paste, setSelection UAF) plus c11's own plan A (abortable pushes) and B (bigger mailbox). That is one rebuild, one CI checksum cycle, and the whole trap closed.
   - No: port only the cmux fixes. They narrow the trap but leave it open.
3. **Sidebar: snapshot isolation or an AppKit rewrite?** cmux tried snapshot isolation first (#8211) and then rewrote the list in AppKit (#8270), because SwiftUI kept livelocking at scale.
   - Snapshot isolation: M to L. It stays in SwiftUI and attacks c11's known 62-minute stall path directly.
   - AppKit list: L+. It is the durable answer and a large rewrite of c11's own sidebar (pulse cards, chips, attention marks).
   - My recommendation: snapshot isolation in 1.0, and decide on AppKit after measuring.
4. **Renderer GPU reclaim in 1.0?** This is the largest memory win (cmux measured 13.7 GB after 28 hours). It needs a Ghostty C API, a planner, and the teardown fix that came with it. L.
   - Yes: 1.0 grows by about a week.
   - No: it goes on the roadmap right after 1.0.

## How this sweep ran

- **Enumerated:** every "Fixed" changelog entry from v0.63.0 through Unreleased, plus every merged PR since the fork (`53910919`) whose title says fix, crash, hang, leak, livelock, regression, race, freeze or similar. Also performance PRs whose titles do not say "fix" (off-main moves, coalescing, reclaim), and the fix commits in cmux's Ghostty fork that c11's Ghostty lacks.
- **Filtered:** each PR was mapped to its commit on `upstream/main`. A fix counts as shared only if it touches files that existed at the fork point, or the extracted `Packages/macOS` modules (CmuxTerminal, CmuxControlSocket, CmuxBrowser, CmuxWorkspaces, CmuxFoundation) that hold formerly shared code. Title filters then removed cloud, iOS, SSH and tmux, vault, diff, feed, canvas, AppKit sidebar, agent hook integrations and localization.
- **Verified:** I verified the top tier directly against c11 source by reading the upstream diff, then the matching c11 code. One focus-group helper (Opus) and the browser verifier finished before the limit; I spot-checked their key claims.
- **Cross-referenced:** `notes/2026-08-25-freeze-surface-deinit-deadlock.md`, `notes/c11-hang-2026-07-28-session-manifest.md`, `notes/c11-restart-recovery.md`, and open c11 bugs on the Lattice board (read-only).

Full verdict ledgers are in `05-bug-sweep-data/` (`verdicts-lead.md`, `verdicts-browser.md`, `verdicts-focus.md`), along with the candidate lists.

## What cmux built

cmux spent roughly half its fix volume on three things c11 shares:

1. **Main-thread survival at scale.** This covers sidebar livelocks, title churn, focus storms, socket work moved off main, and bounded Ghostty mailbox drains. cmux's users run 10 to 100+ workspaces, and their hang reports look like c11's `hang.log`.
2. **Terminal lifecycle.** This covers cold surfaces that never start, renderer GPU reclaim for hidden terminals, PTY sizes during reveal and restore, and teardown races.
3. **Session safety.** This covers autosave deadlocks, snapshot history, and restore races with the socket.

Most of the rest fixes features c11 does not have: cloud VMs, iOS, SSH and tmux, the vault, the diff viewer, the AppKit sidebar, and hook integrations for 17 agent CLIs. A large share of those are regressions in code cmux added after the fork.

cmux fixed most of these by extracting code into Swift packages (`Packages/macOS/Cmux*`) and adding a lot of lifecycle machinery: tickets, leases, coordinators, deadlines. Its diffs rarely cherry-pick onto c11 cleanly. The ideas port well.

## What c11 has today

c11 has already fixed several of the same problems its own way. Examples: the socket accept-loop autoreleasepool leak (C11-211), the `set_display_id` deadlock (#403), the `free_text` ABI leak (C11-212), skipping `updateFrame` when occluded (C11-225), telemetry and send moved off main (C11-26), the browser eval starvation (C11-209, C11-217), and the browser portal rework (C11-132, C11-133). c11's Ghostty fork is at `26c3e499e`; cmux's is about 2,000 commits ahead (merge-base `b9989c101`).

c11's open stability problems are the main-thread congestion family (C11-197, C11-202, C11-205), the unfixed Surface.deinit deadlock, PTYs that never attach (C11-130, C11-169, C11-235), and crash-resume and data-loss safety (C11-131, C11-139).

## The gap: top ten

Ranked by severity for Atin's use (many agents, many workspaces, days-long sessions), weighted by confidence and port cost.

**1. Autosave can deadlock main through the terminal renderer mutex (#14784). Shared-confirmed. High, S, port.**
c11 runs session autosave on a main-queue timer (`Sources/AppDelegate.swift:4070-4078`). For every terminal, the snapshot calls `shouldPersistScrollbackForSessionSnapshot` (`Sources/Workspace.swift:816`, `Sources/Panels/TerminalPanel.swift:296-299`), which calls `ghostty_surface_needs_confirm_quit`. That locks the surface's `renderer_state.mutex` (`ghostty/src/Surface.zig:968`). A PTY read thread holds the same mutex while it processes output (`ghostty/src/termio/Termio.zig:681`). Inside that, it can park on a `.forever` push into the shared app mailbox (`ghostty/src/termio/stream_handler.zig:134`); `set_title` from agent spinners is one such push (`:1018`). Only main drains that mailbox. So a full mailbox plus one autosave tick is a permanent deadlock, with no surface close involved. This is a second door into the 2026-08-25 trap, and a plausible cause of the unexplained 2026-07-28 deadlock with 22 agents (inferred). cmux's fix reads `ghostty_surface_process_exited` (lock-free) on the snapshot path. The same trap applies to any main-thread call that takes `renderer_state` while the mailbox is full, so the durable fix is in Ghostty (see 2 and question 2).

**2. Ghostty drains its app mailbox without bound on main (#9117, Ghostty `2258bea96`). Shared-confirmed. High, S, port.**
`drainMailbox` is `while (self.mailbox.pop())` (`ghostty/src/App.zig:238-239`). With many surfaces streaming output, producers parked on the full 64-slot queue refill each slot as main pops it, so one app tick never returns and AppKit input starves. cmux reproduced it with about 10 panes of tight output: around 1000% CPU and clicks landing 25 s late. cmux's fix bounds a turn to `mailbox.count()` and re-wakes. Under 30+ streaming agents this likely accounts for part of c11's "runloop-idle late heartbeat" stalls (inferred). It is a ten-line Ghostty patch, and it reduces how often the deadlock in item 1 is armed.

**3. Cold background terminals can lose their bootstrap window and never get a PTY (#9796). Shared-confirmed. High, M, reimplement.**
A never-shown terminal starts inside a hidden borderless window. Portal churn can reparent its host view out of that window and park it with no window. `headlessStartupWindow` stays set, so every later start returns at `guard headlessStartupWindow == nil else { return }` (`Sources/GhosttyTerminalView.swift:2929`). The release path only fires when the view reaches a real window (`:2966-2972`). The surface never spawns, and queued `send` input never flushes, while `tree` answers instantly. That is very likely the root of C11-130, C11-169 and C11-235. cmux re-adopts parked hosts into the bootstrap window. It also bounds its claude-shim gate and stops hidden mount slots from pinning; c11's equivalents of those two were not checked.

**4. Bracketed paste can be split by terminal replies (#9875, Ghostty `f27772d10`). Shared-confirmed. High, S, port.**
`completeClipboardPaste` queues the opening fence, the payload and the closing fence as three IO messages. Terminal replies (DA, mode, focus) share that mailbox and can land inside the paste. The TUI then stays in paste mode and swallows Enter, Esc and Ctrl+C. cmux's trigger was Claude Code 2.1.221's terminal-query burst. c11's `send` writes through `ghostty_surface_text`, which is this bracketed-paste path (`Sources/GhosttyTerminalView.swift:3956-3958,4158`), so every `c11 send` into a Claude Code tab is exposed. The fix is one message per paste.

**5. A socket command during startup restore crashes the app (#9627). Shared-confirmed. High, S, port.**
Every v2 command runs `v2RefreshKnownRefs` on main (`Sources/SocketHandlers/SocketDispatch.swift:969`). It walks every window, workspace, pane and panel (`Sources/TerminalController.swift:2622-2640`), with no guard for a restore in progress. cmux saw EXC_BAD_ACCESS when a command arrived within a second of launch. Atin's restored agents hit the socket at once (wrapper `ping`, `set-agent`). The fix is a readiness guard. The walk also runs on main for every command, a per-command O(panels) cost worth revisiting (C11-141, inferred).

**6. A synchronous focus broadcast re-enters the focus path (#5108, #9026). Shared-confirmed. High, S, port.**
`applyTabSelectionNow` posts `.ghosttyDidFocusSurface` synchronously while `@Published` selection state is still changing (`Sources/Workspace.swift:11771-11778`). ContentView's synchronous `.onReceive` (`Sources/ContentView.swift:2624-2630`) calls `tabManager.focusTab` again (`:7028-7044`). The only guard is per workspace, so a cycle across workspaces is unbounded. cmux measured a 426 s main hang. This is a candidate contributor to c11's long unexplained stalls (inferred). The fix is a deferred, coalesced broadcaster; #9026 adds a circuit breaker.

**7. One snapshot file with no history means a poor relaunch can erase the layout (#14824). Shared-confirmed. High, M, reimplement.**
`SessionPersistenceStore.save` overwrites a single file atomically (`Sources/SessionPersistence.swift:539-553`). If a relaunch comes up poorer (a failed or partial restore, a skipped picker at `Sources/AppDelegate.swift:3573-3574`, an empty window), autosave writes the poor state over the full layout, and a second quick relaunch makes the loss permanent. cmux now keeps 10 rotated launch snapshots plus the richest one, and holds back poorer writes for 5 minutes. For Atin a lost layout means re-placing 20 to 40 agents by hand. This ties to C11-131 and C11-139. Pair it with #14788 (drop 0-workspace phantom windows at load, S).

**8. Hidden terminals keep their GPU swap chains forever (#5857, #7050, #10815, #10922). Shared-confirmed (missing feature). High, L, reimplement.**
Each shown terminal holds a Metal IOSurface swap chain of about 40 MB, and c11 never releases it. There is no renderer realization or reclaim, only `ghostty_surface_set_occlusion` (`Sources/GhosttyTerminalView.swift:3925`), and C11-225 saves CPU, not memory. cmux measured 13.7 GB and 603 IOSurfaces after 28 hours, and a 45% footprint drop with windows covered. The port needs Ghostty's `displayUnrealized`/`displayRealized` exposed as a C API, an LRU planner, and occlusion and memory-pressure triggers. It must also take Ghostty `7b24d1c5d`: the reclaim path added a `dispatch_sync` to main in `clearSurface` that deadlocks teardown.

**9. The sidebar recomputes every workspace and panel in its body (#8211, #7117, #8270). Shared-confirmed (pattern). High, L, reimplement.**
`VerticalTabsSidebar.body` loops every workspace and every panel on each pass. Per panel it calls `surfaceTitleBarState` (a synchronous `SurfaceMetadataStore` read), `unreadCount`, activity resolution and attention snapshots (`Sources/ContentView.swift:8600-8700`). This is exactly the path in c11's 62-minute stall and the AttributeGraph storms (C11-197, C11-202). cmux's first answer was a snapshot factory plus a coalesced publisher that isolates rows from live workspace objects. Its final answer was an AppKit NSTableView list. cmux's measurement-loop livelocks (#6033, #6188) do not apply; c11 never had that code.

**10. Browser lifecycle: forced synchronous layout and an in-callback WebView swap (#9773, #9774, #12519). High, M, reimplement.**
These came from the browser verifier, and I spot-checked the citations.
- **Forced layout (shared-confirmed):** c11's portal refresh calls `layoutSubtreeIfNeeded` and a whole-window `displayIfNeeded()` from inside SwiftUI update stacks (`Sources/BrowserWindowPortal.swift:3300-3312`, `Sources/Panels/BrowserPanelView.swift:6170-6173`). That drags sibling terminals and the hosting view through layout, and cmux traced a crash to an exception crossing it.
- **In-callback swap (shared-probable):** c11 builds the replacement WKWebView inside `webViewWebContentProcessDidTerminate` (`Sources/Panels/BrowserPanel.swift:2912,3490-3560`). On macOS 26 this overlaps WebKit's attach path and crashed cmux about 1,900 times in one release. A host crash takes down every terminal session.

## Full ranked table

Status key: `shared-confirmed` (same buggy code found in c11), `shared-probable`, `already-fixed`, `n/a-diverged`. Port: S under a day, M days, L a week or more.

| # | Bug | Upstream PR(s) | Subsystem | c11 status | Severity | Port | Rec |
|---|---|---|---|---|---|---|---|
| 1 | Autosave deadlock through `needs_confirm_quit` renderer mutex | 14784 | session / ghostty | shared-confirmed | high | S | port |
| 2 | Unbounded Ghostty `drainMailbox` livelock | 9117, gh `2258bea96`, `188d31a97` | ghostty / main | shared-confirmed | high | S | port |
| 3 | Cold surface loses bootstrap window, never gets a PTY | 9796 | terminal / socket | shared-confirmed | high | M | reimplement |
| 4 | Bracketed paste split by terminal replies | 9875, gh `f27772d10` | ghostty / input | shared-confirmed | high | S | port |
| 5 | v2 command during restore crashes | 9627 | socket / session | shared-confirmed | high | S | port |
| 6 | Synchronous focus broadcast re-entrancy | 5108, 9026 | focus | shared-confirmed | high | S | port |
| 7 | No snapshot history; poorer relaunch overwrites layout | 14824 | session | shared-confirmed | high | M | reimplement |
| 8 | Hidden terminals keep GPU swap chains | 5857, 7050, 10815, 10922, gh `517a4c75a`, `7b24d1c5d` | render / memory | shared-confirmed | high | L | reimplement |
| 9 | Sidebar body recomputes all workspaces and panels | 8211, 7117, 8270 | sidebar | shared-confirmed | high | L | reimplement |
| 10 | Browser portal forced sync layout | 9773, 9774 | browser | shared-confirmed | high | M | reimplement |
| 11 | WebContent termination swaps WebView in the callback | 12519 | browser | shared-probable | high | M | reimplement |
| 12 | `read_text` / `read_screen` never start a cold background terminal | 14673 | socket | shared-confirmed | med | S | reimplement |
| 13 | `read_text` formats multi-MB scrollback on main | 7357, 5243 | socket | shared-confirmed | med | M | reimplement |
| 14 | Title churn floods main; `window.title` written with no dedupe | 10510, 10351, 9098, 8084, 8155 | titles | shared-probable | med | S | reimplement |
| 15 | Portal reveal publishes intermediate PTY sizes; 800x600 placeholder | 11528, 12662 | pty | shared-confirmed | med | M | reimplement |
| 16 | Divider hit-test walks whole view tree per pointer move | 6592 | render | shared-confirmed | med | M | reimplement |
| 17 | AppKit first responder vs Ghostty focus divergence holds input | 6359, 7278 | focus | shared-confirmed | med | M | reimplement |
| 18 | Closing an unfocused pane steals focus (bonsplit) | 10021 | focus | shared-confirmed | med | S | port |
| 19 | `closePanel` fallback can close another panel's tab | 14704 | layout | shared-confirmed | med | S | port |
| 20 | Ghostty `setSelection` use-after-free | gh `ab82b8ab7` | ghostty | shared-confirmed | med | S | port |
| 21 | `browser cookies clear --url` wipes the whole profile | 10626 | browser automation | shared-confirmed | med | S | port |
| 22 | `browser state load` writes storage into the old document | 16204, 16205 | browser automation | shared-confirmed | med | M | reimplement |
| 23 | `browser fill/type/select` miss React-controlled inputs | 2059 | browser automation | shared-confirmed | med | S | port |
| 24 | Web Inspector open at close crashes in WebKit | 3835 | browser | shared-confirmed | med | S | port |
| 25 | Popup policy handler never called when controller is gone | 10567 | browser | shared-confirmed | med | S | port |
| 26 | Google download URL with duplicate params traps | 10480 | browser | shared-confirmed | med | S | port |
| 27 | Omnibar typing cost scales with workspaces and history | 3422, 4647, 5397 | browser | shared-confirmed | med | S/M | port |
| 28 | `browser.eval` fails opaquely under CSP | 5778 | browser automation | shared-probable | med | M | reimplement |
| 29 | Closed browser panel keeps its portal slot until deinit | 7487 | browser / memory | shared-probable | med | S | port |
| 30 | Background browser screenshots stale or blank | 5424, 9281 | browser automation | shared-probable | med | L | watch |
| 31 | Browser-heavy restore starts every WebContent at once | 11006 | session / memory | shared-probable | med | L | watch |
| 32 | Wedged `usernoted` blocks main in `UNUserNotificationCenter.add` | 9630 | notifications | shared-probable | med | M | reimplement |
| 33 | Restored terminals start before the socket listens | 10058 | socket / session | shared-probable | med | M | reimplement |
| 34 | Restore of 0-workspace phantom windows | 14788 | session | shared-probable | low | S | port |
| 35 | Japanese IME Backspace wipes preedit (`replacementRange` ignored) | 13581 | ime | shared-confirmed | low | S | port |
| 36 | Korean jamo leak; Option dead keys | 2529, 12997 | ime | shared-probable | low | S | watch |
| 37 | Minor focus items (drag-to-split, `goto_split` edge, notification jump, dim lag, find overlay mouse-up) | 9754, 12401, 6416, 14892, 5335 | focus | 2 confirmed, 3 probable | low | S | watch |
| 38 | Minor browser items (inspector lifecycle, `window.close()`, reopen retarget, httpOnly, system proxy, file drop, DOMRect on macOS 15, find-overlay weak scan, onAppear re-fire) | 4182, 6559, 2621, 5180, 4070, 4961, 10628, 5915, 1843, 12237, 5755, 5311 | browser | confirmed/probable | low | S | watch |
| 39 | CLI SIGPIPE on closed stdout | 12503 | cli | already-fixed | n/a | n/a | skip |
| 40 | Deselected bonsplit tab's browser portal stays visible | 2000 | browser | already-fixed | n/a | n/a | skip |
| 41 | Not applicable to c11's code (the bug lives in code cmux added after the fork, or in paths c11 rebuilt) | 13292, 6033, 6188, 12521, 9358, 12796, 9000, 8884, gh `ff36ae8ac`/`af4dfb43f`/`b47e5cac2`, 5296, 13968, 14276, 11349, 6073, plus four browser portal and keyboard groups | various | n/a-diverged | n/a | n/a | skip |

Notes on rows 39 to 41:
- **#12796 residual:** c11's CLI sets SIGPIPE to `SIG_IGN` (`CLI/c11.swift:17639`), and ignored dispositions survive `execv`. So `c11 claude-teams` hands claude an ignored SIGPIPE. Reset it before exec (low).
- **#9000:** the changelog cites it as #8851, which is a test-only PR. The landscape doc inherited that wrong number.

## Proposed c11 1.0 shape

Doctrine check: every item above is a c11-internal fix in the app, CLI or Ghostty fork. None writes into agent tools' config, and none needs agent cooperation. Nothing here touches the "unopinionated about the terminal" line.

**Tracks:**

| Track | Items | Size | Why together |
|---|---|---|---|
| A. Ghostty patch set | 2, 4, 20, Ghostty side of 1, plus c11's own plan A and B for the 08-25 deadlock | S to M, one submodule bump | One rebuild and one checksum cycle. It closes the shared-mailbox trap that several symptoms share. |
| B. App hang and crash fixes | 1 (snapshot path), 3, 5, 6, 18, 19 | M total | Small, independent, high value. Each is its own PR. |
| C. Session safety | 7, 34, 33 | M | Restart safety for a 40-agent layout. Pairs with C11-131. |
| D. Socket reads for the fleet | 12, 13 | M | Overwatch-style reads. Reuses c11's own send-path helper. |
| E. Browser automation correctness | 21, 22, 23, 25, 26, 24, 28 | M total | Small JS or handler fixes that the `c11-browser` skill flows depend on. |
| F. Main-thread architecture | 9, 14, 16, 10, 11, 15 | L | The congestion workstream. Pick 9 and 14 first. |
| G. Memory | 8, 29, 31 | L | Long-session footprint. |

**Approach options:**

1. **Cherry-pick upstream diffs.** Fastest where code is still identical: Ghostty patches, small Swift fixes like 5, 18, 19, 21, 25 and 26. Most app-side diffs land in files that diverged heavily or in packages c11 does not have, so this fails for M and L items.
2. **Reimplement from the idea (recommended for app code).** Read the upstream root cause and write the c11-shaped fix. It costs more per item but keeps c11's architecture coherent and avoids importing cmux's package and lifecycle scaffolding.
3. **Resync large subsystems (not recommended).** Adopting cmux's CmuxTerminal or sidebar wholesale contradicts the standing assumption of deliberate divergence, and would drag in features c11 rejects.

**Recommendation:** Tracks A and B first, since they are mostly S and cover the worst hangs and crashes. Then C, D and E. F and G are the 1.0 stretch, sized by your answers to questions 3 and 4. Cherry-pick Ghostty, reimplement app code.

## Effort and risk

| Track | Effort | Risk |
|---|---|---|
| A | S to M | The Ghostty submodule workflow (fork branch, push first, `docs/ghostty-fork.md`, about a 10-minute GhosttyKit rebuild, two-run CI checksum). A bounded drain changes tick timing, so watch typing latency. Abortable pushes drop messages only during teardown; that needs a soak test with heavy output while closing surfaces. |
| B | M | Focus changes (6, 18) touch typing-latency-sensitive code; follow the c11 CLAUDE.md hot-path rules. Bonsplit is a submodule: push before bumping the pointer. |
| C | M | A snapshot history must not grow without bound. The overwrite guard must not block a deliberate "start fresh". |
| D | M | Moving formatting off main needs a consistent snapshot taken on main first, or reads tear. |
| E | M | Low. Page-JS changes are testable through `tests_v2` against a tagged build. |
| F | L | The sidebar rewrite touches `TabItemView`'s Equatable contract and every sidebar feature c11 added. It is easy to regress typing latency. |
| G | L | The renderer reclaim must take `7b24d1c5d`, or it adds a new teardown deadlock. Re-realizing a surface must restore content, not a blank frame. |

General risk: green tests do not prove any of the hang fixes. Each needs a tagged build driven under load (many streaming panes, surface churn, autosave ticks). Run that soak on Atlas, not Hyperion.

## Open questions

1. Relaunch the remaining verification on Bravo? See "Needs you" 1.
2. Include the 08-25 deadlock root fix in Track A? See "Needs you" 2.
3. Snapshot-isolated sidebar or AppKit rewrite? See "Needs you" 3.
4. Renderer GPU reclaim in 1.0? See "Needs you" 4.
5. Offer the Ghostty fixes (1's Ghostty side, 2, the 08-25 root) to mainline `ghostty-org/ghostty`? The mailbox trap exists in stock Ghostty. Per standing policy, nothing goes to manaflow-ai.
   - Yes: c11's fork patch dissolves at a future sync.
   - No: c11 carries the patch indefinitely.
6. Should the build phase pull the 187 unverified crash and hang candidates in as a checklist (`05-bug-sweep-data/unverified-high-severity-keywords.tsv`)?
   - Yes: each Track B and F ticket checks its neighbors.
   - No: they wait for the Bravo run.

## Counts

| Stage | Count |
|---|---|
| Enumerated, app side | 2,537: 2,364 fix PRs or changelog fixes, 40 changelog fixes with no PR link, 133 performance PRs |
| Enumerated, Ghostty fork | 416 fix-like commits, out of 2,015 commits c11's Ghostty lacks |
| **Enumerated, total** | **2,953** |
| Filtered out (app) | 1,438: 321 n/a by path, 284 no product code, 563 n/a by title (cloud, iOS, SSH, vault, and so on), 207 upstream-only new code paths, 30 already in c11 before the fork, 33 infra or cmux-next |
| Candidates remaining | 1,515: 897 app fixes, 162 performance supplement, 40 changelog-only, 416 Ghostty |
| Triaged by a verifier | 135 browser rows (31 n/a, 12 noise, 92 to verify) plus my direct passes |
| **Verified against c11 source** | **71 bugs, covering about 115 upstream PRs and commits** |
| shared-confirmed | 32 |
| shared-probable | 19 |
| already-fixed | 2 |
| n/a-diverged | 18 |
| Not yet verified | about 1,400 candidates; 187 app candidates carry crash, hang, leak or freeze keywords |

Caveat: the confirmed count is a floor. The verification pass was cut short by the spend limit and covered the highest-severity tier first.
