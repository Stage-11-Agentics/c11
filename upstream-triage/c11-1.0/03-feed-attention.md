# 03 · Feed, and replying to agents from notifications

Scoping for c11 1.0. Read-only research, 2026-10-01. cmux citations are at `upstream/main` = `920ff39ff7` unless they name the installed 0.64.25 bundle. c11 citations are at `main` = `d63b937f6`. "Inferred" marks anything not read directly in code.

**Needs you:**

1. **Widen the wrapper rail to carry attention payloads?** c11's wrappers already inject hooks per process (Claude `--settings`, Codex `-c notify=`, OpenCode `OPENCODE_CONFIG_CONTENT`, Pi `--extension`). The doctrine limits them to "the minimum needed for session resume ... plus lifecycle status" (`CLAUDE.md`, "unopinionated about the terminal"). A Feed needs a bit more: the question text, its options, the tool that is waiting, and the last message.
   - Yes: the doctrine gets a one-line amendment. The rail becomes "observe-only lifecycle and attention signals, per process, no persistent writes, no decisions." Feed items for Claude, Codex and OpenCode become structured (options you can pick).
   - No: Feed items come from screen reads only. They show readable text, but option picking is limited to what a screen parser can find.
2. **Ever adopt cmux's blocking decision bridge?** cmux parks a synchronous `PermissionRequest` hook and answers through hook stdout JSON. That is robust, but it puts c11 inside the agent's control path, which is a clear doctrine break.
   - Never: c11 answers only by typing into the PTY, after re-reading the screen. This is our assumption in the plan below.
   - Later, as an opt-in: worth it only for sessions that are not in bypass mode. Most of your fleet runs `--dangerously-skip-permissions`, where Claude never fires that hook for questions or plans (see "The gap").
3. **Feed order: queue or stack?** Today ⌥V takes flags oldest first, then waiting newest first (`Sources/AppDelegate.swift:10456-10484`).
   - Queue (oldest first everywhere): this is fairer across 30 agents, and Feed and ⌥V become the same list. This is my recommendation.
   - Keep the stack for waiting: the most recent context stays freshest in your head, but old asks starve.
4. **Do turn-ends belong in the Feed?** "Claude finished" is the most common event by far.
   - Default Feed shows only blocking asks and flags, with turn-ends under a second filter. This is my recommendation, and it matches cmux's "Actionable" versus "All Activity" split.
   - Turn-ends are first-class rows: you get a reply box on every finished turn, but the list is noisy at fleet scale.

## Summary

- **Feed in cmux:** one list of "an agent is blocked on you" items across every workspace. It appears in a right-sidebar mode, a keyboard TUI, and actionable macOS banners. Answers go back to the agent as hook JSON, not keystrokes.
- **What actually reaches you in bypass mode:** questions, plan approvals and turn-ends, not permission prompts. cmux's decision bridge does not fire for any of these in bypass mode.
- **What c11 has:** most of the pieces (waiting state, flags, ⌥V, `send`, `send-key`, `read-screen`, a notification store), but no structured "why it's waiting", no reply path, and three bugs that would corrupt a Feed.
- **Recommendation:** a c11 Feed that is a projection of one open "ask" per surface plus flags. It is fed by per-process hooks and screen reads. It answers by typing into the PTY after re-verifying the screen, and it lives first as a ⌘I quick view, a `c11 feed` CLI and actionable banners.

## What cmux built

### Lineage

| PR | Date | What |
|---|---|---|
| #3057 | 2026-04-26 | Original Feed: right-sidebar mode, hook bridge, `WorkstreamStore`, `feed.*` socket verbs, banner categories, `cmux feed clear` |
| #3217 | 2026-04-29 | `cmux feed tui` (OpenTUI and legacy Swift) |
| #5174 | 2026-06-01 | Feed gated behind Beta Features, off by default (current state) |
| #8670 | 2026-08-09 | Inline banner replies, schema-driven reply shapes, notification debug mode |
| #8968 | 2026-07-27 | Blocking becomes an explicit per-agent capability; unknown sources are telemetry only |
| #11917 | 2026-09-04 | Banner text reply switched from `send_text` plus CR to bracketed paste plus a named Return |
| #14960 | 2026-09-27 | Clicking a Feed banner opens the agent's pane |
| #15170 | 2026-09-29 | A pending request retires when Claude's prompt is answered in the terminal |
| #15888 | 2026-10-01 | Agent Inbox quick view (⇧⌘I), behind a PostHog flag, off by default |

