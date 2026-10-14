# 1. Verdict in five lines

Must do: **112** ledger rows.
Nice to have: **119** ledger rows.
Not a priority: **134** ledger rows.
Rejected: **3** ledger rows. Total: **368**, each assigned once below.
Most important: **B010, teardown-abortable Ghostty mailbox pushes**, including all three producer queues. The recorded join cycle is the release blocker. See `notes/2026-08-25-freeze-surface-deinit-deadlock.md:9-20,71-91,130-145`.

# 2. Spot-check results

**Checked 19 shared-confirmed rows: 15 held, 4 overturned in whole or part.** B009 and B274 are rejected. B010 and B066 remain must-do with narrower claims. I also examined B350, a probable row, and reject its proposed behavior as a c11 bug fix. That extra check is outside the 19-row denominator.

Scope: static review only. No builds, tests, fetches, runtime probes, or contact with another auditor. Source reads used c11 `origin/main = 0ff8887e5e965400b01645ef40b85fd0b2605cf2`, cmux `upstream/main = 920ff39ff7cd6166434c12b9c2f167d4284fe6b2`, and the matching c11 Ghostty gitlink `26c3e499ed8c4d65e3748248de7fd04c1e9a8103`. These were read from the local refs, without fetching. The ledger's older app baseline is explicitly recorded at `LEDGER.md:5`; it is not the reviewed c11 head.

Citation convention: app paths in this section and section 9 are at that c11 head. `ghostty/` paths are at the gitlink above. Upstream citations include the inspected commit, file and line or diff hunk. `LEDGER.md:N` means the supplied evidence at that exact line, including its original verifier links. Outside the spot-check sample, table mechanisms are **reported evidence**, not a claim that I independently reverified all 368 rows against origin/main. Probable entries retain that uncertainty. All tiers, sizes, priorities and proposed remedies are my judgments.

The ledger digest is `75520b56ac5cc481741ec009fede36431193bcc8106c30971818fccca13195f9`. Source verdict digests match its manifest (`LEDGER.md:475-490`). The original plan and sweep use obsolete release splits and calendar estimates (`../C11-1.0.md:320-324`, `../05-bug-sweep.md:158-170`). This audit follows the brief's later rulings: one 1.0 release, no sidebar rewrite, GPU reclaim only for a clear bug, relative S/M/L sizes (`audit-brief-astra.md:65`).

| Ledger id | Result | Independent comparison |
|---|---|---|
| B001 | Held | Capturing work item remains in value-view state: `Sources/ContentView.swift:1492,1881-1892`. Upstream `f5361074f6c8:Sources/ContentView.swift`, hunks 877 and 1375, replaces it with a reference scheduler. Crash applicability is inferred, not reproduced. |
| B002 | Held | Press-only event with zero codepoint: `Sources/TerminalController.swift:6584-6605`. Upstream `ca92cbbe2e:Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+Input.swift:578-685` adds canonical text/codepoint and generation-checked release. No claim that every TUI drops every chord. |
| B009 | **Overturned, rejected** | Old `close-surface` aliases to `close-tab`, which now calls `rejectEmptyTargetFlags` before normalization: `CLI/c11.swift:2626-2636,11765,11881-11888`. This already implements the safety intent of `69c9518f5c:CLI/cmux.swift`, hunk 7112. |
| B010 | **Partly overturned; must remains** | The claimed autosave mutex cycle omits `ghostty/src/termio/stream_handler.zig:131-134`: the producer **unlocks** renderer_state before its blocking app-mailbox push. Thus `Surface.zig:968` cannot wait on that mutex held by that parked producer. Upstream `ea5a1666723e:Packages/macOS/CmuxTerminal/Sources/CmuxTerminal/Surface/TerminalSurface+CloseConfirmation.swift:12-38` removes a lock from autosave, but does not prove this c11 cycle. The distinct teardown join cycle remains: main frees at `Sources/GhosttyTerminalView.swift:3287-3291,4328-4330`, documented with sampled stacks at `notes/2026-08-25-freeze-surface-deinit-deadlock.md:9-38`. |
| B012 | Held | All pending background IDs raise the mount cap: `Sources/ContentView.swift:3029-3051`. Upstream `802351c879:Sources/TabManager+BackgroundWorkspaceMountPolicy.swift:4-23` caps concurrent mounts while preserving headless startup. Do not cap pending work by dropping launches. |
| B013 | Held | Separate paste vectors become separate IO messages: `ghostty/src/Surface.zig:6302-6324`. Upstream `f27772d10:src/Surface.zig`, hunk 7935, uses one owned encoded message. Interleaving reachability follows from the shared queue; no local TUI reproduction. |
| B016 | Held, severity qualified | Ring changes trigger bind: `Sources/GhosttyTerminalView.swift:10229-10255`. Upstream `0bdf69496a:Sources/GhosttyTerminalView.swift`, hunk 12631, removes that condition. Needless bind is confirmed; universal blanking is not. Nice to have. |
| B023 | Held | PR watcher checks only PID liveness and HEAD watcher has no parent check: `Resources/shell-integration/cmux-zsh-integration.zsh:454-472,500-513`. Upstream `22eec580cb`, same file, hunk 1505, adds start-time identity and liveness checks. Upstream orphan counts are not c11 measurements. |
| B029 | Held, mechanism only | Measured height writes state and feeds the drop target: `Sources/ContentView.swift:12964-12973,13009`. Upstream `499c8ea35b:Sources/ContentView.swift`, hunks 13524 and 13959, removes that dependency. A c11 infinite loop is not proven merely by the GeometryReader. |
| B030 | Held | Every wakeup enqueues a tick, scrollbar updates are immediate: `Sources/GhosttyTerminalView.swift:1069-1072,2161-2168`. Upstream `2d51c14ba1`, same file, hunks 1091,1816,4255, coalesces both. Retain a wakeup after a bounded drain leaves messages. |
| B031 | Held, earlier correction retained | Visibility/focus use forever pushes: `ghostty/src/Surface.zig:3336-3354`. Upstream `ca21db1bb:src/Surface.zig`, hunks 3718 and 3750, publishes latest state. The renderer queue is distinct from B010's app queue. Do not replace this with dropping the final visibility update. |
| B033 | Held | Inline UI mutation remains at `Sources/GhosttyTerminalView.swift:2161-2180`. Upstream `ad57e10772`, same file, hunks 2249 and 2363, dispatches UI mutations to main. Coalesce high-rate callbacks at the same time. |
| B047 | Held, mechanism corrected | `ghostty/src/datastruct/segmented_pool.zig:34-59` advances availability without recording which slot returned; its contract requires in-order return. Upstream `e0ef934f7:src/termio/Exec.zig`, hunks 418-506, pools the request and buffer together. Wrong-order reuse can corrupt outstanding bytes; `put()` does not literally refuse out-of-order returns as the verifier prose implies. No c11 byte-loss quantity established. |
| B056 | Held | Window-update observer schedules follow-up and each flush visits all windows: `Sources/Workspace.swift:10137-10143,10238-10242`. Upstream `8850142b8e:Sources/Workspace.swift`, hunks 10248,10334,10522, removes the observer **and** preserves bounded retry/backoff. |
| B060 | Held, mechanism only | Lazy stack and unconditional drag-indicator assignment remain: `Sources/ContentView.swift:8535,14905-14915`. Upstream `2bf436779b`, same file, hunks 9929 and 14790, changes the stack and equality-guards invalidation. No proof that this caused a specific c11 hang. |
| B066 | **Partly overturned; must remains** | Close dispatch validates refs at `Sources/SocketHandlers/SurfaceHandlers.swift:39-40`; clear validates at `:1063-1069`. Validator at `Sources/TerminalController.swift:2713-2748` rejects empty/dead targets. Read and split still fall back at `SurfaceHandlers.swift:316,1137`. Apply the fail-closed idea from `71f0e69578:Sources/TerminalController.swift`, hunks 5346-5482, only to the remaining gaps. The current source does not support the claimed destructive-close example. |
| B180 | Held | No-op geometry writes remain: `Sources/AppDelegate.swift:3563-3576`. Upstream `db5103d2a4`, same file, hunks 3687-3700, uses stable sorted encoding and conditional writes. Byte comparison without deterministic encoding is insufficient. |
| B188 | Held | Per-row settings and parent workspace scans remain: `Sources/ContentView.swift:12024-12037,8535-8543`. Upstream `9e75355525de:Sources/ContentView.swift`, hunk 8492 onward, introduces a settings snapshot. This is fan-out, not by itself a deadlock. |
| B274 | **Overturned, rejected** | `Sources/SocketHandlers/SurfaceHandlers.swift:316-323` rejects a parsed stale UUID. Upstream `096ed627eb^1..096ed627eb:Sources/TerminalController.swift`, hunk 4649, deliberately restores focus fallback. That is undesirable for explicit agent targets. Retain rejection and close B066's malformed-handle gap. |

Overturns are exactly **B009, B010's autosave cycle, B066's destructive fallback claim, and B274**. The B047 wording correction preserves its source mechanism and verdict. B029/B060 retain source-pattern confirmation; they do not establish a measured c11 livelock. This distinction matters when choosing narrow changes over a sidebar replacement.

# 3. Must do

**112 rows.** S means a small local correction. M means a cross-file invariant or adaptation to c11. L means a substantial engine/lifecycle change. These are relative, not day estimates. “Probable” means establish the trigger or the unsafe invariant before implementing; it is a release investigation obligation, not permission to import a speculative upstream subsystem. No runtime fix is certified by this audit. Risk labels identify the seams that implementation must protect: typing, deadlock, ownership, restore data, process identity, browser callbacks or wire routing.

