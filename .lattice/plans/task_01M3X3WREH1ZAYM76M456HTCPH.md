# C11-268 plan: guarded `c11 feed answer`, and an answer on `flag.lowered`

P2. Planning only. One PR, its own branch `c11-1.0/C11-268-feed-answer` from `origin/main` at build time. Depends on C11-264 (the row) and C11-267 (the input state). Does not start until both have merged.

## Why it can ship alone

The 1.0 Feed is the read-only list, open, watch, order, and quick view from C11-264, C11-265, and C11-266. Those three do not call this command. Ordinary `c11 send` does not call it either. An unrecognized screen is refused here, so this command cannot change fleet send behavior. Reverting the PR removes `feed answer` and the optional `answer` field. Plain `c11 lower-flag` and the banner dismiss stay `{by}` with no migration. The release can ship without this ticket. It does not hold C11-264 or C11-267.

## Citations on `0ff8887e5e`

The ticket cites `AttentionModel.swift:418-429` as the lower path. That range is the epoch bookkeeping after a successful lower (`emitFlagLowered` at `:419`). The mutation entry points are `TabAttentionService.lower` (`:247`) and `lowerIfFlagged` (`:263`, no-op unless a flag is up). Socket `flag.lower` is `AttentionHandlers.swift:113`. `emitFlagLowered` (`EventEmitter.swift:164`) sends only `by`.

`deliverSocketSendText` (`TerminalController.swift:6703`) pastes, then `scheduleSubmitReturnAfterPasteDelay` (`GhosttyTerminalView.swift:4016`). The delay is `TextBoxBehavior.returnKeyDelayMs` (`TextBoxInput.swift:298`, 200). That timer calls `sendKey(.returnKey)` (`:4086`). With a window, `sendSyntheticKey` (`:4048`) sets `isSynthesizingKey` and calls `keyDown`. `keyDown` (`:5646`) skips `lastOperatorInputAt` for a synthesized key, and then (`:5656`) still calls `lowerIfFlagged(..., by: .operator)`. A socket submit therefore emits `flag.lowered` by the operator, with no answer. Without a window, `sendKey` injects via `sendKeyDirectlyToSurface` (`:4105`) and does not lower. Either path can double-fire or skip the answer event if this ticket lowers on its own clock.

`flag.lowered` payload is free-form (`spec/event-envelope.v1.schema.json:71`). Adding an optional key keeps `v = 1`. The schema prose and `skills/c11/references/events.md:56` currently say the payload is `{by}` only.

C11-264's plan does not emit a generic `input` row. The journal has no such kind. This ticket's "input" scope is that gap. Do not invent the kind. Eligible rows are `turn_end` and a flag with no blocking ask.

## C11-257 boundary

Do not edit `Sources/Mailbox/`, do not emit `tab.input_sent`, and do not log the reply body a second time. Delivery of a live, attached surface goes through `deliverSocketSendText`, so a C11-257 emit that runs only after a payload reaches the PTY still sees this reply. Do not move that emit. C11-257 must be merged before any shared send/scheduling changes, including different hunks. Integrate onto its landed change. The new code is one optional gate on `scheduleSubmitReturnAfterPasteDelay`, default nil, so ordinary send is unchanged.

## Command

`c11 feed answer <tab> --text <text> [--by agent|operator]` → socket `feed.answer` in `Sources/SocketHandlers/FeedHandlers.swift`, next to C11-264's methods. CLI lives in `CLI/FeedCommand.swift`.

Resolve the ref once to a workspace UUID and a tab UUID. Every later check uses those UUIDs. If the workspace or the panel is gone, return `unavailable` and focus nothing. Do not call `focusTabFromNotification`. Do not substitute the focused tab.

`--by` uses the same parse as `lower-flag`. Default is `agent`. The synthetic Return is never recorded as `operator`.

`--text` longer than 16384 UTF-8 bytes is `answer_too_long`. Refuse before any read or write. Do not truncate. Whitespace-only text is the empty case. A payload that `socketTextIsPasteDeliverable` rejects (a C0 byte other than newline) is `not_prose`: no key-event typing.

## Who may be answered

Read the current C11-264 row for that tab, then read it again immediately before the paste.

- Blocking `question`, `plan`, or `permission`: reject `ineligible`. No paste, no queue, no lower, even when a flag is also up.
- Flag up, and no blocking ask: eligible. A coexisting `turn_end` does not change this. Success lowers that flag.
- No flag, row kind `turn_end`: eligible. Success does not emit `flag.lowered`.
- Anything else, including the absent `input` kind: `ineligible`.

