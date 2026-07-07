# c11 — Consultant Review (July 2026)

*Synthesis of a four-lane deep review: vision/positioning docs, architecture and feature inventory, momentum and health, and the agent-facing surface. Data as of v0.56.1 (2026-07-01).*

---

## 1. Headline assessment

c11 is a real product with a differentiated thesis, roughly 12 to 18 months ahead of "tmux plus scripts" on the agent-native layer, executed by effectively one human plus an agent fleet at unusual process maturity. The engineering is ahead of the distribution by a wide margin: 155k LOC of Swift, 188 socket methods, an inter-agent mailbox with a formal schema, cross-vendor session resume for 8 agent CLIs, and a working Go remote daemon, against 35 GitHub stars and a launch plan that has sat unexecuted and uncommitted since May 23.

The moat is the agent layer (skills-as-contract, mailbox, metadata precedence, conversation store, registry). That layer is exactly where the maturity gaps are: no event/subscribe primitive, self-reported telemetry with no liveness decay ("the sidebar lies" is the in-house doctrine), crash-resume incomplete, no remote story shipped, no inter-agent trust model.

Three strategic decisions gate everything else, and all three are currently being made passively:

1. **Product or substrate?** Is c11 a public product with growth ambitions, or Stage 11's internal working environment that happens to be open source?
2. **Fork posture.** Upstream cmux is 900+ PRs ahead, converging on c11's differentiators, and the triage machinery has been dormant since May 1. Recommit, declare a hard fork, or fold into D11.
3. **Launch timing.** The launch-grade competitive scan exists; the window it describes is closing.

---

## 2. Where the project actually stands

### Reality exceeds narrative

- **Scale:** ~155k LOC Swift app + 17.5k LOC CLI + 11k LOC vendored bonsplit + Go remote daemon (3.5k LOC with tests). 2,339 XCTest functions, 250+ Python socket test files.
- **Socket surface:** 188 distinct v2 methods; browser.* alone is 73 verbs (a Playwright-lite embedded in the multiplexer). The public API doc covers ~30 of them and still says "cmux."
- **Shipping cadence:** ~20 releases in 10 weeks. June themes: exact-session resume across 8 TUIs, mailbox hardening, fleet legibility (`tree --report`), multi-instance stability.
- **Underexposed capabilities:** the browser automation stack, workspace blueprints (declarative layout apply), `c11 health` crash-log/MetricKit diagnostics, AppleScript support, Drawbridge (a live autonomous OSS-triage pipeline), and a remote daemon that already does durable PTYs + browser egress + CLI relay over SSH.

### The public planning surface is empty

- `TODO.md` and `C11_TODO.md`: 0 bytes (deliberately emptied 2026-04-28).
- `ROADMAP.md`: does not exist, though PHILOSOPHY.md points at it.
- `PROJECTS.md`: frozen at the cmux era (2026-02-14).
- Real planning lives in `.lattice/` (partly untracked). An outside contributor cannot tell what c11 intends to build next, while the README says "come build with us."

### Traction snapshot

35 stars, 7 forks (repo created 2026-04-16). Upstream cmux: 17.7k stars. One anomaly: v0.53.0 (Jun 16) shows ~3,300 downloads against a 15 to 150 baseline; likely auto-update traffic, worth confirming before reading it as demand.

---

## 3. The moat and its exposed flanks

### Genuinely differentiated

1. **The skill as shipped product surface.** "Every CLI change is incomplete until the skill matches" is a real engineering-culture invariant nobody else has. The skill corpus encodes hard-won gotchas (banner-scrape ban, prompt-gated delivery, polling deadlocks) that no competitor documents for agents.
2. **The mailbox.** A durable, schema'd (`spec/mailbox-envelope.v1.schema.json`), audit-logged, filesystem-is-the-contract inter-agent message bus with byte-parity CI between CLI and raw writes, and forge-proof prompt-gated PTY injection. No peer tool has an inter-agent messaging primitive at all.
3. **Cross-vendor neutrality.** 8 first-class agents (Claude, Codex, Copilot, Grok, Kimi, Pi, omp, opencode) with declared resume tiers and a researched 14-agent integration matrix, against single-vendor lock-in everywhere else.
4. **The trust posture.** Never writes tenant config; PATH wrappers are the ceiling. A real differentiator against agent IDEs that own your dotfiles.
5. **Addressable-everything + no-focus-steal socket contract**, designed for agents rather than retrofitted.

