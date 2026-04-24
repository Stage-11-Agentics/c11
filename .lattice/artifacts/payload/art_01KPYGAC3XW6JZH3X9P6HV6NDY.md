# Design Review: c11 Inter-Agent Messaging Primitive

## 1. Architectural coherence

The filesystem-first contract is the strongest part of the design. Sections 1 and 3 correctly identify that a primitive for agents should be inspectable, scriptable, and independent of an SDK. A shared `_outbox/` plus per-surface inboxes gives c11 a Unix-shaped contract that bash, agents, test harnesses, and future tooling can all use. The socket-for-streams split also holds: `mailbox watch` is the one operation that naturally requires a long-lived connection, while send/recv/configure can remain plain file I/O.

The dispatcher scope in sections 1 and 2 is mostly right, but "stateless" is overstated. The dispatcher cannot be truly stateless if it must quarantine malformed envelopes, dedupe repeated fsevents, garbage-collect stale `.tmp` files, update `_topics.json`, maintain watch streams, bump badges, and possibly retry or record handler failures. The right boundary is not "stateless"; it is "no business protocol state." c11 should own transport state, delivery attempts, durability, diagnostics, and cleanup. Agents should own workflows, acks, schemas, and body semantics.

PTY injection as the default is useful but less universal than the design implies in sections 2, 5, 6, and 10. Claude Code, Codex, and Kimi may parse XML-like tags well once the bytes are accepted as prompt input, but terminal TUIs are not just line-oriented stdin consumers. They may be in alternate screen mode, raw mode, mid-paste bracket handling, using multiline editors, waiting for a confirmation prompt, or running a child process such as `npm test`, `vim`, `less`, or a shell command that will receive the injected block instead of the agent. Bare bash REPLs are worse: `<c11-msg ...>` is shell syntax, not a message, and can produce confusing errors or accidental redirections unless delivered only at a prompt with enough escaping.

The abstraction leaks at the exact phrase "the PTY is the queue" in sections 5 and 6. The PTY is a byte stream into whatever process currently owns the terminal, not an agent mailbox. It offers buffering, but not semantic ownership, parse boundaries, idempotence, backpressure, retry visibility, or knowledge that the agent is ready to receive. I would still ship `stdin` as a default for known agent surfaces, but not as a universal default for "any TUI." The manifest default must be surface-type-aware, and `stdin` should be opt-in or auto-selected only for agent terminal profiles c11 can identify.

## 2. Failure modes and edge cases

Concurrent writes to `_outbox/` are acceptable only if file names are collision-resistant and the dispatcher treats rename as the publish boundary. Section 3 uses ULIDs, which is fine, but the schema should require globally unique IDs and define collision behavior. If two files with the same id appear, c11 should quarantine the later one or suffix the inbox copy path without pretending they are the same message.

Fsevent misses are acknowledged in section 11 and 12, but this needs to be a v1 requirement, not a footnote. A periodic sweep of `_outbox/*.msg` is mandatory. The dispatcher should also be idempotent because fsevents can coalesce or repeat. "Event noticed" and "file successfully dispatched" should be decoupled by a durable dispatch marker or atomic move into an internal `_processing/` directory.

Recipient crashes mid-PTY-write expose the weakness of "handler failures are logged, not fatal" from section 2. The durable inbox copy should happen before handler execution, as shown, but the message status must record that `stdin` delivery failed or was partial. Otherwise the operator sees an inbox file and maybe a badge but cannot tell whether bytes reached the recipient. Partial PTY writes should be treated as handler failure with bytes-written diagnostics.

Malformed envelopes should never clog `_outbox/`. Section 3's `_rejected/<id>.msg` plus `.err` is the right direction. Add strict caps: max envelope bytes, max body bytes for inline PTY delivery, max attribute lengths, valid UTF-8 policy, allowed field names, and max recipient fan-out. Oversized bodies should not be injected into PTYs. The future `--via-ref` mentioned in section 11 should become part of v1 if inline bodies are capped.

