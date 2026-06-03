## Evolutionary Synthesis — C11-24 (`c11 health`)

- **Date:** 2026-05-03
- **Branch:** c11-24/health-cli
- **HEAD:** cdc51c278ddf7bd31ac0c0c540b614d4ee5c1e92
- **Sources:** evolutionary-claude.md (Opus 4.7), evolutionary-codex.md (GPT-5), evolutionary-gemini.md (Gemini 1.5 Pro)
- **Scope:** Read-only synthesis of three evolutionary reviews. No code/Lattice changes.

---

## Executive Summary — Biggest Opportunities

All three reviews independently arrive at the same thesis with different vocabulary:

- **Claude (Opus):** "Disk-Coupled Telemetry Aggregation" — producers write artifacts to well-known paths, decoupled readers walk them later.
- **Codex (GPT-5):** "Local evidence plane" / "passive flight recorder" — local incident reconstruction without trusting any one producer.
- **Gemini:** "Immune System API / Observability Seam" — agent-readable timeline turning opaque host failures into queryable context.

The shared insight: **the four-rail unifier is not the feature, it is the platform.** What ships as a CLI is actually the engine for fleet aggregation, agent self-triage, live tailing, narrative reporting, and (eventually) D11's evidence substrate.

The three biggest opportunities, in priority order:

1. **Formalize the rail abstraction (registry/table) before the fifth rail arrives.** Unanimous across all three reviews. Highest-leverage, mechanical refactor, ~80 lines, no behavior change. Drops the per-rail addition cost from ~8 edits across 5 files to ~1 struct + 1 append.
2. **Promote the renderer boundary from `[HealthEvent]` to a `HealthReport` value object.** Codex names it explicitly; Claude names the same need via the "schema_version + bundleID/build fields" cluster; Gemini implies it through the "JSON-as-API" framing. Fixes the empty-state-text drift bug *and* gives every future surface (table, JSON, brief, watch, narrative) one input shape.
3. **Surface the latent fleet/agent dimensions already in the architecture.** `home: String` is already a parameter. Three reviews independently flag `--home <path>` as a flag-away win that turns the engine into a fleet inspector with zero architectural change. Gemini extends to `--remote <ssh-target>`. Combined with a new "agent rail" (Gemini), `c11 health` becomes the operator-and-tenant timeline rather than just the host timeline.

The unanimous warning: **`HealthEvent.Severity` is a junk drawer that will not survive the fifth rail.** Address it (per-rail severity, or tags) before the schema locks in via downstream JSON consumers.

---

## 1. Consensus Direction — Evolution Paths Multiple Models Identified

Patterns where two or three reviews independently converged:

1. **Rail registry / data-driven scanner table** (Claude #1, Codex #2, Gemini implicitly via "5th rail"). All three see the four scanners as already-uniform pure functions waiting for a registry. Claude proposes a `HealthRail` protocol; Codex argues for a plain function table over a protocol hierarchy ("keep the ergonomic advantage of plain functions"). Gemini doesn't propose the structure but treats "the next rail" as the natural extension. **Synthesis:** start with Codex's lighter table-of-functions; promote to a protocol only if/when warning helpers need polymorphism (Claude's `HealthRailWithWarning` extension). The protocol-vs-table debate is real; the table is the cheaper opening move.

2. **`HealthReport` / report-shaped output boundary** (Codex #1, Claude #4 + leverage point #6 implicitly, Gemini via the "JSON as API" framing). Codex names the value object directly; Claude reaches the same idea through `schema_version`, `bundleID`/`build` fields, and the `HealthArtifact` vs `HealthEvent` split; Gemini emphasizes that the `--json` flag has *already* turned the command into an API, so the schema needs to be a deliberate object. **Synthesis:** introduce `HealthReport { window, rails, events, warnings, schema_version }` as the unified renderer input. This single move unblocks four downstream items (empty-state fix, schema versioning, `--brief`, evidence confidence).

3. **`schema_version` / explicit JSON contract** (Claude #1 + #4, Codex via `HealthReport` framing, Gemini via "JSON as API"). All three agree the JSON shape is now load-bearing because agents and CI gates will lock onto it. Add the version key now while it is one line.

4. **Fleet seam via `home`** (Claude #5 + leverage point #3, Codex via `HealthScanContext`, Gemini explicitly as `--remote <ssh-target>`). The plumbing exists; only the flag is missing. All three see this as the cleanest signal that the abstraction is right — the same engine works for "this machine", "rsynced snapshot", and (Gemini) "remote SSH target".

5. **Producer/reader contract formalization** (Claude #4 — paired `FilenameSafeISO8601` primitive; Codex #3 — `HealthEvidenceContract` consumer-side table; Gemini implicit in the universal-timeline pattern). The two reviews approach the same risk from opposite ends: Claude binds producer and reader at the type level; Codex documents the contract on the reader side without touching producers. **Synthesis:** Codex's approach is non-invasive (does not modify `SentryHelper.swift` or `LaunchSentinel`) and is the right v1.1 move; Claude's typed primitive is the right v1.2+ move once a producer change is otherwise needed.

6. **Test scaffolding consolidation** (Codex #5 explicitly, Claude implicitly via "fuzz test on the ISO primitive", Gemini implicitly via "fixture per rail"). All three see `scaffoldAllRails` and the duplicated temp-home setup as the seed of a synthetic-evidence builder. Cheap, prevents fifth-rail test sprawl.

7. **The "next rails" list converges on roughly the same candidates.** Claude lists Console.app log show, spindump IPS, workspace-snapshot lifecycle, Sentry envelope age. Gemini lists "agent rail" (drop-zone for agent-emitted JSONs). Codex stays abstract but defends the shape. **Synthesis:** the agent rail is the highest-value next rail because it closes the operator-vs-tenant gap that none of the current four rails fills, and it is the rail the c11 SKILL can teach agents to populate themselves.

---

## 2. Best Concrete Suggestions — Most Actionable Across All Three

Ranked by leverage-per-effort, with cross-references to which reviews support each:

1. **Add `schema_version: 1` to `renderHealthJSON`.** (Claude #1, implied by Codex/Gemini.) One line. Locks the JSON contract before downstream consumers exist. Existing `testJSONShapeContainsTopLevelKeys` won't regress. Path: `Sources/HealthCommandCore.swift:1158-1167`.

2. **Hoist `Library/Caches/com.stage11.c11*` walk into `forEachC11Bundle(home:)`.** (Claude #2 + #5.) Three explicit call sites + one *hardcoded* implicit one. The hardcoding in `telemetryAmbiguityFooter` (`Sources/HealthCommandCore.swift:996`) is a real v1 footgun: it never fires on machines that only ran the debug build. Fix the bug while deduplicating; add a test using `com.stage11.c11.debug` to lock the fix.

3. **Introduce `HealthReport`.** (Codex #1, Claude implicitly through #6/#9, Gemini implicitly.) The single move that fixes the empty-state-text drift (the table currently always says "last 24h across ips, sentry, metrickit, sentinel" regardless of `--rail` or `--since`) *and* unblocks every future surface. Both renderers consume the same value. Compatible with current data flow — `runHealth` already gathers all the inputs.

4. **Add `HealthScanContext { home, now, bundleVersion, fileManager }`.** (Codex #3.) Mechanical migration; concentrates time and environment decisions in one place; preparation for fleet/snapshot mode. Does not require touching `LaunchSentinel` or `CrashDiagnostics`.

5. **Promote scanners to a rail definition table.** (Claude #1 as protocol, Codex #2 as table, both validated.) Start with Codex's table-of-functions form. Adding a fifth rail becomes one struct + one append. Bundle this with `HealthScanContext` (#4) so scanner signature is `(HealthScanContext) -> [HealthEvent]`.

6. **Pin filename-safe ISO grammar as a paired primitive.** (Claude #4.) Producer (`SentryHelper.swift`/`LaunchSentinel`) and reader (`HealthCommandCore.parseFilenameSafeISO`) currently maintain independent copies of the same 24-character rule. Type-level binding plus a round-trip property test eliminates a future drift bug. Note: this is the one item Codex explicitly chose *not* to touch (its review intentionally avoided producer-side changes); land it in a follow-up that consciously crosses the producer/reader boundary.

7. **Add `bundleID` and `build` (optional) fields to `HealthEvent`.** (Claude #6, supports Gemini's "agent rail".) Three of four rails already know this. Additive — no test breakage. Unblocks "group by build, what did 0.44.1 break" queries.

8. **Surface `--home <path>` as a CLI flag.** (Claude #7, Codex via `HealthScanContext`, Gemini as `--remote`.) The function is already pure-of-disk. Document as fleet/snapshot/post-mortem use case. Caveat (Claude): `--since-boot` is meaningless against a remote snapshot — needs a defensive error or a documented restriction.

9. **Track rail status per scan (`missing | empty | scanned | permissionDenied | parseSkipped`).** (Codex #4.) Surfaced in JSON, not table. Makes "0 events" interpretable without changing passive semantics. Coarse-grained on purpose.

10. **Add "agent rail" — fifth rail at `~/Library/Logs/c11/agents/`.** (Gemini #2.) Drop-zone for agent-emitted JSON crash payloads. Validates the rail-registry abstraction and closes the operator-vs-tenant observability gap. Pairs with a SKILL update teaching agents to drop these.

11. **Update `skills/c11/SKILL.md` to teach agents `c11 health --json --since 15m` on failure.** (Gemini #1.) Zero code change. Activates the flywheel today. The single most leveraged *non-code* change in the synthesis.

12. **Consolidate test scaffolding into `SyntheticEvidenceBuilder`.** (Codex #5.) Extract `scaffoldAllRails` into helpers per rail (`writeIPS`, `writeSentryEnvelope`, etc.). Compatible with the test-quality policy because tests still exercise runtime behavior through temp-home files.

---

## 3. Wildest Mutations — Creative / Ambitious Ideas Worth Exploring

Ranked by ambition × payoff, not by feasibility:

1. **`c11 health --watch` (live tail).** (Claude mutation A.) Long-running variant; scan every N seconds; print only deltas; exit on Ctrl-C. Operator leaves it running during a multi-hour agent session and *sees* a crash the moment its artifact lands. Naturally pairs with the AsyncStream-based scanners (Claude mutation D).

2. **Agent-driven auto-triage.** (Gemini wild idea #1.) Agents detecting unexpected shell exit / pane failure automatically run `c11 health --since 5m --json` and attach the result to their context window before retrying or escalating. The flywheel kicks in immediately because the SKILL is the only delivery vehicle needed. This is the highest-payoff mutation across all three reviews — it changes c11 from "operator runs a tool" to "agents observe their own ground truth."

3. **Sentinel-as-fingerprint cross-rail correlation.** (Claude mutation B.) Add `fingerprint = sha256(version + build + commit + bundle_id)` — ten bytes — to sentinel events. Other rails inherit the field from filename/path context. `c11 health --correlated` clusters multi-rail evidence of the same incident without parsing payloads.

4. **Cross-machine fleet view via `--remote <ssh-target>`.** (Gemini wild idea #2, builds on Claude #5.) Mount or sync a remote `Library` folder; run local `c11 health` against it. With agent rail (#2) added, this becomes "what happened on the CI runner / dev laptop / remote agent host last night."

5. **`c11 health --producer-trace`.** (Claude mutation C.) Inverts the read direction: dumps where each rail *would* read from on this machine, whether the directory exists, file count, most-recent mtime. Self-diagnosing setup tool. "Why does my health command say zero metrickit?" → trace shows the directory doesn't exist because MetricKit hasn't fired yet on this machine. Cheap to build, very high "operator walks away knowing why" value.

6. **Health as a v2 socket method (`system.health`).** (Gemini experimental #3.) Daemon continuously monitors rails and broadcasts `system.health_events`; agents react instantly to OOMs/hangs without polling. Caveat: must be careful not to block the main thread on heavy I/O sweeps. The pure-function scanners and the `HealthScanContext` abstraction make this a small wrapper.

7. **Evidence confidence axis (`confirmed | inferred | ambiguous`).** (Codex experimental #6.) Sentinel `unclean_exit` = confirmed; Sentry queued = inferred; empty-cache warning = ambiguous. JSON-only initially. Lets agents reason over output without brittle string parsing. Bundles naturally with `HealthReport`.

8. **`c11 reportz` — narrative renderer.** (Claude mutation E.) Same engine, different render. LLM-rendered story over the disk evidence: "On May 1st, c11 unclean-exited twice during 0.43.0. The next version, 0.44.0, ran clean for 36 hours before its first MetricKit hang at 14:30 on May 3." Pure speculation; the engine you have can produce it.

9. **`c11 health --brief` ritual mode.** (Codex experimental #7.) One-line scannable summary for daily operator rhythm: window, counts, newest event, warnings. Better terminal cadence for repeated checks. Wait until `HealthReport` exists.

10. **`--explain <event-id>` forensics recipes.** (Codex.) Rail-specific explanation from a contract table: where the evidence came from, what it proves, what it does *not* prove. Especially useful where "no rows" can mean several different things (Sentry, MetricKit).

---

## 4. Leverage Points and Flywheel Opportunities

### Highest-leverage points (small change, disproportionate value)

1. **The renderer boundary.** (Codex.) Once table and JSON consume one `HealthReport`, every future rail gets counts, warnings, and empty-state semantics for free. This is the single architectural seam that, if gotten right, makes the next ~5 features additive.

2. **Scanner uniformity → registry.** (Claude #1 leverage, Codex #2.) Four scanners already share the contract; promoting that to data drops fifth-rail cost ~80%.

3. **`schema_version` in JSON.** (Claude leverage #2.) One line. Locks the contract before downstream consumers exist. Every future schema change becomes backwards-compatible-by-choice rather than backwards-compatible-by-accident.

4. **`forEachC11Bundle(home:)` helper.** (Claude leverage #3.) ~25 lines saved. Single source of truth for "what counts as a c11 bundle dir." Fixes the latent debug-bundle bug in `telemetryAmbiguityFooter`.

5. **Paired `FilenameSafeISO8601` primitive.** (Claude leverage #4.) Producer and reader stop drifting. Doesn't show up in any release note; saves a future debug session.

6. **`HealthEvent` carrying `bundleID` and `build`.** (Claude leverage #5.) Three rails already know these. Once the event carries them, every downstream surface (group-by-build, version-compare warnings, fleet aggregation) gets them for free.

7. **`HealthArtifact` vs `HealthEvent` split.** (Claude leverage #6.) Cheap now, painful later. One review (Claude) downgrades this without a concrete consumer; the synthesis agrees — defer until the second non-1:1 rail (e.g., MetricKit body parsing, fingerprint correlation) makes the case.

8. **Test scaffolding helpers.** (Codex leverage #3.) `scaffoldAllRails` becoming `SyntheticEvidenceBuilder` shrinks the cost of every future rail's tests.

### The flywheel(s)

All three reviews independently identify the same compounding loop, with different starting points. Combined, the flywheel reads:

1. **Producers leave passive, local, well-named artifacts** during their normal lifecycle. They never know about the reader.
2. **`c11 health` normalizes those artifacts into one report** — same shape, same JSON, same renderer.
3. **The SKILL teaches agents to read the report on failure** (Gemini's contribution). Agents now have ground-truth context about their host environment without polling, asking the operator, or hallucinating.
4. **Agent failure reports become highly-contextual** — the operator (and the orchestrator) gets specific diagnoses instead of "something broke."
5. **Faster fixes to the environment** → agents run longer without dying → more confidence → more aggressive iteration.
6. **New incidents teach c11 a new rail** (Codex's framing). The rail-registry abstraction makes adding it boring. The new rail is immediately consumable by every existing surface (table, JSON, agent SKILL, fleet view).
7. **Cross-rail correlation gets easier with each rail added** (Claude mutation B, the fingerprint). Once two rails agree on a fingerprint, the third joins for free.
8. **Fleet aggregation falls out** (Claude #5, Gemini #2). `--home <path>` is one flag away. The same skill works for "what happened on the CI runner last night" and "what's my dev laptop done since I left it." The engine doesn't care.

### What would break the flywheel

Unanimous warning: **letting `HealthEvent.Severity` keep growing as a single junk-drawer enum.** Every new rail will fight to add a case; the enum will accumulate special meanings; the table column gets wider than the user's terminal; the JSON consumers lock in a schema that doesn't compose. Per-rail severity (or severity-as-tags, Claude's preference) before the fifth rail is the right call. Bundle with `schema_version` bump (1 → 2).

### What lights the flywheel today (no code changes)

The single highest-leverage *non-code* move (Gemini #1): **update `skills/c11/SKILL.md` to teach agents `c11 health --json --since 15m` on unexpected shell exit / pane failure.** Zero engineering. Activates the agent-driven-auto-triage mutation (#2 in wildest) immediately. Validates the JSON-as-API framing in production. Generates real signal about which rails matter most to agents, which feeds back into rail-registry priorities.

---

## 5. Recommended Sequencing

Distilled from the priority orderings across all three reviews:

### v1.1 — "Make the seams right before the fifth rail"
1. `schema_version: 1` in JSON (one line, no debate).
2. Fix `telemetryAmbiguityFooter` hardcoded bundle path + extract `forEachC11Bundle(home:)` helper. (Real bug; deduplicates four call sites.)
3. Introduce `HealthReport` and `HealthScanContext`; refactor renderers to consume them.
4. Promote scanners to a rail definition table (start with Codex's lighter table form).
5. Update `skills/c11/SKILL.md` with the agent auto-triage pattern. (Independent; can ship anytime.)

### v1.2 — "Activate the agent and fleet dimensions"
6. Add `bundleID` and `build` fields to `HealthEvent`.
7. Add `--home <path>` flag with documented snapshot/fleet semantics.
8. Add the agent rail (`~/Library/Logs/c11/agents/`) as the first proof of the registry.
9. Per-rail severity / severity-as-tags + `schema_version` bump 1→2.
10. Rail status field (`missing | empty | scanned | permissionDenied`).

### v1.3+ — "Let the platform breathe"
11. `--watch` (live tail) + AsyncStream-based scanners.
12. Paired `FilenameSafeISO8601` primitive (touches producers; bundle with another producer-side change).
13. `--producer-trace` (self-diagnosing setup tool).
14. Cross-rail fingerprint correlation.
15. Socket method `system.health` (when daemon-side polling becomes valuable).
16. `--brief`, `--explain <event-id>`, `c11 reportz` (operator-rhythm and narrative surfaces).

### Speculative / D11
17. The whole substrate (rail enum, scan-with-since, filename grammar, JSON shape) is the right shape for D11 to inherit largely unchanged. The seams above are the ones to lock in *now* so that inheritance is clean.

---

## Bottom Line

The three reviews agree on a single architectural read: the branch ships a four-rail CLI but builds the substrate for a passive local evidence plane that agents and operators will both consume. The single most important v1.1 investment is making the rail abstraction and the report value-object explicit — every later mutation (watch mode, agent rail, fleet view, narrative renderer, socket API) is additive on top of that foundation. The single most important *non-code* move is teaching agents in the SKILL to read their own ground truth via `c11 health --json`, which lights the flywheel today with zero engineering.
