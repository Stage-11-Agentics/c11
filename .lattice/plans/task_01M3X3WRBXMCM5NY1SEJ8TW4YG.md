# C11-267 plan: on-demand input state, and a send guard for real drafts

P2 implementation. One PR on `c11-1.0/C11-267-send-guard`, refreshed from `origin/main` before validation and handoff. No Feed command in this PR.

## Why it can ship alone

Nothing in the release depends on this ticket. `feed answer` is C11-268 and stays out. Refusal applies only when the active screen is positively a draft or a dialog. An unrecognized screen or cold tab keeps today's delivery and reports `input_guard: unknown`; an older app is visibly `unguarded`. `--allow-unguarded` is an explicit override, not the default. Reverting the PR restores `send` with no migration. The release can ship without it.

## Citations on refreshed `origin/main` `1199866cbc`

- `deliverSocketSendText` (`Sources/TerminalController.swift:7215`) writes text and schedules the submit Return after the paste-settle delay. It has no draft check; paste-vs-key handling is in `socketTextIsPasteDeliverable` (`:7235`).
- `v2SurfaceSendText` (`Sources/SocketHandlers/SurfaceHandlers.swift:938`) resolves the tab in Phase A, re-reads its live surface on the Phase B main hop (`:1013-1018`), then delivers or queues (`:1015-1047`). `submitted`, `queued`, and `delivered` are response fields (`:1086-1090`).
- `readTerminalTextBase64` (`Sources/TerminalController.swift:3865`) distinguishes active screen from viewport/scrollback, but `ghostty_surface_read_text` (`ghostty/include/ghostty.h:1141`) returns plain text without per-cell faint style. It cannot distinguish Claude's faint suggestion from typed text (`skills/c11/references/api.md:278`).
- C11-294 added one-shot try-lock reads (`ghostty/src/apprt/embedded.zig:1703-1735`); the prompt-region export uses the same bounded acquisition rule. `v2SurfaceSendKey` (`Sources/SocketHandlers/SurfaceHandlers.swift:1104`) stays unchanged.

## C11-257 boundary

C11-257 is done and merged to `origin/main` (integration commits include `0bc4b61779`). It owns `tab.input_sent` emission on the send path and every mailbox file (`Sources/Mailbox/`, inbox drain, `messages.html`, mailbox event bodies).

This ticket does not add or move event emission and does not edit mailbox files. The guard runs inside `v2SurfaceSendText` immediately before `deliverSocketSendText` and both queue paths. A refusal returns before the existing successful-send event and includes no prompt contents. Work is based on C11-257's landed send path.

## Style seam

AC1 needs the faint bit. Plain text cannot supply it.

A single cursor row cannot recognize a multi-row question/plan chooser or preserve a wrapped draft; it can mislabel the last blank composer row empty. Add one bounded active-screen styled prompt-region export, not cmux's render grid. Return cursor coordinates, explicit row/soft-wrap boundaries, UTF-8 runs and SGR-2 faint bits for up to 16 rows around the cursor, 4096 cells / 16 KiB text total. Mark clipped/ambiguous prompt regions incomplete; an incomplete region is unknown, never empty. Keep capture limits inside native copying, not clipping a full-screen allocation afterward. No colors, full screen or scrollback. Fixture-backed complete prompt geometry is required before reporting empty/suggestion/draft/dialog; surrounding prose containing ❯ alone is unknown.

The parent pins Ghostty `5830d1976eecca0d7dee202aef8fb2338d99ed6d`, where `include/ghostty.h` exposes plain text and `src/apprt/embedded.zig` provides one-shot `try_read_text` / `try_read_selection`. The new export and `src/terminal/prompt_region.zig` are limited to the active screen, and native tests cover faint plus soft-wrap preservation and bounded truncation.

