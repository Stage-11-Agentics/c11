# Synthesis: Standard Plan Reviews — Conversation Store Architecture

**Plan reviewed:** `/Users/atin/Projects/Stage11/code/c11/docs/conversation-store-architecture.md`
**Reviewers synthesized:** Claude (Opus 4.7), Codex, Gemini
**Synthesis date:** 2026-04-27

---

## Executive Summary

All three reviewers converge on the same headline: **the architecture is the right move, the decomposition is sound, and the plan should land — but not without revision.** Each reviewer independently identifies the same structural strengths (push/pull duality, first-class Conversation primitive, provenance-tracked refs, the `isTerminatingApp` gate) and the same handful of pressure points (Codex identity ambiguity, scrape I/O cost, the `shutdown_clean` marker semantics, YAGNI on `replayPTY`).

The disagreement among the three is narrow but informative: it sits almost entirely on **how aggressive the revision bar should be before greenlight**. Gemini reads the plan as "ready to execute with minor revisions." Claude reads it as "ready to execute once the open questions are answered, with a tightening of rollout." Codex reads it as "needs revision, then ready" — and is the only reviewer that explicitly downgrades a load-bearing claim (Codex same-cwd disambiguation) from "structurally fixed" to "heuristic until fixture-proven."

The synthesized verdict: **the plan is architecturally ready. It is not yet implementation-ready.** Roughly a half-day of authoring work — answering the consolidated questions below, picking concurrency primitive, picking rollout option, and downgrading the Codex claim to the appropriate confidence tier — converts it from "good plan" to "actionable plan."

The single highest-leverage revision across all three reviews: **stop treating the existence of a `ConversationStore` as equivalent to having reliable conversation identity.** They are different problems. The store solves provenance, lifecycle, and reconciliation. It does not, by itself, solve identity for hookless TUIs (Codex, opencode, kimi). That distinction needs to be explicit in the plan.

---

## 1. Where the Models Agree (Highest-Confidence Findings)

These are findings where two or three reviewers independently land on the same conclusion. Treat these as the highest-confidence signal in this review pack.

1. **The architectural shape is right.** All three reviewers explicitly endorse the move from wrapper-centric resume to a c11-owned `Conversation` primitive. Each calls out push/pull duality as the strongest single design choice. None proposes an alternative core architecture.

2. **The push/pull (hook + scrape) reconciliation pattern is the correct foundation.** All three name this as architecturally load-bearing: hooks for low-latency precision when available, scrape as the crash-recovery primary. Claude calls it "the literal expression of c11 owns the lifecycle." Codex calls it "directionally correct." Gemini calls it "a classic reconciliation loop pattern."

3. **`ResumeAction.replayPTY` should be dropped from v1 (YAGNI).** Unanimous. No v1 strategy emits it; it pollutes the executor's switch statement with a dead code path. All three explicitly recommend removing it. Claude and Gemini also flag `composite` as borderline; Codex flags `launchProcess` as also potentially aspirational.

4. **The `isTerminatingApp` gate solves the right race, but the query path needs more thought.** All three reviewers note this gate as architecturally elegant. Claude and Codex independently flag that the *mechanism* by which a CLI tombstone subprocess queries `isTerminatingApp` from the running c11 app is under-specified and is on the keystone path. Gemini suggests piggy-backing on existing capabilities/ping responses rather than adding a dedicated socket method.

5. **Pull-scrape I/O cost is under-bounded.** All three independently flag this. Specific concerns vary slightly (Claude: directory scan over months-old session directories; Codex: corrected the autosave cadence from ~30s to the actual 8s; Gemini: I/O storms when many agents run concurrently). All three propose tightening: scrape only on push, app quit, and crash recovery launch — not on every autosave tick — or bound the candidate set explicitly.

