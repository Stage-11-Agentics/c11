# Ghostty A verification

Read-only static research. No builds, tests, fetches, or runtime probes. Ghostty HEAD: `26c3e499ed8c4d65e3748248de7fd04c1e9a8103`. c11-only history from `b9989c101` and parent submodule/input history were inspected, including C11-21/C11-22. No matching port was found for the shared findings below. Parent HEAD checked at closeout: `d63b937f6580f362a19dcfe1b2a11fa45a09e765`. Working-tree code is the cited evidence. The PRs column contains Ghostty commit IDs because this batch has commits rather than cmux PR rows. Counts use original commit rows; grouped bug totals are shown separately. No cause is assigned to the unexplained July 28 freeze.

## Verified

bug (plain English) | PRs | subsystem | c11 status | severity | port | rec | evidence (upstream file + c11 path:line) | notes (incl. link to c11 known problem)
--- | --- | --- | --- | --- | --- | --- | --- | ---
Surface close can wait forever for an uncooperative child | 5b20c6229, 01e7c93ca | termio | shared-confirmed | high | M | reimplement | Upstream src/termio/Exec.zig and src/Surface.zig; c11 ghostty/src/termio/Exec.zig:1151, ghostty/src/termio/Exec.zig:199, ghostty/src/Surface.zig:826 | The shutdown loop repeatedly sends SIGHUP without a deadline or escalation. An ignoring launcher can hold the IO join forever. The later prompt-escalation change is relevant guidance when porting the bounded shutdown. Different mechanism from [known problem 1](../../../../notes/2026-08-25-freeze-surface-deinit-deadlock.md).
Descendants and foreground jobs survive surface shutdown | 88c3325dc, 81b4de4f5, 47e9bd4c9 | termio | shared-confirmed | high | M | reimplement | Upstream src/termio/Exec.zig; c11 ghostty/src/termio/Exec.zig:1152, ghostty/src/termio/Exec.zig:1183 | Shutdown treats the direct child exiting as completion and does not track the PTY foreground group. Repeated agent churn can leave running descendants. Port with bc7e9f746 safety constraints, not its stale cached-PGID intermediate design.
Dead PTYs can spin and exited children can escape reaping | 5ef5cba63 | termio | shared-confirmed | high | S | reimplement | Upstream src/termio/Exec.zig; c11 ghostty/src/termio/Exec.zig:1323, ghostty/src/termio/Exec.zig:1336, ghostty/src/termio/Exec.zig:1343, ghostty/src/termio/Exec.zig:1152 | EOF merely returns to poll; ERR/NVAL are not terminal events. getpgid failure skips reaping and waitpid lacks the explicit competing-waiter handling. Actual EOF-without-HUP trigger is inferred. Not the August mailbox cycle.
Focus and visibility can block the UI on renderer capacity | ca21db1bb | renderer | shared-confirmed | high | S | reimplement | Upstream src/Surface.zig and src/renderer/Thread.zig; c11 ghostty/src/Surface.zig:3338, ghostty/src/Surface.zig:3354; Sources/GhosttyTerminalView.swift:3909, Sources/GhosttyTerminalView.swift:3925 | Both lifecycle callbacks push with forever. Use coalesced latest-value publication. Display-ID alone was fixed by caf199071 and parent 8c7422b4f1. Related to known congestion and problem 4, not a fix for [problem 1](../../../../notes/2026-08-25-freeze-surface-deinit-deadlock.md).
Compacted pages can loop forever when a capacity starts at zero | 8307349ec | terminal allocation | shared-confirmed | high | S | port | Upstream src/terminal/PageList.zig; c11 ghostty/src/terminal/PageList.zig:3258, ghostty/src/terminal/PageList.zig:2763 | increaseCapacity doubles zero to zero, so allocation retry loops cannot progress. Existing compact can produce exact zero dimensions. A parser holding the terminal mutex can then block render and screen-read work. No evidence tying this to the July freeze.
Search results can retain freed page pointers after resize | 627518447 | terminal search | shared-confirmed | high | S | port | Upstream src/terminal/search/screen.zig; c11 ghostty/src/terminal/search/screen.zig:394, ghostty/src/terminal/search/screen.zig:698 | Only feed checks dimensions; reloadActive/select inspect cached highlights without first resetting them. Reflow can replace their nodes. c11 c64952975 fixes a different SlidingWindow row-metadata race.
Resize allocation failure leaves partially destroyed terminal state | 91f0cf67d, dde3d4d6b, a3c1caba5 | terminal resize | shared-confirmed | high | M | reimplement | Upstream src/terminal/Terminal.zig and src/terminal/Screen.zig; c11 ghostty/src/terminal/Terminal.zig:2825, ghostty/src/terminal/Terminal.zig:2831, ghostty/src/terminal/Screen.zig:1642 | Old tabstops are freed before replacement allocation; screen and primary/alternate updates are not transactional. Under memory pressure, an error leaves dangling or inconsistent state. Adapt rollback to c11's older PageList too.
Scroll-clear cursor reload carries page-local IDs onto another page | b3d4f547b | terminal state | shared-confirmed | high | S | port | Upstream src/terminal/Screen.zig; c11 ghostty/src/terminal/Screen.zig:758, ghostty/src/terminal/Screen.zig:771 | cursorReload assigns the new pin directly instead of migrating style/hyperlink references through cursorChangePin. A subsequent lookup or release can address an unrelated page entry.
Hyperlink reflow checks the wrong allocation shape | 5fac44744 | terminal reflow | shared-confirmed | high | S | port | Upstream src/terminal/PageList.zig; c11 ghostty/src/terminal/PageList.zig:1572 | One combined URI-plus-ID probe does not prove two rounded allocations fit. Capacity changes also invalidate the probe before the second dupe. Reflow can fail or hit assumptions with OSC 8 links during frequent pane resizing.
Cell movement across a row boundary computes an invalid column | 0ff4e41b2 | terminal pins | shared-confirmed | high | S | port | Upstream src/terminal/PageList.zig; c11 ghostty/src/terminal/PageList.zig:5300, ghostty/src/terminal/PageList.zig:5327 | Exact multiples of row width create an extra row step and can subtract one from zero for the column. Selection/navigation can produce invalid pins or overflow.
Switching grapheme mode can assert on previously stored clusters | b287f6d1a | terminal Unicode | shared-confirmed | high | S | port | Upstream src/terminal/Terminal.zig; c11 ghostty/src/terminal/Terminal.zig:375 | A cluster formed with mode 2027 disabled can contain a boundary. Enabling the mode later asserts that each existing pair has no boundary instead of updating the state machine. Release impact beyond the assertion depends on build safety.
Null CoreText names can crash font discovery and copied names leak | ff362c99c | font discovery | shared-confirmed | high | S | port | Upstream pkg/macos/text/font.zig and src/font/DeferredFace.zig; c11 ghostty/pkg/macos/text/font.zig:159, ghostty/src/font/DeferredFace.zig:142 | CTFontCopyDisplayName is treated as non-null and the copied object is not released. Guard missing names and copy into the caller buffer before release. Not the free-text ABI leak.
Alt plus a non-ASCII key can emit invalid or missing UTF-8 | 9038c8ef4 | input encoding | shared-confirmed | high | S | reimplement | Upstream src/input/key_encode.zig; c11 ghostty/src/input/key_encode.zig:542, ghostty/src/input/key_encode.zig:573 | legacyAltPrefix reduces the unshifted scalar to u8 and writes one byte. Non-ASCII Option-as-Alt input is truncated or rejected. Port UTF-8 encoding around the older Writer interface.
Startup locale mutation races crash-report initialization | f0f8273b7, abcf5697d | global initialization | shared-probable | high | S | reimplement | Upstream src/global.zig and src/crash/sentry.zig; c11 ghostty/src/global.zig:146, ghostty/src/global.zig:164, ghostty/src/crash/sentry.zig:74, ghostty/src/crash/sentry.zig:121, ghostty/src/os/locale.zig:62 | A background Sentry initializer can read process environment while locale setup mutates it. Inferred for c11's older libc/getenv implementation; it lacks the exact newer borrowed Environ object. Move locale initialization earlier and resolve environment-derived paths before spawning.
Queued PTY writes can drop a chunk on WouldBlock | 2f6ee7b3d | libxev writes | shared-probable | high | M | reimplement | Upstream vendor/libxev/src/watcher/stream.zig; c11 ghostty/build.zig.zon:12, ghostty/src/termio/Exec.zig:455; pinned dependency src/watcher/stream.zig:841 | The pinned cached dependency pops the request for every error instead of retaining WouldBlock. The exact old code is present; whether this backend surfaces WouldBlock is inferred. Large socket sends/pastes are the relevant trigger. Cache path is recorded below.
Host callback userdata already outlives synchronous surface free | 289097387, 76c8b03d8 | embedded lifetime | already-fixed | high | - | skip | Upstream src/apprt/embedded.zig; c11 Sources/GhosttyTerminalView.swift:3460, Sources/GhosttyTerminalView.swift:4296, ghostty/src/apprt/embedded.zig:619 | c11 retains GhosttySurfaceCallbackContext until ghostty_surface_free returns after thread teardown. The upstream owned-userdata constructor and additional callback leasing are not required for this host lifetime contract.
Previous search cannot underflow at wraparound | 1e63834cd | terminal search | n/a-diverged | high | - | skip | Upstream src/terminal/search/screen.zig; c11 ghostty/src/terminal/search/screen.zig:803 | c11 returns false at index zero and does not implement the upstream wraparound expression. History a2a771bb6 confirms its older previous-match design.
Resize does not retain a cursor pin above active rows | 7837563ed | terminal reflow | n/a-diverged | high | - | skip | Upstream src/terminal/PageList.zig; c11 ghostty/src/terminal/PageList.zig:1028 | c11 reconstructs the cursor pin using active coordinates before counting wraps. It cannot precede the active-area top in this branch; the later tracked-pin regression is absent.
New action leases address a dispatch model absent in c11 | cf1dee45d | embedded lifetime | n/a-diverged | high | - | skip | Upstream src/App.zig and src/apprt/embedded.zig; c11 ghostty/src/App.zig:282, Sources/GhosttyTerminalView.swift:4299 | c11 teardown is queued to MainActor and App.redrawSurface performs no surface access after the host callback. It lacks the upstream cross-thread external redraw ticket dispatch that requires these leases.
Timed GPU teardown can free the wrong in-flight frame upstream | d5d3dec57 | Metal lifetime | n/a-diverged | high | - | skip | Upstream src/renderer/generic.zig and src/renderer/metal/CompletionLifetime.zig; c11 ghostty/src/renderer/generic.zig:288, ghostty/src/renderer/Metal.zig:188 | c11 waits for every frame permit and drains the command queue via b4ef0ac2c. It lacks iOS bounded teardown and tokened presentations. This does not prove c11 GPU teardown cannot hang; the separate main-queue deadlock was handled in round 1.
Growing Metal buffers repeatedly allocate too much memory | e78e31a93 | Metal memory | shared-confirmed | med | S | port | Upstream src/renderer/metal/buffer.zig; c11 ghostty/src/renderer/metal/buffer.zig:84, ghostty/src/renderer/metal/buffer.zig:141 | req_bytes is multiplied by sizeof(T) again and self.len is never raised. Oversized allocations can recur every frame above the initial capacity. This scales across visible agents; separate from C11-225 occlusion work.
Freed scrollback pages retain their high-water footprint | 896aca499 | terminal memory | shared-confirmed | med | S | port | Upstream src/terminal/PageList.zig; c11 ghostty/src/terminal/PageList.zig:3421 | Returning zeroed pages to MemoryPool never releases physical backing. Add Darwin reusable/reuse advice. This is retained high-water memory, not proven unbounded leakage.
Bitmap allocator reserves unreachable chunk bytes | b953bb346 | terminal memory | shared-confirmed | med | S | port | Upstream src/terminal/bitmap_allocator.zig; c11 ghostty/src/terminal/bitmap_allocator.zig:222 | Layout multiplies aligned byte capacity by chunk size instead of multiplying chunk count. Extra allocation multiplies across terminal pages.
Dense hyperlink maps accumulate expensive probe chains | 7e14347c1 | terminal hash maps | shared-confirmed | med | M | reimplement | Upstream src/terminal/hash_map.zig and src/terminal/hyperlink.zig; c11 ghostty/src/terminal/hash_map.zig:707, ghostty/src/terminal/hyperlink.zig:23 | Full-load open addressing and tombstones leave long unsuccessful probes. Port the load budget and in-place rehash with the page-layout capacity contract. Cost grows with link-rich output.
Count-limited page iteration truncates at the first page | 9b466e9c5 | terminal iteration | shared-confirmed | med | S | port | Upstream src/terminal/PageList.zig; c11 ghostty/src/terminal/PageList.zig:4713, ghostty/src/terminal/PageList.zig:4782 | len is min(available, limit), so len greater than limit is impossible and iteration always ends. Reverse chunk bounds also omit a row.
Consumed bindings leak a key release when modifiers change first | d9311bb99 | input bindings | shared-confirmed | med | S | reimplement | Upstream src/Surface.zig and src/input/key.zig; c11 ghostty/src/Surface.zig:2892, ghostty/src/Surface.zig:3089 | Press and release are matched using a hash containing modifiers. Releasing the modifier first breaks the pair. The fix applies beyond upstream's newer menu API.
Repeated config finalization removes custom matchers | 30bd02565 | config | shared-confirmed | med | S | reimplement | Upstream src/config/Config.zig; c11 ghostty/src/config/Config.zig:4621 | With link-url=false, every finalize slices the first matcher away again. It eventually deletes custom rules or slices an empty list. Track whether the built-in matcher was already removed.
Cmd-click can send an unmatched mouse press to an agent TUI | d1dbbec9b, 76ead3eae, f24195271, 5998abddd, 59fb750c0, 9f014e98b, df789cd4b | mouse input | shared-confirmed | med | M | reimplement | Upstream src/Surface.zig; c11 ghostty/src/Surface.zig:4049, ghostty/src/Surface.zig:4072, ghostty/src/Surface.zig:4094 | Link opening consumes release before mouse reporting, while press/motion still reach the TUI. Port a complete left-click latch with press-time chord and link-origin checks. Later commits repair intermediate latch designs, not seven independent c11 defects.
IME commits outside keyDown bypass application key encoding | 751a60df6 | macOS input | shared-confirmed | med | S | reimplement | Upstream macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift; c11 Sources/GhosttyTerminalView.swift:9812, Sources/GhosttyTerminalView.swift:9831 | insertText discards marked state and routes standalone commits through raw text/paste. A composed commit should use key events. c11 b4d152c189 fixes Enter leakage, a different IME seam.
Mixed pasteboard items lose text and item order | 49806fc4c | paste | shared-confirmed | med | S | reimplement | Upstream macos/Sources/Helpers/Extensions/NSPasteboard+Extension.swift; c11 Sources/GhosttyTerminalView.swift:108 | Reading all NSURL objects first drops adjacent non-URL text. Iterate items and preserve c11's explicit UTF-8 preference.
URL drops use file paths and differ from paste | 6e267d336 | drag and drop | shared-confirmed | med | S | reimplement | Upstream macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift; c11 Sources/GhosttyTerminalView.swift:6724, Sources/GhosttyTerminalView.swift:6730 | Dropped NSURL values are converted to path even for web URLs, and the fallback shell-escapes raw URLs. Reuse the corrected shared pasteboard helper.
Identical SGR attributes repeatedly churn the style map | cee35cabf | terminal throughput | shared-confirmed | med | S | port | Upstream src/terminal/Screen.zig; c11 ghostty/src/terminal/Screen.zig:1978 | setAttribute always calls manualStyleUpdate even when the style is unchanged. An equality guard saves work for repetitive colored agent output.
macOS log calls repeatedly create handles and format disabled messages | ee691e86b | logging | shared-confirmed | med | S | port | Upstream src/main_ghostty.zig and pkg/macos/os/log.zig; c11 ghostty/src/main_ghostty.zig:145, ghostty/pkg/macos/os/log.zig:35 | Every enabled macOS log route creates/releases its logger; Log.log formats before testing enabled level. Cache per-scope handles and gate formatting.
CJK fallback glyphs use a one-cell estimate for a two-cell span | 0068ece73 | font metrics | shared-confirmed | med | S | port | Upstream src/font/Collection.zig and src/font/Metrics.zig; c11 ghostty/src/font/Collection.zig:629 | A primary font missing ideograph metrics normalizes fallback size through icWidth instead of the intended two-cell width. Visible with CJK output.
Consumed Alt incorrectly suppresses associated text | 14d4d041b | Kitty keyboard | shared-confirmed | med | S | port | Upstream src/input/key_encode.zig; c11 ghostty/src/input/key_encode.zig:291 | Kitty associated-text gating checks raw Alt/configuration without honoring consumed_mods.alt. Layout-generated text can be absent in keyboard-protocol TUIs.
Hot PTY output can starve renderer snapshots | d34b54e9b | renderer scheduling | shared-probable | med | S | reimplement | Upstream src/renderer/State.zig, src/renderer/generic.zig, src/termio/Exec.zig; c11 ghostty/src/renderer/generic.zig:1189, ghostty/src/termio/Exec.zig:1326 | The parser repeatedly reacquires an unfair terminal mutex without waiter handoff. Renderer starvation is inferred from the shared loop. Relevant to known congestion, but does not explain SwiftUI AttributeGraph or metadata-store queue stalls.
Metal command queues keep their default driver capacity | 85002fa1c | Metal memory | shared-probable | med | S | watch | Upstream src/renderer/Metal.zig; c11 ghostty/src/renderer/Metal.zig:83, ghostty/src/renderer/generic.zig:298 | The default newCommandQueue call is shared. A three-slot queue could reduce per-surface driver overhead, inferred. c11 already limits active frames to three; this is not unbounded submission.
Ordinary terminal resize already updates pixels and synchronized output | 89b103dd5 | terminal resize | n/a-diverged | med | - | skip | Upstream src/terminal/Terminal.zig and src/termio/Termio.zig; c11 ghostty/src/termio/Termio.zig:495, ghostty/src/termio/Termio.zig:502, ghostty/src/termio/Termio.zig:507 | The upstream change centralizes these side effects for lib-vt callers. c11's embedded resize path already performs them and does not ship that new lib-vt terminal API.
Soft-wrapped URLs are not cut at semantic prompt markers | eee34d0f9 | terminal links | n/a-diverged | med | - | skip | Upstream src/Surface.zig; c11 ghostty/src/Surface.zig:4525 | c11 already selects the complete logical line with semantic_prompt_boundary=false. Upstream's newer semantic/path matcher split introduced the truncation.
Font-name logging can abort otherwise valid font setup | b45f4e6ac | font discovery | shared-confirmed | low | S | port | Upstream src/font/SharedGridSet.zig; c11 ghostty/src/font/SharedGridSet.zig:200, ghostty/src/font/SharedGridSet.zig:231 | Diagnostic face.name errors propagate instead of falling back to a placeholder. This compounds the null-name issue above but is a separate failure policy.
Single-slot theme selection writes an incomplete conditional theme | 987780a13 | theme picker | shared-confirmed | low | S | port | Upstream src/cli/list_themes.zig; c11 ghostty/src/cli/list_themes.zig:407, ghostty/src/cli/list_themes.zig:415 | With only one slot configured, the picker emits light-only or dark-only syntax although conditional parsing requires both. c11's earlier theme-picker commits do not change these branches.
Overlapping hover rules underline a different span than clicks resolve | b5c39a8f7 | terminal links | shared-confirmed | low | S | port | Upstream src/renderer/link.zig; c11 ghostty/src/renderer/link.zig:98, ghostty/src/Surface.zig:4536 | Hover collects every matching rule while click resolution returns its first match. Stop lower-priority hover rules after a claim.
Decomposed Hangul resolves and shapes through the wrong fallback | 3fbdd078d, 3a7fc9230 | font shaping | shared-probable | low | M | reimplement | Upstream src/font/shaper/run.zig and src/font/hangul.zig; c11 ghostty/src/font/shaper/run.zig:318 | Font selection starts from individual stored codepoints and lacks canonical Hangul composition. Equivalent NFC/NFD output can differ, inferred for c11 fonts. Preserve original terminal text and apply composition only to font/shaping queries.
Theme picker waits for an event before its first draw | 5068b3a37 | theme picker | shared-probable | low | S | port | Upstream src/cli/list_themes.zig; c11 ghostty/src/cli/list_themes.zig:623, ghostty/src/cli/list_themes.zig:635 | cmux picker skips the terminal query and only draws after pollEvent. Whether the older vaxis startup supplies a winsize event immediately is unproven. c11 does already call loop.start at line 614.
Extreme drag coordinates can overflow integer conversion | 08e376f23 | terminal selection | shared-probable | low | S | watch | Upstream src/terminal/SelectionGesture.zig; c11 ghostty/src/Surface.zig:4975, ghostty/src/Surface.zig:4976 | The older inline implementation also converts unclamped positive floats to u32. Normal AppKit coordinates are finite and small; reachable extreme input is unproven. Saturating conversion is a small defensive port.
Reordered combining glyphs can use another cluster's anchor | eea8fdce5 | font shaping | shared-probable | low | M | watch | Upstream src/font/shaper/coretext.zig; c11 ghostty/src/font/shaper/coretext.zig:439, ghostty/src/font/shaper/coretext.zig:491 | The old shaper has one cell offset and no per-cluster anchor. The LTR missing-first-glyph repair is plausibly useful for Bengali. The upstream RTL implementation itself is absent, so exact multilingual output remains unverified.
Repeated click anchor is already refreshed | abd40f6e4 | terminal selection | n/a-diverged | low | - | skip | Upstream src/terminal/SelectionGesture.zig; c11 ghostty/src/Surface.zig:4148, ghostty/src/Surface.zig:4156 | c11 untracks the prior pin and stores the current click position for every press, including repeats. The extracted upstream gesture regression does not occur.
VT replay cursor restoration follows margins incorrectly in an unused formatter path | 9e49174be, d6fdb42e1, 2bba4149b, 9ddb1ab57 | VT formatter | n/a-diverged | low | - | skip | Upstream src/terminal/formatter.zig; c11 ghostty/src/terminal/formatter.zig:341, ghostty/src/terminal/formatter.zig:369 | The old formatter has the ordering defect, but repository call-site search finds no production TerminalFormatter caller. c11 does not export full-state VT replay through the newer upstream snapshot API. Revisit if that API is added.

