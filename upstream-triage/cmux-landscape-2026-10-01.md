# cmux since the fork (as of 2026-10-01)

**Needs you:** nothing blocking. Three optional decisions at the bottom.

## The numbers

- **Fork point:** `53910919`, 2026-03-18, between cmux v0.62.2 and v0.63.0.
- **Since then:** 17,553 commits and 6,275 merged PRs.
- **Pace:** 2,931 PRs merged in September alone. The last 300 merged in 31 hours, and one account (`teamleaderleo`) authored 220 of them, which looks like an automated agent pipeline.
- **Releases:** 29 (v0.63.0 through v0.64.25, the latest on 2026-09-17). Main also carries about 320 unreleased changelog entries.
- **Reach:** 27.5k stars, 2.4k forks, 3,078 open issues.
- **License:** relicensed from AGPL-3.0 to GPL-3.0 in v0.63.2 (#2364). c11 still carries AGPL-3.0 from the fork.
- **c11's last pull from upstream:** about 15 picks in April (C11-20, C11-21). The upstream-triage program set up in May has been idle since. Its catchup plan cites a 912-commit gap; the gap is now 17.5k.
- **Installed here:** cmux 0.64.25, which is running this session, and c11 0.67.0.

## The shape

cmux has moved in three directions at once:

1. **Agent session manager.** This direction is converging on c11's thesis: resume and fork for about 17 agent CLIs, session search, hibernation, an event-driven status model, and automation rules.
2. **Account-backed platform.** This is most of the volume and the least relevant to c11: Cloud VMs, an iOS companion app, mirroring across Macs, a headless TUI server, and a paid Founder's Edition.
3. **IDE-adjacent surfaces.** A diff viewer with review comments, a file editor, iOS Simulator panes, browser Design Mode, and a chat-style agent surface.

Their README still says "a primitive, not a solution," but in practice cmux now writes hooks into every agent tool's own config. That is the line c11 refuses to cross.

## What's new, ranked by relevance to c11

### 1. Agent session lifecycle (the biggest overlap)

- **Hook integrations for about 17 agent CLIs** through `cmux hooks setup`, giving notifications and resume for each. The list includes Claude, Codex, OpenCode, Gemini, Grok, Pi, OMP, Amp, Hermes, Kimi, Kiro, Antigravity, Cursor, Copilot, Rovo Dev and Campfire. c11 has PATH wrappers for 7 of them.
- **Fork Conversation** into a new split, tab or workspace (0.64.7 to 0.64.20). c11 lacks it, though c11's conversation store is the substrate a fork would build on.
- **Vault** (0.64.23): history of all sessions, search with `agent:`, `repo:` and `before:` operators, checkpoints, and fork from a checkpoint (`cmux vault ...`). c11 lacks it.
- **Agent Hibernation** (0.64.11), extended in 0.64.21 and 0.64.23 to trigger under memory pressure. c11 has manual workspace hibernate (C11-25) but nothing agent-aware or automatic.
- **Event journal drives sidebar status** (#10490). Running, Needs input, Idle and Error now come from a durable journal instead of text heuristics.
- **Restore hardening** (unreleased): `agents.launchers` declares wrapper launchers such as multi-account routers, so restore resumes through them. `launch_rejection_reason` explains why a captured launch was refused for restore.
- **Agents on SSH hosts** (unreleased): Claude Code and Codex running on a remote host report status to the sidebar (#14902). `cmux session move` moves a stopped session, with its transcript, memory and git tree, between the Mac and an SSH host (#14959). This maps directly onto the Atlas and Hyperion split.
- **Team launchers:** `claude-teams`, `codex-teams`, `omo`, `omx` and `omc` turn teammates into native splits through a tmux shim. c11 has only `claude-teams`.

### 2. Attention and automation

- **Reply from the macOS notification banner** (#8670, #10511). You can type a reply, pick an AskUserQuestion option, or hit Revise on a plan exit without switching panes.
- **Feed:** one queue of approvals and questions across all agents, with a keyboard TUI.
- **Automations rule engine** (#10654) in `~/.cmuxterm/automations.json`. Events such as `surface-needs-input` trigger notify, run, webhook or RPC actions, and rules support dry-run tests and logs.
- **`cmux events`:** a resumable NDJSON stream with a cursor file and reconnect. c11's `events tail` is close but lacks cursor and reconnect.
- **`cmux current`** (unreleased): one call returns workspaces, agents, attention items and PRs. This is the Overwatch view as a single CLI call.
- **`cmux todo`:** a per-workspace checklist that agents can write to.

### 3. CLI and socket hardening (the cheapest wins)

- **Strict socket arguments** (#13214). camelCase keys such as `surfaceId` are rejected instead of silently acting on the focused terminal. It's worth checking whether c11's v2 socket has the silent fallback.
- **Stable IDs** (`stable_surface_id`, #13247). A stale short ref like `surface:7` now fails as unknown after a restart instead of retargeting another terminal (#13633).
- **`--command` on `new-split`, `new-pane` and `new-surface`** (#9614). c11 has it only on `new-workspace`.
- **`cmux paste --submit`** with a `delivered` or `queued` result (#14837, #13849). Multi-line prompts arrive as a real paste.
- **Smaller additions:**
  - `read-selection` (#10022) and `resize-window` (#9826).
  - `--window` routing on every window-scoped command (#4211).
  - Batch `reorder-workspaces` with `--dry-run` (#4507).
- **Agent onboarding inside the CLI:** `cmux guide` and `cmux --skill` print the agent guide, `cmux capabilities` lists about 100 versioned feature flags, and `cmux rpc` makes raw socket calls. c11 ships its skill as a file instead.
- **`cmux config doctor`** validates settings against a published JSON schema.

### 4. Workspaces and layout

- **Workspace groups** (0.64.11): collapsible sidebar groups with color, icon and unread badge, plus a `workspace-group` CLI.
- **Saved layouts** with a default layout for new workspaces (0.64.18). c11's blueprints cover most of this but have no default-layout setting.
- **Per-workspace environment variables** (0.64.16).
- **Opt-in AI naming** of workspaces and tabs from the conversation (0.64.16).
- **Sidebar extensions:**
  - Dock: controls pinned in the sidebar, on by default.
  - Custom sidebars: run by a sandboxed interpreter that later moved out of process.
  - Right-sidebar modes: files, find, vault, sessions and feed.
- **Navigation:** focus history, Recently Closed, and Cmd+Shift+T to reopen the last closed item.
- **Experimental freeform 2D canvas** for panes.
- **AppKit sidebar rewrite** (0.64.20), after a long series of SwiftUI livelocks with many workspaces open.

### 5. New surfaces

- **Diff viewer** (`cmux diff`, including `--last-turn`). Review comments typed into it can be handed to an agent (`cmux comments list`).
- **File tools:** a file explorer, a file editor with syntax colors, and global search that now covers terminal scrollback.
- **`agent-session` surface:** a chat-style agent UI rendered in a React or Solid webview instead of a TUI.
- **iOS Simulator panes** with a `cmux ios` CLI for tap, swipe, permissions and camera.
- **Browser:**
  - Design Mode: annotate a page, then hand the changes to an agent.
  - Profiles, and import from 20+ browsers.
  - Passkeys, a URL allowlist, and an isolated WebKit process per pane.
  - A standalone "cmux Browser" build was submitted for Apple's passkey capability review. It declares http/https handling, so it could register as a default browser.

### 6. Computer use: `cmux-cua` (worth a look)

`cmux-cua` is a bundled computer-use driver: MIT-licensed, version 0.7.1. It is auto-attached as an MCP server to Claude and Codex sessions launched in cmux, which includes this one.

- **How it works:** it acts through the accessibility tree on background windows. It claims to do this without stealing keyboard focus or moving the visible cursor.
- **Extras:** each session gets its own colored agent cursor, and trajectories can be recorded and replayed.
- **Why it matters for c11:** the planned `c11-computer-use` validation skill, and the 2026-09-29 call that synthesized drags on Hyperion disrupt your live use. A focus-safe driver is exactly what that is missing.
- **Not verified here.** The no-focus-steal claim needs a test before anyone relies on it. Drags in particular probably still move things.

### 7. Platform bets (high volume, low relevance)

- **Cloud and teams:** cmux Cloud VMs (beta, account-bound, about 45 `vm` verbs) and CodeRouter, a team model plane.
- **iOS companion app:** peer-to-peer over Iroh, with push notifications and a Task Composer. The `cmux-terminal-client` xcframework (prereleases this week) is the embeddable client library behind it.
- **Remote sessions:** `cmux-tui`, a 77 MB headless server, owns sessions. Plain `cmux` starts or reuses the server and attaches to it, so agents outlive the GUI. Mosh, ssh-tmux and local-tmux build on it.
- **My Devices:** mirror workspaces from your other Macs (opt-in, needs an account).
- **Enterprise and odds:**
  - MDM policies.
  - Localization into 9 languages.
  - `cmux sudo`: root commands for agents behind a Touch ID prompt.
  - Founder's Edition paid tier.

## Where c11 is still distinct

- **No tenant config writes.** `cmux hooks setup` writes into 17 tools' config directories, and c11 refuses to. Much of cmux's agent-status machinery rides on that mechanism, so importing it means re-deriving it through wrappers or skill self-reporting.
- **Agent-written telemetry.** Per-surface metadata manifests, typed `set-agent` and `launch-agent`, flags and `area-confirm`, mailbox messaging between agents, and workspace roots.
- **Skills shipped in the app.** c11, lattice-orchestrator, the tone stages and others ship in the bundle, plus the Lattice integration.
- **Markdown surfaces are still first-class in c11, but the lead is narrowing.** cmux now has a markdown viewer with Mermaid and Vega.

## Bugs cmux fixed that c11 probably shares

These were found by grep and are not verified against c11.

1. **SwiftUI sidebar livelock** with many workspaces (#6033, #6188, #6870, #7117, #8211). cmux gave up and rewrote the sidebar in AppKit (#8270).
2. **Title churn causing typing latency and beachballs** (#8084, #8155, #10510).
3. **Bracketed-paste framing desyncing Claude Code's input parser** (#9875).
4. **Hidden or covered terminals holding Metal swap chains**, about 40 MB per surface (#10815, #10922).
5. **Leaked thread loops burning about 90% of idle CPU** (#8851).
6. **Socket faults:**
   - a crash when a connection closes mid-read (#13292)
   - SIGPIPE on closed pipes (#12503)
   - stale socket rebinding (#10058)
   - a CLI command arriving during restore crashing the app (#9627)
7. **Transient PTY sizes during reveal or restore corrupting TUI output.** The fix publishes the size only after geometry settles (#12662, #11528, #12796).
8. **Session autosave and restore:**
   - autosave hanging when a renderer is stuck (#14784)
   - restoring only empty windows wedging WindowServer (#14788)
   - two quick restarts wiping the saved layout (#14824)
9. **`read_screen` failing on never-shown background workspaces** (#14673). This matters for Overwatch-style reads.
10. **Focus:**
    - a hidden or zero-size terminal taking focus (#14276)
    - Ghostty focus needing to be reasserted before physical input (#7278)
11. **IME:** Japanese backspace deleting the whole composition (#13581), Korean rendering, and Option dead keys (#12997).
12. **Sentry conflict between the app and GhosttyKit's own initializer on Intel** (#9436).

## Recommendation

Our assumption stays the same: the divergence is deliberate, and there is no resync. At 17.5k commits behind and about 100 upstream PRs a day, importing one PR at a time cannot keep up. Treat cmux as a source of ideas and a bug oracle, not a merge target. In order:

1. **Bug-oracle sweep.** Check the 12 bugs above against c11 and ticket only the confirmed ones. Cheap, and high value.
2. **CLI hardening batch.** Strict socket keys, `--command` on splits, `paste --submit` with delivery status, `read-selection`, and stable IDs. These are small, agent-facing, and land straight in the skill.
3. **Feature bets that need your call:**
   - Fork Conversation plus Vault-style session search, built on c11's conversation store.
   - Inline replies from notification banners.
   - Agent-aware hibernation under memory pressure.
   - Workspace groups.

## Decisions (optional)

1. **Run the bug-oracle sweep now?**
   - Yes: one agent checks the 12 items against c11 source and files confirmed ones as Lattice tickets.
   - No: this file stays the record.
2. **Trial `cmux-cua` against a tagged c11 build?**
   - Yes: a bounded test of whether it can drive c11 without moving your cursor or stealing focus. A pass would make on-machine `c11-computer-use` validation viable on Hyperion.
   - No: it stays a note.
3. **Retire the stale catchup plan?** `upstream-triage/catchup/feature-catchup-plan.md` still frames a 912-commit forward sweep.
   - Yes: rewrite it around the "idea source plus bug oracle" stance above.
   - No: leave it.

---

Sources: the upstream `CHANGELOG.md` on main (v0.63.0 through Unreleased), `gh` release and PR metadata, the upstream README, and the `--help` output and bundle contents of the installed cmux 0.64.25. The "c11 has / lacks" calls come from greps of `Sources/`, `CLI/` and `skills/c11/`, not deep verification.
