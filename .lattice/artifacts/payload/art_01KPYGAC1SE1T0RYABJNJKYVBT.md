# c11 Inter-Agent Messaging — Design Review

**Reviewer:** Claude Sonnet 4.6  
**Date:** 2026-04-23  
**Doc reviewed:** `docs/c11-messaging-primitive-design.md`

---

## 1. Architectural Coherence

The fs-first + socket-for-streams split holds up. The shared outbox with atomic `.tmp → .msg` rename is a well-understood Unix pattern. Restricting the socket to live streams only is the right call — it keeps the send path offline-safe and testable without a running c11.

**Two coherence problems need fixing:**

The design says "The PTY is the queue" (§6, §11). This is wrong. The PTY has a kernel ring buffer of ~4 KB. Under load, writes to a full PTY buffer *block*. If the dispatcher writes to the PTY synchronously and the recipient is busy, the dispatcher stalls — potentially blocking the fsevent processing loop for every other surface. The PTY is a delivery channel, not a queue; the inbox directory is the queue. The slogan misleads about the actual failure behavior.

The dispatcher is called "stateless" in §1. It isn't. It maintains: (a) active watch subscribers on the socket, (b) the topics registry `_topics.json`, (c) sidebar badge counts. "Stateless" here seems to mean "no per-message in-memory state," which is true, but the framing will confuse implementers about what state they need to protect.

**PTY injection across TUI types.** For Claude Code and Codex, this actually works — both leave stdin open for user input, and injected bytes will appear at the next prompt read. For raw-mode TUIs running tight loops, writes may sit in the kernel buffer indefinitely if there are no read() calls scheduled. The design handles vim correctly (silent mode), but there's an implicit assumption that any surface with `delivery: ["stdin"]` is polling stdin. That assumption needs to be surfaced explicitly, not assumed.

The `<c11-msg>` injection into Claude Code's PTY presents a semantic subtlety: the agent sees these bytes as human-turn input, not system-prompt content. The skill (§10) handles this correctly, but it means message priority is entirely LLM-discretionary — `urgent="true"` is advice, not a preemption signal. That's fine for v1 but should be explicit in the design rather than buried in the skill excerpt.

---

## 2. Failure Modes and Edge Cases

**Concurrent writes from many senders.** Fine. Each sender writes to a unique ULID-named file; POSIX rename is atomic within a local filesystem. No races.

**fsevent misses under load.** The doc acknowledges this and proposes a periodic sweep, but doesn't specify: how frequent, what triggers it, or what the window is. FSEvents on macOS coalesces rapid events by design. Under burst traffic, the sweep cadence determines your worst-case delivery latency gap. This needs a concrete number before implementation — 5 seconds is probably right, 60 seconds is too slow for interactive use.

**Recipient crashes mid-PTY-write.** A write() to a closed PTY master returns EIO/EPIPE. The inbox copy already happened, so the message is durable. But the design doesn't say what c11 does with the EIO — retry, log, emit to operator? The envelope sits in the inbox unacknowledged, so a recovering surface will find it on next recv. That's actually the correct behavior for at-least-once, but it's not stated anywhere.

**Malformed or oversized envelopes.** Routed to `_outbox/_rejected/` with a sibling `.err`. Good. But "malformed" is undefined — no schema, no field list, no size limit. This needs to be specified before the dispatcher is written, not discovered during implementation.

**Body containing `</c11-msg>`.** The design specifies escaping `<`, `>`, `&` as standard XML entities (§ "Proposed wire format"). A literal `</c11-msg>` in the body becomes `&lt;/c11-msg&gt;`. This is correct and injection-safe. Call it out explicitly in the security section — it's non-obvious that this is a deliberate defense.

**Race between write and surface shutdown.** If a surface shuts down between fsevent firing and inbox copy, the inbox directory may be partially torn down. The design doesn't specify whether surface shutdown deletes the inbox. If it does, there's a message-loss window. The inbox should outlive the surface session (per the §12 retention default of 7 days) — making this explicit prevents the teardown logic from doing the wrong thing.

**Writer crashes between `.tmp` and rename.** Leaves a stale `.tmp`. §12 proposes GC after N minutes. N is unspecified. 5 minutes is a reasonable default; pick one.

**Clock skew.** `ts` is sender-attested. It is not authoritative for ordering — that's determined by fsevent receipt order. The field is metadata for human debugging, not a sort key. Say this explicitly so agents don't sort their inbox by `ts` and get confused.

---

## 3. Drift Risk

The seven rules (§3) are the best-thought-out part of the design. The structural rules (one envelope builder, validation at dispatch, no CLI-only features) are solid if enforced by code organization rather than documentation.

