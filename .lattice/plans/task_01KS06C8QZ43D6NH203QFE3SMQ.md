# C11-106: C11-104 follow-ups: wire GitContextResolverCache + missing tests + enum naming

> **Revision note (2026-05-19, trident plan review pass 1).** This plan was revised after a trident plan review produced verdict `revise-then-proceed`. All Blocker, Important, Medium, and "Evolutionary clear win" findings from the action-ready synthesis have been absorbed into the body below. Open strategic questions (S1–S7 in the synthesis) are left for operator decision and tracked in a Lattice comment, not in this plan. Review pack: `.lattice/orchestration/c11-106/c11-106-plan-review-pack-2026-05-19T0935/`.

## Follow-up to C11-104 (PR #181)

PR #181 merged at `2b1be4220` on 2026-05-19. The Phase 4 Result Validator audit produced 22 PASS / 6 PARTIAL / 4 FAIL / 1 CANNOT_VERIFY against the 30-AC validation plan. Merge gate was **clear** (no user-visible regressions); these are the gaps to close in a follow-up PR.

Full audit at `.lattice/orchestration/c11-104/validation-report.md`. Spec source: C11-104 § "Refined SPEC + decisions v2 (2026-05-19, post-trident-review)".

## Scope

### 1. Wire `GitContextResolverCache` into production (mandatory); `DerivationCoordinator` decoupled

> Revised per Blocker B1 + Important I5, B2, B3 from the trident action synthesis.

`TabManager.initialWorkspaceGitMetadataSnapshot(for:)` currently calls `GitContextResolver.resolve(cwd:)` directly. There is no cache. The E1 reframe is half-realized.

**Required change.** Wire `GitContextResolverCache` into the production `GitContextResolver` probe path. The cache wraps `resolve(cwd:)`; the synchronous snapshot path stays synchronous.

`DerivationCoordinator` adoption is **decoupled** from the cache wiring. Its async-completes-on-main shape doesn't fit the existing synchronous probe path on `initialWorkspaceGitProbeQueue`. Two acceptable resolutions for the coordinator:

- Adopt it now in the snapshot path by reshaping `initialWorkspaceGitMetadataSnapshot` to call `DerivationCoordinator.run` against `[GitContextDeriver]`. If this is chosen, the queue + generation-token + expected-cwd guards stay in `TabManager.applyWorkspaceGitMetadataSnapshot`, **not** in the coordinator. Document the precondition contract (off-main only) in `Sources/Metadata/DerivationCoordinator.swift` and `skills/c11/references/metadata.md`.
- Leave `DerivationCoordinator` as a forward seam for future derivers (host/SSH target, container, kubectl, AWS profile). Document this explicitly in `skills/c11/references/metadata.md` and in a doc-comment on `DerivationCoordinator` so the next agent doesn't think it's load-bearing. **The cache wiring still ships; only the coordinator is deferred.**

Recommendation: wire the cache, leave the coordinator as a forward seam. The cache is the unit-of-correctness win; the coordinator's async/main shape doesn't pay for itself with one deriver.

**Cache key + invalidation specification.**

- For non-submodule cwds: `(absoluteCwd, mtime(headPath))` where `headPath = git rev-parse --git-path HEAD`. This is correct for plain checkouts and linked worktrees (the v2 SPEC § B2 fix).
- For submodule cwds: the key **must** include both the resolved submodule HEAD path mtime **and** the superproject HEAD path mtime. Otherwise a superproject branch change while the submodule HEAD is stable serves a stale outer-branch value. If implementing both mtimes is more than ~30 LOC of glue, skip caching for submodule-combined contexts entirely until a multi-HEAD invalidation pass — but state the policy explicitly in `GitContextResolverCache`.
- **Nil-result caching is forbidden.** If `headPath` is nil (not-in-repo, missing cwd, bare repo, timeout, broken gitdir), do **not** cache the result. A later `git init` / repaired worktree / recovered command must re-resolve immediately. The cache only stores results whose `headPath` resolved successfully and whose mtime was read successfully. Add a unit test asserting nil-head results are re-resolved on subsequent calls.