### Exposed flanks (ranked)

1. **No push/subscribe anywhere.** Metadata is pull-only, mailbox `watch` is unimplemented, topics unshipped. Every coordination loop in the product's own orchestration patterns is polling or turn-boundary draining. For a many-agent-orchestration product this is the largest architectural hole, and it caps every meta-orchestration pattern (Overwatch polls scrollback).
2. **Telemetry trust deficit.** Status/progress are agent-self-reported with no TTL, no staleness decay, no last-updated surfaced. The in-house review skills' doctrine is literally "The sidebar lies. The terminal usually doesn't." The pitch IS the sidebar.
3. **Crash-resume incomplete.** The conversation store v1 is architecturally complete but the scrape rail is dead code in the live path and crash recovery is documented as failing (panes restore, conversations don't). "Everything comes back" is the emotional tmux-parity promise and it is 80% built.
4. **No remote story shipped.** Fleets are one-Mac-only; the market is moving to cloud/remote agents. c11d cloud host is design-only (though the SSH daemon is more real than its marketing).
5. **No inter-agent permission model.** Any agent can type into any peer's PTY, rewrite peer metadata, or drain a peer's inbox. Acceptable for one local operator; blocks any multi-host or multi-tenant future.

---

## 4. Health and debt

- **Six god files ≈ 89k LOC ≈ 57% of app source** (TerminalController 20.4k, CLI 17.5k, ContentView 14.5k, AppDelegate 14.2k, Workspace 12.2k, BrowserPanel 10.3k). They are also the top-churned files; every fix lands in a monolith.
- **The June 9 audit predicted the incidents.** The socket/main-thread genre it flagged as P0 produced two production incidents Jun 29 to 30 (bind-stomp C11-155, hook-flood hang C11-156). Diagnosis-to-fix was 24 to 48h with written root causes (excellent), but the five audit remediation meta-tickets remain untouched in backlog.
- **Rename residue is an active bug source** (c11mux config-path casualty in 0.56; stale cmux-branded API doc; 35 tests_v2 files that can only find a binary named `cmux`).
- **Distribution ops fragility:** two of the last three releases were signing-continuity repairs; pre-0.38 users are permanently stranded on auto-update.
- **Repo hygiene:** `node_modules/` is tracked (about two thirds of all tracked files); `web/` remains half-rebranded with manaflow PostHog/legal pointers (audit P0); 7 dependabot PRs sitting; ~40 stale local branches.

The pattern: knowledge of debt is excellent, throughput on it is near zero. Attention went to the agent-primitive stack and firefighting.

---

## 5. Tensions to resolve

### Philosophy vs. shipped reality

PHILOSOPHY.md: "c11 features must not require agent-side cooperation... The moment an agent has to be modified to work well in c11, c11 has already lost." Yet every headline differentiator (sidebar identity, mailbox, skills, resume wrappers) depends on agent cooperation. The exceptions clause is carrying the whole doctrine.

**Recommendation: rewrite the doctrine as two honest layers rather than a rule plus exceptions.** Floor: external observation, works for any pane, no cooperation required (and should power liveness/staleness detection). Amplifier: open contracts (skills, wrappers, mailbox) that any agent may adopt for a richer experience, never captive config. That is what c11 actually practices, and it is defensible as stated.

### Fork posture is drifting, not decided

Upstream ships weekly, has merged 900+ PRs since the fork base, and landed markdown preview panels in May (eroding a claimed differentiator). The triage machinery (skill, runbook, divergence map) has exactly one log entry, dated 2026-05-01. The most expensive option is the current one: implicit divergence while maintaining the pretense and tooling of bidirectionality. Either fund a triage cadence (even one PR-sweep per fortnight), or declare the hard fork and archive the machinery.

*Operator call (2026-07-06): divergence is deliberate, not neglect. No felt need to pull upstream now; revisit later. Remaining cleanup: the docs and tooling should stop implying an active bidirectional cadence.*

### Launch readiness without launch

The May 23 competitive scan is genuinely good: five claimed exclusives, honest deficits, rehearsed objections, a recommended Show HN title ("Terminal where 10+ AI agents drive their own panes via a skill file"). None of it has shipped: not committed, README unpatched, no launch post, showcase ticket in backlog. Six weeks of decay so far. The README also violates the project's own voice rule (external surfaces use the external register); the current register invites the "obviously made by Claude" critique the scan itself catalogs.

---

## 6. Recommended direction (sequenced)

**Now (1 to 2 weeks): make the sidebar tell the truth, and stop the bleeding.**
1. Liveness/staleness on telemetry: last-updated timestamps, TTL decay on status pills, and externally-derived waiting/working state (aligns with the observe-from-outside floor). Kills the "sidebar lies" problem at the root.
2. One debt sprint scoped to the audit's P0 list: empty-ref write misrouting, the remaining main-thread-reachable socket paths, untrack node_modules, web rebrand. Extract the socket dispatcher from TerminalController as the first god-file cut.
3. Finish crash-resume (wire the scrape rail, ship `state save/verify`). It is the emotional core of the tmux inheritance.

**Next (2 to 6 weeks): the event stream, then launch.**
4. `c11 events tail`: an NDJSON subscribe primitive over the socket (metadata changes, status transitions, mailbox arrivals, waiting-agent transitions). Single biggest architectural unlock; supercharges Overwatch-style meta-orchestration and makes the "open metadata comm layer" pitch true in the reactive sense.
5. Execute the launch: commit the scan, write ROADMAP.md, do the README external-register pass with the "isn't this just cmux" paragraph, record the showcase videos, ship the Show HN. The product is ahead of its distribution; this is the highest-leverage cheap work in the repo.

**Then (quarter scale): remote as the second act.**
6. c11d persistent host, built on the already-real SSH daemon. Narrate it earlier than you build it ("your fleet, one room, any host") because one-Mac-only is a shrinking frame, but do not let it queue-jump stability and launch.
7. Inter-agent trust model and mailbox Stage 3 (topics, watch, caps) ride along with remote, since that is when they become load-bearing.

---

## 7. The narratives

Primary, in order of sharpness:

1. **"Agents drive their own panes."** The skill-file hook. Concrete, demoable, nobody else can say it. The scan's recommended Show HN title is right.
2. **"The room where the fleet stays legible."** The operator-cognition pitch: 10 to 30 agents, one field of view, cmd-tab roulette retired. This is the durable human story even as agent tech churns.
3. **"Neutral ground."** Every vendor's agent is first-class; c11 never touches your config. Grows in value as vendor competition intensifies and single-vendor harnesses proliferate.
4. **"The only terminal with an inter-agent mailbox."** The technical exclusivity claim, verifiable, schema'd.
5. **(Once resume lands) "Close the lid. Everything comes back."** The tmux emotional inheritance, upgraded to conversations.

---

## 8. Open questions for the operator

*Updated 2026-07-06 with operator answers.*

1. **Product or substrate?** ANSWERED: public product, launched, live on GitHub, with meaningful use. Star-count and distribution therefore matter; the growth posture (active push vs organic) is the follow-on question.
2. **Fork posture:** ANSWERED for now: divergence is deliberate; no felt need to pull from upstream at present, revisit in the future. Cleanup implication: retire or clearly park the triage machinery and stale bidirectional language.
3. **Sequencing appetite:** OPEN: how much time goes to the truth-and-stability work (telemetry liveness, P0 debt, crash-resume) versus feature and distribution pushes?
