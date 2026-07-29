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
- Say why it's open right now: `c11 set-description --surface "$C11_SURFACE_ID" "<current context>"`.
- If your model chip is blank (an unpinned launch c11 couldn't label), set it: `c11 set-agent --surface "$C11_SURFACE_ID" --type "$C11_AGENT_TYPE" --model "$C11_AGENT_MODEL"` — substitute your own known type/model if those vars are empty.
- Reach for `c11 tree` / `c11 identify --json` only when you actually need layout or your refs (footgun below).
- Read a reference (map below) only for the capability you're using — not preemptively.
- **Declare a stable mailbox address** if peers will reach you: `c11 set-metadata --surface "$C11_SURFACE_ID" --key mailbox.address --value "<stable-handle>" --type string`. Titles are mutable and renames silently re-partition the bus; a declared address survives them. (Depth → [docs/c11-mailbox-guide.md](../../docs/c11-mailbox-guide.md).)

**Launched with only a hydrate message and no task yet?** An operator can configure a "load the skill" launch prompt, so your first turn may carry no real task. Don't invent a title — leave the placeholder, reply in one line that you're ready, and set your real title/description from the next real message, as your first action that turn.

> **Pass `--surface` explicitly on surface- or tab-scoped writes.** Every surface exports `$C11_SURFACE_ID` (inherited by subprocesses), so `--surface "$C11_SURFACE_ID"` targets you correctly. As of C11-165 a surface-scoped write with a **missing or empty** ref no longer silently falls back to the operator-focused surface — it is **rejected** with a clear error (`missing_ref` / `empty_ref`), so an omitted or empty flag fails loudly instead of stomping a peer agent's tab. You must therefore still pass a valid ref: if `$C11_SURFACE_ID` reads empty, capture your refs once from `c11 identify --json` and pass the literal `surface:<n>` (robust on any build). Applies to every surface/tab write (`set-metadata`, `set-agent`, `set-title`, `set-description`, `rename-tab`, `clear-metadata`, `trigger-flash`) and to the tab-scoped sidebar writes (`set-status`, `set-progress`, `log`), which require `--workspace`/`--tab` (auto-supplied from `$C11_WORKSPACE_ID` inside a pane; a ref-less call from a bare shell or cron is now rejected rather than routed to the selected tab). Verify the first write with `c11 get-titlebar-state --surface <surface>` against the surface marked `◀ here` in `c11 tree --no-layout`.

### Title vs description, and lineage

- **Title = what the surface *is*** — generic, reusable. A filename for file-backed surfaces (`PHILOSOPHY.md`); a role for terminals (`Phase 2 agent`, `Log tail`).
- **Description = why it's open *right now*** — one or two sentences of current context the operator can read without opening the surface.
- **Refresh both when scope shifts** (plan → impl, ticket → ticket, file → file) — at the pivot, not at session end.
- **Lineage lives in the DESCRIPTION, not the title (revised 2026-07-20).** Titles are 2–3 words, role-first, DISTINCT — make the first word differ between sibling tabs; `::` parent-prefix chains are retired (at fleet scale every sibling truncates to the same parent prefix and the sidebar becomes unreadable — operator verdict). Lead the description with a `Lineage: <parent> → <role>` breadcrumb instead. Before renaming, check `c11 get-titlebar-state`; keep names short, keep the description's lineage line.

## Flags and suppression (the attention model)

Your surface's mark shows your lifecycle — working, needs attention (waiting), idle, cold.
Two modifiers sit over it, and they are yours to use.

### Flag: work has stopped and only a human can restart it

```bash
c11 raise-flag --surface "$C11_SURFACE_ID" "Need a call on schema migration vs dual-write"
c11 lower-flag --surface "$C11_SURFACE_ID"
```

The reason is required, one line, and surfaced everywhere the flag appears — write it as the
sentence you would say if the operator walked over.

- A flag is **sticky**: it holds until the operator dismisses it or you lower it. While it is
  up, your marks render violet across the workspace; if you are also stopped, the mark
  strobes — the strongest visual signal c11 has. When the flag lowers, your marks return to
  normal lifecycle colors.
- **Flag only when work has stopped and only a human can restart it**, or when you have hit
  an urgent issue whose blast radius crosses other agents. "I finished, please review" is
  waiting, not a flag. If the operator is already in conversation with you, just ask them —
  the flag is your channel back when you were dispatched and left alone.
- Flags arrive from either side: the operator may launch you flagged (a mission they intend
  to watch), or you may raise one mid-run. Both are rare by design — **expect at least nine
  in ten agents to never carry a flag**. The tier's power is its scarcity; an agent that
  flags routinely is spending everyone's signal.
- A dismissed flag is not an unseen flag. `flag.lowered` carries `by: "operator" | "agent"`;
  operator dismissal without an answer means *seen and deferred*. Re-raise only if the
  blocker still stands and you can say why the deferral does not.

### Suppression: keep working, do not signal

```bash
c11 suppress --surface "$C11_SURFACE_ID"
c11 unsuppress --surface "$C11_SURFACE_ID"
c11 launch-agent ... --suppressed     # the common case: set at dispatch
```

A suppressed surface never enters the needs-attention state: when it stops, its mark reads
idle, and it is excluded from waiting counts, ⌥V, and routine waiting-derived system
notifications. The notification record still lands in the store — suppression silences the
routine signal, not the history. A direct notification from `flag.raise` is the deliberate
exception because the flag tier overrides suppression completely.

- The natural fit is **subagents under an orchestrator**: the orchestrator watches you, so
  the operator's sidebar stays quiet while coordination happens one level down. If you are
  orchestrating, launch your workers `--suppressed` and sweep them yourself.
- **Suppression is not a gag.** If you hit a genuine blocker, raise the flag — a flag
  overrides suppression entirely, at full visual strength. "Do not tell me when you finish,
  do tell me if you get stuck" is the contract, and the flag is the second half.

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