A literal `</c11-msg>` in the body is only safe if escaping is unambiguous and mandatory. Section 0 says c11 XML-escapes `<`, `>`, and `&`, which prevents closing-tag injection in the PTY format. The design must also specify that attributes are escaped, control characters are rejected or encoded, and receivers must not parse raw body text before unescaping. A JSON envelope body can contain any text; only the PTY projection is escaped.

Race with recipient shutdown needs a defined outcome. If the surface disappears after recipient resolution but before inbox copy, quarantine or mark undeliverable. If it disappears after inbox copy but before PTY write, keep the inbox copy and record handler failure. Do not remove `_outbox` before all recipient inbox copies have either succeeded or been durably rejected.

A writer crash between `.tmp` and rename is harmless only with garbage collection. Section 12 mentions stale `.tmp` cleanup; make it required and conservative. Never parse `.tmp`. Sweep `.tmp` older than a threshold into `_abandoned/` or delete with a debug log.

Clock skew should not affect transport ordering. `ts` is sender-declared metadata, useful for humans but not ordering. Use file discovery order plus ULID lexicographic order as a weak display heuristic, and assign a dispatcher `received_at` or monotonically increasing per-recipient sequence when copying to inboxes.

## 3. Drift risk

Section 3's drift-prevention rules are directionally right, but prose rules do not enforce a contract. "One envelope-builder library" helps the CLI, but raw file writers will not use it. The real enforcement point is dispatcher validation plus parity tests.

I would require a checked-in JSON Schema for envelope v1, golden fixtures for valid and invalid envelopes, and integration tests that publish the same logical message through CLI and raw file write and then compare the resulting inbox envelope, PTY projection, watch output, rejection behavior, and diagnostics. Property-based tests are useful around escaping, unknown fields, missing fields, fan-out, and size limits. CI should also fail if CLI help advertises behavior that has no raw-envelope equivalent, but that lint will be imperfect.

The realistic creep path is "ergonomics." Someone adds `c11 mailbox send --urgent --notify --retry 3`, implemented in CLI code because it is faster. Then the dispatcher starts relying on fields only the CLI emits, or the CLI performs preflight checks that raw writers cannot reproduce. Another creep path is output formatting: TOON and watch streams grow richer than the on-disk envelope, and agents learn the richer CLI behavior instead of the filesystem contract. The antidote is to treat the envelope schema and mailbox directory layout as a public API with fixtures, versioning, and compatibility tests.

## 4. Missing concerns

Security is underdeveloped. Section 1 says `$C11_STATE` is mode 700, which handles cross-user access on a local machine, but not intra-workspace trust. "Any surface can send to any surface" is powerful and dangerous. A compromised terminal, random script, or accidental shell command can inject instructions into a high-privilege agent. At minimum, manifests need opt-out, allow/deny lists, and a way to disable stdin delivery from untrusted senders. `exec` and `webhook` should not ship until there is a clear permission model.

Observability needs first-class design. The operator will ask, "Where did my message go?" The system needs message status transitions: accepted, rejected, routed, copied, handler_started, handler_succeeded, handler_failed, watched, expired. A `c11 mailbox trace <id>` command and a `_logs/` or `_status/` structure would save hours of debugging. Sidebar badges are not enough.

Schema evolution needs more than `"version": "1"`. Define semantic version handling, unknown-field policy, required field rules, reserved namespaces, and extension keys. I would allow unknown top-level keys only under `"x"` or `"ext"` to avoid accidental future conflicts.

Delivery semantics are currently implicit. The design should say v1 is durable-at-least-once to inbox, best-effort to handlers. If the dispatcher crashes after copying to an inbox but before removing `_outbox`, duplicates are possible unless there is a dispatch ledger. If a handler partially succeeds, the inbox still contains the message and status records the partial failure.

Backpressure is missing. A slow-draining recipient can accumulate inbox files and PTY bytes. Define per-surface inbox limits, max fan-out, max active watch subscribers, and what happens when limits are exceeded. Ordering also needs a sober statement: preserve per-sender order only if ULID/write order allows it and dispatcher processes serially; across senders no total semantic order is guaranteed.

## 5. Over-engineering

Cut TOON from v1. Section 3's TOON support is plausible later, but it has no bearing on the core primitive and introduces spec pinning, parser expectations, and another test matrix. JSON/NDJSON is good enough until the mailbox works.