The realistic drift path isn't a big design decision — it's a sequence of small conveniences:

1. Someone adds `c11 mailbox send --reply` that auto-fills `reply-to` from `$C11_SURFACE_ID`. Technically reachable from file writes (env var is available), but no file-write example shows it. The file-write path becomes second-class in practice.
2. Rate limiting gets added to the CLI for safety. File writers are unthrottled.
3. The dispatcher validator is updated to require a new field. The CLI auto-fills it. File writers start getting rejected.

The "CLI is thin — counted in lines" rule (rule 7) is a smoke alarm but not a circuit breaker. Without a CI test that sends the same logical payload via both paths and asserts byte-equivalent inbox output, drift is invisible until someone hits it in production.

**Recommendation before coding:** Write one integration test that parameterizes over both send paths (CLI and raw file write) and asserts identical inbox state. This test is the actual enforcement mechanism. The rules in §3 are the policy; the test is the lock.

---

## 4. Missing Concerns

**Observability.** The biggest gap in the design. If message `01K3A2B7X` was never received by surface `watcher`, how do I debug it? Right now: check if the file is in `_outbox/` still, check if it's in `watcher/` inbox, check `_rejected/`. This requires filesystem spelunking with the right timing. Add a structured dispatch log: an append-only NDJSON file at `$C11_STATE/mailboxes/_dispatch.log` with entries `{ts, id, from, to_resolved, handlers, outcome}`. One line per dispatch event. This costs almost nothing to implement and makes every debugging question answerable.

**Delivery semantics.** The design doesn't commit to at-most-once vs at-least-once. The periodic sweep that re-scans `_outbox/` for missed fsevents can re-dispatch already-dispatched envelopes if cleanup didn't complete before the crash. That's at-least-once. At-least-once requires receivers to be idempotent (deduplicate by `id`). At-most-once requires the cleanup step to be atomic with dispatch — which isn't achievable here. Pick at-least-once explicitly, document it, and tell agents to deduplicate by `id`. This is a one-sentence design decision with significant implementation consequences.

**Backpressure.** No mechanism exists for a slow recipient. 1000 messages per second to a busy surface means 1000 attempted PTY writes, each blocking if the kernel buffer is full. The fsevent watcher processes events on a queue — what happens when that queue fills? This needs a dispatcher design that handles PTY writes asynchronously (enqueue write, fire-and-forget with timeout) rather than blocking the main dispatch loop.

**Schema evolution.** The `version` field is named but not specified. "Additive changes are forward-compatible" — this is the right principle, but "additive" needs definition: adding optional fields is additive; adding required fields is not; changing the semantics of existing fields is a breaking change regardless of field presence. Write a one-page compatibility matrix before implementation.

**Security and `exec` handler.** The exec handler (future) runs user-specified commands with the envelope on stdin. If the command string passes envelope fields as shell arguments without sanitization, that's command injection. Flag this prominently in the `exec` handler spec when it ships. The webhook handler carries similar risks if envelope fields appear in URLs or headers without encoding.

**Message ordering guarantees.** Explicitly not guaranteed across senders. Say so. macOS FSEvents does not guarantee event ordering across multiple files created in rapid succession. Agents that depend on order must coordinate themselves (reply chains, explicit sequence numbers in the body).

---

## 5. Over-Engineering

**Cut from v1:**

- **TOON.** Token savings are real but the spec is a 3.0 working draft. Agents may not parse it reliably. JSON is what every shell tool speaks. Add TOON when there's evidence of actual token pressure from real usage. Pre-optimizing for this in v1 adds surface area with speculative payoff.

- **`_topics.json` and topic discovery.** Useful, but non-trivial — c11 must rebuild it on manifest changes and message flow, which adds state management complexity. For v1, agents can read manifests directly. Ship topic discovery in v1.1 once the send/recv primitive is battle-tested.

- **`advertises` in manifests.** The `subscribe` glob is load-bearing. `advertises` with descriptions is a developer ergonomic that can ship later without breaking anything.

- **`--via-ref`.** Mentioned in §11 costs. Don't design or ship this in v1.

**Keep:**

- `stdin`, `silent`, `watch` handlers (load-bearing trio)
- Manifest with `delivery` + `subscribe` only
- `_rejected/` for malformed envelopes
- `.tmp → .msg` atomicity
- Periodic sweep for missed fsevents

**Ship `exec` in v1** (addressed in §7c below).

---

## 6. Alternative Architectures

**Named pipes per recipient.** Solves PTY injection for raw-mode TUIs; named pipes are directly readable without an intermediate dispatcher. But: no persistence across process restarts, awkward lifecycle management for dynamic surface creation, no "filesystem is inspectable" property. Weaker than the current design.