Empty text does not send. Route only this branch through the explicit `feed.open` focus-policy scope; do not add all of `feed.answer` to the focus-intent allowlist. It calls the C11-264 `feed.open` path for that same UUID pair and returns `opened: true`, `delivered: false`, `submitted: false`. A missing tab is `unavailable`.

## Acceptable screen

Require a C11-267 state of `empty` or `suggestion` in a complete, fixture-supported active prompt region before the paste. Refuse `draft`, `dialog`, `unknown`, and `unavailable` with that code, before any write. Point the error at `c11 feed open`. This is stricter than ordinary send, which still delivers on `unknown`. Do not retarget. Do not poll.

## Delivery and the single lower

`Sources/Feed/FeedAnswer.swift` decides. The surface must already be attached. If it is not, return `not_ready` and do not call `sendSubmitFormText` or either queue fallback (`SurfaceHandlers.swift:927` and `:958`).

One in-flight answer per tab. A second call while a gate is armed returns `submit_pending` and does not paste again.

On an attached surface:

1. Capture exact workspace/tab, terminal-surface object/native lifetime, eligible journal owner/current-row sequence, and `flagRaisedAt` when the row is a flag. That is the flag epoch (`AttentionModel.swift:38`). Capture the existing real-operator-input clock and normalize the expected body with `trimmingTrailingNewlines`. A command starting from a flag remains bound to that epoch.
2. Arm a one-shot gate on that surface, then call `deliverSocketSendText` with submit.
3. The gate runs inside the existing 200 ms block, on the main actor, before `sendKey`:
   - Panel UUID mismatch, terminal-surface replacement/native lifetime change or surface gone: do not send Return. Result `target_lost`. Do not lower. Re-read the current Feed/journal row; a new blocking ask or replaced owner makes this answer ineligible even if the screen still looks like an empty composer.
   - Do not require `empty`/`suggestion` after pasting: our own text is now a draft. Use C11-267's private bounded complete-region parser to require that the composer equals this command's normalized pasted body, including supported multiline/wrap boundaries, and that the real-operator-input clock has not advanced. Perform the comparison transiently, without publishing text or hashes. A draft made solely by this paste is expected. Changed body, new dialog/ask, unknown/incomplete region, or an oversized/unsupported multiline layout gives `pasted_not_submitted`; no Return, no delete and no lower. If the TUI has not visibly ingested the full paste by the delay, report unconfirmed submission rather than asserting success or extending a polling loop.
   - Otherwise set the one-shot `suppressNextSyntheticFlagLower`, call the submit path and clear that suppression token if it was not consumed (the windowless path never enters `keyDown`).
4. `keyDown` consumes the suppress flag only when `isSynthesizingKey` is set, and skips `lowerIfFlagged` for that one event. A real operator key has the flag clear and still lowers immediately, with no answer text.
5. Add a callback/outcome to the feed-specific submit gate that confirms actual passage through `ghostty_surface_key` for the original surface. Calling the void `sendKey`/`sendSyntheticKey` alone is not proof: those paths return early when a surface/event cannot be made. A false/native-unhandled outcome is `submit_unconfirmed`; no answer-bearing lower. This is transport handoff only, never proof the agent understood the text. After that positive handoff, and only then: if this reply started as a flag and `flagRaisedAt` is still the captured epoch, call `lower(..., by: actor, answer: text)`. One `flag.lowered`. Payload `by` plus `answer`. If the epoch changed or the flag is already down, do not lower. Result `flag_epoch: replaced`, `flag_lowered: false`. The text was still submitted.
6. A `turn_end` reply never lowers.

The socket call waits for that block (bound of 1 s) off the main actor. It does not return `answered` when the paste was only queued or the Return was only scheduled. Response fields, beside the existing `delivered` / `queued` / `submitted`:

- `answered` describes eligible text transport only: true after positive Return handoff for `turn_end`, or after that handoff plus lowering the originally captured flag. If its flag was replaced/already lowered, report `submitted: true`, `flag_lowered: false`, `answered: false`, and the changed-epoch result. Do not describe the new flag as answered. Agent comprehension remains unknown. It is false for every refusal and for `pasted_not_submitted` and `target_lost`.
- `retry` is `safe` only when nothing was pasted. It is `unsafe` after a paste, including `pasted_not_submitted` and a timeout. A timeout is `submit_unconfirmed`: atomically invalidate the pending gate on the worker so a late main timer sees cancellation before side effects. Do not wait for a main-queue cancellation task that can arrive after the timer. A running main callback records its bounded observed outcome; never fabricate that a Return already handed off was cancelled. No crash-durable request protocol is introduced.