**Threading contract.**

- The cache wraps synchronous `GitContextResolver.resolve(cwd:)` calls. Cache reads/writes occur on whichever queue the resolver was already called from — typically `initialWorkspaceGitProbeQueue` (off-main). The cache itself is a value-typed or `NSCache`-backed store; thread-safety is the cache's responsibility, not the caller's.
- Generation-token + expected-cwd guards remain in `TabManager.applyWorkspaceGitMetadataSnapshot`. The cache does not know about them.
- `initialWorkspaceGitMetadataSnapshot` stays `nonisolated static` and stays synchronous.
- If the coordinator path is also wired (option 1 above), document in code that `DerivationCoordinator.run` must be invoked off-main and completes on main with its own `dispatchPrecondition` guard. If only the cache path is wired (option 2 / recommended), `DerivationCoordinator` is untouched in production and the precondition contract continues to apply only to its tests.

**Tests required for the wiring** (these are part of AC12 from the v2 validation plan):

- Linked-worktree fixture: invalidates cache when the linked worktree's HEAD changes (via the `git rev-parse --git-path HEAD` redirection).
- Submodule fixture: invalidates cache when **either** the submodule HEAD or the superproject HEAD changes.
- Nil-result re-resolution: `(cwd, nil)` is not cached; subsequent call re-runs the resolver.

### 2. Add the four missing tests the v2 validation plan called for

> Revised per Important I1, I2, I8.

These were specified in `validation-plan.md` v2 but not implemented:

- **AC14 — Git subprocess timeout.** Stub `git` with a sleep > timeout, run resolver, assert no hung queue and a defined-shape result.
  - **API decision (must be made before the test is written):** `GitRunner.run` currently returns `String?`. Timeout, non-zero exit, missing git, not-in-repo, bare clone, broken HEAD all collapse to nil. For C11-106, **option (c)** — assert subprocess terminates within budget + nil result + no hung queue. Do **not** introduce a typed timeout enum in C11-106; that pairs naturally with the `.stale` work and is a follow-up. Record this decision in the PR body. (Typed timeout state is filed as a follow-up; see "Out of scope".)
  - **Timeout value decision (must be made before the test is written):** spec says 2s, impl is 5s. Resolution for C11-106: **keep 5s, amend the v2 SPEC to 5s with a note explaining "conservative for slow disks."** AC14 is written against 5s. Recording the decision is part of the PR body. (If the operator prefers 2s, flip both the impl value and the test in the same commit.)
- **AC16 — Socket `set_metadata` rejection.** Send a `set_metadata` frame with `source=derived` from a non-internal-caller path; assert `invalid_source` error.
  - Rejection code is at `Sources/TerminalController.swift:8246-8248, 8368-8370, 9124-9126, 9221-9223`. One representative call site is sufficient — the rejection logic is uniform.
  - **The test must exercise the external socket frame handler**, not the `SurfaceMetadataStore` API directly. Acceptable seams: (a) full unix-socket loop in a `tests_v2/`-style integration test, (b) an extracted handler function in `TerminalController` callable from a logic test with a fake controller context. Whichever seam is chosen, document it in the test file's comment header so the next reviewer can see what was actually exercised.
- **AC17 — Socket `get-metadata --key worktree`/`--key branch` returns derived values.** Populate via the production probe path (cache-aware), query via the socket get path, assert values match. By construction this works; the test is the missing piece.
- **AC20 — Deterministic main-thread precondition trip.**
  - `XCTExpectFailure` does **not** trap `dispatchPrecondition`. Preconditions abort with `EXC_BAD_INSTRUCTION`, not XCTFails.
  - **Pick one concrete approach**: either (a) **subprocess fatal-test harness** — a small helper binary calls the coordinator from main; parent process asserts non-zero termination and the precondition diagnostic in stderr; or (b) **explicit downgrade** — keep the existing off-main sentinel test, add a code comment "AC20: in-process precondition crash testing is unsafe in XCTest; sentinel verifies off-main happy path only," and record the residual gap in the PR body and the validation-plan addendum.
  - Forbid inventing a third "weak fake" pattern. Default recommendation: **(b) explicit downgrade**, given the option-1-vs-2 coordinator decision in Section 1 may leave `DerivationCoordinator` unused in production anyway.

