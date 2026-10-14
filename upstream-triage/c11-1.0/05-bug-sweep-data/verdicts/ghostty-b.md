# Ghostty-b verification

Static research on 2026-10-01. c11 main: `d63b937f6580f362a19dcfe1b2a11fa45a09e765`. Ghostty checkout: `26c3e499ed8c4d65e3748248de7fd04c1e9a8103`. Ghostty comparison base: `b9989c101`. No builds, tests, fetches, or runtime experiments. The cited source files had no working-tree diffs at final inspection.

The PRs column contains Ghostty commit identifiers because this batch is commit-based. All 208 identifiers were checked against the three round-1 verdict files. Only `ab82b8ab7` matched, in `verdicts-lead.md:32`. It is recorded only in the ledger.

History checks covered `b9989c101..26c3e499e`, affected-path logs since 2026-03-18, selected symbol searches, and parent C11-20/21/22 history. Commit identity alone is insufficient: the older engine contains equivalent fixes through its synchronized baseline, including `d631f36ce`. Current source determines the verdict. c11-specific Ghostty changes include `caf199071`, `d4431f804`, and `26c3e499e`.

Known-problem cross-reference: [August teardown deadlock and recorded congestion](../../../../notes/2026-08-25-freeze-surface-deinit-deadlock.md). No commit verified here repairs that three-thread mailbox cycle. No evidence here explains the unrecorded July deadlock. Relationships to the other known problems are stated where relevant; otherwise no causal link is established.

## Verified

