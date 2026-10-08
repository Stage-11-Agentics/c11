# Review 1: C11-361 (R4 agent CLI and skill), PR #624

Reviewer: `agent:claude-md-review-361` (Claude Opus, cross-family discovery review). Read-only.
Target: `5de1c487722acd26b58ce332f0235c8cdb5feba2` (asserted), diff `origin/main...HEAD`.

## Verdict: FAIL

Two blocking findings, both reproduced on Atlas in a sandbox guest running the tagged build `c11 DEV rv-361.app`:

1. `scroll`, `visible` and `visible --watch` do not work on a markdown panel whose reader is not mounted. That covers a panel an agent opens in a background workspace, a panel that is not the selected one in its area, and a panel evicted by C11-359.
2. `open-external` takes macOS focus away from c11.

## Invariants checked

| # | Invariant | Result |
|---|---|---|
| a | Each command does what the contract table says against the named panel, and rejects bad input with a clear error | **Broken for unmounted panels (B1).** Otherwise holds: unknown theme or typeface, scale outside 0.5–3.0, NaN, a missing `--panel`, an empty heading and a wrong panel type each fail clearly. |
| b | Threading: queries run off-main, only the WebKit or model hop runs on main, and no `main.sync` is used. Focus: non-focus commands never steal macOS focus, switch the visible workspace or move in-app focus | Threading holds: all six methods are `socketWorker`, every hop is async with a bounded wait, and the watch writes on the connection thread. **Focus is broken by `open-external` (B2).** Workspace selection and in-app focus hold, both in the owner's evidence and in my runs. |
| c | `visible --watch` is bounded and tears down cleanly | Holds at runtime for coalescing (at most 2 pending), panel close and client disconnect. Gaps are N3 to N6. |
| d | Commands against an evicted or never-shown panel answer from the model or recreate the reader without stealing focus | **Broken (B1).** Theme, typeface and font answer from the model. Scroll, visible and watch return `not_ready` with no recovery path. |
| e | The skill matches the shipped CLI | Command forms and help text match exactly. Gaps are in N8. |
| f | Capability registration follows the versioned-feature pattern | Holds: `markdown.agent_cli` v1 is in the registry, methods are advertised only when the feature is enabled, and both dispatch and stream are gated. Documentation gap in N8. |

## Blocking

### B1. Scroll, visible and watch fail with `not_ready` on any unmounted panel, and an agent cannot recover

- **Where:** `Sources/SocketHandlers/MarkdownFeedbackHandlers.swift:204`, and the same guard at :226 and :395. `panel.renderer` is nil until `MarkdownWebContent.makeNSView` calls `ensureRenderer()` (`Sources/Panels/MarkdownPanelView.swift:280`, `Sources/Panels/MarkdownPanel.swift:122`). C11-359 sets it back to nil on eviction.
- **Reproduced on Atlas** (sandbox guest `c11-sb-rv361`):
  1. `c11 new-workspace --title BG` created `workspace:3`.
  2. `c11 markdown open /tmp/rv361.md --workspace workspace:3` created `panel:7`. Workspace 2 stayed selected.
  3. `markdown visible --panel panel:7 --json` returned `Error: not_ready: Markdown renderer is not ready` (exit 1). `scroll --heading Installation` and `visible --json --watch` failed the same way.
  4. After waiting 20 s, `visible` still returned `not_ready`.
  5. `theme --list`, `theme --set dark` and `font --scale 1.3` succeeded, because they answer from the model.
- **Why it blocks:** the ticket's proof is "each command driven from a terminal against a markdown panel in a background workspace". Agents cannot select a workspace (`workspace_switch_blocked`), so this is a permanent failure for them, not a transient one. The owner's proof only passed because the operator selected workspace 3 first ("initialize the renderer", validator step 1). The same failure applies to:
  - every markdown panel that is not the selected panel in its area;
  - every hidden reader beyond C11-359's four-reader cap.