6. **The `~/.c11/runtime/shutdown_clean` marker has subtle and under-specified semantics.** Claude and Codex both flag the same conceptual error: writing the marker at the *start* of termination creates a "false-clean" window if c11 crashes mid-shutdown. Both recommend writing the marker only after final scrape + final snapshot complete. Both also note multi-instance / multi-bundle collision potential. Gemini suggests placing it inside the snapshot directory itself rather than a separate runtime path.

7. **The plan understates Codex identity confidence.** Claude and Codex both flag this. The "same-cwd + mtime + after surface activity" heuristic is plausible but is not yet validated against real Codex session-file fixtures, and is not strong enough to support the plan's claim that two same-cwd Codex panes become "structurally impossible to confuse." This is the single largest weakness in the plan — and in Codex's review it is the named blocker for greenlight.

8. **The `skills/c11/SKILL.md` update is part of the work, not a follow-up.** Claude and Codex both call this out independently and both cite c11's "the skill is the agent's steering wheel" principle. The plan does not currently mention the skill update; both reviewers say it must land in the same change.

9. **Removing focused-surface fallback from the new conversation CLI surface is correct.** All three explicitly endorse this. The current `resolveSurfaceId` fallback at `CLI/c11.swift:7261` is acceptable for interactive operator commands but dangerous for hook subprocesses where `CMUX_SURFACE_ID` may be missing; conversation writes must fail closed.

10. **Strategy-missing-on-restore should skip with `Diagnostics.log`, not error.** Unanimous. All three say silent skip with logging is the correct v1 behavior; Claude adds a desire for an operator-visible sidebar advisory so the missing-strategy state is not invisible.

11. **The wrapper should short-circuit when `CMUX_DISABLE_AGENT_RESTART=1`.** Claude and Gemini both explicitly recommend this. If the operator opted out of restart, the wrapper should not seed placeholder claims that will never be resumed.

12. **The plan correctly rejects PTY hibernation and "harden the current pattern."** All three concur. PTY hibernation does not survive reboot/power loss (the primary operator complaint); hardening the current pattern just moves the failures to the next TUI.

---

## 2. Where the Models Diverge (Disagreement is Signal)

These are points where two or more reviewers reach different conclusions or weight the same fact differently. The disagreement is itself useful information.

1. **Concurrency primitive: actor vs. serial dispatch queue.**
   - **Gemini:** "Yes, absolutely use a Swift `actor`. c11 is moving toward actor-isolation; this is the perfect isolated state container."
   - **Claude:** "Lean serial dispatch queue + `async` accessors for v1. Actor migration is a future cleanup. Reason: compatible with existing socket handler shape; an actor forces every caller to be `async`, changing call-site shape across socket handlers that are currently sync."
   - **Codex:** Does not pick directly but emphasizes that whatever is chosen must support "monotonic sequence numbers or compare-and-set generations" rather than wall-clock-only ordering, which leans toward actor or queue with explicit sequencing.
   - **Signal:** This is a real disagreement worth surfacing. Gemini optimizes for forward direction; Claude optimizes for minimum disruption to existing call sites. Codex highlights that ordering correctness matters more than the primitive choice.

2. **Source priority on tiebreakers (`push > scrape > wrapperClaim > manual`).**
   - **Plan as written + Claude:** The proposed ordering is reasonable and provenance-aware.
   - **Codex:** Disagrees specifically on `manual` being the lowest priority. "If an operator manually sets or clears a conversation, that should either be an explicit override or a distinct action with clear precedence." This is a substantive point the other two miss.
   - **Signal:** Codex is right to flag this. Manual operator action is intent; it should not lose to a stale push.

3. **Snapshot integration: sibling map vs. embedded in panel snapshots.**
   - **Plan as written + Claude:** Sibling `surface_conversations: { surface_id: SurfaceConversations }` map alongside `panels` in the workspace snapshot.
   - **Codex:** Argues for embedding conversation state directly into each `SessionPanelSnapshot`. Reasoning: existing `oldToNewPanelIds` remap path makes a sibling map require lockstep remapping or it produces orphans. Embedding makes conversations follow restored panels naturally.
   - **Gemini:** Notes architectural friction with the global derived index but does not directly engage with the sibling-vs-embedded decision.
   - **Signal:** Codex's proposal is technically stronger here. Claude and Gemini do not engage with the orphan-map risk class. This is a real architectural decision worth revisiting.