Native capture remains main-actor under the established surface-lifetime policy. Use the C11-294 bounded-lock acquisition policy; contention returns immediately. This optional ABI is implemented in the Ghostty submodule. Push the submodule change to the Stage-11 fork's `main` before moving the parent pointer, update `docs/ghostty-fork.md`, and wait for the auto-generated matching checksum and green GhosttyKit CI. Do not invent a checksum or bypass the build route. Parser tests take an immutable prompt-region value; native tests cover actual attributes and wrap bounds.

If that export cannot land, stop and send BLOCKED. Do not guess faint from theme color.

## Classifier

`Sources/Feed/PromptInputClassifier.swift`, pure. Input is a complete bounded prompt region of `{text, faint}` runs with row/wrap/cursor geometry, or `unreadable`/incomplete. Only the recorded Claude layouts are supported. Output:

| State | When |
|---|---|
| `empty` | Claude prompt glyph `❯` and only whitespace after it. Fixture-covered. |
| `suggestion` | Same glyph, and every non-whitespace run after it is faint. Not a draft. |
| `draft` | Same glyph, and any non-faint, non-whitespace run after it. `draft_length` is the scalar count of that text. The characters are not in the result. |
| `dialog` | Fixture-covered Claude question or plan chooser (the recorded frame, not a general detector). |
| `unknown` | Any other screen, including Codex, Grok, a shell, or a partial read. |
| `unavailable` | No surface, surface not attached, or the read failed. |

No polling. No screen classifier loop. No second provider table. A sentinel string in a fixture must be absent from the JSON. C11-268 may privately compare the complete captured composer against its own expected pasted body; that transient comparison is never returned, logged or persisted. It is not a general screen-classification API.

Collection reads the active screen around the cursor, including when the viewport is scrolled up. A multiline/wrapped human composer with a blank final cursor row remains draft; clipping that composer returns unknown. It does not call the scrollback path. The read is the one main-actor Ghostty call on demand. Parsing the returned row is pure and is not added to `hitTest`, `forceRefresh`, or the sidebar body.

## Send policy

`Sources/Feed/SendInputGuard.swift`: `decide(state, allowUnguarded) -> deliver | refuse`.

On `tab.send_text` / `c11 send` / `c11 send-tab`, after the tab is resolved and on the same phase-B turn as the write:

- Re-check the panel UUID. If that tab is gone, return `unavailable` and do not queue onto another panel. This is the close/replacement case.
- `draft` or `dialog`: refuse. Codes `draft` and `dialog`. Do not paste, queue, or submit. `input_guard: refused`. `draft_length` only for draft.
- `empty` or `suggestion` in a complete fixture-supported prompt region: deliver with today's semantics. `input_guard: checked`. A suggestion is not a draft, so send may overwrite it.
- `unknown` or capture-unavailable on an otherwise live, exact tab: deliver as today. `input_guard: unknown`. A closed/replaced tab is a target error, not compatibility delivery. A cold live tab may retain today's queue behavior with explicit unchecked status. This is not a claim that the screen was safe.
- `--allow-unguarded`: deliver even on draft/dialog. `input_guard: overridden`. Document it. Do not apply it automatically.

Older app, method missing: the CLI still sends and prints `input_guard: unguarded`. A missing field means the running app did not check. The CLI must not invent `checked`.

Help text states the check is not atomic with a later keypress. A person can type after the read and before the paste. No "safe to type" claim.

`c11 input-state --tab` calls `tab.input_state` and prints the same fields. It does not send.

Response fields, added beside the existing `submitted` / `queued` / `delivered`: `input_guard`, `input_state`, `draft_length` (null except for draft), `source` (`active_screen` or null), `observed_at_ms`. No draft text.

## Skill and localization

Update `skills/c11/references/api.md` at the send section (`:270` and the ghost-text note `:278`): `input-state`, the guard field, `--allow-unguarded`, and that `send-key` is not guarded. One sentence in `skills/c11/SKILL.md`. Do not sync the installed skill in this owner run; only the Merge Captain syncs after landing.

