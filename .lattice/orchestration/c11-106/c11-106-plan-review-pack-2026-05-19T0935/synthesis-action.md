# Action-Ready Synthesis: c11-106-plan

## Verdict
revise-then-proceed

Reviewer-level verdicts span a wider band: Standard-Claude reads "ready to execute with minor clarifications"; Standard-Codex and both Adversarial reviews land on "needs revision" / "would not send as-is"; Evolutionary reviews accept the scope but want the central decision tightened. The consensus signal that crosses lenses and models is the same one regardless of overall verdict: the plan keeps Section 1 (wire vs. document) as a forked decision, and several downstream ACs silently assume one branch (wiring) without committing to it. That single ambiguity is what makes this `revise-then-proceed` rather than `plan-ready`. The revisions below are surgical, not structural: the plan's overall decomposition is sound and every reviewer agreed on that.

## Apply by default

### Blockers (plan is not yet executable as written)

- **B1: Section 1's "wire OR document" fork must be resolved before delegation.**
  - Where in the plan: Section 1, lines 11–20; acceptance criterion #1 (line 73) treats both branches as pass conditions.
  - Problem: All four downstream tests in Section 2 (AC14, AC16, AC17, AC20) and AC12's linked-worktree/submodule cache-invalidation fixtures implicitly assume the wiring path. If the delegator picks "document forward-only," AC17 needs a different setup ("populate via the production apply path, not the coordinator"), AC12's cache tests become tests of an unused class, and AC20's precondition test exercises code nobody calls in production. The plan currently lets a delegator satisfy the letter of the ACs while leaving the architectural drift unresolved.
  - Revision: Make wiring `GitContextResolverCache` into the production resolver path **mandatory** (not optional). Keep `DerivationCoordinator` adoption decoupled: explicitly allow Alternative B from Standard-Codex — cache-aware resolution wired into `TabManager`'s probe path, with `DerivationCoordinator` documented as a forward seam if its current async/main-callback shape doesn't fit the synchronous snapshot path cleanly. Rewrite acceptance criterion #1 to: "(a) the production git-context probe goes through `GitContextResolverCache`; (b) `DerivationCoordinator`'s production status is stated explicitly in code comments + `skills/c11/references/metadata.md` — either load-bearing with one named call site, or forward-seam with the documentation refresh." Delete the standalone "documentation-only" branch.
  - Sources: Standard-Codex § "1. The plan must choose 'wire' or 'document' before delegation"; Adversarial-Codex § "Executive Summary" + § "Challenged Decisions" first paragraph; Adversarial-Claude § "Decision 1" / § "The 'deferred-to-operator' bait-and-switch" / Q1 in Hard Questions; Standard-Claude Q3 (recommends operator confirm but agrees "wire it in" is correct); Evolutionary-Claude § "1. Reframe scope item #1 as the spine of the ticket" (explicitly calls the doc-only branch a "trap"); Evolutionary-Codex § "How It Could Be Better" first paragraph.

- **B2: Cache key `(cwd, mtime(headPath))` is incorrect for submodules and must be specified.**
  - Where in the plan: Section 1, line 17 ("Cache key = `(cwd, mtime(headPath))` where `headPath = git rev-parse --git-path HEAD`").
  - Problem: From a submodule cwd, `git rev-parse --git-path HEAD` resolves to the submodule's HEAD, not the superproject's. C11-104's resolver returns combined outer + inner context; if the superproject branch changes while the submodule HEAD is stable, a one-HEAD cache key serves stale outer-branch values. The same key also doesn't address linked-worktree-removed-and-recreated cases under coarse fs mtime. Plan claims `git rev-parse --git-path HEAD` "works correctly for linked worktrees and submodules" — true for linked worktrees, false for the combined submodule case.
  - Revision: For submodule cwds, the cache key must include both the resolved superproject HEAD path mtime *and* the submodule HEAD path mtime (or skip caching submodule-combined contexts entirely until multi-HEAD invalidation is implemented). State the policy explicitly in Section 1. The AC12 fixture tests must include a submodule fixture that mutates the outer HEAD while the inner HEAD is unchanged, and assert the cache invalidates.
  - Sources: Standard-Codex § "Executive Summary" + § "2. Cache key semantics are underspecified for submodules"; Adversarial-Codex § "Assumption Audit" load-bearing #2; Adversarial-Claude § "Blind Spots" #3.

