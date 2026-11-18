# Ghostty Fork Changes

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

The submodule now points to `Stage-11-Agentics/ghostty` (previously `manaflow-ai/ghostty`).
The Stage-11-Agentics fork is based on `bc9be90a` (the c11 theme-picker fork tip, section 7),
NOT on `manaflow-ai/ghostty` main. The PageList fix (section 8) is rebased on top of that tip.

## Fork update checklist

1) Make changes in `ghostty/`.
   A new or changed C API goes in both `ghostty/include/ghostty.h` and c11's repo-root
   `ghostty.h` (the copy the bridging header imports); with only the first, the app build
   fails with "cannot find ... in scope".
2) Commit and push to `Stage-11-Agentics/ghostty`.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Kitty graphics: a per-surface direct-only switch (C11H-363)

Branch `c11h/C11H-363-kitty-direct-only`, one commit on `cfdf3dce0` (`c11h/C11H-133-prefix-map-v2`),
adds `ghostty_surface_config_s.kitty_graphics_direct_only` (appended last, off by default). With it
on, a Kitty graphics query, or the first chunk of a transmit or transmit-and-display, whose medium
is a file (`t=f`), a temporary file (`t=t`) or shared memory (`t=s`) is answered
`EINVAL: unsupported medium` before `LoadingImage.init`: no path is resolved, opened, read or
unlinked, and the reply carries only the command's own `i`, `I` and `p`, so it is the same for every
path. Continuation chunks are data, never paths. Direct (`t=d`) images load as before.

The value is copied onto `Terminal.kitty_graphics_direct_only` in `Surface.init`, after Termio init
and before the IO thread starts or any embedder output is processed. It is a top-level `Terminal`
field, not part of `flags`, so a full reset (`ESC c`) does not clear it. `newSurfaceOptions` carries
it to inherited configs.

Why: c11 feeds every hc terminal's output to Ghostty with `ghostty_surface_process_output`, and the
replies go back as that program's input. For a terminal on another machine, path media let that
machine test whether any path exists on this Mac and learn a readable file's exact size, block the
output lane on a FIFO, force large reads, or unlink temp-folder files and shared-memory objects.
c11 sets the switch on every hc (manual-IO) surface (`HCSurfaceNativeIO`); exec surfaces keep
Ghostty's behaviour.

The `kitty path media` tests cover an existing and a missing `t=f` path giving one reply (and
different replies with the switch off), a `t=t` file under the temp folder that is refused and still
exists afterwards, `t=f` and `t=s` transmits that store nothing, a direct image that still loads, and
a full reset that keeps the switch. The admitted kit builder verifies that removing the guard fails
them. On a future upstream sync keep the field and both call sites in `graphics_exec.zig`.
Admitted kit gate `9270d2eee5174c5ab1c2feaa16aad6b1` (build host, 81 native tests, every mutation red,
`kitty-direct-only` among them); fork commit `d5de3713a13ac65386a0a86ec033a85563e713cb`, archive SHA256
`f68b76312fd0dabcbd1307358574ae7b888b23f351d8ac85c2244bf2e67046b0`, also in
`scripts/ghosttykit-checksums.txt`.

## Highway's file path carries no builder home

Branch `c11h/C11H-133-prefix-map-v2` at `cfdf3dce00247effdac0764db88797fe315d8d10`, one commit on
`ae28413c9` (`c11h/C11H-325-hyperlink-at`), adds `-ffile-prefix-map=<package root>=highway` to the
C++ flags of the upstream highway sources in `pkg/highway/build.zig`. `HWY_ABORT` bakes `__FILE__`
into the binary, and the package sits in the zig global cache under the builder's home, so a release
carried that path. The shipped string is now `highway/hwy/targets.cc`. The same commit first sat on
`8f851996b` as `c11h/C11H-133-prefix-map` (`34adc0154`); that branch stays. On a future sync, keep the
flag unless upstream drops `__FILE__`.
Admitted kit gate `ded3b5d034a64f01a18ce6a8f0a6319f` (build host, 76 native tests, every mutation red);
archive SHA256 `e4010b4d84df4b3681c6f15ac20b8ea33fe4250b905fc95a9da43b597bff2ef7`, also in
`scripts/ghosttykit-checksums.txt`.