New localized keys: `cli.input_state.arguments`, `cli.input_state.duplicate_tab`, `cli.input_state.help`, `cli.input_state.tab_required`, `cli.send.guard_refused`, `cli.send.input_guard`, `socket.input_state.tab_required`, `socket.input_state.timeout`, `socket.input_state.unsupported`, `socket.send.guard_refused`, and `socket.send.target_unavailable`. The six-locale catalog pass is C11-291; machine codes stay codes.

## Acceptance → oracle → proof

| AC | Oracle | Proof |
|---|---|---|
| 1. Draft, empty, faint, dialog, unrecognized stay distinct; faint is not a draft; no draft text in the result | Claude ghost line (`api.md:278`); cmux draft-guard idea | `PromptInputClassifierTests` on sanitized recorded layouts, including wrapped/multiline draft with blank final row, both chooser layouts, an old chooser above a live prompt, and prompt-like prose. Incomplete/oversize capture returns unknown. Assert the sentinel characters are absent. |
| 2. Draft and dialog refuse before any PTY write; empty still sends | `deliverSocketSendText` has no input-state check | `SendInputGuardTests` exercise the write-decision seam with a recording closure. Atlas tagged runtime proof checks that refused text leaves the PTY and successful-send event stream unchanged, while an empty prompt accepts the send. |
| 3. Scrolled viewport is not the input; cold and unknown are not `empty` | Active vs viewport tags in `readTerminalTextBase64:3865` | Native capture calls only the active-screen API. Atlas runtime proof scrolls the viewport away from the prompt, then verifies `input-state` still reports the active composer. An unattached tab reports `unavailable`; an unreadable or unsupported layout is never `empty`. |
| 4. A replaced tab is not written; help admits the race | Phase-B surface can change (`SurfaceHandlers.swift:896`) | Guard test: identity mismatch returns `unavailable` and does not call the writer. Help/skill text contains no atomic-safety claim. The test checks the response, not a source grep of the help file: the CLI `--help` path prints the sentence and the test asserts that sentence. |
| 5. An older server is visibly unguarded | Agents already depend on send succeeding | CLI fixture against a legacy response with no guard fields: send succeeds and shows `input_guard: unguarded`. A new server's checked empty send returns `input_guard: checked`; refusal preserves structured JSON and exits nonzero. |

Build, test, and launch only on Atlas through `scripts/remote-build.sh` with tag `c11-267`; launch with `C11_QA_LAUNCH=fresh` in an isolated guest. Computer use types a synthetic unsent draft in one terminal and invokes `c11 send` from another tab. The draft remains and the command reports `input_guard: refused`. An empty Claude prompt accepts send; a faint suggestion is not refused; a dialog is refused; Codex/unknown and a cold live tab retain delivery/queue behavior with `unknown`; multiline sends and `send-key` preserve existing behavior. Inspect the active screen after scrolling the viewport up. Compare a short on-demand inspection and typing sample to a tagged `origin/main` build with the same scenario and record both values, artifact/source SHAs, and Atlas load average. This is descriptive evidence, not a C11-270 soak pass or a new threshold. No production session and no Hyperion launch.

## Cut line

Out: `feed answer` (C11-268), send-key guarding, polling, a classifier for every TUI, menu keys, approvals, the blocking hook bridge, `tab.input_sent`, mailbox delivery, and the messages page.

Packaging: register `tab.input_state` in worker routing/capabilities and include new app/CLI/test files in compile entry points. Native capture uses a short lifetime-safe main hop; parser/response encoding stay off main where feasible. Ordinary-send phase-B guard remains immediately before delivery/queue with no extra per-key observer. Atlas evidence includes native-copy/lock timing, the paired short typing sample, and host load; no full C11-270 soak claim.

Open decisions: none. P2 remains optional and must not gate P1 Feed; an unavailable native seam is BLOCKED, never a guessed style. Implementation and runtime proof follow this plan.
