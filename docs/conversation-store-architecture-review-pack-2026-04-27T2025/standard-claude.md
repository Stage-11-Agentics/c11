# Standard Plan Review — conversation-store-architecture (Claude)

**Plan reviewed:** `/Users/atin/Projects/Stage11/code/c11/docs/conversation-store-architecture.md`
**Reviewer:** Claude (Opus 4.7), Standard Plan Review
**Date:** 2026-04-27

## Executive Summary

This plan is fundamentally sound and is the right kind of architectural move at the right moment. The author has correctly identified that the wrapper-only pattern in 0.43/0.44-pre is a *category error*: it tries to push c11's resume responsibility into TUI lifecycle hooks that two of the four target TUIs do not even expose, and one of the two that *does* expose them (Claude Code, via SessionEnd) actively races c11's own shutdown sequence. The proposed shape — a small in-c11 `Conversation` primitive with per-kind strategies that fuse a push channel (hook/wrapper-claim) with a pull channel (on-disk session-file scrape) — moves the locus of responsibility from "whatever the TUI happens to expose" to "what c11 needs in order to resume." That inversion is the right one.

The single most important thing about this plan: **it does not over-reach**. The Conversation primitive is scoped narrowly to the resume problem c11 actually has today, with deliberate forward-compat seams (kind/id opacity, history list, derived global index) that cost nothing in v1 but unlock cloud agents, history UI, and "any past conversation in any pane" without re-architecting. That restraint is the difference between a refactor that ships and a refactor that becomes a year-long rewrite. The plan is also explicit about what is *not* in scope, which is the correct discipline for a v1.

The risks are mostly execution risks, not design risks: (a) the pull-scrape paths for opencode and kimi are TBD and could turn out to be much harder than estimated, (b) the `isTerminatingApp` query from a CLI subprocess back into the running c11 app is a new socket round-trip on a hot tombstone path that can race shutdown itself, and (c) the rollout story for the held PR #94 / 0.44.0 needs more than a one-line mention in §Rollout. None of these are blockers; all are addressable in implementation.

**Verdict at a glance:** Ready to execute with answers to the open questions and a tightening of the rollout story. Not "needs rethinking." Not "needs revision in shape." Just "answer the dozen sharp questions the author already wrote down at the bottom of the plan, plus the additional ones below."

## The Plan's Intent vs. Its Execution

**Intent (as I read it).** Replace a wrapper-centric resume mechanism that cannot serve the operator's actual fleet (claude, codex, opencode, kimi, future cloud agents) with a c11-owned primitive whose authority over conversation lifecycle is independent of whether any specific TUI cooperates. The deeper intent: move c11 from "passenger of TUI lifecycle" to "owner of conversation lifecycle, consumer of TUI signals."

**Execution against intent.** The execution is well-aligned. Three observations:

1. **The push/pull fusion captures the intent precisely.** A strategy that takes hooks when offered and falls back to scraping the TUI's session-file directory is the literal expression of "c11 owns the lifecycle; TUI signals are an input, not the input." The provenance field (`capturedVia`) is a small but crucial detail: it lets the reconciliation rule prefer push over pull *when push is fresh*, while still making pull authoritative on crash recovery. That is exactly the policy a system whose authority survives the TUI's death needs.

2. **The "wrapper-claim" lowest-priority signal is a cleaner pattern than it looks at first glance.** It seeds the surface with *something* (a placeholder ref) before the TUI has done anything, so every downstream consumer (sidebar UI, list commands, scrape reconciliation) has a stable thing to point at. The placeholder gets replaced when scrape catches up. This is the right shape — it removes the "no ref yet" / "ref present but empty" duality that complicates wrapper-only designs.

3. **One mild drift.** §Capture says "Push primary, pull as fallback and crash-recovery primary." But the strategy table for Codex is *entirely* pull-based on the live path (the wrapper claim only mints a placeholder; the real id only ever comes from scrape). For Codex, pull is primary even on the happy path. The wording is fine if you read it carefully, but a reader could come away thinking push/pull is an A/B fallback when in practice it is per-kind. Worth one sentence in §Capture clarifying that the primary/fallback split is *per strategy*, not global.

