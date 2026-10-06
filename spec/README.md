# Event Envelope Spec

The c11 events stream is a per-instance NDJSON log, one event per line, written to:

```
~/Library/Application Support/c11/events/events-<instance>.ndjson
```

where `<instance>` is the per-process instance id (e.g. `com.stage11.c11-12345`). Each running c11 process owns its own file; when a file grows past the rotation threshold it is renamed to `events-<instance>.ndjson.1` and a fresh `.ndjson` is opened. One `EventEnvelope` (`Sources/Events/EventEnvelope.swift`) serializes to exactly one line.

Two schema versions exist. Each line's `v` field names the schema it validates against:

| `v` | Schema | Fixtures | Written by |
|---|---|---|---|
| `2` | `event-envelope.v2.schema.json` | `fixtures/events-v2/` | c11 today |
| `1` | `event-envelope.v1.schema.json` | `fixtures/events/` | earlier c11 builds |

Old logs are never rewritten, so a reader meets both versions in the same directory. Readers accept v1 and v2 lines; the helpers at the bottom of `EventEnvelope.swift` (`canonicalType`, `panelRef`, `areaRef`, `callerPanelId`, `lifecyclePanel`, `canonicalScope`) do the mapping.

### v1 → v2

| v1 | v2 |
|---|---|
| envelope `surface` | envelope `panel` |
| envelope `pane` | envelope `area` |
| type `surface.created` | `panel.created` |
| type `surface.closed` | `panel.closed` |
| type `tab.input_sent` | `panel.input_sent` |
| `metadata.changed` scope `surface` / `pane` | `panel` / `area` |
| payload `caller_tab_id` / `caller_surface_id` | `caller_panel_id` |
| `lifecycle.changed` payload `tab` | `panel` |
| `v: 1` | `v: 2` |

Every other type and payload key is unchanged. `c11 events tail --filter type=<type>` compares the v2 spelling of both the filter and each line, so either spelling of a renamed type matches lines of either version.

In each fixture directory, `valid-*.json` must all parse successfully and `invalid-*.json` must each violate exactly one documented rule. These fixtures drive:

- `tests_v2/test_events_parity.py`: asserts every `valid-*` validates and every `invalid-*` fails against its version's schema, validates a serialized log line by line (schema picked by `v`), then checks CLI vs raw-file parity for `c11 events tail` when a live instance is available.

## What the schema enforces

- `seq` is an integer ≥ 0, the monotonic per-instance sequence number.
- `ts` is an RFC3339 / ISO-8601 UTC timestamp with `Z` suffix and optional fractional seconds.
- `type` is one of the closed enum: `panel.created`, `panel.closed`, `workspace.selected`, `workspace.switch_blocked`, `workspace.reordered`, `metadata.changed`, `liveness.derived`, `waiting.entered`, `waiting.left`, `lifecycle.changed`, `flag.raised`, `flag.lowered`, `flag.suppressed`, `flag.unsuppressed`, `mailbox.accepted`, `panel.input_sent`, `mailbox.delivered`, `conversation.resume.mode`, `conversation.resume.decision`, `hang.precursor`, `ask.opened`, `ask.closed`, plus the stream-control markers `log.opened`, `log.rotated`, `log.dropped`. (v1 spells the three renamed types as in the table above.)
- `instance` is a non-empty string.
- `v` is the integer `2` (`1` in the v1 schema).
- `workspace`, `panel`, `area` are optional UUID strings (`workspace`, `surface`, `pane` in v1).
- `payload` is an optional, free-form object (any keys); its shape is keyed by `type`. `mailbox.accepted` carries `{id, from, body, body_ref?, to?, topic?, reply_to?, in_reply_to?, urgent?, truncated?}`, `panel.input_sent` carries `{caller_panel_id, caller_title, target_title, kind, text, bytes, submitted, truncated?, queued?}`, and `mailbox.delivered` carries `{id, recipient, via}`. `via` is `push`, `drain`, or `inbox`; `queued` marks input accepted before the target panel attached.
- `seq`, `ts`, `type`, `instance`, `v` are required; `additionalProperties: false` at the top level.

## What the schema does NOT enforce

- **`seq` monotonicity across lines.** The schema validates one line in isolation; gap-free, strictly-increasing seq within a file is the writer's contract (`EventLog`, serial queue).
- **`instance` uniqueness** across processes, and the seq namespace being per-instance.
- **Ref UUIDs matching live panels/workspaces/areas.** `workspace` / `panel` / `area` are validated as UUID strings only; whether they name an entity that currently exists lives in the emitter/consumer.
- **`ts` ordering.** `ts` is captured on the emitting thread and is only approximately monotonic; it may invert relative to `seq` across racing threads.

**`seq` (not `ts`) is the ordering oracle.** Consumers order by `seq`, which the writer assigns on its serial queue so file order and seq order always agree. Those cross-line and liveness invariants live in `Sources/Events/EventEnvelope.swift` and the `EventLog` writer / `c11 events tail` reader, not the schema.

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
