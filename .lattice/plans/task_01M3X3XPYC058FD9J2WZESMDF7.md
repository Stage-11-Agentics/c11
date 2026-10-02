# C11-276: Advisory Codex and Grok turn edges

Planning only. Implement after BUILD MODE and after C11-273 has merged. Citations checked on `0ff8887e5e`.

## Verified citations

- `TranscriptEvent` at `Sources/AgentModelDetection.swift:88` is only `prompt`, `agent`, and `toolResult`. `parseCodex` at `:399` maps `task_started` to `prompt`. `:400` maps `task_complete` to `agent`, which only moves `lastEventAt`. It is not a completion edge.
- The 4 MiB skip is real: `maxPollBytes` at `:119`, and `incrementalScan` at `:273` jumps `start` to `size - 4 MiB` and drops the leading partial line. Nothing records the skip.
- Grok at `:167` reads `summary.json` only. `readGrokSummary` at `:641` keeps `current_model_id` and `last_active_at`. There is no turn edge on that file.
- The tailer is already off main, on the detector's 10 s queue (`:18`). Session change resets state at `:156`. Truncation and inode change reset the offset at `:205`. Partial lines stay unconsumed in `completeLines` at `:299`.

The prior owner reported the native edges below. During takeover, bounded read-only structural samples independently confirmed Codex task_started/task_complete shapes and Grok turn_started/turn_ended shapes. No message text, paths, or session ids were copied. Codex turn_aborted remains prior-owner reported until the versioned Atlas fixture confirms it. The C11-271 Grok case explicitly covers wrapper/metadata only, not these transcript edges; do not label this adapter as already proven by F3.

## Edges that exist

Codex rollout `event_msg` payload, same file the tailer already reads:

| Payload type | Journal kind | Identity |
|---|---|---|
| `task_started` | `agent.turn.started` | `turn_id`. `root_turn_id` when it differs from `turn_id` means this is not the root turn. |
| `task_complete` | `agent.turn.completed` | same `turn_id` |
| `turn_aborted` | `agent.turn.interrupted` | same `turn_id`. One such line exists in local rollouts. |

`timestamp` on the line is the native time (`time_quality` `native_local` for this adapter). `last_agent_message` on `task_complete` and `reason` on `turn_aborted` are not stored, not logged, and not parsed into a kept string. A `response_item`, tool call, or `token_count` is not a turn edge. Clock behavior for those lines stays as it is.

Grok `<session dir>/events.jsonl`, not `summary.json` and not `chat_history.jsonl`:

| Type | Journal kind |
|---|---|
| `turn_started` with `session_relationship` `primary` | `agent.turn.started`. `turn_id` is the decimal `turn_number`. `ts` is native time. |
| `turn_ended` with `outcome` `completed` | Completion only when continuously paired with a prior verified primary `turn_started` in this exact session file. Actual sampled end records contain only `type`, `ts`, and `outcome`; they do not carry `turn_number`, `session_id`, or `session_relationship`. Use the start's native decimal turn_number, never an invented counter. |
| anything else, including `permission_requested`, `permission_resolved`, `phase_changed`, `tool_started` | no journal event |

`last_active_at` does not start, complete, or interrupt a turn. It still updates the model clock. Local `turn_ended` rows were only `outcome=completed`. Grok interrupt is unavailable. Do not invent one from `signals.json` `cancellationCount` or from a quiet file. A later fixture with a different `outcome` does not become `turn.interrupted` unless this plan is revised with that marker.

A Grok start must have session_id equal to the exact eligible ConversationRef and session_relationship=primary; otherwise drop it and invalidate any pending pairing so an id-less child/mismatched end cannot complete the prior root. Hold at most one pending qualified start (native turn_number and time), scoped to that exact owner/file. A completed end with a comparable non-earlier ts may pair only while the tail has continuous coverage since that start. Missing start, mismatched start, replacement/truncation, skipped bytes, malformed/oversize structural line, or session change clears pairing and reports an unavailable/gapped completion; it never guesses a turn_number. A second qualified start supersedes the pending start without inventing a completion for it. Capture a sanitized native start/end pair on Atlas before claiming Grok completion coverage. Never use the focused tab.