4. **Codex tombstone semantics (Claude SessionEnd outside app termination).**
   - **Plan as written:** SessionEnd with `isTerminatingApp == false` tombstones (interpreted as user `/exit`).
   - **Codex:** Pushes back. SessionEnd may also fire on Claude process crash, terminal shell kill, or wrapper failure — none of which are intentional tombstones. Suggests `unknown` or `suspended-with-ended-process` as the safer default unless the hook payload distinguishes explicit `/exit` from process death.
   - **Claude and Gemini:** Accept the plan's mapping without challenge.
   - **Signal:** Codex caught a real edge case the others missed. The plan should answer whether SessionEnd's payload distinguishes these cases.

5. **Rollout strategy.**
   - **Claude:** Forces an explicit choice between three options (ship 0.44.0 with C11-24 hotfix and conversation-store in 0.45.0 / pull C11-24 entirely / hold 0.44.0 until conversation-store ready). Recommends option (a). Calls out that the current plan implies (c) but is ambiguous.
   - **Codex and Gemini:** Do not engage with rollout sequencing at all.
   - **Signal:** Claude is the only reviewer surfacing this — but it is a real product-shipping decision the plan should make explicit.

6. **Strategy interface shape.**
   - **Plan as written + Gemini:** Two pure functions (`capture`, `resume`).
   - **Codex:** Strategies should not be described as pure functions if they perform scrape discovery. Splits the interface into a strategy (interprets pre-collected signals), a scraper/provider (performs bounded I/O), and the store (reconciles). Argues this matters for testability and concurrency.
   - **Claude:** Predicts the strategy interface will grow to 3-4 functions in practice (`applyPush`, `applyScrape`, `applyClaim`, `resume`) but does not propose the scraper/strategy split that Codex does.
   - **Signal:** Codex's split is the cleanest architectural refinement of the three. Worth considering.

7. **`history: []` on disk — empty array or omitted key.**
   - **Claude:** Empty array. Reason: stable `--json` shape across v1/v2, no special-casing in tooling.
   - **Codex and Gemini:** Do not address.
   - **Signal:** Claude's recommendation is sound and unopposed; treat as resolved unless the author has a specific reason to omit.

8. **Codex tombstone heuristic (reading `last_message_role` from session files).**
   - **Claude:** Skip for v1. Heuristic-based tombstoning fails silently when wrong; better to never auto-tombstone Codex than to auto-tombstone wrong.
   - **Codex:** Does not engage directly but emphasizes "wrong auto-resume is worse than skipped auto-resume" — same principle.
   - **Gemini:** Notes the limitation as ambient ("the system can never confidently know if a session is truly dead until a restart happens") but does not propose a policy.
   - **Signal:** Convergent on the principle (skip-on-ambiguity) even where reviewers do not engage directly.

---

## 3. Unique Insights (Surfaced by Only One Reviewer)

These are findings that only one reviewer raised. They are not necessarily lower-value — sometimes one reviewer caught something the others missed.

### Only Claude (Opus 4.7) surfaced:

1. **The drift in §Capture wording: "primary push, fallback pull" reads as global A/B but is actually per-strategy.** For Codex, pull is primary even on the happy path. Worth one sentence of clarification.
2. **A "conversation supervisor" or "lifecycle coordinator" actor is implicit but unnamed.** The thing that triggers pull-scrape on autosave tick, gates `isTerminatingApp`, and orchestrates crash recovery is scattered across three sections. Naming it now prevents emergence-during-impl churn.
3. **The wrapper-claim placeholder id format (`<surface-uuid>:<launch-ts>`) lacks a recognition predicate.** No way for a strategy at scrape time to distinguish "placeholder waiting for replacement" from "real id, leave alone." Recommends `placeholder: true` boolean or `placeholder:` prefix.
4. **Snapshot version-skew during pre-release testing matters.** Atin tests across builds. Pre-release snapshots containing `claude.session_id` in surface metadata need a one-time read-side migration; otherwise captured sessions are lost across cutover.
5. **`c11 conversation push --payload <json>` shell-quoting matters.** The reference wrapper uses `HOOKS_FILE` (path-or-inline) precisely to avoid hook-author quoting hell. Plan should specify path-or-inline vs. inline-only.
6. **The codex `cwd-filter` claim in the existing wrapper is inherited assumption.** The plan asserts `codex resume <session-id>` makes per-pane resume work. If `codex resume` itself filters by cwd, the same multi-pane "last wins" bug recurs. Verify against codex 0.124+ before impl.
7. **Where does the new code physically live?** `Sources/ConversationStore.swift`? `Sources/Conversation/Store.swift`? Naming up front avoids churn.
8. **`claim` CLI idempotency.** If the wrapper restarts twice in the same surface, does the second `claim` overwrite, leave, or compare? Plan's reconciliation rule implies overwrite, but a less-informative `wrapperClaim` should not clobber a scrape-confirmed ref.
9. **Failure-mode table → test matrix mapping.** The §Failure modes table has eight rows; §Testing lists generic categories. One test per failure-mode row would close the loop.
10. **Tone/closing observation:** "The 30 questions in this review are a mark of how much the plan invites engagement, not how flawed it is. Land it." — Claude's review is the most enthusiastic of the three.

### Only Codex surfaced:

1. **The store/identity distinction must be explicit in the plan.** "ConversationStore exists" ≠ "conversation identity is known." This is the single sharpest framing across all three reviews.
2. **Strategy interface should split into strategy + scraper/provider + store.** The cleanest decomposition refinement proposed in any review.
3. **Tiered-confidence v1 shipping plan:** Strong resume (Claude) / heuristic resume (Codex, with diagnostics) / fresh-launch declaration (opencode/kimi). Honest and operationally useful — and the only review to propose explicit confidence tiering.
4. **`typeCommand` requires per-strategy id-validation grammar.** Claude has UUID validation today. Codex needs an equivalent grammar before any `typeCommand` emits. Without this, ids are opaque to the store but cannot be opaque to a shell.
5. **Privacy boundary for transcript reads must be explicit.** Reading `~/.claude/sessions` and `~/.codex/sessions` is not a write, so it does not violate the unopinionated-terminal rule — but transcript content should never be copied into c11 snapshots. Bounded parsing, metadata-only reads where possible.
6. **Confidence-scored refs as an alternative model.** `active: ConversationCandidate?` with confidence/provenance instead of `active: ConversationRef?`. Auto-resume only above a threshold. Probably overkill for v1 but the principle (wrong auto-resume > skipped auto-resume) is sound.
7. **Wall-clock `capturedAt` is a weak ordering tool under close races.** Suggests store-side monotonic sequence numbers or compare-and-set generations.
8. **The Codex wrapper could potentially inject a harmless per-surface marker into the session.** Asks whether this violates the host-not-configurator principle, or whether filesystem scrape is the only allowed signal.
9. **Manual-overrides priority concern (already in §2).**
10. **Embedded panel-snapshot conversations as the cleaner alternative (already in §2).**

### Only Gemini surfaced:

1. **`shutdown_clean` placement closer to the data it affects.** Specifically suggests placing the marker inside `~/.c11-snapshots/` rather than a separate `~/.c11/runtime/` path. Conceptual binding of state to the data.
2. **`isTerminatingApp` could piggyback on existing capabilities/ping responses.** Avoids adding a dedicated, highly-specific socket method just for the CLI tombstone check.
3. **Hook payload routing taxonomy.** When collapsing `c11 claude-hook session-start` into `c11 conversation push`, can telemetry breadcrumbs be migrated into the generic push handler (logging `conversation.push.claude-code`) rather than keeping the old hook command alive purely for taxonomy purposes?
4. **Brevity as a stylistic property.** Gemini's review is the shortest of the three by a wide margin and reaches the same core conclusions. Worth noting that the plan's signal-to-noise ratio is high enough that a compact review can hit most of the same points.

---

## 4. Consolidated Questions for the Plan Author

Deduplicated across all three reviews, ordered by structural importance (architecture-defining first, scoping decisions second, implementation details third).

### Architecture-defining (answer before greenlight)

1. **Codex identity confidence — fixture validation.** What exact fields exist in `~/.codex/sessions/*.jsonl`? Is there a stable session id, creation timestamp, cwd, process id, or invocation id that can be tied to a specific wrapper claim? Has the "same-cwd + mtime + after surface activity" heuristic been validated against real Codex session files with overlapping same-cwd panes? Until proven, downgrade the plan's claim from "structurally fixed" to "heuristic until fixture-proven." (Codex Q1, Q2, Q3; Claude Q29)

2. **Codex ambiguity policy.** When the Codex scraper finds two plausible sessions for one surface, what happens — skip, choose newest, prompt via diagnostics, or store an ambiguous ref? Is wrong auto-resume worse than no auto-resume? (Codex Q2, Q3; aligned with Claude Q23)

3. **`isTerminatingApp` query path under shutdown stress.** When SessionEnd fires *during* c11's shutdown sequence and the CLI tombstone subprocess tries to query `system.is_terminating` over the socket, what is the policy if the socket is already torn down or hung? Default to "not terminating" (recreates the bug)? Default to "terminating" (loses legitimate `/exit` tombstones)? Wait with timeout? (Claude Q14; Codex Q16; Gemini Q8)

4. **`shutdown_clean` write timing.** Should the marker be written only after final forced scrape and synchronous snapshot complete, not at the start of `applicationWillTerminate`? Or use a dirty/clean generation pattern (mark dirty at launch, write clean only after final capture)? (Codex Q6; Claude §Weaknesses 4)

5. **`shutdown_clean` location and multi-instance collision.** Is the marker shared across tagged debug builds, release builds, and multiple running c11 instances? Should it be per-bundle-id, per-socket-path, or inside the snapshot directory? (Claude Q26; Codex Q7; Gemini Q2)

6. **Snapshot integration: sibling map or embedded.** Should conversations be a sibling `surface_conversations` map on the workspace snapshot, or embedded into each `SessionPanelSnapshot`? If the sibling map stays, what is the exact old-surface-id to new-surface-id remap behavior? Embedding avoids the orphan-map class of bugs and follows existing restore remapping naturally. (Codex Q8)

7. **SessionEnd interpretation.** Does Claude SessionEnd distinguish explicit `/exit` from process crash or terminal kill? If not, should SessionEnd outside app termination tombstone, transition to `unknown`, or transition to `suspended-with-ended-process`? Tombstone should mean intentional end, not "the process happened to die." (Codex Q5)