### 3. Enum case naming: rename + commit to `.stale` if renaming (coupled to Section 4)

> Revised per Important I3, I4.

The v2 SPEC said `BranchValue.noBranch`, `GitContextKind.notInRepo`, `GitContextKind.stale`. Implementation uses `nil` and `.unknown`. User-visible behavior matches the SPEC; the enum naming doesn't.

**Recommendation: rename the implementation enums to match the SPEC.** This implies `.stale` adoption in Section 4 is mandatory (free cost while the switch statements are already being updated). If the operator instead prefers amending the SPEC to keep `nil`/`.unknown`, Section 4 stays deferred and an audit-trail note must be added to the C11-104 ticket description identifying this as a hindsight rewrite (see also S7 in the trident pack).

**This is not search-and-replace.** Adding `.stale` and `.notInRepo` to `GitContextKind` and renaming `.unknown` → `.noBranch` on `BranchValue` changes the **shape** of each enum, not just labels. Every `switch` over each enum needs a new case (compiler-enforced unless the site uses `default`). The existing projector-vs-store mismatch (`WorktreeChipProjector` renders `.unknown` as `"(no branch)"` while `applyDerivedWorktreeBranchMetadata` writes an empty derived `branch` for `.unknown`) must be resolved as part of this pass.

**Required semantic contract table.** For each renamed/new state, specify three behaviors before the rename ships:

| State | `WorktreeChipProjector` renders (chip text + dim) | `applyDerivedWorktreeBranchMetadata` writes | Socket `get-metadata --key branch`/`--key worktree` returns |
|---|---|---|---|
| `BranchValue.named("main")` | `"main"`, full opacity | branch=`"main"` | `"main"` |
| `BranchValue.noBranch` (renamed from `.unknown` for detached HEAD / no branch) | (decide: `"(detached)"` or `"(no branch)"`), dimmed | (decide: empty string vs. key removal vs. `"(no branch)"` token) | (matches store) |
| `GitContextKind.inRepo` | normal | worktree=resolved name | resolved name |
| `GitContextKind.notInRepo` (renamed from `.unknown` for "cwd is not under a git tree") | dimmed, blank text or `"—"` | key removal | `nil` / not present |
| `GitContextKind.stale` (new — gitdir/HEAD path missing post-resolution) | chip clears | key removal | `nil` / not present |

Fill the (decide:) cells in the plan body before delegation begins.

### 4. Add `.stale` state + AC10 test for the worktree-removed case (mandatory if Section 3 renames)

> Coupled to Section 3 per Important I3.

When `git worktree remove` is run from another pane, the affected pane's chips today either (a) clear if the cwd directory is gone, or (b) stick with the last cached value if the cwd directory remains. SPEC says: introduce a `.stale` `GitContextKind` case; deriver returns `.stale` when the resolved gitdir/HEAD path is missing; chip clears.

- If Section 3 takes the rename path (recommended), `.stale` ships in the same commit. AC10 (worktree-removed case) is mandatory.
- If Section 3 amends the SPEC to keep `nil`/`.unknown`, Section 4 stays deferred and the AC10 test moves to the AC19-style follow-up ticket.

The cache implications: when the deriver returns `.stale`, the cache should **not** store the `.stale` result (treat it like a nil-result — re-resolve on next call). Otherwise a recreated worktree wouldn't be picked up. Document this in `GitContextResolverCache`.

### 5. Confirm + delete dead code (optional cleanup, no behavior change)

> Revised per Important I6: demoted from acceptance criterion to optional cleanup.

After AC24 retired the legacy text branch+directory row, these may be unused:

- `Workspace.orderedUniqueBranchDirectoryEntries()`
- `tab.sidebarBranchDirectoryEntriesInDisplayOrder` callers
- Any helpers downstream of those

