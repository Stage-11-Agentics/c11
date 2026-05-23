# Adversarial Review Synthesis — C11-104 Plan

**Plan:** C11-104 (Surface worktree + branch as derived canonical metadata chips in the sidebar)
**Mode:** Adversarial / Critical synthesis (read-only)
**Sources:** 2 of 3 planned reviews
**Timestamp:** 2026-05-18T22:28

---

## Coverage Notice (read this first)

> **The Gemini adversarial review failed (rate-limited / "exhausted capacity on this model"). This synthesis is across 2 models, not the planned 3.** Treat "consensus" below as "agreement between Claude and Codex." Items unique to one reviewer have correspondingly less corroboration than a normal three-model pass would provide. A third independent perspective is not in this record.

Sources synthesized:
1. `adversarial-claude.md` — Claude
2. `adversarial-codex.md` — Codex
3. `adversarial-gemini.md` — **MISSING (rate-limited)**

---

## Executive Summary

Both reviewers agree the user need is real but the plan is **shippable, not bulletproof**. The two single biggest failure vectors that both reviewers independently land on:

1. **The `(cwd, mtime(.git/HEAD))` cache key is wrong for the topology this feature claims to serve.** Linked worktrees, submodules, and gitfiles do not have `.git/HEAD` at the cwd root. Packed-refs, ref reorgs, network filesystems, and coarse mtime granularity break the invariant in both directions (silent staleness *and* spurious misses).
2. **The `derived` metadata tier is bolted into a precedence chain whose semantics were never re-specified.** The plan wants both "derive, don't store" *and* "write into the canonical metadata store with a new source tier." These are in tension. Persistence, socket acceptance, override semantics, and clear-issuance are unspecified.

Beyond those, both reviewers independently identify the same pattern: **the acceptance criteria look rigorous but several are fudge-able as written**, the **typing-latency claim has no runtime assertion**, and **error/timeout behavior for `git` subprocesses is undefined** — in a project whose CLAUDE.md explicitly enumerates typing-latency-sensitive hot paths.

If only the most load-bearing items are addressed before delegation, the short list is: **cache key correctness, `derived` tier semantics, stale-result cancellation, git timeout/budget, submodule + linked-worktree correctness, and a real (non-grep) typing-latency assertion.**

---

## 1. Consensus Risks (Both Models)

Numbered by descending severity. Every item here was raised independently by Claude *and* Codex.

1. **Cache key `(cwd, mtime(.git/HEAD))` is structurally incorrect for the very topologies the feature targets.**
   - Linked worktrees have `.git` as a *file*, not a directory. The real HEAD lives under `<common-dir>/worktrees/<name>/HEAD`.
   - Submodules have `.git` as a gitfile pointing elsewhere.
   - Packed-refs / ref reorgs can change branch resolution without touching `.git/HEAD` mtime.
   - `git gc` can rewrite mtime without changing anything semantic.
   - Network/FUSE/encrypted volumes have coarse mtime granularity (often 1s), enabling back-to-back missed invalidations.
   - Both reviewers recommend resolving via `git rev-parse --git-dir --git-common-dir` and keying against the *resolved* gitdir/worktree admin files, not raw `.git/HEAD` mtime.

2. **`derived` as a new metadata-source tier is under-specified and contradicts "derive, don't store."**
   - Plan says both "ranked between `osc` and `heuristic`" *and* "store nothing, recompute on cwd change." These are incompatible if the value is written through `SurfaceMetadataStore`.
   - Neither reviewer can find an answer to: is `derived` persisted? Accepted over the socket? Override-able? Restorable?
   - The clear-semantics rules are unspecified: when the resolver determines "no longer in git," who issues `clear_metadata` with `source: derived`, and what semantics does that have?
   - The test that `osc > derived` proves the ordering machinery, not the product behavior — `osc` currently writes `title`, not branch/worktree.

3. **No timeout, no concurrency budget, no admission control for `git` subprocesses.**
   - Plan says "off-main" and stops there.
   - Slow disks, FUSE mounts, encrypted volumes, large repos (Linux/chromium scale), and corrupt repos can hang or take hundreds of ms per call.
   - Multiple agents spawning across worktrees (the exact motivating scenario) will fan out into dozens of fork/exec calls in the first second.
   - Codex additionally notes the existing `TabManager` git probe also has no timeout; the new resolver will compound it.