## Hyperlink lookup under a point (C11H-325)

Branch `c11h/C11H-325-hyperlink-at` at `ae28413c99bfa03dd8472d36df12ccf29b806743`, one commit on
`8f851996b` (`c11h/C11H-255-ff`), adds `ghostty_surface_hyperlink_at(surface, x, y, buf, cap)`.
It returns the byte length of the OSC 8 URI on the cell under a view position (the same unscaled
coordinates as `ghostty_surface_mouse_pos`; 0 for no link or a negative coordinate) and copies at
most `cap` bytes, so a return above `cap` means truncated; a null buffer only measures. A point past
the grid's right or bottom edge (the padding) reads the edge cell, as Ghostty's own `linkAtPos` and
the mouse reports it sends the program do; the fork commit's doc comments still say "outside the
viewport" and are corrected with its next change. It takes the
renderer mutex, changes no link, selection or mouse state and reports nothing to the program.

Why: Ghostty resolves link hover and link clicks only while it is not reporting the mouse (or
Shift releases the grab). With a program holding the mouse (Claude Code fullscreen), c11 reads the
cell's target itself so a plain or Cmd click on a c11 link reaches c11 (`CapturedPanelLinkClick`).

The `hyperlink at viewport` test covers hit, miss, link end, a second row, rows and columns
outside the viewport, truncation and measuring. The admitted kit builder verifies that reporting
no link, or the truncated length, fails it. On a future sync keep the function; upstream has no
equivalent query.
Admitted kit gate `8ea6fc305f284a6f9192e02106d166c7` (build host, 76 native tests, both mutations red);
archive SHA256 `98b34e0f877f0352e5576d29de9d5b1556462747363878289d83197f09a63e49`, also in
`scripts/ghosttykit-checksums.txt`.

## Surface creation does not wait for glyph-cache writers

Branch `c11/surface-lock` at `e54aa97945d0e595e0f6a4707688a37963c07a04` removes the shared font-grid lock from
renderer initialization's metrics copy. `SharedGrid` metrics are immutable after
initialization, and `Surface.init` already owns a grid-set reference. This matches
`setFontGrid`, which already reads metrics without acquiring the glyph-cache lock.
Surface creation remains on the main thread; no attachment or input lifecycle changes.

The `surface creation metrics` regression holds the grid's writer lock while
calling the production initialization helper. Completion must occur before the
writer is released. The admitted kit builder verifies that restoring the old
shared lock fails this test, then restores the source and runs the green suite.
Guest creation timings and rendered first-output evidence are recorded separately.
The additive `ghostty_surface_font_size` C API returns the main-thread surface's
requested font points, independently of pending renderer work or display scale.
Creation inheritance uses it instead of reading a quicklook font face under the
grid lock. It accepts a live surface on the app thread and returns zero for null.
The native test exercises the production scalar helper under a held writer; injecting a
shared lock must fail before the green suite runs. The Debug creation diagnostic
also avoids quicklook. Existing APIs and struct layouts are unchanged.

On a future sync, preserve both lock-free reads unless upstream removes the same
contention. The test-only guest fixture is not in the shipping commit.

## Additive manual-input and loaded-config APIs

The c11 integration pins `216418f4afe8e1caf0c0d91b7365f55c339a87cc` on
`c11/synchronous-input-encode`, based on `1fe92fa804821088cd01931fa0c47c0bfc16f6bd`.
This branch is reviewed separately before pushing to `stage11`; the fork's
`main` and classic c11's pointer remain unchanged.

