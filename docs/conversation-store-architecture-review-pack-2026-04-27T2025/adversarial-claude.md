# Adversarial Plan Review — conversation-store-architecture (Claude)

**Plan:** `/Users/atin/Projects/Stage11/code/c11/docs/conversation-store-architecture.md`
**Reviewer model:** Claude (Opus 4.7)
**Mode:** Adversarial — designated opposition. The Standard review handles balance.
**Date:** 2026-04-27 20:25

---

## Executive Summary

This plan is the right *direction* but the wrong *moment*. The core insight — that the wrapper-only pattern cannot capture what TUIs do not expose, and that capture-clear-on-the-same-hook is structurally broken — is correct and worth investing in. But this proposal is being floated *as a blocker for 0.44.0's release*, replacing a hotfix (#89) that has already shipped opt-in in 0.43.0 and is converging in 0.44.0-pre. That framing is the single biggest issue.

The plan reads like an architecture document written in the first 24 hours of discovering a class of bug. It enumerates strategy interfaces, state machines, schema fields, snapshot integration, history support, remote/cloud forward-compat, and a global derived index — for a v1 that ships *zero* user-facing features beyond what the existing C11-24 hot-fix already does for Claude Code, and *less* than what the hot-fix does for codex (which the plan honestly admits cannot tombstone autonomously). The cost of the architecture is paid up-front; the value lands "later" across optional v1.x and v2 features that this document explicitly says are out of scope.

