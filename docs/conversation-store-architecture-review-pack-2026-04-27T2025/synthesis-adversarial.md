# Adversarial Review Synthesis — Conversation Store Architecture

**Plan:** `/Users/atin/Projects/Stage11/code/c11/docs/conversation-store-architecture.md`
**Reviewers:** Claude (Opus 4.7), Codex, Gemini
**Mode:** Adversarial (designated opposition)
**Synthesis Date:** 2026-04-27

---

## Executive Summary

All three adversarial reviewers converge on a single core verdict: **the plan is directionally correct but oversold, structurally over-engineered for the bugs it actually fixes, and load-bearing on assumptions that have not been proven**. The proposal trades the fragility of metadata hooks for the fragility of filesystem scraping against undocumented, third-party TUI internals — and packages that fragility in language ("structurally impossible," "primitive," "no migration") that the architecture cannot deliver on.

The most consequential consensus: **pull-scrape against TUI session storage is being elevated from fallback hack to load-bearing architectural pillar without proof that per-TUI session identity can be reliably reconstructed in c11's actual operating conditions** — multiple agents in the same cwd, fast-typing operators, crash recovery, and concurrent panes. Codex same-cwd disambiguation, the bug that motivated the rewrite, is *not solved* by this plan; it is *deferred* to a future strategy that the plan has not validated.

The secondary consensus: **the 0.44.0 marquee-feature framing is too aggressive** for an architecture with 12 open questions, no automated reproduction of the original bug, no kill switch, and a snapshot-schema change that ships before the design is settled. Two of three reviewers explicitly recommend deferring to 0.45.0+ behind a flag with a parallel-branch prototype.

The shared uncomfortable truth: **the plan does not actually decouple c11 from the TUIs**. It moves the coupling from environment variables and hooks to internal file formats — surfaces that vendors own, can change without notice, and that c11 does not control. "Decoupled from process lifecycle" is true; "decoupled from the TUI" is rhetoric.

---

## 1. Consensus Risks (multiple reviewers flagged)

Risks that two or more reviewers raised independently. Highest priority — these have the strongest signal.

### 1.1 Pull-scrape is load-bearing on undocumented third-party formats — and the plan treats that boundary as an implementation detail
**Flagged by:** Claude, Codex, Gemini (all three).
The architecture's safety net for hookless TUIs and crash recovery is reading session files c11 does not own (`~/.claude/sessions/`, `~/.codex/sessions/*.jsonl`). Vendors can rename, restructure, or move to SQLite at any time. Claude Code 2.1.119's silent `--settings` semantics change is precedent. Today's wrapper-only pattern is *more* resilient because it does not parse vendor formats; the new architecture privileges scrape over push, so vendor format churn breaks resume even when hooks still work.

### 1.2 Same-cwd, multi-pane Codex disambiguation is not solved — it is deferred
**Flagged by:** Claude, Codex, Gemini.
The bug that motivated the rewrite (two Codex panes, same project, both restoring the wrong session) is the bug the plan is least equipped to solve. cwd + mtime + "last activity timestamp" is a heuristic, not a guarantee. Agent workflows treat same-cwd parallelism as the default case, not a degenerate one. Codex has no hook, so there is no high-confidence signal. The plan ships best-effort attribution under the brand of "structurally impossible."

### 1.3 "Structurally impossible" / "no regression test" is overclaim
**Flagged by:** Claude, Codex.
The plan's line "we do not ship a regression test for the bug observed today; we ship the architecture that makes the bug structurally impossible" is the single most challenged sentence across the reviews. The bug is reproducible with a 4-pane fixture. Architectures that replace tests instead of complementing them ship buggy abstractions confidently. The architecture itself has more moving parts and needs the test *more*, not less.

### 1.4 Reconciliation by "latest capturedAt wins" is too crude
**Flagged by:** Claude, Codex, Gemini.
Different sources have different reliability and different clocks (hook wall-clock, file mtime, monotonic uptime, scrape time). A delayed scrape can clobber a fresh hook; a stale push can override a valid scrape under skew; a wrapper-claim placeholder ID can outlive a real ID. Reconciliation needs source-specific semantics or a confidence-weighted rule, not a single timestamp comparator.

