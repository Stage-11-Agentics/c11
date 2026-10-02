# C11-267 plan: on-demand input state, and a send guard for real drafts

P2. Planning only. One PR, its own branch `c11-1.0/C11-267-send-draft-guard` from `origin/main` at build time. No Feed command in this PR.

## Why it can ship alone

Nothing in the release depends on this ticket. `feed answer` is C11-268 and stays out. Refusal applies only when the active screen is positively a draft or a dialog. An unrecognized screen, a cold tab, or an older app keeps today's delivery and says so in the response (`input_guard: unknown` or a missing field). `--allow-unguarded` is an explicit override, not the default. Reverting the PR restores `send` with no migration. The release can ship without it.

## Citations on `0ff8887e5e`

- `deliverSocketSendText` (`Sources/TerminalController.swift:6703`) pastes, then `scheduleSubmitReturnAfterPasteDelay`. No draft check. Paste-vs-key rules are `socketTextIsPasteDeliverable` (`:6662`) and `trimmingTrailingNewlines` (`:6679`).
- `v2SurfaceSendText` (`Sources/SocketHandlers/SurfaceHandlers.swift:846`) resolves the tab, then on the phase-B main hop (`:905`) re-reads the live surface and either delivers or queues. `submitted`, `queued`, and `delivered` are already the response (`:976`).
- `readTerminalTextBase64` (`TerminalController.swift:3453`) can read `GHOSTTY_POINT_ACTIVE`, separate from the scrolled viewport. `ghostty_surface_read_text` (`ghostty.h:1120`) returns plain `ghostty_text_s` (`:381`). There is no per-cell style. `read-screen` therefore cannot tell a faint suggestion from typed text (`skills/c11/references/api.md:278`).
- `send-key` is out. Do not change `v2SurfaceSendKey`.

## C11-257 boundary

C11-257 is in progress. It owns `tab.input_sent` emission on the send path and every mailbox file (`Sources/Mailbox/`, inbox drain, `messages.html`, mailbox event bodies).

This ticket does not emit events, does not log send bodies, and does not edit those files. The guard runs inside `v2SurfaceSendText` immediately before `deliverSocketSendText` and before either queue fallback (`:927` and `:958`). A refusal returns without calling them. If C11-257 emits only after a payload reaches the PTY, a refusal stays unlogged, which matches their contract. Do not move or rewrite their emit. Implement only after C11-257 merges, as the board dependency now requires. Do not touch its shared send/dispatch files earlier, even at different hunks. Integrate onto its landed change; the guard is one call, not a second writer.

## Style seam

AC1 needs the faint bit. Plain text cannot supply it.

A single cursor row cannot recognize a multi-row question/plan chooser or preserve a wrapped draft; it can mislabel the last blank composer row empty. Add one bounded active-screen styled prompt-region export, not cmux's render grid. Return cursor coordinates, explicit row/soft-wrap boundaries, UTF-8 runs and SGR-2 faint bits for up to 16 rows around the cursor, 4096 cells / 16 KiB text total. Mark clipped/ambiguous prompt regions incomplete; an incomplete region is unknown, never empty. Keep capture limits inside native copying, not clipping a full-screen allocation afterward. No colors, full screen or scrollback. Fixture-backed complete prompt geometry is required before reporting empty/suggestion/draft/dialog; surrounding prose containing ❯ alone is unknown.

Verified pinned Ghostty `26c3e499ed8c4d65e3748248de7fd04c1e9a8103`: `include/ghostty.h:381` gives plain text only; `src/apprt/embedded.zig:1675-1721` holds the renderer mutex while dumping text; `src/terminal/style.zig:33` retains faint. Plan changes are in that header, embedded export/free pair and terminal style/page access helper, plus native behavior tests. The worktree's submodule is uninitialized; this evidence was read from the pinned Ghostty checkout/header Git object, with no initialization/build performed. Never borrow its modified worktree files for implementation.

Native capture remains main-actor under the established surface-lifetime policy. Use the C11-294 landed bounded-lock acquisition policy; if not available or contended, return unavailable. A cell cap alone does not bound mutex wait. Implement this optional ABI after C11-294's fork/GhosttyKit integration, push the submodule change to the fork's main before moving the parent pointer, update `docs/ghostty-fork.md`, and wait for the auto-generated matching checksum and green GhosttyKit CI. Do not invent a checksum or bypass the one-build lock. Parser tests take an immutable prompt-region value; native tests cover actual attributes and wrap bounds.

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

## Skill

Update `skills/c11/references/api.md` at the send section (`:270` and the ghost-text note `:278`): `input-state`, the guard field, `--allow-unguarded`, and that `send-key` is not guarded. One sentence in `skills/c11/SKILL.md`. Sync the installed skill when the edit lands, not during planning. No new SwiftUI strings. Machine codes stay codes. C11-291 has nothing to translate unless a later UI string appears.

## Acceptance → oracle → proof

| AC | Oracle | Proof |
|---|---|---|
| 1. Draft, empty, faint, dialog, unrecognized stay distinct; faint is not a draft; no draft text in the result | Claude ghost line (`api.md:278`); cmux draft-guard idea | `PromptInputClassifierTests` on recorded regions, including wrapped/multiline draft with blank final row, full chooser layout and text containing a prompt-like glyph. Incomplete/oversize capture returns unknown. Assert the sentinel characters are absent. |
| 2. Draft and dialog refuse before any PTY write; empty still sends | `deliverSocketSendText:6703` has no check | `SendInputGuardTests` plus a socket-handler test with a fake writer that records calls. Refused states record zero writes. |
| 3. Scrolled viewport is not the input; cold and unknown are not `empty` | Active vs viewport tags in `readTerminalTextBase64:3499` | Classifier tests take the active region, not a viewport string. Collection test: a fake reader fails if asked for scrollback. Unreadable → `unavailable`, not `empty`. |
| 4. A replaced tab is not written; help admits the race | Phase-B surface can change (`SurfaceHandlers.swift:896`) | Guard test: identity mismatch returns `unavailable` and does not call the writer. Help/skill text contains no atomic-safety claim. The test checks the response, not a source grep of the help file: the CLI `--help` path prints the sentence and the test asserts that sentence. |
| 5. An older server is visibly unguarded | Agents already depend on send succeeding | CLI test with a fake socket that returns unknown method: send still returns success and `input_guard: unguarded`. A new server's checked empty send returns `input_guard: checked`. |

Atlas tagged app, `C11_QA_LAUNCH=fresh`, after BUILD MODE: computer use types a real unsent draft in one terminal and `c11 send` from another tab. The draft is still there and the command's `input_guard` is `refused`. A second tab with an empty Claude prompt accepts send. A scrolled-up viewport still reports the draft on the active row. Record the artifact SHA. Compare one on-demand inspect plus a typing sample to the C11-270 baseline. No new threshold. Do not run this on Hyperion.

## Cut line

Out: `feed answer` (C11-268), send-key guarding, polling, a classifier for every TUI, menu keys, approvals, the blocking hook bridge, `tab.input_sent`, mailbox delivery, and the messages page.

Packaging: register `tab.input_state` in worker routing/capabilities and include new app/CLI/test files in compile entry points. Native capture uses a short lifetime-safe main hop; parser/response encoding stay off main where feasible. Ordinary-send phase-B guard remains immediately before delivery/queue with no extra per-key observer. Atlas evidence includes native-copy/lock timing against C11-270, not only parser tests.

Open decisions: none. P2 remains optional and must not gate P1 Feed; an unavailable native seam is BLOCKED, never a guessed style. Takeover verification performed without builds/tests/product edits.