The three observed bugs (codex last-wins, Claude blank restore, opencode/kimi don't resume) have far cheaper fixes than this rewrite. The plan's own "Approach A: Harden the current pattern" section dismisses the cheap fixes in two sentences without quantifying them. Rejecting Approach A by saying "we would re-confront the structural problems with the next TUI integration" is exactly the kind of sentence that gets written when an engineer has already decided to do the bigger thing — it's not an argument, it's a declaration of preference. The real question is: what's the actual rate of new TUI integrations, and is it high enough to justify paying the architecture cost now versus when the next two integrations actually arrive?

The architecture itself has multiple unresolved details (12 explicit open questions, plus several invisible ones — see below). It binds itself to a release window (0.44.0 marquee feature) before those questions are answered. That's the textbook setup for "scope creep eats a release" or "we shipped a half-built abstraction and now we're stuck with it."

**Recommended posture:** be very suspicious of letting this displace 0.44.0. If the operator wants the architecture, build it on a parallel branch behind a flag, ship 0.44.0 on the hot-fix, validate the architecture in 0.45.0+ with real evidence (number of TUI integrations, real reconciliation cases, real remote-agent demand), and only then promote it to default. The plan as written conflates "fixing today's bugs" with "preparing for tomorrow's primitives" and pays for both with one release window's worth of risk.

---

## How Plans Like This Fail

This is a **"strategy/registry refactor"** plan — extract per-thing-X behaviour from inline branching into a polymorphic interface, plus a store, plus a state machine. The failure modes for this category are well-trodden:

1. **The abstraction fits today's two cases (Claude, codex) and breaks on case three.** The proposal already concedes this in subtle ways: opencode and kimi capture is "TBD at impl — needs reverse engineering." The ResumeAction enum is suspiciously well-suited to the current TUI behaviours; `replayPTY` exists with no current consumer (open question 8). Strategies are described as "pure given inputs" with "stateless" calls — but reconciliation across push/pull/wrapperClaim with provenance and timestamp tiebreaking happens *somewhere*, and that somewhere is the store, which is now stateful and concurrent (open question 11). The typical outcome: a future TUI doesn't fit the model, the store grows special cases, and within two years the codebase has both the strategy abstraction *and* the per-TUI branching — paying for both at every site.

2. **The state machine looks tidy on the diagram and is a swamp in practice.** Five states (none/unknown/alive/suspended/tombstoned), plus the `isTerminatingApp` gate, plus crash recovery transitions, plus per-strategy interpretation of "absent-on-restore = tombstone" (codex) versus "absent-on-restore = scrape" (Claude). Every transition crossed with every TUI is a test case. The "Manual QA matrix" mentions a "4-pane Claude/Codex test." Try drawing the *full* matrix: 5 states × 4 TUIs × {clean shutdown, crash, sleep, hook-fires-late, hook-fires-never, env-strip, file-deleted-out-of-band, two-panes-same-cwd, …} — the cross product is large and most cells will go untested.

3. **"We do not ship a regression test for the bug observed today; we ship the architecture that makes the bug structurally impossible."** This sentence (line 343 of the plan) is a red flag. Every architecture-replaces-test argument that has ever been made has been wrong some non-trivial fraction of the time, because the architecture itself has bugs and the regression test would have caught them. The bug observed today is **specific, reproducible, and cheap to encode as a fixture-driven test.** Refusing to write that test on principle, then betting the architecture is bug-free, is the kind of self-confidence that ages poorly.

4. **The "primitive" framing inflates scope.** Calling it a `Conversation` primitive (capitalized, first-class, owned by c11, decoupled from process lifecycle) sounds important. But what it *does* in v1 is: store a (kind, id) tuple per surface, persist it, replay a synthesised command on restore. That's exactly what `claude.session_id` reserved metadata + `AgentRestartRegistry` already do. The primitive framing earns its weight only when the v1.x/v2 features (history, cloud, cross-machine, blueprints-with-pinned-conversations) actually ship. If those features are 12-24 months out — or never — we paid for a primitive and got a `Dictionary<SurfaceID, (String, String)>` with extra steps.

5. **Open questions piled at the end of the plan.** Twelve open questions in the "Open questions for plan review" section. Five of them touch load-bearing decisions (cadence, tombstone determination, hook payload routing, strategy resolution at restore, concurrency model). Plans that ship 12 open questions through plan-review and then enter implementation are plans where 8 of those 12 become "decisions made by the implementer at 11pm" without re-circulating to review. Half will be wrong; the other half will lock in defaults that nobody re-evaluates for years.

6. **Snapshot schema migration framed as "no migration."** The plan says "Pre-release software. The existing `claude.session_id` reserved key in surface metadata is dropped." But the C11-24 hot-fix has shipped opt-in in 0.43.0 and default-on in 0.44.0-pre. Operators who turned on `agentRestartOnRestoreEnabled` already have snapshots with `claude.session_id` baked into surface metadata. "Read once for backward-compat at v1.0 launch (one release window) and dropped" is a migration; calling it "no migration" obscures that there's read-side compat code to write, test, and then later remove — three follow-up commits hidden behind one bullet. Pre-release software does not mean "free to break the wire format"; it means "free to break the wire format if you accept that everyone with an in-flight snapshot has to do work."

---

## Assumption Audit

### Load-bearing assumptions (the plan collapses without these)

1. **Pull-scrape is reliable enough to be the "primary source on death."** The plan leans on pull-scrape at every autosave tick, at quit, and at crash recovery as the safety net. This requires:
   - Each TUI's session storage layout is documented or reverse-engineerable (Claude: yes, ~/.claude/sessions/; codex: yes, ~/.codex/sessions/*.jsonl; opencode/kimi: explicitly TBD).
   - Each TUI writes its session file *before* a hook would fire / before c11 quits / before the TUI process dies.
   - Each TUI's session file format is stable across versions.
   - Filtering by cwd + mtime resolves correctly in degenerate cases (two TUIs of the same kind in the same cwd; clock skew; filesystem mtime granularity).
   **Likelihood it holds:** Medium. Claude and codex hold it today. Opencode and kimi explicitly do not — the plan ships fresh-launch-only for those, which is the same as the current state. So the "decoupled-from-process" magic is not magic for two of four current TUIs.

2. **TUI vendors will not break their on-disk session formats.** Pull-scrape is a contract with a private format that c11 doesn't own. Claude Code 2.1.119 changed `--settings` semantics (inline JSON silently dropped — see the wrapper comment lines 153–175). Anthropic, OpenAI/codex, and the opencode/kimi maintainers can move their session storage at any time. The architecture privileges pull-scrape *over* push, meaning a vendor change to session storage breaks resume even when the hook still works. Today's wrapper-only pattern is more resilient to format changes because it doesn't read the format.

3. **The 2.5s `agentRestartDelay` survives across all surface types and all hardware.** Inherited from the existing implementation. The plan assumes shells are ready 2.5s after restore. Cold-boot Macs, slow disks, network home directories, Filevault decrypt cycles all violate this. The current hot-fix has the same issue; the new architecture inherits it without addressing.

4. **`isTerminatingApp` is queryable from the CLI process via a socket call.** Open question 12 in the plan. If the answer turns out to be "we'd need a new socket method, and synchronous queries during shutdown are racy," the SessionEnd-clears-on-quit fix gets harder. The plan posits a `system.is_terminating` method without checking whether the socket is still serving requests during `applicationShouldTerminate`. (It probably is, briefly, but this is exactly the kind of detail where "probably" turns into a flake.)

5. **A surface hosts at most one *active* Conversation at a time (v1).** Stated explicitly. This holds for all current TUIs. It will not hold for orchestrator agents that spawn sub-conversations, multi-tab Claude sessions in one terminal, or any case where the operator runs `claude` then `/exit` then `claude` again in the same surface. The plan handles this by overwriting the active ref and (eventually) appending to history. Fine for now. Document it as a known limit.

6. **Strategy code is small enough to be "pure given inputs."** Listed as a property: "Both [capture and resume] are pure given their inputs. The strategy is stateless." But the strategy reads filesystem state (pull-scrape), which is by definition stateful, side-effecting, and time-dependent. The plan's own description of pull-scrape ("`stat` the directory, find the most-recently-modified session matching this surface's filter") is impure. This is a minor framing issue but it suggests the author hasn't fully thought through where the impurity lives — which matters for testability and concurrency.

7. **The wrapper-claim placeholder id is recognisable as a placeholder by the strategy.** Open question 5. If pull-scrape can't tell "this is still a placeholder, replace it" from "this is a real id that just happens to look like a UUID," reconciliation breaks silently. Format: `<surface-uuid>:<launch-ts>`. Real ids: opaque per-TUI. Probably distinguishable in practice but the plan doesn't enforce it.

### Cosmetic assumptions (worth flagging but won't sink the plan)

8. The `ResumeAction` enum covers all current and near-future cases. (`replayPTY` has no consumer; `composite` is YAGNI-flavoured.)
9. Snapshot file format can grow a `surface_conversations` field without breaking older readers. (Probably true since snapshots are JSON and Codable defaults handle missing fields, but worth verifying.)
10. The blueprint schema doesn't need to change. (True today; "blueprints with pinned conversations" is explicitly v2+.)
11. The `ConversationStrategyRegistry` being a hardcoded enum-shaped struct is actually a feature. (It is, for now. Becomes a problem the day someone wants to ship a strategy from a plugin or third-party.)

### Invisible assumptions (the dangerous ones)

12. **The operator wants to resume conversations at all.** The plan assumes resume is a feature; some operators prefer fresh launches every time, especially for codex where "last wins" is currently breaking what they wanted. The CMUX_DISABLE_AGENT_RESTART flag exists but isn't surfaced as a UI preference.
13. **Resume should happen automatically.** Some operators want to *see the previous conversation* and decide whether to resume. Auto-typing `claude --resume <id>` is a strong opinion that hides the choice.
14. **One conversation per kind per surface is the right model.** Some TUIs let you have multiple conversations in one session (Claude's `/clear` followed by new prompts). The model is "session = conversation" which is approximate, not exact.
15. **Snapshots are the source of truth.** The plan says so explicitly. But a global derived index gets built at launch by scanning all snapshots. If snapshots disagree (workspace A says session X is in surface 1, workspace B says session X is in surface 2 — possible if surfaces were copied between workspaces), the index has to pick one. Resolution rule undefined.
16. **Pull-scrape costs are negligible.** Open question 1. "Lightweight: stat the directory, find the most-recently-modified session…" This is N stats per autosave per TUI per surface. Multiply by the number of surfaces in a workspace and the autosave cadence and it's not free, especially on network filesystems or when the session storage directory has thousands of files (Claude's `~/.claude/sessions/` accumulates).
17. **The `claude-hook` CLI subcommand can be a "thin translator" without losing telemetry breadcrumbs.** Open question 3. The current `runClaudeHook` carries breadcrumb taxonomy that the proposal plans to "route through `conversation push|claim|tombstone`." Telemetry that depended on the existing breadcrumb shape is silently broken.
18. **Agents writing to `c11 conversation push` will not race the snapshot write.** With the snapshot capture path in `applicationShouldTerminate` and the hook subprocess writing concurrently, the same "race" the plan identifies for SessionEnd-clears-metadata can happen for SessionStart-writes-mid-shutdown. The plan doesn't enumerate it.

---

## Blind Spots

### What the plan does not ask

1. **Why is codex's "last wins" actually a bug?** Read the "Two Codex panes opened in the same project, both restored to the most-recent global Codex session ('B')" framing carefully. The codex wrapper currently issues `codex resume --last`, which by codex's own behaviour filters to the *current cwd*. If two panes share a cwd, last-wins is codex's design, not c11's. The plan's solution is to capture per-pane session ids via cwd+mtime filter. But: how often do operators *actually* run two codex panes in the exact same cwd? Once per project, or once per career? If the answer is "once per career," shipping a primitive to fix it is over-engineering.

2. **What happens when the agent's `claude.session_id` UUID has rotated since snapshot?** Claude Code can rotate sessions. If the user typed `/clear` and then continued, the on-disk session changes. The snapshot has the old id. Pull-scrape *should* catch this, but the plan doesn't describe what the user sees: do they get the *most recent* session (probably what they want) or the *snapshotted* session (what was captured)?

3. **Does the wrapper-claim path race the user typing into the terminal?** If the wrapper backgrounds `c11 conversation claim` and the user is fast, the claim can land *after* the first SessionStart hook. Reconciliation by capturedAt timestamp should handle this, but only if clocks are monotonically aligned across processes. (They are, on macOS.) Worth stating.

4. **What does `c11 conversation list --workspace <id>` do during a restore?** The store is being populated *during* restore. A query mid-restore returns partial data. Is that fine? Documented? Tested?

5. **Where does the `shutdown_clean` flag live during a forced power-off mid-write?** The plan says "writes `~/.c11/runtime/shutdown_clean` at the start of `applicationWillTerminate`, deletes it at the end of `applicationDidFinishLaunching`." If the OS dies between "deletes it" being called and the syscall actually completing, the next launch sees the file present and assumes clean shutdown. Marker absence is the only reliable signal; marker presence is ambiguous. The plan inverts this: it treats absence as "we crashed" (which is correct) and presence as "we shut down clean" (which is *probably* correct). The edge case: c11 quits clean, ~/.c11/runtime is on a network drive that was disconnected, the file persists from a previous boot. Unlikely on macOS but the plan doesn't even mention these edge cases.

6. **What happens to running TUIs during `applicationWillTerminate`?** c11 kills terminals. The TUI's session file is in whatever state its last write left it. For codex, sessions are append-only JSONL; the tail is probably consistent. For Claude, the format is internal and the on-disk state mid-write is an Anthropic implementation detail. Pull-scrape on next launch reads whatever's there. If the format is internally inconsistent (half-written turn), the TUI may error on `--resume`. The plan doesn't enumerate this.

7. **What's the threat model?** The plan adds CLI subcommands (`c11 conversation claim|push|tombstone|list|get|clear`) accessible via the c11 socket. Any local process with socket access can manipulate any surface's conversation state. The current claude-hook CLI is similarly exposed but limited. New surface area = new attack surface. Probably fine for a local-only socket, but it's not addressed.

8. **Why is Conversation a Swift primitive rather than a CLI primitive?** The plan describes `Conversation` as "owned by c11," implementing it in Swift, with strategies as Swift functions. But the *capture and resume* surface is the CLI. Why not push more of this into the CLI / shell layer? The Swift in-process model couples the architecture to the macOS app's release cadence; pushing it to the CLI lets agents iterate on strategies without new c11 builds. Open question 11 (actor vs serial dispatch queue) hints at this; it's not just a concurrency-primitive choice but a "where does this code live" choice.

9. **What's the fallback when the strategy registry has no row for `kind`?** Open question 4 mentions this — the proposal leans toward "skip with Diagnostics.log." That's the right answer, but it has a nasty failure mode: a snapshot from a future c11 with a `claude-code-2` strategy gets restored on an older c11. Surface comes back blank. The user has no UI signal that "your snapshot referenced a strategy I don't have." Just silence.

10. **What if pull-scrape returns a session id that matches the snapshot id, but the file was modified at a stale timestamp?** Reconciliation rule is "latest capturedAt wins, with source-priority tiebreaker." But what's the timestamp on a pull-scrape result — the file's mtime or the time the scrape ran? The plan implies the latter (the strategy "produces the current ref from whatever signals are available right now"), which means push-then-pull always pulls newer than push, which makes push effectively dead-letter when scrape runs after.

11. **Cross-workspace conversation reuse.** The global derived index lets future UI "bring back any past claude conversation into a new pane in a fresh workspace." But the conversation is keyed by `(kind, id)`, the surface is keyed by `(workspace_id, surface_id)`. What's the semantics of "moving" a conversation to a new surface? Does the old surface's record clear? Become history? The plan ducks this ("UI to consume it is a later piece"), but the *data model* needs to be settled in v1.

12. **Wrapper's `c11 conversation claim` runs in the background and is `disown`'d.** The codex wrapper today has the same pattern with `set-agent`. If the claim fails (socket dies between `cmux_socket_available` check and the actual call), there's no surface ref. The strategy degrades to pull-scrape only. The plan documents this as "no regression" but it does mean the architecture's only-push-source for hookless TUIs is best-effort. Worth being explicit.

### Stakeholders unaddressed

13. **Operators currently running 0.43.0 opt-in or 0.44.0-pre default-on.** Their snapshots have `claude.session_id` reserved metadata. The plan drops the key from new snapshots. The "read once for backward-compat at v1.0 launch" is one release window of compat code, but the plan doesn't say what happens to operators on slow update cycles. Pre-release framing handles this but it's worth saying.

14. **Sub-agents and headless agents that read surface metadata for status.** Some skills may be reading `claude.session_id` directly today (the codebase ships SurfaceMetadataKeyName.claudeSessionId as a reserved key). Renaming or moving that breaks consumers we don't control.

15. **Future c11 maintainers.** Six months from now, a maintainer wants to ship a fifth TUI. They look at the strategy registry, write a new file with two functions, and… discover that pull-scrape requires understanding the new TUI's session storage format, the wrapper-claim flow, the placeholder id format, the reconciliation rules, and the state machine semantics for "absent-on-restore." The cost-per-new-TUI is *higher* than it is today, not lower, because today they just edit one closure in `AgentRestartRegistry.phase1`.

---

## Challenged Decisions

### "Replace the architecture, not the patch"

The plan opens with this. It's the framing that justifies everything that follows. Counterargument: **this isn't actually a choice between architecture-replace and patch.** The three observed bugs have specific, narrow fixes:

- **Bug 1 (codex last-wins):** wrapper captures the codex session id post-launch via a one-shot `c11 set-metadata` call after watching `~/.codex/sessions/` for new files matching cwd+launch-window. ~50 lines of bash + one new metadata key. Solves it for codex without architecture.
- **Bug 2 (Claude blank restore):** SessionEnd hook checks `isTerminatingApp` via socket and no-ops if true. ~20 lines in the existing hook handler. Solves it.
- **Bug 3 (opencode/kimi don't resume):** they don't have resume flags. *No architecture solves this.* The plan even admits this in the per-TUI strategy section. Resume support requires the TUI vendor to ship a resume mechanism; until then it's fresh launch.

So the architecture solves bug 1 (with significantly more code than a per-wrapper fix), solves bug 2 (with significantly more code than checking `isTerminatingApp` in the existing handler), and does not solve bug 3 (same as patch). The "replace the architecture" framing makes it sound like the patch is broken; it isn't broken, it's just smaller.

### "0.44.0 ships with the conversation-store as its marquee feature."

This is the most aggressive claim in the plan and the easiest to push back on. 0.44.0 is currently in held-PR state (PR #94). It already has 25+ upstream picks ready to ride along. The proposal is to *displace the existing C11-24 implementation* (PR #89, already shipped opt-in in 0.43.0 and default-on in 0.44.0-pre) with a from-scratch architecture before 0.44.0 cuts.

Counterargument: **0.44.0 should ship on the hot-fix.** The hot-fix works for 80% of cases (Claude resume). Codex degrades to last-wins (current behaviour, not a regression). Opencode/kimi don't resume (current behaviour, not a regression). The architecture lands in 0.45.0 or 0.46.0 with proper bake time, real test coverage, and the option to validate that the "primitive" framing actually pays off before committing to it.

Marquee features should ship when they're done. Architectures shipping mid-design-review are how releases slip and quality dips.

### "We do not ship a regression test … we ship the architecture that makes the bug structurally impossible."

This is the single most challengeable sentence in the plan. The bug is reproducible: 4-pane workspace, 2 Claude + 2 codex, quit, relaunch, observe restore. This *is* a test fixture. The architecture itself needs this test even more than the hot-fix did, because the architecture has more moving parts. Refusing to write the test on principle is choosing future regression for current cleanliness.

Counterargument: **write the regression test anyway.** It's a fixture-driven snapshot round-trip with N surfaces, N strategies, N expected ResumeActions. It documents the bug and prevents recurrence. The architecture-makes-it-impossible argument is one a maintainer makes *after* the test passes for two releases, not before the architecture ships.

### "The new design is the only design. … No feature flag for the architecture."

This is bold and risky. The current code has `agentRestartOnRestoreEnabled` and `CMUX_DISABLE_AGENT_RESTART` for a reason: it lets operators opt out when the auto-resume goes wrong. The proposal removes the architecture-level flag — meaning if the new design has bugs in v1.0, there's no kill switch for the conversation store as a concept; only the auto-resume policy can be flipped.

Counterargument: **keep an architecture-level flag for the store itself for one release window.** `CMUX_DISABLE_CONVERSATION_STORE=1` falls back to the old `claude.session_id` reserved-metadata path. Removed in v1.1 once the store has bake time. Yes, that means double-maintaining for one release. That's the cost of caution on a new primitive.

### "Pull-scrape primary on death; push primary in life."

This is a clean line on paper. In practice it splits the truth source by lifecycle phase, which makes debugging hard ("why does the surface have an id different from what I just pushed via the hook?" — answer: because crash-recovery ran a forced scrape on relaunch and the file moved). Counterargument: **pick one primary, document that the other is corroborating evidence.** Current proposal: any time you see a discrepancy, you have to walk the provenance graph to figure out which signal won and why.

### Strategy as a hardcoded enum-shaped struct

"The `ConversationStrategyRegistry` is a hardcoded enum-shaped struct; we are not building a plugin system." Defensible for v1 — but then why is the strategy interface so polymorphic (`capture`, `resume`, `ResumeAction.composite`, etc.)? If you're not going to ship a plugin system, *don't ship the polymorphic interface that plugins would want.* Keep a fat switch statement. The plan has the abstraction-without-the-extensibility shape, which is the worst of both worlds.

### Missing decision: snapshot vs sidecar storage

Conversation refs land in the workspace snapshot. They could equally have lived in a sidecar file (`~/.c11-snapshots/<workspace>/conversations.json`). Sidecar would let the snapshot stay schema-stable for things that change less often (layout, panels) and the conversation file iterate independently. The plan doesn't consider this; it folds conversations into the existing snapshot, which is the easiest thing but binds conversation-store evolution to snapshot-format evolution. Worth interrogating.

---

## Hindsight Preview

Things we'd say in 18 months looking back:

1. **"We should have just fixed the SessionEnd race."** It's 20 lines of code. We'd have shipped 0.44.0 on time, kept the hot-fix architecture for 6 more months, watched whether opencode/kimi/future-TUI integration *actually* hit the structural problems the plan predicted, and only then invested in the primitive. Instead we paid the architecture cost up front and the value tail was longer than expected.

2. **"`replayPTY` never had a consumer."** It was added to the ResumeAction enum because someone thought it might. It sat there for 18 months. We added a swift compiler warning to detect unused enum cases and finally deleted it.

3. **"The pull-scrape cadence was wrong."** Open question 1 wasn't answered before impl, so the implementer picked "every autosave tick (~30s)." Operators with 20 surfaces in a workspace saw battery drain. We changed it to "on push + at quit" and the resume reliability dropped. Eventually we landed on "every autosave but only if a hook hasn't fired in N seconds."

4. **"The wrapper-claim placeholder id format was a mistake."** It looked like a UUID enough to confuse pull-scrape into not replacing it. We had to add a magic prefix. The prefix conflicted with future TUI session ids. Three releases of patches.

5. **"`isTerminatingApp` queried over the socket was racy."** During app shutdown, the socket is sometimes still serving and sometimes not. The hook tried to query it and got "connection refused" half the time, so it conservatively defaulted to "tombstone anyway," which re-introduced the original bug for ~5% of shutdowns.

6. **"The architecture didn't actually help with opencode."** When opencode shipped a resume mechanism, integrating it required a whole new strategy, a new state machine extension (their resume is async and returns a future), and reconciliation rules that didn't fit the model. We ended up special-casing opencode in three places.

7. **"The `Conversation` primitive's history field was never used."** v1.x and v2 features ("show me past conversations") didn't ship — the operator never asked. We carried the schema field for two years and finally removed it.

### Early warning signs the plan should watch for

The plan does not list early-warning signs. It should. Examples:

- **Pull-scrape returning empty results for >5% of restores** → the cwd-filter assumption is broken or session storage paths drifted.
- **Reconciliation provenance showing wrapperClaim winning over hook** → wrapper is racing the hook, contrary to the priority order.
- **`unknown → tombstoned` transitions on >X% of crash recoveries** → pull-scrape is missing files, possibly because TUI didn't flush in time.
- **`Diagnostics.log("conversation.resume.skipped")` rate** → strategies are routinely skipping; users are silently not getting resumes.

Add these before implementation, not after.

---

## Reality Stress Test

Three most-likely disruptions:

### 1. Claude Code 2.x ships a breaking change to SessionEnd or `--settings` semantics

Claude Code has been moving fast; the wrapper already documents that 2.1.119 silently drops inline `--settings` JSON. If 2.2 changes hook payload shape, removes SessionEnd, or renames session_id, the push path for the Claude strategy breaks. The plan's defense: pull-scrape from `~/.claude/sessions/`. But Anthropic also owns that storage layout; they could change it in the same release. The architecture's "decoupled from the TUI process" claim doesn't hold when the TUI vendor controls *both* the hook surface and the on-disk format.

**Impact when it hits this plan:** Claude resume breaks for the new Claude version until a strategy update ships. Same as today. The architecture didn't help.

### 2. Operator priorities shift away from session resume entirely

Resume is expensive scaffolding for a feature whose actual user demand is unmeasured. If the operator decides "actually I just want fresh launches and a UI to bring back conversations on demand" (the v1.x/v2 thing the plan mentions but doesn't ship), the auto-resume path becomes deadweight and the architecture's whole point — the primitive — becomes a `Dictionary<SurfaceID, Ref>` with a serialized format.

**Impact when it hits this plan:** We shipped a primitive, paid the maintenance tax, and the user-facing payoff was a feature operators didn't actually want.

### 3. A second engineer joins the c11 team and pushes back on the architecture

Today the operator is the primary engineer. Plan-review is happening with model agents. If a second human engineer joins in the next 6 months and reads this plan, they may push back hard on the abstraction's complexity-versus-value ratio, propose simpler alternatives, and the team ends up doing v2-of-v1 before v1 has shipped to anyone. Architecture decisions made by one person tend to revisit when more people enter the room.

**Impact when it hits this plan:** The architecture rewrite stretches across multiple releases as the team converges. 0.44.0 either ships on hot-fix anyway, or 0.44.0 slips.

### All three at once

Operator reads a vendor announcement (#1), reconsiders priorities (#2), and a new engineer arrives mid-disagreement (#3). The 0.44.0 marquee-feature framing collapses; the architecture is half-built; the hot-fix has been deprecated in the proposal but not yet removed in code. Worst-case: a release ships with both code paths half-wired and neither working reliably. This is the failure scenario for any "replace not patch" plan that commits to a release window before the architecture is done.

---

## The Uncomfortable Truths

1. **This plan is more interesting to write than it is necessary to ship.** The primitive framing, the strategy interface, the state machine diagram, the snapshot integration — these are fun engineering. The actual user-visible delta in v1 over the hot-fix is "codex resumes the right session in the multi-pane case" and "Claude doesn't blank-restore on quit-during-shutdown." Both of those have 20-50 line fixes.

2. **The plan is a rationalisation of a hot-fix that didn't work cleanly.** PR #89 shipped the C11-24 hot-fix; the bugs surfaced in 0.44.0 staging QA; instead of patching the hot-fix, the plan proposes throwing it out. Sometimes that's the right call; sometimes it's the engineer's frustration with a fragile patch finding architectural justification for a do-over. Worth asking which.

3. **The "open questions for plan review" section at the end is large.** Twelve questions, several load-bearing. Plans that enter implementation with this many unresolved questions bleed scope. The plan acknowledges this implicitly by labelling the questions "calls I want pressure-tested before implementation starts" — but the schedule (0.44.0 marquee) doesn't leave room for serious pressure-testing.

4. **The "no migration" framing is technically true but misleading.** Pre-release software, fine — but the C11-24 hot-fix is in operator hands today. Operators don't want to lose their snapshots even if the software is pre-release. The compat-read-once strategy is fine; calling it "no migration" hides the cost.

5. **The plan lacks a "what does v1 *not* do" section that's honest.** The "Out of scope" section lists big things (cloud, history UI, plugin system) but doesn't list the small things (e.g., no UI to *inspect* conversation state — only `c11 conversation list/get` CLI; no UI to manually re-resume a tombstoned conversation; no operator notification when a strategy skips). The user-visible v1 is *less* than the hot-fix in some ways (the hot-fix doesn't tombstone autonomously and so always tries to resume, which is sometimes what the user wants).

6. **"The skill is the agent's steering wheel" is c11's stated design principle, and this plan doesn't talk about the skill at all.** No mention of what the c11 skill needs to learn so agents can drive the new CLI surface. New CLI subcommands (`c11 conversation claim|push|tombstone|list|get|clear`) mean new skill surface. The CLAUDE.md says "every change to the CLI, socket protocol, metadata schema, or surface model is incomplete until the skill is updated to match." The plan ignores this.

7. **The plan ignores the cmux upstream relationship.** c11's CLAUDE.md is explicit that bidirectional contributions matter. If session-resume is a primitive, is *cmux* getting it too? Or is c11 forking further from the upstream lineage? The plan doesn't say. If this primitive lives only in c11, the divergence cost on future cmux merges grows. If it should land in cmux, the plan should say so and propose a path.

8. **"We are not building a plugin system" + "future kinds: a new kind is one Swift file" is contradictory in spirit.** Either the strategy interface is a plugin contract or it's an implementation detail. The plan wants both, which means new TUI strategies will keep landing as PRs against c11 itself, gated on c11 release cadence.

---

## Hard Questions for the Plan Author

(Numbered, blunt. "We don't know" answers flagged.)

1. **What is the actual rate of new TUI integrations expected over the next 12 months?** If it's 2-3, the architecture pays off slowly. If it's 8-10, it pays off fast. **Likely answer: "we don't know, but probably 2-4 over a year" — which makes the architecture cost-benefit borderline.**

2. **Why is this the 0.44.0 marquee feature instead of a 0.45.0 / 0.46.0 ship?** What forces the architecture into 0.44.0's window?

3. **What concrete evidence do you have that "we'd re-confront the structural problems with the next TUI integration"?** Has anyone tried adding a new TUI to the current pattern and found it painful, or is this anticipated pain?

4. **Why no regression test for the bug observed today?** "The architecture makes it impossible" is not an answer that ages well. What specifically prevents a future regression in the strategy registry from reintroducing a last-wins-in-cwd bug for a kind we haven't added yet?

5. **Open question 1 (pull-scrape cadence): what is the actual I/O cost?** Has anyone measured? If not, what's the plan to measure before shipping? **"We don't know" is a problem.**

6. **Open question 2 (tombstone determination for hookless TUIs): is "absent-on-restore = tombstone" actually correct?** A user who quits c11 mid-session, then opens another tool that touches the codex session file (e.g., codex CLI directly), comes back to c11 and the session file is technically present but in an unexpected state. Tombstone? Resume? Skip?

7. **Open question 4 (unknown strategy at restore): how does the user discover their snapshot referenced a strategy that doesn't exist?** Silent skip means silent data loss as far as the user perceives.

8. **Open question 11 (concurrency model): actor or serial dispatch queue?** Decide before implementation. The choice constrains the API shape (sync vs async accessors).

9. **Open question 12 (`isTerminatingApp` query): does the c11 socket reliably serve requests during `applicationShouldTerminate`?** **"We don't know" is a problem — verify with a test before shipping.**

10. **What's the migration story for operators with 0.44.0-pre snapshots containing `claude.session_id` reserved metadata?** "Read once for backward-compat at v1.0" is one release window — what's *one*? Is it 0.45.0? 1.0.0? The plan is hand-wavy.

11. **What does the c11 skill need to learn for agents to use the new CLI surface?** The skill is the contract; the plan doesn't update it.

12. **Does cmux upstream want this primitive?** If yes, what's the path? If no, why not — and what does this mean for future merge conflicts on shared code?

13. **What metric will tell us the architecture is paying off?** Number of TUIs successfully integrated? Reduction in resume-failure reports? Add-time per new strategy? **Define this before implementation; otherwise we won't know if it worked.**

14. **What happens to PR #89 and the `claude.session_id` metadata key in code?** The hot-fix is in operator hands. The new design drops the key. When is the key removed from `Sources/WorkspaceMetadataKeys.swift`? When is the SurfaceMetadataStore reserved-key validation removed? When is `AgentRestartRegistry` deleted?

15. **Why no architecture-level kill switch (`CMUX_DISABLE_CONVERSATION_STORE=1`)?** What's the rollback story if v1 ships and breaks resume worse than the hot-fix?

16. **What's the test story for crash recovery?** The plan says "simulate missing `shutdown_clean` flag" — that tests the marker logic. It does not test "real crash mid-session, real on-disk session state, real reconciliation." How is that exercised?

17. **What's the worst real-world scenario for "two strategies disagree about a ref"?** Push from hook says id A; pull-scrape on next autosave returns id B. capturedAt tiebreaker picks B. User submitted prompts in id A and now resumes id B losing context. Is this possible? How is it detected?

18. **What does the codex strategy do when `~/.codex/sessions/*.jsonl` has multiple files matching the cwd+mtime filter?** Is the filter strict enough to be unique? What's the tiebreaker?

19. **How does the plan handle a TUI that ships its own session-resume hook *after* c11 has built a custom strategy for it (via wrapper-claim + pull-scrape)?** Migration of existing surfaces from "wrapperClaim id format" to "real id from new hook"?

20. **Does the operator actually want this?** The plan was triggered by 3 bugs in QA. It proposes a primitive. Has anyone confirmed the operator wants the primitive — including the v1.x/v2 features it enables — or are we building scaffolding for a future the operator hasn't asked for yet?

---

## What I would do instead

For completeness, the alternative path:

1. **Ship 0.44.0 on the hot-fix.** Land the SessionEnd-on-quit fix (20 lines: check `isTerminatingApp` in `c11 claude-hook session-end`). Land a codex per-pane session capture (50-line bash addition to the codex wrapper, watching `~/.codex/sessions/` for new files matching cwd+window, calling `c11 set-metadata codex.session_id <id>`). Ship.

2. **Open a 0.45.0+ design exploration for the conversation primitive.** Write the architecture doc. Get plan review. *Build a prototype on a parallel branch.* Validate against a 4th TUI (whichever is next) before merging.

3. **Promote the primitive to default in 0.46.0 or 0.47.0.** With real test coverage, real bake time, and the option to compare against the hot-fix in production.

This is slower. It's also how primitives that don't backfire actually ship.

---

**End of review.** This is a read-only review; no other files were modified.