- `3129307c5fc52260c327b7d984119521f99cd3e1` adds
  `ghostty_surface_encode_paste`. Manual surfaces can synchronously capture
  canonical paste bytes and a separate unmodified Return without transmitting.
  It snapshots terminal modes under the existing mutex, then unlocks before
  encoding and calling back. Buffers are borrowed only during the callback;
  false means no callback and no transmission. Existing input APIs are unchanged.
- `21027b804712820d1e2155577a7c82636d1ad796` adds
  `ghostty_config_visit_launch`. It visits loaded command/shell or ordered argv
  and explicit config env entries, without reading process environment or
  mutating configuration. Strings are borrowed only during each synchronous
  callback. Both callbacks are required. Existing layouts and APIs are unchanged.
- `cf8ccb9c14fa5bdc2eee10be8d6ef4757b83c3c7` adds
  `ghostty_clipboard_request_get_type`. It reads the kind of a borrowed live
  clipboard request before completion. Null arguments return false without
  changing the output; the function does not consume or mutate the request.
  This lets an embedder distinguish paste from OSC 52 reads while preserving
  the existing completion path and every existing struct layout.

- `a4bea3aef680b5a92d3e5b33aac00b70fabe4929` adds
  `ghostty_config_visit_launch_fields`. It visits only loaded working-directory
  and term, read-only, with bytes borrowed during the synchronous callback.
  Null arguments refuse before visitation. It reads no process environment.

- `216418f4afe8e1caf0c0d91b7365f55c339a87cc` adds
  `ghostty_surface_encode_key`. Manual surfaces synchronously capture canonical
  key bytes and an optional paired release, using one terminal-mode snapshot.
  Modifier remaps and Option-as-Alt configuration are read without changing
  key state. No bindings, selection changes or IO run; the callback borrows
  bytes outside the terminal lock. Existing key APIs are unchanged.

All changed Zig files pass `zig fmt --check`; the C header passes syntax checks.
Admitted native gate `4ae2d44c2153424d956c1739ebf8bff7` ran all five new filters
(73 tests passed) and built the universal kit. Clipboard null-output,
launch-fields null-callback and key-release mutations failed their behavioral
tests before restoration and the green run. Archive SHA256:
`13bc9478f9ce52679692b5a920bc3d90e21f21e9eab7b74677c6594089cfc560`, also in
`scripts/ghosttykit-checksums.txt`. This proves native unit tests and packaging;
app integration and guest input proofs remain separate. Commits 3–5 await one
combined review and push authorization; the first two are published.
No existing behavior or ABI layout changed. The fork main and classic c11's
pointer remain unchanged.

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

### 12) C11-267 bounded styled prompt-region capture

- Commit: `e6999ae7adc7c584d6bbda415aa59a6a8c3a2470`
- Files: `include/ghostty.h`, `src/apprt/embedded.zig`,
  `src/terminal/prompt_region.zig`
- Adds `ghostty_surface_try_read_prompt_region`, a one-shot renderer-lock
  acquisition that copies only the active screen into caller-owned buffers:
  at most 16 rows, 4096 cells, and 16 KiB of UTF-8 text. Rows preserve hard and
  soft wraps; cells retain faint style. A clipped copy is marked incomplete.
  It reads no viewport or scrollback, allocates no text, and introduces no
  colors. Swift captures on the app thread while the surface is live, then
  classifies the bounded snapshot off the socket worker.
- On rebase, preserve the C struct layout and limits with the matching Swift
  importer, plus the one-shot mutex try-lock. Do not turn incomplete captures
  into an empty prompt.

### 13) C11-406 italic cells in the prompt-region capture

- Commits: `d05a1fa7b` (keep SGR-3 italic per cell), `066c8bf2f` (run the
  prompt-region tests with the terminal suite), `805714c6f` (replay Grok's
  recorded suggestion bytes in a test)
- Files: `include/ghostty.h`, `src/terminal/prompt_region.zig`,
  `src/terminal/main.zig`
- `ghostty_prompt_region_cell_s` gains `bool italic` after `faint`. Grok
  draws its next-prompt suggestion SGR 3 italic in a truecolor grey, never
  SGR 2, so c11's reader needs italic to tell the suggestion from typed text.
  The capture still copies no colors and stays within the same bounds.
