<!-- c11-2.0:begin-keep (history: written while this line was c11h; the rename must not touch it) -->
# c11h plan

> **Historical.** Written while this line was c11h, before it became c11 2.0 (`C11.md`, Decisions 1-3). Names are as they were then; `docs/c11-2.0-identity.md` maps each to its 2.0 name.

Status: draft for Atin's review, 2026-10-31, revised after two independent reviews (`notes/c11v-herdr-core/reviews/astra.md`, technical, 13 findings; `fable.md`, high level, 10 findings; cited below as A1 to A13 and F1 to F10). Nothing has started. The why, the laws and the milestone table live in `docs/c11-vision.md`; the Orchestrator's launch brief is `docs/c11-m1-brief.md`. Evidence: `notes/c11v-herdr-core/SPIKE-0B.md` and `feature-map.md` ("row N").

## When M1 is done, what you can do

You install a signed c11h staging build on the laptop, beside c11, and do real agent work in it.

- **It is c11.** Same workspaces, panels, sidebar, browser and markdown panels, flags, Feed, mailbox and skill, with your c11 settings brought over at install. Agents in c11h use the `c11` command as they do today.
- **Nothing you do to the app ends your work.** Quit c11h, force-quit it, let it crash, or install a newer build: every terminal keeps running. When c11h comes back, each panel shows the same process and screen, and within 10 seconds the sidebar again shows which agents are working, flagged or waiting. Mail still reaches them, including Claude's direct route.
- **It updates in place.** A new signed build installs with one command while your agents keep running and keep their file access.

What you can't do yet, or what works differently:

- **Other machines, until phase 2.** Build-host terminals in the same window arrive in phase 2 of this run (Settled 14); build-host agents working with the lid closed is M6.
- **Reboots.** A reboot of the laptop ends the terminals, as it does today; c11h then resumes conversations into fresh terminals the way c11 does.
- **Holder loss.** One hc process holds every terminal; if it dies, they all end (risk 1). Counted during M1 use (Settled 12).
- **Closing a panel ends everything it started.** hc ends every process the terminal started, `nohup` and background jobs included; today such jobs survive a closed panel (F5, Settled 10).
- **Small terminal-query differences**, listed in "Accepted for M1".

## Where we start

The spike (commit `dd0d4e75a9f`, local branch `spike/c11v-hc`) runs c11 terminals on hc 0.1.14 behind environment variables. It passed 18 of 20 checks; Quit, force-quit and killing hc brought every panel back with the same processes; the hc hop added 0.2 to 0.3 ms at p99. It is spike code: it has a lock order that can freeze the app when a flooding panel closes (A4), drops input silently when a queue fills (A5), starts a second terminal when a lookup fails (A6), and does nothing for agents (row 8: the socket refuses every `c11` call from an hc terminal). M1 rebuilds it on a contract rather than porting it as is.

## Settled

