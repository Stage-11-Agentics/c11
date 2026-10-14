# c11 1.0 topic 02: agents on SSH hosts, and moving sessions between machines

Research by SSH Agents Research, 2026-10-01. Sources: c11 `main` at d63b937f6, cmux `upstream/main` at 920ff39ff7, installed cmux 0.64.25, the Overwatch repo. Tags: **[R]** read in code or PR text, **[I]** inferred.

**Needs you:**

1. **Security: c11 has a live remote-to-Mac command execution hole in `c11 ssh`.** It is the bug cmux fixed as GHSA-9vmv-3hjw-j28c. After the HMAC handshake, c11's relay forwards any command line verbatim to the local socket, as the app, so the `c11Only` check passes (`Sources/Workspace.swift:3102-3124`). There is no method allowlist and no surface scoping. cmux describes the impact in `67d4dbde6e` (2026-08-13): a compromised remote host can run arbitrary commands on the Mac. Exposure is limited to the window when a `c11 ssh` workspace is open to a host where something hostile runs as your user. c11 is publicly released, so this is a production change and needs your named approval. The choice:
   - **(a) Fix now, outside 1.0 (my recommendation).** Port cmux's deny-by-default `RemoteRelayCommandPolicy` (`67d4dbde6e`, `b455514205`, `c4b0205843`) as a point release. Handle it privately: no public ticket that describes the mechanism until it ships.
   - **(b) Disable the relay now** and rebuild it in 1.0. Smaller change, but `c11 <cmd>` inside `c11 ssh` stops working, and I would guess almost nobody uses it.
   - **(c) Leave it for 1.0.** The hole stays open in shipped builds until then.
2. **Does a remote agent live in a tab or in a workspace?** `c11 ssh` and cmux both make a whole workspace remote. You described "a c11 tab whose agent runs on Atlas", which means local and remote tabs side by side in one workspace.
   - **Per-tab host:** matches your description and lets an orchestrator keep a remote delegator in its own workspace. It changes the model, roughly one size bigger (L instead of M for that piece).
   - **Per-workspace host:** reuses today's code paths. A remote agent then always sits in its own workspace.
   - **My lean:** per-tab host, with one transport shared per host.
3. **What holds the agent on Atlas when Hyperion's lid closes?** A `c11 ssh` tab today is a local `ssh -tt`, so the remote agent dies on SIGHUP.
   - **c11d-remote owns the PTYs:** harvest cmux's Go persistent-PTY daemon, which fits c11's existing Go daemon. Bigger build, but native scrollback and no tmux artifacts. My lean.
   - **tmux on a c11-owned socket:** fastest path. You inherit tmux's scrollback, mouse and escape-passthrough problems, and the Overwatch seat-attach work already hit them.
4. **Should 1.0 include the federated end state?** That means Atlas's own c11.app owns the agent and Hyperion attaches to Atlas's tabs.
   - **Yes:** 1.0 grows by the c11d host-runtime work (XL), and every agent, Overwatch's included, ends up in one place.
   - **No (my lean):** 1.0 ships Hyperion-hosted remote tabs, built so the federated model can follow. The cost: until then, Atlas's c11 cannot see agents launched from Hyperion.

Everything else below is our assumption unless you overrule it.

---

## What cmux built

cmux has three remote stacks. Only parts of them carry the two features in the brief.

### Stack 1: the legacy Go relay (`cmuxd-remote`), which c11 forked

