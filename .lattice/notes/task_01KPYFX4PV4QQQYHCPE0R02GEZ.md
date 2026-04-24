# C11-13 — Inter-agent messaging primitive

**Short code:** C11-13
**Design doc:** [`docs/c11-messaging-primitive-design.md`](../../docs/c11-messaging-primitive-design.md)
**Alignment doc:** [`docs/c11-13-cmux-37-alignment.md`](../../docs/c11-13-cmux-37-alignment.md) — shared conventions with CMUX-37
**Status (2026-04-24):** Stage 0 + Stage 1 complete. Ready to start Stage 2 (vertical slice prototype).

## Goal

Ship the smallest primitive that lets agents in separate c11 surfaces coordinate without c11 imposing a protocol. Filesystem-contract-first mailbox for content. Pane metadata (CMUX-11) for config. PTY framed-text delivery for stdin agents. Pluggable delivery handlers for everything else.

## Design summary (one paragraph)

Senders write JSON envelopes to a per-workspace shared `_outbox/` directory. c11 watches via fsevents and dispatches to recipient inboxes based on pane metadata (`mailbox.delivery`, `mailbox.subscribe`). Default `stdin` handler writes an XML-style `<c11-msg>` block to the recipient's PTY **asynchronously** with a 500 ms timeout; `silent` and `watch` handlers cover non-stdin cases. Delivery is **at-least-once** — receivers dedupe by `id`. CLI is a thin convenience wrapper over file operations; agents can write envelopes directly with four lines of bash. Structured `_dispatch.log` NDJSON makes every "where did my message go?" answerable. Handlers beyond `stdin/silent/watch` (`exec`, `webhook`) deferred to v1.1 pending a security model. Full design in the attached doc.

## Work stages

### Stage 0 — Pre-code decisions — LOCKED 2026-04-23/24

- [x] Envelope schema (snake_case, version=1 int, required/optional/ext rules)
- [x] PTY tag name: `<c11-msg>`
- [x] v1 handler set: `stdin + silent + watch` (exec deferred to v1.1)
- [x] Topic subscribe/fan-out: in v1; discovery registry in v1.1
- [x] `body_ref` / `--via-ref`: in v1 as safety valve; per-workspace `blobs/` allowlist
- [x] TOON output format: deferred to v1.1
- [x] Mailbox aliases = surface names (CMUX-11 nameable-panes metadata)
- [x] Per-workspace scoping: `$C11_STATE/workspaces/<ws>/mailboxes/`
- [x] Config in pane metadata (`mailbox.*` namespace), no separate manifest.json file
- [x] CLI root: `c11 mailbox` (noun pattern matching `c11 workspace`, `c11 snapshot`, `c11 tree`)
- [x] Skill location: main `c11` SKILL.md section
- [x] Alignment addendum with CMUX-37 locked and attached to both tickets (2026-04-24)

### Stage 1 — Pressure-test — DONE 2026-04-23

- [x] Full-force review: clear claude + clear codex. Merged synthesis at `/tmp/c11-messaging-review-merged.md`, attached as artifact.
- [x] Both reviewers caught the "PTY is the queue" framing error, the stateless-dispatcher overclaim, and the need for explicit delivery semantics. All folded into the design doc.
- [x] Reliability items promoted to v1 mandatory (see Stage 2 scope below).

### Stage 2 — Vertical slice prototype (NEXT)

Goal: prove the primitive end-to-end with the smallest shippable slice — send, recv, stdin handler, parity test. No topics, no subscribe, no watch handler, no body_ref yet.