| bug (plain English) | PRs | subsystem | c11 status | severity | port | rec | evidence (upstream file + c11 path:line) | notes (incl. link to c11 known problem) |
|---|---|---|---|---|---|---|---|---|
| Link regex work has no explicit retry budget | 3dde6e255 | link matching | shared-confirmed | high | S | port | Upstream src/terminal/StringMap.zig; pkg/oniguruma/regex.zig; c11 ghostty/src/terminal/StringMap.zig:47; ghostty/pkg/oniguruma/regex.zig:67; ghostty/src/Surface.zig:4513 | Root cause: link matching calls unbudgeted Oniguruma search while holding the renderer mutex. Pathological output can stall input and rendering. An additional congestion mechanism is inferred, not an explanation proven for the recorded SwiftUI, metadata, or hover-recursion stalls. |
| IME preedit catch-up reads past shaped glyphs | fe972c095 | renderer | shared-confirmed | high | S | port | Upstream src/renderer/generic.zig; c11 ghostty/src/renderer/generic.zig:2798 | Root cause: the catch-up loop indexes the glyph slice without checking its length. c11 retains the original inline loop. The helper extraction in 70b95dada is noise; port the bounds check into this loop. |
| Malformed Kitty graphics commands leak parser allocations | 83027407e | APC parser | shared-confirmed | high | S | port | Upstream src/terminal/apc.zig; c11 ghostty/src/terminal/apc.zig:47; ghostty/src/terminal/kitty/graphics_command.zig:78 | Root cause: feed failure replaces the owned parser with ignore state without deinit. Repeated malformed graphics output leaks across long sessions. Separate from the already-fixed socket pool and free-text ABI leaks. |
| Grapheme widening at the right edge can panic | 3ba49a784 | Unicode terminal cells | shared-confirmed | high | S | port | Upstream src/terminal/Terminal.zig; c11 ghostty/src/terminal/Terminal.zig:433; ghostty/src/terminal/Terminal.zig:467 | Root cause: grapheme widening installs a spacer head before marking row.wrap, exposing invalid intermediate state to hyperlink/page integrity checks. A terminal crash threatens all agent surfaces. The ordinary wide-character branch is already fixed separately. |
| Resize cursor arithmetic can underflow | 7fa6fffbc | terminal reflow | n/a-diverged | high | n/a | skip | Upstream src/terminal/PageList.zig; c11 ghostty/src/terminal/PageList.zig:1028; ghostty/src/terminal/PageList.zig:3864; ghostty/src/terminal/PageList.zig:4912; ghostty/src/terminal/PageList.zig:5341 | Root cause upstream: simultaneous row/column shrink leaves cursor.y beyond the new bottom after the newer cursor.pin path bypasses coordinate lookup. c11 has no cursor.pin input and rejects that old coordinate through pin(...).down(...), so the documented underflow trigger is blocked. Include saturation if porting c44afa625, which introduces that pin path. |
| Reflow leaves a history viewport pin in the active area | 815ccb060 | terminal reflow | shared-confirmed | high | S | port | Upstream src/terminal/PageList.zig; src/terminal/Screen.zig; c11 ghostty/src/terminal/PageList.zig:1137; ghostty/src/terminal/PageList.zig:1169 | Root cause: cursor-preserving grow runs before converting a history viewport pin that reflow moved into the active area. Upstream adds normalization before this block. c11 only normalizes later in resize. Integrity failures can interrupt resize. The demonstrated upstream failure is an integrity assertion in safety builds; production crash behavior was not tested. |
| Reflow loses cursor position after blank cells | c44afa625 | terminal reflow | shared-confirmed | high | M | port | Upstream src/terminal/PageList.zig; src/terminal/Screen.zig; c11 ghostty/src/terminal/PageList.zig:1015; ghostty/src/terminal/PageList.zig:1110; ghostty/src/terminal/Screen.zig:1757 | Root cause: reflow changes column geometry before resolving the old cursor and trims blank cells before the cursor because its tracked pin is not passed through. Split resizing can relocate subsequent terminal writes. Port alongside viewport and saturating-arithmetic fixes. |
| Korean IME arrow commits reuse the arrow keycode | fa141a726 | macOS input | shared-probable | high | S | reimplement | Upstream macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift; c11 Sources/GhosttyTerminalView.swift:5876; Sources/GhosttyTerminalView.swift:5905; Sources/GhosttyTerminalView.swift:6275 | Root cause: committed text is sent using the physical arrow event instead of a neutral text event followed by movement. c11 has the same encoding shape and only special-cases Return. Korean arrow behavior is inferred from static code. C11-21 and b4d152c189 addressed other input cases, not this arrow path. |
| Insert blanks can orphan wide characters at the right margin | 177612a4c 90e96a389 | terminal cells | already-fixed | high | n/a | skip | Upstream src/terminal/Terminal.zig; c11 ghostty/src/terminal/Terminal.zig:2223 | Root cause: shifting or clearing one half of a wide character leaves an orphan tail. c11 clears both halves before either branch, including the follow-up fix. |
| Full line clears can orphan wide cells | b39a00ddf | terminal cells | already-fixed | high | n/a | skip | Upstream src/terminal/Terminal.zig; c11 ghostty/src/terminal/Terminal.zig:1968; ghostty/src/terminal/Terminal.zig:2156 | Root cause: full-clear branches skipped rowWillBeShifted. Both calls already exist. |
| No-reflow grow can leave spacer heads inside a row | 1ba9f9187 | terminal resize | already-fixed | high | n/a | skip | Upstream src/terminal/PageList.zig; c11 ghostty/src/terminal/PageList.zig:2157 | Root cause: the capacity fast path enlarged rows without repairing old end-of-row spacer heads. c11 detects them and falls through to cloneRowFrom. |
| Overwriting wide characters can corrupt the preceding row | e7030e73d | terminal cells | already-fixed | high | n/a | skip | Upstream src/terminal/Terminal.zig; c11 ghostty/src/terminal/Terminal.zig:733; ghostty/src/terminal/Terminal.zig:758 | Root cause: unconditional narrowing changed a previous-row cell that was not a spacer head. Both assignments are guarded in c11. |
| Wide linked characters can violate wrap integrity | 97c11af34 | terminal cells | already-fixed | high | n/a | skip | Upstream src/terminal/Terminal.zig; c11 ghostty/src/terminal/Terminal.zig:637 | Root cause: spacer-head insertion preceded the wrap flag. c11 sets wrap before printCell in the ordinary wide-character path. |
| Overflowing tab-clear parameters can panic | a595c00f3 | terminal parser | already-fixed | high | n/a | skip | Upstream src/terminal/stream.zig; c11 ghostty/src/terminal/stream.zig:1341 | Root cause: unchecked enum conversion accepted out-of-range input. c11 uses intToEnum with an error return. |
| Zero insert-blanks count can crash | 9157eb439 | terminal parser | already-fixed | high | n/a | skip | Upstream src/terminal/Terminal.zig; src/terminal/stream.zig; c11 ghostty/src/terminal/Terminal.zig:2193; ghostty/src/terminal/stream.zig:1900 | Root cause: zero reaches an algorithm requiring positive count. c11 has both the direct-call early return and CSI minimum clamp. |
| CSI W without parameters can read out of bounds | dcaa8f397 | terminal parser | already-fixed | high | n/a | skip | Upstream src/terminal/stream.zig; c11 ghostty/src/terminal/stream.zig:1192 | Root cause: params[0] was read without checking length. c11 requires exactly one parameter. |
| DCS passthrough can overflow its parameter array | 12f43dfb7 | terminal parser | already-fixed | high | n/a | skip | Upstream src/terminal/Parser.zig; c11 ghostty/src/terminal/Parser.zig:293 | Root cause: passthrough entry finalized one more parameter after MAX_PARAMS. c11 has the bounds guard. |
| Text release used the wrong C ABI signature | 4803d58bb | embedded ABI | already-fixed | high | n/a | skip | Upstream src/apprt/embedded.zig; c11 ghostty/src/apprt/embedded.zig:1725; ghostty/include/ghostty.h:1136 | Root cause: the export interpreted the surface argument as the text pointer. Fixed independently by d4431f804 and parent 703987bb42, C11-212. Direct match to known problem 4. |
| Display-link callbacks can stop after display changes | 05cf31b38 | renderer display link | already-fixed | high | n/a | skip | Upstream src/renderer/generic.zig; c11 ghostty/src/renderer/generic.zig:1012; Sources/GhosttyTerminalView.swift:3911 | Root cause: a running display link started before a valid display could stop producing callbacks. c11 restarts it after reassignment and reasserts the display on focus. Separate from the #403 main-thread mailbox deadlock fix. |
| Cmd-click links fail inside mouse-reporting TUIs | 1c7613c95 55d154a97 | terminal links | shared-confirmed | med | S | port | Upstream src/Surface.zig; c11 ghostty/src/Surface.zig:2764; ghostty/src/Surface.zig:4800 | Root cause: link refresh permits only no mouse mode or Shift escape, and uses raw mode rather than effective reporting state. Claude Code and Codex can capture mouse input. Include 354e3626b when porting so the new local click path does not leak an unmatched press. |
| Spaced file links absorb neighboring prose or punctuation | 6eed7af92 | terminal link regex | shared-confirmed | med | M | reimplement | Upstream src/config/url.zig; c11 ghostty/src/config/url.zig:67; ghostty/src/config/url.zig:93 | Root cause: broad dotted-path space segments consume text beyond a file path. c11 retains that expression. Adapt the bounded grammar with ff6e1260d follow-up coverage. Regex retry limits remain a separate requirement. |
| Modifier-only mouse updates are discarded | 5d1ba056b | embedded mouse input | shared-confirmed | med | S | port | Upstream src/apprt/embedded.zig; c11 ghostty/src/apprt/embedded.zig:909 | Root cause: deduplication checks coordinates but not modifiers, so a stationary pointer can retain stale link or capture state. This is a follow-up to the already-present phantom-mouse fix. |
| IME preedit shifts left one cell too early | ac67a6160 | renderer preedit | shared-confirmed | med | S | port | Upstream src/renderer/State.zig; c11 ghostty/src/renderer/State.zig:115 | Root cause: inclusive end position uses start + width rather than start + width - 1. Affects visible composition at the right edge. Distinct from the renderer bounds crash. |
| Link matching crosses semantic shell prompt boundaries | 85dc4b184 | terminal links | shared-confirmed | med | S | port | Upstream src/Surface.zig; c11 ghostty/src/Surface.zig:4525 | Root cause: selectLine explicitly disables semantic prompt boundaries, joining prompt text with neighboring paths. |
| Variation selectors inspect the wrong codepoint | 3f11e695d | Unicode terminal cells | shared-confirmed | med | S | port | Upstream src/terminal/Terminal.zig; c11 ghostty/src/terminal/Terminal.zig:370; ghostty/src/terminal/Terminal.zig:393 | Root cause: variation validation uses the grapheme base rather than the immediately preceding codepoint. Emoji sequences can get incorrect width or dropped selectors. |
| Combining marks attach to the wrong cell at pending wrap | c20fcfa1b | Unicode terminal cells | shared-confirmed | med | S | port | Upstream src/terminal/Terminal.zig; c11 ghostty/src/terminal/Terminal.zig:562; ghostty/src/terminal/Terminal.zig:569 | Root cause: zero-width attachment always looks one cell left, although pending wrap leaves the last printed cell under the cursor. |
| Terminal color-scheme reports use stale app state | 2be58ee0e 96bad9020 | surface configuration | shared-confirmed | med | S | port | Upstream src/Surface.zig; c11 ghostty/src/Surface.zig:1797 | Root cause: termio derived config inherits the app conditional theme instead of the surface theme when no conditional config reload occurs. Extract the one-line state assignment from 96bad9020, which also contains unrelated picker work. |
| Bash vi-mode redraw inserts extra newlines | e31615d00 | shell integration | shared-confirmed | med | S | port | Upstream src/shell-integration/bash/ghostty.bash; c11 ghostty/src/shell-integration/bash/ghostty.bash:201 | Root cause: the prompt embeds fresh-line OSC 133 A on every readline redraw. Upstream emits A once and uses non-fresh-line P inside the prompt. |
| Bash multiline prompt rewriting can corrupt substitutions | 26d8bd9e7 | shell integration | shared-confirmed | med | S | port | Upstream src/shell-integration/bash/ghostty.bash; c11 ghostty/src/shell-integration/bash/ghostty.bash:210 | Root cause: replacing literal newlines also injects escape markers inside command substitutions. Only the escaped prompt newline should be rewritten. |
| Existing zsh aliases can break integration function definitions | e07aefa60 | shell integration | shared-confirmed | med | S | port | Upstream src/shell-integration/zsh/ghostty-integration; c11 ghostty/src/shell-integration/zsh/ghostty-integration:284; ghostty/src/shell-integration/zsh/ghostty-integration:307 | Root cause: name() declarations allow alias expansion for sudo and ssh. The function keyword avoids that parsing failure. c11 bundles this integration; this is not cmux remote-workspace code. |
| Forward prompt navigation lands on continuation rows | 53637ec7b | scrollback navigation | shared-confirmed | med | S | port | Upstream src/terminal/PageList.zig; c11 ghostty/src/terminal/PageList.zig:2685 | Root cause: forward navigation advances one row without skipping continuation rows of the current multiline prompt. |
| Resize can briefly present blank or stretched frames | a3588ac53 | Metal renderer | already-fixed | med | n/a | skip | Upstream src/Surface.zig; src/apprt/embedded.zig; src/renderer/Metal.zig; src/renderer/generic.zig; c11 ghostty/src/renderer/generic.zig:1499; ghostty/src/renderer/Metal.zig:307 | Root cause: synchronous display can present before resized terminal buffers arrive. c11 retains and re-presents the last target and guards transient sizes. Equivalent changes landed as efb0b03d1/5a987a148, not this SHA. Separate from C11-225. |
| Theme reload retains stale OSC background color | 57d202066 | macOS terminal background | already-fixed | med | n/a | skip | Upstream macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift; c11 Sources/GhosttyTerminalView.swift:2304 | Root cause: the OSC background cache survived config changes. c11 clears the override on GHOSTTY_ACTION_CONFIG_CHANGE. |
| Dragging surfaces leaves stale window occlusion | 2c6dd5940 | macOS surface lifecycle | n/a-diverged | med | n/a | skip | Upstream macos/Sources/Features/Terminal/BaseTerminalController.swift; macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift; c11 Sources/GhosttyTerminalView.swift:4663; Sources/Panels/TerminalPanel.swift:112 | Root cause upstream: tree replacement does not resync per-view window occlusion. c11 intentionally ignores AppKit occlusion and drives it from panel lifecycle instead. This specific BaseTerminalController mechanism does not exist. It does not solve the teardown deadlock. |
| Bare relative path links consume unified diff suffixes | f66064b0b | terminal link regex | already-fixed | med | n/a | skip | Upstream src/config/url.zig; c11 ghostty/src/config/url.zig:109 | Root cause: bare relative paths accepted spaced dotted suffixes. c11's bare path branch already omits dotted_path_space_segments. |
| Growing grapheme widths fail to widen terminal cells | 6afdf3400 | Unicode terminal cells | already-fixed | med | n/a | skip | Upstream src/terminal/Terminal.zig; src/unicode/props.zig; c11 ghostty/src/terminal/Terminal.zig:403; ghostty/src/terminal/Terminal.zig:414 | Root cause: appended codepoints can change grapheme width after the initial cell allocation. c11 already has width_zero_in_grapheme, desired_wide, and grapheme-transfer handling. The newer edge-wrap bug above still remains. |
| Leading-newline zsh prompts gain extra blank lines | 9a3dbe10b | shell integration | already-fixed | med | n/a | skip | Upstream src/shell-integration/zsh/ghostty-integration; c11 ghostty/src/shell-integration/zsh/ghostty-integration:161 | Root cause: prompt marking treated the leading newline as a continuation requiring fresh-line handling. c11 already skips that first newline. |
| Find Next and Previous search for literal direction words | 18f270222 | terminal search menu | shared-confirmed | med | S | reimplement | Upstream macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift; c11 Sources/TabManager.swift:1344; Sources/TabManager.swift:1353; Sources/Find/SurfaceSearchOverlay.swift:54 | Root cause: menu actions send search:next and search:previous, which set the search needle, instead of navigate_search actions. c11's overlay already uses the correct actions, but its menu path retains the bug. |
| Search-field Return intercepts IME composition | 7a346dd8d | terminal search input | already-fixed | med | n/a | skip | Upstream macos/Sources/Ghostty/Surface View/SurfaceView.swift; c11 Sources/Find/SurfaceSearchOverlay.swift:289 | Root cause upstream: a Return key handler consumes IME confirmation before text submission. c11's native text-field delegate explicitly returns false while marked text exists. |
| Ending search from the menu may leave terminal focus behind | 97c5a21ab | terminal search focus | shared-probable | med | S | reimplement | Upstream macos/Sources/Ghostty/Ghostty.App.swift; macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift; c11 Sources/TabManager.swift:1368; Sources/GhosttyTerminalView.swift:2199; Sources/GhosttyTerminalView.swift:8010; Sources/GhosttyTerminalView.swift:7873 | Root cause: menu/end-search paths clear search state without the explicit moveFocus used by the close button. Overlay removal likewise has no focus transfer. Inferred because AppKit/portal focus recovery may sometimes mask it. |
| Theme preview fails when its directory exists | aa650937d b90dee5f9 ea482b73e | theme helper | already-fixed | low | n/a | skip | Upstream src/cli/list_themes.zig; c11 ghostty/src/cli/list_themes.zig:332 | Root cause: makeDirAbsolute fails on an existing parent directory. c11 has makePath via efff67770 and later atomic-write hardening bc9be90a2. |
| Phantom mouse events unhide the pointer while typing | 2a4140146 | embedded mouse input | already-fixed | low | n/a | skip | Upstream src/apprt/embedded.zig; c11 ghostty/src/apprt/embedded.zig:909 | Root cause: stationary events were processed as real motion. c11 has the position filter. Its modifier-state omission is a separate shared bug above. |
| Palette C layout has too many color entries | 20351a71d | configuration ABI | already-fixed | low | n/a | skip | Upstream src/config/Config.zig; c11 ghostty/src/config/Config.zig:5646 | Root cause: the Zig C-compatible palette used 265 rather than 256 entries. c11 already declares 256. |
| Cursor reset ignores the configured default style | 6c6865092 | terminfo | shared-confirmed | low | S | watch | Upstream src/terminfo/ghostty.zig; c11 ghostty/src/terminfo/ghostty.zig:116 | Root cause: Se emits style 2 instead of 0. TUIs restore a fixed block cursor rather than the configured default. |
| Middle-click can paste stale selection instead of the system clipboard | 50e8ebaf6 | clipboard | shared-confirmed | low | S | watch | Upstream src/Surface.zig; c11 ghostty/src/Surface.zig:4239; Sources/GhosttyTerminalView.swift:1068; Sources/GhosttyTerminalView.swift:89 | Root cause: middle-click always prefers selection clipboard even with copy-on-select=clipboard. c11 explicitly enables its private selection pasteboard, so the macOS fallback does not avoid this. |
| Trailing percent signs combine with zsh prompt marks | 43f3dc5f1 | shell integration | shared-confirmed | low | S | watch | Upstream src/shell-integration/zsh/ghostty-integration; c11 ghostty/src/shell-integration/zsh/ghostty-integration:150; ghostty/src/shell-integration/zsh/ghostty-integration:172 | Root cause: a bare trailing percent combines with the next percent-brace marker. c11 does not escape it before appending markB. |
| SSH environment helper overrides user SetEnv values | 69554f414 | shell integration | shared-confirmed | low | S | watch | Upstream src/shell-integration/{bash,zsh,fish,elvish,nushell}; c11 ghostty/src/shell-integration/zsh/ghostty-integration:317; ghostty/src/shell-integration/bash/ghostty.bash:126; ghostty/src/config/Config.zig:8464 | Root cause: command-line SetEnv replaces user SSH configuration. c11 has this optional Ghostty shell feature, disabled by default. This is ordinary shell ssh, not the absent cmux remote-workspace implementation. |
| SSH terminfo transfer interprets backslash escapes | 875985dbd | shell integration | already-fixed | low | n/a | skip | Upstream src/shell-integration/zsh/ghostty-integration; c11 ghostty/src/shell-integration/zsh/ghostty-integration:350 | Root cause: plain print interprets terminfo backslashes before transfer. c11 already uses builtin print -r. |
| Configured working directory does not expand tilde | 04d5efc8e | configuration | shared-confirmed | low | M | watch | Upstream src/config/Config.zig; src/apprt/embedded.zig; c11 ghostty/src/config/Config.zig:1535; ghostty/src/config/Config.zig:4507 | Root cause: working-directory recognizes home/inherit but otherwise passes raw strings, so ~/ is not expanded. c11's host-provided explicit absolute cwd can avoid this in ordinary launches. |
| Empty clipboard paste cannot decline a performable binding | aaad43c23 | embedded clipboard ABI | shared-confirmed | low | M | watch | Upstream include/ghostty.h; src/apprt/embedded.zig; src/config/Config.zig; c11 ghostty/include/ghostty.h:975; ghostty/src/apprt/embedded.zig:709 | Root cause: the void read callback cannot report failure, so clipboardRequest always reports success. Port needs a coordinated header, Zig, and Swift callback change, not a Zig-only cherry-pick. |
| Locale initialization hard-codes Linux constants on macOS | f0badd34d | locale | shared-confirmed | low | S | port | Upstream src/os/locale.zig; src/build/SharedDeps.zig; c11 ghostty/src/os/locale.zig:213; ghostty/src/global.zig:164 | Root cause: LC_ALL is hard-coded as 6; the local macOS SDK locale.h:45 defines it as 0. Initialization therefore targets the wrong locale category. Use translated platform constants. No claim that it explains the recorded hangs. |
| Ghostty helper loses buffered action-list output | 235dde684 | helper CLI | shared-confirmed | low | S | watch | Upstream src/cli/list_actions.zig; c11 ghostty/src/cli/list_actions.zig:42 | Root cause: the stdout writer returns without flushing. This concerns the bundled Ghostty helper, not c11's socket CLI. |
| SSH helper cache loading mishandles allocation failure | a5550a2dc | Ghostty helper cache | shared-confirmed | low | S | watch | Upstream src/cli/ssh-cache/DiskCache.zig; c11 ghostty/src/cli/ssh-cache/DiskCache.zig:284; ghostty/src/cli/ssh-cache/DiskCache.zig:292; ghostty/src/cli/ssh-cache/DiskCache.zig:304 | Root cause: failed cache loading leaks the map and a duplicate-host path can free a hostname again through errdefer. This is present in the optional Ghostty CLI helper, not a long-lived c11 socket handler. Severity is low because it needs helper use and allocation failure. |
| Uppercase configured shortcuts do not match menu equivalents | 702a2b43c | macOS shortcut mapping | already-fixed | low | n/a | skip | Upstream macos/Sources/Ghostty/Ghostty.Input.swift; c11 Sources/AppDelegate.swift:10718 | Root cause upstream: Unicode shortcut mapping preserves uppercase characters. c11 already lowercases mapped characters. |

