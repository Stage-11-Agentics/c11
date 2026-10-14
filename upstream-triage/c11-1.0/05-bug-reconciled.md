# Bug harvest: reconciled tiers

2026-10-01. Fable (`audit-fable.md`) and Astra (`audit-astra.md`) audited the 368-bug ledger independently. This file reconciles them for Atin's review and for bug ticketing.

## Counts

| | Fable | Astra |
|---|---|---|
| Must do | 30 | 112 |
| Nice to have | 117 | 122 |
| Not a priority | 223 | 134 |
| Rejected | 4 | 3 |

**Both must-do:** 27. Fable-only must-do: 3. Astra-only must-do: 85, of which Fable rated 51 nice to have, 31 not a priority, and 3 already fixed on newer `main`.

Fable's diagnosis: the verifiers read code accurately, but they inflate severity. Astra's diagnosis: four of its 19 spot-checks were overturned in whole or part. That includes the mechanism behind round one's top item, B010: the output thread unlocks before it blocks.

## Tier 1: must do in 1.0 (30). Both auditors agree, plus Fable's three additions

Ticketed as P0 or P1. Exceptions, marked below: B058 conflicts with ruling D15; B059 is gated by D21; B044 is delivered by the journal.

| Ledger | Bug | Subsystem | Severity | Port |
|---|---|---|---|---|
| B002 | `send-key ctrl+letter` is keycode plus Ctrl, with codepoint 0 and no key release, so Kitty-protocol TUIs drop  | input / socket | high | S |
| B003 | A cold (never-shown) terminal's host view is reparented out of its hidden bootstrap window by portal churn and | render / socket; terminal /  | high | M |
| B005 | A new copy of the app force-kills the running fleet before it can save | app lifecycle | high | S |
| B007 | A v2 socket command arriving during startup session restore walks the half-built window/tab tree on main and c | socket/session; socket / ses | high | S |
| B010 | Autosave and terminal teardown can deadlock main through the full app mailbox | session / ghostty; Ghostty l | high | M |
| B012 | Background workspace loads raise the mount cap without a fixed ceiling | layout | high | S |
| B013 | Bracketed paste fence, payload and closing fence are queued as three IO mailbox messages, so a terminal reply  | ghostty / input | high | S |
| B019 | Closing a workspace through the wrong manager tears down live terminals | workspace lifecycle | high | S |
| B022 | Descendants and foreground jobs survive surface shutdown | termio | high | M |
| B023 | Disowned shell watchers survive the shell. They only test `kill -0` on the parent pid, so a reused pid keeps t | shell | high | S |
| B024 | Duplicate panel IDs in a saved session crash restoration | session restore | high | S |
| B028 | Each Claude Stop reads and parses the entire growing transcript | hook memory / CPU | high | S |
| B030 | Every Ghostty wakeup enqueues its own `tick()` on main, and every scrollbar action posts immediately, so bulk  | terminal / main thread | high | S |
| B031 | Focus and visibility changes can block main on a full renderer mailbox | ghostty / render; renderer | high | M |
| B044 | Notification records and unread notifications disappear on restart | session | high | M |
| B047 | Out-of-order write-buffer returns can drop bytes from large terminal sends | ghostty termio | high | M |
| B056 | Scrolling re-arms a full-window layout flush on every AppKit window update, so one scroll tick lays out every  | layout | high | S |
| B058 | Short socket references silently target different objects after restart | socket / session identity | high | S |
| B059 | Sidebar bodies repeatedly rebuild all workspace and panel projections | sidebar | high | L |
| B061 | Spinner-only terminal titles are still published as real title changes | titles | high | S |
| B062 | Surface close can wait forever for an uncooperative child | termio | high | M |
| B065 | Unbounded app-mailbox draining starves UI input under continuous terminal output | ghostty / main thread; ghost | high | S |
| B072 | Queued PTY writes can drop a chunk on WouldBlock | libxev writes | high | M |
| B074 | Replacing a web view inside its termination callback can crash the host | WebKit lifecycle; browser | high | M |
| B086 | `surface.read_text` / `read_screen` format multi-MB scrollback on the main actor | socket / main thread; socket | med | M |
| B087 | "`surface.read_text` / `read_screen` on a never-shown background terminal fails (""Failed to read terminal tex | socket | med | S |
| B094 | Automatic git dirty-state reports can contend with agents for the repository index | git / shell | med | S |
| B200 | The pinned Sparkle 2.8.1 helper is susceptible to macOS 26 installation rejection | updater | med | S |
| B204 | Use-after-free in Ghostty `Surface.setSelection`: compares the new selection against the previous one after `S | ghostty / crash; ghostty | med | S |
| B246 | Restored terminals start before the control socket listens, so restore-time CLI calls fail | socket/session; socket / ses | med | M |

## Tier 2: Astra must-do, Fable nice to have (51)

**Rule:** these ride along. A tier-2 bug is fixed in 1.0 when it lives in the same files or the same submodule bump as a tier-1 ticket; the owner picks it up there. Otherwise it is P2, taken only if the run is ahead.

| Ledger | Bug | Subsystem | Severity | Port |
|---|---|---|---|---|
| B001 | `ContentView` stores a `DispatchWorkItem` in `@State` that captures the view value, so tearing the view down r | sidebar; SwiftUI / schedulin | high | M |
| B004 | A LaunchServices self-open can suppress session restore | session restore | high | S |
| B006 | A socket command that waits for a callback from the main thread pumps the main run loop until the timeout. Whi | socket | high | M |
| B014 | Browser portal refresh forces synchronous layout and whole-window display | portal / SwiftUI; browser | high | M |
| B015 | Cell movement across a row boundary computes an invalid column | terminal pins | high | S |
| B018 | Closed main windows retain their SwiftUI content through a strong window reference | window lifetime | high | M |
| B020 | Compacted pages can loop forever when a capacity starts at zero | terminal allocation | high | S |
| B021 | Dead PTYs can spin and exited children can escape reaping | termio | high | S |
| B025 | Duplicate-instance enforcement can terminate unrelated helper processes | app lifecycle | high | S |
| B029 | Each sidebar row measures itself with a GeometryReader and writes that height into `@State`, which is fed back | sidebar | high | S |
| B032 | Focus broadcast re-enters the focus path synchronously (`.ghosttyDidFocusSurface` posted mid-`@Published` muta | focus | high | S |
| B033 | Ghostty callbacks can mutate terminal UI state off the main thread | render | high | S |
| B034 | Grapheme widening at the right edge can panic | Unicode terminal cells | high | S |
| B036 | Hyperlink reflow checks the wrong allocation shape | terminal reflow | high | S |
| B037 | IME preedit catch-up reads past shaped glyphs | renderer | high | S |
| B042 | New-workspace configuration copies C pointers without owning their strings | layout | high | S |
| B043 | Notification churn invalidates the entire workspace sidebar | sidebar performance | high | M |
| B045 | Null CoreText names can crash font discovery and copied names leak | font discovery | high | S |
| B046 | One snapshot file, no history: a relaunch that comes up poorer (failed or partial restore, a skipped picker, a | session | high | M |
| B049 | Portal `bind` runs `layoutSubtreeIfNeeded` inside a SwiftUI layout turn and can abort in the display-link flus | portal | high | M |
| B050 | Quit waits synchronously for telemetry that can wait for main | telemetry / quit | high | S |
| B060 | Sidebar layout can recurse. `LazyVStack` plus drag invalidation re-enters layout, and the sidebar body is alre | layout | high | S |
| B064 | Two Claude wrapper paths can exec each other indefinitely | Claude wrapper | high | S |
| B066 | Unresolvable explicit socket targets fall back to the focused pane | socket | high | S |
| B067 | A layout follow-up calls `displayIfNeeded` on every window before the current display pass finishes | layout | high | S |
| B068 | Closed terminal runtimes can be recreated and missing-surface input recovery is incomplete | terminal / lifecycle | high | M |
| B069 | Closed windows can retain terminal owners and allow late PTY creation | window lifecycle | high | M |
| B075 | Session restore leaves the replaced workspace graph without explicit teardown | restore / lifecycle | high | M |
| B078 | `browser cookies clear --url X` (or `--path`) ignores the filter and clears every cookie in the shared profile | agent browser automation; br | med | S |
| B080 | `browser state load` starts navigation and immediately writes localStorage/sessionStorage into the still-commi | agent browser automation; br | med | M |
| B083 | `NSColor.darken` calls `getHue` without converting to sRGB, which raises on catalog and grayscale colors | theme | med | S |
| B089 | A replacement terminal host is rejected until its area is 20% larger or the old host disappears | portal | med | M |
| B093 | AppKit and Ghostty focus can disagree, leaving typed input held | focus / input; focus | med | M |
| B113 | Closing a browser pane, window or quitting the app while the Web Inspector is open crashes in WebKit (`WKWebIn | Web Inspector; browser | med | S |
| B114 | Closing an unfocused pane moves focus to the closed pane's sibling | focus / bonsplit; focus | med | S |
| B120 | Context-menu download resolution traps (`Duplicate values for key`) on a Google-host URL that repeats a query  | context menu download; brows | med | S |
| B137 | Ghostty's PWD action writes the directory through the key window's `TabManager`, so a background window's cwd  | layout | med | S |
| B148 | Keys that arrive before the Ghostty runtime exists are passed to `super`, so AppKit beeps or inserts them into | input | med | S |
| B160 | Pane ownership lookup reads every tab model and subscribes portal views to title changes | portal / observation | med | S |
| B162 | Popup navigation delegate returns without ever calling the WebKit `decisionHandler` when its controller is gon | WebKit delegates; browser | med | S |
| B166 | Rebuilding a renderer row reads `shaped_cells[shaper_cells_i]` before checking the index, and traps when the t | ghostty | med | S |
| B175 | Restored or new background terminals start with incorrect Ghostty focus | terminal / focus | med | M |
| B180 | Session autosave writes window geometry to UserDefaults even when the bytes did not change, so every save post | session / UserDefaults | med | S |
| B188 | Sidebar settings are `@AppStorage` on every row, and each row scans the full workspace list to build context-m | sidebar | med | M |
| B189 | Socket responses use one unchecked, unbounded write, so clients can pin threads or receive truncated replies | socket | med | S |
| B193 | Switching away from c11 synchronously snapshots all sessions | session / main thread | med | S |
| B247 | Resume does not check whether a surviving process already owns the session writer | agent resume | med | M |
| B248 | Resume launches from a drifted terminal directory instead of the session directory | conversation cwd | med | M |
| B257 | Terminal readiness is published before queued input is flushed and focus is retried | restore / input | med | M |
| B266 | `c11 send-key` keeps only the first key and silently drops the rest. | socket | low | S |
| B355 | "Restoring a session that holds only 0-workspace ""phantom"" windows builds empty NSWindows at launch and was  | session | low | S |

## Tier 3: parked (34)

These are Astra must-dos that Fable rated not a priority (31), plus 3 that Fable found already fixed on `origin/main` after the 36 commits the ledger missed. They are parked, not ticketed. When a tier-1 owner is already in the same code, it re-checks the parked rows there.

IDs: B008, B017, B026, B038, B039, B040, B041, B048, B052, B053, B054, B055, B057, B063, B098, B112, B115, B118, B119, B121, B139, B143, B153, B171, B184, B197, B203, B295, B305, B309, B324, B051, B073, B081

## Rejected by both

B009: c11 already rejects empty close targets.
