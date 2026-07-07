# c11 Events Stream

c11 emits a **file-first pub/sub log** of everything structural that happens inside a running process — surfaces opening and closing, workspace selection, metadata edits, liveness flips, waiting edges, mailbox traffic. Each running c11 writes an append-only NDJSON file; any process may `tail -f` it directly. This is the push counterpart to per-surface [metadata](metadata.md)'s pull-on-demand model: metadata answers *what is the state now*, the events stream answers *what just changed*.

**The file is the contract.** The CLI (`c11 events tail`) is sugar over reading that file — it works with no running app, and a consumer that wants the raw bytes never has to touch c11 at all.

## Contents

- [File & format](#file--format)
- [Envelope](#envelope)
- [v1 taxonomy](#v1-taxonomy)
- [Stream-control markers](#stream-control-markers)
- [CLI](#cli)
- [Consumer patterns](#consumer-patterns)
- [Guarantees & non-guarantees](#guarantees--non-guarantees)

## File & format

- **Per-instance NDJSON log** at `~/Library/Application Support/c11/events/events-<instance>.ndjson`, one JSON object per line. The `<instance>` id is `<launch-tag-or-bundleid>-<pid>` (e.g. `com.stage11.c11-12345`) — **every running c11 process writes its own file**, so a machine with three c11 windows open across two launches has multiple logs.
- **Newest-by-mtime is "current."** The CLI defaults to the most recently written instance log; target another with `--instance`.
- **`log.opened` begins each instance's log.** Its payload carries the `pid`. **`seq` resets to 0 per instance** — it is monotonic *within* one file, never across instances.
- **Rotation at a size cap (~8 MiB).** The live file is rolled to `events-<instance>.ndjson.1` (a single rolled generation is retained; the previous `.1` is discarded). The fresh file opens with a `log.rotated` marker as its **first line**; `seq` **continues** across the roll (it is monotonic for the whole instance — only a new `log.opened`/instance resets it). `c11 events tail --follow` is rotation-aware: on the roll it drains the tail of the `.1` file, then continues on the fresh file, so a follower doesn't lose its place.

Schema: **`spec/event-envelope.v1.schema.json`** is the source of truth — every line must validate against it. One `EventEnvelope` serializes to exactly one line.

## Envelope

Every line is a flat JSON object. Five fields are required; the subject refs and `payload` are optional and present only when they apply.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `seq` | int (≥ 0) | yes | Monotonic per instance, assigned on the writer's serial queue so file order and seq order always agree. **THE ordering oracle** — order by `seq`, never by `ts`. |
| `ts` | string | yes | ISO-8601 / RFC3339 UTC with fractional seconds and `Z` (`2026-07-07T08:20:00.123Z`). Captured on the emitting thread — only *approximately* monotonic and may invert slightly relative to `seq` across racing threads. **Approximate ordering only.** |
| `type` | string | yes | Dotted event type from the closed v1 enum (below). Matches `^[a-z][a-z0-9_.]*$`. |
| `instance` | string | yes | The emitting process's instance id. Namespaces `seq`. |
| `v` | int | yes | Schema version, `1`. Integer, not a string. Bumps are breaking. |
| `workspace` | UUID string | no | Subject workspace/tab this event concerns. |
| `surface` | UUID string | no | Subject surface this event concerns. |
| `pane` | UUID string | no | Subject pane this event concerns. |
| `payload` | object | no | Type-specific detail, keyed by `type`. Omitted (not `null`) when empty. |

## v1 taxonomy

The nine taxonomy types below are the closed v1 enum. `workspace` / `surface` / `pane` mark which subject refs are populated; `payload` shows the type-specific shape.

| `type` | Subject refs | Payload | Notes |
|--------|--------------|---------|-------|
| `surface.created` | workspace + surface | `{kind, title?}` | A new surface opened. `kind` is terminal / browser / markdown. |
| `surface.closed` | workspace + surface | — | Surface torn down. |
| `workspace.selected` | workspace (the selected one) | `{previous?}` | Sidebar tab switch. `previous` is the prior workspace UUID. |
| `metadata.changed` | workspace + surface | `{scope, key, value?, prior?, source}` | A canonical/non-canonical metadata write landed. `scope` ∈ `surface`\|`pane`; `source` is the precedence tier (`explicit`\|`declare`\|`osc`\|`derived`\|`heuristic`). **`progress` is excluded in v1** (flood control); this covers `status`/`title`/`description` (+`role`/`task`/`model`). See [metadata.md](metadata.md). |
| `liveness.derived` | workspace + surface | `{state}` | Derived agent activity, `state` ∈ `working`\|`idle`. Rides a seam with the TEL ticket (C11-162), which *produces* the derived-liveness signal; documented here as v1 taxonomy but **wired by TEL**. |
| `waiting.entered` | workspace (= tabId) + surface? | — | The "agent is waiting" edge — the unread-notification transition, per tab. |
| `waiting.left` | workspace (= tabId) + surface? | — | Paired exit edge for `waiting.entered`. |
| `mailbox.accepted` | workspace | `{id, from, to?, topic?}` | A mailbox message was accepted onto the bus. |
| `mailbox.delivered` | workspace + surface? | `{id, recipient}` | A mailbox message reached a recipient. |

## Stream-control markers

Three additional `type` values are **not taxonomy members** — they are structural markers that let consumers detect instance boundaries, rotation, and backpressure drops. Treat them as control frames, not domain events.

| `type` | Payload | Meaning |
|--------|---------|---------|
| `log.opened` | `{pid}` | First line of an instance's log. `seq` starts here. |
| `log.rotated` | `{rolled_to}` | First line of the fresh post-rotation file; `rolled_to` names the `.1` file the prior contents moved to. `seq` continues (not reset). |
| `log.dropped` | `{count}` | Backpressure shed `count` events under a stalled disk. A gap in the record — see non-guarantees. |

## CLI

`c11 events tail` reads the log directly and **works with no running app**.

```bash
c11 events tail                       # one-shot: print all events in the current instance log, then exit
c11 events tail --follow              # keep streaming new events (rotation-aware); -f for short
c11 events tail --filter type=surface.closed
c11 events tail --since 1200          # start from seq 1200
c11 events tail --since 10m           # start from ~10 minutes ago (resolved against ts)
c11 events tail --instance com.stage11.c11-12345   # a specific instance, not newest-by-mtime
```

| Flag | Argument | Behavior |
|------|----------|----------|
| `--follow` / `-f` | — | Stay attached and stream new lines as they land. Rotation-aware: on a roll it drains the `.1` tail then continues on the fresh file (first line is `log.rotated`). Omit for one-shot drain-and-exit. |
| `--filter` | `type=<t>` | Emit only lines whose `type` equals `<t>`. |
| `--since` | `<seq>` \| `<duration>` | A bare integer is a `seq` floor (emit `seq ≥ N`); a duration (`10m`, `2h`) is resolved against `ts`. |
| `--instance` | `<id>` | Read a specific instance log instead of the newest-by-mtime one. |

Defaults: no `--filter` emits every type (taxonomy + control markers); no `--since` starts at the top of the current file; no `--instance` picks newest-by-mtime.

## Consumer patterns

**React to a specific event.** Follow, filter to one type, act per line:

```bash
c11 events tail -f --filter type=surface.closed | while read -r line; do
  surface=$(printf '%s' "$line" | jq -r '.surface')
  echo "surface $surface closed — cleaning up"
done
```

**Resume after a restart without replaying history.** Persist the last `seq` you handled, then start above it:

```bash
last=$(cat ~/.mytool/last_seq 2>/dev/null || echo 0)
c11 events tail -f --since "$last" | while read -r line; do
  handle "$line"
  printf '%s' "$line" | jq -r '.seq' > ~/.mytool/last_seq
done
```

Watch for a `log.opened` with a `seq` at or below your floor — that's a new instance whose sequence reset; treat its `seq` space as fresh, not a continuation of yours.

**Detect drops.** A `log.dropped` line means the record is incomplete between the surrounding seqs — a durability-sensitive consumer should reconcile against pull-on-demand state (`c11 get-metadata`, `c11 tree`) rather than trust the stream alone across that gap.

**No running app.** A dashboard or post-hoc analyzer can `jq` straight over the file — `jq -c 'select(.type=="mailbox.delivered")' ~/Library/Application\ Support/c11/events/events-*.ndjson` — with c11 not running at all.

## Guarantees & non-guarantees

**Guarantees**

- **Off-main and non-blocking.** Emission never blocks the UI or the writer's caller; serialization and the file write happen off the main actor.
- **Low latency.** A line is readable **within ~1s** of the event under normal disk conditions.
- **`seq` is the oracle.** Ordering within an instance is total and gap-free *except* where a `log.dropped` marker explicitly records a gap. Order by `seq`; `ts` is advisory.
- **Rotation is observable.** The `log.rotated` marker (first line of the fresh file) plus the CLI's rotation-aware follow (it drains the rolled `.1` tail, then continues) means a follower doesn't silently lose events across a roll. A direct file reader that wants the same guarantee should watch for a size shrink / inode change and drain `.ndjson.1`.

**Non-guarantees**

- **Not a durable queue.** The log is a size-capped ring (one rolled generation), not a message broker. History older than the rolled file is gone. Consumers that need durability **own it** — checkpoint your `seq` and persist what you must keep.
- **Drops surface as data, not silence.** Under a stalled disk c11 sheds events and records the loss as `log.dropped {count}` rather than blocking. A gap is always marked; it is never hidden.
- **`ts` is not authoritative for ordering.** It can invert slightly relative to `seq` across racing threads. Never sort or dedupe on `ts`.
- **Per-instance, not global.** There is no cross-instance total order; `seq` only means something within one `instance`.
