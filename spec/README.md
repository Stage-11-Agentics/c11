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