1. **Code.** A private GitHub repo, `Stage-11-Agentics/c11h`, cloned to `~/src/c11h`, so c11 keeps going untouched in its own folder. A fetch-only remote `c11` brings c11's `main` in. GitHub Actions stay off (macOS minutes are billed on private repos; the gate is the build host), except one Linux job, `c11h-shareable.yml` (Atin, 2026-11-03, C11H-130).
2. **Tickets.** A new hosted Lattice project, `stage11/c11h` (code `C11H`), bound to that clone.
3. **Seats.** Astra owns hard tickets, Grok bounded ones, Claude runs the line and reviews Astra's work, Fable validates the finished build (brief, Seats).
4. **Scope.** M2 (agents) is folded into M1, and M1 ends in a staging build Atin uses.
5. **The laptop is M1's target.** Validation stays in build-host guests; only a build that passed there reaches the laptop ("yes, definitely").
6. **Signed with the Developer ID c11 releases use** ("why not?"). Atin ruled at 15:37 that c11's signing keys move to a dedicated, sealed keychain on the build host ("Keys to the build host"), landed by the release-speed work (c11 panel 29). c11h signs there once that lands, so builds sign with the laptop asleep. Until then, the fallback is the split `scripts/release-local.sh` uses: build on the build host, sign on the laptop. Notarization is optional for a build installed locally. c11h never moves or exports a key itself.
7. **Orphaned terminals go to a "Recovered" workspace** for Atin to close; c11h never kills them. Only terminals from c11h's own hc session count ("fine with recovered for the time being; we can see how that works").
8. **The hc pin is chosen by evidence.** 0.1.16 shipped a fix in the flood and reconnect area (F4). The Pathfinder runs the checks on 0.1.16 and falls back to 0.1.15 only if 0.1.16 regresses one; the chosen version and checksum go into the brief. The pin holds for all of M1.
9. **Build-host agents talk back through the relay, authenticated per terminal** (C11H-176; Atin, 2026-11-03: fixed before any build is shared with a friend). While the laptop is awake, `c11` on the build host reaches c11h's socket over the same SSH link hc uses. c11h serves a call only when it is signed with the credential c11h gave that c11h terminal, and runs it only as that terminal's panel; a removed machine's credentials are revoked (`docs/c11-relay.md`, Authentication). Stock hc still gives every process of the same user on a linked machine that machine's terminals, so such a process that reads a c11h terminal's environment or types into it through hc can act as that terminal; closing that is M6's per-host agent layer (C11H-71) with per-client authentication in hc.
10. **Closing a panel ends its session, and says so** (Atin: "that's fine", with the language made clear). hc ends every process the terminal started, `nohup` and background jobs included. The close command and its confirmation say "End session" and name what ends; the guide and the skill say it in one sentence.
11. **Every terminal shows where its session runs** (Atin). The panel's subtitle area shows, clearly and semi-prominently, the machine the session executes on, and marks a session that won't survive a restart (the plain-shell fallback). An HTML prototype comes first for Atin's sign-off (ticket 15).
12. **Holder losses are counted during a week of real use**. Any loss moves sharding (vision Decided 12) to the front of phase 2 and ahead of daily use across machines (F10).
13. **c11's settings are copied into c11h once, at install**: themes, keys, sidebar, flag kinds, agent configs; c11's are read, never written (F6).
14. **One run, two phases**. Phase 2 (build-host terminals, M3) starts the moment phase 1's tickets merge; the week of local use overlaps it.
15. **The run lives in a c11 workspace named "c11h build"**, inside c11 on the laptop. The c11h app runs only in build-host guests until the install.

16. **Ticket 15 uses variant A**, a chip on the panel's subtitle bar (Atin: "A for sure").
17. **Phase 2 builds on today's relayed link** (Atin: "I'll work on that later for the time being. Press ahead"). The laptop reaches the build host through Tailscale's DERP relay (typing p50 72 ms, `<run-notes>/atlas-link-result.md`). Atin applies the fix later (a UniFi forward of UDP 41641 to the laptop); the 20 ms typing line is re-measured then and is not a stop before it.

Items 12 to 15 were recommendations Atin accepted with "this looks really good" (2026-10-31).

## Accepted for M1 (unless the Pathfinder finds them fixed on the chosen pin)

- hc answers three terminal queries itself, slightly differently from c11 today: device attributes without clipboard support (`52`), part of a capability query, and a version string without the version (spike defects 3 to 5). Programs that ask may turn off clipboard writes. A patch only if real use makes it hurt (vision Decided 12).
- Bell and IME can't be driven in a guest; Atin checks them by hand on day one.
- `clear-history` is durable only if hc exposes a way to clear its own history; otherwise the command says that history returns after a restart (A13).

## The contract ticket 2 freezes first

Seven tickets build on ticket 2. Before any of them writes code, ticket 2 publishes a one-page contract, reviewed and then frozen, and the rest build against it (A6, A9, A10):