**Three-step safety protocol** (not `grep` alone):

1. `grep` in `Sources/`, `c11Tests/`, and `tests_v2/` for direct references.
2. Compile both `c11-logic` and `c11-unit` schemes after deletion — the Swift compiler is the authoritative dead-code prover (catches protocol witness tables, `@objc`, KeyPath references that `grep` misses).
3. Verify the snapshot-restore and persistence migration paths haven't silently lost a field.

If any caller remains (especially in test-only files, persistence, or snapshot-restore), leave the helper in place and add a `// TODO(c11-followup): retire after AC24 callers migrate` comment. **This section is now optional cleanup and does not gate the PR.**

### 6. Optional polish (operator's call)

- **Timeout 5s → 2s** is **no longer in this section** — see Section 2's AC14 timeout-value decision (kept at 5s for C11-106; SPEC amendment recorded in PR body). If the operator wants the 2s tighter bound, it's a separate ticket.
- **Dim opacity → ThemeKey-backed** (per v2 SPEC M6). Currently hardcoded `0.55` at `Sources/Sidebar/WorktreeChipsRow.swift:73`. Replace with `ThemeKey.chipTextDimmedOpacityLight` (default 0.65) and `chipTextDimmedOpacityDark` (default 0.55), exposed to theme JSON. PR body acknowledged this as v2-deferred.
  - **Open question for operator** (S4 in trident pack): this change is user-visible and arguably conflicts with the "no user-visible sidebar render change" boundary below. Split into a separate tiny visual-polish ticket OR keep here and loosen the no-visible-change rule? Default if no decision: split into a separate ticket; do not include in C11-106.

### 7. Validation plan addendum (v3 addendum file, not in-place edit)

> Revised per Important I7.

Do **not** edit `.lattice/orchestration/c11-104/validation-plan.md` in place — it is historical evidence. Instead:

- Create `.lattice/orchestration/c11-104/validation-plan-c11-106-addendum.md` (or append a clearly-marked "## C11-106 amendments (2026-05-19)" section to the existing file with no edits to prior content).
- Note which ACs were deferred-then-resolved-here (AC10 conditional on Section 3/4 decision, AC12 cache-invalidation fixtures, AC14, AC16, AC17, AC20).
- Note which remain deferred (AC19 restore-warmpath, AC31–33 operator post-merge smoke).
- This is an acceptance criterion, not a "nice to have."

## Out of scope

- **AC19 (restore-warmpath snapshot pre-paint).** Real follow-up; filed as **C11-107** (`task_01KS08E3NRW5PVM9YCGW04JK6E`), spawned_by C11-104, related_to C11-106. Title: "C11-104 follow-up: restore-warmpath snapshot pre-paint for sidebar chips." Touches workspace restore lifecycle, out of C11-106's blast radius.
- **AC31–AC33 (operator post-merge smoke).** Operator runs at their convenience; not a delegator task. **AC33 (typing latency)** in particular: the parent #181 never had an AC33 pass either; whether C11-106 should require a tagged-build smoke pass as part of its merge gate is an open operator question (S5 in trident pack).
- **Typed `GitRunner` result enum.** Pairs with the `.stale` work; file as a follow-up if Section 4 ships.
- **FSEvents-based cache invalidation.** mtime polling is the entry-level pattern; FSEvents is the structural answer for an N-deriver world (S3 in trident pack). Out of scope for C11-106; add a TODO comment in `GitContextResolverCache` referencing the eventual replacement.
- Anything that would change the user-visible sidebar render compared to what shipped in #181 (subject to the Section 6 dim-opacity decision above).

## Acceptance criteria for this follow-up PR

