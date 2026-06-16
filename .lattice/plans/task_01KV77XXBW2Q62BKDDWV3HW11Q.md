# C11-144: Mailbox: delivery safety — prompt-gated stdin injection + receiver-pull cadence

Operator's TOP concern from the Trident review (notes/trident-review-mailbox-feature-pack-20260615-2208/synthesis-evolutionary.md §8). Today the stdin handler pastes a framed <c11-msg> block into the recipient PTY and dispatches Return — unsafe when the agent is mid-command or in a raw-mode app (Vim): corrupts the input stream. Gemini predicts operators abandon stdin delivery within 3 months unless this is fixed.

Deliverable (two layers, both reuse existing machinery — minimize new hooks):
1. Gate the push on c11's ALREADY-tracked PanelShellActivityState { unknown, promptIdle, commandRunning } (Workspace.swift:5399, already used for close-confirmation). In StdinMailboxHandler: promptIdle -> inject now; commandRunning -> BUFFER and flush on transition back to promptIdle; unknown -> conservative buffer. No new lifecycle hook.
2. Add a receiver-pull cadence to the c11 skill (agents 'c11 mailbox recv --drain' at turn boundaries) as the robust floor — the AgentMail-style pull pattern. Zero c11 code; sync installed skill.

Validation: dogfood test — fire messages into agents mid-Vim and mid-build on a tagged build, confirm no PTY corruption and that buffered messages flush at the next prompt. This test also empirically settles the Claude-vs-Gemini split on whether PTY delivery is safe.

Scope guard: NOT the full out-of-band control-socket (that pushes a listener into the agent layer — bigger than 'minimize hooks'). Revisit only if the prompt-gate proves insufficient in the dogfood test.

---

## Implementation plan (delegator, 2026-06-15)

### Key grounding fact discovered during orientation
The shell-integration zsh/bash hooks report `running` on `preexec` (a foreground command launched) and `prompt` on `precmd` (back at the prompt). **An agent TUI such as Claude Code is itself the foreground command**, so a c11 surface running a live agent reports `commandRunning` for the agent's *entire lifetime* — it only returns to `promptIdle` when the agent process exits. Consequence: gating stdin push on shell state means **push into a live agent is buffered, not injected**; the agent receives via the layer-2 pull floor (`recv --drain`) instead. This is by design and aligns with the Trident framing ("PTY is a best-effort doorbell; the filesystem is the durable queue"): the gate makes the doorbell *safe*, pull makes delivery *reliable*. The dogfood test still records whether direct push into a live agent would actually corrupt (settles the Claude-vs-Gemini split).

### Layer 1 — prompt-gated injection + buffer/flush

**New pure seam (unit-testable, no PTY / no Workspace instance):** `Sources/Mailbox/MailboxStdinBuffer.swift`
- `static func decide(state: Workspace.PanelShellActivityState) -> Decision` — `.promptIdle → injectNow`, `.commandRunning/.unknown → buffer`.
- Per-surface FIFO `[UUID: [Entry]]`; `Entry { id, recipientName, block, bufferedAt }`.
- `enqueue(surfaceId:entry:) -> Entry?` (returns evicted on per-surface cap, default 64).
- `drainForFlush(surfaceId:now:) -> (fresh, expired)` — FIFO; entries older than `freshnessWindow` (default 600 s) are *expired* not injected. **Freshness window is the mechanism that stops hours-long agent sessions from dumping stale `<c11-msg>` blocks onto the bare shell when the agent finally exits** (minutes-long builds/vim still flush; hours-old agent buffers drop, already delivered via pull). `now` injected for deterministic tests.
- `removeSurface(_:)`, `retainOnly(surfaceIds:)`, `pendingCount(surfaceId:)`.

**Handler change:** `StdinMailboxHandler.WriteOutcome` gains `.buffered(bytes:)`; `Writer` typealias extended to `(_ surfaceId, _ envelopeId, _ recipientName, _ bytes) -> WriteOutcome` so the flush path can log the id/recipient. `deliver` maps `.buffered → HandlerInvocationResult(outcome: .buffered)`.

**Log change:** `MailboxDispatchLog.HandlerOutcome` gains `buffered`, `flushed`, `expired`, `evicted` — all emitted as `handler` events (handler="stdin") so `c11 mailbox trace <id>` shows the full lifecycle (a buffered msg is delivered+logged eventually, never silently dropped). Dispatcher gets `logStdinLifecycle(id:recipient:outcome:bytes:)` for Workspace to call from the flush path.

**Workspace wiring (all @MainActor — buffer state is main-confined, no locks):**
- New stored `mailboxStdinBuffer = MailboxStdinBuffer()`.
- `startMailboxDispatcher()` writer closure → new `deliverOrBufferMailboxStdin(...)`: resolve TerminalPanel; `decide(state:)`; inject-now via `TextBoxSubmit.send` OR enqueue (+log buffered/evicted) and return `.buffered`.
- `updatePanelShellActivityState(...)`: on transition **to** `.promptIdle`, call `flushBufferedMailboxStdin(surfaceId:)` → drain, log expired, `TextBoxSubmit.send` each fresh in FIFO + log flushed.
- Surface teardown (lines ~11087, ~11268) → `mailboxStdinBuffer.removeSurface`; prune (line ~7196) → `retainOnly`. Buffered-but-dropped is safe: the filesystem inbox copy (always written before handlers) + `recv --drain` is the floor.

**Edge cases covered:** surface closes while buffered (drop, inbox floor holds); multiple queued (FIFO order preserved); ordering (main-actor serialization between deliver + state-transition); dedupe-by-id (block preserved verbatim → receiver still dedupes; double-delivery via pull+later-flush tolerated by the existing receiver-dedup contract); unknown-forever surfaces (push disabled, pull floor delivers — documented behavior change).

### Layer 2 — receiver-pull cadence in the skill
`skills/c11/SKILL.md` mailbox section: agents should `c11 mailbox recv --drain` at the top of each turn (or every few turns) as the robust floor that works even when push is buffered/unavailable. Then `scripts/sync-installed-skills.sh c11` (HARD RULE). Update `docs/c11-mailbox-guide.md` to describe prompt-gated delivery + buffer/flush + freshness window.

### Tests (c11LogicTests target; file in c11Tests/ on disk like the other Mailbox tests)
`MailboxStdinBufferTests.swift`: decide() per-state; buffer→flush FIFO; freshness-window expiry; per-surface cap eviction; removeSurface/retainOnly; empty-drain no-op. Plus extend `StdinHandlerFormattingTests` for the `.buffered` deliver outcome. Window/PTY behavior itself is the live dogfood gate, not unit-testable.

### Validation
Tagged build `./scripts/reload.sh --tag c11-144`; recipient surface with `mailbox.delivery=stdin`; fire mid-build + mid-vim → confirm no corruption + flush at next prompt; record whether direct push into a live agent corrupts. Screenshots/read-screen evidence. Tear down tagged build; never touch prod c11.