Cut `exec` and `webhook` from v1. Section 2 correctly labels them future-compatible. They are high-value, but they multiply security, failure semantics, retries, environment handling, and observability requirements. Do not let them define v1.

Topic discovery is useful but can be slimmer. Keep `subscribe` and topic fan-out if coordination is a goal, but defer `_topics.json` descriptions, traffic-derived emergent registry, and TOON output. Manifest-driven delivery is load-bearing because it prevents PTY injection into hostile contexts. The handler registry is load-bearing only as an internal switch over `stdin`, `silent`, and `watch`; a public extensible registry is speculative.

`--via-ref` should move the other direction: from future opt-in to v1 safety valve if the design permits logs and traces as message bodies. Inline PTY delivery without a size/ref story is the bigger v1 risk.

## 6. Alternative architectures worth considering

Named pipes per recipient are worse as the primary contract. They are stream-oriented, fragile across restarts, harder to inspect, and awkward for offline delivery. They might be useful as an implementation detail for watch, but not as the mailbox.

SQLite as the message store is the strongest alternative. It would solve atomicity, queries, ordering, dedupe, status transitions, and observability better than loose files. It loses the four-line bash story, though not completely: `sqlite3` is scriptable but less universal than `cat > file && mv`. If c11 wants a serious durable broker, SQLite is better. If the core value is transparent agent participation, the filesystem design is better, provided it adds a dispatch ledger/status files.

A sidecar daemon per surface is too heavy and violates c11's host-not-configurator principle. It improves readiness detection and handler control, but creates lifecycle and installation problems.

Unix domain sockets per surface are good for live capable agents, bad for cold durability and hand-written scripts. They also require every participant to speak a protocol. This design is better for an agent workspace primitive.

gRPC is wrong for v1. It adds schemas, generated clients, version negotiation, and a service mindset where the design wants a local filesystem contract.

Redis or an external broker is operationally wrong. It solves messaging by adding dependency management, security surface, and failure modes that do not belong inside a local terminal multiplexer.

## 7. The three gating decisions

### (a) Envelope JSON schema

Use a strict v1 schema:

Required: `version`, `id`, `from`, `ts`, `body`, and at least one of `to` or `topic`.

Recommended optional: `reply_to`, `in_reply_to`, `urgent`, `ttl_seconds`, `content_type`, `body_ref`, `attrs`, `ext`.

Rules: `version` is integer `1` or string `"1"` but pick one before implementation; I prefer integer. `id` must be ULID-like but treated as opaque. `from` and `to` are surface handles or stable aliases with documented character limits. `topic` is a dotted token with glob matching only in subscriptions, not in published topic names. `body` is UTF-8 string and may be empty only if `body_ref` exists. Unknown top-level fields are rejected except under `ext` to keep evolution deliberate.

### (b) PTY wire-format tag name

Use `<c11-msg>`. It is short, visually distinctive, and already aligned with the doc. Avoid `<c11:msg>` because namespace syntax implies real XML namespace handling that the design does not want. `<c11-message>` is more readable but longer and more expensive in the exact path where token and terminal noise matter. The escape rules matter more than the name.

### (c) v1 handler set

Ship `stdin`, `silent`, and `watch` only. Do not ship `exec` in v1. `exec` is a privilege boundary disguised as convenience. It needs allowlists, environment policy, timeout/kill behavior, stdout/stderr capture, retry semantics, and UI affordances before it is safe. The v1 should prove the mailbox, routing, PTY projection, watch stream, and diagnostics first.

## 8. Top 3 things to fix before writing code

1. Replace "the PTY is the queue" with explicit delivery semantics: durable-at-least-once inbox delivery, best-effort handler delivery, mandatory status/trace records, and no claim that PTY buffering equals message queuing.

2. Define the v1 envelope schema, validation, size limits, escaping rules, and rejection/quarantine behavior before implementing the CLI. This is the public API.

3. Make reliability and observability v1 requirements: periodic `_outbox` sweep, idempotent dispatch, stale `.tmp` cleanup, per-message trace, and visible handler failure diagnostics. Without these, the first missed fsevent or partial PTY write will be nearly impossible to debug.