1. `GitContextResolverCache` **is** invoked by `TabManager`'s production probe path through `GitContextResolver.resolve(cwd:)`. Cache key, nil-result policy, and threading contract match Section 1. Cache invalidation fixture tests exist for linked-worktree and submodule scenarios, plus a nil-result re-resolution test. `DerivationCoordinator`'s production status (load-bearing with a named call site **or** explicit forward seam) is stated in code comments and in `skills/c11/references/metadata.md`.
2. AC14, AC16, AC17, AC20 tests exist in `c11Tests/` with `c11LogicTests` target membership and the specifications in Section 2 (in particular: AC16 exercises the external socket handler seam, not the store API; AC20 picks one of the two listed patterns).
3. Either (a) enum cases renamed to match the v2 SPEC (`BranchValue.noBranch`, `GitContextKind.notInRepo`, `GitContextKind.stale`) **and** the projector-vs-store mismatch resolved per Section 3's contract table, **and** `.stale` state + AC10 test land in the same PR; **or** (b) the v2 SPEC is amended to the `nil`/`.unknown` shape with an audit-trail note on the C11-104 ticket. Decision recorded in PR body.
4. `skills/c11/references/metadata.md` is updated to reflect the production status of `DerivationCoordinator` and `GitContextResolverCache` chosen by Section 1. The doc names the production call site(s) if wiring; states `DerivationCoordinator` is a forward seam if not. **Also includes a new "How to add a `MetadataDeriver`" sub-section** listing the contract (off-main, cache-key choice, snapshot exclusion, source `.derived`, projector update, test pattern) with `GitContextDeriver` named as the reference implementation. ~20–40 lines.
5. Validation plan addendum exists per Section 7 (separate file or clearly-marked appended section).
6. Optional but recommended: dead code in Workspace.swift cleaned up per Section 5's three-step protocol.
7. **CI green; no regressions in `c11-logic` or `compat-tests`.** Local validation loop: `xcodebuild -scheme c11-logic test` plus a tagged-build reload (`./scripts/reload.sh --tag c11-106`) for any code touching the typing-latency hot path. Defer `c11-unit`, `compat-tests`, and `test-e2e` to CI per `code/c11/CLAUDE.md` § "Testing policy". Never `open` an untagged `c11 DEV.app`.
8. **Commit hygiene inside the PR.** Commits are organized one-per-section (or one-per-meaningful-unit): a "cache wiring" commit, an "invalidation fixture tests" commit, a "missing tests" commit, an "enum rename + .stale" commit, a "dead-code cleanup" commit, a "validation plan addendum" commit, etc. Do **not** squash before merge — this preserves bisection granularity if a typing-latency or other hot-path regression appears post-merge.
9. PR body links to this ticket and to PR #181; describes which AC numbers it closes; records the decisions called out in this plan (Section 1 coordinator option, Section 2 AC14 API + value, Section 3 rename vs SPEC amendment, AC20 pattern choice, Section 6 dim-opacity disposition).

## Cost notes

- Wiring glue (cache + threading + nil-result policy): ~50–100 lines.
- AC12 fixture infrastructure (linked-worktree + submodule scratch dirs in `setUp`, deterministic HEAD-path manipulation, plus the nil-result re-resolution test): additional ~100–200 lines + one-time review of the fixture pattern. If an existing `c11Tests/` helper builds submodule fixtures, reuse; otherwise the fixture is greenfield.
- AC14, AC16, AC17, AC20 tests: ~100–200 lines combined depending on AC20 path choice.
- Enum rename + `.stale` + AC10 (if renaming): ~50–150 lines spread across `GitContextDeriver`, `GitContextResolver`, `WorktreeChipProjector`, `applyDerivedWorktreeBranchMetadata`, snapshot encode/decode, plus AC10 test.
- Skill doc + "How to add a deriver" sub-section: ~30–50 lines of prose.
- Validation plan addendum: ~30 lines.

Total: in the ballpark of ~500–1,000 lines of code+test+docs depending on the chosen options.

## References

- C11-104 (parent): `task_01KRYWXX6ECSCVRGFTYYA594HK`
- PR #181 (merged): https://github.com/Stage-11-Agentics/c11/pull/181
- Validation report: `.lattice/orchestration/c11-104/validation-report.md`
- v2 SPEC: inside C11-104 description, § "Refined SPEC + decisions v2"
- Trident plan-review pack (parent ticket reasoning): `.lattice/orchestration/c11-104/c11-104-plan-review-pack-2026-05-18T2228/`
- Trident plan-review pack (this revision): `.lattice/orchestration/c11-106/c11-106-plan-review-pack-2026-05-19T0935/`