Codex `root_turn_id` different from `turn_id`: do not append a root edge or invent `agent.child.spawned`. Preserve that bounded per-current-turn classification so its subsequent task_complete/turn_aborted, which may omit root_turn_id, cannot become root completion. Resolve the exact session from the already established ref and validate any session_meta identity before using the file; do not scan another session by cwd. A child line is not a root event even if the end omits the root marker.

## Rank and fold

Every emitted turn edge is source `transcript`, rank 40, adapter `codex` or `grok`. The producer does not pass a numeric rank. Rank 40 never sets or clears blocked. No `question.requested`, `approval.requested`, or `plan_review.requested` from this lane.

Dedupe is C11-272's fold, not a second reducer:

- Same native turn_id from stronger evidence and transcript is one turn. Codex notify may lack a turn_id; use C11-272's semantic duplicate/terminal-barrier rule and report lower-bound/ambiguity where correlation is unavailable, rather than claiming exact native-ID matching for notify.
- A transcript `turn.started` after a higher-ranked terminal barrier does not restart working unless it has a new `turn_id` or a newer comparable native time.
- Unchanged offset means a second poll emits no event. Each distinct parsed observation gets one fresh UUID and emitted_at_ms before delivery; its bounded retry/spool keeps the entire draft unchanged. Never recompute a semantic UUID with a fresh emitted_at_ms or native_event: C11-272 §6 would return idempotency_conflict on rotation/relaunch. A rescan may create a distinct recorded observation, while the existing fold uses native turn_id/time/barrier to avoid another applied turn. Do not claim receipt dedupe across every rescan or unbounded history.
- Absent `turn_id`: do not emit. Do not number turns from arrival order.

Coverage skip: account for bytes omitted by both the bounded initial window and incrementalScan, including any discarded leading partial line. When either skips unobserved content, clear any pending Grok turn pairing and report the gap through C11-273's existing health/capability seam; a same-owner agent.state.changed / adapter_gap is source c11 rank 0 and phase-neutral under the binding contract. A byte counter without consumer-visible degraded readback is insufficient. If that readback seam or phase-neutral control meaning is absent, send BLOCKED. Keep the retained tail only; no invented events for skipped spans. Model-only backward search must not emit lifecycle edges.

## Files

- `Sources/AgentModelDetection.swift`: add a lifecycle edge beside the clock event. Codex maps the three payload types. Grok tails `events.jsonl` with the existing offset, inode, partial-line, and 4 MiB rules. `summary.json` stays the model read. Record skippedBytes on initial and incremental omissions, reset the bounded pending-turn classification on conversationId/inode/truncation/gap, and keep model clocks separate from Grok edge pairing. initialScan expands/replays candidate windows today: collect lifecycle results only from the selected final window, not each model-discovery attempt. Do not maintain an unbounded emitted-event set.
- `Sources/Journal/JournalTranscriptProducer.swift`: builds the allowlisted draft and hands it to C11-273's coordinator on the detector queue. It does not wait for SQLite or for main. A full journal queue increments its existing drop/gap counter, makes transcript coverage degraded, and drops the draft; the next poll must not silently report uninterrupted coverage. Bound pending drafts to the existing journal admission limits. No CLI subprocess or waiting for SQLite/main.
- Tests in `c11Tests/AgentModelDetectionTests.swift`, temp files, synthetic ids. Add fold cases next to C11-273's reducer tests for rank 40 versus a hook-rank barrier. No source-grep test.

The producer does not open `chat_history.jsonl`, `summary.json` for edges, or Codex `last_agent_message`. Parsing a `task_complete` line must not retain that field.

## Acceptance