**SQLite as message store.** Better transactions and querying. Loses the "any process can participate with cat + mv" property — readers need a SQLite library or CLI. Too heavy; wrong tradeoff for a primitive.

**Sidecar daemon per surface.** Cleanly handles backpressure and per-surface queuing. But: c11 core *is* the sidecar. Adding another layer doubles the lifecycle management problem.

**Unix domain sockets per surface.** Faster, no PTY conflicts, no raw-mode issues. But: requires active listener (no buffering across restarts), loses filesystem inspectability. Strictly worse durability story.

**gRPC, Redis, external broker.** Wrong layer entirely. This is a local multiplexer for a single operator, not a distributed system. The complexity budget doesn't include a broker.

**Verdict.** The current design is correct. The fs-first approach is the right primitive for local, single-machine, multi-process coordination. The main alternative worth noting is named pipes for *delivery only* (not storage), but the current design's inbox files give you durability without adding complexity.

---

## 7. The Three Gating Decisions

### (a) Envelope JSON schema

Required fields: `id` (ULID string), `version` ("1"), `from` (surface handle string), `ts` (ISO-8601 UTC string), `body` (string, must not be null or absent), plus at least one of `to` (surface handle) or `topic` (dot-separated string).

Optional fields: `reply-to` (surface handle), `in-reply-to` (ULID), `urgent` (boolean — not string `"true"`; use actual JSON boolean), `ttl` (integer seconds, for auto-expiry future support).

Extensibility: additive optional fields are ignored by old dispatchers. Breaking changes require `version` bump. No arbitrary sender-defined fields that change dispatch behavior — dispatch semantics must be deterministic from the required fields above.

The PTY tag attributes should carry a strict subset: `from`, `topic`, `id`, `ts`, `reply-to`, `in-reply-to`, `urgent`. Do not expand attributes beyond what agents need to parse the message inline.

### (b) PTY wire-format tag name

**Use `<c11-msg>`.** Shorter means fewer injected tokens per message. The brand is "c11" (not "c11-message"), and `msg` is the right noun. Namespaced `<c11:msg>` requires namespace-aware XML parsing, buys nothing in this context, and introduces a parsing edge case that agents may handle inconsistently. `<c11-message>` is just `<c11-msg>` with four extra characters and no semantic benefit. Lock it in now — this is the one decision that's actually expensive to change post-ship.

### (c) v1 handler set

**Ship `stdin`, `silent`, `watch`, and `exec`.** Four, not three.

`exec` is simple to implement (spawn a configured process with envelope on stdin, log result, don't retry). It's what makes `silent` surfaces useful to operators — without it, a silent surface can only self-poll or run a persistent `watch` sidecar, both of which are heavier than a one-shot exec hook. Notification-center pings, audio cues, log appends, and build kicks are the most immediately valuable operator workflows, and all of them require `exec`. The failure semantics are already specified (independent, logged, non-fatal). Include it.

Do not ship `webhook` (network dependency, auth complexity), `file-tail` (exec + tee), or `signal` (edge case) in v1.

---

## 8. Top Three Things to Fix Before Writing Code

**1. Commit to at-least-once delivery and document it.**

The periodic sweep makes at-most-once unachievable (cleanup isn't atomic with dispatch). Pick at-least-once explicitly. Document that receivers should deduplicate by `id`. Design the cleanup logic around this: envelopes are removed from `_outbox/` only after all handlers complete or explicitly fail. A crash mid-dispatch leaves the envelope in `_outbox/`; the sweep re-delivers it. That's the contract.

**2. Add a dispatch log before implementation, not after.**

A structured `_dispatch.log` (append-only NDJSON: `{ts, id, from, to_resolved, handlers, outcome}`) is the only way to debug the two-interface model without filesystem timing luck. Every "why didn't X receive Y" question becomes answerable. This is one file append per dispatch event — negligible cost, enormous debugging value. Design it now so every handler implementation writes to it from day one, rather than retrofitting it after the first production incident.

**3. Specify PTY write failure semantics for the `stdin` handler.**

"Write to PTY" is one write() call on the master fd. It can block (buffer full), fail with EIO (process dead), or fail with EPIPE. The design is silent on all three. Before any code: specify that the dispatcher performs PTY writes asynchronously with a timeout (suggested: 500 ms), logs failure, and leaves the envelope in the inbox for self-retrieval. This prevents a slow or dead recipient from blocking the fsevent processing loop for every other surface in the workspace — which is the most operationally damaging failure mode for a multi-surface coordinator.