## Top findings

**Bound link-regex work first.** `3dde6e255` adds an explicit Oniguruma retry budget. c11 still calls ordinary search from link matching while holding the renderer mutex at `ghostty/src/Surface.zig:4513`. A pathological wrapped output line can consume CPU and delay the operator's input and renderer. Ten to forty agents increase the volume of candidate output. A contribution to main-thread congestion is inferred. This does not establish that regex matching caused the recorded AttributeGraph, metadata-lock, or hover-recursion stalls.

**IME has one confirmed renderer hazard and one probable input bug.** `fe972c095` bounds the glyph catch-up loop still present at `ghostty/src/renderer/generic.zig:2798`. A preedit region can consume all shaped glyphs before the loop reaches its target cell. Separately, `fa141a726` sends Korean committed text independently of the arrow event. c11 still combines both at `Sources/GhosttyTerminalView.swift:5905`. Its Return-specific fix does not address arrow commits. The latter needs a real Korean IME reproduction before claiming runtime proof.

**Port the reflow fixes as a coordinated set.** `c44afa625` preserves the write cursor through trailing blanks, while `815ccb060` normalizes a viewport pin before intermediate growth. c11 retains both old paths. Frequent split resizing makes these relevant across an agent fleet. The viewport failure is proven upstream through safety-build integrity checks, not by a production c11 run here. Include `7fa6fffbc` when porting the new cursor-pin path. Its documented underflow trigger is currently blocked by c11's older coordinate lookup, so it is not counted as a shared bug.