| Ledger id | Bug | Cluster | Why must | Size | Risk |
|---|---|---|---|---|---|
| B001 | `ContentView` stores a `DispatchWorkItem` in `@State` that captures the view value, so tearing the view down recursively releases it and crashes. `LEDGER.md:68` | Lifetime | Crash during repeated view teardown. | M | Lifetime; teardown deadlock |
| B002 | `send-key ctrl+letter` is keycode plus Ctrl, with codepoint 0 and no key release, so Kitty-protocol TUIs drop the chord. `LEDGER.md:69` | Input | Lost agent interrupts and control input. | S | Typing; IME/byte integrity |
| B003 | Cold terminal loses its bootstrap window and never starts. `LEDGER.md:70` | Lifetime | Direct candidate for the never-attached PTY incidents. | M | Lifetime; teardown deadlock |
| B004 | A LaunchServices self-open can suppress session restore. `LEDGER.md:71` | Restore | Relaunch can discard the restore opportunity. | S | Restore; identity/data loss |
| B005 | A new copy of the app force-kills the running fleet before it can save. `LEDGER.md:72` | Restore | Kills live agents before saving. | S | Restore; identity/data loss |
| B006 | Main-thread callback waits trap main-dispatch work. `LEDGER.md:73` | Main | Retained main-dispatch starvation hazard; audit reachable callers. | M | Typing; layout/queue reentry |
| B007 | A v2 socket command arriving during startup session restore walks the half-built window/tab tree on main and crashes (EXC_BAD_ACCESS). `LEDGER.md:74` | Restore | Restored agents issue socket calls during startup. | S | Restore; identity/data loss |
| B008 | Alt plus a non-ASCII key can emit invalid or missing UTF-8. `LEDGER.md:75` | Input | Non-ASCII input bytes are corrupted. | S | Typing; IME/byte integrity |
| B010 | Terminal teardown joins a reader blocked on the app mailbox. `LEDGER.md:77` | Engine | Recorded fleet-wide teardown deadlock; autosave cycle claim corrected below. | L | Engine ABI; deadlock/ownership |
| B012 | Background workspace loads raise the mount cap without a fixed ceiling. `LEDGER.md:79` | Lifetime | Burst creation defeats the mount bound and amplifies main-thread stalls. | S | Lifetime; teardown deadlock |
| B013 | Terminal replies interleave with bracketed paste. `LEDGER.md:80` | Input | Every agent paste needs contiguous framing. | S | Typing; IME/byte integrity |
| B014 | Browser portal refresh forces synchronous layout and whole-window display. `LEDGER.md:81` | Main | Avoid whole-window display reentry from browser updates. | M | Typing; layout/queue reentry |
| B015 | Cell movement across a row boundary computes an invalid column. `LEDGER.md:82` | Engine | Invalid pins can trap selection/navigation. | S | Engine ABI; deadlock/ownership |
| B017 | Close shortcuts can target an old event window instead of the focused window. `LEDGER.md:84` | Restore | Close shortcuts must not kill agents in another window. | S | Restore; identity/data loss |
| B018 | Closed main windows retain their SwiftUI content through a strong window reference. `LEDGER.md:85` | Lifetime | Repeated window churn retains content and terminal owners. | M | Lifetime; teardown deadlock |
| B019 | Closing a workspace through the wrong manager tears down live terminals. `LEDGER.md:86` | Lifetime | A stale manager can destroy another manager's agents. | S | Lifetime; teardown deadlock |
| B020 | Compacted pages can loop forever when a capacity starts at zero. `LEDGER.md:87` | Engine | Zero-capacity retry cannot make progress. | S | Engine ABI; deadlock/ownership |
| B021 | Dead PTYs can spin and exited children can escape reaping. `LEDGER.md:88` | Engine | Exited PTYs must stop polling and be reaped. | S | Engine ABI; deadlock/ownership |
| B022 | Descendants and foreground jobs survive surface shutdown. `LEDGER.md:89` | Engine | Repeated closes can leave live descendants. | M | Engine ABI; deadlock/ownership |
| B023 | Disowned shell watchers survive their parent. `LEDGER.md:90` | Shell | Days-long churn accumulates orphan helpers. | S | PID identity; helper cleanup |
| B024 | Duplicate panel IDs in a saved session crash restoration. `LEDGER.md:91` | Restore | One duplicate ID can prevent fleet restore. | S | Restore; identity/data loss |
| B025 | Duplicate-instance enforcement can terminate unrelated helper processes. `LEDGER.md:92` | Restore | Bundle identity alone can select the wrong process to terminate. | S | Restore; identity/data loss |
| B026 | During `ghostty_app_new`, an action callback can call `GhosttyApp.shared` while that singleton is still initializing, and re-enter it. `LEDGER.md:93` | Lifetime | Startup callback can re-enter singleton initialization. | S | Lifetime; teardown deadlock |
| B028 | Each Claude Stop reads and parses the entire growing transcript. `LEDGER.md:95` | Shell | Stop-hook allocation and parse work grow with days of transcript. | S | PID identity; helper cleanup |
| B029 | Sidebar height measurement feeds layout state. `LEDGER.md:96` | Main | Remove the measured-height feedback edge in the existing sidebar. | S | Typing; layout/queue reentry |
| B030 | Wakeups and scrollbar updates are not coalesced. `LEDGER.md:97` | Main | Bound pending main-queue work under continuous output. | S | Typing; layout/queue reentry |
| B031 | Focus and visibility changes can block main on a full renderer mailbox. `LEDGER.md:98` | Engine | Focus/visibility must not park main behind renderer capacity. | M | Engine ABI; deadlock/ownership |
| B032 | Synchronous focus broadcasts re-enter selection. `LEDGER.md:99` | Main | Reentrant selection can monopolize main. | S | Typing; layout/queue reentry |
| B033 | Ghostty callbacks can mutate terminal UI state off the main thread. `LEDGER.md:100` | Main | AppKit state must be mutated on main. | S | Typing; layout/queue reentry |
| B034 | Grapheme widening at the right edge can panic. `LEDGER.md:101` | Engine | Ordinary wide-character output can hit a panic. | S | Engine ABI; deadlock/ownership |
| B036 | Hyperlink reflow checks the wrong allocation shape. `LEDGER.md:103` | Engine | OSC 8 reflow can exceed the allocation it checked. | S | Engine ABI; deadlock/ownership |
| B037 | IME preedit catch-up reads past shaped glyphs. `LEDGER.md:104` | Engine | IME rendering can read beyond the glyph buffer. | S | Engine ABI; deadlock/ownership |
| B038 | Initial split layout overwrites configured divider ratios. `LEDGER.md:105` | Restore | Preserve requested layout ratios during initial layout. | S | Restore; identity/data loss |
| B039 | Link regex work has no explicit retry budget. `LEDGER.md:106` | Engine | Adversarial or pathological link text needs a finite regex budget. | S | Engine ABI; deadlock/ownership |
| B040 | Lossy plain clipboard text wins over intact rich Unicode text. `LEDGER.md:107` | Input | Paste must preserve Unicode text. | M | Typing; IME/byte integrity |
| B041 | Malformed Kitty graphics commands leak parser allocations. `LEDGER.md:108` | Engine | Repeated malformed graphics input leaks allocations. | S | Engine ABI; deadlock/ownership |
| B042 | New-workspace configuration copies C pointers without owning their strings. `LEDGER.md:109` | Lifetime | Deferred creation must own inherited strings. | M | Lifetime; teardown deadlock |
| B043 | Notification churn invalidates the entire workspace sidebar. `LEDGER.md:110` | Main | Whole-store invalidation feeds the known sidebar congestion path. | M | Typing; layout/queue reentry |
| B044 | Notification records and unread notifications disappear on restart. `LEDGER.md:111` | Restore | Restart must retain unanswered agent notifications. | M | Restore; identity/data loss |
| B045 | Null CoreText names can crash font discovery and copied names leak. `LEDGER.md:112` | Engine | Guard null font names and release copied CoreText names. | S | Engine ABI; deadlock/ownership |
| B046 | Poor restores overwrite the only good snapshot. `LEDGER.md:113` | Restore | Never let an incomplete restore destroy the last good layout. | M | Restore; identity/data loss |
| B047 | Write-buffer pool assumes ordered completion. `LEDGER.md:114` | Engine | Large sends must keep each pending write's bytes alive. | M | Engine ABI; deadlock/ownership |
| B048 | Paste shortcut can request the clipboard twice and deliver only the first character. `LEDGER.md:115` | Input | A paste must neither duplicate nor truncate text. | S | Typing; IME/byte integrity |
| B049 | Portal `bind` runs `layoutSubtreeIfNeeded` inside a SwiftUI layout turn and can abort in the display-link flush. `LEDGER.md:116` | Main | Avoid nested AppKit layout from representable updates. | M | Typing; layout/queue reentry |
| B050 | Quit waits synchronously for telemetry that can wait for main. `LEDGER.md:117` | Restore | Quit must not wait on a queue that can need main. | S | Restore; identity/data loss |
| B051 | Quitting from the app switcher bypasses Warn Before Quit. `LEDGER.md:118` | Restore | Every quit entry must honor the live-session warning. | S | Restore; identity/data loss |
| B052 | Reflow leaves a history viewport pin in the active area. `LEDGER.md:119` | Engine | Resize must preserve the scrollback viewport pin. | S | Engine ABI; deadlock/ownership |
| B053 | Reflow loses cursor position after blank cells. `LEDGER.md:120` | Engine | Resize must preserve cursor position. | M | Engine ABI; deadlock/ownership |
| B054 | Resize allocation failure leaves partially destroyed terminal state. `LEDGER.md:121` | Engine | Memory-pressure resize must leave valid terminal state. | M | Engine ABI; deadlock/ownership |
| B055 | Scroll-clear cursor reload carries page-local IDs onto another page. `LEDGER.md:122` | Engine | Page-local IDs must migrate with the cursor pin. | S | Engine ABI; deadlock/ownership |
| B056 | Window-update observer repeatedly flushes all window layouts. `LEDGER.md:123` | Main | Remove per-scroll whole-window flushes, preserve bounded retries. | S | Typing; layout/queue reentry |
| B057 | Search results can retain freed page pointers after resize. `LEDGER.md:124` | Engine | Search must invalidate pointers when reflow frees pages. | S | Engine ABI; deadlock/ownership |
| B058 | Short socket references silently target different objects after restart. `LEDGER.md:125` | Restore | A remembered tab number must not identify another agent after restart. | M | Restore; identity/data loss |
| B059 | Sidebar rebuilds projections and synchronously reads metadata. `LEDGER.md:126` | Main | Remove synchronous metadata reads from SwiftUI body. | M | Typing; layout/queue reentry |
| B060 | Lazy sidebar layout and drag invalidation can recurse. `LEDGER.md:127` | Main | Break drag-triggered layout feedback without a sidebar rewrite. | S | Typing; layout/queue reentry |
| B062 | Surface close can wait forever for an uncooperative child. `LEDGER.md:129` | Engine | An ignoring child must not hold surface close forever. | M | Engine ABI; deadlock/ownership |
| B063 | Switching grapheme mode can assert on previously stored clusters. `LEDGER.md:130` | Engine | Mode changes must not invalidate stored grapheme invariants. | S | Engine ABI; deadlock/ownership |
| B064 | Two Claude wrapper paths can exec each other indefinitely. `LEDGER.md:131` | Shell | Wrapper recursion can prevent agent startup indefinitely. | S | PID identity; helper cleanup |
| B065 | Unbounded app-mailbox draining starves UI input under continuous terminal output. `LEDGER.md:132` | Engine | A streaming fleet must not keep one app tick running forever. | S | Engine ABI; deadlock/ownership |
| B066 | Unresolved read/split refs still fall back to focus. `LEDGER.md:133` | Socket | Wrong-target read/split results can corrupt agent context or layout; destructive cases already guarded. | S | Wire compatibility; targeting |
| B067 | A layout follow-up calls `displayIfNeeded` on every window before the current display pass finishes. **Probable.** `LEDGER.md:134` | Main | Deferred layout must not nest whole-window display passes. | S | Typing; layout/queue reentry |
| B068 | Closed terminal runtimes can be recreated and missing-surface input recovery is incomplete. **Probable.** `LEDGER.md:135` | Lifetime | Closed must be terminal, including late attach callbacks. | M | Lifetime; teardown deadlock |
| B069 | Closed windows can retain terminal owners and allow late PTY creation. **Probable.** `LEDGER.md:136` | Lifetime | Closing a window must retire retained owners before late callbacks. | M | Lifetime; teardown deadlock |
| B072 | Queued PTY writes can drop a chunk on WouldBlock. **Probable.** `LEDGER.md:139` | Engine | WouldBlock must preserve the pending write, if reachable on this backend. | M | Engine ABI; deadlock/ownership |
| B073 | Repeated quit requests can enter nested modal confirmation loops. **Probable.** `LEDGER.md:140` | Restore | Repeated quit must not nest confirmation run loops. | S | Restore; identity/data loss |
| B074 | Replacing a web view inside its termination callback can crash the host. **Probable.** `LEDGER.md:141` | Browser | A browser child-process failure must not take down every agent. | M | WebKit; callback/origin |
| B075 | Session restore leaves the replaced workspace graph without explicit teardown. **Probable.** `LEDGER.md:142` | Lifetime | Restoring a replacement graph must retire the displaced graph. | M | Lifetime; teardown deadlock |
| B078 | Cookie-clear filters can erase the whole profile. `LEDGER.md:145` | Browser | A scoped clear must not destroy unrelated sessions. | S | WebKit; callback/origin |
| B080 | Browser state loads storage into the wrong document. `LEDGER.md:147` | Browser | State load must respect the committed document and origin. | M | WebKit; callback/origin |
| B081 | Unmapped panel-close fallback can close another tab. `LEDGER.md:148` | Restore | Closing a stale panel must not kill an unrelated tab. | S | Restore; identity/data loss |
| B083 | `NSColor.darken` calls `getHue` without converting to sRGB, which raises on catalog and grayscale colors. `LEDGER.md:150` | Browser | Normal theme color classes must not raise an Objective-C exception. | S | WebKit; callback/origin |
| B086 | Screen reads format scrollback on main. `LEDGER.md:153` | Main | Heavy read-screen traffic must not monopolize main. | M | Typing; layout/queue reentry |
| B087 | Screen reads do not start cold terminals. `LEDGER.md:154` | Lifetime | Direct candidate for never-started background agents. | S | Lifetime; teardown deadlock |
| B089 | A replacement terminal host is rejected until its area is 20% larger or the old host disappears. `LEDGER.md:156` | Lifetime | Host replacement must not strand a surface awaiting an arbitrary size increase. | M | Lifetime; teardown deadlock |
| B093 | AppKit and Ghostty focus can disagree, leaving typed input held. `LEDGER.md:160` | Lifetime | Typed input must not remain held behind stale Ghostty focus. | M | Lifetime; teardown deadlock |
| B098 | Bash multiline prompt rewriting can corrupt substitutions. `LEDGER.md:165` | Input | Shell prompt rewrites must not corrupt substitutions. | S | Typing; IME/byte integrity |
| B112 | Clipboard text using alternate plain-text UTIs is ignored. `LEDGER.md:179` | Input | Supported clipboard text must not disappear. | S | Typing; IME/byte integrity |
| B113 | Web Inspector remains open during host teardown. `LEDGER.md:180` | Browser | Inspector teardown can crash the entire host. | S | WebKit; callback/origin |
| B114 | Closing an unfocused pane moves focus to the closed pane's sibling. `LEDGER.md:181` | Lifetime | Background close must preserve the operator's input destination. | S | Lifetime; teardown deadlock |
| B115 | Cmd-click can send an unmatched mouse press to an agent TUI. `LEDGER.md:182` | Input | An unmatched TUI mouse press can leave input stuck. | M | Typing; IME/byte integrity |
| B118 | Consumed Alt incorrectly suppresses associated text. `LEDGER.md:185` | Input | Consumed Alt must not erase associated text. | S | Typing; IME/byte integrity |
| B119 | Consumed bindings leak a key release when modifiers change first. `LEDGER.md:186` | Input | Consumed chords must not leak unmatched key releases. | S | Typing; IME/byte integrity |
| B120 | Duplicate download query keys trap the app. `LEDGER.md:187` | Browser | Ordinary repeated URL parameters must not kill the host. | S | WebKit; callback/origin |
| B121 | Count-limited page iteration truncates at the first page. `LEDGER.md:188` | Engine | Screen iteration must not silently truncate content. | S | Engine ABI; deadlock/ownership |
| B137 | PWD callback routes through the active window. `LEDGER.md:204` | Restore | Persist the originating window's cwd, not a focused sibling's. | S | Restore; identity/data loss |
| B139 | Growing Metal buffers repeatedly allocate too much memory. `LEDGER.md:206` | Engine | Repeated oversized Metal allocations are a concrete bug, independent of reclaim. | S | Engine ABI; deadlock/ownership |
| B143 | IME commits outside keyDown bypass application key encoding. `LEDGER.md:210` | Input | Composed commits must retain keyboard-protocol semantics. | M | Typing; IME/byte integrity |
| B148 | Keys that arrive before the Ghostty runtime exists are passed to `super`, so AppKit beeps or inserts them into the wrong view. `LEDGER.md:215` | Input | Early keys must not be forwarded into an unrelated responder. | S | Typing; IME/byte integrity |
| B153 | Mixed pasteboard items lose text and item order. `LEDGER.md:220` | Input | Mixed clipboard content must retain text and order. | S | Typing; IME/byte integrity |
| B160 | Pane ownership lookup reads every tab model and subscribes portal views to title changes. `LEDGER.md:227` | Main | Identity lookup must not subscribe portals to title churn. | S | Typing; layout/queue reentry |
| B162 | Popup navigation can abandon its required policy callback. `LEDGER.md:229` | Browser | A missing delegate must still complete WebKit policy exactly once. | S | WebKit; callback/origin |
| B166 | Rebuilding a renderer row reads `shaped_cells[shaper_cells_i]` before checking the index, and traps when the tail is empty. `LEDGER.md:233` | Engine | Renderer tail access can trap on wide glyphs/preedit. | S | Engine ABI; deadlock/ownership |
| B171 | Repeated config finalization removes custom matchers. `LEDGER.md:238` | Engine | Repeated finalize can exhaust matcher slices and trap. | S | Engine ABI; deadlock/ownership |
| B175 | Restored or new background terminals start with incorrect Ghostty focus. `LEDGER.md:242` | Lifetime | New background agents must not inherit active focus. | M | Lifetime; teardown deadlock |
| B180 | Autosave repeats unchanged defaults writes. `LEDGER.md:247` | Main | Stop periodic no-op defaults invalidation of the sidebar. | S | Typing; layout/queue reentry |
| B184 | Sidebar controls can target the stale global active window. `LEDGER.md:251` | Restore | Destructive sidebar controls must use their owning window. | M | Restore; identity/data loss |
| B188 | Rows own settings observers and repeat workspace scans. `LEDGER.md:255` | Main | Reduce row settings fan-out in the known congestion path. | M | Typing; layout/queue reentry |
| B189 | Socket writes have neither completion handling nor deadlines. `LEDGER.md:256` | Socket | Long-lived readers need full replies and bounded writer lifetimes. | S | Wire compatibility; targeting |
| B193 | Switching away from c11 synchronously snapshots all sessions. `LEDGER.md:260` | Restore | App switching must not synchronously capture the whole fleet. | M | Restore; identity/data loss |
| B197 | Lagging binding overwrites the live text-box draft. `LEDGER.md:264` | Input | Preserve the operator's in-progress draft. | S | Typing; IME/byte integrity |
| B203 | URL drops use file paths and differ from paste. `LEDGER.md:270` | Input | Dropped URLs must not be changed into file paths. | S | Typing; IME/byte integrity |
| B204 | Selection comparison reads freed pins. `LEDGER.md:271` | Engine | Selection must not compare freed pins. | S | Engine ABI; deadlock/ownership |
| B246 | Restored terminals start before the control socket listens, so restore-time CLI calls fail. **Probable.** `LEDGER.md:313` | Restore | Restored wrappers need a listening socket before launch. | M | Restore; identity/data loss |
| B247 | Resume does not check whether a surviving process already owns the session writer. **Probable.** `LEDGER.md:314` | Restore | A surviving session writer must not be resumed a second time. | M | Restore; identity/data loss |
| B248 | Resume launches from a drifted terminal directory instead of the session directory. **Probable.** `LEDGER.md:315` | Restore | Resume must use the session's intended project directory. | M | Restore; identity/data loss |
| B257 | Terminal readiness is published before queued input is flushed and focus is retried. **Probable.** `LEDGER.md:324` | Lifetime | Ready must mean pending input ordering is safe. | M | Lifetime; teardown deadlock |
| B266 | `c11 send-key` keeps only the first key and silently drops the rest. `LEDGER.md:333` | Input | Extra key arguments must be rejected or delivered, never silently dropped. | S | Typing; IME/byte integrity |
| B295 | Japanese IME Backspace wipes preedit. `LEDGER.md:362` | Input | Composition Backspace must preserve the remaining draft. | S | Typing; IME/byte integrity |
| B305 | Option dead-key composition uses a modifier-stripped event. `LEDGER.md:372` | Input | Dead-key text must retain the input event's modifiers. | S | Typing; IME/byte integrity |
| B309 | Printable non-US punctuation can be mistaken for a key equivalent. `LEDGER.md:376` | Input | Printable non-US input must not be consumed as a shortcut. | S | Typing; IME/byte integrity |
| B324 | DOMRect eval results may crash WebKit deserialization. **Probable.** `LEDGER.md:391` | Browser | Protect supported older-macOS users from host crashes. | S | WebKit; callback/origin |
| B355 | Restore retains empty phantom windows. **Probable.** `LEDGER.md:422` | Restore | A cheap restore filter prevents empty-window recovery failures. | S | Restore; identity/data loss |