### 1.5 The 0.44.0 release-window commitment is too aggressive for the plan's maturity
**Flagged by:** Claude, Codex.
12 open questions remain (5 load-bearing). The plan ships a snapshot schema change, drops the existing `claude.session_id` reserved key, removes the architecture-level kill switch, and rides on top of 25+ upstream picks already in PR #94. Plans that enter implementation with this much unresolved bleed scope under release pressure; the predictable cut is validation depth, which is exactly where this architecture is weakest.

### 1.6 No architecture-level kill switch / rollback story is brittle
**Flagged by:** Claude, Codex.
"No feature flag for the architecture" is bold but offers no fallback if scraping causes wrong resumes after the snapshot field has shipped. The existing `agentRestartOnRestoreEnabled` flag only disables resume execution; it does not disable capture, scrape, conversation writes, snapshot schema changes, hook routing, wrapper claims, or state transitions. Capture/scrape/execute should likely be independently flagged.

### 1.7 The wrapper-claim placeholder ID is a leaking abstraction
**Flagged by:** Claude, Codex.
The `<surface-uuid>:<launch-ts>` placeholder is encoded as a `ConversationRef.id` while not being a real conversation ID. Every downstream consumer of `ref.id` now needs to know about placeholder-ness despite the schema saying `id` is opaque. Either `id` should be optional while `state == unknown`, or there should be a separate `Claim` type. As designed, a fake ID will eventually leak into a `resume(surface, ref)` call.

### 1.8 The plan does not specify the `isTerminatingApp` query mechanism, and the answer matters
**Flagged by:** Claude, Codex, Gemini.
The SessionEnd-clears-on-quit fix depends on the hook subprocess querying `isTerminatingApp` via the c11 socket during `applicationShouldTerminate`. The reviewers question whether the socket reliably serves requests during shutdown, what happens during terminal-close / pane-close / window-close cascades (which are not app termination), and what happens if SIGTERM hits the TUI before c11 sets the flag. Open question 12 in the plan flags this; none of the reviewers find the answer satisfying.

### 1.9 Crash detection via `~/.c11/runtime/shutdown_clean` is under-specified
**Flagged by:** Claude, Codex, Gemini.
A global one-byte marker has scope problems: tagged builds, dev builds, multiple bundle IDs, multiple running c11 instances, network-mounted runtime dirs. Marker presence is treated as "clean shutdown" and absence as "crash"; the inverse edge cases (marker persists across boots, marker on disconnected drive) are not enumerated.

### 1.10 Polling cadence is unjustified and partly wrong
**Flagged by:** Claude, Codex, Gemini.
The plan references "~30s" autosave-tick scraping, but Codex notes the actual `SessionPersistencePolicy.autosaveInterval` is 8 seconds. With 30 surfaces × 4 strategies, even cheap stat calls accumulate. Gemini and Codex argue the right primitive is filesystem watchers (`FSEvents` / `kqueue`), not polling; piggybacking scrape on autosave conflates two budgets that should be separate.

### 1.11 Privacy and security boundaries are underdeveloped
**Flagged by:** Codex (heavy emphasis), Gemini (sandboxing angle).
Scraping `~/.claude/sessions` and `~/.codex/sessions/` may read transcript content, prompts, file paths, model names, and possibly secrets. There is no "metadata only" contract, no redaction rule, no statement on what gets persisted into c11 snapshots. `ResumeAction.typeCommand(text:)` reintroduces command synthesis with opaque IDs from each strategy — a command-injection trap unless every strategy owns argv-level escaping. Gemini adds: future macOS sandboxing or TUI sandbox profiles may revoke read access entirely, which the plan does not consider.

### 1.12 Resume is treated as automatic; user intent is not modeled
**Flagged by:** Claude, Codex.
The plan assumes operators want auto-resume. Some don't — especially after a crash, after a long idle, or when the previous session was experimental. There is no per-surface "do not resume," no stale-age threshold, no "low-confidence" prompt, no separation between "restore the room" and "wake the agents." The current global flag is too coarse; the new architecture inherits the coarseness.

### 1.13 Observability is too shallow to debug a wrong resume
**Flagged by:** Codex (primary), Claude (echoed).
`conversation list/get` shows current state. They do not answer "why did this pane resume *that* session?" The system needs a bounded, replayable decision log: claim received, scrape candidates considered, candidates rejected with reasons, selected ref, resume action emitted, resume action skipped, tombstone reason. Without it, the first wrong resume in the field is unfalsifiable.

