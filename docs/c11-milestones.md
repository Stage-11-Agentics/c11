<!-- c11-2.0:begin-keep (history: written while this line was c11h; the rename must not touch it) -->
# c11h milestones

> **Historical.** Written while this line was c11h, before it became c11 2.0 (`C11.md`, Decisions 1-3). Names are as they were then; `docs/c11-2.0-identity.md` maps each to its 2.0 name.

Status: final, 2026-11-01 12:44 PST. Atin's direction via the c11h Lead: "focus is just on milestone 1 and 2. Get everything done." Milestones 1 and 2 are in scope and the Orchestrator turns them into tickets; milestone 3 is recorded for later and out of the current scope. Written on the build host at his request ("plan out the remaining milestones of c11h, because it feels like we're just about set with what we've set out to do here", 11:20 PST). Revised at 12:05 PST on his ask to compound the work into fewer, larger milestones, and at 12:50 PST for the hc Lead's stock-first plan (`<run-folder>/hc-fork-plan.md` on the build host, `docs/fork-plan.md` in the hc repo), which Atin approved in part at 12:40 PST. The vision's milestone table (`docs/c11-vision.md`, M1 to M9) stays the frame; its codes appear here as labels inside three milestones so tickets and notes still trace back. Each milestone says what it proves, which tickets build it, what it waits on, roughly how big it is, and what needs Atin. The decisions at the end are taken. Nothing here writes the board; the Orchestrator creates the proposed tickets for milestones 1 and 2.

Sources: `docs/c11-vision.md` (Laws, Decided 1 to 11, Open 3 and 5), `docs/c11-plan.md` (Settled 1 to 17, Risks 1 to 6, After M1), `<run-notes>/status.md`, `run-state.md`, `validator-phase1.md`, `validator-phase2.md`, `laptop-day1.md`, the hosted board `stage11/c11h`, and the c11h Lead's `retro-notes.md`.

## Where things stand, 2026-11-01 11:20 PST