- **B3: Nil-result caching policy is undefined and can make negative results sticky.**
  - Where in the plan: Section 1, line 17 (cache key description); the plan does not specify what is cached.
  - Problem: If `headPath` is nil (not-in-repo, missing cwd, bare repo, timeout, broken gitdir), all of those collapse to `(cwd, nil)`. Caching that result means a later `git init`, repaired worktree, or recovered command remains invisible until eviction. Two reviewers raised this independently.
  - Revision: Specify the policy explicitly. Recommended: only cache results where a resolved HEAD path exists and its mtime was read successfully. Do not cache nil-head states. If the operator wants nil caching, the key must include an independent invalidation input (e.g., cwd directory mtime). Add a unit test that asserts `(cwd, nil)` results are re-resolved on subsequent calls.
  - Sources: Standard-Codex § "3. Caching nil can create stale negative results"; Adversarial-Codex § "Blind Spots" cache-invalidation paragraph (multiple dependency files / submodule combined).

- **B4: AC20 test pattern is not viable as described; commit to a concrete approach or downgrade explicitly.**
  - Where in the plan: Section 2, line 29 ("Either `XCTExpectFailure` around a main-thread invocation, or precondition-fatal test pattern").
  - Problem: `XCTExpectFailure` does not trap `dispatchPrecondition` — preconditions abort with EXC_BAD_INSTRUCTION, not XCTFails. The C11-104 validation report already admitted this is hard; the plan repeats both options as if they're equivalent. A delegator following this instruction will most likely reproduce the existing weak sentinel-test pattern.
  - Revision: Pick one concrete approach. Either (a) subprocess fatal-test harness (`Process` launches a helper binary that calls the coordinator from main; parent asserts non-zero termination and the precondition diagnostic in stderr), or (b) explicit downgrade — keep the existing off-main sentinel test, add a `// AC20: in-process precondition crash testing is unsafe in XCTest; sentinel verifies off-main happy path only` comment, and record the residual gap in the PR body and the validation-plan addendum. Forbid the implementer from inventing a third "weak fake" pattern.
  - Sources: Standard-Claude § "Weaknesses and Gaps" #2 + Q7; Standard-Codex § "6. AC20 is likely fragile unless implemented as a subprocess fatal test"; Adversarial-Claude § "Hard Questions" #8; Adversarial-Codex § "How Plans Like This Fail" + § "Hard Questions" #10; Evolutionary-Codex § "Concrete Suggestions" AC20 paragraph.

### Important (revise before implementation starts)

- **I1: `GitRunner` result type cannot distinguish timeout from other failures; AC14 needs an API decision.**
  - Where in the plan: Section 2, line 26 (AC14 — Git subprocess timeout).
  - Problem: `GitRunner.run` currently returns `String?`. Timeout, non-zero exit, missing git binary, not-in-repo, bare clone, broken HEAD all collapse to nil. The AC14 test as worded ("assert defined timeout result") cannot pass without either (a) changing `GitRunner` to return a typed result enum, (b) adding a timeout-aware runner API used only by the resolver, or (c) accepting "timeout maps to nil" and testing only that the subprocess terminates within budget. The plan should pick.
  - Revision: Choose one. Recommended: option (c) for this PR — assert subprocess termination within the budget + nil result + no hung queue. Note in the plan body that typed timeout state is a follow-up (it pairs naturally with the `.stale` work in Section 4). If the operator wants typed timeout now, expand AC14 to include the `GitRunner` result-type refactor and add it to the AC list with a concrete return enum.
  - Sources: Standard-Codex § "4. Timeout needs an API shape, not just a test"; Adversarial-Codex § "Blind Spots" timeout paragraph + § "Hard Questions" #9; Evolutionary-Codex § "Concrete Suggestions" AC14 paragraph; Adversarial-Claude § "Hard Questions" #5 (specifically: which value to assert).