# 4. Clusters

These are implementation boundaries, not one cherry-pick per ledger row.

1. **Engine queues and shutdown.** B010, B021, B022, B031, B062 and B065 are related but have different consumers and failure modes. Make producer waits teardown-abortable before joining workers. Bound app drain turns and explicitly re-wake. Publish renderer lifecycle state through a nonblocking latest-value slot. Bound child shutdown and reap safely. A larger mailbox alone fixes none of the dependency cycles. Evidence: `ghostty/src/termio/stream_handler.zig:125-139`, `ghostty/src/Surface.zig:3336-3354`, `ghostty/src/App.zig:238-260`, `LEDGER.md:88-89,129`, `notes/2026-08-25-freeze-surface-deinit-deadlock.md:86-91,140-151`.

2. **Input transport and ownership.** Atomic paste B013, pooled write ownership B047, WouldBlock handling B072 and key encoding B002 are separate fixes in one byte-integrity lane. Add the newly found UTF-8 framing defect from section 9. A successful socket acknowledgement must not be confused with complete PTY delivery. Evidence: `ghostty/src/Surface.zig:6302-6324`, `ghostty/src/datastruct/segmented_pool.zig:34-59`, `Sources/TerminalController.swift:6584-6605,2012-2021`, `LEDGER.md:139`.