**Two small engine fixes protect long sessions.** `83027407e` deinitializes the Kitty parser before discarding it after a feed error; c11 loses its allocations at `ghostty/src/terminal/apc.zig:49`. `3ba49a784` marks wrap before grapheme widening creates a spacer head, avoiding an intermediate integrity violation. These mechanisms differ from C11-211's socket autorelease leak and C11-212's text-release ABI leak. The latter ABI correction is already present as `d4431f804`.

**Search and link actions have operator-visible gaps.** Cmd-click link refresh still excludes mouse-reporting TUIs. Port `1c7613c95` with `55d154a97` and the later full-click suppression `354e3626b`; the last fixes a regression in the new path and is not currently shared. The terminal menu also sends `search:next` and `search:previous` at `Sources/TabManager.swift:1344` and `:1353`, replacing the needle instead of navigating. Ending search from the menu lacks the close button's explicit focus transfer, a probable remaining issue. None of these is the [August surface-deinit deadlock](../../../../notes/2026-08-25-freeze-surface-deinit-deadlock.md); that remains independent work.

## Triage ledger

| pr | disposition | one-line reason |
|---|---|---|
| 354e3626b | na-feature | Fixes half-click leakage introduced by 1c7613c95, which c11 lacks. Include it when porting that fix. |
| 55d154a97 | verify | shared-confirmed: Cmd-click links fail inside mouse-reporting TUIs. |
| 1c7613c95 | verify | shared-confirmed: Cmd-click links fail inside mouse-reporting TUIs. |
| 7fa6fffbc | verify | n/a-diverged: the documented shrink trigger is rejected by c11's old pin lookup; required follow-up if c44afa625 is ported. |
| c4e1ab888 | na-feature | Adds a selection-change action and standalone accessibility notification, absent from c11's ABI and host. |
| ef68e9640 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| ab82b8ab7 | done-round1 | Already verified in verdicts-lead.md:32; do not duplicate its use-after-free finding. |
| a181c386c | noise | Documentation spacing only. |
| eb5c1c722 | noise | Standalone Swift logging privacy annotations, no terminal behavior fix. |
| e32d7abe6 | noise | Swiftlint formatting only. |
| ff963f311 | noise | GTK timeout names and comments, no new behavior fix. |
| 1753d57bf | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| 00eb48a99 | na-feature | Fixes upstream mobile write_active_file output; c11's writer has no active location. |
| 68959c5c6 | na-feature | Fixes the newer SelectionGesture engine; c11 does not have that class. |
| 57d202066 | verify | already-fixed: Theme reload retains stale OSC background color. |
| 37997f8db | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| 9910a1a47 | noise | NixOS audio-bell test only. |
| 0b6d91e53 | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| a5550a2dc | verify | shared-confirmed: SSH helper cache loading mishandles allocation failure. |
| 545a5aef6 | noise | VT selection lifetime documentation only. |
| da541bea6 | noise | Standalone Swift merge-conflict brace repair, no applicable runtime fix. |
| 7a346dd8d | verify | already-fixed: Search-field Return intercepts IME composition. |
| fffdaadcb | na-feature | New quick-terminal CLI parsing and newer clear-token config semantics; c11 still correctly round-trips empty-list syntax. |
| bf716a0c3 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| ff6e1260d | na-feature | Repairs dotted-path branches introduced by 6eed7af92; those new branches are absent. Include as port follow-up. |
| 6eed7af92 | verify | shared-confirmed: Spaced file links absorb neighboring prose or punctuation. |
| 6e10706a7 | noise | File-link regression test only. |
| 22b9df25e | noise | Availability documentation correction only. |
| 69cab3d80 | na-feature | Ghostty standalone macOS search/pasteboard UI is not used by c11's Swift host. |
| 59eece9a8 | na-feature | Ghostty standalone macOS search/pasteboard UI is not used by c11's Swift host. |
| 93d1142ad | noise | GTK formatting only. |
| 54a38e813 | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| aef980e27 | na-feature | New configurable crash-directory feature, not a shared bug fix. |
| e59e27f8b | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| 2c6dd5940 | verify | n/a-diverged: Dragging surfaces leaves stale window occlusion. |
| 366c34831 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| fe972c095 | verify | shared-confirmed: IME preedit catch-up reads past shaped glyphs. |
| 70b95dada | noise | Extracts the existing unsafe loop and adds tests; actual fix is fe972c095. |
| ec145bca9 | noise | Basque translation wording only. |
| c44afa625 | verify | shared-confirmed: Reflow loses cursor position after blank cells. |
| 3f11e695d | verify | shared-confirmed: Variation selectors inspect the wrong codepoint. |
| 5d1ba056b | verify | shared-confirmed: Modifier-only mouse updates are discarded. |
| 57a9adce7 | na-feature | Ghostty standalone split-tree resizing; c11 uses Bonsplit, not this tree. |
| 81e399c41 | noise | CI dependency-version bump only. |
| c20fcfa1b | verify | shared-confirmed: Combining marks attach to the wrong cell at pending wrap. |
| 61595b5ec | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| dae04211c | noise | Fork CI workflow repair only. |
| aa650937d | verify | already-fixed: Theme preview fails when its directory exists. |
| b90dee5f9 | verify | already-fixed: Theme preview fails when its directory exists. |
| 154169b05 | na-feature | Linux-only scroll behavior change; macOS behavior is preserved. |
| 97c5a21ab | verify | shared-probable: Ending search from the menu may leave terminal focus behind. |
| 6c6865092 | verify | shared-confirmed: Cursor reset ignores the configured default style. |
| ac67a6160 | verify | shared-confirmed: IME preedit shifts left one cell too early. |
| b66258806 | noise | UI test setup changes only. |
| c4a671ba5 | noise | Removes a test only. |
| fa141a726 | verify | shared-probable: Korean IME arrow commits reuse the arrow keycode. |
| 85dc4b184 | verify | shared-confirmed: Link matching crosses semantic shell prompt boundaries. |
| 6fb86a819 | na-feature | Linux distribution packaging or desktop integration only. |
| 00dfd67be | noise | CPU-detection implementation replacement, no stated runtime bug fix. |
| ae1dd5666 | noise | Fuzzer toolchain and linker setup only. |
| b0b23f53a | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| a8ed37a79 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| 08a2d9b22 | noise | Build archive assembly refactor and artifact naming. |
| ce3c319ab | noise | CI dependency-version bump only. |
| 50e8ebaf6 | verify | shared-confirmed: Middle-click can paste stale selection instead of the system clipboard. |
| 83027407e | verify | shared-confirmed: Malformed Kitty graphics commands leak parser allocations. |
| c7a73076e | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| adb0d793a | na-feature | Android shared-memory compatibility only. |
| 8a6c66468 | noise | Locale identifier spelling cleanup. |
| 9cbca5459 | noise | Translator documentation only. |
| 5939b8c1b | na-feature | Standalone SurfaceView click-monitor coordinate fix; c11 uses its own portal routing, not this monitor. |
| 815ccb060 | verify | shared-confirmed: Reflow leaves a history viewport pin in the active area. |
| 3ee0b0a77 | noise | Belarusian translation wording only. |
| ff9ca55b5 | noise | Belarusian translation terminology only. |
| 858e856e2 | na-feature | Ghostty standalone macOS search/pasteboard UI is not used by c11's Swift host. |
| 2648668da | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| de4992c2b | noise | Equivalent control-flow refactor. |
| 53019991f | noise | Tiny standalone secure-input popover alignment adjustment. |
| bf6fd4abe | noise | No-op surface method placeholders. |
| 650cd9664 | na-feature | Standalone TerminalController work-item retention cycle; c11 lacks pendingInitialPresentation. |
| 4fd16ef9b | noise | Internal library artifact names in build installation. |
| 41c872c1f | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| 1855b3efc | noise | CI dependency-version bump only. |
| 363cb9560 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| 97b8b8faa | noise | Zig helper CLI compilation compatibility. |
| 249aee701 | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| 65e3265e3 | na-feature | Includes production fixes in the separate libghostty-vt C API, which c11 does not embed. |
| 68a8cbb06 | noise | VT image test expected-format correction. |
| e39093786 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| 29e3de737 | na-feature | Adds Kitty graphics to the separate libghostty-vt API; c11 embeds the app API. |
| 30fdc8f4c | na-feature | Removes standalone SurfaceView native-scroll selector code absent from c11. |
| 18f270222 | verify | shared-confirmed: Find Next and Previous search for literal direction words. |
| c16cf0ef0 | na-feature | Linux distribution packaging or desktop integration only. |
| 702a2b43c | verify | already-fixed: Uppercase configured shortcuts do not match menu equivalents. |
| c8702ece8 | noise | GTK spelling cleanup. |
| 4803d58bb | verify | already-fixed: Text release used the wrong C ABI signature. |
| 591dbd511 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| a75615992 | na-feature | Repairs OSC 99 after an upstream parser API refactor; c11 lacks that newer parser layout. |
| 2be58ee0e | verify | shared-confirmed: Terminal color-scheme reports use stale app state. |
| ea482b73e | verify | already-fixed: Theme preview fails when its directory exists. |
| a3588ac53 | verify | already-fixed: Resize can briefly present blank or stretched frames. |
| 05cf31b38 | verify | already-fixed: Display-link callbacks can stop after display changes. |
| 3864fa585 | noise | CI dependency-version bump only. |
| 5de30c0dc | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| 013579cfc | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| 32920b6b2 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| af3695994 | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| 1fcd80daa | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| 3c2c596dc | na-feature | Standalone GlobalEventTap implementation is absent from c11. |
| 2b1ec5db6 | na-feature | explain_config.zig does not exist in c11's Ghostty checkout. |
| f0badd34d | verify | shared-confirmed: Locale initialization hard-codes Linux constants on macOS. |
| 96bad9020 | verify | shared-confirmed: Terminal color-scheme reports use stale app state. |
| ad0c5fbec | na-feature | Standalone SurfaceView search-focus monitor regression, not c11's portal focus path. |
| 95ee87890 | noise | Standalone search-focus regression test only. |
| 11574c35a | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| 43f3dc5f1 | verify | shared-confirmed: Trailing percent signs combine with zsh prompt marks. |
| c12f62c82 | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| 6f18d44ed | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| 68378a0bb | noise | Compile-time enum-check quota adjustment. |
| ce9930051 | na-feature | MSVC/Windows FreeType build compatibility. |
| 147596d56 | noise | CI dependency-version bump only. |
| 701d1d55d | noise | Terminal device-attributes test expectation only. |
| 22c7edf3f | noise | Effect name refactor, no behavior correction. |
| c1e616c6c | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| 1ce057f05 | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| 3c8d0a9c2 | na-feature | Includes production fixes in the separate libghostty-vt C API, which c11 does not embed. |
| 8bc75907b | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| e7a18ea5b | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| 220d6fd43 | noise | Nix inputs and dependency wiring only. |
| 900afa7b8 | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| b0789af58 | na-feature | Fixes newer translated-C PTY build machinery, not c11's current embedded runtime path. |
| 264a1a7cd | na-feature | Fixes target type in newer libc build wiring. |
| d80d84862 | na-feature | Standalone command-palette event monitor, absent from c11. |
| 27fd1c778 | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| 2d514013d | na-feature | Linux distribution packaging or desktop integration only. |
| 978abdeeb | na-feature | tmux control-mode parser, outside c11's terminal host integration. |
| 69554f414 | verify | shared-confirmed: SSH environment helper overrides user SetEnv values. |
| f730eed21 | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| fe6e7fbc6 | na-feature | Separate libghostty-vt C API, examples, or build target, not c11's embedded app API. |
| af84fdbea | noise | Search tests only. |
| 64331b8c3 | na-feature | Linux Snap launcher environment only. |
| 07bc88868 | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| 5e3866381 | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| ea262cdd3 | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| 4f849a151 | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| e31615d00 | verify | shared-confirmed: Bash vi-mode redraw inserts extra newlines. |
| 26d8bd9e7 | verify | shared-confirmed: Bash multiline prompt rewriting can corrupt substitutions. |
| c2206542d | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| 82a805296 | noise | Configuration documentation formatting only. |
| ad6d3665c | na-feature | GTK new-window working-directory inference. |
| 6dd5b856b | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| 85bec8033 | noise | CI dependency-version bump only. |
| 04d5efc8e | verify | shared-confirmed: Configured working directory does not expand tilde. |
| 53637ec7b | verify | shared-confirmed: Forward prompt navigation lands on continuation rows. |
| aaad43c23 | verify | shared-confirmed: Empty clipboard paste cannot decline a performable binding. |
| a6cd1b08a | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| cfedda1a0 | noise | Standalone window-size regression tests only. |
| 96f9772cd | noise | Font test isolation only. |
| 3ba49a784 | verify | shared-confirmed: Grapheme widening at the right edge can panic. |
| 235dde684 | verify | shared-confirmed: Ghostty helper loses buffered action-list output. |
| df4d9bc0d | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| 4bb602b0e | na-feature | Linux distribution packaging or desktop integration only. |
| f72d41675 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| 40c74811f | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| 3dde6e255 | verify | shared-confirmed: Link regex work has no explicit retry budget. |
| 5bc5820f3 | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| 9a3dbe10b | verify | already-fixed: Leading-newline zsh prompts gain extra blank lines. |
| e07aefa60 | verify | shared-confirmed: Existing zsh aliases can break integration function definitions. |
| 69df92b56 | noise | CI dependency-version bump only. |
| 391c9044b | noise | Fuzzer invocation argument cleanup. |
| 177612a4c | verify | already-fixed: Insert blanks can orphan wide characters at the right margin. |
| b39a00ddf | verify | already-fixed: Full line clears can orphan wide cells. |
| 1ba9f9187 | verify | already-fixed: No-reflow grow can leave spacer heads inside a row. |
| e7030e73d | verify | already-fixed: Overwriting wide characters can corrupt the preceding row. |
| 90e96a389 | verify | already-fixed: Insert blanks can orphan wide characters at the right margin. |
| 97c11af34 | verify | already-fixed: Wide linked characters can violate wrap integrity. |
| 630c2dff1 | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| a595c00f3 | verify | already-fixed: Overflowing tab-clear parameters can panic. |
| dce2326c4 | noise | Fuzz fixture Git attributes only. |
| 9157eb439 | verify | already-fixed: Zero insert-blanks count can crash. |
| dcaa8f397 | verify | already-fixed: CSI W without parameters can read out of bounds. |
| 2ed0e3b82 | noise | Contribution-document formatting only. |
| 12f43dfb7 | verify | already-fixed: DCS passthrough can overflow its parameter array. |
| 6e622f8c7 | noise | Standalone window cascade helper extraction. |
| 0db32ab9a | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| 2a4140146 | verify | already-fixed: Phantom mouse events unhide the pointer while typing. |
| 3ee63035d | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| c4766dff7 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| e6da439e4 | noise | Standalone macOS visual style changes. |
| 875985dbd | verify | already-fixed: SSH terminfo transfer interprets backslash escapes. |
| 05a125533 | na-feature | Ghostty standalone macOS app implementation is not used by c11's Swift host. |
| 20351a71d | verify | already-fixed: Palette C layout has too many color entries. |
| 7db8346fc | na-feature | GTK ImGui GLArea lifecycle, not c11's macOS embedded renderer. |
| dd4e36f92 | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| 57d570525 | na-feature | GTK tab/window lifecycle leak and associated command cleanup. |
| 0af3477e3 | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| d9d65fdb9 | na-feature | GTK runtime and UI only; c11 embeds Ghostty on macOS. |
| 407b3c082 | na-feature | Ghostty standalone macOS window/tab UI is not used by c11's Swift host. |
| 6052f664c | noise | Swiftlint formatting-rule update. |
| 2a62f21bf | noise | Renderer and search test expectations only. |
| f66064b0b | verify | already-fixed: Bare relative path links consume unified diff suffixes. |
| 85a631dd2 | noise | VT build formatting and style only. |
| 44b7d3465 | na-feature | Separate libghostty-vt Darwin build target. |
| d1cb22589 | noise | Bulgarian translation wording only. |
| a1a47d011 | noise | Irish translation wording only. |
| 1dc7158a3 | noise | Translation merge-conflict cleanup only. |
| 77957aa31 | noise | Font-shaping test expectations only. |
| 6afdf3400 | verify | already-fixed: Growing grapheme widths fail to widen terminal cells. |

## Counts

208 rows; na-feature 91; noise 57; done-round1 1; verify 59: confirmed 30, probable 2, already-fixed 25, n/a-diverged 2, skipped 0.

Counts above use input commit rows, so the disposition totals sum to 208 and the verification statuses sum to 59. The Verified table groups duplicates into 54 bug entries: 28 confirmed, 2 probable, 22 already-fixed, 2 n/a-diverged, 0 skipped. Port difficulty and recommendations are static estimates.