## Top findings

Focus and visibility still push into the renderer mailbox with an infinite wait. `ca21db1bb` is the clearest extension of c11's existing display-ID fix. Coalescing these lifecycle values would remove two UI blocking paths during workspace churn. This is related to the known congestion profile, but it does not resolve the [August 25 freeze](../../../../notes/2026-08-25-freeze-surface-deinit-deadlock.md): that cycle involves the separate app mailbox and a read thread joined by main. The app/renderer drain budgets were already covered in round 1 and are excluded here.

Surface shutdown also has an independent infinite wait: it repeatedly signals SIGHUP until the direct child exits. The bounded process-teardown family matters for agent launchers that ignore HUP and for descendants in separate foreground groups. Reimplement the final behavior as a unit, with graceful deadlines, escalation, race-safe reaping, and fresh process-group attribution. Importing an intermediate cached-PGID version would introduce a new risk. These changes alone still cannot release a read thread parked on the full app mailbox.

The most serious terminal-state findings are zero-capacity growth that never progresses, stale search pointers after resize, and failed resize operations leaving destroyed or inconsistent state. All have matching c11 code. Frequent splits, changing layouts, heavy scrollback, and long sessions make them worth addressing before cosmetic ports. The OSC 8 reflow and page-local cursor-ID fixes belong in the same terminal hardening pass. None is proven to explain a recorded c11 crash or freeze.