- [ ] **Schema + fixtures checked in first.** JSON Schema file at `spec/mailbox-envelope.v1.schema.json`. Golden valid and invalid envelope fixtures under `spec/fixtures/envelopes/`. Used by validator + tests.
- [ ] **Parity test before CLI.** Integration test parameterized over two send paths (raw file write vs `c11 mailbox send` CLI); asserts byte-equivalent inbox state after dispatch. This is the drift-enforcement lock (rule #6). Must pass before the CLI is considered complete.
- [ ] **Directory layout + atomic writes.** `$C11_STATE/workspaces/<ws>/mailboxes/{_outbox,_processing,_rejected,<surface-name>}` created on first send. `.tmp → .msg` atomic rename. Stale `.tmp` GC after 5 min.
- [ ] **fsevent watcher + 5 s periodic sweep.** Dispatcher reads `.msg` files from `_outbox/`, atomic-moves to `_processing/` as the dispatch marker (idempotency under fsevent replay).
- [ ] **Envelope validator at dispatch.** Schema validation, size caps (4 KB inline body), UTF-8 check, required-fields check. Failures quarantined to `_rejected/<id>.msg` with sibling `.err`.
- [ ] **`stdin` handler with async PTY write + 500 ms timeout.** EIO/EPIPE graceful failure. Failure logged to `_dispatch.log`; envelope stays in recipient inbox for self-retrieval.
- [ ] **`_dispatch.log` NDJSON.** Events: `received`, `resolved`, `copied`, `handler`, `rejected`, `cleaned`, `replayed`. Append-only. One line per event.
- [ ] **`c11 mailbox send --to <surface-name> --body <text>`** CLI — thin wrapper, <30 lines of send logic.
- [ ] **`c11 mailbox recv --drain`** CLI — thin wrapper reading from current surface's inbox dir.
- [ ] **Minimum observability CLI:** `c11 mailbox trace <id>` (greps `_dispatch.log`) and `c11 mailbox tail` (live follow).

Acceptance for Stage 2: send a message from surface A (via CLI) and surface B (via raw bash), both arrive in surface C's PTY as `<c11-msg>` blocks, both appear in surface C's inbox, both trace cleanly in `_dispatch.log`, parity test passes.

### Stage 3 — Full primitive

- [ ] `c11 mailbox configure` CLI (writes to pane metadata via existing socket path)
- [ ] `mailbox.delivery` / `mailbox.subscribe` / `mailbox.retention_days` keys wired through
- [ ] Topic fan-out: dispatcher reads all workspace surfaces' `mailbox.subscribe` globs, matches published topics, copies to matching inboxes
- [ ] `silent` handler (no-op path)
- [ ] `watch` handler + socket NDJSON stream (`c11 mailbox watch`)
- [ ] `body_ref` / `--via-ref` with per-workspace `blobs/` allowlist
- [ ] Per-surface inbox cap (1000 pending → reject to `_rejected/` with `recipient_inbox_full`)
- [ ] Processing-directory recovery on c11 start (sweep stranded `_processing/` → `_outbox/`)

### Stage 4 — Skill + docs + rollout

- [ ] Update `skills/c11/SKILL.md` with messaging section (recognition, protocol, send/recv, configure, debug)
- [ ] Update the design doc to reflect what actually shipped
- [ ] Create Lattice subtasks for each deferred handler (`exec`, `webhook`, `file-tail`, `signal`) and v1.1 features

### v1.1 backlog (informational, not this ticket)

- `exec` handler (with security model: allowlists, env policy, timeout/kill, stdout capture)
- `webhook` handler (auth, remote-workspace story)
- `file-tail` / `signal` handlers
- Topic discovery registry (`_topics.json`, `mailbox.advertises`, `c11 mailbox topics`)
- TOON output format (`--format toon` for list-shaped commands)
- Manifest allow/deny lists (`mailbox.allow`, `mailbox.deny`)

## Drift prevention (enforced, not aspirational)

From design doc §3, but the real enforcement is **#6**:

1. One envelope-builder library — CLI has no private code path
2. Validation at dispatch, not at send
3. No CLI-only features
4. Envelope schema carries `version` field
5. Skill teaches both paths side-by-side
6. **Parity test — this is the lock.** Same payload via CLI vs raw file write → byte-equivalent inbox state
7. CLI `send` implementation fits in ~30 lines

## Alignment with CMUX-37

See `docs/c11-13-cmux-37-alignment.md` for the shared locked conventions. Summary: surface names are the stable addressing primitive; `mailbox.*` is a reserved metadata namespace CMUX-37 round-trips unmodified; pane-metadata values are strings for v1 (joint migration if that changes); `WorkspaceApplyPlan` absorbs mailbox config naturally when CMUX-37 Phase 0 lands; Snapshot/restore is safe by construction because receivers dedupe by `id`.

C11-13 ships independently. Does not block on CMUX-37. Re-converges at CMUX-37 Phase 2 (Blueprint format) when mailbox fields become first-class Blueprint properties.

## Links

- Design doc: `docs/c11-messaging-primitive-design.md`
- Alignment doc: `docs/c11-13-cmux-37-alignment.md`
- Related: [CMUX-37](../plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md) — workspace persistence: Blueprints + Snapshots
- Builds on: CMUX-11 — Nameable panes: metadata layer (done)
- Full-force reviews: `/tmp/c11-messaging-review-claude.md`, `/tmp/c11-messaging-review-codex.md`, `/tmp/c11-messaging-review-merged.md` (all attached as artifacts)
