<!-- c11-2.0:begin-keep (history: written while this line was c11h; the rename must not touch it) -->
# c11h milestones 3 to 5

> **Historical.** Written while this line was c11h, before it became c11 2.0 (`C11.md`, Decisions 1-3). Names are as they were then; `docs/c11-2.0-identity.md` maps each to its 2.0 name.

Status: approved by Atin, 2026-11-02 01:24 PST ("Yes and yes!": the reading of decision 2 confirmed, and merge). Written 2026-11-01 with his answers of 17:39 and 18:16. Owner: the c11h M3-M5 Lead (mailbox `c11h-m3`). Planning only: nothing here writes the board; the Orchestrator creates tickets when a milestone opens. This replaces the Milestone 3 (Release) section of `docs/c11-milestones.md` (PR #97). Milestones 1 and 2 are unchanged; Milestone 2's section was brought up to its 13:30 re-plan in #125, which moved C11H-72 and C11H-75 here.

**Atin's calls behind it** (2026-11-01, in the M3-M5 Lead's panel unless noted):

- 13:20: c11h stays a separate app for now (vision Decided 13).
- 13:35: the bus stays off the critical path (Decided 14).
- 15:08, on the first outline: "Milestone 4 feels more important to me. I think Milestone 4 also includes effective communication bus. Milestone five, that makes sense, and I think then three moves to be the lowest priority milestone."
- 15:52: "yes, renumber the milestones. I think the getting the bus in as soon as reasonable is fine, and maybe that is part of Milestone 3. Regarding release ... public release to the world, let's keep C11H a separate thing that just I'm using for the time being."
- 15:53: "We can lift the no-coding yet line" (for the bus).
- 17:39, via the Chief of Staff: seal agents' mail on the bus ("Encrypt").
- 18:16, on the decisions: "Bus is optional. No big deal on weak trust as it is temporary. Two B. It's going to be ready soon. But maybe not today and not tomorrow. Let's say November 3rd." The phone: "This is completely out of scope. This does not matter. We do not need to build this right now." The attention screen: "I will handle this on my own. We're building a beautiful primitive that's going to handle this. Ultimately, though, we'll use a chief of staff type approach at least." Ticket tags: "No, we do not need to." Sealing: "plain text everything just in the short term seems okay too. If it doesn't add much extra complexity, though, sure ... go ahead and encrypt I suppose."

These are recorded as vision Decided 15 in the same PR.

