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

If you resolve a conflict, update this doc with what changed.