Several small changes reduce work multiplied across 10 to 40 agents: correct Metal buffer sizing and capacity bookkeeping, correct bitmap allocation sizing, return free-listed page backing to macOS, skip unchanged SGR updates, and cache/gate macOS logging. The unfair terminal mutex also lacks the upstream demand handoff; renderer starvation remains inferred until measured. These changes concern Ghostty work and do not repair the separate SwiftUI AttributeGraph, hover-recursion, or SurfaceMetadataStore queue stalls.

The input findings affect real terminal bytes and event pairing. Non-ASCII Alt encoding is directly shared, and Cmd-click can leave an unmatched press in a mouse-reporting TUI. The pinned libxev source also contains the error-pop behavior fixed by `2f6ee7b3d`, but the macOS WouldBlock trigger is not established, so that finding stays probable. The cached dependency inspected was `/Users/atin/.cache/zig/p/libxev-0.0.0-86vtc4IcEwCqEYxEYoN_3KXmc6A9VLcm22aVImfvecYs/src/watcher/stream.zig:841`, matching `ghostty/build.zig.zon:12`. No runtime paste or key probe was run.

## Triage ledger

pr | disposition | one-line reason
--- | --- | ---
315d78b99 | noise | Tests, CI, documentation, or revert housekeeping. test: a prompt after a padded partial line must stay at column 0 across resize
2decb9c14 | na-feature | Upstream bounded-shutdown SIGTERM grace regression requires the new teardown phases.
0068ece73 | verify | CJK fallback glyphs use a one-cell estimate for a two-cell span. shared-confirmed.
01e7c93ca | verify | Surface close can wait forever for an uncooperative child. shared-confirmed.
f44c09ab9 | na-feature | New bare-localhost matcher and its punctuation follow-up add recognition c11 never had.
b05fc200f | na-feature | Upstream Zig 0.16 migration regression; c11 uses Zig 0.15.2.
cb794a219 | na-feature | Upstream keyboard copy-mode APIs are absent from c11.
a94ef8d97 | na-feature | Upstream keyboard copy-mode APIs are absent from c11.
9038c8ef4 | verify | Alt plus a non-ASCII key can emit invalid or missing UTF-8. shared-confirmed.
b3d4f547b | verify | Scroll-clear cursor reload carries page-local IDs onto another page. shared-confirmed.
ff2e810f7 | na-feature | Upstream Valgrind fixes concern new formatter/compression code and test cleanup.
5fac44744 | verify | Hyperlink reflow checks the wrong allocation shape. shared-confirmed.
e78e31a93 | verify | Growing Metal buffers repeatedly allocate too much memory. shared-confirmed.
39215aba9 | noise | MemoryPool replaces a historical pool and improves benchmarks; commit does not establish a behavioral bug.
6f2701078 | noise | Tests, CI, documentation, or revert housekeeping. test: cover Hangul selection bounds, copy path, and uncomposable jamo
e5a6849dc | noise | Tests, CI, documentation, or revert housekeeping. test: cover Hangul jamo fonts and style fallback
3a7fc9230 | verify | Decomposed Hangul resolves and shapes through the wrong fallback. shared-probable.
452bc460c | noise | Tests, CI, documentation, or revert housekeeping. test: reproduce NFD Hangul fallback glyph mismatch
7d6da4213 | na-feature | Upstream keyboard copy-mode APIs are absent from c11.
46428d790 | na-feature | New bare-localhost matcher and its punctuation follow-up add recognition c11 never had.
abd40f6e4 | verify | Repeated click anchor is already refreshed. n/a-diverged.
466f85867 | noise | Tests, CI, documentation, or revert housekeeping. Reapply "Merge remote-tracking branch 'origin/main' into issue-10557-reload-config-stall"
61c4d1f02 | noise | Tests, CI, documentation, or revert housekeeping. Revert "Merge remote-tracking branch 'origin/main' into issue-10557-reload-config-stall"
fd13a3fc2 | na-feature | Upstream shell SSH wrapper is outside c11 support and not the embedded terminal path.
5045df3f2 | na-feature | Upstream pixel-offset scrolling state is absent from c11 RenderState.
987780a13 | verify | Single-slot theme selection writes an incomplete conditional theme. shared-confirmed.
3da10da73 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
a63a97868 | na-feature | Upstream shell SSH wrapper is outside c11 support and not the embedded terminal path.
f27772d10 | done-round1 | fix: enqueue bracketed paste atomically
7ad529298 | noise | Tests, CI, documentation, or revert housekeeping. test: cover atomic bracketed paste encoding
bfd51a21b | na-feature | Upstream lib-vt export or imported graphics-state API is absent from the c11 embedder.
bc7e9f746 | na-feature | Upstream cached process-group fallback introduced by bounded teardown is absent from c11.
53239618f | noise | Tests, CI, documentation, or revert housekeeping. test: reject stale process-group teardown
47e9bd4c9 | verify | Descendants and foreground jobs survive surface shutdown. shared-confirmed.
babe4266c | noise | Tests, CI, documentation, or revert housekeeping. test: cover distinct foreground process-group teardown
9ddb1ab57 | verify | VT replay cursor restoration follows margins incorrectly in an unused formatter path. n/a-diverged.
2bba4149b | verify | VT replay cursor restoration follows margins incorrectly in an unused formatter path. n/a-diverged.
d6fdb42e1 | verify | VT replay cursor restoration follows margins incorrectly in an unused formatter path. n/a-diverged.
9e49174be | verify | VT replay cursor restoration follows margins incorrectly in an unused formatter path. n/a-diverged.
81b4de4f5 | verify | Descendants and foreground jobs survive surface shutdown. shared-confirmed.
b8a643561 | noise | Tests, CI, documentation, or revert housekeeping. test: cover process-group grace and leader exit
88c3325dc | verify | Descendants and foreground jobs survive surface shutdown. shared-confirmed.
3fbdd078d | verify | Decomposed Hangul resolves and shapes through the wrong fallback. shared-probable.
0316a8de8 | noise | Tests, CI, documentation, or revert housekeeping. test: NFC and NFD Hangul must resolve the same font face
5b20c6229 | verify | Surface close can wait forever for an uncooperative child. shared-confirmed.
9513174f2 | na-feature | Upstream lib-vt export or imported graphics-state API is absent from the c11 embedder.
11aa609d7 | na-feature | Upstream lib-vt export or imported graphics-state API is absent from the c11 embedder.
45aec50de | noise | Tests, CI, documentation, or revert housekeeping. test: cover spawned open stderr reader log bound
f0f8273b7 | verify | Startup locale mutation races crash-report initialization. shared-probable.
ee691e86b | verify | macOS log calls repeatedly create handles and format disabled messages. shared-confirmed.
5068b3a37 | verify | Theme picker waits for an event before its first draw. shared-probable.
abcf5697d | verify | Startup locale mutation races crash-report initialization. shared-probable.
6143bac77 | na-feature | Upstream vaxis 0.6 lifecycle regression; c11 pins vaxis 0.5.1.
e7d06af34 | na-feature | Upstream renderer recovery timers and shared shader cache are absent from c11.
45abb8a2d | na-feature | Upstream renderer recovery timers and shared shader cache are absent from c11.
78621f8ce | na-feature | Upstream renderer recovery timers and shared shader cache are absent from c11.
a1e727ad2 | na-feature | Upstream renderer recovery timers and shared shader cache are absent from c11.
9fff00fc4 | na-feature | Upstream renderer recovery timers and shared shader cache are absent from c11.
2258bea96 | done-round1 | fix: bound app mailbox drain turns
6a8cdbc7a | done-round1 | test: reproduce app mailbox drain starvation
074c0f7b7 | na-feature | Upstream renderer recovery timers and shared shader cache are absent from c11.
982a723ff | na-feature | Backend error-set compatibility fix for the newly added WouldBlock retry patch.
d74e17608 | noise | Tests, CI, documentation, or revert housekeeping. test: compile queued writes without WouldBlock
2f6ee7b3d | verify | Queued PTY writes can drop a chunk on WouldBlock. shared-probable.
b45f4e6ac | verify | Font-name logging can abort otherwise valid font setup. shared-confirmed.
5faee251a | na-feature | Upstream renderer recovery timers and shared shader cache are absent from c11.
8f31fb57c | done-round1 | os/open: stop the stderr drain from spinning and leaking zombies
4a6c443c3 | na-feature | Upstream keyboard copy-mode APIs are absent from c11.
7a5d08b7c | na-feature | Upstream keyboard copy-mode APIs are absent from c11.
acefff5de | na-feature | Upstream keyboard copy-mode APIs are absent from c11.
65505e8c3 | na-feature | Upstream keyboard copy-mode APIs are absent from c11.
aeed68c44 | na-feature | Upstream keyboard copy-mode APIs are absent from c11.
0f2b10bad | noise | Tests, CI, documentation, or revert housekeeping. test: require renderer-owned Metal resource lifetimes
7b24d1c5d | done-round1 | renderer: avoid main-queue teardown deadlock
68ffad656 | noise | Tests, CI, documentation, or revert housekeeping. test: prevent main-queue renderer teardown deadlock
90ce8e97b | na-feature | Shared Metal command queue does not exist in c11; per-surface queue reviewed separately.
fece6fbb1 | noise | Tests, CI, documentation, or revert housekeeping. test: bound shared Metal queue depth
85002fa1c | verify | Metal command queues keep their default driver capacity. shared-probable.
f6e1839a2 | noise | Tests, CI, documentation, or revert housekeeping. test: bound Metal queue capacity to swap chain
517a4c75a | done-round1 | renderer: reclaim hidden macOS tab GPU memory
af4dfb43f | done-round1 | fix: release action lease before teardown wake
b8efe0f45 | noise | Tests, CI, documentation, or revert housekeeping. test: cover action release teardown ordering
d9311bb99 | verify | Consumed bindings leak a key release when modifiers change first. shared-confirmed.
22d6c589f | na-feature | Upstream menu-owned exact-action API is absent from c11.
28c0f9bf5 | noise | Tests, CI, documentation, or revert housekeeping. test: order cross-thread teardown assertions
ff36ae8ac | done-round1 | fix: serialize teardown with cross-thread actions
b47e5cac2 | done-round1 | fix: complete surface teardown before free returns
fcafac572 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
f4b337d1d | noise | Tests, CI, documentation, or revert housekeeping. test: require synchronous teardown during redraw action
7541eb3db | noise | Tests, CI, documentation, or revert housekeeping. Revert "Merge pull request #140 from manaflow-ai/issue-8808-owned-userdata-lifetime"
5ef5cba63 | verify | Dead PTYs can spin and exited children can escape reaping. shared-confirmed.
365fe1d2c | na-feature | Upstream PTY tee setter API is absent from c11.
14ce6dbd3 | noise | Tests, CI, documentation, or revert housekeeping. test: lease setter-installed PTY tee callbacks
76c8b03d8 | verify | Host callback userdata already outlives synchronous surface free. already-fixed.
289097387 | verify | Host callback userdata already outlives synchronous surface free. already-fixed.
cf1dee45d | verify | New action leases address a dispatch model absent in c11. n/a-diverged.
b1ad44d13 | noise | Tests, CI, documentation, or revert housekeeping. test: reproduce redraw dispatch teardown race
741b11662 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
b7feeea5c | na-feature | Upstream lib-vt export or imported graphics-state API is absent from the c11 embedder.
62e1de720 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
3c6f54836 | noise | Tests, CI, documentation, or revert housekeeping. test: reproduce external redraw delivery races
6126cfd39 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
d1efafd78 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
f2f1dfeb8 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
727a7dc02 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
2cfe9b349 | done-round1 | fix: bound renderer mailbox wake batches
83c3e4c51 | noise | Tests, CI, documentation, or revert housekeeping. test: reproduce renderer mailbox wake starvation
188d31a97 | done-round1 | fix: bound renderer mailbox drain turns
823641e23 | na-feature | New hard-wrap/path resolver API and follow-up fixes are absent from c11.
ff362c99c | verify | Null CoreText names can crash font discovery and copied names leak. shared-confirmed.
1b703a9d8 | na-feature | Upstream Zig 0.16 migration regression; c11 uses Zig 0.15.2.
8779d2d7f | na-feature | Upstream Zig 0.16 migration regression; c11 uses Zig 0.15.2.
9687f7b72 | na-feature | Upstream Zig 0.16 migration regression; c11 uses Zig 0.15.2.
ca21db1bb | verify | Focus and visibility can block the UI on renderer capacity. shared-confirmed.
2d99010ff | noise | Tests, CI, documentation, or revert housekeeping. test: cover nonblocking renderer lifecycle state
24c3f0822 | na-feature | Upstream Zig 0.16 migration regression; c11 uses Zig 0.15.2.
79c5b032b | noise | Tests, CI, documentation, or revert housekeeping. test: cover Kitty temporary file directory boundary
14d4d041b | verify | Consumed Alt incorrectly suppresses associated text. shared-confirmed.
573661a03 | na-feature | Upstream Zig 0.16 migration regression; c11 uses Zig 0.15.2.
5c271509e | na-feature | Upstream Zig 0.16 migration regression; c11 uses Zig 0.15.2.
b988efcfe | na-feature | Upstream Zig 0.16 migration regression; c11 uses Zig 0.15.2.
a77c706a1 | na-feature | Upstream Zig 0.16 migration regression; c11 uses Zig 0.15.2.
b211341be | na-feature | Upstream OpenGL embedded surface path is not used by the macOS Metal app.
fe44a2ef4 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
fb97d47a0 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
f22ef7896 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
d5d3dec57 | verify | Timed GPU teardown can free the wrong in-flight frame upstream. n/a-diverged.
56f0479de | noise | Tests, CI, documentation, or revert housekeeping. test: cover stalled Metal teardown lifetime
56e3fcfd5 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
cc1574d2d | noise | Tests, CI, documentation, or revert housekeeping. test: cover callback registration lifetime
da0372405 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
e4851d3d7 | noise | Tests, CI, documentation, or revert housekeeping. test: cover presentation teardown and deferral
5038188f1 | na-feature | New hard-wrap/path resolver API and follow-up fixes are absent from c11.
fedd33703 | na-feature | Upstream external rendering and presentation-token API is absent from c11.
8eb1857c4 | na-feature | New hard-wrap/path resolver API and follow-up fixes are absent from c11.
0768b05d2 | na-feature | New hard-wrap/path resolver API and follow-up fixes are absent from c11.
eb9004aa8 | na-feature | New hard-wrap/path resolver API and follow-up fixes are absent from c11.
b5c39a8f7 | verify | Overlapping hover rules underline a different span than clicks resolve. shared-confirmed.
11dd30a9b | na-feature | New hard-wrap/path resolver API and follow-up fixes are absent from c11.
a3c1caba5 | verify | Resize allocation failure leaves partially destroyed terminal state. shared-confirmed.
dde3d4d6b | verify | Resize allocation failure leaves partially destroyed terminal state. shared-confirmed.
89b103dd5 | verify | Ordinary terminal resize already updates pixels and synchronized output. n/a-diverged.
90ee78676 | na-feature | Upstream OpenGL embedded surface path is not used by the macOS Metal app.
516a72ac1 | na-feature | Upstream OpenGL embedded surface path is not used by the macOS Metal app.
0d23cf558 | na-feature | Upstream OpenGL embedded surface path is not used by the macOS Metal app.
68376f5ac | noise | Tests, CI, documentation, or revert housekeeping. build(deps): bump cachix/install-nix-action from 31.10.7 to 31.11.0
30bd02565 | verify | Repeated config finalization removes custom matchers. shared-confirmed.
cbf65567a | na-feature | New hard-wrap/path resolver API and follow-up fixes are absent from c11.
eee34d0f9 | verify | Soft-wrapped URLs are not cut at semantic prompt markers. n/a-diverged.
d1b22bf96 | na-feature | Upstream post-fork API is absent: authoritative scrollbar getter.
59153a988 | na-feature | Upstream terminal config import build repair has no corresponding missing import in c11.
ae76cfbfc | na-feature | GTK-only behavior; c11 is a macOS embedded host.
7e14347c1 | verify | Dense hyperlink maps accumulate expensive probe chains. shared-confirmed.
9b466e9c5 | verify | Count-limited page iteration truncates at the first page. shared-confirmed.
91f0cf67d | verify | Resize allocation failure leaves partially destroyed terminal state. shared-confirmed.
b287f6d1a | verify | Switching grapheme mode can assert on previously stored clusters. shared-confirmed.
08e376f23 | verify | Extreme drag coordinates can overflow integer conversion. shared-probable.
8f1c2fe95 | na-feature | Backwards caller-supplied timestamps concern extracted SelectionGesture; c11 obtains monotonic Instant.now internally.
0ff4e41b2 | verify | Cell movement across a row boundary computes an invalid column. shared-confirmed.
bdf4baa80 | na-feature | Selection-change host notification was added upstream; c11 has no such callback.
627518447 | verify | Search results can retain freed page pointers after resize. shared-confirmed.
d0c50089e | na-feature | Selection-change host notification was added upstream; c11 has no such callback.
035ae8ddb | noise | Tests, CI, documentation, or revert housekeeping. build(deps): bump cachix/install-nix-action from 31.10.6 to 31.10.7
d34b54e9b | verify | Hot PTY output can starve renderer snapshots. shared-probable.
25e624569 | na-feature | Upstream compression pipeline is absent from c11.
6d5dda40d | noise | Tests, CI, documentation, or revert housekeeping. inspector: clarify page compression memory
f6fd4cb08 | na-feature | Upstream compression pipeline is absent from c11.
c62c15984 | na-feature | Upstream compression pipeline is absent from c11.
dd726a9a6 | na-feature | Upstream ownership-guard type repair depends on new layer-detach code.
66c3bc6f1 | na-feature | External render-now owner handoff is iOS-only; c11 has no external drainer. Shared early stop notification is insufficient to fix the known mailbox cycle.
60121a039 | na-feature | Non-Darwin-only read-ahead change has no effect on this macOS app.
896aca499 | verify | Freed scrollback pages retain their high-water footprint. shared-confirmed.
8307349ec | verify | Compacted pages can loop forever when a capacity starts at zero. shared-confirmed.
b953bb346 | verify | Bitmap allocator reserves unreachable chunk bytes. shared-confirmed.
20a1bfa5f | na-feature | Upstream lib-vt export or imported graphics-state API is absent from the c11 embedder.
751a60df6 | verify | IME commits outside keyDown bypass application key encoding. shared-confirmed.
bed47168c | na-feature | Non-Darwin-only read-ahead change has no effect on this macOS app.
cee35cabf | verify | Identical SGR attributes repeatedly churn the style map. shared-confirmed.
6e267d336 | verify | URL drops use file paths and differ from paste. shared-confirmed.
004c88e41 | na-feature | GTK-only behavior; c11 is a macOS embedded host.
8fe5913f7 | na-feature | Upstream 32-bit atomics build fix is irrelevant to macOS arm64/x86_64.
bdc0b6c19 | noise | Generation stamps add cache identity and lib-vt observation; no demonstrated c11 timestamp collision or behavior regression.
49806fc4c | verify | Mixed pasteboard items lose text and item order. shared-confirmed.
acd09c0a6 | noise | Tests, CI, documentation, or revert housekeeping. macos: add tests for NSPasteboard.getOpinionatedStringContents
aea63d71f | na-feature | Upstream lib-vt export or imported graphics-state API is absent from the c11 embedder.
0274e7ad8 | na-feature | Upstream standalone Ghostty window UI is not shipped by c11.
31068ca6e | na-feature | RTL run shaping and per-cluster RTL anchors were added after c11 forked.
eea8fdce5 | verify | Reordered combining glyphs can use another cluster's anchor. shared-probable.
0a117e079 | na-feature | GTK-only behavior; c11 is a macOS embedded host.
632aa6756 | na-feature | Upstream standalone Ghostty window UI is not shipped by c11.
301e0791b | na-feature | Upstream keyboard copy-mode APIs are absent from c11.
e81fb65f6 | na-feature | Upstream keyboard copy-mode APIs are absent from c11.
8e8a8dc11 | na-feature | Upstream standalone Ghostty window UI is not shipped by c11.
c3ceb55f5 | noise | Tests, CI, documentation, or revert housekeeping. added comment explaining fix
749d45490 | noise | Tests, CI, documentation, or revert housekeeping. fix swiftlint
5697db813 | na-feature | Upstream post-fork API is absent: renderer realized setter.
002fd4142 | na-feature | Upstream lib-vt export or imported graphics-state API is absent from the c11 embedder.
97777cf5a | noise | Enum casing, formatting, and corrected tests; no behavior change.
1e63834cd | verify | Previous search cannot underflow at wraparound. n/a-diverged.
d6494544c | noise | Tests, CI, documentation, or revert housekeeping. terminal: add panic test for integer overflow in selectPrev with no active matches
7837563ed | verify | Resize does not retain a cursor pin above active rows. n/a-diverged.
df789cd4b | verify | Cmd-click can send an unmatched mouse press to an agent TUI. shared-confirmed.
9f014e98b | verify | Cmd-click can send an unmatched mouse press to an agent TUI. shared-confirmed.
59fb750c0 | verify | Cmd-click can send an unmatched mouse press to an agent TUI. shared-confirmed.
5998abddd | verify | Cmd-click can send an unmatched mouse press to an agent TUI. shared-confirmed.
f24195271 | verify | Cmd-click can send an unmatched mouse press to an agent TUI. shared-confirmed.
76ead3eae | verify | Cmd-click can send an unmatched mouse press to an agent TUI. shared-confirmed.
d1dbbec9b | verify | Cmd-click can send an unmatched mouse press to an agent TUI. shared-confirmed.

## Counts

208 rows; na-feature 92; noise 40; done-round1 11; verify 65: confirmed 42, probable 10, already-fixed 2, n/a-diverged 11, skipped 0.

Grouped Verified entries: 48; confirmed 31, probable 8, already-fixed 1, n/a-diverged 8.