4. **Stale-result writeback is unguarded.**
   - If `cwd` changes A → B while A's resolver is still running, nothing in the plan prevents A from writing chips after B is current.
   - Codex points out `TabManager` already has generation tokens + expected-directory checks for its existing probe. The plan does not specify whether the new resolver reuses that mechanism or invents a parallel one (likely the latter).

5. **Deleted-worktree / vanished-cwd case is unaddressed.**
   - OSC 7 won't fire (no `cd` happened).
   - `stat` on `.git/HEAD` returns ENOENT — cache key undefined.
   - No mechanism specified for invalidation. Chips will silently lie for the rest of the session.
   - Codex extends: this also applies after `git worktree prune` from another pane, or when the gitfile target is removed.

6. **Submodule resolution is partly *wrong* in the spec.**
   - From inside a submodule, `git rev-parse --show-toplevel` returns the submodule top-level, not the superproject. `--show-superproject-working-tree` must be used as the outer path, then branch/worktree resolved from *that* path separately.
   - The plan's command sequence (per Codex) does not correctly derive outer context.
   - Stacked two-row layout answers ergonomics, not edge-case correctness.
   - Nested submodules, detached-HEAD submodules (the normal post-`submodule update` state), and linked-worktree superprojects containing a submodule are unspecified.

7. **The typing-latency acceptance criterion (AC10/AC11) is fudge-able as written.**
   - AC10 = grep for `DispatchQueue.global`. A delegator could wrap a sync `Process` call and pass.
   - AC11 = verify the diff doesn't touch two specific files. A delegator can put the work in adjacent files and pass vacuously.
   - Neither AC is a runtime assertion. The plan needs an actual latency measurement against a tagged build.

8. **Color palette: 8–12 colors, multiple parallel worktrees, collision is *guaranteed* by design.**
   - AC4 ("two different paths produce different colors") cannot hold by birthday-bound math at modest N.
   - Plan delegates resolution to "operator review on PR" without specifying what the operator does about a collision.
   - Both reviewers treat color as **decorative reinforcement** at best, not disambiguation.

9. **Bundling C + D (resolver + color hint) in one PR increases review surface for a feature that's load-bearing on hot-path discipline.**
   - Both reviewers flag the bundling as a higher-risk choice than the original "ship C first" recommendation.
   - Codex frames it as "PR feels complete while resolver flaws hide behind UI polish."
   - Claude notes the *spec recommendation* was overruled on stylistic grounds.

10. **No observability / telemetry for the resolver.**
    - No counter for cache hit/miss, resolver wall-clock, timeouts, stale drops, git failures.
    - Without instrumentation, future latency regressions and stale-chip bugs will be anecdotal only.

11. **Restore window is unspecified.**
    - Workspace snapshot has `gitBranch` (stale). Restore re-derives from `currentDirectory`.
    - What renders in the gap between restore and first OSC 7? Synchronous derive (blocks UI) or asynchronous (chips appear N seconds later)?
    - Two sources of truth coexist during restore.