- **A related race:** the guard also returns `not_ready` immediately while a mounted renderer has not yet posted `ready`. An agent that opens a panel and scrolls straight away fails, even on the visible workspace.
- **Fix direction:** have the command create the reader without showing it.
  - On the main hop, call `ensureRenderer()` with no host view, keeping its viewport hidden.
  - Off-main, wait a bounded time for `ready` and the first `rendered`, with the query pinning the reader.
  - Then run the call.
  - Alternatively, answer `visible` from `readingPosition` plus presentation, and queue a pending scroll target that runs when the reader mounts.
  - Either way, add a socket-level test that runs against a panel with no reader.

### B2. `open-external` makes another app frontmost, so an agent command steals macOS focus

- **Where:** `Sources/SocketHandlers/MarkdownFeedbackHandlers.swift:353`. `NSWorkspace.shared.open(URL)` activates the opened app.
- **Reproduced on Atlas:**
  - With the tagged c11 frontmost (`front-before=c11`), `c11 markdown open-external --panel panel:8` printed `OK opened externally: /tmp/rv361.md`, and then `front-after=TextEdit`.
  - Guest screenshot: TextEdit's window and menu bar are in front of c11. Saved at `.lattice/orchestration/md-viewer/review1-C11-361-openext.png`.
  - The owner's evidence checked only `tree --all` (the selected workspace), not which app was frontmost.
- **Why it blocks:** the repo's `CLAUDE.md` says "Socket/CLI commands never activate c11 or raise a window", and the brief's bar treats an agent command that changes the operator's focus as a wrong-target failure. An operator typing in c11 has their keystrokes moved into the other app.
- **Fix:** call `NSWorkspace.shared.open(url, configuration:)` with `activates = false`. Report success from its completion, since the error arrives asynchronously, and keep that wait off-main. Add one line to the skill saying the file opens behind c11. An operator-initiated toolbar button (C11-360) may still activate.

## Non-blocking