3. **Terminal content memory safety.** Engine rows in section 3 cover resize, pins, search, glyph bounds, allocation and parser leaks. Port their minimal corrections together, with one coherent GhosttyKit artifact. This is a patch set, not a claim that one fix retires all engine rows. Especially keep B054's allocation-failure rollback distinct from B139's repeated oversized Metal allocation. Evidence: `LEDGER.md:82,87-89,101,103-106,108,112,119-124,206,233,271`.

4. **Retirement and cold startup.** Make closed lifecycle state irreversible and make headless host adoption idempotent. Use one explicit retirement operation for window close, restore replacement and late callback rejection. That operation can retire B018, B068, B069 and B075 together, **inference**, once the retention and late-start paths are covered. B003/B087 still need their own cold-start entry correction. Do not solve blank views by forcing synchronous layout. Evidence: `Sources/GhosttyTerminalView.swift:2921-2972`, `Sources/ContentView.swift:1482`, `LEDGER.md:85,135-136,142,154`.

5. **Restore transaction and identity.** Validate the full snapshot before installing it. Preserve bounded history and a known-good recovery candidate. Start the socket before resuming agents. Preserve durable refs, intended cwd and single-writer admission. B044 belongs in the already planned journal/restore contract, not another competing notification persistence store. Evidence: `LEDGER.md:71-74,91,111,113,125,313-315`; journal consumers at `../C11-1.0.md:130-151`. Inference: a shared restore boundary prevents these fixes from contradicting each other.

6. **Main-thread publication and layout.** First coalesce tick/scrollbar work (B030/B033) and defer focus broadcasts (B032). Remove reentrant layout edges (B014/B049/B056/B067). Publish immutable sidebar values instead of reading the metadata queue from body (B043/B059/B188). Preserve c11's SwiftUI sidebar and its identity/equality contract. The **largest plausible single retirement change is the common lifecycle retirement operation above, four rows**. The **highest-value narrow sidebar change is snapshot publication, three rows**; it does not retire the separate row-height or drag feedback bugs B029/B060. Evidence: `Sources/GhosttyTerminalView.swift:1069-1075,2161-2180`, `Sources/ContentView.swift:8535-8543,12024-12037,12964-12973`, `Sources/Workspace.swift:10137-10143,10238-10242`, `LEDGER.md:99,110,116,126`.

7. **Browser host safety.** Close inspectors before host destruction, finish every policy callback, defer replacement WebViews outside termination callbacks, normalize eval return values, and sequence state-load writes against the committed origin. Keep cookie scope explicit. These are independent small corrections, not a browser replacement. Evidence: `LEDGER.md:141,145,147,180,187,229,391`.

8. **Shell/helper lifetime.** Tie watchers to process identity, prevent wrapper cycles and bound transcript reads. B027's new spool and B125/B185's poll consolidation are useful follow-ups, not prerequisites for fixing orphan growth. Evidence: `Resources/shell-integration/cmux-zsh-integration.zsh:454-472,500-513`, `Resources/bin/claude:207`, `LEDGER.md:95,131,192,252`.

**Memory distinction.** B139 is a concrete allocation defect and stays must-do. B035/B140 are absence-of-reclaim policies for live hidden content, not proven leaks per creation/close. B135 is retained high-water memory. Do not label all three “unbounded growth” or use them to authorize GPU reclaim. Closed-owner leaks B018/B069 are a different class. Evidence: `LEDGER.md:85,102,136,202,206-207`; ruling at `audit-brief-astra.md:65`.

# 5. Build order

Recommendation: three implementation waves and one integrated acceptance wave, all shipping in **1.0**. Run independent lanes in parallel when implementation is authorized. This audit does not launch them. Sizes are relative. 112 ledger obligations do not imply 112 PRs, nor does the static evidence justify an overnight completion promise.

## Wave 1: eliminate blocking dependencies and unsafe byte transport

Start the Ghostty artifact lane immediately. Cancellation must be visible before joins, including the renderer-first teardown path. B031 must retain the final focus/visibility state; B065 must re-wake after a bounded drain. In parallel, fix watcher lifetime, wrapper recursion, unsafe inherited config ownership and the socket framing/bounds findings in section 9. B030/B033 can land as one coalesced callback change. This makes subsequent close/restore work safer.

Ledger coverage: B001, B010, B015, B018, B019, B020, B021, B022, B023, B026, B028, B030, B031, B033, B034, B036, B037, B039, B041, B042, B045, B047, B052, B053, B054, B055, B057, B062, B063, B064, B065, B066, B072, B121, B139, B166, B171, B189, B204.

Future gate: deterministic full-mailbox shutdown, child ignoring SIGHUP, out-of-order writes, split UTF-8 frames, repeated create/close and parser/resize boundaries. Run builds and sustained load on Atlas. Highest deadlock risk: B010/B021/B022/B031/B062/B065. Highest typing risk: B030/B033 and the input mailbox changes.

## Wave 2: preserve restore state, ownership and exact input

Use the safe teardown baseline before retiring replaced graphs. Land snapshot validation/history and durable ref allocation before widening resume. Bring the listener up before wrapper launches. Resolve cold-host adoption before capping mount concurrency so background agents still start. Keep input/IME ports together with byte-level fixtures, but do not replace the whole input subsystem.

Ledger coverage: B002, B003, B004, B005, B007, B008, B012, B013, B017, B024, B025, B038, B040, B044, B046, B048, B050, B051, B058, B068, B069, B073, B075, B081, B087, B089, B093, B098, B112, B114, B115, B118, B119, B137, B143, B148, B153, B175, B184, B193, B197, B203, B246, B247, B248, B257, B266, B295, B305, B309, B355.

Future gate: restore under concurrent wrapper traffic, malformed/duplicate snapshot IDs, failed partial restore followed by a second restart, stale handles, wrong-window close, queued input before first display, locale-specific composition and clipboard preservation. Typing/deadlock risk: B003/B012/B068/B069/B075/B089/B093/B114/B175/B193/B257. Persistence risk: all Restore rows.

## Wave 3: remove main-thread fan-out and browser host crashes