Sources: `docs/c11-vision.md`, `docs/c11-plan.md`, `docs/c11-milestones.md`, `docs/c11-contract.md`, `docs/c11-contract-detail.md` (Amendment 1, #107), `docs/c11-agent-layer-contract.md` (A6, #111), `docs/c11-relay.md`, `<run-notes>/status.md` to 16:20 PST, the hosted board `stage11/c11h`, the hc repo's `docs/c11h-to-hc.md` (R1 to R4) and `docs/shards-c11h.md`, the bus repo's `SPEC.md`, `BUILDPLAN.md`, `sequence/USER_STORIES.md`, `sequence/run-state.md` and `spikes/RESULT.md`, the Bus Lead's mail of 15:29, 15:59, 16:21 and 17:44 PST, the M1 M2 Lead's mail of 15:30, 16:20 and 17:44 PST, and the Constellation's `PLACEMENT.md`.

## Where Milestones 1 and 2 leave us

| | Delivers | ETA (Pacific) | Source |
|---|---|---|---|
| **1 Daily driver** | Atin's real work in c11h across the laptop and the build host for two weeks, on notarized updates. The use clock started at 13:31 (C11H-53). | ~2026-11-19 | status 13:30 |
| **2 The fleet** | Shards: a pool of 8 per machine, frozen at 14:36 (#107). The per-host agent layer on envelope v1, with c11h's relay behind one transport interface (A6, #111). One Prime box in one command (C11H-76), holding one c11h panel. The bar: about 30 agents across the laptop, the build host and a Prime box for a working day and a lid-closed night (C11H-81), which also records Milestone 4's baseline. | shards ~11-05, layer ~11-20, box ~11-26, bar ~12-01 | status 13:30, 13:49 and 16:20; M1 M2 Lead 15:30 |
| **Moved out of 2** | C11H-72 (bus transport) and C11H-75 (relay retirement). | Milestone 3 | board, #125 |

The M1 run built 15 tickets and two Validator passes in about 18 hours (launched 2026-10-31 16:32 PDT). Calendar time comes from waits: overnight proofs, outside work like the bus, and the tickets each milestone builds on.

## The three milestones

| | Milestone | Goal | Done, in one line | Waits on | Size | ETA |
|---|---|---|---|---|---|---|
| **3** | **Your constellation** | Every machine you use runs agents as well as the laptop does, and their mail moves to the bus once it's ready. | Agents on the build host and two Prime boxes mail each other overnight while the laptop sleeps, over the bus if it's ready, else the relay. | C11H-76 (the first box); the bus for its bus tickets only | 1 to 2 weeks of c11h work, overlapping Milestone 2 from ~11-03 | ~2026-12-01 to 12-08 |
| **4** | **Hundreds** | Hundreds of agents across your machines, and c11h stays fast and steady. | A working day with 200 or more agents on five or more machines, inside budgets you signed. | Milestone 3; C11H-81's baseline | 2 to 3 weeks | late December 2026 to mid January 2027 |
| **5** | **Public release** (lowest) | Anyone can install c11h as its own app and run their own constellation safely. | A stranger installs on a clean Mac, links their own host and updates in place with no Stage 11 credential, under a trust model you signed. | Milestone 4; your go | 3 to 5 weeks, re-planned when Milestone 4 closes | not before February 2027 |

Cut: folding c11h into c11 (Decided 13); a client-deployment milestone (c11h is Atin's alone until Milestone 5); a "resilient operations" milestone (its host-loss proof is in Milestone 3); a phone path (Atin, 18:16: "completely out of scope"); an attention screen (Atin, 18:16: he builds that primitive himself, with a Chief of Staff approach).

## Milestone 3: Your constellation

**Goal.** Every machine you use runs agents as well as the laptop does, and their mail moves to the Constellation bus as soon as it's ready (vision Laws 2 and 3; the transport half of M6, and M7 beyond one box).

**Done when (proven on real machines).**

1. **Hosts.** Two Prime boxes join in one command each, and a third replaces one of them. A removed box can't reconnect, and nothing of c11h is left on it. Killing a box ends only that box's terminals; every other terminal keeps its pid.
2. **Mail overnight.** With the laptop's lid closed for a night, agents on the build host and on two Prime boxes mail each other with receipts, and their flags and status reach the laptop when the lid opens, once and in order. This goes through the transport interface (A6), whichever transport is behind it.
3. **The bus, if it's ready.** When the bus core is ready, it carries that mail behind A6, and the relay is removed (C11H-75). When it isn't, Milestone 3 closes on the relay and the bus swaps in later (Atin, 18:16: "Bus is optional").
4. Atin's continue call (Law 9).

**Not in Milestone 3.**

- The first Prime box (C11H-76) and the per-host agent layer: both are Milestone 2.
- A phone path, and an attention screen (Atin, 18:16).
- Any c11 change or release (Decided 13). The c11h cut of the bus needs none (Bus Lead, 16:21).
- A user's own constellation with no Stage 11 cloud copy or credential (bus AC-182 and AC-183): that is Milestone 5's.
- Anyone besides Atin using c11h.

**Tickets, in order.** c11h's work starts about 2026-11-03, alongside Milestone 2 (Atin, 18:16). Ticket 6 opens earlier, when the bus build starts, so it is ready with Cut 1. Ticket 4's certificates wait for Cut 1; ticket 5 waits for C11H-76 and Cut 3.

1. `bus-test` (bus board). **Passed** at 17:40 in about 1 hour 45 minutes, against a day and a half: 20 mails to a host stopped for an hour landed once, in order, with every receipt, on identical id sets on all three copies; two kill -9 runs lost and duplicated nothing (bus D66, `spikes/RESULT.md`).
2. `bus-c11h-cut` (bus board). The core with the hand-off into A6, the build host as a copy, client mode for boxes (including replacing one), the cloud copy, and telemetry as event envelopes. Sealing (bus D64) stays only if it adds little; if it threatens the date, plain text ships first. Run and ticket tags stay unsealed (Atin, 18:16). **Proof:** a real three-host sleep test (Bus Lead, 15:29). It ships in three cuts (bus D68, 18:18): **Cut 1, 2026-11-03**, plain text: the laptop and the build host as full copies plus the cloud copy, host keys with a join certificate, and the daemon offering A6's send, receive and hold on `cbus.sock`, targeting A6's T1 to T7 and T8's unsealed checks; **Cut 2, about 11-05**: sealing and T8's sealed mode; **Cut 3, about 11-08**: a Prime box client, a box replacement and a 24-hour soak. The 12 to 18 figure is total agent-days; parallel seats shorten the calendar. A surprise in keys and joining would push Cut 1 to 11-04. Cut 1 carries only test traffic through the Cloudflare copy; c11h's real mail stays on the relay until Cut 2 seals it (bus D70, per the Chief of Staff, 23:01). Atin gave the go for the bus build on the evening of 11-01.
3. `m3-contract`. One frozen page, reviewed twice, time-boxed, with a named decider. It covers how the bus implements A6 (bus SPEC 12.5; "delivery: unknown" is acceptable, since A6 Amendment 1 makes late applies harmless with per-panel sequence numbers, M1 M2 Lead 17:44); joining and revoking hosts, one owner per job (c11h's box join calls `cbus join`; the bus owns certificates and revocation; Overwatch's `seat.sh` calls the same `cbus join`; Bus Lead 16:21); and who owns the bus daemon (c11h on the laptop and the build host, handing over with `cbus upgrade`, never a kill; Bus Lead 16:21).
4. `host-join`. Joining and removing a machine from c11h's machine list. On the relay, a removed box's link and relay access are revoked. With the bus, each host gets a join certificate and revocation refuses it within 10 seconds (bus SPEC 7.1). **Proof:** guest rows for join, remove, and a reconnect after removal.
5. `boxes-many`. C11H-76's one-command join made to work for several boxes, plus replace and remove. **Proof:** two boxes join, one is replaced and one is killed, and the census and the sidebar stay right.
6. `bus-transport` (C11H-72). c11h's Swift adapter calling the bus daemon's A6 operations on `cbus.sock` (bus SPEC 12.5), with the core bundled and signed in c11h.app beside hc and installed on every host. It is written in parallel with Cut 1, so it opens when the bus build starts, ahead of the other tickets. **Proof:** A6's T1 to T7 and T8's unsealed checks against Cut 1 on test traffic, then real mail and T8's sealed mode with Cut 2, and a lid-closed hour. Opened on Atin's go for the bus build (M1 M2 Lead, via the Bus Lead, 23:01).
7. `relay-retire` (C11H-75). After ticket 6.
8. `m3-proof`. A Validator that wrote none of it runs Done 1 to 3 on the real machines, then a night with the lid closed.

**Depends on.**

- Milestone 2's transport interface (A6, #111, merged) and its Amendment 1 (per-panel sequence numbers, written in Milestone 2).
- C11H-76 for tickets 4 and 5, and the open question of how the laptop and build-host reach a Prime box (status 14:04).
- The bus core for tickets 3, 6 and 7, on the Bus Lead's line.
- hc's Linux build for boxes (Milestone 2).

**Unlocks.** Milestone 4's scale: more machines to place agents on, and one transport for their mail.

**Size and staffing.** About 1 to 2 weeks of c11h work, overlapping Milestone 2's last weeks: two owners (hosts and boxes; bus transport with the relay's retirement) and a Validator. Whether they come from Milestone 2's line or are new seats is the Orchestrator's capacity call. Two or three Prime boxes for the proofs, at about a dollar a box-day. Atin: one night with the lid closed. The bus runs on the Bus Lead's own line.

**Risks, each with its cheapest early test.**

| Risk | Cheapest early test |
|---|---|
| Cut 1 slips past 2026-11-03 (keys and joining are the likely surprise, to 11-04). | Milestone 3 doesn't wait: Done 3 lets it close on the relay. C11H-72 written against SPEC 12.5 in parallel catches interface gaps before Cut 1 lands. |
| Milestone 2 and 3 change the same code at once. | Before each Milestone 3 ticket opens, the Orchestrator checks its files against Milestone 2's open PRs, and the Merge Captain orders them. |
| The relay's weak trust lasts longer, maybe into Milestone 4: any process on a machine can claim a c11h panel there (`docs/c11-relay.md`). | Accepted by Atin as temporary (18:16). Milestone 2's one-panel-per-box rule (C11H-76) limits it on boxes, and C11H-45 stays a release gate. |
| A linked machine can read and type into any local terminal that started work on it (hc R4.2), and every added rented box widens that. | A one-hour guest check by the hc Lead that lists what a linked box can reach from the laptop. PLACEMENT already keeps a box from ever being a parent. |
| A box can't hold a link through its egress allowlist. | SP-4a: a real box holds a WebSocket to a Worker for 30 minutes (bus `BUILDPLAN.md`). |
| The bus binary breaks c11h's signing or notarization. | SP-5: the static binary signed beside hc, with its size and start time measured. |

**Needs Atin.** A night with the lid closed; which Prime boxes (open since status 14:04); the continue call.

## Milestone 4: Hundreds

**Goal.** You run hundreds of agents across your machines, and c11h stays fast and steady (vision Law 4). How attention reaches you at that scale is your own primitive, with a Chief of Staff approach, not this milestone's work (Atin, 18:16).

**Done when (proven).**

1. **A working day at scale.** 200 or more live agents on at least five machines: the laptop, the build host, and three or more Prime boxes, or the Linux host (the Linux starmind), once it arrives (PLACEMENT; ordered 2026-11-01, never holds private material). Every budget from ticket 1 holds all day. Typing stays inside a budget per machine: local on the laptop (p99 measured at 0.99 ms, status 14:38), the build host under the 20 ms line on the direct path (plan Settled 17), and each box at its measured baseline. The app's responsiveness and memory, and the time from a flag raised on any machine to the laptop seeing it, stay inside the numbers Atin signed.
2. A holder loss still ends one shard only, at 200 agents.
3. Atin's continue call.

**Tickets, in order.**

1. `scale-budgets`. Take the baseline C11H-81's 30-agent day records (status 16:20: flag to the laptop and flag to Atin's answer at p50 and p95, memory per agent and per hc core, main-thread stalls, relay latency and refusals, use per Claude and Codex account) and Milestone 3's night. Propose budgets for 200 agents. **Proof:** Atin signs the numbers.
2. `load-harness`. Synthetic agents that report, flag and mail at the measured real rates, up to 200 and 500, across Prime boxes, started with one command. **Proof:** two runs give the same numbers.
3. `scale-fixes`. Whatever the harness breaks first, one ticket each: the sidebar row, telemetry coalescing, mail fan-in, the shard count, the SSH links.
4. `m4-proof`. The Validator's 200-agent day, then a day of Atin's real work at that scale.

**Depends on.** Milestone 3: the machines, and the bus if it's in. Milestone 2's shards; raising the pool above 8 is one constant plus a path-length check (`docs/c11-contract-detail.md`, K). The bus's own load spike, SP-9 (200 links, 20 envelopes a second), if the bus carries the mail.

**Unlocks.** A constellation big enough that public users, with smaller fleets, won't hit its limits first.

**Size and staffing.** 2 to 3 weeks, mostly scale fixes. A Lead, a Merge Captain, two or three owners (the harness, performance) and a Validator. Three to five Prime boxes, or the Linux host, during load runs.

**Risks, each with its cheapest early test.**

| Risk | Cheapest early test |
|---|---|
| Main-thread work grows with every agent (sidebar, telemetry), so c11h stalls before hc does. | One afternoon: a synthetic 200-agent telemetry load against a tagged build in a guest. It can run whenever a guest slot is free, even during Milestone 2. |
| Shards pair one to one per machine pair (hc `docs/shards-c11h.md`), so four remote machines means up to 32 SSH links from the laptop, and a reconnect storm when the lid opens. | SH4's pairs against four stand-in hosts in a guest, timing a wake. |
| 25 terminals per shard on one machine strains a holder. | The hc Lead's flood harness at 200 terminals across 8 shards on the build host. |
| 200 live Claude sessions meet the four accounts' limits. Capacity, not spend: accounts run to their actual limit (Atin, 16:00, via the Chief of Staff). | C11H-81 records use per account during the 30-agent day (status 16:20); scale it to 200. |
| The bus slows at 200 agents. | SP-9, already in the bus plan. |

**Needs Atin.** Signing the budgets; a day at scale; the continue call.

## Milestone 5: Public release (sketch)

Lowest priority (Atin, 15:52: "public release to the world, let's keep C11H a separate thing that just I'm using for the time being"). Until this milestone, c11h is Atin's alone. It gets a full plan when Milestone 4 closes. Folding c11h into c11 stays deferred (vision Open 5).

**Goal.** Anyone can download c11h, install it as its own app beside c11, link their own machines, and trust it.

**Done when (sketch).**

1. A stranger installs from a public page on a clean Mac, links one of their own hosts, runs agents, and takes an update in place with every terminal kept. They use no Stage 11 credential or machine: their hosts pin each other's keys, with no Stage 11 cloud copy (bus AC-182 and AC-183, SPEC 7.1).
2. A written trust model, signed by Atin, names every path into the app and its agents and what admits each. C11H-45 is done. hc's six R4 limits are each fixed or stated on a trust page: no per-client authentication, total federation trust, an unchecked remote binary, no audit, terminal contents on disk, and shards that separate failure, not users. An independent review finds no bypass.
3. Updates come through c11h's own signed feed. The build is notarized with the bundled, hardened hc (R2, C11H-66). hc's self-update refusal is more than a mode-0555 guard, or the trust page says it isn't (R1). Rollback across hc pins either passes R3, or the release notes say it ends terminals.
4. c11 and its users are untouched: c11h keeps its own bundle id, socket, state and feed (vision, Separation from c11).
5. Each repo goes public only on Atin's "make it public": c11h (AGPL-3.0), the hc tooling, and the bus core.

**Tickets (rough).** `trust-model`, C11H-45, `trust-review`, `user-constellation` (AC-182 and AC-183), `release-feed` (the appcast, with update keys in the build host's sealed keychain), `public-docs` (install, update, trust and privacy pages, known limits), `stranger-pilot`, `publish` (on Atin's go).

**Size.** 3 to 5 weeks, set by Apple, the review and the pilot.

**Decisions for later, at Milestone 4's end.** Publishing c11h, the hc tooling and the bus core; crash reports and telemetry (off today, with c11's keys stripped); a support owner; whether fixing an R4 limit needs an hc patch (Law 8).