---

## Plan amendments — operator decisions on Surface-to-user items (2026-05-19, delegator C11-106-D1-1)

The trident pack flagged 7 strategic items (S1–S7) and 3 evolutionary items (E1–E3) as needing operator input. The delegator is fully autonomous for C11-106 (the operator authorized "route around everything short of spend > \$20 or permanent data destruction"). The decisions below are recorded for the PR body and the post-merge AAR.

**S1 — Second deriver (HostDeriver stub) inside C11-106.** **DECLINED.** Scope-expansion. C11-106's mandate is closing C11-104's test/wiring debt; protocol genericity verification is valuable but belongs in a separate ticket that pairs the second deriver with its own ACs.

**S2 — DerivationLifecycle envelope refactor.** **DECLINED.** Largest structural reframe on the table; explicitly out of C11-106's blast radius per the ticket's "Out of scope" + "Anything that would change the user-visible sidebar render" boundary.

**S3 — Mark FSEvents-based cache invalidation as explicit follow-up.** **PARTIALLY ADOPTED.** Add a `// TODO(c11-followup): FSEvents-based invalidation is the structural replacement for mtime polling. See plan-review pack 2026-05-19T0935 § S3.` to `GitContextResolverCache`. Do **not** file the follow-up Lattice ticket from this delegator; that is the operator's call after C11-106 lands and the cost shape is visible.

**S4 — Demote Section 6's ThemeKey dim-opacity out of C11-106.** **ADOPTED.** The ThemeKey-backed opacity work is user-visible polish that conflicts with C11-106's "no user-visible sidebar render change" boundary. Leave the hardcoded `0.55` in `WorktreeChipsRow.swift:73` alone. Section 6 in this plan now reads "no work in C11-106." The operator can file a separate tiny visual-polish ticket if they want the ThemeKey wiring.

**S5 — AC33 typing-latency tagged-build smoke as C11-106 merge gate.** **DECLINED.** AC33 stays as an operator-driven post-merge smoke recommendation in the PR body, identical to PR #181's pattern. The delegator will run `./scripts/reload.sh --tag c11-106` once at the end to confirm the build is launchable, but the burst-typing assessment is the operator's call. Forcing AC33 as a delegator gate would require either the delegator to make the qualitative call (out of scope) or a second pane to drive computer-use validation (separate ticket).

**S6 — Split C11-106 into two PRs (wiring + cleanup).** **DECLINED.** Keep as one PR with M4 commit hygiene (one commit per section / meaningful unit, no squash before merge). Reassess mid-flight if Section 1 unexpectedly grows beyond the cost estimate.

**S7 — SPEC rewrite branch ownership.** **MOOT.** The delegator is taking the rename path (Section 3 (a)), so the audit-trail question doesn't arise. If the rename ends up infeasible mid-implementation, this will resurface as a real blocker and a `needs_human` transition.

