# Agent messaging: record every send, deliver mail to waiting agents, a live messages page

Atin decisions, 2026-10-01:
- Two channels, both kept. `c11 send` stays the plain, explicit text poke. The mailbox is the durable, sophisticated channel.
- Full visibility: every `send` and every mailbox message is recorded with its **full text**.
- c11 writes a live HTML page of all traffic (both channels). A file, not a localhost server: bodies include full agent briefs, and a local port is readable by any process (and by DNS-rebinding pages).
- One ticket, worked in parallel lanes. Prototype of the page lives in Overwatch first (`code/overwatch/tools/mailbox-viz/`); it is the design reference for Lane D.

## Why (findings, tested live on 0.67.0)

- Agents use `c11 send` exclusively because it is the only channel that reaches a running agent. Mailbox stdin push gates on the *shell* being `promptIdle`; a live agent TUI keeps its shell `commandRunning` for life, so push buffers and never lands. All-time real dispatch logs: stdin `buffered` 166, `flushed` 2, `evicted` 26, `_copy eio` 52 (recipients named by very long tab titles).
- `c11 send` leaves no trace anywhere: ~300k events across 17 types, none is a send. No view of agent traffic is possible today.
- `_dispatch.log` carries no bodies; drained inbox files are unlinked, so mailbox bodies are lost after reading.
- `c11 mailbox --help` prints "Unknown command 'mailbox'" (CLI/c11.swift ~1660 help pre-check), though every subcommand works. It makes the feature look missing.
- Every harness c11 wraps has the hook model needed: Claude (`--settings` hooks already injected by `Resources/bin/claude`; `additionalContext`, Stop `decision:block`, `asyncRewake`, `FileChanged`/`watchPaths`), Codex (hooks only from config files or plugins, not CLI flags; Stop `decision:block` becomes a continuation prompt), Grok Build (plugins bundle hooks; UserPromptSubmit/Stop can block).

## Pinned contracts (every lane builds against these; change only by comment on this ticket)

**C1. `tab.input_sent` event** (new v1 taxonomy entry beside `mailbox.accepted`), emitted once per `send` / `send-tab` / `send-key` / `send-key-tab` that reaches a PTY:

```json
{"type":"tab.input_sent","workspace_id":"…","tab_id":"<target uuid>",
 "data":{"caller_tab_id":"<uuid|null>","caller_title":"…","target_title":"…",
         "kind":"text|key","text":"<full text or key name>","bytes":123,
         "submitted":true}}
```

`caller_tab_id` is resolved the same way as `flag_caller_tab_id` (the CLI passes `C11_TAB_ID`); null when sent from outside c11. Full text, no truncation below 256 KB; above that, `text` holds the first 256 KB and `truncated: true`.

**C2. `mailbox.accepted` carries the body**: add `body`, `body_ref`, `topic`, `reply_to`, `in_reply_to`, `urgent` to its data. `mailbox.delivered` gains `via: "push"|"drain"|"inbox"`.

**C3. Read, not unlink.** An envelope consumed by push or by drain moves to `<inbox>/_read/<ULID>.msg` instead of being deleted. Whoever consumes first moves it; the other path finds it gone and skips it (rename is the lock). `recv --drain` reads only the inbox root. `_read/` is history for the page, not for re-delivery.

**C4. Page location**: `~/Library/Application Support/c11/messages/messages.html` (self-contained, data embedded as JSON). Inputs: the events log (C1, C2) plus `_read/`, the undrained inbox files and `_rejected/` for older bodies.

## Lanes (independent branches and PRs; one worktree each)

### Lane A: record every send (c11 core)
- Add `tab.input_sent` to `Sources/Events/EventEnvelope.swift`; emit from the socket send path (`Sources/SocketHandlers/`, `TerminalController` send_text / send_key). CLI passes the caller tab.
- Extend `mailbox.accepted` / `mailbox.delivered` per C2.
- Update `skills/c11/references/events.md` taxonomy.
- Accept: `c11 send --tab tab:N "hi"` from one tab produces one `tab.input_sent` with both tab ids, both titles, full text, `submitted:true`; `c11 events tail --filter type=tab.input_sent` shows it; a send from a bare shell outside c11 records `caller_tab_id:null`. Typing-latency hot path untouched (emission is off the keystroke path; send is a socket command, not typing).