## Decisions

All taken. Nothing open for Atin in this plan.

1. **The bus is optional for Milestone 3** (Atin, 18:16). Milestone 3 closes on the relay if the bus isn't ready, and the relay's weak trust is accepted as temporary.
2. **Milestone 3's c11h work overlaps Milestone 2, starting about 2026-11-03** (Atin, 18:16: "Two B ... Let's say November 3rd"; this reading confirmed 2026-11-02 01:24). C11H-72 opened first, with the bus build; the bus ships Cut 1 on 11-03 (bus D68).
3. **No phone path** (Atin, 18:16: "completely out of scope").
4. **Sealing** (Atin, 17:39 and 18:16): seal mail on the bus if it adds little; plain text is acceptable in the short term. Run and ticket tags are not sealed.
5. **No attention screen in these milestones** (Atin, 18:16). He builds that primitive himself, with a Chief of Staff approach.

Decisions for later, at Milestone 4's end: the items under Milestone 5.

## Proposed tickets

For the Orchestrator when each milestone opens; Milestone 3 opens about 2026-11-03. Existing tickets keep their ids. Bus tickets live on the bus board.

| Milestone | Slug | One line |
|---|---|---|
| 3 | `bus-test` (bus) | SP-1 plus the sleep slice. Passed 17:40. |
| 3 | `bus-c11h-cut` (bus) | Cut 1 (11-03, plain), Cut 2 (~11-05, sealing), Cut 3 (~11-08, a box and its replacement). |
| 3 | `m3-contract` | The bus behind A6, host joining with one owner per job, daemon ownership; frozen. |
| 3 | `host-join` | Join and remove machines; revocation on the relay now, certificates with the bus. |
| 3 | `boxes-many` | Several boxes join, are replaced and removed in one command each. |
| 3 | C11H-72 `bus-transport` | The bus core bundled on every host behind A6. |
| 3 | C11H-75 `relay-retire` | The relay, its shim and docs removed, after the bus carries the mail. |
| 3 | `m3-proof` | Validator on real machines, then a lid-closed night. |
| 4 | `scale-budgets` | Budgets for 200 agents from C11H-81's baseline, signed by Atin. |
| 4 | `load-harness` | Synthetic agents to 200 and 500 across boxes, one command. |
| 4 | `scale-fixes` | One ticket per wall the harness finds. |
| 4 | `m4-proof` | The 200-agent day. |
| 5 | `trust-model`, C11H-45, `trust-review` | The written trust model, the mailbox file trust, the independent review. |
| 5 | `user-constellation` | A user's own hosts pinning each other's keys, no Stage 11 cloud copy (AC-182, AC-183). |
| 5 | `release-feed`, `public-docs`, `stranger-pilot`, `publish` | c11h's own feed, the public pages, a stranger's clean install, the go to publish. |
<!-- c11-2.0:end-keep -->
