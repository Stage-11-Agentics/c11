# Event Envelope Spec

`event-envelope.v1.schema.json` is the source of truth for the c11 events-stream envelope format (v1). The stream is a per-instance NDJSON log — one event per line — written to:

```
~/Library/Application Support/c11/events/events-<instance>.ndjson
```

where `<instance>` is the per-process instance id (e.g. `com.stage11.c11-12345`). Each running c11 process owns its own file; when a file grows past the rotation threshold it is renamed to `events-<instance>.ndjson.1` and a fresh `.ndjson` is opened. **Every line must validate against `event-envelope.v1.schema.json`.** One `EventEnvelope` (`Sources/Events/EventEnvelope.swift`) serializes to exactly one line.

`fixtures/events/valid-*.json` must all parse successfully. `fixtures/events/invalid-*.json` must all violate exactly one documented rule. These fixtures drive:

- A Swift validator unit test (mirrors `c11Tests/MailboxEnvelopeValidationTests.swift`) — asserts every `valid-*` validates and every `invalid-*` fails.
- `tests_v2/test_events_parity.py` (to be created) — CLI vs raw-file parity test for `c11 events tail`.

## What the schema enforces

- `seq` is an integer ≥ 0 — the monotonic per-instance sequence number.
- `ts` is an RFC3339 / ISO-8601 UTC timestamp with `Z` suffix and optional fractional seconds.
- `type` is one of the closed v1 enum: `surface.created`, `surface.closed`, `workspace.selected`, `metadata.changed`, `liveness.derived`, `waiting.entered`, `waiting.left`, `mailbox.accepted`, `mailbox.delivered`, `conversation.resume.mode`, `conversation.resume.decision`, plus the stream-control markers `log.opened`, `log.rotated`, `log.dropped`.
- `instance` is a non-empty string.
- `v` is the integer `1`.
- `workspace`, `surface`, `pane` are optional UUID strings.
- `payload` is an optional, free-form object (any keys); its shape is keyed by `type`.
- `seq`, `ts`, `type`, `instance`, `v` are required; `additionalProperties: false` at the top level.

## What the schema does NOT enforce

- **`seq` monotonicity across lines.** The schema validates one line in isolation; gap-free, strictly-increasing seq within a file is the writer's contract (`EventLog`, serial queue).
- **`instance` uniqueness** across processes, and the seq namespace being per-instance.
- **Ref UUIDs matching live surfaces/workspaces/panes.** `workspace` / `surface` / `pane` are validated as UUID strings only; whether they name an entity that currently exists lives in the emitter/consumer.
- **`ts` ordering.** `ts` is captured on the emitting thread and is only approximately monotonic; it may invert relative to `seq` across racing threads.

**`seq` (not `ts`) is the ordering oracle.** Consumers order by `seq`, which the writer assigns on its serial queue so file order and seq order always agree. Those cross-line and liveness invariants live in `Sources/Events/EventEnvelope.swift` and the `EventLog` writer / `c11 events tail` reader — not the schema.

# Mailbox Envelope Spec

`mailbox-envelope.v1.schema.json` is the source of truth for the c11 inter-agent mailbox envelope format (v1). Every envelope in `$C11_STATE/workspaces/<ws>/mailboxes/_outbox/*.msg` must validate against this schema.

`fixtures/envelopes/valid-*.json` must all parse successfully. `fixtures/envelopes/invalid-*.json` must all violate exactly one documented rule. These fixtures drive:

- `c11Tests/MailboxEnvelopeValidationTests.swift` — Swift validator unit tests.
- `tests_v2/test_mailbox_parity.py` — CLI vs raw-file parity test.

See `docs/c11-messaging-primitive-design.md` §3 for the full envelope contract and `docs/c11-13-cmux-37-alignment.md` for the alignment with CMUX-37.

## What the schema enforces

- `version` is the integer `1`.
- `id` is a 26-char Crockford base32 ULID.
- `from` is a non-empty string up to 256 chars.
- `ts` is an RFC3339 UTC timestamp with `Z` suffix.
- `body` is a string up to 4096 chars and must be empty when `body_ref` is set.
- At least one of `to` or `topic` is required.
- `topic` is a dotted token `^[A-Za-z0-9_][A-Za-z0-9_.\-]*$`.
- `body_ref` is an absolute path starting with `/`.
- `ttl_seconds` is an integer ≥ 1.
- `ext` is an object; `additionalProperties: false` everywhere else.

## What the schema does NOT enforce

- Byte-length of `body` (chars vs bytes differ for non-ASCII); the Swift validator enforces 4096 bytes.
- ULID monotonicity within a surface.
- `body_ref` file existence.
- `from` / `to` / `reply_to` matching a live surface in the workspace.

Those live in `Sources/Mailbox/MailboxEnvelope.swift` or the dispatcher.