With startup/ownership stable, remove layout reentry and cross-queue sidebar reads. B056 needs replacement bounded retries, not just deleting an observer. Keep snapshot isolation inside the existing sidebar. Browser callback and data-scope fixes can run as a separate lane. Trace B006's remaining main-bound callers rather than replacing the helper with an indiscriminate failure return.

Ledger coverage: B006, B014, B029, B032, B043, B049, B056, B059, B060, B067, B074, B078, B080, B083, B086, B113, B120, B160, B162, B180, B188, B324.

Future gate: pointer/typing latency with streaming agents, scrolling while layout settles, repeated drag/drop, sidebar metadata bursts, inspector close, WebContent termination, controlled origin storage load and scoped cookie clear. Typing risk: B014/B029/B032/B043/B049/B056/B059/B060/B067/B086/B160/B180/B188. Deadlock/reentry risk: B006/B014/B032/B049/B056/B067.

The wave memberships inherit the row-specific evidence and risks in section 3. Their dependency order is an inference from those mechanisms. Build placement follows the plan's Atlas requirement (`../C11-1.0.md:312-316`).

## Wave 4: one integrated 1.0 acceptance pass

After the component gates, drive a packaged tagged build with the real socket, real agent startup, simultaneous output, surface churn, autosave, restart and recovery. Include a 16 GB memory budget, international input, and supported older macOS browser coverage. Check both typing latency and bounded shutdown. These are proposed gates; none were run for this audit. A passing unit suite alone would not establish the user paths.

Do not let nice-to-have work delay the high-risk artifact and restore lanes. Also do not waive unresolved probable must-do rows merely because a wave is scheduled to finish overnight. First establish or disprove their stated trigger. An explicit disproof can retire the obligation; a missing reproducer alone is not a fix.

# 6. Nice to have

**119 rows.** Pick small adjacent fixes after the relevant must-do lane is stable. “Reported” preserves the source verdict; “probable” requires verification before changing behavior.