- **What it is.** `cmux ssh` uploads a SHA-pinned Go daemon and speaks newline JSON-RPC to it over the ssh exec channel's stdio. The daemon handles `hello`, `proxy.*` for browser egress, and `session.*` for resize [R: c11 `docs/remote-daemon-spec.md` §3.2].
- **CLI relay.** A separate `ssh -N -R 127.0.0.1:PORT:127.0.0.1:LOCALRELAY` reverse-forwards a TCP port to an HMAC-authenticated relay in the Mac app [R: spec §3.5]. Inside the remote shell, `cmux <cmd>` dials that port, so the remote CLI calls reach the Mac.
- **Added after the fork:**
  - Detachable persistent PTY slots that survive the ssh link (#4807, 2026-05-30), hardened by #7717, #8438, #9111 and `06e27e445b` [R: `git log upstream/main -- daemon/remote`].
  - The relay allowlist for GHSA-9vmv-3hjw-j28c (`67d4dbde6e`).
  - **#14974 (merged 2026-09-27): Claude on a relay host drives the Mac sidebar.** This is the closest template for c11:
    - Bootstrap writes a `claude` PATH shim into the relay shell dir. It hands off to `cmux claude-wrapper`, which adds one `--settings` file with relay hooks [R: #14974 body; `daemon/remote/cmd/cmuxd-remote/claude_hook.go`].
    - Claude Code honors only the last `--settings` flag, so the wrapper merges a launcher's own `--settings` into one file under `~/.cmux/claude-settings/` (0600, pruned after 7 days) [R: #14974, tested on Linux].
    - Hooks send `agent.hook.enqueue` through the relay. The Mac admits it only for `agent=claude` and six lifecycle subcommands, with a payload of 8 KiB or less and a `workspace_id`/`surface_id` the relay owns [R]. The app rebuilds the hook environment from those selectors and strips host paths before queueing [R].
    - Status rows show without a local PID. They clear when the relay leaves `.connected` [R].
    - A resume binding is not recorded; that is follow-up #14907 [R].
    - It also adds `cmux claude-hook install`, which writes into `~/.claude/settings.json` for sessions started outside a cmux shell (`claude_hook_install.go`) [R]. That half is off-limits to c11.

### Stack 2: cmux-tui (the default `cmux ssh` on main since #12956, 2026-09-25)

- **Bootstrap.** It installs one Rust binary, `~/.local/bin/cmux-tui`, through a digest-checked `npm pack` on the host (Node 18+ and registry access needed). The fallback is a stdin upload for the same OS and architecture [R: `cmux-tui/crates/cmux-remote/src/ssh_bootstrap.rs`].
- **Process model.** It starts a durable headless mux owner plus a replaceable sidecar [R: `cmux-tui/spec/remote-daemon.md` "SSH and lifecycle"].
- **Transport.** Length-delimited binary frames ("CMXR" protocol 5) ride ssh exec stdio [R]. There is no `ssh -R` and no forwarded socket. The Mac never listens, and the host never dials the Mac [R: `docs/cloud-cmux-tui-daemon.md` l.551].
- **Rendering.** The daemon owns the PTYs. The Mac renders them through Ghostty manual-IO and receives state as a cursor-resumable snapshot and delta feed [R].
- **Auth.** OpenSSH carrier auth (BatchMode, a shared ControlMaster). Noise device keys apply only to the network providers [R].
- **Link drop.** Reconnect is unlimited with 100 ms to 5 s backoff. A 120 s lease covers reliable replay; past it the Mac resyncs from VT snapshots [R]. Panes survive Mac sleep and disconnect [R: `SSHTuiLinkManager.disconnect()`].
- **Remote reboot.** It kills the mux owner, which is a user process, not a service [I].
- **Version skew.** The probe requires an exact distribution and protocol match. A running sidecar is replaced only with `--upgrade` [R].

### #14902 (merged 2026-09-27): remote agent status on Stack 2

How it works [R: PR body and diff]:

1. When the Mac's Claude Code or Codex hook toggles are on, it passes `--agent-hooks claude,codex` to `remote-link`.
2. `remote-link` runs `agent hook install` on the host before attaching. That writes `~/.claude/settings.json`, and for Codex both `~/.codex/hooks.json` and the trust state in `~/.codex/config.toml` [R: `cmux-tui/crates/cmux-tui/src/agent_hook_install.rs` l.255-266, 1267-1271, 1930-1936]. Turning a toggle off stops new installs but removes nothing.
3. The hook commands are no-ops outside cmux-tui terminals (`${CMUX_TUI_HOOK:-:}`, l.1914-1924).
4. A hook calls `cmux-tui-hook`, which writes `session.journal.append` to the daemon. The daemon folds events into an agent roster with the states working, blocked, idle and done (`journal_reducers.rs`). The roster rides the link to the Mac catalog as an `agent` badge.
5. `SSHTuiAgentStatusProjector` maps the badge to Running, Needs input or Idle, plus a per-panel lifecycle [R: `Sources/RemoteTui/SSHTuiAgentStatusProjector.swift`]. Notifications are durable daemon rows that the Mac acknowledges.
6. The session id was not carried at first. #14904 and #14906 added it [R: CHANGELOG l.52]. The resume binding is still open (#14929).
7. The PR says: "Not verified: a live `cmux ssh` session showing the sidebar status end to end."
8. A launcher that sets its own `CLAUDE_CONFIG_DIR` bypasses these hooks. #14974 says so explicitly [R].

### #14959 (merged 2026-09-27): `cmux session move`

- **Syntax.** `cmux session move <uuid> --to <ssh-dest|local> [--from] [--no-code] [--port] [--identity] [--ssh-option] [--no-focus]` [R: `CLI/CMUXCLI+SessionMove.swift` l.30-36].
- **Directions.** Claude only. Mac to host and host to Mac work. Host to host is refused [R: `AgentSessionMover.swift:42-47`].
- **Transport.** Plain `ssh … sh -s`, `rsync -a --partial`, and `git` over `GIT_SSH_COMMAND`. No daemon [R: `AgentMoveEndpoint.swift:30-40, 84-93`].
- **Remote needs.** Key-based ssh, POSIX sh, git, rsync, pgrep, claude.
- **"Stopped".** No live pid in `~/.claude/sessions/*.json`, and no `claude … --resume <id>` from `pgrep`, checked on both ends [R: `AgentMoveScripts.swift:24-37`]. It never stops the agent for you.
- **What moves:**
  - the transcript, its sidecar directory (subagents and tool results), and `file-history/<id>`;
  - project memory, merged both ways newest-wins [R: `AgentSessionMover.swift:136-168`].
- **What does not move:** todos, plans, settings and CLAUDE.md [R].
- **Path mapping.**
  - The home prefix is swapped and the project re-slugged [R: `AgentMovePathMap.swift:31-59`].
  - Transcript contents are not rewritten. The CLI warns that old absolute paths remain [R: CLI l.223].
  - Paths are hard-coded to `<home>/.claude`, so `CLAUDE_CONFIG_DIR` is ignored [R: `AgentSessionMover.swift:61-62`].
- **Git.** It never uses stash or a bundle [R: `AgentMoveScripts.swift:107-205`, `AgentMoveCodeSync.swift`]:
  1. It snapshots tracked plus untracked non-ignored files into a commit, through a temp index.
  2. It pushes or fetches that commit into `refs/agent-move/*`.
  3. It applies it on the destination with `read-tree -u --reset` and `reset`.
  - It refuses if the destination is dirty or its branch has diverged.
- **Safety:**
  - It refuses if the destination transcript is not a byte prefix of the source (a `cksum` check) [R: l.171-186].
  - There is no lock or lease, and no rollback. Code is applied before data, so a failed copy leaves a changed checkout [R: `AgentMoveModels.swift:81-83`].
  - The source copy stays where it was [R: CLI l.235].
- **After the move.** It opens a new workspace (`cmux ssh --command <resume>` or `new-workspace`) and clears the old surface's resume binding [R: CLI l.126-195].
- **Tests.** A loopback runner maps "the host" onto a second local home. Real ssh is not tested [R].
- **Config writes.** None into agent config [R].

## What c11 has today

| Area | State | Evidence |
|---|---|---|
| `c11 ssh <dest>` | Shipped, works as far as code shows, not in the c11 skill | `CLI/c11.swift:1987-1990, 5816`; `c11 ssh --help` |
| `c11d-remote` Go daemon | Shipped in every release (darwin and linux, arm64 and amd64); provides proxy, `session.*` resize bookkeeping, and the CLI relay. Owns no PTYs | `daemon/remote/README.md`; `.github/workflows/release.yml:334-339`; v0.67.0 assets; `main.go:339-349` |
| Remote terminal | A local PTY running `ssh -tt` with a bootstrap `RemoteCommand`, so a link drop kills the remote process | `CLI/c11.swift:6108-6130, 6273-6330` |
| CLI relay | `ssh -R` TCP plus HMAC; **forwards every command unfiltered** (Needs you 1) | `Sources/Workspace.swift:2950, 3087-3124` |
| Remote CLI | Only the Go `c11d-remote cli` (busybox `c11`), about 25 verbs, no `set-agent`/`set-metadata`/`set-status`/flags/`claude-hook`/`conversation`/`mailbox`, except via raw `rpc` | `daemon/remote/cmd/c11d-remote/cli.go:44-67` |
| Swift CLI over TCP | Cannot dial the relay; only the Go CLI speaks the relay handshake | `cli.go:498-593`; no TCP path in `CLI/c11.swift` |
| Tab identity on the remote | Not sent. Only `TERM_PROGRAM`, `COLORTERM` and `CMUX_SOCKET_PATH=127.0.0.1:<port>` cross | `CLI/c11.swift:6119-6120, 6279-6284` |
| Agent wrappers | Local only. The socket check `[[ -S … ]]` fails on a TCP address | `Resources/bin/claude:80-91` |
| Status and liveness | `kill(pid,0)` sweep on the Mac evicts remote pids. `AgentDetector` runs `ps -t` on local ttys, and for an ssh tab the foreground process is `ssh` | `Sources/TabManager.swift:1215-1225`; `Sources/AgentDetector.swift:182-187` |
| Conversation store | Has no host field. Scrapers read the local `~/.claude`/`~/.codex`. The resume command is typed text, so it is host-agnostic | `Sources/Conversation/Ref.swift:81-93`; `Conversation/Scrapers/ClaudeCodeScraper.swift:35-37` |
| Persistence | Remote workspaces are dropped from snapshots, so nothing restores after a restart | `Sources/TabManager.swift:5636-5637` |
| Host identity | The OSC 7 hostname is discarded. The tab sheet's "host" is a browser URL host | `Sources/TabManager.swift:2602-2611` |
| Mailbox | Files in the local App Support directory with FSEvents. Delivery to a recipient is PTY injection, so it reaches a remote agent; sending from one does not | `Sources/Mailbox/MailboxLayout.swift:24-36` |
| Pure c11-side verbs | `read-screen`, `send`, `send-key`, and `set-metadata`/`set-status`/flags called from outside all work on an ssh tab today, because the PTY is local | §6 of the c11 inventory, [R] |
| Tmux line (C11-36) | `Resources/bin/c11-spawn-agent` (C11-37, done) runs Claude in `tmux -L agents` on Atlas. C11-38 and C11-39 are in the backlog | `notes/c11-37-atlas-validation.md` |
| Design doc | `docs/c11d-cloud-host-design.md`: persistent `c11d`, mTLS over the tailnet, daemon-owned workspaces, federated sidebar (phases P1 to P5). Not built | file |
| Doc drift | The skill says "c11 is a local multiplexer… install tmux on the remote" | `skills/c11/references/api.md:431` |

A side finding, inferred from #14974's Linux test and not checked in c11: `Resources/bin/claude:233-236` puts its `--settings` before `"$@"`. A launcher that passes its own `--settings` would therefore win, and c11's hooks would silently drop.

## The gap

Against the target (a Hyperion tab whose agent runs on Atlas, with full citizenship):

| Citizenship item | Works today? | What is missing |
|---|---|---|
| Survives Hyperion's lid | No | A session holder on the remote host |
| Sidebar status, waiting, idle | No | Remote hook path, tab identity on the remote, no pid eviction |
| `set-agent`, metadata, description, flags from the agent | Only via raw `rpc` and unscoped | Remote CLI verbs, bound to the calling tab |
| `read-screen`, `send` | Yes | Nothing (local PTY) |
| Mailbox delivery to the agent | Yes | Nothing |
| Mailbox send from the agent | No | A relay verb |
| Resume after c11 restart | No | Persist remote tabs, reattach to the holder, store host in the conversation ref |
| Move a stopped session | No | Everything |
| Safe to point at a less trusted host | **No** | The relay allowlist (Needs you 1) |

The doctrine gap is narrower than it looks. cmux's two remote-status paths split cleanly:

- **#14902 and #14974's `claude-hook install`** write into `~/.claude/settings.json` and `~/.codex/*` on the host. c11 cannot import them.
- **#14974's wrapper path** is a PATH shim that injects `--settings` per launch and writes only into cmux's own directory. That is the shape of c11's `Resources/bin/claude` exception, moved to the remote host.

## Proposed c11 1.0 shape

### Principles

1. **A remote agent is a tab with a host.** Every c11 verb works on it the way it works on a local tab.
2. **Nothing is written into tenant config on any machine.** Hooks reach an agent only through c11's PATH wrapper and per-launch `--settings`.
3. **The Mac initiates every connection.** No host ever dials Hyperion, and no port forwarding is required.
4. **A remote host gets only the verbs its own tab needs**, deny by default.
5. **It works the same on Atlas, a Linux box, or a Prime sandbox.**

### Architecture options

| | A. Evolve `c11 ssh` (recommended) | B. Federate with Atlas's c11.app | C. Adopt cmux-tui |
|---|---|---|---|
| What | `c11d-remote` gains durable PTYs and a scoped command channel over its existing stdio link. The Mac renders the tab | Hyperion's c11 attaches to tabs that Atlas's c11 owns | Import the Rust daemon, its protocol and the manual-IO renderer |
| Citizenship | Full, through the relay | Full, natively on Atlas | Status via the journal; CLI verbs not designed |
| Doctrine | Needs one small amendment (below) | Clean | #14902 hook install is forbidden; would need a rewrite |
| Effort | L in total, built in independent slices | XL: c11 PTYs must become daemon-owned (C11-186) plus cross-instance auth | XL, plus Rust, npm bootstrap and a 77 MB binary |
| Risk | Inherited code, unexercised since the fork | Inverts state of record (design doc §3) | Tracks a moving upstream with 100 PRs a day |
| Converges to | B, if c11d-remote later becomes the PTY owner for local tabs too | (already there) | A fork of cmux's platform |

**Recommendation: A for 1.0, built so B follows.** The PTY holder in A is the same component C11-186 and `c11d-cloud-host-design.md` P1 need. Once Atlas's own c11.app runs its tabs through that holder, Hyperion attaching to Atlas tabs is the federation step, not a rewrite.

### A in detail

**1. Session holder on the remote (decision: Needs you 3).**
- `c11d-remote` gains persistent PTY slots that survive link drop and Mac sleep, with a bounded replay buffer.
- Harvest from cmux's Go daemon: #4807, #7717, #8438, #9111, `06e27e445b`, `05f3e1a0a9`, and `persistent_pty_exec*.go` [R: file list on `upstream/main`].
- cmux is GPL-3.0 and c11 is AGPL-3.0. GPLv3 §13 permits combining them [I: license reading, not legal advice].
- tmux on a c11-owned socket (`tmux -L c11`, status off, no user config) is the interim alternative.

**2. Command channel over stdio, not `ssh -R`.**
- `c11d-remote` listens on `~/.c11/run/<slot>.sock` (0600, peer uid checked; compare cmux's `cloud_cli_peer_*.go`).
- It multiplexes CLI calls over the stdio link the Mac already holds.
- Why: this drops the TCP reverse forward (which needs `AllowTcpForwarding` and fails behind gateways that forward nothing, Prime included) and the auth-token file on the host. cmux-tui made the same move [R].
- Keep `ssh -R` only as a fallback if stdio multiplexing proves awkward.

**3. Scoped dispatch on the Mac.**
- Every relayed call carries the slot. The Mac binds the slot to exactly one tab and rewrites or validates `--tab`/`--workspace` against it, after cmux's `RemoteRelayCommandPolicy` and #14974's admission model.
- Allowed by default:
  - for its own tab: `set-agent`, `set-metadata`, `set-description`, `rename-tab`, `set-status`, `set-progress`, `log`, `raise-flag`, `lower-flag`;
  - `claude-hook` and `agent-hook` lifecycle events (not decision hooks), `conversation claim`, `conversation capture-runtime`, `notify`;
  - `mailbox send` and `recv` as that tab.
- Denied: `send`, `send-key` and `read-screen` against other tabs, any command-bearing param, workspace or window creation, raw `rpc`.
- Host classes such as `trusted` and `box` narrow this further (see Overwatch below).

**4. Remote CLI and wrappers.**
- Extend the Go `c11d-remote cli` (already busybox `c11` on the remote) with the verbs above, generated from one shared command table so it cannot drift from the Swift CLI. The skill stays the contract.
- Bootstrap uploads c11's `Resources/bin` wrappers into `~/.c11/bin`, prepended to PATH only in c11 holder sessions, and exports `C11_TAB_ID`, `C11_WORKSPACE_ID` and `C11_SOCKET_PATH=<slot socket>`.
- Fix the wrappers' `-S` socket test, and merge any launcher `--settings` into one file, which #14974 found necessary.

**5. Host-aware status.**
- For remote tabs, skip `kill(pid,0)` eviction and `ps` detection. Status comes from hooks and the wrapper's `set-agent`.
- Clear remote agent status when the link leaves connected, as #14974 does, and show "link down" instead.
- Transcript-based clocks and model detection (origin/main's `AgentModelDetection`) read nothing for remote tabs in 1.0, or ask the daemon to stat the transcript as a later slice.

**6. Persistence and resume.**
- Snapshot remote tabs with host and slot; drop the `!isRemoteWorkspace` filter.
- On restart, reconnect and reattach to the holder. If the holder is gone, type the stored resume command, which already works on any host.
- Add `host` to `ConversationRef`, as a first-class field or in `payload`.
- Keep the OSC 7 hostname as a derived host badge.

**7. Tab or workspace (Needs you 2).**
- Move remote configuration from `Workspace` to the tab, with one daemon link per host shared by all its tabs.
- Then `c11 new-split --host atlas` and `launch-agent --host atlas` fall out, which is exactly what an orchestrator on Hyperion needs to place a delegator on Atlas.

### Doctrine amendment this needs

`CLAUDE.md` allows wrappers that "live in c11's own bundle." On a remote host, c11's bundle does not exist, so the wrappers would live in c11's own runtime directory there (`~/.c11/`). Every other rule holds: PATH-scoped to c11 sessions, no writes to tenant config, fall through to the real binary outside c11. The proposed wording: "a c11-owned directory on a host c11 connected to counts as c11's bundle for this rule." This keeps c11 on the right side of the line cmux crossed in #14902.

### Moving a stopped session

Proposed verb: `c11 move <tab> --to <host|local>`. It moves the agent in a tab, not a session id, because c11 already knows the tab's conversation ref.

1. **Refuse if the agent is live on either side.** Use the conversation store's state plus cmux's pid and `pgrep` checks, and hold a lock in the store for the length of the move. A later `--stop` can wait for idle and exit the agent first.
2. **Use per-host agent homes, not `~/.claude`.**
   - Hyperion runs Claude from `~/.claude-profiles/<call-sign>`.
   - Atlas's user is `atinwoodard`, not `atin` [R: `overwatch/CLAUDE.md` "Atlas's user is `atinwoodard`"], so home paths differ.
   - Each host entry records `CLAUDE_CONFIG_DIR` and `CODEX_HOME` and a path map. cmux ignores all of this, which would break here.
3. **Code: reuse cmux's technique.** Snapshot commit through a temp index, push or fetch into `refs/c11-move/<id>`, apply with `read-tree -u --reset`, refuse on a dirty or diverged destination.
   - Order: refuse checks, then code, then data.
   - Unlike cmux, record a rollback ref so a failed data copy can restore the checkout.
4. **Data.**
   - Claude: the transcript, its sidecar directory, `file-history`, and project memory merge.
   - Codex: the `~/.codex/sessions/**/rollout-*.jsonl` for that id. That is an S on top; Codex resume is by id.
   - Keep the byte-prefix divergence check.
5. **Resume in the same tab, now bound to the new host**, by typing the resume command. Leave a tombstone on the source ref so a stale resume there is refused.
6. **Stale absolute paths inside the transcript stay.** Two options: put a symlink `/Users/atin` on Atlas so paths resolve (needs one sudo step), or accept the drift as cmux does.

### Overwatch

- **Today.**
  - Box seats show up view-only through `seat-attach` in Atlas's c11.
  - They talk back through `[seat]` PR comments and a `needs-human` label that the orchestrator's poller turns into a c11 flag.
  - `c11` and the mailbox do not exist on a box because "Prime's gateway forwards no ports" [R: `overwatch/SEAT-MODEL.md` §5].
- **What A changes.** A's stdio channel needs no port forward. Atlas would open `prime sandbox ssh <id> -- c11d-remote serve --stdio`, outbound only, the way the launcher already runs `prime sandbox ssh "$id" -- "$@"` [R: `launcher/seat.sh:144`]. The box gets a channel to exactly one surface on Atlas's c11 and no route to anything else, so **the box never joins the tailnet** and the hard rule holds.
- **Missing piece.** `c11 ssh` needs a transport-command override, such as `--transport-command 'prime sandbox ssh {id} --'`.
- **Unverified.** Whether Prime's ssh carries a long-lived, binary-clean stdio stream [I].
- **What a box should be allowed: report verbs only.** That covers `set-agent`, `set-status`, `set-description` and `raise-flag` on its own tab.
  - No `mailbox send` and no `send`: mailbox delivery types into the recipient's PTY, so a compromised box could otherwise push text into the orchestrator's turn.
  - That would be worse than PR comments, which the orchestrator reads but does not execute.
- **Complement or replace `seat-attach`? Complement in 1.0.** `seat-attach` is deliberately view-only and ends inert; c11 has no read-only tab mode. Replacing it later needs `c11 ssh --view-only` plus the mode reset on drop that `seat-attach` already does.
- **What this buys.** Seats raise flags and set status directly instead of through the PR-label poller, and their tabs carry real agent chips.

## Effort and risk

| Slice | Size | Main risks |
|---|---|---|
| 0. Relay allowlist (Needs you 1) | S-M | Shipping to live users; must not break the few relay verbs people use |
| 0b. Smoke-test today's `c11 ssh` against Atlas | S | It may already be broken; nothing exercised it since the fork, beyond the Go unit tests in `ci.yml` `remote-daemon-tests` |
| 1. Persistent PTY holder in `c11d-remote` | M-L | Replay mid-escape artifacts (cmux's own doc warns), resize races, orphaned slots; cmux needed about 15 follow-up fixes |
| 2. Stdio-multiplexed command channel | M | Head-of-line blocking behind proxy traffic; needs lane priority like cmux-tui's interactive and control lanes |
| 3. Scoped dispatch on the Mac | M | Every new socket method must be classified; add a guard like cmux's `b455514205` so new methods default to denied |
| 4. Remote CLI verbs, wrappers, `--settings` merge | M | Drift between the Go and Swift CLIs; Claude's last-`--settings`-wins rule |
| 5. Host-aware status, link-down state | S-M | Stale "working" after a silent remote death (cmux's known limit) |
| 6. Persistence, reattach, host in the conversation ref | M | Restart while the link is down; snapshot schema migration |
| 7. Per-tab host model | L | Touches the workspace model, sidebar, tree output and the skill |
| 8. `c11 move` (Claude, then Codex) | M + S | Path maps across homes, partial failure, account and profile mismatch |
| 9. Prime transport override (Overwatch) | S | Prime ssh stdio quality; Prime CLI shape changes |
| Federation (B), post-1.0 | XL | State of record inversion, cross-instance auth |

1.0 in total is about L to XL depending on Needs you 2 and 3. Slices 0, 0b, 2+3+4 and 8 can run in parallel. Slice 1 gates the lid-close guarantee and slice 6 gates restart.

Validation needs Atlas. The heavy parts (daemon stress, e2e) run there under the Hyperion no-heavy-work rule. The docker ssh suites in `tests_v2/test_ssh_remote_*` are a starting harness.

## Open questions

1. Needs you 1 to 4 above.
2. Does Atlas's sshd allow TCP forwarding today? This decides whether the relay fallback is usable at all. A quick `ssh atlas` check settles it.
3. Should a remote tab's agent chip show the host, for example `Opus · atlas`, in the tab sheet and sidebar?
4. Which Anthropic account does a remote Claude bill: Atlas's own login, or the profile Hyperion would have used? `c11 move` across profiles hangs on this.
5. Should `c11 move` also offer `--stop` (wait for idle, exit the agent, move, resume) in 1.0, or stay stopped-only as cmux does?
6. Should Linux hosts be in 1.0 scope, or only macOS hosts (Atlas)? The Go daemon covers both; the wrappers are bash and need checking on Linux.
7. Should the skill teach `c11 ssh` now? The current text contradicts what ships (`skills/c11/references/api.md:431`). This is independent of 1.0.
8. Is `c11-spawn-agent` and the C11-36 tmux line retired once slice 1 lands, or kept as the headless path for agents nobody watches?