| | State | Evidence |
|---|---|---|
| **M1 Usable** | Done. update1 (commit 8246ac27) installed on the laptop at 10:34 PST in place over the running build; five hc terminals kept their pids. Two Quit survival tests passed by hand (10:08 and 10:15 PST). Agents inside c11h use `c11` since the C11H-33 fix. Phase 1 Validator: RESIDUALS 10, none blocking, on 9b38bf78; the long pass is still pending. | `laptop-day1.md`, `validator-phase1.md`, status 10:38 |
| **M3 the build host** | Code merged (#26, #27, #28, #40, #69, #72, #74). Phase 2 Validator in a guest: RESIDUALS 4, none blocking, on da5a8ecd. The build host is linked from the laptop's c11h (09:08 PST). The build-host relay install for the real session was in progress at 11:13 PST. Typing to the build host runs over Tailscale's DERP relay at about 72 ms p50, pending Atin's UniFi forward of UDP 41641 (Settled 17). By hand on the laptop still: typing (G.7), sleep (T11.4), an hour with the lid closed (T12.4), a file drag (T12.5), Claude working then blocked (T13.1), an away turn in Feed (T13.3). | `validator-phase2.md`, status 11:11 and 11:14, `atlas-link-result.md` |
| **update2** | Queued: C11H-39 (#83, resume sheet no longer gates live terminals), C11H-40 (#84, a refused caller writes no envelope), #76 (per-launch note), C11H-41 (ship the CLI as `c11h` too), C11H-42 (`hc machine ls`), C11H-44 (Claude login in build-host panels, plan written), the phase 2 kit fixes (#88). | status 11:01, board |
| **UX wave 1** | Decided by Atin at 11:05 and 11:11 PST and building: C11H-32 (Sunset Mall in the Dark slot, Outrun Horizon offered), C11H-36 (sidecar skill, Settings and `c11 skill install c11h` only), C11H-37 (standalone hc core utility with his six changes), C11H-38 (resume by default, c11's C11-559 words and key; Start fresh never ends a live terminal). | status 11:12 and 11:17 |
| **Trust** | Same-user file trust kept for the prototype and documented in the install guide (C11H-43, #87). Tightening is C11H-45, a pre-release item. The relay's trust is prototype-only (Settled 9, `docs/c11-relay.md`). | board, status 11:12 |
| **c11 sync** | None yet. c11h forked c11 at 20c4583d (2026-10-31 15:55 PDT). c11's `main` is 44 commits past that point at dc461322 (2026-11-01 10:45 PST); c11h carries 347 commits of its own. c11h's project version is 1.6.0; the laptop runs c11 1.7.6. | `git log origin/main ^c11/main`, lead-state 10:40 |
| **hc** | Pinned at 0.1.16 (`c617feeb…`), the newest release as of today (`releases.herdr.dev/core/latest.json`); upstream `master` is 11 commits past it, with a launchd start and signed macOS builds, and v0.1.17 is expected. Atin decided at 12:40 PST: the fork lives at `Stage-11-Agentics/hc` (working name), private and standalone, owned by the new hc Lead (laptop panel 91, mailbox `hc-lead`); an hc census across machines is approved, built after phase 2. Direction from Atin: "effortlessly pull herdr-core updates, maybe a shim so we use stock herdr-core." Atin ruled at 12:50 PST that stock hc plus shards is the new plan ("consider this the new plan"); the hc Lead recorded it on `main` as vision Decided 12 and the reworded law 8 (8d97969): unmodified upstream hc, built and signed by us, every need met outside the binary, terminals spread across hc sessions, a patch only when nothing outside can do the job. | run-state Pathfinder table, vision Decided 12, `hc-fork-plan.md` Stock first |
| **Signing** | Developer ID `UKQ4QALWD4` from the build host's `acetate-release.keychain-db`, hardened and timestamped, not notarized. The keychain already holds the `acetate-notary` profile c11 1.7.5 and 1.7.6 were notarized with (Chief of Staff, 11:47 PST). The first launch after each install waits about 4.5 minutes on Gatekeeper (F9). Sparkle off, telemetry and crash reporting off. | status 05:39 and 08:09, `validator-phase1.md` F9 and V4 |

## The three milestones

| | Milestone | Folds | Goal | Size | Ends with |
|---|---|---|---|---|---|
| **1** | **Daily driver** | M3 close-out, M4, notarized updates | Build-host proven on the real link, and Atin does his real agent work in c11h across the laptop and the build host for two weeks on notarized updates. | About three weeks; a lean line of three or four seats | Atin's continue-or-stop call (Law 9) |
| **2** | **The fleet** | M5, M6, M7 | c11h runs on stock hc that we build, sign and bundle, sharded so no holder loss or flood touches more than one shard; an agent on any machine is a full citizen with the lid closed; a Prime box joins in one command. | Six to seven weeks; the large-ticket track, four to six seats, its own Validator | The full c11 skill working from the build host and from a box |
| **3** | **Release** (later, out of the current scope) | R2 trust gate, M8, M9 | The trust surfaces closed, the graduation call made, a release shipped, and a blocked agent answered from a phone. | Three to four weeks after the call | A c11 release with the hc backend, or c11h as its own app |

Milestone 2's fork work starts during milestone 1 (vision, Decided 4) and its remote-agent work runs on c11h's relay behind one transport interface, with the bus off its path (Decided 14). Milestone 3 gates any build that reaches someone other than Atin.

## Milestone 1: Daily driver

**Goal.** Phase 2's promise holds on the laptop, not only in a guest, and Atin runs c11h for his real agent work across the laptop and the build host for weeks, with notarized updates arriving through one command (vision M3 and M4, Law 9).

**Done when (proven).**

- Every line of the plan's "When phase 2 is done" is recorded in `laptop-day1.md` with a result: a build-host panel opened from the menu and with `--on studio`; the lid closed for an hour and every build-host panel back live; Claude on the build host showing working, then blocked, in the sidebar; a build-host agent naming its panel, raising a flag and mailing a laptop agent. Typing to the build host is re-measured after Atin's UniFi forward, against the 20 ms line (Settled 17).
- update2 and update3 installed in place with terminals kept; update3 is the first notarized one, and the new build opens within seconds of its process start (F9 gone). `c11h --version` and About show c11h's own version line.
- Fourteen days of use logged in `<run-notes>/laptop-use.md` (one line a day: hours, agents, machines, anything that bit). Holder losses counted for the whole period (Settled 12). The typing probe run under Atin's real load at least twice (several builds and agents at once, risk 2), with p99 recorded.
- UX wave 1 shipped in an update he uses. c11's `main` merged into c11h once, before update3.
- The M1 run is closed: the phase 1 long pass has a verdict, the board's tickets still in review (C11H-11, C11H-16, C11H-17) are completed, C11H-29 is done or cancelled, the run's tags and worktrees are pruned, and `run-retro` has folded the Lead's retro notes into the skills that own them.
- At the end Atin says he prefers c11h for agent work that reaches the build host, or says why not. The vision's stop stands: a holder crash that takes every terminal with no affordable fix, or lag under his real load, ends the project and triggers the fallback.

**Tickets, in order.**

1. C11H-16: relay installed on the build host for the real session (in progress 11:13 PST); then the laptop tester's T14 rows.
2. C11H-44: Claude login inside a build-host panel, confirmed on the real link first (T13.1 and T13.3 wait on it). The day-one workaround is `/login` in that panel; the real fix is milestone 2's per-host layer or a GUI-session core on the build host, per its plan.
3. update2: C11H-39, C11H-40, C11H-41, C11H-42, #76, #88, built and signed from the build host, a READY FOR laptop line, installed in place.
4. By-hand rows on the laptop: G.7, T11.4, T12.4, T12.5, T13.1, T13.3, plus the Codex rows (`laptop-codex-rows.md`, one Force Quit by Atin).
5. Proposed `p2-typing-remeasure`: the typing probe on the direct path after the UniFi forward; the 20 ms line becomes a stop or a fork item (risk 2).
6. Proposed `notarize`: notarytool submission and stapling in the c11h build script, using the keychain's existing `acetate-notary` profile; a `release-local`-shaped script for c11h with the same hash and identity files the install guide lists.
7. Proposed `version-line`: c11h's version scheme (recommendation: c11's version plus an `h` build line, so 1.7.6-h3 says which c11 it carries and which c11h update it is), set in one place, shown in About, `--version`, the per-launch note and `hc-diagnostics`. The install script stays the update path; Sparkle stays off until a build reaches someone else.
8. `hc-census` (approved by Atin at 12:40 PST, owned by the hc Lead, lives under `stage11/` in the hc repo): a census of hc cores and sessions across the laptop, the build host and later the boxes, reporting each core's version and build ("hc 0.1.16 (stock, Stage 11 build)"), its session, holder and terminals; it feeds C11H-37's utility and the holder-loss count.
9. Proposed `c11-sync-1`: merge c11's `main` into c11h for the first time (44 commits since the fork point, c11 1.7.x), gated on the build host, before update3. See the Sync track.
10. UX wave 1 as decided: C11H-38 (resume by default), C11H-32 (Sunset Mall), C11H-37 (the core utility), C11H-36 (the sidecar skill, text to Atin before it is written). Ship in update3.
11. Proposed `use-log`: the daily use line and the holder-loss counter, written by the c11h Lead from Atin's notes and the `holder_lost` log; proposed `real-load-probe`: the typing probe under Atin's real load, twice.
12. Proposed `agent-facing-residuals`: the residuals that mislead an agent. P2-F1 (`hc-diagnostics` says `live` for a build-host panel whose link is down, carries no machine field); F10 (hidden tabs blank after a core kill until shown); F2 (no tty in `hc-diagnostics`). Proposed `cosmetic-residuals`, backlog: F4 and P2-F2 (the where-it-runs chip has no accessibility label), the Settings text that still says c11.
13. Validator phase 1 long pass (31 rows, its own lease, the token holder for the agent rows); proposed `run-closeout`: board hygiene, tag and worktree pruning on the build host, `run-retro` on `retro-notes.md` and `run-state.md`'s retro notes.
14. Maintenance for the rest of the period: whatever the use log surfaces, one update a week at most, each with a READY FOR laptop line and an in-place install.

**Depends on.** Atin's UniFi forward (Settled 17) for ticket 5 only. Nothing else blocks; local use started 2026-11-01.

**Size.** About three weeks of calendar time: two or three days to close out phase 2 and the run, then two weeks of use. The line behind it is lean: one Lead, one Merge Captain, two or three owners, no Validator lease unless an update changes the hc backend.

**Needs Atin.** The by-hand rows (about an hour across a day, since the lid row needs an hour closed); one Force Quit for the Codex rows; the UniFi forward when he gets to it; the go for each update's install; the version scheme pick; using it daily and a line a day for the use log, or a word to the Lead; the continue-or-stop call at the end. His decision on what moves first: the recommendation is agent work that reaches the build host, since that is what c11 cannot do.

## Milestone 2: The fleet

Re-planned at 13:30 PST (Atin 13:25, via the c11h M1 M2 Lead; status 13:30): c11h stays a separate app, the bus is off the critical path (vision Decided 14), shards come first. Bus transport (C11H-72) and the relay's retirement (C11H-75) moved to Milestone 3 (`docs/c11-milestones-3-5.md`).

**Goal.** c11h ships with stock upstream hc that we build, sign and bundle, its terminals spread across shards, adopting each upstream release as a pin change with nothing to merge or rebase, our tooling open source in `Stage-11-Agentics/hc` (vision law 8 and Decided 12, 8d97969); an agent on any machine reports, flags and mails exactly as a local one does, with the laptop closed, and each machine keeps its agents' state; one command makes a Prime box a host (vision M5, M6, M7; Decided 4, 10 and 11). M6 is the goal the vision names.

**Done when (proven).**

- One app, no separate hc install step: a first install on a clean guest runs terminals with the bundled stock core, built by us from an upstream tag, in bundle mode achieved outside the binary: the binary sits in a folder the user can't write, so hc's own `update` refuses; the launcher sets `HC_LAUNCHD_DIRECT` so TCC stays with c11h; the core gets its own `XDG_CONFIG_HOME` while agents keep theirs. An installed update keeps every live screen (T3.4 and T10.3 on the bundled core). Our build reproduces itself (two builds of one commit hash-equal) and is behavior-identical to the pin on c11h's contract suite, with a checksum c11h verifies at every connection (contract L2). c11h's terminals are sharded across several hc sessions (one per workspace, say), each its own core, holder and parse thread, and a guest proof shows a holder kill and an 8-terminal flood each touch one shard only (risks 1 and 2 answered without a patch; vision Decided 12). An upstream tag is adopted by the watch job fetching it by hash and building it unmodified, the contract suite passing, and the pin moving, with nothing to rebase and no code change in c11h beyond the pin. The repo is public, with upstream's LICENSE and third-party notices carried alongside our tooling, as Apache-2.0 asks. Durable clear-history (A13) and hc's query answers (X.1 to X.3) stay accepted residuals unless use makes them hurt; only then does a patch exist, and the repo then says how it is applied on top of the fetched tag.
- The full c11 skill works from a build-host terminal: every verb the skill teaches, run from the build host with the laptop asleep, lands when the laptop wakes, with nothing lost and nothing duplicated. A blocked build-host agent's flag reaches the sidebar and the menu bar extra after an hour of lid-closed time. Mail between a build-host agent and a laptop agent travels over the relay behind the host transport interface (C11H-70), with receipts; no bus is involved, and the bus replaces that transport in Milestone 3. The session finder (bus D38) resumes a build-host transcript into a terminal on the build host.
- On a fresh Prime box, one command run from laptop installs the bundled hc, the agent layer and the agent CLIs, links the box, and a terminal on it appears in c11h with its host chip. An agent launched there reports, flags and mails like a build-host one. A box never becomes the parent of a Mac terminal (plan, After M1). Removing the box with one command leaves nothing behind.
- The bar (C11H-81, Atin 13:25): about 30 agents across the laptop, the build host and a Prime box through a working day and a lid-closed night. Typing feels local; overnight, build-host agents mail each other and their flags wait for Atin; a holder loss ends one shard only; Claude works in every remote panel.

**Tickets, in order.**

Shards, the critical path:

1. C11H-65 SH1: the contract amendment for shards and the bundled core (Amendment 1, #107, frozen 14:36).
2. C11H-67 SH2: the shard pool (8 per machine, started lazily) and sticky placement by workspace.
3. C11H-77 SH3: admission and agents across shards.
4. C11H-78 SH4: remote shard pairs, one build-host link per shard pair.
5. C11H-79 SH5: diagnostics per shard.
6. C11H-80 SH6: the shard guest proof (a holder kill ends one shard; floods stay in one shard).
7. C11H-66 `hc-bundle`: the stock binary inside c11h.app at `Contents/Helpers/<name>`, in a folder the user can't write, signed in the same inside-out codesign pass with hardened runtime (W3 cleared it with no entitlements); started directly by c11h, with its own `XDG_CONFIG_HOME`; no PATH exposure; the installer stops installing hc separately; the build-host link script installs the same binary on the remote.

The per-host agent layer, with the relay behind one transport interface:

8. C11H-70: the frozen contract for the per-host layer on envelope v1, including the host transport interface (send an envelope to a host; receive from a host, ordered, at least once, deduped by id; hold for a host that's away). The relay is its first implementation; bodies and subjects are opaque bytes to it, so the bus drops in later.
9. C11H-71: the layer on every host, with cross-host mail over the relay, including C11H-44's real fix (Claude works in every remote panel, moving no credential).
10. C11H-73 `away-merge`: each host's log merged on wake; turns, flags and status that happened away appear in Feed and the sidebar in order.
11. C11H-74 `session-finder`: each host indexes its own transcripts; resume opens a terminal through hc on the host that holds the transcript.

The Prime box:

12. C11H-76: what a box needs, the one command from the laptop and its inverse, and the proof. A box holds exactly one c11h panel: box-join links one seat, so a process copying the environment can claim only that seat. Mail from a box keeps `ext.c11h.origin_host`, and agents treat it as that seat's words, never Atin's. Same-user relay trust on a rented box is accepted for Milestone 2 under that rule; real relay authentication (C11H-45) is a release gate (M1 M2 Lead, 16:20).

The bar:

13. C11H-81: the 30-agent day and night, run by a Validator that wrote none of it, plus Atin by hand. It also records Milestone 4's baseline: time from a flag being raised to showing on the laptop (p50, p95), time from a flag to Atin's answer, memory per agent and per hc core, main-thread stalls (count and longest), relay call latency (p50, p95) and refusals, and use per Claude and Codex account over the day (M1 M2 Lead, 16:20).

Alongside: the hc Lead's wave 1 (C11H-58 to C11H-64: the repo and build, the contract suite, the shim checks, the shard experiment and design, the census, the upstream watch), C11H-68 (adopting an upstream tag as a pin change with the compatibility check; nothing to rebase) and `hc-publish` (the tooling repo public on Atin's go). Moved to Milestone 3: C11H-72 (bus transport) and C11H-75 (the relay's retirement).

**Depends on.** Milestone 1's holder count and real-load probe for the shard-or-patch call, and the name (Open 3) for `hc-publish`; the hc Lead's wave 1 runs alongside from Milestone 1. Nothing waits on the bus (vision Decided 14). The bar's "typing feels local" needs Atin's UniFi forward (UDP 41641 to the laptop): the build host typing p95 is about 500 ms over the DERP relay today (Glass Test, 14:08). Ticket 12 needs the bundled hc, including its Linux build, and the agent layer on a non-Mac host.

**Size.** ETAs from the 13:30 re-plan: shards ~2026-11-05 (status 13:49), the per-host layer ~11-20, the Prime box ~11-26, the bar ~12-01. The original estimate was six to seven weeks on the large-ticket track: one to two weeks for own hc (the hc Lead for the repo, pipeline and watch job; one c11h seat for bundling and sharding; no Rust patch work unless evidence calls for it; overlapping milestone 1), three to four weeks for remote agents (four to six seats, a Validator run of its own, the biggest remaining work), one week for boxes (two seats).

**Needs Atin.** The repo name (Open 3; working name `hc`; the binary may stay `herdr-core`, credited as upstream's); the go to publish, since that is outward-facing; K = 8 shards per machine or one per workspace (asked 2026-11-01 15:33; the recommendation is keep 8); the UniFi forward (UDP 41641 to the laptop), which the bar's "typing feels local" needs; an hour of lid-closed time for the proof; which Prime boxes, their OS, how the laptop reaches them, and whether a box also runs agents or only sandboxes.

## Milestone 3: Release (later, out of the current scope)

Superseded by `docs/c11-milestones-3-5.md` (vision Decided 15, Atin 2026-11-01 15:52): Milestone 3 is now Your constellation, and Release moves to Milestone 5. Kept below as the record.

Recorded so the shape is known; nothing below is scheduled or ticketed until Atin reopens it after milestones 1 and 2.

**Goal.** Before any build reaches someone other than Atin, c11h's same-user trust surfaces are closed or deliberately documented with his sign-off; Atin decides whether c11h's backend becomes a setting, then the default, in c11, and the c11h name retires, or c11h stays a separate app; a release ships; and a blocked build-host agent is answered from a phone (vision M8 and M9; Decided 9; Open 5; C11H-45).

**Done when (proven).**

- A written trust model in `docs/c11h-trust.md` names every path that reaches the app or its agents and what admits each: socket admission by terminal ancestry (C11H-33), mailbox files, the link to other hosts. C11H-45 is done: the dispatcher delivers only envelopes whose sender an admitted call claimed, and the turn-end drain reads through the socket; the c11 raw-file protocol's agents still work or the skill says what changed. The relay is gone (milestone 2) or authenticated. A review by a seat that wrote none of it finds no same-user bypass. Atin waives any item he wants kept open, in writing.
- Atin makes the graduation call and it is recorded in the vision's Decided list. If graduation: c11 `main` carries the hc backend behind a setting, off by default, with every c11h test green in c11's CI and the c11 skill carrying the sidecar's content; then a release with it on by default, with his named approval. If separate: c11h gets its own release skill, an appcast and a public repo decision, and the vision's "Not doing" list is rewritten.
- From a phone, Atin sees a flagged build-host agent, reads its screen and sends the answer; the agent continues; the sidebar on the laptop shows the flag cleared.

**Tickets, in order.**

1. Proposed `trust-model`: the document, from C11H-40's audit and `docs/c11-relay.md`.
2. C11H-45: the mailbox file trust.
3. Proposed `trust-review`: the independent review, with the gated-mode guest rows (V6.admission) extended to mail and the link.
4. Proposed `graduation-brief`: the two options costed from what milestones 1 and 2 showed, for Atin's call.
5. If graduation: proposed `backend-setting` (the hc backend in c11 behind `c11.terminal.backend`), `c11-ci-green` (c11h's tests in c11's PR poller and backstop), `skill-merge` (the sidecar folds into the c11 skill), then a c11 release through `skills/release`. If separate: proposed `c11h-release-skill`, the appcast, and the public repo question.
6. Proposed `screens-brief`: build a small web viewer on the per-host layer and hc, or evaluate Heeler (the third-party phone client porting to hc) against the bus and the agent layer. A brief first, since milestone 2 decides what a viewer can read.
7. The viewer's build or the integration, scoped by the brief.

**Depends on.** Milestone 1's verdict and milestone 2 in full (the relay's removal for the trust gate; the agent layer for the phone).

**Size.** Three to four weeks after the call: a week for the trust gate (two seats), two weeks if graduation since c11's gates are heavier than c11h's or a few days if separate, one to two weeks for a viewer (unknown for Heeler).

**Needs Atin.** The ruling on whether anyone gets a c11h build before this milestone (the vision says no; the gate exists in case that changes); sign-off on the trust model; the graduation call and the named approval any c11 release needs; whether to build or borrow the phone screen, after the brief.

## Tracks that run through every milestone

**Sync with c11 (Settled 1).** c11's `main` is merged into c11h before each update build from update3 on, as its own ticket with the build-host gate and a guest smoke when the merge touches terminals, restore or the socket. The first merge was C11H-51 (#104, c11 `d04011eb`); the second is C11H-95, to c11 `v1.7.9`. From C11H-180 (2026-11-03) each sync merges a pinned c11 `main` tip, not a release tag, and lands as a merge commit, never a squash, so the next one starts from it (rules in `C11.md`; #104's squash had to be repaired on 2026-11-02 with a tree-neutral `-s ours` merge of `d04011eb`). The other direction is closed: c11h fixes stay in c11h and the sync takes c11's version where both fixed the same thing (Decisions, 2, revised 2026-11-02).

**The skill.** C11H-36's sidecar carries only what differs in c11h, installed only through c11h's own skill install (milestone 1). Milestone 2 proves the full c11 skill from a build-host terminal. Milestone 3 either folds the sidecar into the c11 skill or keeps it. The hard rule holds throughout: a CLI, socket or model change is incomplete until the skill matches, and the installed copies are synced.

**Security.** C11H-40 (update2), C11H-43's documented boundary (done), the trust gate before any outside build (milestone 3), the relay's end in milestone 2. The socket admission by ancestry is a same-user check and stays so (risk 3); the trust model says so in writing.

**Release machinery.** Milestone 1 gives notarized, versioned updates through the existing install command, from the keychain that already notarizes c11. The update feed and a release skill wait for the graduation call. Keys never leave the build host's sealed keychain (Settled 6).

**How each milestone runs.** Each runs through `lattice-hosted-orchestrator` with its own brief, a Validator that wrote none of it, and Atin's call at the end (Law 9). The M1 run closes with a retro inside milestone 1, which is otherwise a lean line that lives for weeks, not a full run. Milestones 2 and 3 are full runs. The Lead's retro lessons apply from the next brief on: a gate never waits on a scarce shared resource, each run gets its own build lanes and tags from the start, proofs run the product's real security posture, and a contract that blocks several tickets gets a time box and a named decider.

## Decisions

Numbered as in the panel message. Atin took 1, 2, 4 and 5 on the planner's recommendations (via the c11h Lead, 12:44 PST) and settled 3 with the hc Lead at 12:40 PST. The earlier question on notarization needed no decision: the notary profile is already in the build host's sealed keychain (Chief of Staff, 11:47 PST).

1. **Three milestones**, Daily driver, The fleet, Release, in that order, with the vision's M-codes as labels inside them. Taken; Release is out of the current scope.
2. **c11 sync.** Merge c11's `main` into c11h before every update from update3 on; generic c11h fixes may go back to c11 as normal PRs when they do not touch the backend. Taken, both. Revised by Atin 2026-11-02: syncs merge a c11 release tag and land as merge commits; generic fixes do not go back to c11 ("I've got so many agents making so many commits, I'm just trying to manage the chaos here").
3. **The fork.** Settled by Atin at 12:40 PST with the hc Lead: `Stage-11-Agentics/hc`, private and standalone, stock-first, census approved. Still his: the name (Open 3) and the go to publish.
4. **Trust line.** Nobody outside gets a build before milestone 3 (vision, Not doing); no separate relay-authentication ticket, since milestone 2's bus replaces the relay. Taken.
5. **Version scheme.** c11's version plus an `h` build line, like 1.7.6-h3. Taken.

## Proposed tickets, by milestone

For the Orchestrator to create now for milestones 1 and 2. Milestone 3's rows are kept for later and not created. Existing tickets keep their ids.

| Milestone | Proposed slug | One line |
|---|---|---|
| 1 Daily driver | `p2-typing-remeasure` | Typing probe on the direct path after the UniFi forward; 20 ms line judged. |
| 1 Daily driver | `notarize` | notarytool and stapling in the c11h build script, using the keychain's existing `acetate-notary` profile. |
| 1 Daily driver | `version-line` | c11h's own version scheme, shown everywhere a version is shown; install script stays the update path. |
| 1 Daily driver | `hc-census` | Cores and sessions across machines, version and build, feeds the utility and the holder count (approved 12:40 PST). |
| 1 Daily driver | `c11-sync-1` | First merge of c11 `main` into c11h, gated, before update3. |
| 1 Daily driver | `use-log` | Daily use line and the holder-loss count, two weeks. |
| 1 Daily driver | `real-load-probe` | Typing probe under Atin's real load, twice. |
| 1 Daily driver | `agent-facing-residuals` | P2-F1, F10, F2: the residuals that mislead an agent. |
| 1 Daily driver | `cosmetic-residuals` | F4 and P2-F2 chip accessibility, Settings text that says c11. |
| 1 Daily driver | `run-closeout` | Board hygiene, tag and worktree pruning, `run-retro` on the Lead's notes. |
| 2 The fleet | `hc-repo` | `Stage-11-Agentics/hc`, private, tooling only; builds fetch the pinned upstream tag by hash; contract suite, watch job (settled 12:40 PST). |
| 2 The fleet | `hc-bundle` | Stock hc inside c11h.app, unwritable, `HC_LAUNCHD_DIRECT`, own config; installer and link script updated. |
| 2 The fleet | `hc-shards`, `hc-patch` | Shards in c11h from the hc Lead's measured design (run's line); a patch only as the fallback (Decided 12). |
| 2 The fleet | `hc-upstream-track` | Adopting a tag the watch job passed: a pin change, our build tag, a c11h pin-bump with the compatibility check; nothing to rebase. |
| 2 The fleet | `hc-publish` | The tooling and queue repo public under its name, lineage in the README, on Atin's go. |
| 2 The fleet | C11H-70 | Frozen contract for the per-host agent layer and the host transport interface. |
| 2 The fleet | `host-agent-layer` | Per-host store and admission, bundled on every host. |
| 2 The fleet | `away-merge` | Each host's log merged on wake, shown in order. |
| 2 The fleet | `session-finder` | Per-host transcript index; resume on the owning host. |
| 2 The fleet | `box-image`, `box-join`, `box-proof` | What a box needs, the one command and its inverse, the proof. |
| 2 The fleet | C11H-81 | The bar: about 30 agents across three hosts for a day and a lid-closed night, plus Milestone 4's baseline. |
| Moved to Milestone 3 | C11H-72 `bus-transport`, C11H-75 `relay-retire` | Moved out of Milestone 2 at 13:30 (vision Decided 14). |
| 3 Release | `trust-model`, `trust-review` | The written trust model and its independent review; C11H-45 between them. |
| 3 Release | `graduation-brief` | The two options costed for Atin's call. |
| 3 Release | `backend-setting`, `c11-ci-green`, `skill-merge` or `c11h-release-skill` | Whichever way the call goes. |
| 3 Release | `screens-brief` | Build a viewer or borrow Heeler, decided on milestone 2's shape. |
<!-- c11-2.0:end-keep -->