| Ledger id | Bug | Why it can slip | Size | Evidence |
|---|---|---|---|---|
| B011 | Background JSON encoding can overflow the worker stack for deeply nested splits | Reported. About 150 nested splits is outside the normal fleet shape; retain a defensive depth limit. | S | `LEDGER.md:78` |
| B016 | Unread-ring changes rebind the terminal portal | Reported. Remove the needless bind while touching portals; c11 blanking was not reproduced. | S | `LEDGER.md:83` |
| B027 | Each Claude hook event launches the full c11 CLI | Reported. Real spawn overhead; a spool is an architectural optimization, not proven unbounded growth. | M | `LEDGER.md:94` |
| B061 | Spinner-only terminal titles are still published as real title changes | Reported. Filter title-only spinner churn; cost is real but not a separate proven hang. | S | `LEDGER.md:128` |
| B070 | Korean IME arrow commits reuse the arrow keycode | Probable. Probable IME corruption; pin the c11 event sequence before changing encoding. | S | `LEDGER.md:137` |
| B077 | Workspace creation can overwrite a reentrant close or reorder with an older snapshot | Probable. Potential stale-snapshot loss; the ledger explicitly withdraws the claimed array UAF. | M | `LEDGER.md:144` |
| B079 | Controlled browser inputs retain old form state | Reported. High-value browser correctness; no host crash or fleet loss. | S | `LEDGER.md:146` |
| B082 | Global numeric locale can crash symbol rendering | Reported. Process-wide locale risk, with the reported crash tied to newer OS symbol rendering. | S | `LEDGER.md:149` |
| B084 | `refreshSurfaceNow` calls `forceRefresh` before AppKit has realized the hosted view, so a new split stays blank | Reported. Blank reveal recovery; integrate only after removing synchronous layout fixes. | S | `LEDGER.md:151` |
| B088 | A never-used Claude startup session is treated as resumable | Reported. Improve resume eligibility without treating empty sessions as durable work. | S | `LEDGER.md:155` |
| B090 | A resize that lands before the layer is a `CAMetalLayer` never retries the drawable size, so the first Metal frame stays at the old size | Reported. Retry first drawable sizing with a finite retry policy. | S | `LEDGER.md:157` |
| B091 | A revealed terminal can remain blank until another focus or geometry change | Reported. Repair reveal invalidation without adding forced drawing to every keystroke. | S | `LEDGER.md:158` |
| B092 | After `cd` out of a repo, the HEAD watcher still reports the old repo's branch, so the sidebar chip stays. | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:159` |
| B094 | Automatic git dirty-state reports can contend with agents for the repository index | Reported. Use optional-lock suppression or a cheaper probe; do not claim every git status locks. | S | `LEDGER.md:161` |
| B096 | Automatic terminal titles are stored and persisted without an application bound | Reported. Bound title admission; parser growth is not proven unbounded. | S | `LEDGER.md:163` |
| B100 | Bash prompt hook destroys the previous exit status | Reported. Preserve exit status; a small shell integration correction. | S | `LEDGER.md:167` |
| B101 | Bitmap allocator reserves unreachable chunk bytes | Reported. Concrete allocation waste, useful for 16 GB users. | S | `LEDGER.md:168` |
| B104 | Cancelling a delayed updater state drops Sparkle's required reply | Reported. An abandoned updater callback can strand that update, not the whole fleet. | S | `LEDGER.md:171` |
| B106 | Claude hooks fall back to the focused workspace | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:173` |
| B107 | Claude hooks retain and parse full large input payloads | Reported. Bound hook payload fields; transient allocation is not a persistent leak. | S | `LEDGER.md:174` |
| B108 | Claude short resume flag gets a conflicting fresh session ID | Reported. Respect -r before injecting a new session ID. | S | `LEDGER.md:175` |
| B109 | Claude Stop hooks surface expected teardown failures | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:176` |
| B110 | Claude subcommands outside the wrapper allowlist receive interactive flags | Reported. Expand utility-command classification without mutating tenant config. | S | `LEDGER.md:177` |
| B116 | Cmd-click links fail inside mouse-reporting TUIs | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:183` |
| B117 | Combining marks attach to the wrong cell at pending wrap | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:184` |
| B122 | Dense hyperlink maps accumulate expensive probe chains | Reported. Optimize dense link maps after memory-safety patches. | M | `LEDGER.md:189` |
| B123 | Port discovery misses agent children and clears on failed scans | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:190` |
| B124 | Direct interaction can leave notification unread while app-active state lags | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:191` |
| B125 | Each shell polls `gh` for PR status on its own 45 second loop. | Reported. Coalesce per-repository polls; bounded subprocess overhead. | M | `LEDGER.md:192` |
| B126 | Every notification update rebuilds notification rows and rescans workspace titles | Reported. Cache notification projections after the sidebar source fix. | S | `LEDGER.md:193` |
| B127 | Pointer hit-testing walks the whole window | Reported. Optimize the pointer-only divider lookup; measure before changing the hot path. | M | `LEDGER.md:194` |
| B128 | Every precise scroll delta is doubled, including high-resolution mice that are not trackpad gestures | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:195` |
| B129 | Every printable key calls `forceRefresh` on the typing path | Reported. Remove redundant refresh only with real typing validation. | S | `LEDGER.md:196` |
| B130 | Every workspace row registers a Bonsplit `onDrop`, so a drag asks every row to validate on the main thread | Reported. Consolidate drag validation without rewriting the sidebar. | S | `LEDGER.md:197` |
| B131 | Existing zsh aliases can break integration function definitions | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:198` |
| B132 | Find Next and Previous search for literal direction words | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:199` |
| B134 | Forward prompt navigation lands on continuation rows | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:201` |
| B135 | Freed scrollback pages retain their high-water footprint | Reported. High-water retention, not proven unbounded leakage. | S | `LEDGER.md:202` |
| B136 | Ghostty creates and destroys an `os_log` object on every log line | Reported. Cache log handles in the shared Ghostty patch batch. | M | `LEDGER.md:203` |
| B138 | GNU nc on PATH silently drops shell hook messages | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:205` |
| B141 | Hook reports fail before fallback routing when TabManager is unavailable | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:208` |
| B142 | Identical SGR attributes repeatedly churn the style map | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:209` |
| B145 | Incoming output pulls explicit wheel scrollback back to the bottom | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:212` |
| B146 | Injected Claude settings conflict with user settings arguments | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:213` |
| B147 | Equalize produces 50/25/25 for three panes | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:214` |
| B149 | Link matching crosses semantic shell prompt boundaries | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:216` |
| B150 | Listening-port scans still spawn `lsof`, which walks every fd slot up to `kern.maxfilesperproc` | Reported. Useful off-main CPU reduction; not a demonstrated main-thread hang. | S | `LEDGER.md:217` |
| B151 | Live resize sends every pixel change to the PTY | Reported. Coalesce resize notifications while preserving final grid size. | M | `LEDGER.md:218` |
| B154 | Modifier-only mouse updates are discarded | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:221` |
| B155 | Nested shells leave redundant parent Git HEAD watchers running | Reported. Nested-shell redundant watchers are bounded by live nesting; pair with B023 cleanup. | S | `LEDGER.md:222` |
| B156 | New workspace goes to the active window instead of the caller's window | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:223` |
| B157 | Notification attribution falls back to the focused pane when identity is missing | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:224` |
| B158 | Omnibar suggestions repeat whole-history and workspace scans on every keystroke | Reported. Bound suggestion work; validate typing latency. | M | `LEDGER.md:225` |
| B159 | Opening a path from an external terminal is rejected by default socket authorization | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:226` |
| B161 | Pointer forwarding hit-tests in the wrong coordinate space | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:228` |
| B164 | Provisional browser URLs replace the committed page URL | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:231` |
| B165 | Rapid workspace title changes keep rebuilding command-palette results | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:232` |
| B167 | Recovered window context is not reindexed, breaking later workspace creation | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:234` |
| B168 | Reload configuration walks every terminal and calls `forceRefresh` on the main thread. | Reported. Schedule reload work; configuration reload is less frequent than normal typing. | M | `LEDGER.md:235` |
| B169 | Reorder accepts conflicting selectors when one does not resolve | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:236` |
| B170 | Reparented shell reporters fail descendant-only socket authorization | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:237` |
| B173 | Restore startup titles replace persisted automatic surface names | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:240` |
| B174 | Restored listening ports remain visible after their processes have died | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:241` |
| B176 | Restored scrollback replays old theme OSC colors | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:243` |
| B178 | Clipboard callback synchronously encodes screenshots | Reported. Move encoding off the callback only with owned data and cancellation. | M | `LEDGER.md:245` |
| B181 | Prompt Git probes run outside repositories | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:248` |
| B182 | Shell prompt pays a process-tree `ps` and a fork/exec for every socket send | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:249` |
| B183 | Shell startup changes can bypass bundled wrappers and hook commands | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:250` |
| B185 | PR status repeats per-workspace subprocesses | Reported. Share repository results without losing per-workspace display state. | M | `LEDGER.md:252` |
| B186 | Sidebar resize hitbox intercepts terminal column zero | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:253` |
| B187 | Sidebar resize tracking runs on every mouse-move, including when the window is occluded, and arms a 16 ms main-queue timer | Reported. Gate hover work to visible windows; no c11 stall duration established. | S | `LEDGER.md:254` |
| B190 | Socket window focus can raise or unminimize a window | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:257` |
| B192 | Subagent completions can mark a still-working Claude pane as needing input | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:259` |
| B194 | Synchronous prompt hooks can outlive the agent's hook deadline | Reported. Bound hook latency; do not introduce a second lifecycle transport casually. | M | `LEDGER.md:261` |
| B195 | Terminal color-scheme reports use stale app state | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:262` |
| B196 | Terminal find field can reclaim focus from the command palette | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:263` |
| B198 | The divider overlay sets `needsDisplay` on every portal sync, even when the dividers did not change | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:265` |
| B200 | Old Sparkle helper may fail installation | Reported. Update dependency with signed-artifact proof; the version pin alone proves no install failure. | S | `LEDGER.md:267` |
| B201 | Unbound Cmd+Shift combinations can be swallowed before reaching the TUI | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:268` |
| B202 | Unmounting a workspace hides the terminal view but leaves it in the window | Reported. Detach hidden views only after ownership and reattach invariants are fixed. | S | `LEDGER.md:269` |
| B205 | v2 heartbeat waits behind the main-thread queue | Reported. Useful liveness signal; distinguish a live socket from a responsive UI. | S | `LEDGER.md:272` |
| B207 | When zsh's job table is full, cmux's precmd/preexec hooks error on every prompt. | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:274` |
| B208 | While command-palette Escape suppression is set, every Escape repeat is consumed and the timeout never runs | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:275` |
| B209 | Window commands send typed handles to a UUID-only legacy endpoint | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:276` |
| B210 | Reveal publishes intermediate PTY sizes | Reported. Hold final geometry through reveal; coordinate with the portal work. | M | `LEDGER.md:277` |
| B211 | CSP eval failures lack a useful fallback or error | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:278` |
| B214 | A stranded AppKit first responder leaves the selected terminal unable to type | Probable. Probable focus recovery gap; needs the real responder sequence. | M | `LEDGER.md:281` |
| B215 | Notification XPC may block main | Probable. Call thread was not traced by the verifier; establish main reachability first. | M | `LEDGER.md:282` |
| B216 | After a workspace switch, a portal entry can stay visible because the registry does not know which workspace owns it | Probable. A missing workspace gate is not itself proof of a visible stale portal. | M | `LEDGER.md:283` |
| B218 | An answered agent notification ring stays up until something else marks the notification read. | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:285` |
| B219 | An exited agent can be auto-resumed after a later restart | Probable. Confirm missed-exit behavior for Codex; normal Claude SessionEnd is already handled. | M | `LEDGER.md:286` |
| B221 | Close Other Tabs schedules competing confirmations instead of one batch | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:288` |
| B222 | Closed browser portal detachment depends on deinit | Probable. Explicit detach is worthwhile; retained-callback reachability remains inferred. | S | `LEDGER.md:289` |
| B224 | Cmd+Z can hit the window undo stack after the text box that registered it is gone | Probable. No c11 crash or dangling undo target was established. | M | `LEDGER.md:291` |
| B225 | Ending search from the menu may leave terminal focus behind | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:292` |
| B226 | Equalize can be overwritten while nested split geometry settles | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:293` |
| B227 | Escape can miss terminal find after responder focus moves | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:294` |
| B230 | Hot PTY output can starve renderer snapshots | Probable. Scheduler fairness hypothesis needs a measured renderer starvation case. | S | `LEDGER.md:297` |
| B233 | Keyboard copy mode stays armed on a pane after focus leaves it | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:300` |
| B234 | Late Claude notification status can survive an abrupt agent exit | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:301` |
| B236 | Losing a main-window context makes surviving terminals unreachable through routes | Probable. Confirm route-loss reachability before adding another context registry. | M | `LEDGER.md:303` |
| B237 | Lost mouse releases leave terminal selection or button state stuck | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:304` |
| B240 | Multiple tab IDs can retain the same panel mapping | Probable. Assert mapping uniqueness first; the verifier did not create a duplicate mapping. | M | `LEDGER.md:307` |
| B242 | Pane resize applies the latest Ghostty scrollbar packet as the scroll origin, so a review position jumps | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:309` |
| B255 | SwiftUI `.textSelection(.enabled)` sits on markdown that live-reloads | Probable. Prove live-selection/reload hang before removing useful text selection. | S | `LEDGER.md:322` |
| B258 | Terminal title callbacks and undeduplicated window-title writes flood main | Probable. Coalesce title callbacks and dedupe window titles; do not claim upstream timing locally. | S | `LEDGER.md:325` |
| B260 | Titlebar buttons can act on the previously active window | Probable. Bind titlebar actions to their window after identifying destructive callbacks. | M | `LEDGER.md:327` |
| B265 | "Mark Workspace as Unread" stays disabled once the read notification objects are gone. | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:332` |
| B267 | `cookies set` ignores `httpOnly`, and `cookies get` does not report it. | Reported. Respect cookie attributes in automation. | S | `LEDGER.md:334` |
| B275 | Bash integration erases a prompt callback appended by Starship | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:342` |
| B283 | Drag-to-split omits focus-owner reconciliation | Reported. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:350` |
| B288 | Font-name logging can abort otherwise valid font setup | Reported. A font diagnostic should not abort setup; pair with B045. | S | `LEDGER.md:355` |
| B302 | Non-Latin input sources prevent Latin keyboard shortcuts matching | Reported. Public international-keyboard support merits a compact follow-up. | S | `LEDGER.md:369` |
| B335 | Browser file drops omit drag lifecycle steps | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | S | `LEDGER.md:402` |
| B337 | Detached hook processes fail descendant-only socket authorization | Probable. Worth correcting; lower priority than the fleet safety and recovery work. | M | `LEDGER.md:404` |
| B339 | IME numpad fallback can duplicate a deferred digit commit | Probable. Probable duplicate IME input; confirm the deferred-commit path. | S | `LEDGER.md:406` |
| B341 | Korean IME composition can leak intermediate jamo | Probable. Probable composition leakage; use language-specific input fixtures. | S | `LEDGER.md:408` |
| B352 | Additional inspector close/redock/reopen defects | Probable. Take proven inspector cases with B113; do not import speculative lifecycle scaffolding. | S | `LEDGER.md:419` |
| B362 | Text-box IME replacement ranges lack clamping | Probable. Possible text-box crash; first trace AppKit replacement-range ownership. | S | `LEDGER.md:429` |

# 7. Not a priority

**134 rows.** This is release prioritization, not a claim that every report is false. Cosmetic behavior, absent optional policies, weakly established triggers and disproportionate ports stay out of the critical path.

- **B035**: Hidden terminals retain their GPU swap chains indefinitely. No clear per-live-surface leak established. Missing GPU reclaim alone does not meet Atin's ruling. `LEDGER.md:102`.
- **B071**: Old window geometry survives a schema-changing upgrade. Probable. No c11 schema-changing migration was established. A v1 key alone is not a defect. `LEDGER.md:138`.
- **B076**: Unbounded SF Symbol sizing can crash launch on macOS 27. Probable. No c11 oversized symbol input established; reported newer-OS crash needs qualification. `LEDGER.md:143`.
- **B085**: Open-wrapper trimming can crash a non-system bash. Report depends on a non-system bash; verify the shipped wrapper interpreter first. `LEDGER.md:152`.
- **B095**: Automatic terminal insets can add a second titlebar gap. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:162`.
- **B097**: Background workspace prime starts a Ghostty surface for every terminal pane, including idle ones with nothing to run. A background terminal intentionally running a shell is not automatically waste. `LEDGER.md:164`.
- **B099**: Bash vi-mode redraw inserts extra newlines. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:166`.
- **B102**: Bulk-close confirmation text can exceed the available viewport. Confirmation overflow is bounded UI work; add scrollability opportunistically. `LEDGER.md:169`.
- **B103**: Cached update state can keep the first detected version visible. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:170`.
- **B105**: CJK fallback fonts use the wrong terminal-cell span. Visual fallback metrics; keep original Unicode text intact. `LEDGER.md:172`.
- **B111**: Clicking update can abandon the install when a transient idle arrives before `.updateAvailable`. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:178`.
- **B133**: Focused terminal notifications skip local sound playback. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:200`.
- **B140**: Hidden browser panes keep their WKWebViews for the life of the workspace. Retained hidden documents preserve form state; absence of discard is not a leak. `LEDGER.md:207`.
- **B144**: IME preedit shifts left one cell too early. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:211`.
- **B152**: Managed PATH is prepended without dropping U+FFFD or control-byte components, so a malformed parent PATH is re-exported into every new pane. Requires a malformed inherited PATH. `LEDGER.md:219`.
- **B163**: PR badges can miss an open PR on the upstream repository. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:230`.
- **B172**: Resizing the tab strip recenters the selected tab before snapping back. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:239`.
- **B177**: Same-display restoration leaves saved windows partly offscreen. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:244`.
- **B179**: Selected workspaces stay outside the sidebar viewport after navigation or reorder. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:246`.
- **B191**: Spaced file links absorb neighboring prose or punctuation. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:258`.
- **B199**: The GUI binary ignores CLI argv. If `c11` resolves to `Contents/MacOS/c11`, a subcommand is dropped and the process is later SIGTERMed (exit 143). Wrong binary on PATH; normal bundled CLI routing already exists. `LEDGER.md:266`.
- **B206**: Variation selectors inspect the wrong codepoint. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:273`.
- **B212**: A new window opened while another window is fullscreen lands in the current Space. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:279`.
- **B213**: A port badge can stick after the owning process is a zombie, privileged, or the TTY is gone, because scans only update panels still in the TTY map. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:280`.
- **B217**: Agent CLI state access can trigger macOS app-data prompts. Probable. Possible OS prompt; no c11 reproduction or authorization failure established. `LEDGER.md:284`.
- **B220**: Apple Silicon can launch the universal app through Rosetta. Probable. Rosetta launch is optional performance hardening. `LEDGER.md:287`.
- **B223**: Cmd-click does not match a URL that soft-wraps across rows. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:290`.
- **B228**: Ghostty's own keybinds are consulted and can consume the event before c11's shortcut owner. Probable. Depends on a conflicting user keybinding configuration. `LEDGER.md:295`.
- **B229**: Host appearance and live terminal configuration can retain different color schemes. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:296`.
- **B231**: Inherited Claude bridge identity contaminates a fresh local launch. Probable. Requires inherited bridge variables from an unusual launch path. `LEDGER.md:298`.
- **B232**: Key events still hit-test the browser portal. Probable. Remaining super.hitTest call alone does not prove key-event work. `LEDGER.md:299`.
- **B235**: Link opening is not tied to one deliberate Command-click gesture. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:302`.
- **B238**: Custom saved frames may remap across display changes. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:305`.
- **B239**: Metal command queues keep their default driver capacity. Probable. Driver queue capacity is tuning, not a demonstrated leak. `LEDGER.md:306`.
- **B241**: Native fullscreen tiling can trap the main window in a managed Space. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:308`.
- **B243**: Port-scanner Process/Pipe cleanup may retain resources or delay completion. Probable. Process/Pipe ownership concern is unproven; do not infer a hang from a missing explicit close. `LEDGER.md:310`.
- **B244**: Quit has no deadline if AppKit blocks in `applicationWillTerminate`. Probable. A watchdog masks hangs; fix the established quit cycles first. `LEDGER.md:311`.
- **B245**: Restore-time terminal binding can leave portal geometry stale. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:312`.
- **B249**: Screen changes synthesize an extra backing-geometry update and can flicker terminals. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:316`.
- **B250**: Background browser screenshots may be stale. Probable. Large render-lease machinery for a secondary automation edge. `LEDGER.md:317`.
- **B251**: Browser restore starts all WebContent processes eagerly. Probable. Browser-heavy startup is not the terminal-heavy fleet's dominant load. `LEDGER.md:318`.
- **B252**: Settings can open off the visible screen, and the open path does not pull the window back. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:319`.
- **B253**: Sidebar PR status keeps being collected when the sidebar is hidden. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:320`.
- **B254**: Sidebar toggle can flash the desktop through the terminal for a few frames because the GPU background lags the view resize. Probable. Transient cosmetic flash with a large renderer change. `LEDGER.md:321`.
- **B256**: SwiftUI intrinsic width can ratchet the main-window minimum upward. Probable. No specific c11 minimum-width ratchet sequence was established. `LEDGER.md:323`.
- **B259**: Unverified Bonsplit geometry feedback loop. Probable. Verifier did not diff the Bonsplit bump. Context anchor is not proof. `LEDGER.md:326`.
- **B261**: Unverified minimal-mode layout loop. Probable. Verifier did not trace a c11 minimal-mode loop. `LEDGER.md:328`.
- **B262**: Vim copy-mode Y copies by faking a mouse drag on the visible viewport, and c11 ghostty has no absolute screen-row selection API. Probable. Large new selection API for a secondary copy-mode edge. `LEDGER.md:329`.
- **B263**: Visual terminal bells can raise background windows in Stage Manager. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:330`.
- **B264**: Workspace switches still flush AppKit layout for the terminal portal hierarchy. Probable. Existing deferred flush alone does not establish the upstream callback reentry. `LEDGER.md:331`.
- **B268**: `DebugEventLog` calls `seekToEndOfFile` on `NSFileHandle`, which throws an ObjC exception. Debug-only logger path. `LEDGER.md:335`.
- **B269**: `goto_split` at a layout edge reports success. `moveSplitFocus` always returns true, so Ghostty `performable:` keybind chains break. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:336`.
- **B270**: `goto_split` previous/next only move left/right, so a vertical neighbor is skipped. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:337`.
- **B271**: `simulate_shortcut` builds an `NSEvent` and can raise `NSException` from `interpretKeyEvents` on a plain character. Debug/test shortcut injection, not normal product input. `LEDGER.md:338`.
- **B272**: `window.close()` from a page does nothing in a normal browser pane (no `webViewDidClose` in the main UI delegate), so OAuth/pop-out pages leave blank panes behind. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:339`.
- **B273**: A pane-local OSC 11 background leaks into the whole window. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:340`.
- **B276**: CJK fallback injection overrides explicit font families and fonts that already cover the glyphs. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:343`.
- **B277**: Cmd+Shift+T reopen retargets a closed browser snapshot to the selected workspace when its own workspace is gone, resurfacing stale URLs in unrelated workspaces. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:344`.
- **B278**: Configured working directory does not expand tilde. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:345`.
- **B279**: Covered terminal windows can assert divider cursors. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:346`.
- **B280**: Ctrl+K moves palette selection instead of deleting text. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:347`.
- **B281**: Cursor reset ignores the configured default style. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:348`.
- **B282**: Double-click selection unnecessarily repositions the terminal cursor. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:349`.
- **B284**: Empty clipboard paste cannot decline a performable binding. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:351`.
- **B285**: Enter from theme-picker search exits search instead of applying. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:352`.
- **B286**: Feedback editor retains an oversized document after text shrinks. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:353`.
- **B287**: Find routing scans weak portal entries. Upstream stack failure cited 166 panes; no c11 reproduction at this profile. `LEDGER.md:354`.
- **B289**: Forced Korean fallback font overrides normal font selection. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:356`.
- **B290**: Ghostty helper loses buffered action-list output. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:357`.
- **B291**: Ghostty resize_split bindings do nothing. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:358`.
- **B292**: Greedy spacing makes short surface tabs wider than their content. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:359`.
- **B293**: If the bundled shell-integration directory is missing, c11 still exports `ZDOTDIR` at it and zsh skips the user's config. Damaged bundle only. `LEDGER.md:360`.
- **B294**: Injected Japanese fallback font can select an unintended thin weight. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:361`.
- **B296**: Legacy filename pasteboard drops are not recognized. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:363`.
- **B297**: Locale initialization hard-codes Linux constants on macOS. Platform-locale edge; do not expand the engine patch without a concrete affected path. `LEDGER.md:364`.
- **B298**: Long updater error details overflow the popover. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:365`.
- **B299**: Long-path zsh prompts gain synthetic blank spacer lines. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:366`.
- **B300**: Middle-click can paste stale selection instead of the system clipboard. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:367`.
- **B301**: Minimal-mode toggles leave titlebar accessories detached or zero-sized. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:368`.
- **B303**: Notification Settings opens the legacy generic destination. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:370`.
- **B304**: Opt-in background log does synchronous open/seek/write/close under a lock. Explicitly opt-in diagnostics. `LEDGER.md:371`.
- **B306**: Option-arrow bindings for general actions do not match recorded arrow glyphs. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:373`.
- **B307**: Out-of-range Cmd+number escapes workspace shortcut handling. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:374`.
- **B308**: Overlapping hover rules underline a different span than clicks resolve. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:375`.
- **B310**: Restored windows spanning displays are unnecessarily clamped. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:377`.
- **B311**: Single-slot theme selection writes an incomplete conditional theme. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:378`.
- **B312**: Some personal-information requests from terminal children lack current TCC declarations. Add TCC declarations only for supported capabilities with a demonstrated failure. `LEDGER.md:379`.
- **B313**: SSH environment helper overrides user SetEnv values. Ghostty SSH environment helper is outside the core local fleet path. `LEDGER.md:380`.
- **B314**: SSH helper cache loading mishandles allocation failure. OOM handling in an ancillary SSH cache helper. `LEDGER.md:381`.
- **B315**: Successful Claude hooks emit visible OK blocks. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:382`.
- **B316**: Swift theme parser rejects symlinked configuration files. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:383`.
- **B317**: Swift theme parsing can override a later explicit color setting. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:384`.
- **B318**: Terminal scrollbar ignores the Ghostty visibility setting. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:385`.
- **B319**: Terminal theme discovery omits app-specific user theme directories. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:386`.
- **B320**: Trailing percent signs combine with zsh prompt marks. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:387`.
- **B321**: Transparent terminals do not apply Ghostty window blur and lack the compositor-friendly backing layer. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:388`.
- **B322**: Vim copy keys fail with non-ASCII input sources. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:389`.
- **B323**: Zhuyin IME candidate state is not represented in marked-text selection. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:390`.
- **B325**: Browser onAppear repeats setup. Probable. Repeated setup is present; upstream discard-navigation loop is absent. `LEDGER.md:392`.
- **B326**: `goto_split` can skip the adjacent column. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:393`.
- **B327**: `zh-Hant` is stored as a raw `AppleLanguages` string, and choosing System deletes the key. Probable. Language override edge, with platform behavior inferred. `LEDGER.md:394`.
- **B328**: A broken process pipe can crash an `NSFileHandle` readability handler. Probable. Ancillary VS Code pipe, not the fleet socket loop. `LEDGER.md:395`.
- **B329**: A coalesced live-resize geometry pass can take the slow path and trail the drag by extra runloop turns. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:396`.
- **B330**: A malformed `LC_ALL` makes the spawned shell fall back to the `C` locale. Probable. Requires a malformed parent locale. `LEDGER.md:397`.
- **B331**: A relative path beginning with a literal tilde may be expanded by the shell. Probable. Shell expansion depends on tilde position; normal escaped absolute paths are unaffected. `LEDGER.md:398`.
- **B332**: A reparented drop overlay animates from coordinates belonging to its old pane. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:399`.
- **B333**: A second surface inherits a font pointer the first surface already freed (Intel crash). Probable. Borrowed-pointer trigger was not proven in c11; do not justify by Intel exclusion alone. `LEDGER.md:400`.
- **B334**: An oversized sidebar subtree is centered and clips its leading edge. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:401`.
- **B336**: Decomposed Hangul uses the wrong fallback font and shaping path. Probable. Font shaping edge, with a larger engine port and no input-byte corruption shown. `LEDGER.md:403`.
- **B338**: Extreme drag coordinates can overflow integer conversion. Probable. Extreme synthetic coordinates have no established AppKit trigger. `LEDGER.md:405`.
- **B340**: IME preedit does not update text box height. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:407`.
- **B342**: Local browser panes leave `proxyConfigurations` empty, so WebKit sends `localhost`/`127.0.0.1` through the macOS system proxy (Clash/Surge) and dev servers fail. Probable. System-proxy edge; no general localhost failure established. `LEDGER.md:409`.
- **B343**: Markdown links inferred broken from absent OpenURLAction. Probable. Missing custom OpenURLAction does not prove default link handling is broken. `LEDGER.md:410`.
- **B344**: Menu Copy always calls parameterless `copy_to_clipboard`, ignoring a configured Ghostty flavor. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:411`.
- **B345**: Minimal-mode portal overlap can intercept tab-strip drags. Probable. Portal-overlap trigger differs in c11 and remains unproven. `LEDGER.md:412`.
- **B346**: Native Ghostty Sentry initialization races locale/environment mutation. Probable. Startup race is inferred for c11's older environment implementation. `LEDGER.md:413`.
- **B347**: No `window.showOpenFilePicker` support (upstream adds a polyfill/handler). Probable. Missing browser capability is feature work. `LEDGER.md:414`.
- **B348**: Notification jump fails when the notification carries a Bonsplit tab UUID instead of a panel UUID (nested tabs). Probable. No c11 producer of the wrong notification UUID was identified. `LEDGER.md:415`.
- **B349**: Option dead-key composition can use the wrong keyboard-layout translation. Probable. Keyboard-layout translation hypothesis needs a concrete sequence. `LEDGER.md:416`.
- **B351**: Printable Option combinations can be consumed as application shortcuts. Probable. Probable Option shortcut conflict needs a concrete c11 binding. `LEDGER.md:418`.
- **B353**: Reload Configuration menu action can fail to dispatch. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:420`.
- **B354**: Reordered combining glyphs can use another cluster's anchor. Probable. Rare combining-glyph placement; no input-byte loss shown. `LEDGER.md:421`.
- **B356**: Runtime config callbacks can overwrite a newer theme preview's host colors. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:423`.
- **B357**: Shell integration still starts helpers for features the user turned off, before the first prompt. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:424`.
- **B358**: Shell-integration cursor feature is left on, so prompts can leave the block cursor. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:425`.
- **B359**: Simple scripted searches open a popup instead of staying in the browser tab. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:426`.
- **B360**: Socket timeout `timeval` microseconds are not clamped, so some fractional timeouts are rejected by `setsockopt`. Probable. Only near-boundary fractional timeout values trigger rounding overflow. `LEDGER.md:427`.
- **B361**: Sparkle is 2.8.1, older than the 2.9.5 bump that mitigates updater-agent timeouts under endpoint security. Probable. Endpoint-security-specific update timeout; combine with a justified Sparkle upgrade. `LEDGER.md:428`.
- **B363**: The Copy menu guard uses `charactersIgnoringModifiers`, which disagrees with AppKit on Command-swapped layouts. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:430`.
- **B364**: Theme picker waits for an event before its first draw. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:431`.
- **B365**: Titlebar controls can be mistaken for draggable empty chrome. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:432`.
- **B366**: Unfocused-split dim updates one runloop turn after focus, so a revealed pane flashes dim, then bright. Probable. One-turn dim flash is cosmetic. `LEDGER.md:433`.
- **B367**: Updater badge can disappear during SwiftUI symbol rendering. Probable. Low-impact edge or presentation detail; defer behind fleet safety. `LEDGER.md:434`.
- **B368**: Vim-mode cursor shape is drawn without Ghostty's effective cursor visual state. Probable. Copy-mode cursor appearance is cosmetic. `LEDGER.md:435`.