### How items get in

The path is: agent hook → `cmux hooks feed --source <agent>` (`CLI/cmux.swift:40962`) → socket `feed.push` (`Sources/TerminalController.swift:6202`) → `FeedCoordinator.ingestBlockingWithOutcome` (`Sources/Feed/FeedCoordinator.swift:251`) → `WorkstreamStore` and `~/.cmuxterm/workstream.jsonl`.

For Claude there is no config write. The bundled wrapper (`/Applications/cmux.app/Contents/Resources/bin/cmux-claude-wrapper`) passes a temp `--settings` file. I printed the injected settings with the read-only `cmux hooks claude inject-settings`. They include:
- a synchronous `PermissionRequest` hook running `cmux hooks feed --source claude` with a 125 s timeout;
- `Stop` and `SubagentStop` running `hooks enqueue claude feed`;
- lifecycle hooks for SessionStart, Notification, UserPromptSubmit, PreToolUse and SessionEnd;
- a PostToolUse hook on `PushNotification`;
- `preferredNotifChannel: notifications_disabled`.

Only five sources can block (`CLI/FeedEventClassifier.swift:261-341`); everything else is telemetry only (`:364`):

| Agent | Blocking card? | Channel back to the agent |
|---|---|---|
| Claude | Yes: permission, AskUserQuestion, ExitPlanMode (all via `PermissionRequest`) | Hook stdout JSON |
| OpenCode | Yes: permission, question, forms | Plugin calls OpenCode's own API (`Resources/opencode-plugin.js:116-189`) |
| Gemini, Kiro | Yes, side-effecting tools only | PreToolUse JSON; Kiro uses exit code 0 or 2 |
| Codex | No. Approval stays in Codex so "Approve for me" keeps working (#5507). Exception: `cmux codex-teams` | Codex Teams: app-server JSON-RPC |
| Grok, Copilot, Kimi, Cursor, Pi and others | No, activity rows only (the docs over-claim this) | n/a |

The bridge really does block. `runFeedHook` stamps `_hook_sent_at_ms` after an ordering barrier, sends `feed.push`, and waits on a synchronous socket read (`CLI/cmux.swift:41478-41495`). The app parks the socket worker on a semaphore keyed by `request_id` (`Sources/Feed/FeedWaiterRegistry.swift:40`). The budgets are: process 120 s, client 118 s, decision wait 115 s (`CLI/CMUXCLI+AgentHookDefinitions.swift:8-10`). Any outcome other than a decision prints `{}`. Claude runs that hook in parallel with its own terminal dialog (#15170 PR body), so the terminal prompt is visible the whole time.

### What an item holds

`WorkstreamItem` (`Packages/macOS/CMUXAgentLaunch/.../Workstream/WorkstreamItem.swift:47-71`) has these fields:
- `id`, `workstreamId` (`<source>-<sessionId>`), `source`, `kind`
- `status`: pending, resolved, expired or telemetry
- `payload`: tool name and input, or plan text, or questions with options
- `context`: last user message, assistant preamble, plan summary, permission mode
- `reply`
- `ppid`

Expiry happens in three ways:
- **Timeout.**
- **Supersession** (#15170): the session's next hook expires the item (`FeedCoordinator.swift:560-625`).
- **Agent exit:** a kqueue watcher fires when the agent's PID dies (`:149`).

History is append-only JSONL with secrets redacted (`WorkstreamPersistence.swift:235-280`). Memory holds 2,000 items.

### How you act on one, and what the agent sees

Every UI calls `FeedCoordinator.deliverReply` (`:511`). For Claude, `renderAgentDecision` (`CLI/cmux.swift:41783`) prints:

| Action | Claude receives |
|---|---|
| Permission Once / Always / All | `allow`; Always and All echo Claude's own `permission_suggestions` back as `updatedPermissions`, so Claude may persist a rule |
| Permission Deny | `deny`, "User denied permission via cmux Feed." |
| Question | `allow` with `updatedInput` = tool input plus `answers{question: option}` (`:42075-42095`). The TUI menu is never keyed |
| Plan Manual / Auto | `allow`; Auto adds `setMode auto` for the session |
| Plan Revise (text) | `deny`, "User rejected the plan via cmux Feed and wants this change: <text>" (`:41918-41954`) |
| Stop card "Reply to Claude" | The only Feed path that types into the PTY (`FeedJumpResolver.swift:183`) |

Jump: double-click or Enter on a row calls `focusIfPossible`, which resolves the pane through `~/.cmuxterm/<agent>-hook-sessions.json` (`Sources/Feed/FeedJumpResolver.swift:10`).

### UI

- **Right sidebar Feed mode** (`Sources/Feed/FeedPanelView.swift`):
  - ⌘⌥B opens the sidebar, then ⌃4 selects Feed.
  - It has an Actionable filter and an All Activity filter, and a pending-count badge.
  - Permission rows show Deny / Once / Always / All.
  - Plan rows show rendered Markdown, a "Tell Claude what to change" field, and Ultraplan / Manual / Auto.
  - Question rows show option chips, free text, and "Skip interview".
  - Keyboard: J/K to move, Enter to jump, Esc to go back. The sidebar has no single-key approve.
- **`cmux feed tui`** polls `feed.list {pending_only:true}` every second and lists pending items only. Keys:
  - Enter: allow once, or the plan default.
  - `a`: always or auto.
  - `l`: all tools.
  - `m`: manual. `u`: ultraplan.
  - `f`: feedback prompt.
  - `d`: deny.
  - `1` to `0`: pick an option.
  - `j`/`k`: move. `r`: refresh. `q`: quit.
  - There is no jump key (`Resources/feed-tui/index.ts:461-548`; legacy `CLI/cmux.swift:40412-40495`).
- **Banners** (`Packages/macOS/CmuxNotifications/.../NotificationDeliveryCoordinator.swift:107-224`):
  - Permission banners have Once / Always / All / Deny.
  - Plan banners have Ultraplan / Manual / Auto / **Revise…** (text input).
  - A single-select question with 1 to 4 options gets a category minted per request, one button per option, plus "Other…" when there are 3 or fewer options (`FeedCoordinator.swift:1321-1330, 1503-1577`). Anything bigger opens the app.
- **There is no menu bar integration.**

### Reply from the banner (#8670, #10511)

There are two lanes behind one UX:

1. **Text reply.** It applies to `turn-complete` and `idle-reminder` notifications, and to `cmux notify --reply` (`TerminalNotificationReplyShape.swift:22-29`). The text goes into the PTY:
   - `AppDelegate+NotificationDeliverySeams.swift:135-177` calls `v2MobileTerminalPaste` (`TerminalController.swift:16144`).
   - That does a bracketed paste, waits 150 ms, then sends a separate named Return. For multi-line Claude text the Return becomes ⌃↩.
   - The reply is bound to the exact surface id, with an in-flight lock and a re-check of the surface generation before Return.
   - It does **not** check that the agent is still at the same prompt. A late reply becomes a new prompt (inferred from the code path).
   - Notifications from remote origins can never carry a reply (`TerminalNotificationStore.swift:1160-1166`).
2. **Decision buttons.** These are the Feed decisions above. The button resolves the parked hook and nothing is typed.

#10511 relays iOS lock-screen replies through a presence worker. It does not matter for macOS, except that it confirms `v2MobileTerminalPaste` is the single reply sink on every path.

## How Atin could try Feed today (cmux 0.64.25)

Feed is a Beta toggle and is **off** on this machine (`rightSidebar.beta.feed.enabled` is absent from `com.cmuxterm.app`; default false at `Sources/App/WorkstreamRuntimeSettings.swift:481-492`). Claude telemetry is already flowing: `~/.cmuxterm/workstream.jsonl` holds 202 Claude rows from today and zero permission rows.

### Minimal path: Claude only, nothing written outside cmux's own state

| Step | What it writes |
|---|---|
| 1. Open a terminal **in cmux.app, not c11**. | nothing |
| 2. Settings › Beta Features › Feed on (or ⌘⇧P, "Feed"). | cmux pref `rightSidebar.beta.feed.enabled` |
| 3. `type -a claude`; the first hit must be under `cmux-cli-shims/<uuid>/claude`. | nothing |
| 4. Optional: `export CLAUDE_CONFIG_DIR=~/.claude-profiles/alpha` and `export CMUX_COMPUTER_USE_MCP_DISABLED=1`. The wrapper otherwise attaches cmux's computer-use MCP and strips `ANTHROPIC_*` env. | nothing |
| 5. Run `claude` **without** `--dangerously-skip-permissions`, since bypass mode fires no PermissionRequest. Trigger a Bash approval, a plan, and an AskUserQuestion. | temp `--settings` file in `$TMPDIR`; rows in `~/.cmuxterm/workstream.jsonl` |
| 6. ⌘⌥B then ⌃4 opens Feed. Or run `cmux feed tui --legacy` in a second cmux pane (`--opentui` runs a bun install into `~/.cmuxterm/feed-tui-opentui`). | (OpenTUI only) that directory |
| 7. Click **Once** or **Deny** only. Always and All echo Claude's suggestions back, and Claude may persist a permission rule (inferred). | possibly a Claude permission rule |

`cmux hooks setup` never touches `~/.claude/settings.json`; Claude is not in its agent list (`CLI/cmux.swift:42250-42329`).

**Never run bare `cmux hooks setup`.** It installs into every detected agent: Codex (`~/.codex/hooks.json` and `config.toml`), Gemini (`~/.gemini/settings.json`), OpenCode and others. It rewrites JSON with sorted keys and makes no backups (`:34620`).

**Do not run cmux's CLI or wrapper from a c11 terminal.** c11 sets the legacy `CMUX_SOCKET_PATH` to its own socket, so cmux's hooks would talk to c11, find no `feed.push`, and fail open with an empty Feed (inferred).

**Undo:**
- Turn the Beta toggle off, or `defaults delete com.cmuxterm.app rightSidebar.beta.feed.enabled`.
- Optionally run `cmux feed clear --yes` (deletes only `workstream.jsonl`).
- `rm -rf ~/.cmuxterm/feed-tui-opentui`.
- If you clicked Always, remove that rule from Claude's settings by hand.

**Optional extras:**
- **OpenCode** gets real Feed decisions. `cmux hooks opencode install --project` writes only `./.opencode/plugins/cmux-feed.js`. Undo with `... uninstall --project`.
- **Codex** gets no decisions (telemetry only) and edits both `~/.codex` files. Skip it.

## What c11 has today

| Piece | Where | What it does |
|---|---|---|
| Waiting state | `Sources/SurfaceLivenessDeriver.swift:13-16` | A surface is waiting while it has an unread notification that suppression does not hide. Working and idle come from `activity` metadata; cold means idle for 10 min (`Sources/SidebarStalenessSettings.swift:99-127`) |
| Claude hooks | `Resources/bin/claude:205-236`; handler `CLI/c11.swift:16161-16604` | Per-process `--settings` tempfile with SessionStart, Stop, SessionEnd, Notification, UserPromptSubmit and async PreToolUse. The Notification text and `notification_type` become a subtitle: Permission, Waiting, Error, Completed or Attention (`:16931-16981`). Stop keeps the last assistant message (`:16840-16879`). AskUserQuestion's question and `[option]` labels are saved at PreToolUse (`:16529-16558`) |
| Codex | `Resources/bin/codex:207-217` | Per-process `-c notify=[wrapper,"__c11-notify"]`. Turn-complete only, empty body |
| OpenCode | `Resources/bin/opencode:73-92`; `skills/opencode-plugins/c11-notify.js:91-111` | Runtime plugin via `OPENCODE_CONFIG_CONTENT`. Sends "Waiting for input" and "Approval needed" |
| Pi | `Resources/bin/pi:139` | `--extension pi-lifecycle.ts`, working and idle only |
| Grok, Copilot, OMP | `Resources/bin/{grok,copilot,omp}` | Identity and resume only, no attention signal |
| Flags and suppression | `Sources/AttentionModel.swift:34-71, 378-450` | One commit path. Events `flag.raised {reason, caller_surface_id, by}` and `flag.lowered {by}` (`Sources/Events/EventEmitter.swift:142-171`). Any keystroke lowers the flag (`Sources/GhosttyTerminalView.swift:5620-5626`). `flag.lower` carries no answer or resolution |
| ⌥V | `Sources/AppDelegate.swift:10456-10484` | Oldest flag first, then newest unread, skipping suppressed tabs. ⌥V is Atin's binding; the code default is ⌃⌘↩ (`Sources/KeyboardShortcutSettings.swift:152`) |
| Notification store | `Sources/TerminalNotificationStore.swift:972-1027` | In memory, **one record per surface**; each event replaces the last |
| macOS banners | `Sources/AppDelegate.swift:12631-12649` | One category, one "Show" action. No text input, no buttons. Flag banners go out directly and pierce suppression (`TerminalNotificationStore.swift:1032-1097`) |
| Menu bar extra | `Sources/AppDelegate.swift:13311-13575` | Off by default. Unread badge, last 6 notifications, jump. **It never reads flags** |
| Notifications page and ⌘I popover | `Sources/NotificationsPage.swift`; `Sources/Update/UpdateTitlebarAccessory.swift:1006+` | Read-only list, click to jump. This is the closest thing to a Feed today |
| Mailbox | `docs/c11-mailbox-guide.md`; `Sources/Mailbox/StdinMailboxHandler.swift` | PTY push only at a shell prompt, so it almost never reaches a running agent. C11-257 (backlog) plans push-when-waiting |
| Reply primitives | `CLI/c11.swift:2765-2856`; `Sources/TerminalController.swift:6579-6646` | `send` is a bracketed paste plus one real Return after a settle delay, and works in background workspaces. `send-key` sends named keys. `read-screen` reads any started surface |
| Events | `skills/c11/references/events.md` | `waiting.entered` and `waiting.left` are per workspace with no payload |

### Overlap with c11's thesis

Flags already are an attention queue with attribution. The C11-184 review framed them that way: "`flag.list` is the queue read, ⌥V is the pop" (`.lattice/plans/c11-184-plan-review-pack-2026-07-28T1726/synthesis-evolutionary.md:14-20`). Feed adds three things c11 lacks:

1. **A reason.** Each item says why the agent waits, and what it is asking.
2. **One list.** It covers every workspace and you read it in one place.
3. **An answer channel.** You answer from the list, not by switching panes.

c11's flag and suppression model has no equivalent in cmux, and it should govern the Feed rather than be replaced by it.

## The gap

### Bugs a Feed would expose (fix first)

1. **Claude hooks clear the whole workspace.** Prompt-submit, pre-tool-use and session-end send `clear_notifications --tab=<workspace>` (`CLI/c11.swift:16372, 16454, 16562`). That reaches `TerminalNotificationStore.clearNotifications(forTabId:)` (`Sources/TerminalNotificationStore.swift:1233`) and removes **every** surface's notification in the workspace (handler at `Sources/TerminalController.swift:5701-5726`; verified). So one Claude starting a tool erases the waiting state of every sibling agent. With six agents in one workspace, this is common.
2. **Bypass-mode questions and plans never enter waiting.**
   - c11 saves the AskUserQuestion text and returns, on the assumption that "The Notification hook fires right after" (`CLI/c11.swift:16553-16555`).
   - cmux found that with `--dangerously-skip-permissions`, Claude fires neither PermissionRequest nor Notification for AskUserQuestion or ExitPlanMode (upstream `CLI/cmux.swift:29701-29709`, issue #6606, PR #6608).
   - ExitPlanMode is worse in c11: PreToolUse treats it as "working" and clears notifications.
   - Inferred for c11 from upstream evidence; high confidence. One bypass session asking a question would confirm it.
3. **The menu bar ignores flags.** The c11 skill says a flag "escalates to the menu bar extra" (`skills/c11/SKILL.md:60`). The code has no path for that (verified: the controller reads only `notificationStore.$notifications`).

### Missing pieces

- **No wait reason.** There is no permission / question / plan / turn-end type, only a keyword subtitle. A permission prompt loses the tool name and command. Options survive only as a flattened `[a] [b]` string.
- **No answer channel.** There are no banner actions, no reply UI, and no `flag.lower` resolution.
- **No payload on events.** Overwatch and any Feed UI must poll `notification.list` plus `flag.list`.
- **Codex has no question or approval signal.** Codex supports per-process hooks; c11 injects only `notify`.

### The bypass-mode fact that reshapes the design

Most of your agents run with `--dangerously-skip-permissions`. For them, permission prompts do not happen. The asks that reach you are AskUserQuestion menus, plan approvals, turn-ends and flags. cmux's decision bridge depends on `PermissionRequest`, so for those sessions it delivers nothing actionable for questions or plans. A c11 Feed built around questions, plans, turn-ends and flags fits your fleet better than a port of cmux's would.

### Lead's hypothesis: per-process hooks with zero tenant writes

The hypothesis holds for most agents. Verified on this machine:

| CLI | Per-process hook path | Verified how | c11 uses it today |
|---|---|---|---|
| Claude Code | `--settings <file>` (file, not inline JSON, on 2.1.x) | c11 and cmux both ship it | Yes |
| Codex 0.159.3 | `--enable hooks --dangerously-bypass-hook-trust -c hooks.<Event>=[...]` | `codex --help`; cmux's `hooks codex inject-args` prints exactly this, including PermissionRequest, Pre/PostToolUse, Stop and Subagent events | Only `-c notify=` |
| OpenCode | `OPENCODE_CONFIG_CONTENT` env (or `OPENCODE_CONFIG=/dev/fd/3`) | `Resources/bin/opencode:79-92` | Yes |
| Pi | `--extension <file>` | `Resources/bin/pi:139` | Yes |
| OMP | `--hook=<file>` / `-e <file>` | `omp --help` | No |
| Gemini 0.26 | `GEMINI_CLI_SYSTEM_SETTINGS_PATH` env (string present in the bundle) | Present, but how it merges hooks is untested | No wrapper |
| Grok | No hook flag. `GROK_CONFIG`/`GROK_HOME` exist, but redirecting home moves auth and sessions | `strings`, `grok --help` | n/a |
| Kimi Code | No hook flag. Only `KIMI_CODE_HOME` | `strings`, `kimi --help` | n/a |

So c11 can get cmux-grade lifecycle events for Claude, Codex, OpenCode, Pi and OMP with zero tenant config writes. Gemini is probable but needs one test. Grok and Kimi need screen reads.

Two caveats:
- **Codex hook trust.** `--dangerously-bypass-hook-trust` tells Codex to run hooks without stored trust. That is fine for scripts in c11's own bundle, but c11 is vouching for them. Without the flag, Codex persists hook-trust tables into `~/.codex/config.toml` (Atin's file already has them, `config.toml:340-363`), which would be a tenant write by proxy.
- **The OpenCode plugin is also installed as a file in OpenCode's config.** c11's skill installer copies `c11-notify.js` into `~/.config/opencode/plugins/` (`Sources/SkillInstaller.swift:58-61`; a file dated today is present), and the wrapper also loads it at runtime. That is a tenant write outside the wrapper rail, and it may load the plugin twice (inferred). Worth a look regardless of Feed.

## Proposed c11 1.0 shape

### Principle

The Feed is a **projection**, not a new store of requests. A TUI agent can block on only one thing at a time, so c11's existing "one record per surface" model is actually the right shape.

The Feed is the set of surfaces that have an **open ask** or a **flag**, ordered like ⌥V. This avoids cmux's request-id and waiter machinery. It also stays well clear of the epochs, markers and coordinators that sank C11-188 (`docs/aar-c11-188-attention-loop.md`).

### Data: an "ask" on each surface

Extend the per-surface notification record into a typed ask:

- `kind`: `question | plan | permission | turn_end | input` (generic) `| flag`
- `prompt`: the question text, plan summary, or `tool: command`
- `options`: labels, in on-screen order, when known
- `source`: `hook | screen | flag`
- `opened_at`, `state`: `open | answered | moved_on`
- `screen_fingerprint`: a hash of the prompt region at open time

Rules:
- **Opens:** a hook (Claude Notification with `notification_type`; Claude PreToolUse for AskUserQuestion and ExitPlanMode; Codex PermissionRequest and Stop through new per-process hooks; OpenCode `permission.asked` and `question.asked`). Or a waiting edge with no hook payload, which triggers one `read-screen` and a prompt classifier.
- **Closes:** the next lifecycle event **from that surface** (prompt-submit, a tool start, stop), an answer sent through the Feed, or operator typing. One surface, latest wins, no IDs.
- **Events:** `ask.opened` and `ask.closed`, with kind, prompt, options and surface. Overwatch can then subscribe instead of polling.
- **Flags:** a flag is a Feed row. Replying to it sends text and lowers it with `resolution: answered`. That ships C11-184's unshipped "reply on lower".
- **Suppression:** suppressed surfaces stay out unless flagged. This is unchanged doctrine.

### Answering: verify, then type

Every answer goes through c11's existing PTY path. Nothing blocks the agent.

1. Run `read-screen` on the surface.
2. Re-match the ask's fingerprint, and confirm the prompt line holds no unsent operator text. Remember that Claude's ghost auto-suggest reads as typed text (`skills/c11/references/api.md:272`).
3. If either check fails, do not type. Jump to the tab instead and say why.
4. Otherwise send the keys:

| Ask | Keys sent | Confidence |
|---|---|---|
| turn_end / input / flag reply | `send` (bracketed paste plus Return) | Exists and is robust today |
| question (Claude) | the option's digit (Enter if needed); free text via the "Type something" row, then paste | **Needs a spike**: confirm Claude's digit hotkeys per version |
| plan (Claude) | the digit for Approve; Revise = the "No, keep planning" digit, then paste the feedback | **Needs a spike** |
| permission (Claude, non-bypass) | `1` Yes, `2` don't ask again, `3` No then feedback | **Needs a spike** |
| Codex approval | Codex's approval keys | **Needs a spike** |
| anything unrecognised | none; jump only | n/a |

The menu-key mappings belong in one small, versioned table per agent. Each entry should have screen fixtures captured from real sessions, so that a TUI change fails one test, not your reply.

### Alternatives

| Option | Pros | Cons |
|---|---|---|
| **A. Projection plus verify-then-type** (recommended) | Agent-agnostic; works in bypass mode; no doctrine break; reuses `send`, `send-key`, `read-screen` | Menu typing depends on TUI layout; needs fixtures and a fail-to-jump fallback |
| B. Port cmux's blocking bridge for Claude | Exact answers through hook JSON; no screen parsing | Doctrine break; c11 sits in the agent's control path (a c11 hang stalls the agent until timeout); does nothing for bypass-mode questions or plans; Claude only |
| C. Screen reads only (no hook payloads) | Purest "observe from outside"; covers Grok and Kimi | Prompt text is a guess; options are fragile; much more parsing code |
| D. Read-only Feed (list and jump, no answers) | Smallest; zero risk | Misses the point: you still switch panes for every answer |

A is our assumption. It uses C as the fallback for agents with no hooks, and D as the fallback for any ask c11 cannot verify.

### UI sketch

Build the projection and CLI once, then put three surfaces on top of it:

**1. Quick view (primary).** The ⌘I popover becomes the Feed: a floating, keyboard-first list that you summon anywhere and dismiss with Esc. ⌥V keeps its meaning, "go to the top item."

```
 Feed · 4 open                                     ⌘I
 ⚑ violet  Schema Migr.  ws:Billing   14m  flag
           "Need a call on schema migration vs dual-write"
 ▸ ?       Feed Research ws:c11        6m  question
           Which UI should ship first?
           1 Quick view   2 Sidebar mode   3 Feed tab
   ▤       C11-212 Fix   ws:c11        3m  plan
           Plan: split socket handler, add test…
   ✓       Docs Writer   ws:Site       1m  turn end
           "Draft is in docs/feed.md; want a pass?"
 ─────────────────────────────────────────────────
 j/k move · 1-9 pick · ⏎ default · r reply · a approve
 v revise · o open tab · x seen · tab: Asks | All
```

- Rows are fixed height. The hint bar never changes size. States swap glyph and text but not layout.
- Order: flags oldest first, then asks oldest first (decision 3).
- `r` opens one inline reply field at the bottom (paste plus Return).
- `o` is exactly what ⌥V does for that row.

**2. Actionable banners.** These replace the single "Show" action with buttons per kind:
- question: up to 3 options plus "Other…" (text);
- plan: Approve and Revise… (text);
- turn_end and flag: Reply… (text) and Open.

They follow cmux's 4-action ceiling and its rule that an empty reply opens instead of sending. A banner answer goes through the same verify-then-type path.

**3. CLI, which doubles as a tab.**
- `c11 feed list [--json]`, `c11 feed answer <tab> <option|--text>`, `c11 feed open <tab>`, `c11 feed watch`.
- `c11 feed tui` runs in any terminal tab, which gives you "Feed as its own tab" with no new surface type.
- Overwatch reads `c11 feed list --json` as its attention view.

**Flag interaction:**
- A flagged row is pinned, violet, and strobes when the agent is also waiting, matching today's marks.
- Answering a flagged row lowers the flag with the answer attached.
- Dismissing with `x` lowers it as "seen, deferred", which is today's semantics.

**Menu bar extra:** add flags and the open-ask count, so the skill's claim becomes true. A sidebar mode (cmux style) is possible later. It would replace the Notifications page rather than add a right sidebar, which c11 does not have.

**Note:** the tab sheet and count cell described in the skill exist on the v0.67.0 release line, not on `main` (`git log -S c11.tabSheet.clocks` → `7cec0946cd`). The count cell's attention dot could open the quick view filtered to that area, but that wiring should land after main catches up.

## Effort and risk

| Phase | Work | Size |
|---|---|---|
| 0 | Fix the three bugs: scope Claude's clear to the surface; handle AskUserQuestion and ExitPlanMode at PreToolUse in bypass mode; make the menu bar read flags | S |
| 1 | Typed ask on each surface, `ask.opened`/`ask.closed` events, `c11 feed list/answer/open/watch`, skill update | M |
| 2 | Quick view (⌘I popover rebuilt), ⌥V order unified, menu bar flags | M |
| 3 | Verify-then-type answering: Claude menus spike, fixture table, fail-to-jump | M |
| 4 | Banner categories with buttons and text input, routed through phase 3 | S-M |
| 5 | Codex per-process hooks (`--enable hooks ... -c hooks.*`), OMP `--hook`, Gemini spike | S-M |
| 6 | Screen classifier for agents with no hooks (Grok, Kimi, plain prompts) | M |

Overall: **L**. Phases 0 to 2 alone are useful (a readable cross-workspace list with jump), and they carry little risk.

What could go wrong:
- **TUI drift.** Claude or Codex change their menus and digits pick the wrong option. Mitigations: verify the screen before typing, keep a per-version fixture table, and fall back to jump on any mismatch. Treat any wrong-option incident as a stop-ship.
- **Typing over the operator.** You are mid-sentence in that pane when a banner answer lands. Mitigations: the empty-prompt check, and the existing focused-surface rule (no banner for the surface you are looking at).
- **Flag attribution.** A Feed answer's synthetic Return lowers a flag "by operator" (`Sources/GhosttyTerminalView.swift:4023-4043`, inferred). That is correct, because you initiated it, but the answer text should ride on `flag.lowered`.
- **Re-living C11-188.** If reviews start demanding crash-durable request identity, stop. The design's correctness argument is "latest ask per surface, re-verified on screen at action time," and nothing more.
- **Doctrine creep.** Each new hook payload is a small widening. Decision 1 should set the boundary once: observe-only, per process, no persistent writes, no decisions.

## Open questions

1. Should the wrapper rail widen to observe-only attention payloads? (Needs you, item 1.)
2. Should a blocking decision bridge ever exist, even as an opt-in for non-bypass sessions? (Needs you, item 2.)
3. Should the Feed be a queue or a stack, with ⌥V following the same order? (Needs you, item 3.)
4. Should turn-ends be Feed rows or sit behind a filter? (Needs you, item 4.)
5. Should the OpenCode plugin file that the skill installer writes into `~/.config/opencode/plugins/` stay? The wrapper already loads it at runtime.
6. Should mailbox push-when-waiting (C11-257) share the Feed's delivery path? Both deliver text at a waiting edge, so one primitive would serve both. My lean is yes.
7. Phase 0 is independent of everything above. Should it be ticketed now as a bug batch?
