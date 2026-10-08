---
name: c11
version: 1
description: "c11 is a native macOS terminal multiplexer. Load this skill anytime any of the following attributes are hit: (1) session is inside c11 (`C11_SHELL_INTEGRATION=1`), (2) working with workspaces, areas, panels (formerly tabs), or splits, (3) sending text or commands to another panel, (4) launching or orchestrating sub-agents, (5) declaring agent identity, setting title/description, or reporting sidebar status, (6) using the embedded browser or markdown panels, (7) any c11-specific command or troubleshooting question. When in doubt, load it."
---

# c11

**c11** is a native macOS terminal multiplexer for the operator:agent pair. One operator runs many agents in parallel; c11 gives every terminal, browser, and markdown panel a handle so the whole field stays legible. Hierarchy: **window → workspace (a sidebar entry) → area (a split region) → panel (a terminal, browser, or markdown viewer)**.

This card is deliberately short. It covers **orientation** — the one thing every agent does on launch — and a **map** of everything else. Load the named reference when you reach for a capability; don't pull in depth you don't need.

## Detect c11

**Ask this build:** `c11 guide` (alias `c11 --skill`) prints the skill shipped in
the CLI's app bundle, including its build identity and skill version, with no
socket required. `c11 guide api` prints a bundled reference page. An installed
skill copy can be older than `c11 guide`; printing the guide does not update it.
`c11 capabilities --json` reports the connected server's methods and enabled
versioned features, both CLI/server identities, and `sha_match` (null when a
commit stamp is unavailable). Use that server feature list to check support;
the PATH CLI can belong to a different build.

`C11_SHELL_INTEGRATION=1` means you're inside c11 — prefer native workflows (splits, the embedded browser, `c11 set-metadata`) over Chrome MCP or plain `open`. Other env vars available to child processes: `C11_WORKSPACE_ID`, `C11_PANEL_ID`, `C11_SOCKET_PATH`, `C11_PANEL_NUM`. The spawn path may also pre-seed `C11_AGENT_TYPE`, `C11_AGENT_MODEL`, `C11_AGENT_TASK`.

Refs accept UUIDs, short refs, or indexes: `workspace:1`, `area:2`, `panel:3`. **A bare number from the operator is a panel ref.** Panels display `N: title` by default (the "Show Panel Numbers in Panel Titles" setting; if the operator turned it off, panels show titles only), where N is its `panel:N` ordinal — so "send that to 292" means target `panel:292` (with its `--workspace`). Always write the `panel:N` form; a bare integer in a CLI flag is a positional index, a different thing. Your own N is `$C11_PANEL_NUM`. `--pane` (tmux-compat) targets an area; `--panel` targets a panel.

**Short refs last only for the current c11 process.** `panel:N`, `area:N`, `workspace:N`, and `window:N` ordinals start over at launch; a ref saved before a restart can name a different object afterward. Keep using short refs for live targets. To find the same panel after a restart, store its UUID from `c11 --id-format both tree --json` or `$C11_PANEL_ID`, and use that UUID. `$C11_WORKSPACE_ID` likewise identifies the workspace; do not store its ordinal across a restart.

**Where new work goes:** a new **area** when the work wants its own spatial slot (a sub-agent, a log tail, a browser for validation); a new **panel** when an area just wants another panel; a new **workspace** when the operator names a different project or mission. Default to one workspace per project unless the operator's setup says otherwise. **Wanting agents isolated from each other is not a reason for a new workspace** — same-workspace agents are already separate processes with separate context; blindness between agents comes from their prompts, never from topology (see [references/orchestration.md](references/orchestration.md#isolation-is-a-prompt-rule-not-a-topology-rule)).

## Boot fast, orient lazily

**Codex: capture your exact thread before other orientation work.** From one of your own tool subprocesses, run `c11 conversation capture-runtime` with no arguments. It reads `CODEX_THREAD_ID`, the agreeing `C11_PANEL_ID` value, and the subprocess's actual cwd itself. Never expand, copy, relay, or add those values as flags; an orchestrator cannot truthfully capture a child agent's runtime identity on its behalf.

The bundled Codex wrapper separately marks each interactive process boundary. Its internal `--expected-resume-id` claim intent preserves an existing exact ref only for the same explicit `codex resume <uuid>`; plain launches and mismatches invalidate the prior lifecycle until this target performs runtime capture. Agents and orchestrators must not call that internal option or treat argv as causal identity.

