# C11-286: Add resize-window that keeps the top-left and does not focus

## Release
P2. This ships in its own PR and never holds 1.0. If it slips, computer-use keeps sizing the window by hand. The ticket says a human can resize until this command exists. Nothing else in the release calls `window.resize`.

It is independent of C11-285. That ticket is a CLI transport. This one is one `setFrame` on a window the caller named. No shared hunk.

The supported form is c11 resize-window --window <id> <width> <height>. --window is command-local, after the verb; do not read the global windowId in this arm or change the C11-283 prelude. In the binding queue C11-283 has already removed the intake-base prelude before this P2 implementation starts.

C11-284 lands first. If this P2 ticket is admitted, add/enable window.resize in Sources/CapabilityFeatures.swift in the same implementation PR; window dispatch and method advertisement use that typed entry. On the tagged artifact the flag and actual resize/no-focus behavior must agree; omitted P2 work advertises neither method nor feature (audit finding 8). The methods list in `v2Capabilities` is separate and is added here, because the socket method has to be advertised by the binary that implements it.

## Incident
Computer-use runs are not comparable when each one starts from a hand-resized window. Backlog C7. Upstream cmux #9826 (`2fd3c403cb`) keeps the top-left fixed, clamps to `minSize`, and treats `- -` as a read. Base `0ff8887e5e`.

## What is already true
`v2DispatchWindow` (`Sources/SocketHandlers/WindowHandlers.swift:15-29`) handles `window.list`, `window.current`, `window.focus`, `window.create`, and `window.close`. No resize. `v2Capabilities` lists those five (`SystemHandlers.swift:61-65`). `window.list` does not include a frame (`WindowHandlers.swift:32-46`).

`window.focus` is in `focusIntentV2Methods` (`TerminalController.swift:252-267`). A resize must not be added there. `focusMainWindow` (`AppDelegate.swift:6128-6141`) orders the window front. This command does not call it, and does not call `NSApp.activate`.

`v2MainSync` runs the body inline on the main thread (`TerminalController.swift:2424-2428`). `window.*` is not in `socketWorkerV2Methods`, so `processV2Command` is already on main (`SocketDispatch.swift:997`). One `setFrame` there does not take a semaphore and does not hop.

`v2UUID` accepts a UUID or a live `window:N` ref (`TerminalController.swift:2705-2710`). Unknown id is the same `not_found` shape as `v2WindowFocus` (`WindowHandlers.swift:67-75`).

AppKit's `frame.origin` is the bottom-left. Keeping that origin and growing the height moves the top. Keeping the top-left means:

```text
newOrigin.x = oldOrigin.x
newOrigin.y = (oldOrigin.y + oldHeight) - newHeight
```

`window.minSize` is the clamp floor. The screen clamp is `window.screen?.visibleFrame`, the screen the window is already on. There is no resize helper to reuse. Session restore's `clampFrame` recenters (`AppDelegate.swift:4024-4060`). Do not call it.

## Change
Pure `WindowResizePlan.decide` in `Sources/WindowResizePlan.swift`. Inputs are the current frame, optional requested width, optional requested height, `minSize`, and an optional visible frame. Output is the new frame, `clamped`, and `write`.

- `nil` width keeps the current width. `nil` height keeps the current height. Both nil is the read: `write` is false, the frame is copied, `clamped` is false. The caller must not call `setFrame`.
- A number is clamped up to `minSize` and down to the visible frame's width or height, and never below `minSize`. If `minSize` is larger than the screen, applied is `minSize` and `clamped` is true.
- `clamped` is true only when a requested number differs from the applied edge. A kept edge does not set it.
- Origin x stays. Origin y moves only so the top edge stays. Do not slide the window back onto the screen. Do not move it to another screen.
- No visible frame (the window has no screen): clamp to `minSize` only.

`AppDelegate.resizeMainWindow(windowId:width:height:)` looks up `windowForMainWindowId`. Nil window returns nil. The handler then returns `not_found` and does not read or write the key window.