# 8. Rejected

- **B009, already guarded on the required head.** `close-surface` resolves to `close-tab`; empty target flags are rejected before normalization. The verifier read an older path. Evidence: `CLI/c11.swift:2626-2636,11765,11881-11888`; original claim `LEDGER.md:76`. Do not reopen this fix merely because the older line numbers still show a normalizer elsewhere.
- **B274, desired fail-closed behavior.** A parsed explicit dead surface UUID must not silently become the operator's focused pane. Upstream PR 2518 deliberately adds that fallback; it conflicts with safe agent targeting. Evidence: `Sources/SocketHandlers/SurfaceHandlers.swift:316-323`; upstream `096ed627eb^1..096ed627eb:Sources/TerminalController.swift`, hunk 4649; `LEDGER.md:341`. This is a policy rejection, not a denial that the implementations differ.
- **B350, semantic expansion rather than a required repair.** The current send-text path is input/paste, including explicit submit handling. Upstream PR 5509 adds a distinct `processOutput` event and routes complete control strings into Ghostty's output parser. That does not show c11's input contract is broken. Reject silently reinterpreting supplied input as rendered output. A separately specified output-injection command would be feature work. Evidence: `Sources/GhosttyTerminalView.swift:3963-3988`; upstream `97cf213978^1..97cf213978:Sources/GhosttyTerminalView.swift`, hunks 5249,7249,7297; `LEDGER.md:417`. This is a policy rejection of the proposed repair.

