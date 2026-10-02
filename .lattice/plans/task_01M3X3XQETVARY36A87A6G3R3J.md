# C11-278: Bounded hook doctrine and the journal skill

Planning only. Implement after BUILD MODE, on `c11-1.0/C11-278-doctrine-skill` from `origin/main`, and only once C11-273 is on that base. Citations checked on `0ff8887e5e`. Upstream hook file checked at `920ff39ff7`.

Takeover verification: C11-272 remains binding; audit findings 2 and 5 govern response coverage and producer-before-docs barriers. Metadata persistence and first emitted seq are verified from executable code/test definitions at 0ff8887e5e; no test was run. Existing source/runtime drift statements are corrected by this ticket only in BUILD MODE.

This is the only doctrine amendment in 1.0. It stays the bounded D5 exception. It does not reopen D5 or D6.

## Verified citations

- `CLAUDE.md:80` is the wrapper exception, and `:84` already allows lifecycle status where the TUI exposes it. `Agents.md` is a symlink to `CLAUDE.md`, so one edit covers both. The sync rule is `:41`–`:52`.
- `PHILOSOPHY.md:11` is "Observe from outside, never hook into agents." `:13` says features must not require agent-side cooperation. That sentence stays.
- `skills/c11/references/metadata.md:18` says the blob is in-memory and does not persist. `:40` and `:283` say derived `activity` is not persisted. `:72` tells new derivers to exclude every derived key. `Sources/PersistedMetadata.swift:136`, `:166`, and `:176` keep derived `activity` and drop other derived keys. `c11Tests/MetadataDerivedPrecedenceTests.swift:156` already asserts that round-trip. No new test.
- `skills/c11/references/events.md:21` says `seq` resets to 0. `Sources/Events/EventLog.swift:36` starts `nextSeq` at 0 and `:115` increments before the write, so the first emitted value is 1. `c11Tests/EventLogTests.swift:125` asserts `log.opened` has seq 1, and `:115` asserts the next appends are 1…5. The events counter is per instance. It is not the journal's committed sequence.
- Upstream `CLI/CMUXCLI+ClaudeHookSettings.swift:85` assigns `PermissionRequest` to `hooks feed --source claude` with timeout 125 (`:87`–`:88`), verified at 920ff39ff7. That is the blocking bridge. Do not copy it. StopFailure aliased to subcommand `stop` at `:20` is also not this ticket (C11-274 maps StopFailure itself).

## Wording to land

`PHILOSOPHY.md`, one paragraph after the existing "How to apply" close. Do not delete the no-cooperation rule.

> Bounded exception. A c11 terminal may attach optional, non-blocking observations to the process it launches, and only to that process. An observation may carry a lifecycle or attention fact the journal already allows. It may not carry a tool body, a prompt, an answer, or a permission decision, and it may not trust hooks the operator configured. A tab with no observation is still a normal terminal. Missing evidence is a visible gap.

`CLAUDE.md`, inside the existing wrapper exception, after the four bullets:

> The same wrapper may attach those optional observations. Delivery is best-effort: a dead socket spools or drops, and the agent is not held for an answer. PermissionRequest is observe-only. The wrapper still does not write tenant config, store a tool body or prompt, or broaden trust. Upstream's blocking `hooks feed` PermissionRequest bridge is outside this exception.

`c11 install <tui>` stays rejected.

## Doc drift

`references/metadata.md`:

- `:18`: the live blob is on the tab. A workspace snapshot keeps what `PersistedMetadata.encodeValues` keeps. Derived keys are dropped except `activity`. A history beyond that snapshot is still the consumer's.
- `:40` and `:283`: `activity` is the derived key the snapshot keeps, so restore can seed the live projection. It still never overwrites a fresh explicit status, and agents still cannot write it.
- `:72` step 5: exclude derived keys except `activity`.

`references/events.md:21`: the counter resets per instance, and the first emitted `seq` is 1 on `log.opened`. Say in the same sentence that this `seq` is not the journal's committed sequence, and that a consumer must not resume a journal cursor from an events file. Leave the `seq ≥ 0` schema minimum. `waiting.entered` / `waiting.left` versus `lifecycle.changed` is C11-231's paragraph in this file; do not write a second one. If that paragraph is already on the base, leave it.

## Skill

New `skills/c11/references/journal.md`. One map row in `skills/c11/SKILL.md`. Do not grow the card with the fold.

C11-273 documents `c11 agent-event append --stdin`, the receipt, and the spool in `references/api.md`. Link that section. Do not write a second append tutorial. Agents do not append their own phase.

Do not equate first keypress, text-box draft editing, seen, generated input, or agent resume with an actual submitted operator response. C11-272 §7 Q2 requires an actual user UI submit or response action tied to that request. Takeover found C11-231's current §Operator response and AC2 use first keystroke instead: record this cross-ticket dependency gap on C11-278 and send BLOCKED to the Orchestrator for the history seat to correct. This seat does not edit C11-231 or add an alternate producer. Do not claim live Q2 or open the docs PR until its producer and a real answer/resume trace meet the binding contract.

Before any command example is written, read `--help` on the implementation base for `c11 agents`, `c11 journal`, and `c11 agent-event`. Document only flags that help prints. If help disagrees with the plans below, follow help and record the delta on this ticket.

Planned shapes, checked against the other plans, not against a shipped binary:

- `c11 agents [--json]` (C11-231). `state` is the journal phase. `reason` is `approval`, `question`, or `plan_review`, or null. `source` is the journal source enum. A restart row is a `restore_candidates` entry with `confirmation=unconfirmed`. The command does not launch or focus. App-down: `tabs` is `[]` and `live_identity` is `unavailable`.
- `c11 journal query|export|clear` (C11-277). Not `c11 stats`. Query flags include `--agent`, `--model`, `--workspace`, `--from`, `--to`, `--stall-ms` (default 900000), and `--json`. The six fields are `time_in_state_ms`, `operator_response`, `blocked_ms`, `turns`, `errors`, and `stalls`. Seen is not an operator response; a missing response stays `status=unavailable`. Export is structural NDJSON, no prompt or tool body, to stdout or to `--output` when the path has no URL scheme.
- `lifecycle.changed` payload is `{tab, agent, from, to, reason}` when C11-231 has merged. `waiting.entered` stays the unread edge.

Producer limits, written only from code that is already on the base. If C11-274, C11-275, or C11-276 has not merged, omit that adapter rather than describing the plan as shipped.

- Claude: StopFailure is `agent.error.reported`. PermissionRequest observes and returns no decision. Ordinary PostToolUse is `tool_activity` and does not clear blocked. PostToolUse of the same AskUserQuestion or ExitPlanMode is `attention.resolved` `resumed` with its native request id. A genuine UserPromptSubmit retains the new-turn mapping; it does not fabricate a matching resolution from a stored current ask. That is not `operator_response`. SubagentStart/Stop are child rows. PreCompact is an observation, not a completion. AskUserQuestion and ExitPlanMode at PreToolUse are blocked asks, bypass included.
- Codex: notify only. No `--enable hooks` and no `--dangerously-bypass-hook-trust`. Root `turn.completed` only. The exact-owner adapter capability profile reports notify-only hook coverage as degraded. Sessionless diagnostics cannot establish that live profile. An adapter_gap is phase-neutral under the binding contract; a missing capability readback seam or contrary fold is BLOCKED, not a doctrine exception.
- Transcript: rank 40 `turn.started` / `turn.completed` for Codex and Grok. Codex interrupt is `turn_aborted`. Grok interrupt is unavailable. Rank 40 never sets or clears blocked. Initial-window or incremental 4 MiB omissions are coverage gaps, not invented turns. Grok completion pairs its id-less end with a verified primary start only through continuous same-owner file coverage; an unmatched end is unavailable.

Examples use fictional ids (`11111111-1111-4111-8111-111111111111`) and no home-directory paths. The F3 read is two rows: one `state=blocked`, `reason=question`, and one `state=working`. The restart read shows the unconfirmed candidate and does not show working time across the gap.

## Acceptance

| AC | Incident | Oracle | Atlas proof |
|---|---|---|---|
| 1 | Reviewers reopen the hook rule on every producer PR (D5, D6). | A read of both doctrine files finds the same bounds: optional, non-blocking, no tool body, no prompt, no answer, no trust broadening, no tenant write, no blocking bridge. PHILOSOPHY still says cooperation is not required. No source-grep test. This prose change has no runtime oracle. | The PR diff is the proof. No tagged UI. |
| 2 | F3 could not name which tab was waiting, and agents will learn whatever the installed skill says. | Documented examples match `--help` and the JSON keys from C11-231 and C11-277. A sentinel body field is absent from the export example's described schema. Rank 40 is described as never setting or clearing blocked. | Tagged app: run the documented `c11 agents --json`, `c11 journal query --json`, and `c11 journal export` against a synthetic journal. Compare keys to the doc. Display, timer, and dismissal apply only if a step claims a visible mark; these reads do not. |
| 3 | metadata.md says activity is not persisted; events.md says seq resets to 0 (report 01 doc drift). | Existing `testDerivedKeysAreDroppedFromSnapshotCapture` keeps activity and drops worktree/branch. Existing `testOpenWritesLogOpenedMarker` emits seq 1. The edited sentences match those results. The events sentence names the journal sequence as a different counter. No new test. | No new soak. Point the review at those two tests. |
| 4 | A skill edit landed and the installed copy stayed stale (`CLAUDE.md:41`). | `scripts/sync-installed-skills.sh c11`, then SHA-256 of each changed file under `skills/c11/` equals `~/.claude/skills/c11/`. `.c11-skill.json` is unchanged. Record the hashes on the ticket. | Same check on the machine that opens the PR. If that install is absent, the script's skip line is the evidence and the source commit is still required. |

## Hot path, strings, persistence

No code changes. No `hitTest`, `forceRefresh`, socket, or sidebar work. No new localized strings. No schema, snapshot, or event-transport change. The persistence text describes the exception `PersistedMetadata` already implements.

## Cut line

Out: a blocking PermissionRequest bridge, tenant writes, `c11 install`, tool bodies, answers, trust broadening, a second reducer, an events-transport change, a rewrite of unrelated docs, and C11-231's `lifecycle.changed` paragraph. C11-273 keeps the append tutorial in `api.md`.

## Dependencies

C11-278 completes only after the producer APIs and the consumer APIs have landed on the base this branch documents. Producers: C11-274, C11-275, C11-276. Consumers: C11-231 (`c11 agents`) and C11-277 (`c11 journal`). Doctrine and drift text may be drafted on the branch after C11-273 merges, and that draft is not completion. Do not open the PR, and do not send HANDOFF, until those APIs are on the base and the skill examples match their `--help`.

No product commit until C11-273 is on `origin/main`. C11-306 does not edit these files.

## Decisions

None for Atin. Owner defaults: one new `journal.md` plus a map row; doctrine is a paragraph in each file; events.md changes only the seq sentence; activity is the one derived key called out; examples follow `--help`.

Review cap: three cycles, then DECISION to the Orchestrator.