| AC | Incident | Oracle | Atlas proof |
|---|---|---|---|
| 1 | Codex and Grok look working for the whole TUI life (report 01). Missing edges must stay missing. | Temp rollouts: `task_started`, `task_complete`, and `turn_aborted` each emit one edge, and a second poll emits none. Grok `turn_started` / `turn_ended` `completed` do the same. A file with only `phase_changed` and `last_active_at` emits no turn. Grok interrupt stays unavailable. | Tagged Codex and Grok sessions: journal rows match the visible turn start and finish. No interrupt row for Grok. Display, timer, dismissal. |
| 2 | Esc leaves Codex working (report 01 interrupt row). A tool line must not count as finished. A quiet file must not look blocked. | `turn_aborted` → `turn.interrupted`. A `response_item` alone does not emit `turn.completed`. No transcript draft has a blocked kind. | Tagged Codex Esc: journal shows `turn.interrupted` from `turn_aborted`, source transcript. The mark is not blocked. |
| 3 | 4 MiB skip is silent today (`:273`). Partial lines, replace, and session change replay old edges. | A backlog above 4 MiB sets the gap and does not emit a `task_complete` that sat in the skipped region. A line split across the cap emits once, on the poll that sees the newline. A new conversation id never admits the previous session's edges. Same-session replacement/relaunch can retain duplicate evidence but cannot count another applied turn or return idempotency_conflict; test both receipt retry and semantic rescan. A Grok end after an initial skip, incremental skip, or rotation with no qualified start emits no completion, while a complete start/end pair in continuous retained coverage emits one. | Same temp-file tests on Atlas. Poll stays on the detector queue. Compare that queue's time under the F2 fleet workload with C11-270's registered baseline. No new threshold after the fact. |
| 4 | Hook and transcript can double-count a turn (C11-272 source overlap). | Fold: hook-rank `turn.completed` for turn A, then transcript `turn.started` for turn A, stays idle. Transcript `turn.started` with turn B starts working. A later lower-rank event does not clear a blocked row. | Replay the same two drafts through the tagged append path. One turn in the journal, not two. |
| 5 | Transcript bodies must not enter the journal (C11-272 privacy). Polling must stay off main. | Sentinel `last_agent_message`, abort `reason`, and a Grok user line in `chat_history.jsonl` are absent from the draft bytes and from the sqlite file. The test never reads `chat_history.jsonl` as an input to the producer. | Tagged journal query for the smoke session shows source `transcript`, no sentinel, no blocked reason from this lane. |

## Hot path, strings, persistence

No work on `hitTest`, `forceRefresh`, Return, or the sidebar body. The new read is the existing 10 s file tail. Append does not use `main.sync` and does not wait on the writer. No new localized strings. No schema change. Receipt IDs are stable only for retries of the same complete draft; native turn correlation and the existing fold prevent a rescan from doubling applied turn counts. Retained duplicate evidence is distinct from duplicate receipt delivery. Retention stays C11-273's.

## Cut line

Out: blocked inference, screen or title classifiers, Kimi, Copilot, Gemini, pi, omp, Claude transcripts, editing files under `~/.codex` or `~/.grok`, treating `last_active_at` as a turn, Grok interrupt, child-turn synthesis, and roster UI (C11-231 / J6 reads the source field this lane writes).

## Dependencies

C11-273's fold and coordinator. If rank 40 can set blocked, stop and send BLOCKED. C11-275's notify path is the higher-rank Codex completion when it lands; this lane does not require hooks. C11-271 fixtures replace the synthetic lines when they exist. C11-278 documents that Grok interrupt is unavailable and that transcript evidence is advisory.

## Decisions

None for Atin. Owner defaults: Grok source is `events.jsonl`; its id-less completed end pairs only with a qualified native start through uninterrupted same-owner coverage; interrupt is unavailable; Codex interrupt is `turn_aborted`; non-root Codex turns are dropped; permission and phase lines are ignored; gap uses `adapter_gap` only when the fold keeps the phase.

Review cap: three cycles, then DECISION to the Orchestrator.

## Reset 2026-10-02 by agent:luna-276