### Lane B: mail reaches a waiting agent
- In `Sources/Mailbox/StdinMailboxHandler.swift` / `MailboxStdinBuffer.swift`: when the recipient tab is an agent, gate push on the agent's lifecycle state (waiting / idle, the same state behind `waiting.entered`), not on shell `promptIdle`. Waiting → inject the framed `<c11-msg>` block and submit it as one turn, exactly as `c11 send` does. Working → buffer; flush on the next `waiting.entered`. Plain shells keep today's `promptIdle` rule.
- Revisit the 10-minute freshness drop for agent recipients: an agent goes waiting often, so keep buffered agent mail until delivered (bounded by the 64-block cap; evicted mail stays in the inbox floor).
- Consume per C3 on successful push.
- Accept: with `mailbox.delivery=stdin` on a Claude tab sitting at its prompt, `c11 mailbox send` lands as a new turn within ~1 s; sent while it is mid-turn, it lands at the end of that turn; `trace` shows `buffered` → `flushed`. Same for a Codex and a Grok tab.

### Lane C: busy agents drain at turn boundaries (hooks)
- `c11 mailbox recv --drain --hook-format claude|codex|grok`: prints the harness's hook JSON (UserPromptSubmit → `additionalContext`; Stop → `decision:"block"` with the framed messages as the reason, so the agent takes another turn) and consumes per C3. Empty inbox → prints nothing, exit 0.
- Claude: add UserPromptSubmit + Stop entries to `HOOKS_JSON` in `Resources/bin/claude` (or fold into the existing `c11 claude-hook prompt-submit|stop`).
- Codex: Codex will not take hooks by flag; ship a c11 Codex plugin (or managed `hooks.json`) installed by c11's agent-skills settings, the same path skills install by.
- Grok: ship a c11 Grok Build plugin with the same two hooks.
- Accept: mail sent to a mid-turn agent of each kind appears in that agent's context at its next turn boundary, exactly once, even with Lane B also enabled (C3 dedupe).

### Lane D: c11 writes the messages page
- A debounced (~1 s) writer regenerates `messages.html` (C4) on `tab.input_sent` / `mailbox.*` events. Both channels on one timeline; who-talks-to-whom graph; per-mailbox view; message detail with lifecycle trail and full body; delivery-health panel; filters by workspace, agent, date, channel, plus search.
- `c11 messages view` (alias `c11 mailbox view`) opens it in a c11 browser tab that reloads when the file changes.
- Design: port the Overwatch prototype once Atin signs it off; until then, build the writer and data shape against fixture events matching C1 and C2.
- Accept: the page opens from `c11 messages view`, shows a `send` and a mailbox message from a live test within ~2 s of each, and survives a relaunch (rebuilt from the log on start).

### Lane E: CLI and teaching
- `c11 mailbox --help` (and `-h`) prints mailbox usage.
- Skill and docs: c11 `SKILL.md`, `references/orchestration.md`, `docs/c11-mailbox-guide.md` teach the split: `send` for an explicit poke, the mailbox for durable coordination and completion reports; declare `mailbox.address` at orientation. Run `scripts/sync-installed-skills.sh c11` after editing.
- Docs land after A–C so they describe shipped behavior; the `--help` fix lands any time.

## Order and integration

A, B, D and E's `--help` fix start immediately and in parallel. C starts immediately against C3. D builds on fixtures until A merges. E's docs land last. Integration: one tagged dev build with all lanes plus one numbered sign-off script for Atin covering a send, a mailbox message to a waiting agent, one to a busy agent, one per harness, and the page showing all of them. His pass is merge approval.
