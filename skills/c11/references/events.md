# c11 Events Stream

c11 emits a **file-first pub/sub log** of everything structural that happens inside a running process — panels opening and closing, workspace selection, metadata edits, liveness flips, waiting edges, mailbox traffic. Each running c11 writes an append-only NDJSON file; any process may `tail -f` it directly. This is the push counterpart to per-panel [metadata](metadata.md)'s pull-on-demand model: metadata answers *what is the state now*, the events stream answers *what just changed*.

**The file is the contract.** The CLI (`c11 events tail`) is sugar over reading that file — it works with no running app, and a consumer that wants the raw bytes never has to touch c11 at all.

## Contents

- [File & format](#file--format)
- [Envelope](#envelope)
- [v2 taxonomy](#v2-taxonomy)
- [Stream-control markers](#stream-control-markers)
- [CLI](#cli)
- [Consumer patterns](#consumer-patterns)
- [Guarantees & non-guarantees](#guarantees--non-guarantees)

## File & format

- **Per-instance NDJSON log** at `~/Library/Application Support/c11/events/events-<instance>.ndjson`, one JSON object per line. The `<instance>` id is `<launch-tag-or-bundleid>-<pid>` (e.g. `com.stage11.c11-12345`) — **every running c11 process writes its own file**, so a machine with three c11 windows open across two launches has multiple logs.
- **Newest-by-mtime is "current."** The CLI defaults to the most recently written instance log; target another with `--instance`.
- **`log.opened` begins each instance's log.** Its payload carries the `pid` and its first emitted `seq` is **1**. The counter is per instance, not the lifecycle journal's committed sequence; do not resume a journal cursor from an events file.
- **Rotation at a size cap (~8 MiB).** The live file is rolled to `events-<instance>.ndjson.1` (older numbered generations are retained within the build’s age and byte budget). The fresh file opens with a `log.rotated` marker as its **first line**; `seq` **continues** across the roll (it is monotonic for the whole instance — only a new `log.opened`/instance resets it). `c11 events tail --follow` is rotation-aware: on the roll it drains the tail of the `.1` file, then continues on the fresh file, so a follower doesn't lose its place.

Schema: **`spec/event-envelope.v2.schema.json`** is the source of truth — every line must validate against it. One `EventEnvelope` serializes to exactly one line. Event logs written by older builds still contain v1 lines (`v` 1, with `surface` / `pane` subject fields and the older type names), and readers accept both. v1 lines validate against `spec/event-envelope.v1.schema.json`.

## Envelope

Every line is a flat JSON object. Five fields are required; the subject refs and `payload` are optional and present only when they apply.

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `seq` | int (≥ 0) | yes | Monotonic per instance, assigned on the writer's serial queue so file order and seq order always agree. **THE ordering oracle** — order by `seq`, never by `ts`. |
| `ts` | string | yes | ISO-8601 / RFC3339 UTC with fractional seconds and `Z` (`2026-07-07T08:20:00.123Z`). Captured on the emitting thread — only *approximately* monotonic and may invert slightly relative to `seq` across racing threads. **Approximate ordering only.** |
| `type` | string | yes | Dotted event type from the closed v2 enum (below). Matches `^[a-z][a-z0-9_.]*$`. |
| `instance` | string | yes | The emitting process's instance id. Namespaces `seq`. |
| `v` | int | yes | Schema version, `2`. Integer, not a string. Bumps are breaking. |
| `workspace` | UUID string | no | Subject workspace this event concerns. |
| `panel` | UUID string | no | Subject panel this event concerns. |
| `area` | UUID string | no | Subject area this event concerns. |
| `payload` | object | no | Type-specific detail, keyed by `type`. Omitted (not `null`) when empty. |

## v2 taxonomy

The taxonomy types below are the closed v2 enum. The envelope fields `workspace` / `panel` / `area` mark which subject refs are populated; `payload` shows the type-specific shape.

| `type` | Subject refs | Payload | Notes |
|--------|--------------|---------|-------|
| `panel.created` | workspace + panel | `{kind, title?}` | A new panel opened. `kind` is terminal / browser / markdown. |
| `panel.closed` | workspace + panel | — | Panel torn down. |
| `workspace.reordered` | none (window-scoped) | `{window_id, final_workspace_ids}` | Applied batch order changed. Dry-run, no-op and rejected batches emit nothing. |
| `workspace.selected` | selected workspace | `{previous?, cause, method?, caller_panel_id?}` | Operator selection. `cause` is `sidebar`, `shortcut`, `palette`, `notification`, `jump`, `menu`, `socket`, `close_fallback`, `restore`, or `create`. Socket fields identify the method and calling panel when known. |
| `workspace.switch_blocked` | requested workspace | `{target, method, caller_panel_id}` | Socket attempt refused before selection changes. `caller_panel_id` is the peer TTY's panel, or the supplied caller UUID when no TTY is available; null means unknown. |
| `metadata.changed` | workspace + panel | `{scope, key, value?, prior?, source}` | A canonical/non-canonical metadata write landed. `scope` ∈ `panel`\|`area`; `source` is the precedence tier (`explicit`\|`declare`\|`osc`\|`derived`\|`heuristic`). **`progress` is excluded** (flood control); this covers `status`/`title`/`description` (+`role`/`task`/`model`). See [metadata.md](metadata.md). |
| `liveness.derived` | workspace + panel | `{state}` | Derived agent activity, `state` ∈ `working`\|`idle`. Emitted on an actual derived working↔idle transition, computed from shell-activity ground truth; a settle back to the absent/unknown state emits nothing. |
| `waiting.entered` | workspace + panel? | — | The "agent is waiting" edge — the unread-notification transition, per workspace. |
| `waiting.left` | workspace + panel? | — | Paired exit edge for `waiting.entered`. This name stays; it is never `waiting.exited`. |
| `lifecycle.changed` | workspace + panel | `{panel, agent, from, to, reason}` | One applied journal phase change. `from` is null on the first event. `reason` is `approval`, `question`, `plan_review`, or null. A repeat observation emits nothing. |
| `flag.raised` | workspace + panel | `{reason, caller_panel_id, by}` | A sticky flag went up. `caller_panel_id` is the UUID of the panel that issued the call (null only for an operator-originated call outside c11); `by` ∈ `operator`\|`agent`. Agent-originated raises without a caller UUID are rejected. |
| `flag.lowered` | workspace + panel | `{by, answer?, answer_bytes?, text_recorded?}` | Flag cleared. `by` ∈ `operator`\|`agent`; only a successful `feed answer` that lowers its original flag epoch adds `answer`. With text recording on, the answer is retained in local activity history, never in the structural journal. With text off, only `answer_bytes` and `text_recorded: false` remain. Other lower paths omit it; operator dismissal without an answer means *seen and deferred*. |
| `flag.suppressed` | workspace + panel | `{by}` | Routine attention withheld for this panel. `by` ∈ `operator`\|`agent`. **Despite the `flag.` prefix this is a suppression event, not a flag-tier one** — a consumer filtering `flag.*` picks up both concerns. |
| `flag.unsuppressed` | workspace + panel | `{by}` | Suppression lifted; routine attention signals resume. `by` ∈ `operator`\|`agent`. |
| `mailbox.accepted` | workspace | `{id, from, bytes, text_recorded, body?, body_ref?, to?, topic?, reply_to?, in_reply_to?, urgent?, truncated?}` | A mailbox message was accepted onto the bus. `body` is recorded in full up to 256 KiB; larger values carry the first UTF-8-safe 256 KiB and `truncated: true`. |
| `panel.input_sent` | workspace + panel | `{caller_panel_id, caller_title, target_title, kind, text?, bytes, submitted, text_recorded?, truncated?, queued?}` | A socket send reached or queued input for the target PTY. `kind` is `text` or `key`; `text` is full up to 256 KiB, then UTF-8-safe truncated with `truncated: true`. `queued: true` means the target panel was not attached yet. Caller refs/titles are null when the caller is unknown (outside c11, or the v1 text protocol). |
| `mailbox.delivered` | workspace + panel? | `{id, recipient, via}` | A mailbox message reached a recipient. `via` is `push`, `drain`, or `inbox`. |
| `conversation.resume.mode` | — | `{mode}` | The resolved recovery mode (`clean`, `dirty`, or `no-resume`) once per app launch. |
| `conversation.resume.decision` | workspace + panel | `{kind, conversation_id, mode, decision, skip_code, reason?}` | One outcome for each restored agent candidate. `decision` is `command` or `skip`; `skip_code` is null for a command. |
| `hang.precursor` | — | `{cause, culprit, count, window_ms, span_ms, durations_ms, fingerprint}` | The main-thread watchdog saw `count` stalls sharing one fingerprint inside `window_ms` — the leading edge of a wedge, emitted before the long stall lands. `durations_ms` are the counted episodes oldest-first; `span_ms` is the wall time the run covered. At most one per fingerprint per window. `runloop-idle` never produces one. |
| `ask.opened` | workspace + panel | `{kind, source, source_rank, opened_at_ms, state, request_id, confirmation, blocking}` | A confirmed blocked ask entered the journal fold. Structural fields only: no prompt, options, plan text, or tool command. |
| `ask.closed` | workspace + panel | `{kind, source, source_rank, opened_at_ms, state, request_id, confirmation, blocking, resolution}` | That ask left the fold. `resolution` is `resumed`, `cancelled`, `unknown`, or null. Still no prompt text. |

`waiting.entered` and `waiting.left` stay the unread 0↔1 edges. A blocked ask is `lifecycle.changed` with `to` or `from` of `blocked` and the journal waiting reason. `waiting.left` is never renamed. Startup baseline publish, a reason-only change that stays blocked, and `duplicate_evidence` do not emit `lifecycle.changed`. The event log can drop a line; `c11 agents` is the recovery read. Do not rebuild a snapshot by tailing the log.

## Stream-control markers

Five additional `type` values are **not taxonomy members** — they are structural markers that let consumers detect instance boundaries, rotation, and backpressure drops. Treat them as control frames, not domain events.

| `type` | Payload | Meaning |
|--------|---------|---------|
| `log.opened` | `{pid}` | First line of an instance's log. `seq` starts here. |
| `log.rotated` | `{rolled_to}` | First line of the fresh post-rotation file; `rolled_to` names the `.1` file the prior contents moved to. `seq` continues (not reset). |
| `log.dropped` | `{count}` | Backpressure or failed writes shed `count` events. This marks incomplete coverage. |
| `log.policy` | `{enabled, analytics_enabled, keep_text, retention_days}` | Recording policy boundary; disabled spans have unknown coverage. |
| `log.retention` | `{state, reason?}` | `degraded` begins a retention-coordination episode; `recovered` ends it. This softens the shared byte cap without implying lost events. |

## CLI

`c11 events tail` reads the log directly and **works with no running app**.

```bash
c11 events tail                       # one-shot: print all events in the current instance log, then exit
c11 events tail --follow              # keep streaming new events (rotation-aware); -f for short
c11 events tail --filter type=panel.closed
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
c11 events tail -f --filter type=panel.closed | while read -r line; do
  panel=$(printf '%s' "$line" | jq -r '.panel')
  echo "panel $panel closed — cleaning up"
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
- **Low latency.** Ordinary events are readable **within ~1s** under normal disk conditions. C11-349 deliberately coalesces meaningful `source=osc` title changes into first/last/count windows: the final tail has a **60-second deadline** while awake, including with analytics off. Spinner-only changes are discarded. This is the sole EVT-6 exception.
- **`seq` is the oracle.** Ordering within an instance is total and gap-free *except* where a `log.dropped` marker explicitly records a gap. Order by `seq`; `ts` is advisory.
- **Rotation is observable.** The `log.rotated` marker (first line of the fresh file) plus the CLI's rotation-aware follow (it drains the rolled `.1` tail, then continues) means a follower doesn't silently lose events across a roll. A direct file reader that wants the same guarantee should watch for a size shrink / inode change and drain `.ndjson.1`.

**Non-guarantees**

- **Not a durable queue.** The log has bounded numbered generations and age retention. History pruned from those generations is gone. Consumers that need durability **own it** — checkpoint your `seq` and persist what you must keep.
- **Drops surface as data, not silence.** Under a stalled disk c11 sheds events and records the loss as `log.dropped {count}` rather than blocking. A gap is always marked; it is never hidden.
- **`ts` is not authoritative for ordering.** It can invert slightly relative to `seq` across racing threads. Never sort or dedupe on `ts`.
- **Per-instance, not global.** There is no cross-instance total order; `seq` only means something within one `instance`.

To answer who attempted a switch, run `c11 events tail --filter type=workspace.switch_blocked`. Resolve `payload.caller_panel_id` against `c11 tree --all --json`; a closed caller remains attributable by UUID. CLI requests include their caller identity; raw sockets from terminals are attributed by the peer's controlling TTY. This is attribution, not permission to switch.

## Local activity history (C11-349)

The app records notification-driven presence edges: `app.activated` /
`app.deactivated`, `screen.locked` / `screen.unlocked`, and `system.sleep` /
`system.wake`. At launch, known presence dimensions are emitted with
`payload.snapshot: true`; these establish a baseline rather than a physical
transition. Duplicate lock/session notifications do not emit duplicate edges.

`workspace.created` carries `{title, root_directory}` (root may be null),
`workspace.renamed` carries `{title, prior}`, and `workspace.closed` carries
`{title}`. Workspace teardown emits `panel.closed` for every remaining known
panel before the workspace edge, including graphs replaced by session restore.
Panel closes remain structural events when analytics are off. On restore,
`panel.created` may precede `workspace.created`; the workspace edge is deferred
until the restored title and root are known. Replay must join these edges by UUID
without requiring their arrival order.

Every workspace-scoped event from the temporary graph constructed by App.init's
uninstalled StateObject getter carries `payload.transient: true`, including panel
edges and delayed callbacks after that getter returns. The installed graph is
constructed outside that synchronous scope and remains unmarked. This classifies
real bootstrap events; it neither invents closes nor changes their ordering.
Replay and activity reports exclude marked graphs from the installed workspace
inventory. The classification survives analytics and recording toggle changes
within the process; analytics-off structural panel edges still carry it.
Classification checks the existing workspace UUID under the emitter's existing
lock: nil subjects and an empty enrollment skip the lookup; otherwise it checks
the small UUID set once. Normal events add no UUID formatting, dictionary, file
I/O, dispatch or timer work. The native A/B gate measures the resulting cost.

`hang.precursor` additionally carries `app_active`, `screen_locked` (null when
not yet known), and current `rss_mb` while usage analytics are enabled. Turning
analytics off preserves the original hang event without those fields or the
process metrics query. `instance.sample` carries current
`rss_mb`, cumulative process `cpu_s_total`, and `threads`. A single
`proc_pidinfo(PROC_PIDTASKINFO)` query obtains these together on the writer
queue. One combined timer schedules the earlier of the next ten-minute health
sample, sixty-second OSC title-tail deadline or daily retention checkpoint.
Health and retention work allow sixty seconds of leeway; title tails allow two
seconds for wakeup coalescing. Sleep suspends the timer and a real wake starts
a fresh sample interval without catch-up. Duplicate awake notifications do not
reset sampling. Analytics-off cancels health sampling but keeps title and daily
retention deadlines. Clean shutdown records one final sample with
`shutdown: true`. Samples never enumerate panels or parse transcripts.

OSC title changes differing only in a recognized leading status/spinner glyph
are suppressed. Meaningful OSC title churn keeps first and last changes plus
`title_change_count` within sixty seconds. Explicit and declared titles,
descriptions, status and all other events are never coalesced. Before any
non-OSC event for a panel, its pending OSC tail is flushed. Panel close,
workspace close, policy changes and shutdown flush applicable tails before
the boundary event. This documented sixty-second tail deadline is the sole
EVT-6 latency exception. Pending state is bounded to 4096 panel/scope entries;
capacity eviction flushes the oldest entry.

Rotation uses plain numbered renames (`.1` newest). The 64 MiB budget and selected
age apply per build label across all its PIDs and generations: production,
nightly and each tag have separate policies. A build never prunes another
production or nightly label. Dead debug/tag labels may also be pruned after a
fixed fourteen-day idle TTL. Live current files are protected by writer locks.
Pruning runs at open, rotation, sample, policy changes and clean shutdown,
plus a daily checkpoint while recording is enabled.
With full recording disabled, startup, policy and shutdown checkpoints still
prune history, but no retention timer runs. A long disabled session can retain
files past their wall-clock age limit until the next checkpoint. Writes maintain
a running byte count; ordinary records do not scan the directory or take a
retention lock.

Shared per-label reconciliation uses a nonblocking lock. If it is busy or
unavailable, recording continues with best-effort pruning of this instance’s
64 MiB history. The shared cap is soft during that episode; `log.retention`
marks degradation once and recovery once. A dead process releases its kernel
lock automatically. A failed writer liveness lock also preserves recording:
`liveness_lock_unavailable` marks non-contention failures, retries occur at rare
checkpoints, and successful recovery is recorded. While liveness is unavailable,
that writer never prunes current files. Other writers require an exclusive probe
and a current file older than 24 hours before pruning it; age pruning also
requires the selected retention horizon. Rolled generations remain eligible.
No retention lock can stall a writer or the UI. Actual write failures and backpressure are counted in `log.dropped`; only successful
writes consume sequence numbers and publish written notifications.

Policy defaults: analytics on, text on, retention 14 days. The cached keys are
`c11.activityHistory.analyticsEnabled`, `c11.activityHistory.keepText`, and
`c11.activityHistory.retentionDays` (7, 14 or 30). Analytics-off skips presence,
workspace and sample envelopes before construction; existing panel, mailbox,
feed and lifecycle events continue. `log.policy` records
`{enabled, analytics_enabled, keep_text, retention_days}` at launch and policy
changes. Disabling full recording writes the final policy boundary first;
re-enabling analytics writes a new presence snapshot. Offline consumers must
preserve disabled spans as unknown coverage, never zero usage.

With text off, new `panel.input_sent` and `mailbox.accepted` payloads omit
`text` / `body` / `body_ref`, retain the original UTF-8 `bytes` count, and carry
`text_recorded: false`. Feed answers omit `answer` and retain `answer_bytes` instead. Existing historical text is not rewritten.

The full recording switch is defaults-only:

```bash
defaults write com.stage11.c11 c11.activityHistory.enabled -bool false
# Relaunch c11 for an external defaults write to take effect.
# Restore recording, then relaunch again:
defaults write com.stage11.c11 c11.activityHistory.enabled -bool true
```

With this off, event tail, live Messages view updates, mailbox event receipts,
and the event-backed feed lose new records; historical files remain readable.
This is independent of anonymous telemetry. Tagged builds use their own
bundle defaults domain.

## Message-history privacy

The Data & Privacy controls apply immediately to new records. Text-off sends and
mailbox accepts carry `text_recorded: false` and `bytes`, without `text`, `body`,
or `body_ref`. Messages view shows “text not recorded” and reads every retained
numbered event generation. Mailbox delivery files keep the actual payload plus
`ext.c11_activity_text_recorded: false`; the page honors that durable marker even
after event-log retention. Sender-supplied reserved privacy markers cannot override c11’s acceptance policy. Unaccepted outbox/processing artifacts never expose text in Messages. If c11 cannot persist a required opt-out marker, valid delivery continues using the normalized in-memory envelope and marked recipient copies. An unresolved recipient instead leaves the original processing envelope held for manual recovery, with a metadata-only failure and no automatic retry. Rejected artifacts without an acceptance decision follow the current text policy. See
[local activity history privacy](activity-history-privacy.md) for scope and defaults.