12. **OSC 7 is the wrong assumption to load-bear on for *this* user population.**
    - OSC 7 is shell-mediated.
    - c11 also accepts `report_pwd` / `report_git_branch` telemetry (Codex's point).
    - TUI agent panes (Claude Code, Codex, kimi) **do not emit OSC 7** unless explicitly wired. These are the primary motivating use case per the ticket.
    - Both reviewers ask: does this feature actually work for the panes it was designed for?

---

## 2. Unique Concerns (One Model Only — Worth Investigating)

### Claude-only

1. **FSEvents was never considered as an alternative to mtime polling.** macOS-native subscribe model would catch external `git checkout` (from Tower/Fork/IDE) that OSC 7 will never see. Plan polls + uses an unspecified "30s coarse interval" instead.
2. **The 30s coarse interval is mentioned once and never specified.** Since last OSC 7? Since last successful resolution? AC12 only tests `.git/HEAD` mtime invalidation, not the coarse interval. The interval is unverified.
3. **Bundle-launched PATH gotcha.** `c11` launches from `/Applications` with minimal PATH. `/usr/bin/git` is present on stock macOS but Homebrew git is not. Which `git` to invoke is unspecified.
4. **Future macOS sandbox / TCC.** If c11 is ever sandboxed (Stage 11 distribution path may push this), `git` invocations against arbitrary cwd require user-granted file access. Unaddressed.
5. **Operator has multiple *clones* of the same repo at different paths** (`manaflow-ai/cmux` and `Stage-11-Agentics/c11` are siblings under `code/`). Both render `worktree: nil` because each is a main checkout. Plan doesn't address whether they should be distinguishable.
6. **Worktree path canonicalization.** Plan says "absolute worktree path" but doesn't define whether that's the symlink-resolved real path or the user-facing path. `git rev-parse --show-toplevel` returns the *real* path. Color stability depends on which one feeds the hash.
7. **Result Validator on / Master Validator off is the inverse of what this feature needs.** A typing-latency-sensitive feature warrants the global CI/PR-queue audit that Master Validator provides; the per-PR fresh-eyes pass that Result provides is less load-bearing here.
8. **PR-author-as-validator antipattern.** Result Validator audits the same PR the delegator wrote. AC11 verifies the diff, not runtime behavior — a delegator wanting green can simply not edit those two files.
9. **The feature might be solving the wrong problem.** Tab-naming is *already mandatory* on agent startup per CLAUDE.md. Agents could include worktree info in self-declared tab titles. The chip system is a workaround for agents not following an existing convention.
10. **Concurrent OSC 7 storms** from `cd a && cd b && cd c && cd a` in rapid succession — five inflight resolutions can stack. No coalescing/debouncing/supersede rule.
11. **Operator changing branches via system git GUI** (Tower, Fork, etc.) emits no OSC 7 and no cwd change. Cache holds. Chips lie until cache TTL expires.
12. **Sidebar real-estate budget.** Two new chips per pane + possible second row for submodules, multiplied by 10+ panes, is substantial vertical density growth. Unaddressed.
13. **Colored dot may collide with the existing status-pill palette.** Both are sidebar visual signal. Visual differentiation requirement is delegated to "operator review on PR" with no spec.
14. **Rollback story.** The settings toggle hides chips but the resolver still runs and consumes resources. No flag to disable the resolver entirely.
15. **`derived` ranked below `osc` without rationale.** OSC is *transport*, not source of truth. A shell with a stale cwd OSC vs. a resolver with fresh filesystem state: why does the shell win? Plan asserts the ordering without argument.

### Codex-only

1. **Two existing branch/cwd subsystems already in c11; the plan reconciles with neither.**
   - `TabManager.initialWorkspaceGitMetadataSnapshot` already runs `git` probes with generation tokens, expected-directory checks, delayed retries, and a background queue.
   - `ContentView.TabItemView` already has `sidebarShowGitBranch`, vertical/compact branch layout, and branch/directory rows sourced from `tab.panelGitBranches` and `tab.panelDirectories`.
   - The plan creates a *third* parallel system. Both existing systems should at least be acknowledged; the lower-risk path may be extending one of them.
2. **Existing settings composition is unspecified.** How does the new master toggle compose with `sidebarShowGitBranch` and "Hide All Details"?
3. **Localization is missing from the plan entirely.** Repo policy requires `Resources/Localizable.xcstrings` updates for new user-facing strings + six-locale translation pass. Not mentioned in the plan.
4. **pbxproj / target-membership churn is unmentioned.** Adding new Swift files to `c11LogicTests` + app target touches the Xcode project. CLAUDE.md flags pbxproj diff bloat. Not addressed.
5. **`TabItemView` is Equatable for typing-latency reasons.** Adding variable chip rows risks row-height churn and equality mistakes unless the plan specifies precomputed value structs included in the `==` function. Plan doesn't.
6. **Sidebar chip surface ambiguity in split/tab-stacked panes.** Existing `AgentChip` is resolved from the focused surface. Existing branch/directory rows iterate ordered panel IDs. Plan doesn't say whether new chips represent the focused surface, every surface, terminal surfaces only, or an aggregate. Fatal in c11's primary multi-pane use case.
7. **`sidebar.state` socket output may disagree with the visible sidebar** if derived chips are render-only but `sidebar.state` reflects something else.
8. **Persisted snapshot migration/backcompat** if `derived` entries leak into snapshots and are later changed or removed. No migration story.
9. **Contrast requirement for main/master/trunk dimming.** "15-25% opacity" needs a concrete contrast target across both Light/Dark theme slots, active *and* inactive rows. Plan delegates to "delegator's call."
10. **Stale-failure clearing rule.** Failed resolution for current cwd must *actively clear* previous `.derived` values for that surface, not leave the last successful result. The plan does not state this.

---

## 3. Assumption Audit (Merged + Deduplicated)

### Load-Bearing (Plan Collapses Without These)

1. **OSC 7 fires reliably on every cwd change in every shell + agent context the operator uses.** Partial at best. Fails in TUI agent panes (the *primary* use case). c11 also accepts `report_pwd` / `report_git_branch` — plan doesn't specify which trigger paths the resolver hooks. (Both reviewers.)
2. **`(cwd, mtime(.git/HEAD))` uniquely identifies a git-context.** Wrong. Falsely positive (silent staleness) on packed-refs change, gitfile redirection, branch rename, coarse mtime. Falsely negative on `git gc`. (Both reviewers.)
3. **Multiple `git rev-parse` invocations per cwd change are "free" because off-main.** Insufficient. No timeout, no concurrency budget, no dedupe with the existing `TabManager` probe, no cancellation, no admission control. (Both reviewers.)
4. **`derived` composes cleanly with the existing `explicit > declare > osc > heuristic` precedence chain.** Untested. Persistence, socket acceptance, clear-issuance, override semantics unspecified. "Derive, don't store" contradicts "write through the metadata store." (Both reviewers.)
5. **Re-deriving on session restore is good enough — no need to persist.** The restore-to-first-OSC-7 window is undefined behavior. Snapshot's existing `gitBranch` field creates two sources of truth. (Both reviewers, Claude in more detail.)
6. **The operator's "worktree" mental model maps cleanly to `git worktree add` linked worktrees.** Misses multiple clones at different paths (Claude). Misses bare repos, deleted-worktree admin dirs, `--separate-git-dir` repos, relative gitfiles, symlinked paths, nested worktrees (Codex).
7. **An 8–12-color palette can be picked at delegator time and is the right call.** Collisions are *guaranteed* by birthday-bound math at modest N. AC4 requires different colors for different paths — internally contradictory. Color must be decorative, not disambiguating. (Both reviewers.)
8. **Users may override `branch` or `worktree` explicitly and that is harmless.** Stale explicit override defeats the feature silently and forever until cleared. Policy question, not edge case. (Codex.)
9. **Basename-only worktree labels are sufficient because color disambiguates.** Same basename under different parents is text-identical *and* color isn't unique. (Codex.)
10. **15–25% opacity for main/master/trunk dimming is safe.** No contrast target across theme slots / active+inactive rows. (Codex.)

### Invisible / Unstated

1. **A background `DispatchQueue` exists for this work** (or one must be created; shared across surfaces or per-surface unspecified). (Claude.)
2. **`git` is on PATH in c11's process environment.** Bundle-launched processes get minimal PATH. Homebrew git not present. Plan doesn't specify which `git`. (Claude.)
3. **macOS sandbox / TCC does not block `git` invocations against arbitrary cwd.** Future-distribution risk. (Claude.)
4. **`MetadataValue` and `ChipModel` types exist in the shape the test plan assumes.** Plan defers to delegator inspection; ACs are written against types that may not exist as imagined. (Claude.)
5. **Workspace snapshot's existing `gitBranch` field stays.** Restore re-derive story assumes this. A future cleanup that removes the field would regress restore. (Claude.)
6. **`.git/HEAD` exists at the worktree root on every code path.** False for linked worktrees and submodules. (Both reviewers.)
7. **The existing `TabManager.initialWorkspaceGitMetadataSnapshot` probe and the new resolver will not conflict / race.** Not specified — they're parallel subsystems with different race behavior. (Codex.)
8. **Adding chip rows won't break `TabItemView` `Equatable` invariant.** Plan doesn't specify precomputed value structs. (Codex.)
9. **The plan's "30s coarse interval" is fully specified.** It isn't — Claude found it mentioned once with no further definition.
10. **Localization xcstrings updates + six-locale pass are out of scope or implicitly handled.** Codex: repo policy requires them; plan omits them.
11. **pbxproj churn is acceptable / not a review concern.** Codex notes this is unmentioned.

---

## 4. The Uncomfortable Truths (Recurring Hard Messages)

1. **The acceptance criteria are too tight in shape and too loose in semantics.** Both reviewers independently flag that AC4, AC10, AC11, AC12, AC18–AC20 can be passed without the underlying property holding. The plan's rigor is **theater**: 20 numbered criteria with verification methods, several fudge-able. The typing-latency claim has no runtime assertion. The "different colors" claim contradicts the palette size. The post-merge smoke criteria will not be exercised with the rigor the plan implies.

2. **The plan wants both "derive, don't store" and "first-class metadata with a new source tier."** These are incompatible architecturally. Either:
   - **Render-time projection** from per-panel git context (no `SurfaceMetadataStore` writes, no `derived` tier, no socket acceptance, no persistence question), OR
   - **Canonical metadata** (persistence, override policy, socket docs, validation, migration).
   The plan needs to pick one before delegation. Currently it wants both. (Codex states this most sharply; Claude arrives at the same point via the precedence-chain analysis.)

3. **This feature is being designed for an environment where its primary trigger (OSC 7) doesn't fire.** TUI agent panes — the motivating use case — don't emit OSC 7 unless explicitly wired. The feature works best in shell panes (where the operator already knows the cwd from the prompt) and worst in agent panes (where the operator most needs the signal). This is the inverse of intent. Both reviewers raise it.

4. **The plan adds a third parallel git-context subsystem without reconciling the existing two.** `TabManager`'s git probe and `TabItemView`'s branch/directory rows are already in place, with generation tokens and existing settings. The plan invents a new resolver alongside them. The lower-risk path is extending one of the existing systems. (Codex, most explicitly.)

5. **`git`-subprocess discipline is a c11-specific load-bearing concern that the plan treats casually.** CLAUDE.md explicitly enumerates typing-latency-sensitive hot paths. "Off-main" is necessary but not sufficient — every subprocess from terminal telemetry deserves a timeout, dedupe, and stale-drop policy. The plan provides none. (Both reviewers.)

6. **The plan is optimized for one operator on one machine.** Atin's m4 Max, local SSD, specific multi-worktree workflow. The decisions (colored dot, stacked submodule, dim main) are personal preferences. None are wrong, but the plan reads as personal toolmaking framed as product engineering. This is fine *if owned*; the plan doesn't own it. (Claude.)

7. **The autonomy framing is aspirational.** "Fully Autonomous delegator" + 17 pre-merge ACs + 3 post-merge smoke ACs + Result Validator pass = heavily gated, not autonomous. (Claude.)

8. **"We don't know" is the answer to a non-trivial number of the hard questions.** And those unknowns are being passed downstream to the delegator rather than resolved in planning. (Both reviewers, Codex's Q23 most directly.)

---

## 5. Consolidated Hard Questions for the Plan Author

Deduplicated, ordered by severity. Numbers in square brackets indicate origin: [C] = Claude, [X] = Codex, [C+X] = both.

### Architecture / Semantics

1. **Are `worktree` and `branch` actually stored in `SurfaceMetadataStore`, or are they render-time projections from per-panel git context?** Pick one. If stored, why does "derive, don't store" still hold? If projections, why does a `derived` source tier exist at all? [C+X]
2. **If `.derived` is added to `MetadataSource`: is it accepted over `surface.set_metadata` / `pane.set_metadata`? Persisted in session snapshots? Restorable? If not, where is that forbidden and what enforces it?** [X]
3. **Why is `derived` ranked *below* `osc` rather than above? OSC is transport, not source of truth — a stale-cwd OSC should not beat a fresh filesystem read.** State the rationale. [C]
4. **Why should an explicit user/agent write be allowed to override derived `branch` and `worktree` at all? What prevents a stale explicit value from defeating the feature forever?** [X]
5. **Who issues `clear_metadata` calls with `source: derived` when the resolver determines "no longer in git"? Where in the code does that path live? How does it compose with existing clear-semantics rules?** [C+X]

### Cache Key / Topology Correctness

6. **Which `.git/HEAD` mtime is being watched in a linked worktree?** The worktree's `.git` is a *file*; the real HEAD lives under `<common-dir>/worktrees/<name>/HEAD`. [C+X]
7. **What is the cache key for submodules, where `.git` is a gitfile pointing elsewhere?** [X]
8. **Which files invalidate branch display besides HEAD?** Branch ref files, `packed-refs`, `commondir`, `gitdir`, deleted gitdir targets, ref reorgs? [X]
9. **How does the resolver detect "linked worktree but not main checkout" for repos using `--separate-git-dir`, relative gitfiles, symlinked paths, or nested worktrees?** [X]
10. **Worktree path canonicalization for color hash:** symlink-resolved real path (what `git rev-parse --show-toplevel` returns) or the user-facing cwd? AC4's "same path → same color" depends on this choice. [C]

### Submodule Correctness

11. **From inside a submodule, exactly how are outer superproject branch/worktree and inner submodule branch resolved? Which command runs in which directory?** Plan's stated sequence appears wrong: `--show-toplevel` returns submodule top, not superproject. [C+X]
12. **What is the submodule display name source: configured name, path from `.gitmodules`, basename, or something else?** [X]
13. **What about nested submodules, detached-HEAD submodules (the normal post-`submodule update` state), and linked-worktree superprojects containing a submodule?** [C+X]

### Performance / Concurrency

14. **What is the per-`git`-subprocess timeout?** What is the total budget per OSC 7 event? What is the concurrency limit across all panes? [C+X]
15. **What happens when `git` hangs (slow network mount, corrupted repo, lock contention)?** Specifically: which error codes are "no chips," which are "fall back to stale cache," which are "log and retry"? [C+X]
16. **What is the stale-result guard?** If cwd changes A → B while A's resolver is still running, what prevents A from writing chips after B is current? Reuses `TabManager`'s generation tokens, or invents new ones? [C+X]
17. **Does the resolver share state across surfaces?** If 10 panes share a cwd, does the resolver run once or 10 times? OSC 7 fires per-pane. Singleton resolver or per-surface? [C]
18. **What's the coalescing/debouncing strategy for OSC 7 storms** (`cd a && cd b && cd c && cd a` in rapid succession)? [C]

### Deleted / Vanished State

19. **How does the resolver detect that the worktree directory was deleted while a pane was open in it?** OSC 7 won't fire; `.git/HEAD` doesn't exist. [C+X]
20. **What is the rule for stale-clearing of `.derived` values on failed resolution?** Failed resolution must actively clear previous chips, not leave them. Where is that specified? [X]
21. **What about external-tool branch changes** (Tower, Fork, IDE git GUI from outside any pane) — no OSC 7, no cwd change, cache holds. Why not FSEvents subscription on relevant gitdir files? [C]

### Restore / Bootstrap

22. **What renders during the window between session restore and first OSC 7?** Synchronous derive (blocks UI) or asynchronous (chips appear N seconds later)? Snapshot has stale `gitBranch`; resolver has fresh derive. Which wins? [C+X]
23. **Migration/backcompat for persisted snapshots if `derived` entries leak in and are later changed/removed?** [X]

### Reconciliation with Existing c11 Code

24. **Why is this not an extension of `TabManager`'s existing git metadata probe, which already has generation checks, expected-directory stale-result protection, and a background queue?** [X]
25. **How does the new branch chip compose with the existing sidebar branch/directory row, `sidebarShowGitBranch`, vertical/compact branch layout settings, and "Hide All Details"?** Is duplicate branch display expected/intended? [X]
26. **Which surface does the sidebar chip describe in a workspace with multiple terminal panes or tab-stacked surfaces:** focused surface only, every surface, terminal surfaces only, or an aggregate? [X]
27. **Does this feature work in panes running TUI agents (claude, codex) that don't emit OSC 7?** This is the *primary use case* per the motivation section. [C+X]
28. **How does the colored-dot palette interact visually with the existing status-pill palette in the sidebar?** Both are sidebar color signal. Contrast/differentiation requirement is unspecified. [C]
29. **How is `TabItemView` `Equatable` preserved with variable chip rows per surface?** Precomputed value structs included in `==`, or runtime invariant break? [X]

### Testing / Acceptance

30. **How will tests prove resolver work never blocks the main thread beyond code inspection?** Can the resolver API assert/inject a main-thread precondition failure in tests? [X]
31. **AC11 says no new git work in two specific files. What stops the delegator from putting the work in `Sources/Sidebar/SomeNewFile.swift` such that AC11 passes vacuously while still affecting typing latency?** [C]
32. **AC10 is a grep, not a runtime test. What's the actual runtime assertion for "git work runs off-main"?** [C]
33. **AC12 tests `.git/HEAD` mtime invalidation. What about the "30s coarse interval" mentioned once and never specified? Since last OSC 7? Last resolution? AC12 is incomplete.** [C]
34. **How will cache invalidation tests prove actual bypass instead of merely getting the same result after a `touch`?** Instrumentation for cache hits/misses? [X]
35. **Why are AC18–AC20 (visual chip behavior) post-merge instead of pre-merge against a tagged build with screenshot/smoke validation?** [X]

### Palette / UX

36. **Why does AC4 require different colors for different paths when the palette has only 8–12 colors and collisions are guaranteed by birthday-bound math at modest N?** Either AC4 is wrong, or color must be admitted to be decorative not disambiguating. [C+X]
37. **What's the operator's recourse when two worktrees collide?** Re-hash, salt, live with it? [C]
38. **What is the contrast requirement for main/master/trunk dimming (15–25% opacity) across Light/Dark theme slots, active and inactive rows?** [X]
39. **What's the sidebar real-estate budget?** Two new chips per pane + possible submodule second row, across 10+ panes. [C]

### Process / Localization / Build

40. **Where are localization updates for new Settings strings handled, including the six non-English locales required by repo policy?** Unmentioned in the plan. [X]
41. **What's the pbxproj / target-membership impact?** Adding new Swift files touches the project; CLAUDE.md flags diff bloat. [X]
42. **What's the rollback story?** Settings toggle hides chips but resolver still runs. Is there a flag to disable the resolver entirely if it causes perf issues? [C]
43. **What's the debug/telemetry story for resolver failures, timeouts, stale drops, cache hits/misses?** Without observability, future bugs are anecdotal. [C+X]

### Meta

44. **Why does the plan delegate so much shape-decision to the delegator** (module shape, palette, color hash input)? Operator-time is being spent in PR review where it could have been spent in planning. [C]
45. **If "we don't know" is the answer for any of the above, why is the delegator being sent to implementation before those boundaries are decided?** [X]

---

## Closing Synthesis

The two reviewers converge on a small list of structurally serious gaps that should be closed before delegation:

- **Cache key correctness for linked worktrees + submodules** (Q6–Q10).
- **`derived` tier semantics — store vs. project, override policy, persistence, socket acceptance, clear-issuance** (Q1–Q5).
- **Stale-result cancellation + reuse of existing `TabManager` machinery** (Q16, Q24).
- **`git`-subprocess timeout/budget/concurrency** (Q14–Q15).
- **Submodule command sequence correctness** (Q11–Q13).
- **A runtime typing-latency assertion** to replace the grep-shaped ACs (Q30–Q32).
- **Trigger-path correctness for TUI agent panes** — the feature's motivating use case (Q27).
- **AC4 internal contradiction with palette size** (Q36).

Everything else is acceptable risk **provided** those eight are resolved. The plan is competent. As adversaries, neither reviewer would ship it as-is.

The single highest-leverage move identified across both reviews:

> **Add a runtime perf assertion (typing latency in a worktree pane vs main pane, measured against a tagged build) and specify error/timeout behavior for `git` invocations.** Those two changes turn the plan from "looks rigorous" to "actually rigorous."

Reminder: **the Gemini perspective is missing from this synthesis due to rate limiting.** A third independent read of the plan could surface additional consensus or contradict items currently classified as "unique." Treat the consensus list as "2-of-3 consensus" pending that read.