- **I2: Decide the timeout-value question (5s vs 2s) before writing the AC14 test.**
  - Where in the plan: Section 2, line 26 ("Also: settle the 2s-vs-5s question (spec said 2s; impl is 5s)"); Section 6 (line 58, "optional polish").
  - Problem: AC14's test value and Section 6's optional polish are coupled. If AC14 is written first against the current 5s implementation, the test cements 5s and the SPEC's 2s gets forgotten; if the implementation is changed to 2s in Section 6, the AC14 test has to be retrofitted. The plan currently treats Section 6 as optional and Section 2 as required.
  - Revision: Lift the 2s-vs-5s decision out of Section 6 and into Section 2 explicitly. Two acceptable resolutions, neither requiring operator intervention: (a) keep 5s, amend the v2 SPEC to 5s with a note explaining "conservative for slow disks," write AC14 against 5s; (b) move to 2s in this PR, write AC14 against 2s. The decision is recorded in the PR body. Forbid writing the AC14 test before this decision is made.
  - Sources: Adversarial-Claude § "How Plans Like This Fail" #4 + § "Decision 4" + § "Hindsight Preview" #4 + Q5; Standard-Codex § "Hard Questions" #11; Evolutionary-Codex § "Questions" #5; Standard-Claude § "Weaknesses and Gaps" #2 (implicit).

- **I3: Section 4 (`.stale` state) is structurally coupled to Section 3 (enum rename) and shouldn't be optional if the rename is taken.**
  - Where in the plan: Section 3 (lines 31–38) recommends renaming `nil`/`.unknown` to `.noBranch`/`.notInRepo`. Section 4 (lines 40–44) describes `.stale` as "decide whether to pick it up here or leave as a known-deferred edge case."
  - Problem: If the enum is being reshaped anyway, adding `.stale` is essentially free; deferring `.stale` means a third touch on the same enum in another PR and another search-and-replace across `switch` statements, `WorktreeChipProjector`, `applyDerivedWorktreeBranchMetadata`, snapshot encode paths, and tests. The plan is asymmetrically firm on rename (recommended) and neutral on `.stale`.
  - Revision: Couple them. If Section 3 takes the rename path, Section 4 (`.stale` introduction + AC10 test) becomes mandatory in the same PR. If Section 3 instead amends the SPEC to keep `nil`/`.unknown`, Section 4 stays deferred (no rename = no cheap window). Surface this coupling explicitly in the plan body.
  - Sources: Standard-Claude § "Architectural Assessment" "asymmetry" paragraph + § "Alternatives Considered" Section 4 + Q4; Adversarial-Claude § "Decision 5"; Adversarial-Codex § "Challenged Decisions" stale paragraph; Evolutionary-Claude § "Sequencing" Phase C / § "Where to under-invest" (couple `.stale` to enum decision).

- **I4: The enum rename is not a search-and-replace; specify the semantic contract for each new state.**
  - Where in the plan: Section 3, line 38 ("the cost is a search-and-replace + the AC10 stale test"); Section 4 implies similar.
  - Problem: Adding `.stale` and `.notInRepo` to `GitContextKind` (and renaming `.unknown` → `.noBranch` on `BranchValue`) changes the **shape** of the enum, not just its labels. Every `switch` over the enum needs a new case (compiler-enforced unless any site uses `default`). The projector currently renders `.unknown` as `"(no branch)"` while `applyDerivedWorktreeBranchMetadata` writes an empty derived `branch` for `.unknown` — that contract mismatch must be resolved in the new shape. The plan understates this as text edits.
  - Revision: For each new/renamed state, specify three behaviors explicitly in the plan body: (a) what `WorktreeChipProjector` renders (chip text + dim state), (b) what `applyDerivedWorktreeBranchMetadata` writes to the metadata store (empty string vs. key removal vs. specific token like `"(no branch)"`), (c) what `c11 get-metadata --key branch`/`--key worktree` returns through the socket. Resolve the existing `.unknown` projector-vs-store mismatch in the same pass. Use a small table in Section 3.
  - Sources: Standard-Codex § "5. The `.stale` / `.notInRepo` / `.noBranch` rename is not merely naming"; Adversarial-Claude § "Assumption Audit" #4 + § "Hard Questions" #9; Adversarial-Codex § "Assumption Audit" "Load-bearing assumption: adding `.stale`..." + § "Hard Questions" #15.