### 1.14 The plan does not honor c11's "the skill is the agent's steering wheel" contract
**Flagged by:** Claude. (Adjacent in Codex's "operator running 8/10/30 agents" critique.)
The plan adds new CLI subcommands (`c11 conversation claim|push|tombstone|list|get|clear`) and a new metadata surface but never updates the c11 skill. Per c11/CLAUDE.md, skill updates are part of "incomplete until done." Without skill updates, agents cannot drive the new primitive — and the primitive's value is largely agent-facing.

---

## 2. Unique Concerns (single-reviewer signal worth investigating)

### From Claude
- **2.1 The strategy interface is polymorphic but the plan ships no plugin system** — worst of both worlds. Either flatten to a fat switch or commit to a real extensibility contract.
- **2.2 The Conversation primitive is described as Swift in-process when the actual capture/resume surface is the CLI.** Pushing more behavior into the CLI/shell layer would let agents iterate strategies without new c11 builds.
- **2.3 Snapshot vs. sidecar storage was never considered.** Folding conversations into the workspace snapshot binds conversation-store evolution to snapshot-format evolution; a sidecar (`~/.c11-snapshots/<ws>/conversations.json`) would let each iterate independently.
- **2.4 The cmux upstream relationship is unaddressed.** Per c11/CLAUDE.md, bidirectional contributions matter. Is this primitive going to cmux too, or is c11 forking further? Not stated.
- **2.5 "No migration" framing is misleading.** The compat-read-once code path is a migration. Calling it not-a-migration hides three follow-up commits (write code, test code, remove code).
- **2.6 `replayPTY` and `composite` ResumeActions have no v1 consumer** — speculative API surface that will rot unused.
- **2.7 An unknown-strategy at restore is a silent failure mode.** A snapshot from a future c11 with a new strategy gets restored on an older c11; surface comes back blank; no UI signal.
- **2.8 Cross-workspace conversation reuse semantics are undefined.** The global derived index enables "bring back any past Claude conversation into a new pane in a fresh workspace" but moving a conversation between surfaces has no defined data-model behavior in v1.
- **2.9 Future c11 maintainers face higher per-new-TUI cost, not lower.** A fifth TUI integration now requires understanding pull-scrape, wrapper-claim, placeholder format, reconciliation rules, and absent-on-restore semantics — versus today's "edit one closure in `AgentRestartRegistry.phase1`."
- **2.10 The plan is plausibly a rationalisation of a hot-fix that didn't work cleanly** — engineer's frustration with a fragile patch finding architectural justification for a do-over.

### From Codex
- **2.11 The state machine is too small.** Five states is insufficient for the lifecycle modeled. Missing at least: `claimed`, `resumable`, `ambiguous`, `failed`, `disabled`. `unknown` is overloaded across crash recovery, wrapper claim, unregistered strategy, and stale snapshot — each of which needs different UI and resume behavior.
- **2.12 Confidence is missing from the schema.** `capturedVia` and `state` do not capture how reliable a ref is. Hook-captured Claude IDs are high-confidence; Codex scrape with two candidates is low-confidence; wrapper claims are near-zero. Resume should treat them differently; the schema does not allow that.
- **2.13 Conflict handling is undefined.** Two surfaces claim the same ref, one session file matches a deleted surface and a live surface, the global index sees the same ref in multiple snapshots. Uniqueness constraints are not stated.
- **2.14 Deletion / tombstone pruning semantics are vague.** When are tombstones pruned? Do they live forever? How does `conversation clear` interact with old snapshots that still hold the ref?
- **2.15 `ResumeAction.launchProcess(argv:env:)` may be unimplementable against today's `TerminalPanel`.** Replacing a running shell with a new process has cwd/env/shell-integration/PTY/UI implications the plan does not address.
- **2.16 Conversation-store mutation's relationship to the existing autosave fingerprint is unspecified.** Does it participate? If yes, autosave churn rises. If no, conversation-only changes are not promptly persisted.
- **2.17 Strategies are claimed "pure" but read filesystem state.** "Pure" only seems to mean "no internal mutable state." Say that, or drop the claim — it obscures concurrency and test requirements.
- **2.18 Lifecycle other than app shutdown is unmapped.** Pane close, surface close, workspace close, shell exit — tombstone, suspension, clear, or history? The plan only handles app termination.
- **2.19 c11 already has many lifecycle layers (autosave quiet periods, restore suppression, synchronous termination saves, stable ID rollback, metadata precedence).** The plan adds another persistence layer without showing how its writes participate in those existing layers.
- **2.20 Field stability inside session files is unknown.** Even if the file location holds, which fields are stable enough to rely on without parsing transcript content?
- **2.21 If implementation discovers Codex attribution cannot be made reliable, does the architecture still ship?** This is a release-decision criterion the plan does not answer.

### From Gemini
- **2.22 Multi-instance c11 behavior is undefined.** Two c11 instances running simultaneously, both managing `~/.c11-snapshots/` or `~/.c11/conversations.index.json` — no mutual exclusion designed in.
- **2.23 Tombstone-on-transient-read-error is irrevocable.** Codex strategy treats absent-on-restore as tombstone. A momentarily unreadable disk, dropped network mount, or permissions hiccup permanently tombstones live conversations.
- **2.24 Sandboxing/permissions are a future risk.** macOS or TUI vendor sandbox tightening could revoke read access to `~/.claude/sessions/` entirely.
- **2.25 The "focused-surface silent misroute footgun removal" decision may have external script dependencies** that c11 cannot see.
- **2.26 Filesystem watchers (`FSEvents`/`kqueue`) are strictly better than polling** for the lightweight-monitoring goal — and were not considered.

---

## 3. Assumption Audit (merged & deduplicated)

Every load-bearing or risky assumption surfaced across the three reviews, deduplicated and re-numbered. Severity reflects the *combined* signal (multi-reviewer = higher).

### Load-bearing — the plan collapses if these break

1. **TUI on-disk session formats and storage paths are stable across vendor releases.** *(All three reviewers.)* Likelihood: low to medium. Pre-cedent for change exists.
2. **Pull-scrape can be the primary source of truth on death and crash recovery.** *(All three.)* Holds for Claude/Codex today; does not hold for opencode/kimi (admitted).
3. **TUIs flush their session file before c11 quits / TUI process dies.** *(Claude, Codex.)* For codex's append-only JSONL, tail is probably consistent; for Claude, this is an Anthropic implementation detail.
4. **cwd is an acceptable discriminator for mapping TUI sessions to c11 surfaces.** *(All three.)* Multi-pane same-cwd is the *common* case in agent workflows, not the edge.
5. **File modification time corresponds to "the conversation this surface is hosting."** *(Codex, Gemini.)* May fail under index rewrites, batch touches, write buffering, cloud sync, history compaction, global-metadata updates.
6. **Hook clock, mtime clock, monotonic uptime, and scrape time can be reconciled by a single `capturedAt` comparison.** *(Claude, Codex.)* They are not the same clock; granularity differs.
7. **`isTerminatingApp` is queryable via the c11 socket during `applicationShouldTerminate`.** *(All three.)* Open question 12; not verified.
8. **A surface hosts at most one *active* Conversation at a time.** *(Claude.)* True for current TUIs; will not hold for orchestrators, multi-tab Claude sessions, or `claude → /exit → claude` flows.
9. **The wrapper-claim placeholder ID format is recognisable as a placeholder by every strategy.** *(Claude, Codex.)* Not enforced by the schema; depends on convention.
10. **Strategies are "pure given inputs."** *(Claude, Codex.)* They read filesystem state, check app termination, interpret external session stores — impure by any meaningful definition.
11. **No migration is acceptable because the software is pre-release.** *(Claude, Codex.)* PR #89 has shipped opt-in in 0.43.0 and default-on in 0.44.0-pre; operators have snapshots with `claude.session_id` already.
12. **The 2.5s `agentRestartDelay` is universal across surface types and hardware.** *(Claude.)* Cold boots, slow disks, FileVault decrypt cycles, network home directories all violate this.
13. **The `ResumeAction` enum covers all current and near-future cases.** *(Claude, Codex.)* `replayPTY` has no v1 consumer; `launchProcess` may be unimplementable; `composite` is YAGNI.
14. **`~/.c11/runtime/shutdown_clean` is correctly scoped for tagged builds, dev builds, multiple bundle IDs, and multiple instances.** *(Codex.)*
15. **Filesystem scraping at autosave cadence is performant enough.** *(All three.)* Plan says "~30s" but actual autosave is 8s; 30 surfaces × 4 strategies multiplies the cost.
16. **`shutdown_clean` marker presence reliably indicates clean shutdown; absence reliably indicates crash.** *(Claude, Gemini.)* Edge cases (network drive, persisted-from-prior-boot) are not considered.

### Cosmetic — worth flagging, won't sink the plan alone

17. Snapshot file format can grow a `surface_conversations` field without breaking older readers.
18. The blueprint schema does not need to change.
19. The `ConversationStrategyRegistry` being hardcoded is fine.
20. `claude-hook` CLI can be a "thin translator" without losing telemetry breadcrumbs.
21. Agents writing `c11 conversation push` will not race the snapshot write during shutdown.

### Invisible — the dangerous ones

22. **The operator wants resume at all** — this is a stronger opinion than the plan acknowledges.
23. **Resume should be automatic** — auto-typing `claude --resume <id>` hides a choice the operator might want to make.
24. **One conversation per kind per surface is the right model** — `session = conversation` is an approximation, not an exact mapping.
25. **Snapshots are the source of truth** — plus a derived global index that scans all snapshots at launch. Resolution rule when snapshots disagree: undefined.
26. **The `claude-hook` path can become `c11 conversation push|claim|tombstone` without losing existing telemetry breadcrumbs.**
27. **Operators want / will benefit from the v1.x and v2 features** (history UI, cloud, cross-machine, blueprints with pinned conversations) that justify the primitive's weight.
28. **TUIs that today have no resume mechanism (opencode, kimi) will gain one in a way that fits the plan's strategy interface.**

---

## 4. The Uncomfortable Truths (recurring hard messages)

The shared, repeated criticisms across the three reviewers, stated bluntly.

1. **The architecture does not actually decouple c11 from the TUIs.** It moves the coupling from environment variables to internal file formats. Coupling persists; only its surface changed.
2. **Pull-scrape is "best-effort" packaged as architecture.** Codex, opencode, and kimi remain best-effort. Calling them "strategies" does not raise their reliability.
3. **The Codex same-cwd bug — the bug that motivated this — is not fixed by this plan.** It is assigned to a future strategy whose viability has not been demonstrated.
4. **"Structurally impossible" is oversold.** Wrong attribution remains possible whenever session identity is non-deterministic. The architecture removes one race and adds several smaller ones.
5. **Cleanliness is not the scarce resource here. Ground truth is.** The plan spends words on the abstraction and too few on whether the abstraction can be populated correctly.
6. **The plan is more interesting to write than it is necessary to ship.** The actual user-visible v1 delta over the hot-fix is two narrow improvements with 20-50 line patches available.
7. **The plan is plausibly a rationalisation of a hot-fix that frustrated its author.** Sometimes that is the right call; sometimes it is "I want to do the bigger thing." Worth asking which.
8. **The release ambition is too high for the plan's maturity.** 12 open questions (5 load-bearing) plus a snapshot-schema change plus 25+ upstream picks plus no kill switch is a recipe for late-cycle regressions.
9. **The plan does not yet meet c11's "operator running 8/10/30 agents" bar.** It describes single-active-conversation-per-surface; it does not prove correctness in a crowded room.
10. **Two years from now, the regret will be: built a generic conversation abstraction before having strong per-TUI identity proofs.** The right sequence may have been: instrument wrappers, build a Codex attribution probe, prove same-cwd disambiguation, *then* generalize.
11. **In two years, hardcoded paths like `~/.codex/sessions/*.jsonl` in Swift source will be the regret.** Vendor-format coupling at the language level ages worst.
12. **The first wrong resume in production will be undebuggable** without an event-level decision log the plan does not specify.

---

## 5. Consolidated Hard Questions (deduplicated, numbered)

Merged across all three reviews; near-duplicates collapsed; load-bearing open questions promoted. "We don't know" is flagged where reviewers explicitly noted it.

### Bug-fix ground truth

1. In the two-Codex-panes-same-cwd failure that motivated this plan, **what concrete data inside the session files lets a strategy distinguish pane A's session from pane B's session?** If cwd + mtime + last-activity is not provably sufficient, what is?
2. **What automated test reproduces the original 4-pane staging-QA failure** and proves this architecture fixes it — without depending on a live Codex binary?
3. **Why is no regression test being shipped for the bug observed today?** "The architecture makes it impossible" does not age well; what specifically prevents future regressions in the registry from reintroducing last-wins-in-cwd for a kind we have not added yet?

### Per-TUI identity & format coupling

4. **What exact fields exist in Claude and Codex session files today, and which are stable enough to rely on without reading transcript content?**
5. **How do we detect and gracefully handle upstream TUI changes that break our hardcoded scraping logic?** ("We don't know" — Gemini.)
6. **What is the version-compatibility matrix** for Claude Code and Codex, and what happens when users upgrade either TUI independently of c11?
7. **Are opencode and kimi in scope for a real improvement, or are they included to justify the abstraction?** If they remain fresh-launch-only, say so plainly.
8. **If implementation discovers Codex session attribution cannot be made reliable, does the architecture still ship?** What does the release note claim?

### Reconciliation, confidence, and conflict

9. **Why is "latest `capturedAt` wins" the right reconciliation rule** when sources have different reliability and clocks?
10. **What is the false-positive policy?** Two plausible candidates → resume one, skip both, or ask the operator?
11. **What confidence level is required before auto-resume executes a command in a terminal?**
12. **What happens if two surfaces resolve to the same conversation ID?** Which wins; how does the operator see the conflict?
13. **What happens if a ref is in an old snapshot, the user clears it in the current workspace, and the derived index rebuilds from both?**
14. **How is per-surface "last activity timestamp" defined, captured, persisted, and tested?** Does terminal output count? User typing? Background process output?

### State machine, IDs, and schema

15. **Why is `id` non-optional if a wrapper claim creates a ref before a real ID exists?** Should the schema use `Claim` separate from `ConversationRef`, or make `id` optional while `state == unknown`?
16. **How do we prevent a fake wrapper-claim ID from ever being passed to `resume(surface, ref)`?**
17. **Is the state machine sufficient?** Should `claimed`, `resumable`, `ambiguous`, `failed`, `disabled` be added? `unknown` is currently overloaded across at least four meanings.
18. **What is the shell-injection defense** for non-Claude IDs used in `typeCommand` resume actions? Per-strategy escaping or argv-based launch?
19. **What does the user see when a strategy is missing, ambiguous, disabled, or low-confidence?** Silent skip means silent data loss.

### Lifecycle, scheduling, and performance

20. **Why polling at 30s** (and why does the plan say 30s when actual autosave is 8s)? Why not `FSEvents` / `kqueue`?
21. **How many filesystem operations does one autosave-tick scrape do** with 30 surfaces and four strategies?
22. **Does conversation-store mutation participate in the existing autosave fingerprint?** If yes, autosave churn rises; if no, conversation changes are not promptly persisted.
23. **During `applicationShouldTerminate`, do we block on in-flight scrapes, cancel them, or snapshot the prior store state?**
24. **Does `c11 conversation tombstone` query `isTerminatingApp` without adding a socket method that races termination?** ("We don't know" — Claude.)
25. **What is the explicit fallback if `isTerminatingApp` evaluates to false during a window-close cascade or abrupt system shutdown?**
26. **What is the behavior for pane close, surface close, workspace close, and shell exit** — tombstones, suspensions, clears, or history?
27. **What is the per-strategy I/O cost on slow disks, network mounts, and battery-constrained states?**

### Crash recovery & shutdown

28. **Is `~/.c11/runtime/shutdown_clean` scoped correctly** for tagged builds, dev builds, multiple bundle IDs, multiple running c11 instances?
29. **If `~/.claude` becomes unreadable due to permissions or a transient error, does the architecture suspend the state or erroneously tombstone it?**
30. **What is the test story for crash recovery?** "Simulate missing shutdown_clean flag" tests the marker; what tests real-crash + real-on-disk-state + real reconciliation?

### Privacy, security, and sandboxing

31. **What privacy guarantee can we make about scraping TUI session directories?** What is read, what is persisted in c11 snapshots, what is logged?
32. **What is the metadata-only contract** with size limits and redaction rules?
33. **What happens when macOS or vendor sandboxing revokes read access to `~/.claude/sessions/`?**

### Observability & rollback

34. **What exact event log will let us debug "why did this pane resume this session?"** after the fact?
35. **What is the rollback plan if scraping causes wrong resumes after the snapshot field has shipped?**
36. **Should capture, scrape, tombstone, and resume execution have separate feature flags** rather than one global resume flag?
37. **Why no architecture-level kill switch** (`CMUX_DISABLE_CONVERSATION_STORE=1`)?

### Release strategy & migration

38. **Why is this the 0.44.0 marquee feature instead of 0.45.0 / 0.46.0?** What forces the architecture into 0.44.0's window?
39. **What is the migration story for operators with 0.44.0-pre snapshots containing `claude.session_id` reserved metadata?** "Read once for backward-compat at v1.0" — *which* release is "v1.0"? When is the compat code removed?
40. **What happens to PR #89 in code?** When is `SurfaceMetadataKeyName.claudeSessionId` removed? When is `AgentRestartRegistry` deleted?

### Scope, evidence, and ecosystem

41. **What is the actual rate of new TUI integrations expected over the next 12 months?** Architecture cost-benefit hinges on this. ("We don't know" — Claude.)
42. **What concrete evidence supports "we'd re-confront the structural problems with the next TUI integration"?** Has anyone tried adding a new TUI to the current pattern and found it painful?
43. **What metric will tell us the architecture is paying off?** Number of TUIs successfully integrated? Reduction in resume-failure reports? Define before implementation; otherwise we won't know if it worked.
44. **Does the operator actually want this primitive** — including the v1.x/v2 features it enables — or are we building scaffolding for a future the operator hasn't asked for yet?
45. **Does cmux upstream want this primitive?** If yes, what's the path? If no, why not — and what does this mean for future merge conflicts on shared code?
46. **What does the c11 skill need to learn** for agents to drive the new CLI surface? Per c11/CLAUDE.md, skill updates are part of "incomplete until done."

### Architectural shape

47. **Why is the global derived index in v1 at all** if no v1 UI consumes it and snapshots are the source of truth?
48. **Why is `Conversation` a Swift in-process primitive when the capture/resume surface is the CLI?** Pushing more behavior into CLI/shell layer would let agents iterate strategies without new c11 builds.
49. **Why fold conversations into the workspace snapshot rather than a sidecar file?** Sidecar lets each format iterate independently.
50. **`ResumeAction.replayPTY` has no v1 consumer and `launchProcess` may be unimplementable against today's `TerminalPanel`** — should v1 ship with these in the enum?

---

## 6. Recommendation Synthesis

All three reviewers, while writing in adversarial mode, converge on a remarkably consistent recommended posture. The cleanest articulation:

1. **Ship 0.44.0 on the current hot-fix.** Land the SessionEnd-on-quit fix (~20 lines: check `isTerminatingApp` in `c11 claude-hook session-end`). Land per-pane Codex session capture in the wrapper (~50 lines watching `~/.codex/sessions/` for new files matching cwd+launch-window, calling `c11 set-metadata`). Both are reversible, narrow, and validate as the operator already expects.
2. **Open a 0.45.0+ design exploration for the conversation primitive.** Prove same-cwd Codex disambiguation with a throwaway probe before committing to the abstraction. Build the prototype on a parallel branch behind a flag.
3. **Promote the primitive to default in 0.46.0/0.47.0** with real test coverage, real bake time, and the option to compare against the hot-fix in production.
4. **Before any implementation begins, answer at minimum questions 1, 2, 4, 5, 9, 17, 24, 28, 38** from §5. Several are explicit "we don't know" today.
5. **Add an architecture-level kill switch** even if the plan author considers it ugly. The cost of double-maintaining for one release window is the cost of caution on a new primitive.
6. **Add a decision-event log specification** to the plan before implementation, not after the first wrong resume.
7. **Update the c11 skill in lockstep** with any CLI surface changes — non-negotiable per project standards.

---

**End of synthesis.** This is a read-only review document; no other files were modified.
