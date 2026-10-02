# Ghostty Fork Changes

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

The submodule now points to `Stage-11-Agentics/ghostty` (previously `manaflow-ai/ghostty`).
The Stage-11-Agentics fork is based on `bc9be90a` (the c11 theme-picker fork tip, section 7),
NOT on `manaflow-ai/ghostty` main. The PageList fix (section 8) is rebased on top of that tip.

## Fork update checklist

1) Make changes in `ghostty/`.
2) Commit and push to `Stage-11-Agentics/ghostty`.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Current fork changes

Fork rebased onto upstream `v1.3.0` plus newer `main` commits as of March 12, 2026.

### 1) OSC 99 (kitty) notification parser

- Commit: `a2252e7a9` (Add OSC 99 notification parser)
- Files:
  - `src/terminal/osc.zig`
  - `src/terminal/osc/parsers.zig`
  - `src/terminal/osc/parsers/kitty_notification.zig`
- Summary:
  - Adds a parser for kitty OSC 99 notifications and wires it into the OSC dispatcher.

### 2) macOS display link restart on display changes

- Commit: `c07e6c5a5` (macos: restart display link after display ID change)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Restarts the CVDisplayLink when `setMacOSDisplayID` updates the current CGDisplay.
  - Prevents a rare state where vsync is "running" but no callbacks arrive, which can look like a frozen surface until focus/occlusion changes.

### 3) Keyboard copy mode selection C API

- Commit: `a50579bd5` (Add C API for keyboard copy mode selection)
- Files:
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
- Summary:
  - Restores `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection`.
  - Keeps cmux keyboard copy mode working against the refreshed Ghostty base.

### 4) macOS resize stale-frame mitigation

Sections 3 and 4 are grouped by feature, not by commit order. The section 4 resize commits were
applied earlier than the section 3 copy-mode commit, but they are kept together here because they
touch the same stale-frame mitigation path and tend to conflict in the same files during rebases.

- Commits:
  - `769bbf7a9` (macos: reduce transient blank/scaled frames during resize)
  - `9efcdfdf8` (macos: keep top-left gravity for stale-frame replay)