- **I5: Threading model for the wired cache/coordinator is unspecified.**
  - Where in the plan: Section 1, lines 16–17 (describes call shape but not the queue/threading contract).
  - Problem: `TabManager.initialWorkspaceGitMetadataSnapshot` is `nonisolated static` and runs on the existing `initialWorkspaceGitProbeQueue` with generation-token + expected-cwd guards. `DerivationCoordinator.run` is async and completes on main with its own `dispatchPrecondition(.notOnQueue(.main))` guard. Wiring without specifying the threading contract risks one of: (a) double-call (legacy direct + coordinator), (b) a structural rewrite of the snapshot path that changes its synchrony contract for every caller, (c) a precondition crash on a cold-launch path. The plan must pick.
  - Revision: State in Section 1: which queue owns the coordinator/cache work (recommendation: reuse `initialWorkspaceGitProbeQueue`); how generation tokens and expected-cwd guards interact with the coordinator's result (recommendation: keep them in `TabManager.applyWorkspaceGitMetadataSnapshot`, not in the coordinator); whether `initialWorkspaceGitMetadataSnapshot` remains synchronous (recommendation: yes — the cache wraps `GitContextResolver.resolve`, the coordinator's async callback path is not used by this wiring); and what stops a second deriver from later getting scheduled on main and tripping the precondition (recommendation: document the precondition contract in code + skill reference).
  - Sources: Standard-Claude § "Weaknesses and Gaps" #1 + Q5; Standard-Codex § "Architectural Assessment" + § "Hard Questions" #2–#5; Adversarial-Claude § "Blind Spots" #2 + § "Hard Questions" #2; Adversarial-Codex § "Blind Spots" coordinator-API paragraph + § "Hard Questions" #4–#5.

- **I6: Section 5 (dead-code deletion) needs a safety protocol beyond `grep`.**
  - Where in the plan: Section 5, lines 46–54 ("Grep for callers; if confirmed dead, delete").
  - Problem: Swift call sites can hide behind protocol witness tables, `@objc` exposure, KeyPath references, or be in test-only files / persistence migrations / snapshot-restore. A `grep` in `Sources/` doesn't prove absence. The C11-104 validator's P6 noted underlying state fields still feed legacy callers; the cleanup is less obviously dead than the plan implies.
  - Revision: Replace "grep + delete" with a three-step protocol: (1) `grep` in `Sources/` and `c11Tests/` and `tests_v2/`; (2) compile both `c11-logic` and `c11-unit` schemes after deletion (compiler is the authoritative dead-code prover); (3) check the snapshot-restore + persistence migration paths haven't silently lost a field. If any caller remains, leave the helper in place and add a `// TODO(c11-followup): retire after AC24 callers migrate` comment. Demote Section 5 from acceptance criterion to "optional cleanup, no behavior change" so it can't gate the PR.
  - Sources: Standard-Claude § "Weaknesses and Gaps" #4 + Q8; Standard-Codex § "7. Dead-code cleanup may be less dead than the plan implies"; Adversarial-Claude § "How Plans Like This Fail" #3 + § "Assumption Audit" #5 + § "Hard Questions" #11; Adversarial-Codex § "Challenged Decisions" dead-code paragraph.

- **I7: Section 7 (validation-plan annotation) should produce a v3 addendum, not edit the v2 file in place.**
  - Where in the plan: Section 7, lines 62–63 ("Annotate the v2 validation plan in-place (or a v3 section)").
  - Problem: The v2 validation plan and the audit report are historical evidence — what was known at #181's merge time. Editing them in place blurs the audit trail. Three reviewers agreed on this independently.
  - Revision: Pick the v3 addendum / dated addendum approach. Either a new file `.lattice/orchestration/c11-104/validation-plan-c11-106-addendum.md` (or similar) or a clearly-marked appended section in the existing v2 file with a "## C11-106 amendments (2026-05-19)" header that doesn't edit prior content. The plan should specify the chosen file path.
  - Sources: Standard-Claude § "Weaknesses and Gaps" #6 + Q10; Standard-Codex § "8. Validation-plan hygiene should not mutate historical evidence casually"; Adversarial-Codex § "Cosmetic assumption" + § "Hard Questions" #16; Evolutionary-Codex § "Concrete Suggestions" final paragraph.

