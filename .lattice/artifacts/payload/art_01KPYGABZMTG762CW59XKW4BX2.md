# c11 Messaging Design — Merged Review Synthesis

**Reviewers:** Clear Claude Sonnet 4.6 + Clear Codex
**Design reviewed:** `docs/c11-messaging-primitive-design.md`
**Source reviews:**
- `/tmp/c11-messaging-review-claude.md`
- `/tmp/c11-messaging-review-codex.md`

---

## Strongly endorsed by both — lock in before coding

### Framing fixes

1. **Kill "the PTY is the queue."** Both reviewers flag this as misleading. Claude is concrete: the PTY has a ~4 KB kernel ring buffer; a write() to a full buffer *blocks*. If the dispatcher writes synchronously, a slow recipient stalls the fsevent loop for every other surface. The **inbox directory is the queue**; the PTY is a byte-stream delivery channel that can fail or block.

2. **Drop "dispatcher is stateless."** The dispatcher owns: watch-subscriber state, `_topics.json` (if kept), sidebar badge counts, fsevent dedupe, quarantine, stale-tmp GC. Right framing: *"no business protocol state."* It owns transport state.

3. **Commit to at-least-once delivery explicitly.** The periodic sweep makes at-most-once unachievable (cleanup isn't atomic with dispatch). Pick at-least-once, document it, tell agents to **dedupe by `id`**. A crash mid-dispatch leaves the envelope in `_outbox/`; the sweep re-delivers; receivers handle duplicates. That's the contract.

### Reliability requirements (promote from open questions to v1 mandatory)

4. **Periodic `_outbox/` sweep.** Not a footnote. Cadence: ~5 seconds (Claude's lean). Belt-and-suspenders for missed fsevents.

5. **Dispatcher must be idempotent.** fsevents coalesce and can repeat. Use an atomic move to `_processing/` as the dispatch marker, so a replay doesn't double-deliver.

6. **Stale `.tmp` GC.** 5-minute default. Sweep into `_abandoned/` or delete with debug log. Never parse a `.tmp` file.

7. **Async PTY writes with timeout.** Claude's concrete proposal: 500 ms timeout per stdin delivery, log failure, leave envelope in the recipient's inbox for self-retrieval on next `recv`. Prevents a dead/slow recipient from stalling the dispatcher.

8. **EIO/EPIPE handling spec'd.** Closed PTY returns EIO/EPIPE. Log, leave envelope in inbox, move on. Make this explicit in the stdin-handler spec.

### Observability (promote from open question to v1 mandatory)

9. **Structured dispatch log.** Append-only NDJSON at `$C11_STATE/mailboxes/_dispatch.log`, one line per dispatch event: `{ts, id, from, to_resolved, handlers, outcome}`. Cheapest win in the design — makes every "why didn't X receive Y" question debuggable. Codex wants richer state transitions (a full state machine per message); Claude's simpler log is the right v1 and the state machine can build on top in v1.1.

### Schema as public API

10. **Lock the envelope schema before the CLI is written.** Both reviewers are emphatic — the schema is the public API, not the CLI. Checked-in JSON Schema + golden fixtures for valid and invalid envelopes. Integration tests that send the same logical payload via both paths (CLI + raw file write) and assert byte-equivalent inbox state. **This test is the actual drift enforcement mechanism** — Claude's framing: "the rules in §3 are the policy; the test is the lock."

11. **Tag name: `<c11-msg>`.** Both agree. Lock it.

12. **Body escaping handles injection attacks.** XML-escaping `<`, `>`, `&` prevents `</c11-msg>` forgery. Call this out explicitly as a security property in the design, not left implicit.

13. **Size caps mandatory.** Max envelope bytes, max inline body for PTY delivery, max attribute lengths, UTF-8 policy, max recipient fan-out. Oversized bodies rejected at dispatch, quarantined to `_rejected/`.

### Cut from v1 (both reviewers agree)

14. **TOON.** Speculative token savings. Spec is 3.0 working draft. Add in v1.1 with evidence.

15. **`_topics.json` discovery registry + `advertises` in manifests.** Discovery is useful but non-trivial (rebuild on manifest changes and message flow). Defer to v1.1. Keep manifest-level `subscribe` if topic fan-out stays v1 (see disagreement #2).

### Other

16. **Clock skew.** `ts` is sender-attested metadata, NOT an ordering field. Document this — agents should not sort inboxes by `ts`.

17. **Message ordering across senders: explicitly not guaranteed.** FSEvents doesn't guarantee ordering across multiple files. Agents that need order coordinate themselves (reply chains, seqnums in the body).

---

## Where reviewers disagree — operator decision needed

### Disagreement #1: Should `exec` ship in v1?

| | Claude | Codex |
|---|---|---|
| Verdict | **Yes, ship it** | **No, defer to v1.1** |
| Reasoning | Simple to implement (spawn process, envelope on stdin, log, no retry). Makes silent surfaces useful (notification-center, audio, log append). Failure semantics already specified. | "Privilege boundary disguised as convenience." Needs allowlists, environment policy, timeout/kill, stdout/stderr capture, retry semantics, UI affordances before safe. |

**My read:** Codex is more right. Even a simple exec handler opens a new class of attack surface (shell injection through envelope fields in command arguments). Claude waves at the failure semantics being specified, but doesn't address the security model. Shipping exec in v1 bakes in expectations before the permission model is designed. **Lean: defer to v1.1 with a proper spec.** The immediate cost is operators can't wire notification-center without writing a watch-sidecar. That's an acceptable v1 limitation.

### Disagreement #2: Topic subscribe/fan-out in v1?

| | Claude | Codex |
|---|---|---|
| Verdict | **Cut topic fan-out entirely from v1** — ship send/recv + stdin only | **Keep subscribe + fan-out, defer registry/advertises** |
| Reasoning | Simpler v1, less state for dispatcher, battle-test send/recv first | Subscribe globs in manifest are load-bearing for coordination. Fan-out is a natural consequence once manifests exist. Removing it means agents can't coordinate via topics until v1.1. |

**My read:** Codex slightly right. The v1 value prop *is* multi-agent coordination — direct `to:` only feels thin. Subscribe globs in the manifest are nearly free once you have manifests. Cut the *registry* (`_topics.json`, `advertises`, `mailbox topics describe`), keep the *mechanism* (subscribe globs + fan-out at dispatch). **Lean: keep subscribe + fan-out. Cut discovery/registry.**

### Disagreement #3: `--via-ref` / oversized-body handling

| | Claude | Codex |
|---|---|---|
| Verdict | **Don't ship in v1.** Just document size limits. | **Promote into v1 as safety valve.** Don't ship without a size-cap story. |

**My read:** Both agree there must be a size cap. They differ on whether a ref mechanism is v1. For v1, hard-cap inline body at e.g. 4 KB with rejection-to-`_rejected/` for oversized. Ship `--via-ref` in v1.1 with `exec`. **Lean: v1 = hard cap + reject; v1.1 = `--via-ref` mechanism.**

### Disagreement #4: Schema field naming style

| | Claude | Codex |
|---|---|---|
| Verdict | `reply-to`, `in-reply-to` (kebab) | `reply_to`, `in_reply_to` (snake) |

**My read:** Codex is right. snake_case is JSON convention. Kebab-case is XML/HTML-attribute convention. Envelope is JSON; PTY tag attributes can use either but snake is safer. **Lean: snake_case throughout envelope; PTY attribute names match.**

---

## Recommended v1 scope after review

**Ship:**
- Filesystem contract (`_outbox/`, per-surface inboxes, `manifest.json`)
- Atomic `.tmp → .msg` writes with 5-minute stale GC
- fsevent watcher + 5-second periodic sweep
- Atomic move to `_processing/` as dispatch marker (idempotency)
- Dispatcher with dedupe, quarantine, structured `_dispatch.log`
- Handlers: `stdin`, `silent`, `watch` (NOT `exec`)
- `stdin` handler: async PTY write with 500 ms timeout, EIO/EPIPE graceful failure
- Manifest fields: `delivery`, `subscribe` (keep fan-out)
- Envelope schema v1, locked and checked in as JSON Schema + golden fixtures
- `<c11-msg>` tag with XML-escaped body
- Hard cap on inline body size (~4 KB); oversized → `_rejected/`
- CLI + file-write parity test (drift enforcement)
- At-least-once delivery semantics documented; receivers dedupe by `id`

**Defer to v1.1:**
- `exec` handler (with proper security model)
- `webhook`, `file-tail`, `signal` handlers
- Topic discovery: `_topics.json`, `advertises`, `mailbox topics describe`
- TOON output format
- `--via-ref` for oversized bodies
- Manifest-level auth allow/deny lists
- Full dispatch state-machine beyond the log

**Out of scope:**
- Remote workspace mailbox sync
- Cross-user messaging
- Ack/receipt protocol (agents build on top)

---

## Top 5 things to fix before writing code

1. **Rewrite "the PTY is the queue" framing** throughout the doc. Inbox is the queue; PTY is the delivery channel.
2. **Lock the envelope schema as JSON Schema** with golden fixtures, before the CLI is written. Test parity between CLI and raw file-write as the drift enforcement mechanism.
3. **Add the structured dispatch log** (`_dispatch.log` NDJSON) to the v1 design now, not after the first debugging incident.
4. **Commit to at-least-once delivery semantics** explicitly. Document that receivers dedupe by `id`.
5. **Specify async PTY writes with 500 ms timeout** for the stdin handler. Spec EIO/EPIPE handling. Prevent slow-recipient stalls.