If `styleMask` contains `.fullScreen`, return `invalid_state` and do not call `toggleFullScreen` or `setFrame`. Fullscreen enter and exit are out of this ticket.

Otherwise one `setFrame(_:display:animate:)` with `display: true` and `animate: false`, and only when `write` is true. Do not register for `NSWindow.didResizeNotification`. AppKit may post one. Do not add a handler, and do not loop.

`window.resize` in `v2DispatchWindow`, next to `window.close`. Params `window_id`, and `width` / `height` as numbers or absent. A bool, string or non-finite number is invalid_params (the CLI never sends -); validate before AppKit math. Numeric requested edges are clamped by the pure helper as described. Not in `focusIntentV2Methods`. Not in `socketWorkerV2Methods`.

Response:

- `window_id`, `window_ref`
- `requested.width` and `requested.height`, null when that edge was kept
- `applied.width`, `applied.height` (the window frame, including the title bar, not a pane)
- `origin` AppKit bottom-left after the call
- `top_left` `{x, y}` with `y = origin.y + height`, so a caller can see that the top edge did not move
- `clamped`, `changed` (`changed` is false on a read)

`v2Capabilities` gains `"window.resize"` beside `"window.close"`.

CLI `resize-window`. Required: command-local `--window`, then two positionals. Each positional is `-` or a finite number. Anything else is a usage error before `sendV2`. Convert `-` to an absent param. `rejectEmptyTargetFlags` on `--window`. Resolve the id with `normalizeWindowHandle` (`:5103`). Send `window.resize`. Print the JSON. Do not call `window.focus`.

Help in `subcommandUsage` and one usage line beside `focus-window` (`:17896`).

## Files
- `Sources/WindowResizePlan.swift`. App phase `A5001051` only. Hand-edit `project.pbxproj`. Do not use the xcodeproj gem.
- `Sources/AppDelegate.swift` — `resizeMainWindow` only. Not `focusMainWindow`. Not `clampFrame`.
- `Sources/SocketHandlers/WindowHandlers.swift` — one case and the handler.
- `Sources/SocketHandlers/SystemHandlers.swift` — one string in the methods array.
- Sources/CapabilityFeatures.swift — enabled window.resize used in dispatch and capability method advertisement.
- `Sources/TerminalController.swift` — no edit. Do not add the method to `focusIntentV2Methods`.
- `CLI/c11.swift` — the arm, help, usage. Not the prelude.
- `c11Tests/WindowResizePlanTests.swift` in c11LogicTests phase `37DDE3B0A6A70E75A7B2BEDF`.
- `tests_v2/test_resize_window.py`.
- `skills/c11-computer-use/SKILL.md` — one short paragraph. Not `skills/c11/SKILL.md` and not `skills/c11/references/api.md`.

