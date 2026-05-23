# c11d Cloud Host — Design

Status: design draft (lightweight, high-level — to be built out)
Owner: Atin
Related: `docs/remote-daemon-spec.md` (the living implementation spec for `cmux ssh` / `c11d-remote` today)

## Vision

Set up a Hetzner / DigitalOcean / AWS box, run `c11d`, and use it from c11 like a local instance. No SSH dance, no tmux, no Mosh, no terminal emulator on the remote. Provision once, then your tabs and agents live there as readily as on the laptop in front of you. Leaving home stops costing you anything.

The operator should be able to spin up a cloud host in one command, see its surfaces in the same sidebar as their laptop, and have lattice delegation spawn siblings on the host that makes sense — local for IDE-adjacent work, cloud for long-running compute or "keep going while I sleep."

## Where we are today

`c11d-remote` already exists as a Go binary that runs on a remote Linux or macOS host and serves c11's v2 JSON-RPC surface over stdio. It is reached today through `cmux ssh`: the local c11 app uploads a release-pinned binary (verified by SHA-256 from the embedded manifest), runs it via SSH stdio, and the Mac app proxies sessions, resize, browser egress, and CLI relay through that transport. See `docs/remote-daemon-spec.md` for the implemented surface.

The daemon already does the hard parts:

- Durable PTY sessions with smallest-screen-wins resize across multiple attachments.
- Browser egress over SOCKS5 / HTTP CONNECT through a stream RPC, with WKWebView auto-wired to a workspace-scoped proxy.
- CLI relay so `cmux ...` works from inside the remote shell (reverse-forwarded TCP, HMAC-authenticated).
- Structured error surfacing into the local sidebar.

## What it is not yet

`c11d-remote` today is a **session-bound helper**, not a **persistent host**.

1. **Lifecycle is tied to SSH.** The daemon launches when c11 establishes the SSH transport and dies when it detaches. There is no "this box is mine, the daemon is up 24/7, I attach and detach freely from any client."
2. **Provisioning is bring-your-own-host.** You arrive with an SSH-reachable box; c11 uploads the binary. There is no `c11 cloud init` that takes a provider + region + size and hands back a working tailnet-attached host with skills mirrored and CLIs preinstalled.
3. **State of record lives on the Mac.** Workspace shape, surface manifests, sidebar telemetry, skill state — all owned by the local app. The remote daemon hosts processes, not the workspace concept.
4. **No web/mobile reach.** A remote workspace requires the macOS app. There is no thin client that lets you tap into the host from an iPad or arbitrary browser.

The gap between "session-bound helper" and "persistent first-class cloud host you connect to like a tailnet peer" is the subject of this doc.

## Design

### 1. Daemon lifecycle: persistent, addressable, supervised

`c11d` gains a persistent service mode (`c11d serve --persistent`) running under systemd on Linux and launchd on macOS. It is reachable on the host's tailnet IP, not just over a per-session SSH transport. Authentication is mTLS or signed tokens, not "we trust SSH." Clients (Mac app today, future web client) attach and detach without disturbing running sessions.

The existing `cmux ssh` path keeps working — it just becomes one of two transports alongside direct mTLS-over-tailnet. The same `c11d-remote` binary serves both.

### 2. `c11 cloud init` — provisioning UX

One command. Picks a provider (Hetzner default; DigitalOcean and AWS as plug-ins), region, size. The flow:

1. Provisions the box via the provider's API.
2. Joins it to the operator's tailnet (Tailscale auth key from `c11d`'s sealed store).
3. Installs `c11d` from a release-pinned manifest (same trust model as today's manifest-SHA verification).
4. Mirrors `~/.claude/` (skills, CLAUDE.md, settings) and a configured dotfile set.
5. Pre-installs Claude Code / Codex / Gemini CLIs, `gh`, `git`, `bun`, language toolchains per a profile.
6. Returns a connection blob the operator pastes into c11 (or auto-discovers via tailnet).

`c11 cloud sync` reconciles skills/dotfiles/binaries without rebuilding the box. `c11 cloud destroy` is exactly what it sounds like.

### 3. Workspace as first-class concept on the daemon

Today the macOS app owns the workspace. In this design `c11d` does, for cloud-resident workspaces. The daemon owns:

- Surface manifests (which surfaces exist, what's running in each, their metadata).
- Sidebar telemetry written by agents (`set-status`, `set-progress`, `log`).
- Persistent agent identity, so a surface survives daemon restart and reattaches to its lifecycle wrapper (the `Resources/bin/claude` pattern).

The Mac app becomes a **view** onto this state — same as a future web client. Multiple clients may attach to the same workspace simultaneously (operator on Mac at home, operator on iPad on the train, both seeing the same panes update live).

This is the biggest architectural shift, because it inverts where state of record lives. It is **opt-in per workspace**: a local-only workspace keeps state in the app as today; a cloud workspace puts state in the daemon. The local app's existing workspace path stays unchanged.

### 4. Federated sidebar

The sidebar aggregates surfaces across multiple `c11d` instances. Each surface carries a host badge (`laptop`, `home-mac`, `hetzner-fra-1`). Lattice delegation can target a host explicitly:

```
c11 split --host hetzner-fra-1 --title "impl"
```

Default targeting is the workspace's home host. `c11 tree` works across hosts. `c11 send` traverses host boundaries transparently.

### 5. Web client — escape hatch, not replacement

`c11.web`: browser client for the no-Mac case. xterm.js for terminals, a minimal sidebar, no embedded browser pane (use the host's via port-forward or just open a tab in the user's browser). Connects to `c11d` over the same protocol the macOS app uses.

A mobile-shaped reduction sits on top: vertical surface list, tap to drill in, push notifications when an agent blocks, voice-to-send (the operator already drives Claude via STT). Explicitly not a full replacement for the native app; a credible escape hatch when the Mac is unreachable.

### 6. Identity and trust

Each `c11d` instance has a stable identity (key pair generated at install). The macOS app maintains a known-hosts equivalent, with a tailnet-aware first-attach flow. Agent secrets (Anthropic API key, GitHub token, etc.) live in a sealed store on the daemon — never round-tripped through clients. `c11 cloud init` provisions the secret store at setup, with a documented rotation flow.

## Phasing

Each phase ships independently and is useful on its own.

| Phase | Scope | Outcome |
|---|---|---|
| P0 | Today | `cmux ssh` per-session helper (done; tracked in `remote-daemon-spec.md`). |
| P1 | Persistent daemon mode on an existing host | `c11d serve --persistent` runs under systemd/launchd, accepts mTLS connections, survives client detach. Mac app gains "Connect to remote daemon…" alongside `cmux ssh`. |
| P2 | `c11 cloud init hetzner` | One-command provisioning: Tailscale join, binary install, dotfile/skill mirror, CLIs preinstalled. |
| P3 | Workspace state on the daemon (opt-in) | Surface manifests, sidebar telemetry, per-surface metadata move into `c11d`. Local-only workspaces unchanged. |
| P4 | Federated sidebar | Multiple `c11d` hosts in one workspace; `--host` targeting in `c11 split` and friends. |
| P5 | `c11.web` thin client | iPad / phone / arbitrary-browser access to a `c11d` instance. |

P1 alone unlocks "leave home, instances keep running" for anyone willing to do their own SSH/Tailscale setup. P2 makes it one command. P3+ are about depth, not unlocking the core use case.

## Open questions

1. **Repo sync.** `lattice` and `c11` repos live somewhere. Sync via git auto-fetch on a convention, Mutagen-style continuous sync, or expect the operator to clone on the host? Initial bias: git auto-fetch with a per-workspace remote convention; Mutagen as an opt-in for "I'm actively editing in two places."
2. **State conflict model when workspace state lives on the daemon.** When the daemon goes offline, do clients show a read-only cached view of last-known surfaces, or hide the workspace entirely? Bias: read-only cached view with a "disconnected" badge.
3. **Multi-client editing semantics.** Two operators attached to the same workspace — shared focus or per-client selection? Bias: per-client selection; surfaces are shared, selection/focus is local to each client.
4. **Provider matrix breadth.** P2 ships with one default. Hetzner has the cost story; DigitalOcean is more familiar to many; AWS is the enterprise path. Pick one for v1 and plug-in pattern for the rest?
5. **Daemon ↔ daemon traffic.** Does federation (P4) imply `c11d` instances talk to each other directly, or always through the client? Bias: always through client. Daemons stay simple; clients are the orchestrators.
6. **Skill propagation scope.** `c11 cloud sync` mirrors `~/.claude/skills/`. Do we also mirror project-scoped skills (e.g. `Stage11/.claude/skills/lattice-delegate/`)? Probably yes, scoped to the synced repos.
7. **Sleep/wake / scale-to-zero.** Should `c11d` support hibernation when no clients are attached and no agents are running? Could halve hobbyist cost. Probably out of scope for P1–P3; revisit at P5.

## Non-goals

- A renderer rewrite. The macOS app's native rendering (Ghostty, AppKit, the sidebar, the WKWebView browser pane) stays as-is. We are moving where workloads run, not how surfaces are drawn.
- A tmux replacement on the cloud side. `c11d` is a c11 daemon, not a general-purpose multiplexer. Operators who want raw tmux on a server keep using it independently of c11.
- Removing `cmux ssh`. P1 makes persistent mode another transport; the existing per-session helper stays for "I just want to bash on a one-off box" use cases.
- Auto-mirroring every remote TCP port to local loopback. (Already explicitly rejected for browser routing in `remote-daemon-spec.md` §4.4; same posture here.)

## Next steps

1. Open a Lattice ticket for P1 (persistent daemon mode on an existing host).
2. Decide P2's default provider and a minimal dotfile-sync set.
3. Decide P3's state-of-record model — the biggest open question and probably worth its own design doc.
4. Sketch the protocol surface deltas needed beyond what `remote-daemon-spec.md` already covers (mostly: workspace RPCs, identity/auth handshake, persistent supervisor lifecycle, surface manifest synchronization).