- **I8: AC16 needs to exercise the external socket handler, not just `SurfaceMetadataStore`.**
  - Where in the plan: Section 2, line 27 (AC16).
  - Problem: The `source=derived` rejection lives in `TerminalController`'s socket frame handlers (4 call sites cited). If the test just calls `SurfaceMetadataStore.setMetadata(... source: .derived)` directly, it doesn't exercise the contract that AC16 is meant to verify (external writes from the socket can't masquerade as derived). The plan says "from a non-internal-caller path" but doesn't say through which surface — store, parser, full socket loop.
  - Revision: Specify the test must invoke the external socket frame handler (or its directly-extracted parser/dispatcher seam) — not the store API. Acceptable seams: (a) full unix-socket loop in a `tests_v2/`-style integration test, (b) an extracted handler function in `TerminalController` callable from a logic test with a fake controller context. Whichever seam the delegator picks, document it in Section 2 so the next reviewer can see what was actually tested. One representative call site is sufficient (the rejection logic is uniform) — "all four" is belt-and-braces and not required.
  - Sources: Standard-Claude § "Weaknesses and Gaps" #8 + Q12; Standard-Codex § "Blind Spots" socket-tests paragraph + § "Hard Questions" #11; Adversarial-Codex § "How Plans Like This Fail" + § "Hard Questions" #11; Adversarial-Claude § "Hard Questions" #6.

### Straightforward mediums

- **M1: Update `TabManager.swift:1724` reference to be a function-name reference, not a line number.**
  - Where in the plan: Section 1, line 14.
  - Problem: Line numbers in a 5,539-line god-class drift across rebases. The local main this review was performed against didn't have #181 merged; the line reference was already off the local-main HEAD even though it's correct against `2b1be4220`.
  - Revision: Replace "`TabManager.swift:1724` calls `GitContextResolver.resolve(cwd:)` directly" with "`TabManager.initialWorkspaceGitMetadataSnapshot(for:)` calls `GitContextResolver.resolve(cwd:)` directly." Apply the same convention elsewhere in the plan if any other `TabManager.swift:NNNN` references appear.
  - Sources: Standard-Claude § "The Plan's Intent vs. Its Execution" + Q1.

- **M2: Add an explicit reference to `code/c11/CLAUDE.md` "Testing policy" so the delegator doesn't run `c11-unit` locally.**
  - Where in the plan: Acceptance criteria, line 77 ("CI green; no regressions in `c11-logic` or `compat-tests`").
  - Problem: Project policy is explicit: `c11-logic` is local-safe, `c11-unit` / `compat-tests` / `test-e2e` go to CI; running `xcodebuild test` against `c11-unit` locally launches an untagged `c11 DEV.app` and crashes the operator's running instance. The plan's AC doesn't reference this; a delegator coming from outside might not know.
  - Revision: Append to acceptance criterion #5: "Local validation loop: `xcodebuild -scheme c11-logic test` plus a tagged-build reload (`./scripts/reload.sh --tag c11-106`) for any code on the typing-latency hot path. Defer `c11-unit`, `compat-tests`, and `test-e2e` to CI per `code/c11/CLAUDE.md` § 'Testing policy'. Never `open` an untagged `c11 DEV.app`."
  - Sources: Standard-Claude § "Weaknesses and Gaps" #5 + Q9.

- **M3: Add an explicit acceptance criterion for the metadata reference doc update.**
  - Where in the plan: Acceptance criteria (lines 73–78) currently bundle the doc update implicitly inside criterion #1's "documented in code + skill reference as forward-looking-only" branch.
  - Problem: Whichever way Section 1 resolves, `skills/c11/references/metadata.md` needs an edit. If wiring, the current "seam" framing becomes inaccurate; if forward-only, the framing needs to be sharper. The doc update should be an explicit AC, not buried in one branch of Section 1.
  - Revision: Add a new acceptance criterion: "`skills/c11/references/metadata.md` is updated to reflect the production status of `DerivationCoordinator` + `GitContextResolverCache` chosen by Section 1. The update names the production call site(s) if wiring; states `DerivationCoordinator` is a forward seam if not."
  - Sources: Standard-Claude § "Weaknesses and Gaps" #7 + Q11; Evolutionary-Codex § "The Flywheel" #1.

- **M4: Add commit hygiene guidance for the single-PR bundling.**
  - Where in the plan: Section 7 / acceptance criteria; the plan doesn't specify commit structure within the PR.
  - Problem: Six categories of work in one PR is fine, but if AC33-type typing-latency regressions surface post-merge, the operator needs commit-level bisection granularity. Two reviewers raised this independently.
  - Revision: Add to acceptance criteria: "Commits in the PR are organized one-per-section (or one-per-meaningful-unit): a 'cache wiring' commit, a 'missing tests' commit, an 'enum rename + .stale' commit, a 'dead-code cleanup' commit, etc. Do not squash before merge. This preserves bisection granularity if a hot-path regression appears post-merge."
  - Sources: Standard-Claude Q2; Adversarial-Claude § "Hard Questions" #15 + § "Decision 1" + § "Blind Spots" #7; Adversarial-Codex § "How Plans Like This Fail" (bundling paragraph).

- **M5: File the AC19 follow-up ticket explicitly, with a number, before C11-106 starts.**
  - Where in the plan: "Out of scope" section, line 67 ("AC19 (restore-warmpath snapshot pre-paint). Real follow-up but separate ticket — touches workspace restore lifecycle").
  - Problem: "Separate ticket" without a ticket number is an informally-indefinite defer. AC19 is the most user-visible deferred item from #181 (chips paint blank on session restore).
  - Revision: Before C11-106 delegation starts, file a Lattice ticket for AC19 (working title: "C11-104 follow-up: restore-warmpath snapshot pre-paint for sidebar chips"). Reference its ID in C11-106's "Out of scope" section. The ticket doesn't have to be planned yet — it just has to exist so the deferral is tracked.
  - Sources: Adversarial-Claude § "Decision 6" + § "Hard Questions" #19.

- **M6: Confirm fixture-building cost in the AC12 estimate.**
  - Where in the plan: Section 1, line 20 ("The cost is modest (~50-100 lines of glue + the two cache invalidation tests)").
  - Problem: A real submodule fixture in `c11Tests/` is meaningfully more than test-glue — either an in-tree fixture (large tarball cost), a temp-dir `setUp` builder (slow + git-version-flaky on CI), or a checked-in skeleton with build-time hydration. The "~50–100 lines" estimate doesn't separate the glue from the fixture.
  - Revision: Split the cost estimate in Section 1: "wiring glue: ~50–100 lines; AC12 fixture infrastructure (linked-worktree + submodule scratch dirs in `setUp`, with deterministic HEAD-path manipulation): additional ~100–200 lines + one-time review of the fixture pattern." If an existing `c11Tests/` helper builds submodule fixtures, reference it; if not, acknowledge the fixture is greenfield.
  - Sources: Adversarial-Claude § "How Plans Like This Fail" #6 + § "Blind Spots" #8; Adversarial-Codex § "Hindsight Preview" early-warning #5 (fake mtimes vs. real fixtures).

### Evolutionary clear wins

- **EW1: Add the "how to add a deriver" mini-section to `skills/c11/references/metadata.md` after wiring.**
  - Where in the plan: Currently no scope item.
  - Problem: Once Section 1 lands the coordinator/cache as load-bearing, the next agent who tries to add a second deriver (host, container, kubectl) will re-derive the conventions — queue choice, cache key, stale guard, source `.derived`, snapshot exclusion, socket read behavior, test pattern — from scratch. A short ~30-line doc-block prevents that.
  - Revision: Add an acceptance criterion: "`skills/c11/references/metadata.md` includes a short 'How to add a MetadataDeriver' section listing the contract (off-main, cache-key choice, snapshot exclusion, source `.derived`, projector update, test pattern) with `GitContextDeriver` named as the reference implementation." Roughly 20–40 lines of prose. This is genuinely cheap and compounds for every future deriver.
  - Sources: Evolutionary-Claude § "Concrete Suggestions" #6 + § "Suggestion 5"; Evolutionary-Codex § "The Flywheel" #1.

## Surface to user (do not apply silently)

- **S1: Add a second deriver (stub `HostDeriver` or refactor `terminal_type` through `MetadataDeriver`) inside C11-106 itself.**
  - Why deferred: scope-creep / author-intent-needed.
  - Summary: Both evolutionary reviews argue independently that the `MetadataDeriver` protocol is unverified until it has two conformers — a protocol with one conformer is just a refactored class. Evolutionary-Claude suggests `HostDeriver` returning `"local"` (~30 LOC) or refactoring `terminal_type` heuristic; Evolutionary-Codex implies the same in its "next unlock" framing. This is a structural payoff (verified protocol genericity, easier next-deriver landing) but it's also scope-expansion the plan author may not want in C11-106. The operator should decide whether C11-106 is the moment to prove the seam by adding the second deriver, or whether to defer that to a follow-up ticket explicitly.
  - Sources: Evolutionary-Claude § "Concrete Suggestions" #2 + § "Mutations and Wild Ideas" + § "The Flywheel" #2; Evolutionary-Codex § "What It Unlocks" + § "Mutations" (context strip).

- **S2: Refactor toward lifecycle/domain enum separation (`DerivationLifecycle` envelope + git-specific domain enum).**
  - Why deferred: design-needed / scope-creep.
  - Summary: Evolutionary-Claude argues the proposed rename (`BranchValue.noBranch`, `GitContextKind.notInRepo` + `.stale`) bakes git-specific naming into states (`.stale`, `.timeout`, `.pending`) that every future deriver will want. The structural answer is to separate a generic `DerivationLifecycle` enum (`.fresh` / `.stale` / `.unknown` / `.pending` / `.timeout`) from a git-specific domain enum (`.linkedWorktree` / `.mainCheckout` / `.detached` / `.notInRepo` / `.bare`). This is the most evolutionary move on the table and the most consequential structural decision in the rename. It's larger than C11-106 should absorb without explicit approval. Evolutionary-Codex's typed `GitContextResolution` enum proposal is a milder variant of the same idea.
  - Sources: Evolutionary-Claude § "Concrete Suggestions" #3 + § "Mutations" #1; Evolutionary-Codex § "Concrete Suggestions" typed-outcomes paragraph.

- **S3: Mark FSEvents-based cache invalidation as the explicit follow-up in C11-106's plan body.**
  - Why deferred: scope-creep / well-out-of-C11-106-scope.
  - Summary: Both evolutionary reviews note mtime polling is the entry-level pattern; FSEvents is the structural answer for an N-deriver world. C11-106 should not implement FSEvents, but acknowledging it as the intended replacement (TODO comment in the cache class + a one-line note in the plan body + a filed follow-up Lattice ticket) prevents the mtime version from becoming a permanent ceiling. Whether to file the follow-up ticket now or after C11-106 lands is an operator call.
  - Sources: Evolutionary-Claude § "Concrete Suggestions" #4 + § "Sequencing"; Evolutionary-Codex § "What It Unlocks" + § "Sequencing".

- **S4: Demote Section 6's ThemeKey-backed dim opacity work out of C11-106.**
  - Why deferred: scope / author-intent-needed (one reviewer pushes back, others accept the plan's "optional" framing).
  - Summary: Adversarial-Codex argues the ThemeKey-backed opacity work is user-visible polish unrelated to the architecture/test debt and conflicts with the plan's stated "no user-visible sidebar render change" boundary (line 69). The other reviews accept it as small optional polish. The operator should decide whether to keep it in C11-106 (and accept that the no-visible-change rule loosens) or split it into a separate tiny visual-polish ticket. Recommendation: split — but this is a judgment call the plan author/operator should make.
  - Sources: Adversarial-Codex § "Challenged Decisions" opacity paragraph; Standard-Codex § "Key Strengths" + § "How Plans Like This Fail" (treats optional as optional).

- **S5: Whether to verify AC33 (typing-latency burst) as part of C11-106 itself.**
  - Why deferred: ambiguous / author-intent-needed.
  - Summary: Adversarial-Claude flags that the parent C11-104 never had an operator-driven AC33 typing-latency pass; C11-106 is layering more work on the same hot path. The plan's AC #5 ("CI green; no regressions in `c11-logic` or `compat-tests`") doesn't cover typing-latency, which CI can't easily verify. The operator should decide whether to require a tagged-build smoke pass as part of C11-106's merge gate, or accept that the typing-latency commitment remains unverified post-follow-up too. This is genuinely a strategic call (extra cost vs. extra confidence).
  - Sources: Adversarial-Claude § "How Plans Like This Fail" #1 + § "Decision 7" + § "The Uncomfortable Truths" #6 + § "Hard Questions" #18.

- **S6: Whether to split C11-106 into two PRs (wiring + cleanup) for blast-radius reasons.**
  - Why deferred: disagreement / author-intent-needed.
  - Summary: Standard-Claude considers and rejects the split ("size of work doesn't justify it"); Adversarial-Claude argues for the split ("section 1 has real risk, the rest is bounded cleanup"); Standard-Codex offers it as Alternative D ("safer if the team is worried about typing-latency regressions"). Reviewers disagree. If B1's "wiring is mandatory" revision is applied, the size of Section 1 grows and the split case strengthens; if the operator accepts I5's "wrap cache around `GitContextResolver.resolve`, defer coordinator-as-scheduler" approach, the split case weakens. The operator should weigh this after seeing the post-revision shape of Section 1. Recommendation: keep as one PR with M4's commit-hygiene rule, but flag the split as an option the delegator can invoke mid-flight if Section 1 unexpectedly grows.
  - Sources: Standard-Claude § "Alternatives Considered" + § "Architectural Assessment"; Standard-Codex § "Alternative D"; Adversarial-Claude § "Decision 1" + § "Challenged Decisions" + § "The Uncomfortable Truths" #7.

- **S7: How explicit Section 3's "rewrite the SPEC" branch should be about ownership.**
  - Why deferred: design-needed.
  - Summary: Adversarial-Claude points out the SPEC source per the validation report is the C11-104 Lattice ticket description. If Section 3 takes the "rewrite SPEC" branch, who owns the edit? Is the ticket description amended as a hindsight rewrite, with a "spec amended post-merge in C11-106" note? Is there an audit trail? The plan is silent. If the recommended path (rename) is taken, this question is moot; if it isn't, the audit-trail question matters.
  - Sources: Adversarial-Claude § "Blind Spots" #6 + § "Decision 3".

## Evolutionary worth considering (do not apply silently)

- **E1: Treat C11-106 as the "derived-metadata seam becomes the product" inflection ticket.**
  - Summary: Both evolutionary reviews converge on the same large reframe: C11-104's worktree+branch chips are exhibit A, not the destination. C11-106 is the first ticket that touches the derived-metadata seam after #181 lands; how it lands shapes whether the seam becomes a one-deriver curio or a foundation for host/container/kubectl/PR/CI/Lattice-task derivers. The reframe affects scope (S1 second deriver), structure (S2 lifecycle/domain split), naming, and the long-arc capability ladder (cross-pane queries, derived-as-telemetry, Lattice task autoderivation). Adopting the reframe doesn't necessarily mean expanding C11-106's scope — it can mean leaving better breadcrumbs (TODO comments, follow-up tickets, the EW1 "how to add a deriver" doc) inside an otherwise tight ticket. The bet is one the plan author and operator should evaluate together rather than have a synthesizer impose.
  - Why worth a look: This is the single most consequential framing decision available, and both evolutionary lenses found it independently. It costs little to adopt (~one paragraph of plan-body reframing + the EW1 doc + S3's FSEvents follow-up note) and compounds for every future deriver.
  - Sources: Evolutionary-Claude § "Executive Summary" + § "What's Really Being Built" + § "Closing thought"; Evolutionary-Codex § "Executive Summary" + § "What's Really Being Built" + § "What It Unlocks".

- **E2: Lattice-task deriver as the highest-value next derived signal for the operator-running-N-agents use case.**
  - Summary: Evolutionary-Claude proposes a `LatticeTaskDeriver` that maps a pane's worktree branch to its Lattice ticket and writes `task` / `status` derived metadata automatically. The agent stops having to remember to update its sidebar chip; just being in the right worktree means the status writes itself. For Stage 11's own use case (Atin running parallel agents on Lattice-tracked tickets) this is potentially the most impactful single follow-up deriver — and Lattice CLI calls are cheap. Not a C11-106 deliverable, but a "should this be next?" decision the operator should weigh.
  - Why worth a look: It's the deriver that has the best operator/agent value-ratio in the catalog, and it requires the C11-106 seam to be load-bearing. Filing it as a follow-up ticket right after C11-106 ships would chain the evolutionary momentum.
  - Sources: Evolutionary-Claude § "Mutations" #3.

- **E3: A small lightweight diagnostic counter / debug log around cache hit/miss/stale/timeout, added in C11-106 itself.**
  - Summary: Evolutionary-Codex argues that without instrumentation, future performance issues with the cache are hard to explain. A single internal counter struct (`cacheHits`, `cacheMisses`, `cacheStale`, `derivationTimeouts`) accessible via debug logging — no UI, no telemetry — costs ~30 LOC and makes the next round of observability work cheap. It also pairs naturally with the AC14 timeout decision (I1/I2) and with the cache-invalidation tests (B2, B3).
  - Why worth a look: Cheap, in-scope, and the only reviewer suggestion that addresses Adversarial-Claude's "the cache wiring lands but no one looks at hit/miss rates" hindsight risk.
  - Sources: Evolutionary-Codex § "The Flywheel" #2; Adversarial-Claude § "Hindsight Preview" early-warning signs.