`lower` gains an optional `answer`. Nil omits the key. Banner dismiss (`GhosttyTerminalView.swift:7598`) and `flag.lower` keep passing nil.

## Skill and strings

When the code lands, document the command, the stricter state rule, `retry`, and the new `flag.lowered` shape in `skills/c11/references/api.md`, `references/events.md`, the schema description, and one sentence in `skills/c11/SKILL.md`. Sync the installed skill then, not during planning. No new SwiftUI strings. Machine codes stay codes. CLI errors stay English `CLIError`. C11-291 has nothing to translate from this ticket.

## Hot path

`keyDown` gains one Bool read next to the existing `lowerIfFlagged`. No allocation, no I/O, no extra main hop on ordinary keys. The 200 ms wait belongs only to `feed.answer`. On Atlas, compare a typing sample to the C11-270 baseline. No new threshold. The check is not atomic with a later human keypress; the delayed re-read is the bound we do take, and the help text says a keystroke inside that window can leave the paste unsubmitted.

## Acceptance → oracle → proof

| AC | Oracle | Proof |
|---|---|---|
| 1. An eligible empty prompt gets the text once; multiline stays one paste; submit is separate from delivery | `deliverSocketSendText:6703` pastes then delays Return; bracketed paste does not submit on interior newlines | `FeedAnswerTests`: a fake writer records one paste and one Return. `queued` is not `answered`. |
| 2. question, plan, permission, draft, dialog, unknown, missing tab, and empty text do not type or lower | C11-264 has no `input` row; `lowerIfFlagged` is unconditional today | Same tests. Zero writer calls. Flag snapshot unchanged. Empty text returns the open result and `delivered: false`. |
| 3. One `flag.lowered`, with answer and the command's `by`. Plain lower has no answer key. A new epoch is not lowered | `emitFlagLowered:164` is `{by}` only; synthesized Return still lowers at `keyDown:5656` | Handler test: the synthesized Return emits nothing, then one event with `answer` and `by=agent`. A second test changes `flagRaisedAt` before the timer and asserts no lower. Banner and `flag.lower` payloads have no `answer` key. |
| 4. A paste that does not submit is not an answered ask, and the result forbids a blind retry | Phase-B can tear the surface down (`SurfaceHandlers.swift:896`); the Return is 200 ms later | Gate tests: own pasted draft equals expected body -> one submit; operator adds a character, prompt becomes a chooser, native handoff fails, or current request changes -> `pasted_not_submitted`/`submit_unconfirmed`, `retry: unsafe`, flag still up; pre-submit refusals have no Return, while native rejection remains an unconfirmed attempted handoff. Unattached tab → `not_ready`, `retry: safe`, queue depth unchanged. |
| 5. Close or replace before Return does not redirect | `sendKey` can target whatever view is current | Identity mismatch → `target_lost`, no Return, no lower, focused tab unchanged. CLI help prints the residual-race sentence; the test asserts that printed sentence. |

Also test timeout before a delayed main callback (no late Return/lower), an already-lowered epoch, and multiline paste with wrap boundaries. Test actual native/synthesized handoff outcomes through an executable seam, not just a fake timer that assumes `sendKey` succeeded.

Public fixtures use the synthetic string `FEED-ANSWER-FIXTURE` only. Assert that string is absent from any journal file the test opens. It intentionally appears in the local `flag.lowered` payload under test and C11-257's existing explicit send log if that channel records this transport; do not falsely promise absence from the already-authorized send channel. It never appears in the body-free journal/analytics/spool. Document both local channels and EventLog's existing 8 MiB current/one rolled generation retention; do not add a second reply log. Sanitized public artifacts use only this synthetic text.

Atlas tagged app, `C11_QA_LAUNCH=fresh`, after BUILD MODE and after C11-264 and C11-267 have merged: computer use raises a flag on an empty Claude prompt, runs `feed answer --text` from another tab, and checks one `flag.lowered` whose `answer` is the synthetic text. A second tab sitting on a question chooser is not typed. Record the artifact SHA. Do not run this on Hyperion.

## Cut line

Out: an `input` row, menu-key answering, banners, approvals, the blocking hook bridge, crash-durable request identity, send-key guarding, mailbox delivery, `tab.input_sent`, and any change to ordinary `c11 send` refusal policy (that is C11-267).

Open decisions: none. P2 optional. Takeover corrects self-paste rejection, delayed identity/eligibility checks, native handoff reporting, atomic pending cancellation and send-log disclosure. No builds/tests/product edits performed.

## Reset 2026-10-03 by agent:luna-268