- **Launch tuple.** One exact hc executable at a stable path; session `c11h` (dev builds `c11h-<tag>`); an explicit socket and holder location; hc's default state root, with no XDG variables on the core, so agents' environments are untouched; a sanitized core environment; `RLIMIT_NOFILE` raised to the hard limit before the core starts (F1, F8). Every connection checks which hc build serves it (A1).
- **Lifecycle states.** Each panel's terminal is `new`, `live`, `ended` or `unresolved`. A `new` panel creates its first terminal. Replacing or resuming an existing identity needs an authoritative `ended`; `unresolved` waits and keeps its identity. An ambiguous creation result becomes `unresolved` and is reconciled by label before any retry.
- **Inventory.** One live list of the session's terminals: a snapshot plus events, a fresh snapshot after missed events, and a readiness signal. Until it is ready, nothing is treated as dead.
- **Input.** Bounded queues; overflow is never silent; a partial command is never submitted; guarded sends recheck the screen after a reattach. Input not yet sent arrives whole or is refused visibly; input interrupted in flight is reported as uncertain, never replayed, and its queued Return is never sent (A5).

## M1 work

Built on the build host with `remote-build.sh`; every proof runs in a build-host guest.

| # | Ticket | Done when |
|---|---|---|
| 1 | **Separate identity.** Bundle id `com.stage11.c11h`, name and icon c11h. Every place c11 keys off its bundle id or a fixed name gets a c11h answer: socket, `/tmp/c11-last-socket-path`, settings, saved sessions, mailbox and journal state, port range, logs. No migration from c11, c11mux or cmux state inside the app (the installer's one-time, read-only settings import is Settled 13), and no CLI discovery outside c11h's own sockets (A2). The skill installer, onboarding and CLI never write or remove c11's installed skills; c11h's agents read the fork's contract through the bundled `c11 guide` (A3). Sparkle off. Every script that kills by name is scoped to c11h's bundle (F9). The bundled CLI keeps the name `c11`, aimed at c11h's socket. | In a guest seeded with c11 state, a `c11mux` link, old breadcrumbs, installed skills and a running c11: first launch, the CLI with c11h down, settings writes, the skill offer and shutdown leave every c11 file, link, skill and listener unchanged, for Debug and Release builds. |
| 2 | **hc backend.** The contract above, then the backend: connection and hello asynchronous with one total deadline; teardown never makes the main thread wait on output that needs it (A4); the same environment as today's shells, initial input sent once, child exit, splits (rows 1, 3 to 5, 18, 25, 31, 32). A panel falls back to a plain shell only when it is new and hc is unreachable, marked as not persistent. | In a guest: 200 panels with c11h launched by `open` and starting the core itself; closing and quitting during a flood stays responsive; a core that answers slowly or never stalls nothing; a `default` hc session with live terminals runs beside, and restarting or killing either core ends nothing in the other (A1, F8); the acceptance matrix rows for ticket 2 pass. |
| 3 | **Restore, close, identity, orphans.** Label `c11.panel=<uuid>`; launch reattaches through the inventory. Liveness from the contract, not from "has a surface" (rows 2, 40). Panel numbers, the allocation high-water mark and port ranges persist across restarts, so a surviving terminal's `C11_PANEL_NUM` and `CMUX_PORT` stay right (A10). Close ends the terminal and its jobs (Settled 10), asserted in a test. No scrollback capture or replay for live terminals (row 28). Orphans go to Recovered with their identity. `clear-history` per "Accepted". | Quit, force-quit, a killed core and an installed newer build each bring back every panel with the same process and screen; reordered panels, two windows, an orphan and a new workspace after a restart all keep refs and ports right; a slow or failed lookup produces one terminal, never two. |
| 4 | **Quit and resume.** Quit no longer suspends live agents; restore never types `--resume` into one still running; the dirty-startup conversation audit and late scrapes reconcile with live hc terminals before marking anything suspended (A7, rows 7, 35). After a reboot or holder loss, the usual resume runs once, in a fresh terminal. The Quit dialog says terminals keep running; a separate command ends them all; closing a panel says "End session" and names what ends (Settled 10). Localized. | Force-quit with exact Claude and Codex conversations: both stay live, nothing is typed, no audit overwrites them; after a real holder loss, each resumes once. |
| 5 | **Rendering.** The spike's fixes, kept and measured: early-frame buffer, resize repaint (cost with 50 panels), resize ordering, focus events, theme facts on a light/dark switch; a workaround for hc's 200x120 start; the typing-latency probe kept for the Validator. | vim after a resize, a theme switch and the find overlay pass; latency within the spike's +0.3 ms p99. |
| 6 | **Reconnect and input across it.** When hc's core restarts, panels reconnect without giving up and show their state while waiting. Typing and pastes during a disconnect are held or refused visibly, never truncated or replayed into a changed prompt (A5). | Kill the core mid-paste and during queue saturation: unsent input arrives whole or is refused visibly, interrupted input is reported as uncertain with no Return sent, and the bytes the program received match the reported outcome; no panel is lost. |
| 7 | **Agents reach c11h.** The socket admits processes descended from a live terminal of c11h's hc session, using the inventory, including one that reports at the moment it starts (rows 8, 22; A9). Identity and `capture-runtime` from env (rows 9, 36). | Every `c11` verb the skill teaches works from an hc terminal before and after a restart, and `panel:$C11_PANEL_NUM` still names the caller. |
| 8 | **Agents come back.** After a restart: tty and agent pid re-learned (rows 11, 14); detection, ports, CPU, model detection and prompt cache re-armed (rows 12, 13, 34); status, flags and delegates restored (rows 37, 39); doorbell and input guard on reattached panels (rows 20, 21); Claude's native mail bridge reconnects to its own session (A8). An agent started while c11h was down gains reporting and mail when c11h returns. | Force-quit with Claude working: the sidebar shows it working within 10 s; mail reaches an idle Claude natively, and one with a draft without touching the draft; one OpenCode or omp agent does the same. |
| 9 | **Observability.** Structured logs for attach, reattach, fallback, recovery, gate decisions, `RLIMIT_NOFILE` and `holder_lost` (counted for Settled 12); a CLI command listing each panel's terminal, tty, lifecycle state and serving hc build. Never terminal contents or secrets. c11h notes in the c11h repo's skill. | Injected faults (core unreachable, failed attach, refused caller) are each diagnosed from logs and the CLI alone. |
| 10 | **Signed build and installer.** A Release build from the build host, signed by the build-host release keychain (or, until it lands, on the laptop by a c11h variant of `release-local.sh`'s tail; Settled 6); one install and update command that swaps the app at a stable path while terminals run, keeps hc at its stable path, and on first install imports c11's settings (Settled 13). Kills nothing outside c11h. | In a guest beside a live c11 and herdr-app: install signed build A, grant Desktop, Documents and Downloads, start agents; install signed build B with the same command; from the same shells read the files again, call `c11` from a surviving agent, open a new shell, then kill only the core. Everything holds, and c11 and herdr-app are untouched. A guest with a customized c11 yields a c11h with the same settings at first launch, c11's files unchanged. |
| 15 | **Where it runs.** An HTML prototype of the panel subtitle area showing the session's machine (the laptop now, the build host in phase 2) and a mark for a session that won't survive a restart; Atin picks; then the build, from the lifecycle state and the inventory (Settled 11). Large text, fixed width, no layout jump. | Atin signed off the prototype; every terminal panel shows its machine and persistence, and the mark matches the CLI's lifecycle state for the same panel. |

**Order.** 1 and 2 start together. Once 2's contract is frozen, 5, 6 and 9 build against it and 3 starts from 2's review handoff; 4 and 7 follow 3; 8 follows 3, 4, 6 and 7; 10 starts after 1; 15's prototype starts at once and its build after 2's contract. The critical path is 2 → 3 → 7 → 8 → Validator: 2, 3 and 8 take the large-ticket review track, and the Orchestrator never lets that path wait for a build slot.

## Go/no-go checks (the Pathfinder runs them on the spike build, on the chosen pin, before any ticket starts)

| Check | How | Stops the project if |
|---|---|---|
| **TCC after relaunch** | A shell in an hc terminal reads Desktop, Documents and Downloads; quit c11h, relaunch it, read again from the same shell; repeat after hc restarts its core. | Access is lost or prompts again, and no fix is affordable. |
| **Memory under a flood** | 500 MB of output in 1, 4 and 8 terminals; core memory during and after; typing delay in another panel; then close a flooding panel (A4). | Core memory grows with flood size and doesn't come back. |
| **Two hc sessions on one machine** | A `default` session with live terminals beside c11h's; restart and kill each core (A1, F8). | Either session ends or adopts the other's terminals, with no fix that keeps the pin. |
| **Scale** | 200 panels; time until CPU settles. On the spike build the core runs under a 256 soft file limit, to record where it caps; the `open`-launched run with the raised limit is ticket 2's acceptance and the Validator's (F1). | Not a stop; decides whether law 4 needs work in M1. |
| **Typing latency** | The spike's in-app probe, idle and with 20 panels replaying agent output. | Not a stop if within +0.3 ms p99. |
| **Holder loss** | Kill hc's holder; record what the panels show. | Not a stop; feeds Settled 12. |
| **Build-host link** | Our hc on the build host (own folder and session) linked from an isolated hc on the laptop over the tailnet: typing round trip, a dropped and restored link, the build-host core and its terminals across both. | Typing over the tailnet above 20 ms typical, or a reconnect loses terminals (the vision's M3 stop). |

The Pathfinder also publishes the **acceptance matrix**: every row of the spike's checklist and every ticket's acceptance against the chosen pin, each with an owner, a procedure, a timeout, what is observed and any accepted residual (A12). The remote leg moves to M3. Reviewers judge tickets against the matrix.

## Phase 2: build-host terminals (M3, same run, Settled 14)

**When phase 2 is done.** You open a panel on the build host from the menu, or an agent runs `c11 new-panel --on studio`. It sits in a workspace beside your laptop terminals, marked with its host, and typing feels local. You close the lid and walk away; build-host agents keep working. An hour later you reopen and every build-host panel is live, with what happened while you were gone. The sidebar shows what each build-host terminal runs and whether Claude there is working, idle or blocked, and build-host agents name their panels, raise flags and mail each other as local ones do, while the laptop is awake (Settled 9).

| # | Ticket | Done when |
|---|---|---|
| 11 | **Our hc on the build host.** c11h's pinned hc installed on the build host in a folder c11h owns, session `c11h`, off PATH; c11h on the laptop links it with `hc machine add` over the tailnet. hc's default remote command runs whatever `herdr-core` is on the build host's PATH or in `~/.local/bin`, which today is herdr-app's install, so the link names our binary explicitly. Link state shown; reconnect after a network drop or a closed lid. herdr-app's build-host install and its `default` session untouched. | The link reconnects after its SSH is killed and after the laptop sleeps; `ps` on the build host shows only our binary serving session `c11h`; herdr-app's build-host terminals are unchanged. |
| 12 | **build-host panels.** Create a terminal on a machine from the UI and with `--on <machine>` on `new-panel`, `new-area` and `launch-agent`; ticket 15's subtitle shows the build host; restore and reattach of remote addresses through the inventory; close; dropped files sent with `terminal.put`; the starting folder from the remote record (rows 29, 43). Browsers stay local. | A workspace mixes laptop and build-host terminals; Quit, force-quit and a lid close of an hour each bring every build-host panel back live. |
| 13 | **build-host status.** Each remote terminal's foreground program and OSC 7501 status (Claude reports working, idle and blocked) feed the sidebar and the attention model; turns that finished while c11h was away are shown; a lost link is visible on its panels (row 37). | Claude on the build host shows working, then blocked, in the sidebar; Codex shows its program name. |
| 14 | **build-host agents talk back (the relay, Settled 9).** The `c11` CLI on the build host, on PATH only inside c11h's build-host terminals, reaches c11h's socket through the machine's SSH link while the laptop is awake; identity comes from the panel's env; calls fail fast and journal writes spool while the link is down. The relay's trust is logged and documented (C11H-176 replaced the prototype's same-user trust with per-terminal credentials). Bus agreements (Bus Lead, 2026-10-31, `constellation-bus/sequence/research/09-c11h-fit.md`): c11's mailbox envelope v1 stays the on-host format, and the relay writes only under `ext.c11h`, stamping `ext.c11h.origin_host` and `ext.c11h.relay: true` on every envelope it carries (`ext.cbus` is reserved for the bus); a mail address is the panel's `mailbox.address`, else `id:<uuid>`, and never carries a host, machine or session name (show the host as a badge, never a `--to` prefix); the sender stamp keeps c11's `ext.c11_sender_panel_id` rule and adds the origin host beside it. | From a build-host terminal: `set-description`, `raise-flag`, `mailbox send` to a laptop agent and `mailbox recv` all work; with the laptop asleep, calls fail fast and nothing hangs. |

**Order.** 11 starts with phase 1, since it touches only the build host and needs only the contract. 12 and 13 start when phase 1's tickets merge; 14 follows 12. The Validator's phase 2 run checks every line of "When phase 2 is done".

## How you get it

1. The Result Validator runs the assembled build in a guest against every promise in "When M1 is done", every go/no-go check, and ticket 10's two-build signed update. GREEN or named residuals.
2. Ticket 10's command installs the signed build on the laptop, with a one-page guide: what to try first and what works differently.
3. You use it for real work beside c11 for at least a week, holder losses counted (Settled 12), while phase 2 builds.
4. Phase 2's Validator run passes; the same command updates your install, and build-host panels appear. You make the call on M4.

## After M1

| | What you do at the end |
|---|---|
| **M3 the build host** | Phase 2 of this run, above. |
| **M4 Daily driver** | Weeks of real work in c11h across the laptop and the build host. |
| **M5 Own hc** | One app with stock hc inside, signed by us, terminals spread across hc sessions (shards, sooner if Settled 12's count says so); upstream releases adopted by contract check and pin bump (vision Decided 12). |
| **M6 Remote agents** | The full c11 skill works from a build-host terminal with the lid closed; agent state lives on each machine (vision, Open 6); for mail, the prototype relay is replaced by the Constellation bus once a host runs it. Includes the session finder (bus decision D38): each host's agent layer indexes that host's transcripts, c11h combines the indexes, and resume opens a terminal through hc on the host where the transcript lives (earlier proposal: `docs/c11v-design.md:234-242`). |
| **M7 New boxes** | One command turns a Prime box into a c11h host. A box never becomes the parent of a Mac terminal: hc lets a federated machine type into and read any local terminal that started work on it (`notes/c11v-herdr-core/hc-federation-robustness.md:204`). |
| **M8 Graduation** | c11h's backend becomes a setting, then the default, in c11; or c11h stays its own app. |
| **M9 Other screens** | Answer a blocked build-host agent from the phone. |

"Customizable display" (law 5) grows from what Atin asks for while using c11h (vision, Decided 6).

## Risks carried through the plan

1. **One holder process runs every terminal.** If it dies, every terminal dies. Counted during M1 use; answered by shards (vision Decided 12; Settled 12).
2. **One lock and one parse thread in hc's core.** Heavy output slows typing in other terminals: 8.4 ms p99 with one flood in the spike; on 0.1.16, p99 76 ms with 4 floods and a 7 to 16 s echo with 8 floods, also when typed straight through hc (`<run-notes>/pathfinder-gates.md`). Normal agent output is fine (+0.2 to 0.6 ms with 20 replaying panels). The phase 1 Validator measures typing under realistic heavy load (several builds and agents at once); if the lag shows there, shards move ahead of M5 (vision Decided 12).
3. **The socket gate becomes a same-user check.** hc lets any process of the same user drive any terminal, so the gate restores function, not a security boundary.
4. **hc moves fast.** Seven releases since 2026-10-23. The pin holds for M1; any later move is its own change with a screen and history compatibility check.
5. **Build-host capacity.** One shared build slot and shared guests with the c11 1.0 run; about 4.7 GB per build tag, 124 GB free. The run uses three tags, checks free disk at launch, and prunes at each completion (F7).
6. **Running beside c11 on the laptop.** Ticket 1's seeded guest test and ticket 10's install beside a live c11 exist for this; the brief forbids every script that kills by name on the laptop.
<!-- c11-2.0:end-keep -->