Net: the plan does what it says. The drift is editorial, not structural.

## Architectural Assessment

**Is this the right decomposition?** Yes, with one nuance. The `Conversation`/`Strategy`/`Store` triad is the canonical decomposition for this problem space (it's roughly the same shape as VCS adapters in editors, multi-cloud SDKs, or notification routers). The pure-function strategy pair (`capture`, `resume`) keeps the business logic testable without live TUIs, which directly addresses the "we cannot keep manually QA-ing the 4-pane matrix" pain that triggered this work.

**The one nuance:** the plan has the strategy interface as two functions but the `capture` function is asked to handle three distinct upstream signal types (push, pull, wrapper-claim) inside one body. In practice each strategy will end up with a small internal switch on signal source. That is fine — and the plan acknowledges it implicitly via the `CaptureSource` enum on the ref — but I would expect the strategy interface to grow to three or four functions (e.g., `applyPush`, `applyScrape`, `applyClaim`, `resume`) within one or two implementations. Not a flaw; just a prediction worth naming so it does not surprise the implementer.

**Decomposition boundaries.** The seam between `ConversationStore` and `Strategy` is well-drawn: store owns persistence + concurrency + reconciliation policy; strategy owns interpretation. The seam between `ConversationStore` and `WorkspaceSnapshot` is also clean: snapshot is source of truth, store rehydrates from snapshot, derived index is a read-only convenience.

**One missing seam.** The plan does not talk about a "conversation supervisor" or "conversation lifecycle observer" — i.e., the thing that *triggers* pull-scrape on autosave tick and crash recovery, and the thing that gates `isTerminatingApp` on tombstone CLI calls. These responsibilities are scattered across §Capture, §Crash recovery, and §Per-TUI strategies. They feel like a `ConversationLifecycle` actor or coordinator class waiting to be named. If the author already has that in mind and just did not pull it out, fine. If not, expect it to emerge during implementation and consider naming it now.

**Alternative framing.** The strongest alternative I can imagine — and the one I tested mentally against this plan — is **"event-sourced ledger of conversation events"** rather than "stateful store of refs." In that model, every signal (start, end, scrape-found, claim, tombstone) is an append to a per-surface event log; the "current ref" is a fold over the log. Advantages: simpler concurrency (append-only), free history, replay-able for debugging, naturally handles "which signal won" (last write wins on a sorted log). Disadvantages: more storage, more code for the fold, and v1 wants none of those advantages. The plan's stateful-store-with-provenance choice is the right v1; the event-sourced model is a v3+ alternative if conversation lifecycle ever gets richer (multi-author conversations, distributed agents, etc.). The plan does not foreclose moving there, which is the correct trade.

## Is This the Move?

**Yes, with caveats about timing.** The bet this plan makes — "the architecture is the bug, ship the architecture not a hot-fix" — is the correct bet *given the QA findings*. Three of the four observed failures (codex multi-pane "last wins," opencode/kimi never resuming, claude SessionEnd-clears-on-quit) are not patchable in the current architecture without compounding kludges. The author is right that approach A (harden the wrapper) just moves the failures one TUI down the road.

**Where I would push back gently:** the rollout story is currently a single bullet point ("0.44.0 ships with the conversation-store as its marquee feature"). For a refactor that touches the snapshot schema, the wrapper bundle, the CLI surface, and the on-launch crash-recovery path simultaneously, that is too thin. The held PR #94 already has 25+ upstream picks bundled with it; stacking a conversation-store landing on top of that will be a several-week implementation, and 0.44.0 is currently held *because* C11-24 is shipping in it. Three sharper rollout choices the plan should make explicit:

1. **Ship 0.44.0 with the current C11-24 hotfix (PR #89), promote conversation-store to 0.45.0.** Lets the hotfix unlock the held release, gives the refactor a clean release window, decouples risk. The 0.44.0 changelog stays as written.
2. **Pull C11-24 hotfix back out of 0.44.0, ship 0.44.0 without resume at all, ship 0.45.0 with conversation-store.** Cleaner conceptually, but means operators lose the partial resume working today.
3. **Hold 0.44.0 until conversation-store is ready, ship them together as 0.44.0.** What the plan currently implies. Highest risk; easiest to explain in a changelog.

The plan should pick one of these explicitly. The current "the held PR #94 gets the implementation diff stacked onto its branch" is ambiguous about whether that means option 3 or something else. (See Question 13.)

**The "right bets" question more broadly.** The plan correctly bets on:
- Seamful design over a plugin system (the explicit "we are not building a plugin system" line is the kind of restraint that ages well).
- In-memory derived index in v1 (do not pre-optimize storage for a feature whose UI does not exist yet).
- Snapshot-as-source-of-truth (preserves the "snapshots are the durable thing" invariant the rest of the codebase relies on).
- Pull-scrape on crash recovery (the only safe choice given that push values may be 100ms stale and unrecoverable).

The plan correctly bets *against*:
- PTY hibernation (would lose conversations on sleep/power-off, defeating the point).
- Manual checkpoints as primary (operator burden for a transparent capability).
- Cloud strategies in v1 (out-of-scope creep).

Those are all the right calls. I would not change any of them.

## Key Strengths

1. **Provenance is first-class.** `capturedVia: CaptureSource` is the kind of detail that distinguishes architecture written by someone who has debugged this class of problem from architecture written by someone who has only thought about it. It makes the reconciliation rule explainable (push > scrape > wrapperClaim > manual on close timestamps), debuggable without instrumentation, and testable. This is the principle: *every signal carries its provenance forward*. That principle pays dividends every time you have to explain why a particular conversation got resumed in a particular way.

2. **The fallback-to-focused-surface footgun is killed.** The plan explicitly removes silent fallback in the `conversation push|claim|tombstone` CLI surface and routes any failure to a hard error. The current `resolveSurfaceId` at `CLI/c11.swift:7261` falls through to `items.first(where: { ($0["focused"] as? Bool) == true })`, which is exactly the silent-misroute the plan calls out. Replacing that for the new CLI surface (and *only* for that surface, preserving the existing fallback elsewhere with a deprecation warning) is the right surgical fix. The principle: *silent fallbacks at boundaries are tech debt with interest.*

3. **State machine is small and the transitions are explicit.** Five states (`alive`, `suspended`, `tombstoned`, `unknown`, "(no ref)") with clearly-drawn transitions, including the critical `isTerminatingApp` gate on `alive → tombstoned`. Small state machines are reviewable; large ones are not. The author kept this small, and the asymmetric "claude can tombstone autonomously, codex never can" rule is correctly factored into the *strategy*, not the state machine.

4. **`history: []` empty-but-typed.** Persisting an always-empty history list in v1 to lock in the schema shape for future history support is exactly the right "make the future cheap" move. Costs almost nothing now; saves a schema migration later. The principle: *the cheapest forward-compat is the empty list, the never-renamed key, the opaque id.*

5. **Strategy resolution by name with fallback to `nil`.** The existing `AgentRestartRegistry.named(_:)` already returns `nil` for unknown names rather than erroring, which lets snapshots survive registry changes. The plan inherits this discipline and extends it to strategies. The principle: *snapshots written today must survive registry edits tomorrow.*

6. **The plan engages directly with the known failures.** The "Failure modes and how each is handled" table is the kind of concrete artifact that tells me the author has actually thought through the breakage modes, not just the happy paths. Every row in that table maps to either an observed bug or a near-miss. That table should survive into the implementation as a runnable test matrix (see "Weaknesses" for the gap).

## Weaknesses and Gaps

1. **`isTerminatingApp` querying is under-specified and on a critical path.** Open question 12 asks where `isTerminatingApp` gets queried by the CLI. This is not a minor implementation detail — it is the *only* mechanism preventing the very race the plan exists to fix. If the SessionEnd hook fires in a CLI subprocess, that subprocess has to round-trip to the running c11 app's socket to ask "are you shutting down?" But the c11 app *is* shutting down at that exact moment, which is when the socket is most likely to be slow, hung, or already torn down. If the CLI cannot get an answer, what does it do? Default to "not terminating" (and tombstone, recreating the bug)? Default to "terminating" (and silently lose legitimate user-typed `/exit` tombstones)? Time out and skip (silent loss either way)? The plan defers this to impl, but it is the keystone of the whole approach. I would flesh this out before greenlight.

   *Downstream effect if not addressed:* the very bug the plan is structured around (Bug 2 in the §Why section) reappears, masked by complexity, and is harder to diagnose than the current direct race.

2. **Pull-scrape directory-watching cost is not bounded.** §Capture says "stat the directory, find the most-recently-modified session matching this surface's filter, no I/O on the file unless newer than the cached ref" at every autosave tick, per TUI per surface. For a workspace with 8 panes × 4 TUIs × 30 s autosave, that is roughly 32 directory stats per autosave plus filename pattern matching. On a fast SSD it is nothing. On a network home directory or a Time Machine snapshot scan, it could be tens of milliseconds per stat. Worse, `~/.claude/sessions/` and `~/.codex/sessions/` accumulate one file per session forever; after a few months an operator's directories have thousands of entries, and "find the most-recently-modified" becomes a full directory scan. The plan should pick a bounded strategy (sorted by mtime via `readdir + sort`, capped at top-N candidates, fall back to filename UUID if filenames carry the id).

   *Downstream effect:* autosave latency creep that is invisible until it causes a user-facing typing-latency regression in c11 itself, since autosave runs on a non-main thread but contends with disk I/O the main thread also touches.

3. **The wrapper-claim placeholder id is under-specified.** Open question 5 acknowledges this. The proposed format `<surface-uuid>:<launch-ts>` is fine but the *recognition predicate* is undefined: how does a strategy at scrape time know "this id is still a placeholder, replace it" vs "this id is real, do not clobber it"? A prefix marker (`placeholder:`) or a dedicated bool field on the ref would make this explicit. Without it, a future kind whose real ids legitimately contain colons would silently break.

4. **The `~/.c11/runtime/shutdown_clean` marker has subtle failure modes.** Open question 6 acknowledges location uncertainty, but the *semantics* also have edge cases not addressed:
   - What if c11 is force-quit twice in a row, second time during the slow-quit cleanup of the first? File could be in any state.
   - What if a second c11 instance launches (multi-account, dev build alongside release)? They share the marker.
   - What if the disk is read-only at quit time (full disk, sandbox issue)?
   The plan should at minimum acknowledge these and pick an "if in doubt, treat as crash" policy. Probably fine, but worth saying.

5. **Concurrency design specifics are vague.** §Concurrency offers serial dispatch queue or actor (open question 11) but does not say which. For a primitive that lives across the main actor (snapshot read/write), socket handlers (off-main), and timer threads (autosave), the choice matters: an actor gets you Swift compile-time isolation guarantees but forces every caller to be `async`, which changes call-site shape across socket handlers that are currently sync. A serial queue is more compatible with the existing CLI socket handler shape. I would lean serial queue for v1 to minimize call-site churn, with a note that an actor migration is a future cleanup. The plan should pick one before impl, not after.

6. **No story for snapshot version-skew during the rollout.** When a 0.44.0-pre snapshot containing `claude.session_id` in surface metadata is loaded by the new conversation-store code, what happens? §Rollout says "read once for backward-compat at v1.0 launch." But pre-release builds are routinely loaded against newer pre-release builds during Atin's testing. The plan should have a paragraph on the read-side compatibility: a one-time migration at launch that lifts `claude.session_id` from surface metadata into the conversation store, then drops the key. Otherwise, anyone testing builds across the cutover loses their captured sessions.

7. **The `c11 conversation` CLI surface adds 6 new commands without discussing security/quoting.** Two of them accept `--payload <json>`. Shell-quoting JSON in bash is a known footgun for hook authors. The reference wrapper handles `HOOKS_JSON` carefully (separate file path argument, etc.); the plan does not say whether `--payload` accepts a path-or-inline argument or only inline. If only inline, expect the same hook-quoting complaint that drove the `HOOKS_FILE` workaround in `Resources/bin/claude` to recur.

8. **Tests are listed but the failure-mode matrix is not directly mapped to them.** §Testing lists unit tests per strategy, state machine, crash recovery, and a manual QA matrix. But the §Failure modes table has eight rows. There should be one test per row in that table. Right now the testing section is a generic "we'll test the things"; tying it to the failure table would close the loop and give the implementer a literal checklist.

## Alternatives Considered

The plan's §Alternatives section already covers A (harden current pattern), B (PTY hibernation), and D (operator checkpoints). It is missing C, presumably an oversight. Beyond filling that gap, here are the alternatives I would have expected named at major decision points:

**At "store mutability" (chose: stateful store with provenance):**
- *Alternative:* Event-sourced log (append-only, fold-on-read). Better for debuggability and history as a free fallout, worse for v1 simplicity. Plan's choice is correct for v1; reconsider at v3.

**At "strategy interface shape" (chose: two pure functions):**
- *Alternative:* Strategy as protocol with N hook methods (`onSessionStart`, `onSessionEnd`, `onScrapeTick`, `onResume`). More extensible, more boilerplate, encourages strategies to carry state. Plan's choice is right for stateless interpretation.

**At "snapshot integration" (chose: embed `surface_conversations` in workspace snapshot):**
- *Alternative:* Separate `~/.c11/conversations/<surface_uuid>.json` files per surface. Decouples conversation lifecycle from snapshot lifecycle (nice — a conversation could survive a snapshot delete). But makes restore atomicity harder (snapshot says "this surface exists" but per-file may be missing or stale). Plan's choice is right; the snapshot is the invariant the rest of the codebase relies on.

**At "global derived index" (chose: in-memory v1):**
- *Alternative:* Persistent SQLite or JSON index with fsync. Faster cold-start, durable across c11 launches, queryable. Premature given there is no UI consuming it yet. Plan's choice is correct; do not build storage you have no reader for.

**At "wrapper claim primitive" (chose: separate `claim` CLI command):**
- *Alternative:* Reuse `set-agent --type` to also write a placeholder claim. Fewer commands, conceptually muddier (`set-agent` already does too much). Plan's choice is right; explicit is better than overloaded.

**At "marker file for clean shutdown" (chose: `~/.c11/runtime/shutdown_clean`):**
- *Alternative 1:* Sentinel inside the snapshot file itself (a `clean_shutdown: true` flag). Self-contained but requires writing the snapshot *twice* per quit (once with flag false during quit, once with flag true at end), which doubles the I/O cost on a hot path.
- *Alternative 2:* No marker; assume any unread snapshot is clean, anything mid-write is dirty. Relies on filesystem rename atomicity, which APFS gives. Simpler. The plan's chosen marker is fine but the alternatives should be acknowledged in open question 6.

**At "ResumeAction shape" (chose: enum with five cases):**
- *Alternative:* A single `(argv, env, postType?)` triple. Less expressive (no `composite`), but covers 90% of cases without the `replayPTY` and `composite` cases that no v1 strategy emits. The plan flags this in open question 8. I would lean ship the smaller shape, add cases when a strategy needs them.

## Readiness Verdict

**Ready to execute, with answers to the open questions and the additional questions below.** The plan does not need rethinking — the architecture is the right one. It does not need revision in shape — the decomposition is correct. It needs:

1. Answers to the 12 open questions the author already wrote down (most of which are decisions, not investigations).
2. Decisions on the four additional gaps named in §Weaknesses 1, 4, 5, 6 (`isTerminatingApp` query path, `shutdown_clean` edge cases, concurrency primitive choice, snapshot version-skew).
3. A picked rollout option from the three named in §Is This the Move? (current implication is option 3, but it should be explicit).
4. The pull-scrape directory-watching cost story (bounded strategy, not "stat the directory").

None of those is hard. None of those needs another full plan-review cycle. They are the kind of decisions a single author can resolve in a focused afternoon. After that, it is ready.

If those are not addressed, the verdict shifts to *Needs Revision* — not because the plan is wrong, but because the impl will hit those questions in week 1 and stall waiting for the answers.

## Questions for the Plan Author

These augment the 12 open questions already in §Open questions for plan review.

13. **Rollout choice — which option?** Pick explicitly: (a) ship 0.44.0 with the C11-24 hotfix, conversation-store in 0.45.0; (b) pull C11-24 from 0.44.0, ship 0.44.0 without resume, conversation-store in 0.45.0; (c) hold 0.44.0 until conversation-store is ready and ship them together. The plan currently implies (c) but is not explicit. (c) is the highest-risk option; (a) is the lowest. Which is it?

14. **`isTerminatingApp` query path under shutdown stress.** When the SessionEnd hook fires *during* c11's shutdown sequence and the CLI tombstone command tries to query `system.is_terminating` over the socket, what is the policy if the socket is already torn down or hung? Default to "not terminating" (recreates the bug)? Default to "terminating" (loses legitimate `/exit` tombstones)? Wait with timeout and assume? This needs a concrete answer before impl, because it is the keystone of the architecture.

15. **Pull-scrape directory bound.** What is the cap on directory scan size? The current `~/.claude/sessions/` and `~/.codex/sessions/` accumulate forever; after a few months, "find the most-recently-modified" is a full sort over thousands of files. Cap at most-recent N by mtime? Use filename-as-id (UUID is in the filename) and skip the file content read? Bound it now, before it bites someone.

16. **Snapshot version-skew during pre-release.** Builds during the cutover will load snapshots written by older pre-release builds containing `claude.session_id` in surface metadata. Is there a one-time read-side migration that lifts that key into the conversation store? Or do operators lose captured sessions across the cutover? Atin tests across builds; this matters.

17. **Wrapper-claim placeholder recognition.** How does a strategy distinguish "this id is a placeholder waiting for scrape to fill it in" from "this id is real, leave it alone"? The proposed `<surface-uuid>:<launch-ts>` format has no explicit marker. A `placeholder: true` boolean on the ref, or a `placeholder:` prefix on the id, or a dedicated state distinct from `unknown`?

18. **Concurrency primitive: serial queue or actor?** Open question 11 lists both as options. Pick one before impl. My recommendation: serial dispatch queue + `async` accessors for v1 (compatible with existing socket handler shape), with an actor migration as a future cleanup. But the plan should pick.

19. **Failure-mode table → test matrix.** §Failure modes lists eight rows. §Testing lists generic categories. Should there be a one-test-per-row mapping? A `ConversationStoreFailureModeTests.swift` with `testHookFiresAfterShutdownBegins`, `testHookEnvStripsCmuxSurfaceId`, `testTuiCrashesBeforeHookFires`, etc.? The matrix exists; tying tests to it directly would close the loop.

20. **`history: []` on disk — empty array or omit?** Open question 7 asks. Lean: empty array. Reason: makes `--json` output stable across v1/v2, no special-casing in tooling that consumes the output.

21. **Wrapper PATH gating on `CMUX_DISABLE_AGENT_RESTART=1`.** Open question 9 asks should the wrapper short-circuit. Lean: yes, the wrapper-claim should bail when the env var disables restart, because otherwise the store fills with claims that will never be resumed. Symmetry with the policy. But pick.

22. **Strategy missing → silent skip or visible failure?** Open question 4 asks. Lean: skip with `Diagnostics.log` (proposal in plan is correct), plus a sidebar advisory "1 surface skipped: unknown agent kind" so operators know a missing strategy is the cause. Silent skip with no operator-visible signal is the wrong end of the trade.

23. **Codex tombstone heuristic — opt-in or skip?** Open question 2 asks about reading codex session-file `last_message_role` to detect "session looked complete." Lean: skip for v1, ship the simple "absent-on-restore = tombstone" rule, file as v1.x improvement. Heuristic-based tombstoning is the kind of thing that goes wrong silently (e.g., a session that ended with an assistant message but the user wanted to keep going). Better to never auto-tombstone codex than to auto-tombstone wrong.

24. **`ResumeAction.replayPTY` and `.composite`.** Open question 8 asks if `replayPTY` is premature. Both `replayPTY` and `composite` have no v1 use case. Lean: ship the four cases that v1 uses (`typeCommand`, `launchProcess`, `skip`) plus `composite` for future-proofing one-off batches. Skip `replayPTY` until something needs it. Smaller surface = less to maintain.

25. **`c11 conversation push --payload <json>` — inline only, or path-or-inline?** Path-or-inline (matching the `HOOKS_FILE` pattern in `Resources/bin/claude`) avoids hook-author quoting hell. Inline-only is simpler. Pick.

26. **Multi-c11-instance shutdown_clean marker collisions.** If a second c11 instance launches (dev build alongside release, multi-account), they share `~/.c11/runtime/shutdown_clean`. Is this acceptable (rare, both crash → both do recovery, fine), or should the marker be keyed per-bundle-id (`~/.c11/runtime/shutdown_clean.<bundle_id>`)? Lean: per-bundle-id is two more characters and removes the edge case.

27. **`claim` CLI: idempotent or write-once?** If the wrapper restarts (operator typed `claude` twice in the same surface), does the second `claim` overwrite the first ref's id, leave the existing one, or both? The plan's reconciliation rule (latest `capturedAt` wins) implies overwrite, but for `wrapperClaim` source the new claim might be *less* informative than the existing scrape-confirmed ref. Pick: claim only writes if the existing ref is older AND of equal-or-lower provenance.

28. **Skill update — when?** The c11 skill at `skills/c11/SKILL.md` documents the wrapper pattern as the resume mechanism. The CLAUDE.md philosophy section codifies it. Both need updates when this lands. Plan does not mention the skill. Per the c11 CLAUDE.md "the skill is the agent's steering wheel" principle, the skill update is part of the work, not a follow-up. Confirm it lands in the same change.

29. **The codex `cwd-filter` claim in the existing wrapper still holds — verify.** The codex wrapper comment at `Resources/bin/codex:13-21` claims `codex resume --last` filters by cwd. The plan asserts this remains the per-pane resume mechanism in the codex strategy. Has this been verified against codex 0.124+, or is it inherited assumption? If wrong, the codex multi-pane "last wins" bug the plan exists to fix is not actually fixed by `codex resume <session-id>` either, since the strategy's pull-scrape ALSO filters by cwd. Verify before impl.

30. **Where does the conversation store live in code?** The plan names files for change but does not say where the new `ConversationStore` Swift file lives. `Sources/ConversationStore.swift`? `Sources/Conversation/Store.swift` with a folder? `Sources/AgentRestart/` (renamed)? Naming up front avoids a churn-y move during impl.

---

Tone note for the author: I am genuinely impressed by this plan. The combination of "look at what failed in QA," "diagnose the structural reason," "design the smallest primitive that makes the failure structurally impossible," and "write the open questions you already know you need answered" is the shape of mature systems work. The 30 questions in this review are a mark of how much the plan invites engagement, not how flawed it is. Land it.