- **N1. The tests named in the owner's plan are missing, and mutations prove the gap.**
  - The plan listed socket and model tests for wrong-type, stale and cross-window targets, settings persisted through the setters, focus, and watch ending on interrupt, pipe close or panel close.
  - None were shipped. Only `MarkdownVisibleStateBufferTests` and a policy-table assertion exist, and server-side validation is exercised only against a fake server.
  - Mutation run `rv-361-mut` (results table below):
    - removing both theme-validation layers (`MarkdownFeedbackHandlers.swift:294` and `MarkdownPanel.setTheme`'s guard) left all 38 tests green;
    - removing the observer finish in `MarkdownWebRenderer.close()` (`MarkdownWebRenderer.swift:188`) also left all 38 green.
- **N2. `testFinishingWakesAnEventWaiter` (`c11Tests/MarkdownPanelFontScaleTests.swift:132`) does not prove the wakeup.**
  - `finish()` usually runs before the waiter blocks. Removing `condition.broadcast()` from `finish()` left the test green.
  - Make sure the waiter is parked first. For example, deliver one state, have the waiter consume it and signal, then call `finish()`. Or assert that `next()` has not returned before `finish()` is called.
- **N3. A watch keeps its reader alive for as long as it runs** (`MarkdownWebRenderer.swift:198-202`, `activeQueries += 1`).
  - N watches on hidden panels keep N WKWebViews and web-content processes, bypassing C11-359's four-reader cap.
  - Each watch also holds one socket thread. Nothing limits the count.
  - Scenario: an agent leaves `visible --watch` running for each of 10 panels, and all 10 readers stay alive indefinitely.
  - Either document this as intended, or end the stream (or detach it) on eviction.
- **N4. The watch's initial state has no deadline** (`MarkdownFeedbackHandlers.swift:398`).
  - If the first `visible` JS call never completes, `buffer.begin` never runs, so the CLI prints nothing and blocks until disconnect or panel close.
  - The one-shot `visible` has an 8 s bound.
- **N5. The watch's first snapshot prefers the cached `renderer.state` over the fresh result** (`:404`).
  - The PR's own comment at `publishObservedState` says hidden workspaces throttle the state messages.
  - So after a change made while hidden (a resize, for example), the cached state is older than the fresh `visible()` result being thrown away. Use the fresh result.
- **N6. The disconnect `DispatchSource` is cancelled without waiting for cancellation to finish** (`:377`).
  - `handleClient` then closes the fd, but libdispatch requires the descriptor to stay open until the cancel handler has run. If the fd number is reused, the late handler can act on someone else's socket.
  - Add a `setCancelHandler` and a semaphore wait.
  - Also, any byte from the peer, or a half-close (for example `nc -U` reaching EOF on stdin), ends the watch at once. Document that or tolerate it.
- **N7. The stream path skips three things the normal path does** (`Sources/TerminalController.swift:2262`):
  - it never calls `startupNotReadyResponse`;
  - it ignores the listener's `shouldContinue()`, so a watch survives Restart CLI Listener or a stop;
  - it checks for unsupported routing keys before checking auth.
- **N8. Skill gaps.**
  - `skills/c11-markdown/SKILL.md:185` and `references/commands.md` say nothing about `not_ready` (when it happens, and that agents cannot fix it themselves), or about `open-external` raising another app (before the fix).
  - Neither skill names the `markdown.agent_cli` feature id.
  - The feature-id list at `skills/c11/references/api.md:131` is not updated, unlike `read_selection.terminal` and `feed.asks`.
- **N9. A bare integer `--panel N` resolves through `panel.list` in the default (selected or caller) workspace**, while `--workspace` is rejected (`CLI/c11.swift:5624`).
  - Seen in the guest: `--panel 1` resolved to index 1 of the selected `workspace:2`.
  - An agent could hit a panel in the operator's workspace. Either reject bare integers for these commands or allow `--workspace` scoping.
  - Low severity. Also, `Double()` accepts hex input (`--scale 0x1p0` gave 1.0); trivial.

## Demonstrations (Atlas only)

| Run | What it shows |
|---|---|
| `rv-361` Debug build (`b62bc3a1…`) | compile ok |
| `rv-361-base` test slice (`aaefec3d…`): CapabilityFeatures, MarkdownVisibleStateBuffer, MarkdownPanelFontScale, MarkdownPresentation, MarkdownWebRenderer, MarkdownRendererRetentionPolicy | 38 tests, 0 failures. Reproduces the owner's 7/7 green. The owner claimed no reds, so there were none to reproduce. |
| `rv-361-mut` (`a829c68b…`), M1: removed `markdown.*` from the socket-worker list | **red**: `testMarkdownAgentMethodsRunOnSocketWorkersWithoutInAppFocusIntent` (6 × `mainActor != socketWorker`) |
| same run, M2: broke coalescing (always append) | **red**: `testWatchDeduplicatesAndBoundsQueuedChangesToLatestState` |
| same run, M3: removed the broadcast in `finish()` | **green**, which is N2 |
| same run, M4: removed theme validation in the server and the panel | **green**, which is N1 |
| same run, M5: `close()` no longer ends observers | **green**, which is N1 |
| `rv-361-mutcli` (`a5e862d9…`): removed the CLI scale-range check, then ran `tests/test_cli_markdown_agent.py` | **red**: `font --scale 3.1` printed `OK font_scale=3.1` |
| Owner's `tests/test_cli_markdown_agent.py` against the unmutated CLI | PASS |

Runtime checks in sandbox guest `c11-sb-rv361` (now deleted):

- **B1:** reproduced as described above.
- **B2:** reproduced as described above.
- **Watch on a visible panel:**
  - It printed the initial state with `["Doc"]`, then `["Doc","Installation"]` after a CLI scroll, then `["Doc","Zeta"]`.
  - Closing the panel ended it with exit 0.
- **Disconnect teardown:** five watches on `panel:5` raised the app's unix sockets from 1 to 6 and its threads from 30 to 35. Killing the clients brought them back to 1 and 31.
- **Focus:** the watch, the scrolls and the settings commands left `workspace:2` selected throughout.

Mutations were made only in a scratch worktree under the session scratchpad. No tracked files in the review worktree were edited.

## What repair must show

1. **B1:**
   - From a terminal in the selected workspace, run `scroll`, `visible` and `visible --watch` against a markdown panel opened with `markdown open --workspace <unselected>` and never shown. Each must succeed.
   - Repeat after evicting the panel (open more than four hidden readers), with the workspace selection unchanged.
   - Add a socket-level test that covers a panel with no reader.
2. **B2:** with c11 frontmost, run `open-external` and confirm that c11 is still the frontmost process and that the file opened.
3. **N1 and N2:** a test that goes red under M4, M5 and M3 respectively.