## Tests
`WindowResizePlan`, incident named (a later computer-use run could not match a hand-sized window, cmux #9826):

- Frame origin `(100, 100)`, size `800×600`. Request `1200×800`. minSize `400×300`. Visible `2000×1200`. Applied `1200×800`, origin x `100`, top y stays `700`, `clamped` false, `write` true.
- Request `100×100` against that minSize. Applied `480×360` if those are the mins under test, `clamped` true, top y still `700`.
- Request width `5000` against a visible width of `1440`. Applied width `1440`, x unchanged, `clamped` true.
- Both nil. `write` false, frame unchanged, `clamped` false.
- Width nil, height `900`. Width stays `800`. Top y stays. `clamped` false when `900` fits.

No `NSWindow` in the logic test. No source-grep test.

## Acceptance
Tagged build in the remote build host sandbox (`scripts/sandbox-tests-v2.sh`), not the operator's c11. The test opens a second window, focuses the first with `focus-window`, then resizes the second. It closes the second window before it exits. No soak.

1. Record `top_left` from `c11 resize-window --window <id> - -`. Then `c11 resize-window --window <id> 1200 800`. `top_left` is unchanged. The frame is `1200×800`, or `clamped` is true and the frame equals `applied`.
2. `c11 resize-window --window <id> - -` prints the current width and height. A second read returns the same origin, size, and `changed: false`.
3. A request smaller than `minSize` returns `clamped: true`, does not throw, and `applied` matches the frame.
4. `window.list` shows the same `key: true` window before and after the resize of the other window.
5. `c11 resize-window --window <random-uuid> 1200 800` is `not_found`. The key window's following `- -` read matches the read from before the failed call.
6. A fullscreen window, if the sandbox has one, returns `invalid_state` and is still fullscreen. Skip this assertion if the guest has no fullscreen window. Do not enter fullscreen to create one.

## Skill
In `skills/c11-computer-use/SKILL.md`, one paragraph under the socket-oracle section: a maintainer can set a tagged window's frame with `c11 resize-window --window <id> <width> <height>` so two runs share a size. `-` keeps an edge. `- -` reads. The top-left stays. The command does not focus. Put the window back, or close the extra window, before the run ends. It is not a daily operator command. Do not add it to `skills/c11/SKILL.md`.

`c11-computer-use` is installable (`skills/MANIFEST.json`). After the edit, on the landing machine, `scripts/sync-installed-skills.sh c11-computer-use`. Planning mode does not run it. The reviewer reads the repo skill and `~/.claude/skills/c11-computer-use/SKILL.md`, and checks that `.c11-skill.json` is still present.

## Hot path
None. One `setFrame` on an explicit command. Do not touch `hitTest`, `forceRefresh`, or the scroll `didUpdate` observer.

## Strings
English only. C11-291 translates. `%@` must survive.

- `cli.resize_window.usage` = "resize-window requires --window <id> <width> <height>. Use - to keep an edge."
- `cli.resize_window.bad_size` = "'%@' is not a width or height. Pass a number or -."

The socket errors `not_found`, `invalid_params`, and `invalid_state` use `String(localized:defaultValue:)` at the handler, same as a new user-facing message.

- `socket.error.window_fullscreen` = "That window is fullscreen. resize-window does not enter or leave fullscreen."

Localize all new call sites even when matching neighboring English wording. List keys explicitly for C11-291:
- socket.error.window_not_found = "Window not found" (reuse an existing equivalent catalog key if present at implementation).
- socket.error.window_resize_params = "Width and height must be finite numbers."
No rewrite of neighboring handlers just to localize them.

## Cut
No `c11 rpc`. No moving a window between screens. No fullscreen toggle. No key-window change. No per-area layout. No computer-use runner. No frame field on `window.list`. No `didResize` observer. No tenant config. No soak.

## Dependencies
C11-284 merges first; C11-283 is already integrated by this seat's binding queue order. C11-285 remains a different optional PR; neither P2 ticket gates the other or the release.

## Branch
Build mode, from `origin/main`: `c11-1.0/C11-286-resize-window`.

## Decisions
None. Refusing fullscreen, instead of leaving it, is how the command stays out of fullscreen enter and exit.

## Codex takeover verification
Owner: agent:codex-cli. Verified ticket, stored plan and cited code on intake origin/main 0ff8887e5e965400b01645ef40b85fd0b2605cf2. All behavioral checks above are planned, unperformed. Planning hold remains: no builds, tests, product-code commits or pushes until explicit BUILD MODE. Branch from current origin/main when this ticket starts, retaining predecessor merges and previous local commits.

## Implementation intake correction (2026-10-02)

Owner is agent:codex-fixtures, admitted by the Orchestrator on main 1334615d98. C11-284 is integrated; C11-283 has not landed yet. Keep the global routing prelude untouched: resize-window requires command-local --window and rejects a global --window before discovery/connection, so the older prelude cannot focus on this command. Validate finite dimensions before discovery as well. Add localized socket.error.window_id = "Missing or invalid window_id" for the new handler. Installed skill refresh belongs only to the Merge Captain after merge; owners edit source only.

## Reset 2026-10-02 by agent:luna-286
