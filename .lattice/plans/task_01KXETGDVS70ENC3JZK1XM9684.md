# C11-173 — `c11 send` silently never submits

## Where the bugs live (read from source on main)

`c11 send` → `surface.send_text` → `TerminalController.v2SurfaceSendText`
(Sources/SocketHandlers/SurfaceHandlers.swift:825).

1. **Submit Return is dropped whenever the target pane is not in a window.**
   The submit path is `scheduleSubmitReturnAfterPasteDelay()` →
   `TerminalSurface.sendKey(.returnKey)` → `sendSyntheticKey(...)`, and that
   function opens with `guard let window = view.window else { return }`
   (Sources/GhosttyTerminalView.swift:3861). It fabricates an `NSEvent`, which
   needs a window number. Panes in a **background workspace** are portal-detached
   — `view.window` is nil — so the Return is silently discarded. The text lands
   (that path is `ghostty_surface_key`, window-independent); the submit does not.
   This is the fleet case: every agent lives in its own workspace, only one is
   on screen, so every `send` to a background agent types and never submits.

2. **The payload is typed as a burst of synthetic key events, not a paste.**
   `sendSocketText` (TerminalController.swift:6363) splits the text and emits
   `ghostty_surface_key` events, with each embedded `\n` becoming a Return key
   event. No bracketed-paste markers. A paste-detecting TUI (Claude Code, codex)
   applies a *timing* heuristic to that burst, renders `[Pasted text #1 +N lines]`,
   and can absorb a Return that arrives inside its coalescing window. Nothing about
   the submit is deterministic.

3. **`send-key space` emits nothing.** `sendNamedKey` sends a keycode with
   `text = nil`. Ghostty's legacy encoder only emits printable keys from the
   event's UTF-8 text (`src/input/key_encode.zig`), so `space` (and any other
   printable named key) writes zero bytes to the PTY. Non-printable keys
   (enter, arrows, ctrl-*) do encode from the keycode alone.

4. **Empty `--surface ""` routes to the caller.** CLI guard is
   `guard sfArg != nil || env[...] != nil` (CLI/c11.swift:2487, 2508) — an empty
   string is non-nil, so it passes. `normalizeSurfaceHandle` then trims it to
   empty and returns nil, so the CLI omits `surface_id`, and the server's
   `resolveSurfaceSendTargets` falls back to `ws.focusedPanelId`
   (TerminalController.swift:2997) — with the workspace defaulted from the
   *caller's* `C11_WORKSPACE_ID`. Same silent misroute happens for an unresolvable
   ref (`v2UUID` returns nil → focused-panel fallback).

## Fix

- **Submit through the window-independent path.** Add a
  `TerminalSurface.sendSubmitReturn()` that goes to `ghostty_surface_key`
  (the same primitive `send-key enter` uses) instead of the NSEvent path, and
  use it from the socket send path. Keep the NSEvent path for TextBox (real
  first-responder routing).
- **Write the payload as a real bracketed paste** (`ghostty_surface_text`) in the
  socket send path when submitting, so the TUI sees an explicit paste end
  (`ESC[201~`) rather than guessing from timing, then submit with the separate
  Return after the paste-settle delay.
- **`send-key`: give printable named keys their text** so `space` actually emits.
- **Reject empty refs, don't misroute:**
  - CLI: an explicitly-passed empty/whitespace `--surface`/`--panel` is an error,
    and an empty env var counts as unset.
  - Server: if `surface_id` is present but unresolvable, return `not_found` instead
    of silently falling back to the focused panel.
- **Make OK honest:** the send response reports what actually happened
  (`submitted: true|false`), and `c11 send --verify` polls the target and fails
  loudly if the text is still sitting in the composer.

## Validation (the bar for this ticket)

Baseline first: reproduce on a tagged build of unmodified `main` —
`send` a multi-line payload to a live Claude Code pane in a **background**
workspace and watch it sit unsent. Then re-run against the fixed build and
confirm it becomes a turn (transcript/token counter moves), not merely `OK`.

Regression tests (`tests_v2/`, driven against a tagged build's socket):
- multi-line send to a background-workspace surface executes (fails on main today)
- `send-key space` echoes a space (fails on main today)
- `send --surface ""` exits non-zero and does not touch the caller's pane
- `send --surface <stale-ref>` errors instead of hitting the focused pane