- `src/terminal/main.zig` imports `prompt_region.zig` in its test block. The
  file was only imported from the embedded apprt, so its tests never ran.
- On rebase, keep the field order (`text_offset`, `text_len`, `faint`,
  `italic`) the same in three places: the submodule's `include/ghostty.h`,
  c11's repo-root `ghostty.h` (the copy the bridging header imports), and
  the Swift importer in `TerminalController.swift`.

### 14) C11-414 truecolor cells and a bottom-anchored prompt-region read

- Commit: `ed0a968cc059ba9249cc6887bbb54e8363fc619b`
- Files: `include/ghostty.h`, `src/apprt/embedded.zig`,
  `src/terminal/prompt_region.zig`
- `ghostty_prompt_region_cell_s` gains `bool fg_rgb_set`, `bool bg_rgb_set`,
  `uint32_t fg_rgb`, `uint32_t bg_rgb` after `italic` (0x00RRGGBB, explicit
  SGR 38;2 / 48;2 only; palette and default colors stay unresolved and read
  unset). A bg-only cell reports its truecolor background. Grok draws its
  unfocused composer's `Build anything` placeholder and an unfocused typed
  draft with the same text and no faint or italic bit; only the grey differs.
- Adds `ghostty_surface_try_read_prompt_region_bottom`: the same one-shot
  try-lock and limits, scanning bottom-up from at most the last 16 rows of the
  active screen. The cell and text budgets can leave a shorter bottom suffix;
  if a partial row above that suffix is discarded, the retained rows remain
  complete. The result still reports the live cursor. Grok parks its hidden
  cursor far above the composer after a hover, outside the cursor window.
- On rebase, keep the cell field order (`text_offset`, `text_len`, `faint`,
  `italic`, `fg_rgb_set`, `bg_rgb_set`, `fg_rgb`, `bg_rgb`) the same in the
  submodule header, c11's repo-root `ghostty.h`, the Zig `extern struct`, and
  `PromptRegionNativeImport` in `TerminalController.swift`.

### 15) C11-453 preserve wide Grok composer rows within the bottom-read budget

- Commits: `c796bbe58` (test wide bottom prompt capture), `8c44ef421`
  (preserve bottom prompt rows within capture budget), and `1b7bcf06b`
  (keep a discarded partial bottom row out of completeness)
- File: `src/terminal/prompt_region.zig`
- The regression test covers a wide Grok panel whose lower composer rows must
  survive the bounded read. The bottom-up scan keeps the fully captured bottom
  suffix when the cell or text budget clips a row above it; that discarded
  partial row does not make the retained suffix incomplete. If the first row
  itself cannot be captured fully, the result remains incomplete.
- On rebase, preserve the bottom-up row order, the per-row cell offsets, and
  the saved completeness state when discarding a partial row.

### 16) C11-525 recognize c11 terminal URLs

- Commit: `1fe92fa804821088cd01931fa0c47c0bfc16f6bd`
- File: `src/config/url.zig`
- Adds `c11://` to the existing URL-scheme matcher in c11's embedded fork.
  Bare panel and workspace UUID links now use the same Cmd-hover and Cmd-click
  path as other terminal URLs. No tenant configuration is written or changed.
- Regression cases cover both target kinds, Codex's `title (c11://...)` output,
  and Markdown links followed by punctuation. The existing `link-url` preference
  is respected. c11 forces `link-previews = true` in its runtime configuration
  so internal-link hover can show the true destination. Regex-matched links
  emit `mouse_over_link` when previews are enabled; OSC 8 links already supply
  their destination URI through that action.
- This engine patch adds detection only. Native navigation and destination
  previews belong to the c11 host's C11-525 routing slice, using C11-515's router.
- On rebase, preserve the `c11://` scheme alternative and its token-boundary
  regression cases. Do not broaden matching to arbitrary schemes.
