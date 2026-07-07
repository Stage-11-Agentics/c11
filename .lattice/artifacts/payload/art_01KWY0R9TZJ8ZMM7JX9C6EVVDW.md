# C11-163 Events Stream — Validation Report

Tagged build: `evt-post` (`c11 DEV evt-post.app`, instance `evt-post-47917`).
Socket `/tmp/c11-debug-evt-post.sock`. Live event log:
`~/Library/Application Support/c11/events/events-evt-post-47917.ndjson`.

**Real-artifact smoke launch (CLAUDE.md doctrine):** the packaged tagged app,
launched via `reload.sh --tag evt-post` + `open -g`, wrote a correct
`log.opened` marker and `surface.created` events for its restored
browser/terminal/markdown surfaces on first launch — no dev-seed path. The
feature works in the shipped bundle, not just in tests.

## Per-EVALUATION-row evidence

| Row | Tag | Result | Evidence |
|-----|-----|--------|----------|
| EVT-1 | autonomous | PASS | Live log lines carry seq (monotonic), ISO-8601 ts, type, instance, v, optional workspace/surface/pane, payload; nil refs omitted. `live-event-log.ndjson`. Unit: `testEnvelopeCarriesRequiredFieldsAndOmitsNilRefs`, `testAppendAssignsMonotonicSeqInFileOrder`. |
| EVT-2 | autonomous | PASS | Every v1 taxonomy member observed live: surface.created (browser/terminal/markdown), surface.closed, workspace.selected, metadata.changed (status/title/description with **source tier** explicit/osc/declare and captured **prior**), mailbox.accepted, mailbox.delivered. `reactions.log` histogram. liveness.derived = TEL/C11-162 seam (type shipped, emit stubbed); waiting.* wired on the unread edge. |
| EVT-3 | autonomous | PASS | Off-main serial-queue writer; `append` never touches disk on the caller; bounded drop-and-report. Unit: `testAppendIsNonBlockingAndDropsUnderBackpressure` (queue pinned via a semaphore; 500 appends return <1s; drops surface as `log.dropped`). |
| EVT-4 | autonomous | PASS | Size-cap rotation → `events-<inst>.ndjson.1`, one generation retained, fresh file opens with a `log.rotated` marker, seq monotonic across the boundary. Unit: `testRotationRollsAndMarksAndRetainsOneGeneration`. CLI follow loop is rotation-aware (shrink/inode reset). |
| EVT-5 | autonomous | PASS | CLI matrix on the tagged CLI: one-shot (8→33 lines), `--filter type=surface.created` (3), `--since 5` (seq → [5,6,7,8]), `--since 1h`/`10s` (duration), `--follow`, pre-socket `--help`. Works with no socket. |
| EVT-6 | autonomous | PASS | Status write → visible to a file consumer in **267 ms** (<1s). `latency-result.txt`. |
| EVT-7 | autonomous (recorded) | PASS | `reactions.log`: a `c11 events tail --follow` consumer reacted, per event, to a status change, a mailbox delivery, and a surface close (plus workspace/surface lifecycle) — cause→event→reaction. `consumer` + `capture.ndjson`. |
| EVT-8 | autonomous | PASS | `spec/event-envelope.v1.schema.json` + fixtures (6 valid / 7 invalid) + `skills/c11/references/events.md` + SKILL.md link, installed copy synced. `tests_v2/test_events_parity.py`: fixtures-vs-schema + live CLI-vs-file parity over 33 lines, all schema-conformant. |

## Test suites
- `c11-logic` scheme: `EventLogTests` — 10/10 pass (`** TEST SUCCEEDED **`).
- `tests_v2/test_events_parity.py` — schema + live parity pass.

## Artifacts in this directory
- `live-event-log.ndjson` — the tagged instance's real event log.
- `reactions.log` — EVT-7 consumer reactions (per-event, wall-clock stamped).
- `capture.ndjson` — full stream snapshot the consumer saw.
- `latency-result.txt` — EVT-6 measurement (267 ms).
- `evt_scenario4.sh` / `reactor.py` — repeatable harness.

## Seams logged
- **liveness.derived** consumes C11-162 (TEL) derived-liveness. TEL has not
  landed that signal; the `liveness.derived` event type + `emitDerivedLiveness`
  stub ship now, TEL wires the call site later. (Per BUILDPLAN seam rule.)
- **waiting.*** rides a second TEL-6 seam (waiting-agent cluster) — currently
  the notification unread edge; rewire if TEL-6 redefines the signal.
- **pane-scoped metadata.changed** deferred for v1 (the pane store is a
  parity/ lineage-title store, not the SPEC's canonical sidebar metadata).

## Code review
Auto code-review hit an empty-diff base bug (resolved the parent checkout, not
the worktree); ran an own-reviewer fallback over the full 31-file diff. Verdict
**SHIP**. One latent bug fixed before landing: `--follow` dropped the rolled
file's sub-second unread tail across a rotation — now it drains `.ndjson.1`
from the last offset before switching to the fresh file. Doc/fixture drift
(`log.rotated` is the first line of the fresh file; `seq` continues across a
roll; payload `{rolled_to}`) corrected. Rebuilt (`** BUILD SUCCEEDED **`) and
re-validated the fixed CLI binary (emits + tails correctly; parity green).