8. **Concurrency primitive: actor or serial dispatch queue?** Gemini recommends `actor` (compile-time isolation, fits c11's actor-isolation direction). Claude recommends serial queue + `async` accessors (compatible with existing socket handler call-site shape, actor migration as future cleanup). Codex emphasizes ordering correctness over primitive choice. Pick one before impl. (Claude Q18; Gemini Q3; plan §Open questions Q11)

9. **Rollout option — pick explicitly.** (a) Ship 0.44.0 with C11-24 hotfix, conversation-store in 0.45.0; (b) pull C11-24 from 0.44.0, ship 0.44.0 without resume, conversation-store in 0.45.0; (c) hold 0.44.0 until conversation-store ready and ship together. The plan currently implies (c) but is ambiguous; (c) is highest-risk, (a) is lowest. (Claude Q13)

### Scoping decisions

10. **Source priority — manual placement.** Should manual operator pushes/clears really be lowest priority? An explicit operator action arguably should be a distinct override or at least win over stale push/scrape. (Codex Q9)

11. **Strategy interface — pure functions or strategy + scraper/provider split?** Strategies that perform scrape discovery are not pure functions in any meaningful sense. Should the interface split into (a) strategy interpreting pre-collected signals, (b) scraper/provider performing bounded I/O, (c) store reconciling? (Codex; aligned with Claude's prediction of a 3-4 function interface)

12. **`ResumeAction` enum scope — drop `replayPTY`?** Unanimous yes from all three. Also drop `composite` and possibly `launchProcess` if no v1 strategy emits them. (Claude Q24; Codex Q11, Q12; Gemini Q4; plan §Open questions Q8)

13. **Wrapper-claim placeholder id recognition.** How does a strategy at scrape time distinguish "placeholder waiting for replacement" from "real id, leave alone"? Add a `placeholder: true` boolean to the ref, or a `placeholder:` prefix on the id, or a dedicated state? (Claude Q17; plan §Open questions Q5)

14. **Wrapper PATH gating on `CMUX_DISABLE_AGENT_RESTART=1`.** Should the wrapper short-circuit completely when this env var is set? Both Claude and Gemini lean yes — otherwise the store fills with claims that will never be resumed. (Claude Q21; Gemini Q5; plan §Open questions Q9)

15. **Pull-scrape cadence — bound or remove autosave-tick scraping.** Should scrape run only on push hooks, `applicationWillTerminate`, and crash-recovery launch — not every 8s autosave tick? If kept on autosave, what bounds the candidate set (cap at most-recent N by mtime, filename-as-id, etc.) so directory growth over months does not regress autosave latency? (Gemini Q1; Claude Q15; Codex §Weaknesses)

16. **Strategy resolution scope.** Should scrape run for every registered TUI strategy per surface, or only for the surface's declared/claimed kind? (Codex Q15)

17. **Privacy boundary for scrape reads.** Does scrape read only metadata and filenames, or can it parse transcript/session content? What transcript content (if any) may be copied into c11-owned files? (Codex Q13)

### Implementation details

18. **`typeCommand` id-validation grammar per strategy.** What validation grammar does each strategy apply before emitting `typeCommand`? Claude has UUID validation today; Codex needs an equivalent rule once the real session-id shape is verified. (Codex Q10)

19. **Snapshot version-skew during pre-release.** Is there a one-time read-side migration that lifts existing `claude.session_id` from surface metadata into the conversation store? Where does the translation happen — one launch, one release, or all legacy snapshots until rewritten? (Claude Q16; Codex Q17)

20. **Wrapper-claim idempotency.** If the wrapper restarts in the same surface, does the second `claim` overwrite, leave, or compare? A less-informative `wrapperClaim` should arguably not clobber a scrape-confirmed ref. (Claude Q27)

21. **`history: []` — empty array or omit key?** Lean: empty array, for stable `--json` output across v1/v2. (Claude Q20; plan §Open questions Q7)

22. **`c11 conversation push --payload <json>` — inline only or path-or-inline?** Path-or-inline (matching `HOOKS_FILE`) avoids hook-author shell-quoting hell. (Claude Q25)

23. **Strategy missing on restore — silent skip or visible failure?** Unanimous: skip with `Diagnostics.log`. Claude adds an operator-visible sidebar advisory so missing-strategy state is not invisible. (Claude Q22; Gemini Q7)

24. **Hook payload routing taxonomy.** Can existing telemetry breadcrumbs be migrated into the generic `c11 conversation push` handler (logging `conversation.push.claude-code`), rather than keeping the old hook command alive just for taxonomy? (Gemini Q6)

25. **`isTerminatingApp` exposure mechanism.** New `system.is_terminating` socket method, an app lifecycle field in `capabilities`/`ping` responses, or internal-only routing that avoids a CLI query entirely? (Codex Q16; Gemini Q8)

26. **Diagnostics for skipped auto-resume.** What should operators see when auto-resume is skipped because: no strategy, ambiguous scrape, tombstoned ref, or failed command synthesis? (Codex Q19)

27. **Manual QA matrix for 0.44.0 ship gate.** Minimum cases: Claude same-cwd, Codex same-cwd, mixed Claude/Codex, crash recovery, clean Cmd+Q, user `/exit` tombstone. Plus: every row in the §Failure modes table mapped to a runnable test. (Codex Q20; Claude Q19)

28. **Skill update — confirm in same change.** `skills/c11/SKILL.md` documents the wrapper pattern as the resume mechanism; the c11 CLAUDE.md philosophy section codifies it. Both must update when this lands. Per c11's "the skill is the agent's steering wheel" principle, this is part of the work, not a follow-up. (Claude Q28; Codex §Weaknesses, Q18)

29. **Where does the conversation store live in code?** `Sources/ConversationStore.swift`? `Sources/Conversation/Store.swift` with a folder? `Sources/AgentRestart/` (renamed)? (Claude Q30)

30. **A `ConversationLifecycle` coordinator/supervisor — name it now or let it emerge?** The thing that triggers pull-scrape on autosave tick, gates `isTerminatingApp` on tombstone CLI calls, and orchestrates crash recovery is implicit across three sections. (Claude §Weaknesses 1, §Architectural Assessment)

---

## 5. Overall Readiness Verdict (Synthesized)

**The plan is architecturally ready. It is not yet implementation-ready.**

Aggregating across all three reviewers:

- **Gemini's verdict:** Ready to execute (with minor revisions).
- **Claude's verdict:** Ready to execute, conditional on answers to ~17 open questions and 4 named gap-decisions.
- **Codex's verdict:** Needs revision, then ready. Six explicit revisions named.

The synthesized position is **"Ready to execute after a focused authoring pass."** That pass should:

1. **Downgrade the Codex same-cwd disambiguation claim** from "structurally impossible to confuse" to "heuristic until fixture-proven," and define the ambiguity-policy fallback (Codex's strongest contribution to this review pack).
2. **Move the `shutdown_clean` write to after final scrape + final snapshot** (or switch to a dirty/clean generation pattern). Specify the multi-instance collision behavior.
3. **Specify snapshot remapping for conversations explicitly** — preferably by embedding conversation state in `SessionPanelSnapshot` rather than as a sibling map, but if the sibling map stays, define the exact `oldToNewSurfaceIds` remap.
4. **Add per-strategy id-validation/quoting requirements** for any `typeCommand` emission.
5. **Pick concurrency primitive** (actor vs. serial queue) and **pick rollout option** (a, b, or c).
6. **Drop `ResumeAction.replayPTY`** from v1; consider also dropping `composite` and `launchProcess` until a strategy emits them.
7. **Bound pull-scrape I/O cost** — either remove autosave-tick scraping or cap the candidate set explicitly.
8. **Add the skill update to the implementation checklist** as part of the work, not a follow-up.
9. **Define the `isTerminatingApp` query path semantics** under shutdown stress (this is the keystone).
10. **Map every row of the §Failure modes table to a runnable test.**

None of these requires another full review cycle. They are decisions a single author can resolve in a focused half-day. After that pass, the plan is genuinely ready.

The deeper meta-signal across all three reviews: **the plan invites this kind of engagement because it is the right kind of architectural work.** Not a refactor for refactor's sake, not a hot-fix masquerading as design, but a primitive-naming exercise that makes the right class of bugs structurally impossible while preserving the right escape hatches for v2/v3. All three reviewers, in their own register, end on this note. Land it — after the half-day pass.