- Files:
  - `pkg/macos/animation.zig`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/renderer/Metal.zig`
  - `src/renderer/generic.zig`
  - `src/renderer/metal/IOSurfaceLayer.zig`
- Summary:
  - Replays the last rendered frame during resize and keeps its geometry anchored correctly.
  - Reduces transient blank or scaled frames while a macOS window is being resized.

### 5) zsh prompt redraw markers use OSC 133 P

- Commit: `8ade43ce5` (zsh: use OSC 133 P for prompt redraws)
- Files:
  - `src/shell-integration/zsh/ghostty-integration`
- Summary:
  - Emits one `OSC 133;A` fresh-prompt mark for real prompt transitions.
  - Uses `OSC 133;P` markers for prompt redraws so async zsh themes do not look like extra prompt lines.

### 6) zsh Pure-style multiline prompt redraws

- Commits:
  - `0cf559581` (zsh: fix Pure-style multiline prompt redraws)
  - `312c7b23a` (zsh: avoid extra Pure continuation markers)
  - `404a3f175` (Fix Pure prompt redraw markers)
- Files:
  - `src/shell-integration/zsh/ghostty-integration`
- Summary:
  - Handles multiline prompts that use `\n%{\r%}` to return to column 0 before the visible prompt line.
  - Keeps redraw-safe prompt-start markers for async themes.
  - Avoids inserting an explicit continuation marker after Pure's hidden carriage return, because Ghostty already tracks the newline as prompt continuation and the extra marker duplicates the preprompt row.
  - Restores that prompt-marker behavior on top of the current Ghostty `main` base after the older redraw fix drifted out during later submodule updates.

The fork branch HEAD is now the section 6 zsh redraw follow-up commit.

### 7) c11 theme picker helper hooks

- Commit: `0c52c987b` (Add c11 theme picker helper hooks)
- Files:
  - `build.zig`
  - `src/cli/list_themes.zig`
  - `src/main_ghostty.zig`
- Summary:
  - Adds a `zig build cli-helper` step so c11 can bundle Ghostty's CLI helper binary on macOS.
  - Lets `+list-themes` switch into a c11-managed mode via env vars, writing the c11 theme override file and posting the existing c11 reload notification for live app-wide preview.
  - Fixes the helper-only `app-runtime=none` stdout path so the Ghostty CLI binary builds with the current Zig toolchain.

The fork branch HEAD is now the section 7 c11 theme picker helper commit.

### 8) PageList SIGSEGV race fix (Stage-11-Agentics fork)

- Commit: `c64952975` (terminal: snapshot page rows in SlidingWindow.Meta to fix SIGSEGV race)
  - Rebased from `f217fb0e6` onto `bc9be90a` (c11 theme-picker fork tip) to preserve the
    7 theme-picker commits that c11 requires. Cherry-picked cleanly with no conflicts.
- Files:
  - `src/terminal/search/sliding_window.zig`
  - `src/terminal/highlight.zig`
- Summary:
  - Snapshots the page row count in `SlidingWindow.Meta.rows` during `append()`, which is called
    under the terminal lock.
  - Prevents a cross-thread SIGSEGV that occurred when `resizeCols` freed page nodes concurrently
    with the search thread's `next()` call reading a now-freed page row count.
  - The `Meta` struct carries a `rows` field that freezes the count at the time the page is
    appended; `next()` reads `meta.rows` instead of the live page.
  - Adds `page_rows` to `FlattenedHighlight.Chunk` for reverse-search multi-chunk fixup.
  - Regression test added to `sliding_window.zig`.

### 9) Surface free-text C ABI alignment

- Commit: `d4431f804` (C11-212: match free-text export to C ABI)
- File:
  - `src/apprt/embedded.zig`
- Summary:
  - Adds the surface parameter declared by `ghostty.h` to the exported
    `ghostty_surface_free_text` function and continues to deinitialize the returned text buffer.
  - Matches the upstream two-parameter export exactly; this patch drops out on the next rebase onto
    a base that already has it.

### 10) Renderer skips updateFrame while occluded (upstream backport)

- Commit: `26c3e499e` (cherry-pick of upstream `14d9e600a`, "renderer: skip updateFrame when
  surface is not visible", 2026-05-20; upstream authorship preserved via `-x`)
- File:
  - `src/renderer/Thread.zig`
- Summary:
  - `renderCallback` returns early while `flags.visible == false`, so an occluded surface no
    longer rebuilds its cell state on every PTY write; only `drawFrame` was gated before.
  - The `.visible → true` mailbox handler runs `updateFrame` before `drawFrame`, so the first
    frame after a surface is shown again is current, not stale.
  - Why c11 wants it: with dozens of agent terminals in background tabs, the hidden renderers
    (utility QoS) were saturating the efficiency cores (C11-225).
  - Identical to upstream; this patch drops out on the next rebase onto a base that already has
    it (ghostty-org main since 2026-05-20, manaflow/cmux main since its July 2026 base).

## Upstreamed fork changes

### cursor-click-to-move respects OSC 133 click-to-move

- Was local in the fork as `10a585754`.
- Landed upstream as `bb646926f`, so it is no longer carried as a fork-only patch.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- `src/terminal/osc/parsers.zig`
  - Upstream uses `std.testing.refAllDecls(@This())` in `test {}`.
  - Ensure `iterm2` import stays, and keep `kitty_notification` import added by us.

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser.

- `src/shell-integration/zsh/ghostty-integration`
  - Prompt marker handling is easy to regress when upstream adjusts zsh redraw behavior. Keep the
    `OSC 133;A` vs `OSC 133;P` split intact for redraw-heavy themes. Pure-style `\n%{\r%}`
    prompt newlines should not get an extra explicit continuation marker after the hidden CR.

- `src/cli/list_themes.zig`
  - c11 relies on the upstream picker UI plus local env-driven hooks for live preview and restore.
    The hooks read `CMUX_THEME_PICKER_COLOR_SCHEME`, `CMUX_THEME_PICKER_INITIAL_LIGHT`, and
    `CMUX_THEME_PICKER_INITIAL_DARK` (set by c11 before calling `ghostty +list-themes`).
    If upstream reorganizes the preview loop or key handling, re-check the c11 mode path and keep the
    stock Ghostty behavior unchanged when the c11 env vars are absent.
  - **Upstream-sync note:** when syncing to a newer upstream Ghostty, the 7 theme-picker commits
    from section 7 (base: `bc9be90a`) will need to be re-applied on top of the new upstream tip.
    Cherry-pick them in order from oldest to newest: `116c7af24` through `bc9be90a2`. Conflicts
    are likely only in `src/cli/list_themes.zig` around the preview loop and key-handling paths.

- `src/terminal/search/sliding_window.zig`
  - The `Meta` struct has a `rows: usize` field added by the PageList SIGSEGV fix (section 8).
    Any upstream change to `SlidingWindow` or `SlidingWindow.Meta` must preserve this field.
    The field is populated in `append()` under the terminal lock; do not move the assignment outside
    that lock boundary.

- `src/apprt/embedded.zig`
  - The `ghostty_surface_free_text` export in section 9 is identical to upstream and should be
    dropped when rebasing onto a base that already has the two-parameter form.

- `src/renderer/Thread.zig`
  - The visibility gate in `renderCallback` and the `updateFrame` on visibility regain (section 10)
    are identical to upstream `14d9e600a` and should be dropped when rebasing onto a base that
    already has them.

If you resolve a conflict, update this doc with what changed.

### 11) C11-294 terminal patch set

The engine tip is `5830d1976` on the Stage 11 fork's `main`. The parent
gitlink refers to that published commit. Product validation and parent PR state
are tracked on C11-294; this section records the engine integration.

- Surface teardown publishes cancellation before search, renderer, or IO joins.
  Worker mailbox backpressure retries in 50 ms intervals and can abort for its
  owning surface. The shared app queue stays open for other surfaces. Main-thread
  ordered publications use a FIFO spill on saturation; focus and visibility use
  independent atomic latest-value slots. App and renderer drains process a
  snapshot of their starting count and retain a wake for any remaining work.
  The ring deliberately remains 64 slots rather than taking H-A's proposed
  mailbox enlargement: cancellation breaks the join cycle, and the unchanged
  capacity keeps the saturation fixture meaningful.
- Paste fences and payload enter IO as one owned message (`f27772d10963`). Write
  request and buffer ownership travel together through out-of-order completion
  (`e0ef934f7360`). Selection replacement no longer compares released pins
  (`ab82b8ab720c`).
- Shutdown uses a monotonic grace/escalation budget and separately accounts for
  the direct child and freshly PTY-attributed foreground group. It never targets
  the host process group, invalid IDs, or a cached group after child reaping.
  Detached/disowned processes no longer attributable to the PTY are kept.
  Defaults: 12 s HUP grace, a verified HUP-ignoring Darwin leader gets 250 ms TERM
  grace, then at most 3 s KILL/reaping. The TERM signal is actually delivered
  before its grace interval expires. Cancellation joins the reader before the
  owned PTY master closes, allowing macOS login to observe hangup. Shutdown is
  idempotent so IO thread exit and final deinit share one signal/reap budget.
  Cancelled POSIX teardown transfers copied process IDs and timeout values to
  a detached reaper, so the IO join does not park main for that budget. No
  surface, command, or PTY storage escapes. Synchronous helpers remain for
  startup cleanup and tests; a thread-spawn failure is logged and falls back
  to bounded synchronous cleanup rather than abandoning a waitable child.
- Two additive C exports, `ghostty_surface_try_read_text` and
  `ghostty_surface_try_read_selection`, attempt the renderer mutex once. Statuses
  are OK=0, BUSY=1, INVALID_SELECTION=2, FAILED=3, NO_SELECTION=4. Non-OK results
  are zero and transfer no allocation. Successful buffers use the existing
  two-argument free-text export. Native formatting still runs synchronously on
  the app thread after acquisition and has no wall-time bound.
- B034 grapheme edge wrapping (`3ba49a784f43`) and B045 null CoreText display names
  (`ff362c99c0a2`) cherry-picked cleanly. B021, B015, B020, B036 and B037/B166
  conflict with this base and are omitted under the ticket's clean-only rule.
  B021's standalone reader change is not claimed fixed by the required reaper
  changes. C11-200 display-ID publication stays unchanged.

Bounded-turn/lifecycle adaptation sources: `188d31a97733`, `2258bea96ddc`,
`ca21db1bb836` (austinpower1258). Shutdown sources: `5b20c62297ac`,
`88c3325dc969`, `81b4de4f540e`, `47e9bd4c90de`, `bc7e9f7466f4`,
`01e7c93ca9e4` (austinpower1258/Austin Wang). The paired write-pool source is
Mitchell Hashimoto's `e0ef934f7360`. Clean cherry-picks preserve author metadata
and record the source with `-x`; adapted commits retain source/author credit.

The test-only engine library is built with `-Dc11-read-test=true`; production
builds do not include its fixture controls. `tests/ghostty_patchset/` in the
parent contains the real-PTY teardown host and pinned-libxev backpressure probe.
The B072 probe distinguishes ordinary saturation from a synthetic competing
writer: only the latter has reproduced WouldBlock and a dropped 64-byte request
on the pinned backend. That result does not claim production c11 byte loss.
B072 therefore carries only the queued-write retry patch (`2f6ee7b3`, Austin
Wang) in a reproducible archive of the original libxev revision. The dependency
URL pins fork artifact commit `b6b0522c9`; `vendor/libxev-c11/VENDORED.md` in
Ghostty records source, patch, archive checksum, and reproduction commands. Both
ordinary and synthetic-race probes preserve all bytes with the patched archive.

Rebase conflicts to preserve: cancellation must precede the first join; cancelled
owned messages must be disposed; final search resets follow already-queued
results; renderer resources are released before pending font-key ownership;
IO config handling appends its color report without waiting on its own queue.
This changes no Swift callback executor and does not close B033. The original
teardown repair is relevant upstream; offering it upstream is not a 1.0 gate.