c11 stamps your sidebar identity itself: the agent-type/model chip and a placeholder **"Awaiting first task"** title are set the moment you launch. Apart from Codex's conversation capture above, there is no mechanical identity ritual to spend the operator's time on.

**You'll usually load this skill because a task arrived** that touches the workspace (a split, a status report, a browser check). When that happens, orient in place and keep moving — at minimal effort, no per-command deliberation:

- Refine the placeholder into your real role: `c11 rename-panel --panel "$C11_PANEL_ID" "<2–4 word role>"`. The sidebar is the operator's only view into a room of parallel agents, so a working agent must not sit under "Awaiting first task".
- Say why it's open right now: `c11 set-description --panel "$C11_PANEL_ID" "<current context>"` — this is your live subtitle, the line the operator reads under your name (contract below).
- If your model chip is blank (an unpinned launch c11 couldn't label), set it: `c11 set-agent --panel "$C11_PANEL_ID" --type "$C11_AGENT_TYPE" --model "$C11_AGENT_MODEL"` — substitute your own known type/model if those vars are empty.
- Reach for `c11 tree` / `c11 identify --json` only when you actually need layout or your refs (footgun below).
- Read a reference (map below) only for the capability you're using — not preemptively.
- **Declare mailbox identity during orientation, before peers need to reach you**: `c11 set-metadata --panel "$C11_PANEL_ID" --key mailbox.address --value "<stable-handle>" --type string`. If this is an interactive agent panel, also opt into waiting-agent push with `c11 set-metadata --panel "$C11_PANEL_ID" --key mailbox.delivery --value stdin --type string`. Titles are mutable; the address survives renames. c11 pushes only to a real agent-owned interactive terminal, never a plain shell or one-shot command. (Depth → [docs/c11-mailbox-guide.md](../../docs/c11-mailbox-guide.md).)

**Launched with only a hydrate message and no task yet?** An operator can configure a "load the skill" launch prompt, so your first turn may carry no real task. Don't invent a title — leave the placeholder, reply in one line that you're ready, and set your real title/description from the next real message, as your first action that turn.

> **Pass `--panel` explicitly on panel-scoped writes.** Every panel exports `$C11_PANEL_ID` (inherited by subprocesses), so `--panel "$C11_PANEL_ID"` targets you correctly. A panel-scoped write with a **missing or empty** ref is **rejected** with a clear error (`missing_ref` / `empty_ref`) rather than falling back to the operator-focused panel, so an omitted or empty flag fails loudly instead of stomping a peer agent's panel. You must therefore still pass a valid ref: if `$C11_PANEL_ID` reads empty, capture your refs once from `c11 identify --json` and pass the literal `panel:<n>`. Applies to every panel write (`set-metadata`, `set-agent`, `set-title`, `set-description`, `set-panel-icon`, `set-panel-color`, `rename-panel`, `clear-metadata`, `trigger-flash`). Sidebar metadata commands are workspace-scoped: `--workspace` is explicit, and `$C11_WORKSPACE_ID` supplies the caller's workspace inside c11. Pass `--workspace` from a bare shell or cron. Every sidebar command (`set-status`, `set-progress`, `log`, `clear-status`, `clear-progress`, `clear-log`, `list-status`, `list-log`, `sidebar-state`) fails when neither target is available; global `--window` alone is not a workspace target, and these commands never use the operator's selected workspace. On sidebar writes (`set-status`, `set-progress`, `log`), `--panel <ref>` names a panel, mirrors the status onto it, and needs a workspace to resolve in; a bare number is rejected as ambiguous. Verify the first write with `c11 get-titlebar-state --panel <panel>` against the panel marked `◀ here` in `c11 tree --no-layout`.

### Title vs description: identity and the live subtitle

- **Title = stable identity.** 2–3 words, role-first, DISTINCT from siblings — make the first word differ; the leading characters are all that survive sidebar truncation. A ticket ID is welcome (`C11-184 Attention`). No `Parent :: Child` chains, no shared prefixes. Rename only when your role or mission changes; check `c11 get-titlebar-state` first.
- **Description = your live subtitle.** The operator reads it in three places: in the bar under the panels (the bar shows only the description), as the subtitle row in the panel sheet, and flattened to one truncated line in the sidebar. First sentence carries what you are doing *now* and the next meaningful gate, present tense: `"Auditing retry admission against the shipped tests; next, verify cancellation."` — not "Reviewing the code."
- **Plain English always.** A ticket number may appear in the subtitle, never *as* the subtitle — the operator should not need a tracker lookup to know what a panel is doing.
- **Refresh at transitions** (task start, phase change, blocker hit or cleared, handoff) — not after every command. The description never decays, so a stale one is a lie the operator cannot detect. A working agent must not sit under a stale subtitle; same register as panel naming.
- **Icon + color = optional at-a-glance marker.** `c11 set-panel-icon --panel "$C11_PANEL_ID" "🧪"` pins a glyph left of the panel's close X; `c11 set-panel-color --panel "$C11_PANEL_ID" teal` tints it (`--clear` removes either). Use them to mark a set or a role family across panels, not as status.
- **Lineage is the LAST line**: `Lineage: <parent> → <role>`. Arrow, never `::`. Ancestry is static; the line that survives truncation must be the live one. Preserve it on every update.

## Flags and suppression (the attention model)

Your panel's mark shows your lifecycle — working, needs attention (waiting), idle, cold.
Cold means you are still at your prompt but your next message starts cold. For Claude Code,
Codex and Grok Build, cold follows the prompt cache only: a **dark blue** line once it
expires (read from their transcripts; Codex and Grok are estimates; a `/model` switch, an
`/effort` change or a compaction resets it at once), and no cold without cache data. Other agents go to a gray
line after the dormancy threshold (10 minutes idle by default). A waiting agent whose cache
expired keeps its gold mark and says so in its tooltip and panel sheet row.
Two independent modifiers sit over it. A flag is **attention** priority, not scheduling
priority; suppression reroutes routine attention, it never blocks escalation.

| State | Meaning |
|---|---|
| Normal | Independent agent; routine completion reaches the operator. Most agents, most of the time. |
| Suppressed | A parent agent owns this worker's completion and recoverable blockers; routine signals stay off the operator's sidebar. |
| Flagged | Operator-designated priority mission, or a running agent now needs human action. Marks render violet; the flag escalates to the menu bar extra, reaching the operator even when c11 isn't frontmost. |
| Flagged + suppressed | Supervised priority mission: routine completion stays quiet, escalation still lands at full strength. |

Feed and the configured attention jump use oldest flags first, then oldest eligible open asks (panel UUID, then workspace UUID for ties). The jump continues through oldest eligible unread completions/legacy notices with exact panel targets.

Show Notifications (default ⌘I; custom bindings preserved) opens the read-only Feed quick view: arrows select, Tab switches Asks/Turns, Return opens that exact panel, Esc restores the originating focus, and Turns shows finished turns without removing attention-jump targets.

Use `c11 feed answer` only for an eligible flag or `turn_end` row; in c11 1.0 it accepts single-line text only, sends one guarded paste to an exact empty/suggestion prompt, and reports whether retry is safe. Text containing a newline is refused as `multiline_unsupported` before typing; nothing is sent. Use `c11 feed open` to answer multiline text in the panel.

### Flag

```bash
c11 raise-flag --panel "$C11_PANEL_ID" "Need a call on schema migration vs dual-write"
c11 lower-flag --panel "$C11_PANEL_ID"
c11 launch-agent ... --flag "Watch the migration" --by operator
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
carry one**; the tier's power is its scarcity. Typing into the flagged panel lowers the
flag immediately — an operator's first keystroke of a reply is the answer arriving — so a
flag that vanishes mid-conversation was answered, not lost. Otherwise a dismissed flag was
*seen*: `flag.lowered` carries `by`, and operator dismissal without an answer means seen
and deferred — re-raise only if the blocker still stands and you can say why the deferral
doesn't. All four attention verbs accept `--by agent|operator`, defaulting to `agent`; pass
`--by operator` only when acting on the operator's instruction, so the event trail stays
honest.

Every raise sent from inside c11 also records the calling panel UUID as
`flag_caller_panel_id`; agent-originated raises are rejected when c11 cannot identify that
caller. An operator-originated raise outside c11 may omit it. This is attribution, not a copied
display identity: resolve the UUID against current panel metadata or conversation state, and
fall back to the raw UUID after the caller closes. `flag.raised` events carry the same
`caller_panel_id` plus `by`.

### Suppression

```bash
c11 suppress --panel "$C11_PANEL_ID"
c11 unsuppress --panel "$C11_PANEL_ID"
c11 launch-agent ... --suppressed     # set at dispatch by the parent
```

A suppressed panel never enters needs-attention: on stop its mark reads idle, and it is
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
c11 get-metadata --panel panel:12    # flag + flag_caller_panel_id / suppressed, when set
```

`tree` and `get-titlebar-state` do not carry attention state; `get-metadata` is the read.
`flag` and its caller UUID are absent rather than empty when unset. Parent-side monitoring patterns:
[references/orchestration.md](references/orchestration.md).

## Workspace folders

Folders are window-local records, not terminals. Start with
`c11 workspace-group list --json`; create an empty folder with
`c11 workspace-group create --name "Backend" --json`, then add ungrouped workspaces
with `c11 workspace-group add --group workspace_group:1 --workspaces workspace:2,workspace:3`.
Use UUIDs for durable references; `workspace_group:N` is an ephemeral handle, never
an ordinal to persist. Names can repeat and are not selectors.

All verbs accept `--window <ref|uuid>` and `--json`; omitted window means the caller's
window. `move --workspace <w> --to-group <g|none>` transfers a member. `delete` and
`ungroup` detach members without closing panels or processes; empty folders persist.
Group pin and workspace pin are independent. `focus` keeps an already selected member; changing to another member is blocked for socket callers. An empty folder returns `empty_group`.

`c11 reorder-workspaces --order workspace:3,workspace:1 --dry-run --json` predicts a
partial priority order within the pinned and unpinned segments. Remove `--dry-run`
to apply against current state. Membership and folder order stay unchanged.
`tree --all` shows folders and each member once, even when collapsed; its JSON keeps
flat `windows[].workspaces`, adds `workspace_groups`, and adds workspace `group_id`.
Use `c11 --id-format both … --json` when you need UUIDs and refs together.
Full verbs, errors and ordering: [API reference](references/api.md#workspace-groups-and-batch-order).

In the sidebar, the chevron hides/shows member rows without changing the active
terminal. Click the group name to focus a member. The header stays highlighted
when its active member is hidden. Its fixed slots show members, flagged panels,
unsuppressed waiting panels, and unread notifications separately, including hidden
members. Any flag makes the group signal violet, even on a suppressed or plain
terminal; unread alone does not add a waiting panel. Counts above 99 show `99+`,
with exact counts in accessibility labels and tooltips.

Use the header menu for Rename, Color, Icon, Pin/Unpin, Ungroup or Delete Group;
name/icon popovers accept Escape to cancel. New Group is in the sidebar menu.
Workspace menus offer Move to Group and Ungrouped. Drag onto a header to join,
onto member edges to position, or onto the Ungrouped lane to leave. Folder drags
reorder folders within their pin segment. Cancelled/invalid drops do not commit.
These controls organize existing work; deleting a group never closes its members.


## SSH workspaces

`c11 ssh <host>` opens a remote shell in a workspace. Remote-to-local c11 commands
are disabled in this version as a hardening change. Running `c11 <cmd>` or the
`cmux` alias inside that shell fails with "c11 commands are not available over
c11 ssh in this version". Use the local CLI to operate the workspace.

## What c11 can do — load the reference when you need it

| You want to… | Load |
|---|---|
| split / create / resize areas & panels, `tree`, `send`, `read-screen`, targeting, `--cwd` | [references/api.md](references/api.md) |
| launch a typed agent (`launch-agent`); save/list/launch reusable agent configs + read launch stats (`c11 config …`) | [references/api.md](references/api.md) |
| launch sub-agents, the panel-naming convention, layout patterns, write c11-aware prompts | [references/orchestration.md](references/orchestration.md) |
| send/receive inter-agent messages (the mailbox) | [docs/c11-mailbox-guide.md](../../docs/c11-mailbox-guide.md) |
| panel-manifest depth, sidebar reporting (`set-status` / `set-progress` / `log`), flash, precedence & sources | [references/metadata.md](references/metadata.md) |
| tail the file-first events stream (`c11 events tail`), envelope schema, v2 taxonomy | [references/events.md](references/events.md) |
| read and answer typed asks (`c11 feed list\|open\|answer\|watch`); generic input is unsupported | [references/api.md](references/api.md#feed) |
| workspace folders (`workspace-group`), membership transfers, atomic `reorder-workspaces` | [references/api.md#workspace-groups-and-batch-order](references/api.md#workspace-groups-and-batch-order) |
| workspace persistence, snapshots, conversation resume & lifecycle journal | [references/conversation.md](references/conversation.md) |
| read agent lifecycle, journal analytics & export | [references/journal.md](references/journal.md) |
| the Claude session-resume hook | [references/claude-resume.md](references/claude-resume.md) |
| drive the embedded browser (validate UI without leaving c11) | [c11-browser skill](../c11-browser/SKILL.md) |
| open markdown panels with live reload | [c11-markdown skill](../c11-markdown/SKILL.md) |
| fan one brief out to several agents (models, harnesses or approaches), then compare, judge and merge their results | [c11-fanout skill](../c11-fanout/SKILL.md) |

A few cross-cutting rules worth knowing before you reach for those:

- **Agents never change the operator's visible workspace.** Socket selection, workspace cycling and cross-workspace browser focus return `workspace_switch_blocked`; there is no setting or override. Raise a flag when the operator needs to look. Background panels support send, browser eval/click/snapshot, creation, agent launch and metadata. `focus-panel` and `focus-area` change focus inside their target workspace without selecting it. Hidden browsers can pause timers/video; ask the operator to view them when visible playback is essential.

- **There is no `c11 list`.** Enumeration is scoped: `c11 tree --all` (every window — the one to reach for when asking "is any agent working on X?"), `c11 tree --all --json` to script against, or `list-workspaces` / `list-areas` / `list-area-panels`. `c11 list` is *not* a command — it errors and prints usage, so `c11 list | grep <x>` greps the **error text**, comes back empty, and reads exactly like a clean "nothing found." Don't let a command that never ran become a confident answer: if an enumeration is empty and it matters, run it bare and confirm you got a tree.
- **Per-panel `prompt_cache` says whether an agent's next message re-caches its context.** Every panel in `c11 tree --json` / `panel.list` carries `prompt_cache`: `null` without cache evidence, else `{state: warm|cold, basis: ttl|estimate, lifetime_seconds, requested_at, cold_at, prompt_tokens}`. Prefer a warm agent, or message one before its `cold_at`, when the choice is free. Details: [references/api.md](references/api.md).
- **Per-panel `last_seen_at` says when the operator last looked at a panel.** Every panel in `c11 tree --json` / `panel.list` carries `last_seen_at` (ISO-8601, second precision, `null` = never seen) and `being_seen`. A panel is seen while it is the selected panel of the focused area in the selected workspace of the key c11 window, with c11 frontmost, the window on the active Space and visible, and the screen unlocked. Because it follows what is on screen, a socket focus change while c11 is in the background stamps nothing; while c11 is frontmost it stamps the panel that left and marks the new one `being_seen`. Details: [references/api.md](references/api.md).
- **`c11 history --json --limit 50` reads completed, dwell-qualified seen visits.** UUID targets survive restore; `history back` / `history forward` may focus within the selected workspace, while cross-workspace navigation returns `workspace_switch_blocked`. Live titles are returned but never persisted in history. The open visit is not listed. Schema, privacy and key bindings: [references/api.md](references/api.md#focus-history).
- **`send` / `set-status` / `log` take their text as a trailing positional, not `--text`.** `c11 send --panel <t> "npm test"`. `send --text "…"` is an unknown-flag error; use `--` before literal flag text.
- **`send` / `send-key` require explicit targeting.** Pass `--workspace` and `--panel` *together* when the target isn't your own panel; `--window` alone is not enough. An empty or stale ref (`--panel ""`, a dead `panel:99`) is an error, not a quiet fallback to whatever area is focused.
- **`send` checks input state on demand.** `input-state --panel <panel>` reports no prompt text, and `send` refuses a recognized draft or question/plan dialog unless `--allow-unguarded` is passed; the check is not atomic with a later keypress, `send-key` is not guarded, and older apps report `unguarded`. A refused send exits nonzero and types nothing: never press Enter after it (chain `c11 send … && c11 send-key … enter`), and raise a flag if the operator is mid-draft.
- **A multi-line `send` arrives whole and becomes one turn**, in a background workspace as reliably as in the focused one. Brief a sibling agent directly; you don't need to stage the text in a file and send a pointer.
- **`c11 rpc <method> [json]` is a local raw socket call** for methods without a friendly command. Prefer the command when one exists; remote calls over `c11 ssh` remain unavailable.
- **Socket/CLI commands never steal macOS focus**, and telemetry commands run off-main — don't expect a `send` to raise a window. The one exception is the explicit `c11 focus-window --window <id>` command, which raises and activates its target window (it never changes which workspace a window shows). Global `c11 --window <id>` scopes the command without raising that window. A panel or workspace outside the scoped window is an error.
- **Send modes and status:** default `send` decodes literal `\n`, `\r`, `\t`; `send --raw` and `paste` preserve escapes and newline content. `send -` reads stdin; `paste` reads stdin when text is omitted. For raw/paste, `--no-submit` suppresses c11's extra Return; default send still treats a trailing newline as submit. `delivered` means PTY input, `queued` means waiting for attach, and `submitted` means Return scheduled, never agent acknowledgment. [Delivery details](references/api.md#reading--sending).
- **`send` reaches PTYs only.** It cannot drive AppKit/SwiftUI controls (the text box, settings, sidebar, find overlay). For those, ask the operator or use accessibility automation.

### Two channels for agent communication

- **`c11 send` is a direct poke.** It types into a target panel's PTY and submits one turn, and c11 records the full text as a `panel.input_sent` event. Use it for a nudge, short brief, or immediate instruction; it is not the durable completion or blocker record.
- **`c11 mailbox send` is durable coordination.** Its envelope and body are recorded through `mailbox.accepted` / `mailbox.delivered` events, with delivery marked `via: push|drain|inbox`. Use it for requests, handoffs, completion reports, and recoverable blockers. A waiting agent that opted into push (`mailbox.delivery=stdin`) gets a new turn; a busy agent gets mail at its turn boundary.
- **Opt into push only for an agent-owned interactive panel.** Set `mailbox.delivery` to `stdin` during orientation. c11 checks foreground ownership and raw-mode input before typing; plain shells, one-shot commands, and other programs are left with their inbox mail. Claude and Codex drain at turn boundaries through their wrappers/hooks; Grok relies on push. `c11 mailbox recv --drain` is the explicit floor.
- **`c11 messages view` is the traffic view.** It opens the live recorded timeline in a c11 browser panel without taking focus; `c11 mailbox view` is the mailbox spelling of the same view.

## Panel bar and panel sheet

**The strip.** Panels stay visible: when they overflow, the strip scrolls sideways (edge fades show more off either end; a vertical wheel or two-finger scroll over it scrolls it too) and folds into the solid block only when under about 150pt remain for panels after the count cell and controls. With "Show Panel Numbers in Panel Titles" on, each panel carries its number in mono, gold on the visible panel.

**The count cell** (`● ⌄ N`: attention dot, chevron, number) is on every bar. In the default layout it opens the area's panel sheet, a drawer exactly as wide as its area (320pt minimum): one two-line row per panel with its number (`Panel 171`) and, under it, the panel's lifecycle mark, type (an agent as `Harness · model`, tinted by model family like the Claude Code statusline: Fable purple, Opus white, Sonnet blue, Haiku pink, others cyan; otherwise `Terminal`, `Browser` or `Markdown`; the model is the one the agent is actually using, read from its own session files: an agent's `set-agent --model` wins, then the detected model, then what `launch-agent` asked for), the state word with how long **that state** has held (`working 12m`, `waiting 6m`, `flagged 14m`, `idle 48m`), the live description as the subtitle (cwd, host or file path when there is none), and clocks. Columns drop by area width: 820+ everything, 600-819 the first clock only, 440-599 the type moves to line 2 and clocks go, under 440 just number (with its mark), title and status. Hovering a row lights its panel in the strip and the reverse. **Active** is the time since something was *added* to the panel, per type: an agent panel, its last assistant message or tool result (from the transcript); a plain terminal, the later of output that scrolled the scrollback while the panel was visible and the last command start or finish (a hidden terminal sees command edges only); a markdown panel, its last content change (file mtime at load); a browser panel, its last page load. Operator input is never part of Active. **Launched** is the time since it opened; **Seen** is the time since the operator last looked at the panel (`now` while they are looking; `—` if never). Opt-in clocks, not in the default order (`active,seen,launched`), and with no signal a clock reads `—`: `touched` (last keystroke or click by the operator, including typing in the text box; keys `c11 send` synthesizes do not count), and for agent panels `turn` (how long the current or last turn ran), `tools` (tool calls this turn), `tokens` (fresh input + output tokens this turn; opencode shows its session total, and opencode/Grok/Kimi/Copilot have no turn data) and `cache` (time left on the agent's prompt cache, `~` for an estimate, `cold` once expired; Claude Code, Codex and Grok Build). The clock order is one ordered list, a user default read each time a sheet opens (unknown names ignored). Write it as a string, or as an array:

```bash
defaults write com.stage11.c11 c11.panelSheet.clocks -string "launched,active"
defaults write com.stage11.c11 c11.panelSheet.clocks -array launched active     # same
defaults write com.stage11.c11 c11.panelSheet.clocks -string "active,touched,turn,tools,tokens"
defaults write com.stage11.c11 c11.panelSheet.clocks -string "active,seen,launched"   # back to the default
```

**Panel Layout** is a setting: `strip` (default) or `rail`. In `rail` the count cell toggles a vertical panel list docked on the area's left edge (about 38% of the area, 200-300pt; it pushes the content over), the bar shows the visible panel's `Panel N · title`, and each area remembers its rail open or closed across relaunch. The panel sheet's footer and the rail's header both carry a `Strip | Rail` switch for the same setting: Rail from the sheet closes the sheet and opens that area's rail; Strip from the rail closes that area's rail first, so a later Rail starts it closed. It is also in Settings > General > Areas & Panels > Panel Layout. Change it in one command:

```bash
defaults write com.stage11.c11 panelLayoutMode -string rail     # or: strip
defaults write com.stage11.c11 panelLayoutMode -string strip    # back to the default
```

When the panel bar overflows on 4 days inside 14 and Panel Layout is still Strip, c11 may offer one tip under the count cell: the number opens the panel list, Try Rail switches Panel Layout to Rail for every area and the tip becomes Undo (Undo puts Strip back and is not a dismissal), and Don't show again retires it. Leaving the tip alone waits 30 days. To force one showing without those waits, `defaults write <domain> c11.panelRailTip.forceOffer -bool true` (same domain as `panelLayoutMode`). That write takes effect at the next panel change, window switch, or app switch. The next overflowing area offers the tip once, then that flag clears itself. It does not override Don't show again. Reset the recorded days, the last offer, and a dismissal by writing their defaults: `c11.panelRailTip.overflowDays -array`, `c11.panelRailTip.lastOffered -string ""`, and `c11.panelRailTip.dismissed -bool false`. Reset by writing, not `defaults delete`: on a machine upgraded from 0.67, a deleted key falls back to the pre-1.0 value.

A tagged dev build has its own domain, `com.stage11.c11.debug.<tag>` with the tag's dashes as dots (tag `panel-bar-round-five` is `com.stage11.c11.debug.panel.bar.round.five`).

The bar under the panels shows only the panel's description (`c11 set-description`); with no description it takes no height.

## Editing this skill

It installs as a **one-time copy** into each agent harness's skills folder (`~/.claude/skills/c11/`, `~/.codex/skills/c11/`, …); the app does not track the repo source after install. After any source edit, run `scripts/sync-installed-skills.sh c11` or the live copy agents load stays stale (until 1.0 is installed, follow the sync hold in the repo's CLAUDE.md). This is the skill-editing equivalent of `reload.sh` after a code change.

## Troubleshooting

If `c11` on PATH isn't the active bundle's CLI, run `c11 doctor` (`--json` for machine-readable). It reports the bundled CLI path, how `c11` resolves on PATH, and a `status` of `ok | mismatch | missing | no_bundle`.

Working Lattice tickets inside c11? Also load the `lattice` skill for the integration patterns.

### Read a terminal selection

Use `c11 read-selection --panel panel:2 --json` to read what the operator highlighted, without changing the selection. No selection is a successful empty result; browser/markdown panels are unsupported. Discovery feature: `read_selection.terminal` version 1. Response cap: 1 MiB on a UTF-8 boundary; `truncated` reports clipping. Retry `busy` later; worker wait is limited to five seconds. Native capture/formatting/allocation and copy/free stay on main, so that wait limit is not a native time/allocation bound. See [API reference](references/api.md#terminal-selection).
