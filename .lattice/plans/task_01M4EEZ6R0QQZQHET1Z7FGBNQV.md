# C11-365: Mailbox push leaves a waiting Codex or Grok agent asleep when the journal hears its turn end from the transcript

Found 2026-10-08 in the MouthKeys build run (workspace:15). Atin asked for the research, the ticket and the fix directly.

## Symptom

panel:98 "MouthKeys build", a Codex (gpt-6.1-sol) coordinator with `mailbox.address=mk-sol`, `mailbox.delivery=stdin`. Sol finished a turn at 13:38:47Z and sat idle at its Codex prompt. Mail at 13:39:15, 13:40:22, 13:40:37, 13:42:56, 13:43:55, 13:48:52, 13:51:22 (`chrome.complete`) and 14:00:22 all logged `buffered`; none woke it. The run stalled 26 minutes until panel 110 typed a nudge with `c11 send` at 14:04:44. The run then built its own wake loop that types into the panel.

## Evidence

Dispatch log `~/Library/Application Support/c11/workspaces/4C4F0DC1-A2A3-41B6-B5FD-4F332A90736E/mailboxes/_dispatch.log`, lifecycle journal `~/Library/Application Support/c11/journal/com.stage11.c11/lifecycle.sqlite3`, events `events-com.stage11.c11-11951.ndjson`. Running app: 1.0.0 build 132, commit ca6355229.

The 13:38 stall, from the journal (panel EF076133, session 01a11abc):

```
13:38:17.559  push ok BKJ3DR (gate open after the 13:36:52 notify)
13:38:27.733  codex_transcript turn.started    applied              -> working
13:38:47.732  codex_transcript turn.completed  applied              -> idle   (10 s transcript poll got there first)
13:38:47.757  codex_notify     turn.completed  duplicate_evidence   turn_already_terminal (hook 25 ms later)
13:39:15-14:00:22  8 x buffered
14:04:47  nudge starts a turn; Sol drains the 8 by hand at 14:04:57
14:25:24  next notify applies -> gate opens -> 20 buffered entries "skipped" (already drained)
```

Every other turn that morning the notify arrived first, applied, and the push worked (81 `ok`, buffered->flushed pairs within seconds). Across the 42 h journal, 9 of 215 attributed Codex turn ends (4%) were recorded by the transcript first, so roughly every 25th turn strands a waiting Codex agent until something else starts a turn.

The 15:11Z-onward stream (64 buffered, then one `evicted` per message) is a different case and not a gate defect. The rollout shows Sol inside one Codex turn since 15:09:19Z (task_started, no task_complete through 19:05Z), kept alive by the wake loop's `c11 send` text steering into the running turn. c11 reads it as working, correctly. All 373 messages since 15:11 reached Sol by `recv --drain` inside that turn; the `evicted` lines are doorbells for mail already delivered. See follow-ups.

## Root cause

Correction to the first hypothesis: `MailboxStdinBuffer.decide(state:)` gating on shell `promptIdle` is C11-144's code on a stale local checkout. Shipped 1.0.0 carries C11-257 Lane B's turn-edge gate (no shell state, no 600 s window for agent mail). The defect is in how that gate is fed:

1. C11-257 Lane B (#491) opened the gate on explicit agent edges: the Codex turn-complete notify, Grok's wrapper `agent-hook`, Claude hooks.
2. C11-273 (#527) made the lifecycle journal the owner. For a journal-live panel the gate opens only on a `JournalMailboxBoundary`: an *applied*, confirmed, hook- or plugin-sourced `turnCompleted`. `PanelLivenessDeriver.onAgentLifecycleChanged` drops every non-submit edge for a journal-live panel, and the notify handler skips its direct edge when the journal owner matches.
3. C11-276 (#542) added Codex and Grok transcript producers (10 s poll, rank 40). It landed after C11-273's plan was written, and it breaks the rule's assumption:
   - **Codex:** when the poll folds the completion first, the notify (rank 60) folds as `duplicate_evidence` and `JournalMailboxBoundary.make` rejects anything not `applied`. The only native prompt edge is lost; the gate stays shut while the sidebar correctly shows the agent waiting.
   - **Grok** (by code reading; no Grok stdin traffic in today's logs): the transcript makes Grok panels journal-live (`journal_current` rows show `connection: live`, source transcript). Grok's native edges arrive only through the wrapper's `agent-hook`, which the journal-live early return drops, and through the transcript, which never forms a boundary. The gate cannot open for a journal-live Grok panel, and the mailbox guide says Grok relies on push.

Why some deliveries logged `ok`: an immediate push happens when the last turn end reached c11 as an applied notify boundary, there is no operator draft, no push since that edge, and the agent's process group owns a raw-mode tty. The skill's promise ("a waiting agent that opted into push gets a new turn") holds only when the hook wins the race, and not for journal-live Grok.

## Fix

1. `JournalMailboxBoundary.make`: also admit a live, root, non-replayed hook/plugin `turnCompleted` that folds as `duplicate_evidence` onto a confirmed idle terminal snapshot. Stamp it with the snapshot's `sinceMs` (when the journal entered idle), not the duplicate's commit time. A transcript observation still never opens the gate by itself; the native hook must still arrive (C11-273's invariant holds).
2. `MailboxStdinBuffer.noteAgentTurn`: ignore a prompt edge older than the newest submit. The agent has had new input since; a late or duplicate turn end must not reopen the gate mid-turn. Needed by (1) and closes the same hazard for a slow hook.
3. `PanelLivenessDeriver.onAgentLifecycleChanged`: for a journal-live panel, forward `.reported` edges (explicit wrapper reports carrying the interactive PID: Grok's turn watcher, the Codex launch seed, opencode, pi) to the mailbox gate, as `.submit` already is. The journal stays the sidebar's truth; inferred and headless edges stay dropped.

Unchanged guards: foreground process group, raw-mode tty, operator-draft guard, input-transaction guard, claim-before-type, plain shells and one-shot commands never typed into.

## Tests (c11LogicTests)

- Journal: transcript completion then hook duplicate yields an idle boundary stamped at the idle start; replayed, historical, child and transcript-only completions yield none.
- Gate: idle agent gets mail injected; busy agent buffers and flushes at its next prompt edge; operator draft defers; a prompt edge older than the last submit is ignored; the late duplicate edge after a push reopens the gate.
- Deriver: a reported edge for a journal-live panel reaches the gate; inferred and headless do not.

## Validation

Atlas `remote-build.sh --mode test` for the classes above, an Atlas tagged build, and a live run of the exact ordering on the tagged build (transcript completion folded first, then the notify), confirming the buffered mail is pushed as a new turn.

## Follow-ups (not in this fix)

- An agent that never ends its turn (a steered Codex coordinator) gets no push and no turn-boundary drain. Delivering mid-turn into Codex (which accepts steering input) is a design call for Atin.
- Buffered doorbells for mail already drained still log `evicted` at the 64 cap. Pruning them on drain would make the dispatch log honest.
