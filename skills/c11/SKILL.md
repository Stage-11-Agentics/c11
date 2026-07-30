---
name: c11
version: 1
description: c11 is a native macOS terminal multiplexer. Load this skill anytime any of the following attributes are hit: (1) session is inside c11 (`C11_SHELL_INTEGRATION=1`), (2) working with panes, surfaces, workspaces, splits, or tabs, (3) sending text or commands to another surface, (4) launching or orchestrating sub-agents, (5) declaring agent identity, setting title/description, or reporting sidebar status, (6) using the embedded browser or markdown surfaces, (7) any c11-specific command or troubleshooting question. When in doubt, load it.
---

# c11

**c11** is a native macOS terminal multiplexer for the operator:agent pair. One operator runs many agents in parallel; c11 gives every terminal, browser, and markdown surface a handle so the whole field stays legible. Hierarchy: **window → workspace (a sidebar tab) → pane (a split region) → surface (a terminal, browser, or markdown viewer)**.

This card is deliberately short. It covers **orientation** — the one thing every agent does on launch — and a **map** of everything else. Load the named reference when you reach for a capability; don't pull in depth you don't need.

## Detect c11

`C11_SHELL_INTEGRATION=1` means you're inside c11 — prefer native workflows (splits, the embedded browser, `c11 set-metadata`) over Chrome MCP or plain `open`. Other env vars available to child processes: `C11_WORKSPACE_ID`, `C11_SURFACE_ID`, `C11_TAB_ID`, `C11_SOCKET_PATH`, `C11_SURFACE_NUM`. The spawn path may also pre-seed `C11_AGENT_TYPE`, `C11_AGENT_MODEL`, `C11_AGENT_TASK`.

Refs accept UUIDs, short refs, or indexes: `workspace:1`, `pane:2`, `surface:3`, `tab:1`. **A bare number from the operator is a surface ref.** With the "Show Surface IDs in Tab Titles" setting on, every tab displays `N: title` where N is its `surface:N` ordinal — so "send that to 292" means target `surface:292` (with its `--workspace`). Always write the `surface:N` form; a bare integer in a CLI flag is a positional index, a different thing. Your own N is `$C11_SURFACE_NUM`.

**Where new work goes:** a new **pane** when the work wants its own spatial slot (a sub-agent, a log tail, a browser for validation); a new **surface** when a pane just wants another tab; a new **workspace** when the operator names a different project or mission. Default to one workspace per project unless the operator's setup says otherwise. **Wanting agents isolated from each other is not a reason for a new workspace** — same-workspace agents are already separate processes with separate context; blindness between agents comes from their prompts, never from topology (see [references/orchestration.md](references/orchestration.md#isolation-is-a-prompt-rule-not-a-topology-rule)).

## Boot fast, orient lazily

**Codex: capture your exact thread before other orientation work.** From one of your own tool subprocesses, run `c11 conversation capture-runtime` with no arguments. It reads `CODEX_THREAD_ID`, the agreeing `C11_SURFACE_ID` / `CMUX_SURFACE_ID` aliases, and the subprocess's actual cwd itself. Never expand, copy, relay, or add those values as flags; an orchestrator cannot truthfully capture a child agent's runtime identity on its behalf.

The bundled Codex wrapper separately marks each interactive process boundary. Its internal `--expected-resume-id` claim intent preserves an existing exact ref only for the same explicit `codex resume <uuid>`; plain launches and mismatches invalidate the prior lifecycle until this target performs runtime capture. Agents and orchestrators must not call that internal option or treat argv as causal identity.

c11 stamps your sidebar identity itself: the agent-type/model chip and a placeholder **"Awaiting first task"** title are set the moment you launch. Apart from Codex's conversation capture above, there is no mechanical identity ritual to spend the operator's time on.

**You'll usually load this skill because a task arrived** that touches the workspace (a split, a status report, a browser check). When that happens, orient in place and keep moving — at minimal effort, no per-command deliberation:

- Refine the placeholder into your real role: `c11 rename-tab --surface "$C11_SURFACE_ID" "<2–4 word role>"`. The sidebar is the operator's only view into a room of parallel agents, so a working agent must not sit under "Awaiting first task".
- Say why it's open right now: `c11 set-description --surface "$C11_SURFACE_ID" "<current context>"` — this is your live subtitle, the line the operator reads under your name (contract below).
- If your model chip is blank (an unpinned launch c11 couldn't label), set it: `c11 set-agent --surface "$C11_SURFACE_ID" --type "$C11_AGENT_TYPE" --model "$C11_AGENT_MODEL"` — substitute your own known type/model if those vars are empty.
- Reach for `c11 tree` / `c11 identify --json` only when you actually need layout or your refs (footgun below).
- Read a reference (map below) only for the capability you're using — not preemptively.
- **Declare a stable mailbox address** if peers will reach you: `c11 set-metadata --surface "$C11_SURFACE_ID" --key mailbox.address --value "<stable-handle>" --type string`. Titles are mutable and renames silently re-partition the bus; a declared address survives them. (Depth → [docs/c11-mailbox-guide.md](../../docs/c11-mailbox-guide.md).)

**Launched with only a hydrate message and no task yet?** An operator can configure a "load the skill" launch prompt, so your first turn may carry no real task. Don't invent a title — leave the placeholder, reply in one line that you're ready, and set your real title/description from the next real message, as your first action that turn.

> **Pass `--surface` explicitly on surface- or tab-scoped writes.** Every surface exports `$C11_SURFACE_ID` (inherited by subprocesses), so `--surface "$C11_SURFACE_ID"` targets you correctly. As of C11-165 a surface-scoped write with a **missing or empty** ref no longer silently falls back to the operator-focused surface — it is **rejected** with a clear error (`missing_ref` / `empty_ref`), so an omitted or empty flag fails loudly instead of stomping a peer agent's tab. You must therefore still pass a valid ref: if `$C11_SURFACE_ID` reads empty, capture your refs once from `c11 identify --json` and pass the literal `surface:<n>` (robust on any build). Applies to every surface/tab write (`set-metadata`, `set-agent`, `set-title`, `set-description`, `rename-tab`, `clear-metadata`, `trigger-flash`) and to the tab-scoped sidebar writes (`set-status`, `set-progress`, `log`), which require `--workspace`/`--tab` (auto-supplied from `$C11_WORKSPACE_ID` inside a pane; a ref-less call from a bare shell or cron is now rejected rather than routed to the selected tab). Verify the first write with `c11 get-titlebar-state --surface <surface>` against the surface marked `◀ here` in `c11 tree --no-layout`.

### Title vs description: identity and the live subtitle

- **Title = stable identity.** 2–3 words, role-first, DISTINCT from siblings — make the first word differ; the leading characters are all that survive sidebar truncation. A ticket ID is welcome (`C11-184 Attention`). No `Parent :: Child` chains, no shared prefixes. Rename only when your role or mission changes; check `c11 get-titlebar-state` first.
- **Description = your live subtitle.** The operator reads it in two places: under the title in the title bar, and flattened to one truncated line in the sidebar. First sentence carries what you are doing *now* and the next meaningful gate, present tense: `"Auditing retry admission against the shipped tests; next, verify cancellation."` — not "Reviewing the code."
- **Plain English always.** A ticket number may appear in the subtitle, never *as* the subtitle — the operator should not need a tracker lookup to know what a surface is doing.
- **Refresh at transitions** (task start, phase change, blocker hit or cleared, handoff) — not after every command. The description never decays, so a stale one is a lie the operator cannot detect. A working agent must not sit under a stale subtitle; same register as tab naming.
- **Lineage is the LAST line**: `Lineage: <parent> → <role>`. Arrow, never `::`. Ancestry is static; the line that survives truncation must be the live one. Preserve it on every update.

## Flags and suppression (the attention model)

Your surface's mark shows your lifecycle — working, needs attention (waiting), idle, cold.
Two independent modifiers sit over it. A flag is **attention** priority, not scheduling
priority; suppression reroutes routine attention, it never blocks escalation.

| State | Meaning |
|---|---|
| Normal | Independent agent; routine completion reaches the operator. Most agents, most of the time. |
| Suppressed | A parent agent owns this worker's completion and recoverable blockers; routine signals stay off the operator's sidebar. |
| Flagged | Operator-designated priority mission, or a running agent now needs human action. Marks render violet; the flag escalates to the menu bar extra, reaching the operator even when c11 isn't frontmost. |
| Flagged + suppressed | Supervised priority mission: routine completion stays quiet, escalation still lands at full strength. |

### Flag

```bash
c11 raise-flag --surface "$C11_SURFACE_ID" "Need a call on schema migration vs dual-write"
c11 lower-flag --surface "$C11_SURFACE_ID"
c11 launch-agent ... --flag "Watch the migration"   # operator-designated priority mission
```

The reason is required — one line, ≤256 chars, surfaced everywhere the flag appears. Write it
as the sentence you would say if the operator walked over. Policy differs by origin:

- **At dispatch** (`--flag`): reserved for missions the operator designated as priority. Pass
  it only when relaying explicit operator intent, with `--by operator`.
- **Self-raised** (mid-run): you have stopped on a decision only a human can make, or hit an
  urgent issue whose blast radius crosses other agents. "I finished, please review" is
  waiting, not a flag. If the operator is already in conversation with you, just ask them.

A flag is **sticky** — it holds until dismissed or lowered, and if you are also stopped the
mark strobes, the strongest signal c11 has. **Expect at least nine in ten agents to never
carry one**; the tier's power is its scarcity. Typing into the flagged surface lowers the
flag immediately — an operator's first keystroke of a reply is the answer arriving — so a
flag that vanishes mid-conversation was answered, not lost. Otherwise a dismissed flag was
*seen*: `flag.lowered` carries `by`, and operator dismissal without an answer means seen
and deferred — re-raise only if the blocker still stands and you can say why the deferral
doesn't. All four attention verbs accept `--by agent|operator`, defaulting to `agent`; pass
`--by operator` only when acting on the operator's instruction, so the event trail stays
honest.

### Suppression

```bash
c11 suppress --surface "$C11_SURFACE_ID"
c11 unsuppress --surface "$C11_SURFACE_ID"
c11 launch-agent ... --suppressed     # set at dispatch by the parent
```

A suppressed surface never enters needs-attention: on stop its mark reads idle, and it is
excluded from waiting counts, ⌥V, and routine waiting-derived notifications. The notification
record still lands in the store; the `flag.raise` notification is the deliberate exception,
because a flag overrides suppression completely.

**Suppression is rare, and never a guess.** Suppress only when you *know* another agent owns
your outcomes — it launched you, consumes your completion, handles your recoverable blockers.
That knowledge comes from your launch prompt or from being the launcher yourself, never from
inference about how the operator's setup probably works. In doubt, stay normal. A parent that
suppresses a worker takes on both channels: give it a completion path back to you (mailbox,
metadata key, a `send`) and put this contract in its prompt:

> Report completion and recoverable blockers to your parent. Raise a c11 flag only when
> operator action is required.

### Reading attention state

```bash
c11 get-metadata --surface surface:12    # flag = <reason> / suppressed = true, when set
```

`tree` and `get-titlebar-state` do not carry attention state; `get-metadata` is the read, and
both keys are absent rather than empty when unset. Parent-side monitoring patterns:
[references/orchestration.md](references/orchestration.md).

## What c11 can do — load the reference when you need it

| You want to… | Load |
|---|---|
| split / create / resize panes & surfaces, `tree`, `send`, `read-screen`, targeting, `--cwd` | [references/api.md](references/api.md) |
| launch a typed agent (`launch-agent`); save/list/launch reusable agent configs + read launch stats (`c11 config …`) | [references/api.md](references/api.md) |
| launch sub-agents, the tab-naming convention, layout patterns, write c11-aware prompts | [references/orchestration.md](references/orchestration.md) |
| send/receive inter-agent messages (the mailbox) | [docs/c11-mailbox-guide.md](../../docs/c11-mailbox-guide.md) |
| surface-manifest depth, sidebar reporting (`set-status` / `set-progress` / `log`), flash, precedence & sources | [references/metadata.md](references/metadata.md) |
| tail the file-first events stream (`c11 events tail`), envelope schema, v1 taxonomy | [references/events.md](references/events.md) |
| workspace persistence, snapshots, the conversation store & resume | [references/conversation.md](references/conversation.md) |
| the Claude session-resume hook | [references/claude-resume.md](references/claude-resume.md) |
| drive the embedded browser (validate UI without leaving c11) | [c11-browser skill](../c11-browser/SKILL.md) |
| open markdown surfaces with live reload | [c11-markdown skill](../c11-markdown/SKILL.md) |

A few cross-cutting rules worth knowing before you reach for those:

- **There is no `c11 list`.** Enumeration is scoped: `c11 tree --all` (every window — the one to reach for when asking "is any agent working on X?"), `c11 tree --all --json` to script against, or `list-workspaces` / `list-panes` / `list-pane-surfaces`. `c11 list` is *not* a command — it errors and prints usage, so `c11 list | grep <x>` greps the **error text**, comes back empty, and reads exactly like a clean "nothing found." Don't let a command that never ran become a confident answer: if an enumeration is empty and it matters, run it bare and confirm you got a tree.
- **`send` / `set-status` / `log` take their text as a trailing positional, not `--text`.** `c11 send --surface <s> "npm test"`. Writing `--text "…"` types the literal string `--text` into the terminal.
- **`send` / `send-key` require explicit targeting.** Pass `--workspace` and `--surface` *together* when the target isn't your own surface; `--window` alone is not enough. An empty or stale ref (`--surface ""`, a dead `surface:99`) is an error, not a quiet fallback to whatever pane is focused.
- **A multi-line `send` arrives whole and becomes one turn**, in a background workspace as reliably as in the focused one. Brief a sibling agent directly; you don't need to stage the text in a file and send a pointer.
- **Socket/CLI commands never steal macOS focus**, and telemetry commands run off-main — don't expect a `send` to raise a window.
- **`send` reaches PTYs only.** It cannot drive AppKit/SwiftUI controls (the text box, settings, sidebar, find overlay). For those, ask the operator or use accessibility automation.

## Editing this skill

It installs as a **one-time copy** under `~/.claude/skills/c11/`; the app does not track the repo source after install. After any source edit, run `scripts/sync-installed-skills.sh c11` or the live copy agents load stays stale. This is the skill-editing equivalent of `reload.sh` after a code change.

## Troubleshooting

If `c11` on PATH isn't the active bundle's CLI, run `c11 doctor` (`--json` for machine-readable). It reports the bundled CLI path, how `c11` resolves on PATH, and a `status` of `ok | mismatch | missing | no_bundle`.

Working Lattice tickets inside c11? Also load the `lattice` skill for the integration patterns.