**E1 — "Derived-metadata seam becomes the product" reframe.** **LIGHT-TOUCH ADOPTED.** The EW1 "How to add a `MetadataDeriver`" doc-block is already an explicit AC (#4); the FSEvents TODO from S3 captures the long-arc invalidation upgrade; the metadata.md update articulates the seam's current production status. No additional plan-body reframe; the seam is treated as a foundation, not a curio.

**E2 — LatticeTaskDeriver as next derived signal.** **DECLINED.** Future ticket. The C11-106 seam being load-bearing is the precondition; that lands here. The Lattice deriver itself is a separate ticket the operator can file post-merge.

**E3 — Cache hit/miss diagnostic counter.** **ADOPTED.** Add a small internal counter struct (`cacheHits`, `cacheMisses`, `cacheStale`, `derivationTimeouts`) on `GitContextResolverCache` accessible via `DEBUG`-only logging. ~30 LOC. No UI, no telemetry. Pairs naturally with the AC14 timeout decision and B2/B3 invalidation tests. This satisfies Adversarial-Claude's "no hit/miss observability" hindsight risk for negligible cost.

## Plan amendments — semantic contract table fill-in (Section 3)

The Section 3 contract table left several `(decide:)` cells blank. Filled in here so implementation has unambiguous spec; the table in Section 3 above remains the source for cross-reference.

| State | Projector renders (chip text + dim) | `applyDerivedWorktreeBranchMetadata` writes | Socket `get-metadata --key branch` / `--key worktree` returns |
| --- | --- | --- | --- |
| `BranchValue.attached("main")` (and other `mainBranchNames`) | `"main"`, **dimmed** (per `WorktreeChipModel.mainBranchNames` check, current behavior preserved) | branch = `"main"` | `"main"` |
| `BranchValue.attached("feature/x")` (non-main) | `"feature/x"`, full opacity | branch = `"feature/x"` | `"feature/x"` |
| `BranchValue.detached(shortSHA:)` | `"(detached @ <sha>)"`, full opacity | branch = `"(detached @ <sha>)"` (current behavior at `TabManager.swift:2449`) | `"(detached @ <sha>)"` |
| `BranchValue.noBranch` (renamed from `.unknown` — worktree at deleted branch / broken HEAD) | `"(no branch)"`, full opacity (preserves current `WorktreeChipModel.swift:131` render) | branch = `""` (empty string — preserves current `TabManager.swift:2450` write) | `""` (empty string) |
| `GitContextKind.mainCheckout` / `.linkedWorktree` (the existing inRepo cases) | normal render per kind | worktree = `""` for mainCheckout, basename for linkedWorktree | accordingly |
| `GitContextKind.notInRepo` (new enum case; semantics same as today's `nil` Optional<ResolvedGitContext>) | chip row not rendered (empty `[WorktreeChipRow]`) | worktree = `""`, branch = `""` (matches today's nil-context branch in `applyDerivedWorktreeBranchMetadata`) | `""` for both keys |
| `GitContextKind.stale` (new enum case; resolver returns when `headPath` resolves but the file doesn't exist on disk) | chip row not rendered (same as `.notInRepo`) | worktree = `""`, branch = `""` (same as `.notInRepo`) | `""` for both keys |

**Resolves the projector-vs-store mismatch noted in I4:** today's `.unknown` (now `.noBranch`) renders `"(no branch)"` but writes empty string to the store. After this PR, that mismatch persists by design — the projector's job is to produce sidebar-renderable text; the store's job is to expose programmatic state. External readers (Lattice queries, future automation) see empty string and know "no meaningful branch"; the sidebar reader sees `"(no branch)"` and gets human-readable context. The PR body will document this intentional asymmetry.

## Plan amendments — minor process / hygiene

- **M5 (file the AC19 follow-up ticket before C11-106 delegation starts).** Delegator files this ticket as the first action after status returns to `in_progress`. Working title: "C11-104 follow-up: restore-warmpath snapshot pre-paint for sidebar chips." Refs C11-104 and C11-106. Captured ID will be written back into Section "Out of scope" above.
- **AC14 default-recommendation pick.** Section 2 lists "(b) explicit downgrade" as default for AC20. Adopting that here unconditionally — AC20 is the explicit-downgrade variant with a code comment + PR body note. Saves the subprocess-fatal-test harness for a later observability sweep.
- **AC14 fixture choice.** `ProcessGitRunner` will accept a `executable: String = "/usr/bin/env"` + `argPrefix: [String] = ["git"]` set of constructor defaults so the AC14 test can substitute `/bin/sh` + `["-c"]` without forking the production path. Defaults remain unchanged from today's behavior; only new optional params.

## Status transition note

Trident moved the ticket to `needs_human` because S1–S7 plus the (decide:) cells in Section 3 required operator-level judgement. With the amendments above, those questions are resolved per the "Fully Autonomous" delegation. The delegator now files the AC19 follow-up ticket per M5, then transitions back to `in_progress` and begins implementation.