B010 and B066 are not counted again here. Their obsolete subclaims were overturned in section 2, and their surviving mechanisms have one must-do row each.

# 9. What the sweep missed

These findings are outside the 368-row totals. They are static source findings with inferred runtime consequences. They need executable regression evidence during implementation.

1. **M001: UTF-8 socket framing drops entire read chunks. Must do, S, Wave 1.** `serveCommandLines` decodes each read independently with `String(bytes: ..., encoding: .utf8) ?? ""`, then appends that string. A stream read can split a multibyte character. For example, an otherwise valid JSON request carrying “é” can split between bytes C3 and A9. Both reads can fail decoding and become empty strings; valid bytes elsewhere in those chunks disappear too. This follows directly from `Sources/TerminalController.swift:2004-2017`. Accumulate bytes until a full newline-framed request is available, then decode once and return an explicit invalid-encoding error. Future proof: split each multibyte sequence at every byte boundary and compare exact delivered request bytes. No network experiment was run.

2. **M002: inbound connections and unfinished frames have no application bound in the serving path. Must do, M, Wave 1.** The listener creates one detached thread per accepted client (`Sources/TerminalController.swift:1847-1858`). Each blocks in read and appends to an unbounded pending string until newline (`:2004-2025`). An accidental client that streams without newline can grow memory; many idle authorized clients can retain threads. This is separate from B189's blocked response writer. Put a frame-size limit, admission budget and cancellable idle-read policy on this protocol while preserving legitimate long-lived polling clients. Inferred impact: a buggy fleet helper can exhaust resources without issuing a complete command. No malicious-client or load test was run.

3. **M003: handle registries retain historical handle entries for the process lifetime. Must do, M, with B058 in Wave 2.** Both UUID-to-ref and ref-to-UUID maps only gain entries in the inspected source. Definitions are at `Sources/TerminalController.swift:289-300`; allocation at `:2504-2517`; resolution at `:2520-2534`. The full source-reference search found no retirement/removal write. Growth therefore follows total created handles, not just live tabs, under repeated churn. Its practical RSS magnitude is unmeasured. Separate durable never-reused ordinal allocation from bounded live routing state; deleting a dead routing entry must never recycle its number. This complements B058 rather than changing its stable-ref requirement.

4. **Coverage remains incomplete.** The ledger itself leaves 49 browser inventory rows unverified (`LEDGER.md:38,42`). Do not advertise this audit or the original sweep as complete browser certification. The sample also found already-fixed destructive targeting and an incorrect lock dependency, so unsampled “shared-confirmed” must-do work should begin with a current-head source check, not a blind cherry-pick.

5. **The cancellation plan needs a whole shutdown dependency graph.** The August note records app, termio and renderer queues, with the renderer joined first (`notes/2026-08-25-freeze-surface-deinit-deadlock.md:71-91`). Inference: cancellation installed only at a later IO exit callback may be too late for a preceding join. Establish the quit signal before the first potentially blocking teardown dependency, preserve owned-message cleanup, and prove every producer can leave a full queue. B065's bounded drain improves fairness; it does not by itself break a join cycle. Neither GPU reclaim nor off-main native free should be added as an unproven escape hatch.
