# Adversarial Trident Synthesis — C11-193

- **Plan under review:** `.lattice/plans/task_01KZAV2VHK2TPFPXE8C7S1YNQ8.md`
- **Ticket:** "launch-agent: refuse to start an agent in another agent's linked worktree"
- **Sources synthesized:** `adversarial-claude.md`, `adversarial-codex.md`, `adversarial-gemini.md`
- **Synthesis date:** 2026-08-06

---

## Executive Summary

All three adversarial reviewers independently reached the same verdict: **do not hand this plan to an implementer as written.** No reviewer disputed the ticket's intent. Every reviewer concluded the five-step plan is an issue decomposition rather than an executable plan, and that the decisions it defers are precisely the ones that determine whether the feature is useful, harmful, or inert.

Five findings are unanimous (3/3):

1. **The plan assumes a cwd seam that does not exist.** All three note that "inherited cwd" is not a materialized value at the guard point. Claude enumerates three divergent candidates (CLI caller shell cwd, target pane's parent-surface cwd, app-process cwd); Codex traces the code path showing omission collapses to `nil` and inheritance is decided downstream at workspace/Ghostty layers; Gemini frames the same gap at the CLI/socket boundary. The guard can therefore approve one directory and spawn in another.
2. **C11-194 will collide with this work, and neither plan names the other.** All three flag the sibling ticket's cwd-precedence centralization as a merge-order hazard that decides product behavior regardless of which branch's tests are green.
3. **A `git` subprocess on the launch path has no specified timeout, threading, or failure policy.** All three raise it. Fail-open reinstates the silent failure the ticket exists to eliminate; fail-closed breaks all launches. The plan chooses neither.
4. **"Linked worktree" is not evidence of "another agent's tree."** Git records topology, not ownership or liveness. All three call the inference out; Claude quantifies the damage (38 live worktrees, house workflow gives every delegator one), Gemini adds that human operators use worktrees heavily too.
5. **Submodules are a live false-positive risk** that the plan's two-command probe description does not address.

Two findings are 2/3 but carry the highest information value:

- **The probe already exists.** Claude and Codex both identify `GitContextResolver.resolveOuter` (`Sources/Metadata/GitContextResolver.swift`) as a mature, tested, injectable implementation of the exact `--git-dir` vs `--git-common-dir` comparison, which additionally handles submodule superprojects, stale worktrees, detached/unborn HEAD, path normalization, and bounded timeouts. The plan does not mention the file. Both reviewers treat this as evidence the codebase was not read before the plan was written.
- **The plan discards its own justification.** Claude states it most sharply: the ticket's case for a guard over a better default is that a guard "also holds when someone passes `--cwd` explicitly." The plan's step 3 then permits explicit `--cwd`. What remains is a loud default, which is C11-194's job.

The reviewers disagree productively on one axis worth surfacing to the author: **where this logic belongs.** Codex argues for the server launch boundary so wrappers cannot bypass it. Gemini argues it does not belong in the c11 binary at all, that it violates the "unopinionated about the terminal" principle, and should live in the `lattice-orchestrator` skill. Claude argues for a third framing entirely: use c11's own per-surface `MetadataKey.worktree` store instead of a git proxy, which needs no subprocess and answers the actual invariant. These are three different answers to "what layer owns this?", and the plan does not currently ask the question.

---

## 1. Consensus Risks (flagged by multiple models)

Ordered by consensus strength, then severity.

### 1.1 Unanimous (3/3)

1. **No implementable effective-cwd contract.** The value the guard inspects and the value the PTY receives are not proven to be the same string.
   - *Claude:* three divergent cwds (`A2`); the CLI never transmits the caller's shell cwd (`cli/c11.swift:2328`); the server already conflates the app-process cwd into project-config lookup (`SocketDispatch.swift:1069`).
   - *Codex:* `v2ResolveCwdParam` collapses omission to `nil` (`TerminalController.swift:2753-2779`); fallback is selected-workspace state or Ghostty config inheritance among selected/focused/remembered candidates (`Workspace.swift:8355-8421`). Prescribes an `AgentLaunchCwdResolution` value of `{path, source, isExplicit}`.
   - *Gemini:* the "Invisible Override" anti-pattern. If the CLI resolves `$PWD` client-side and forwards it, the server cannot distinguish inherited from explicit at all.
   - **Combined severity: blocking.** This is the root defect; several other findings are downstream of it.

2. **C11-194 race with no declared dependency or merge order.** Both plans modify the same resolution; both are live in `.lattice/`.
   - Concrete failure both Claude and Codex construct: a linked workspace root plus a safe surface cwd (or the reverse) produces a false refusal or a missed linked root, with both branches' unit suites green.
   - Claude adds the structural gap: the guard's explicit/inherited binary has **no slot for "configured."** After C11-194, a deliberately-set workspace root is as intentional as `--cwd`, and the guard would punish it.
   - Gemini adds the mechanical risk: C11-194 may rewrite the target code out of the shape this plan expects.

3. **Git subprocess on the launch path: unspecified timeout, threading, and failure policy.**
   - *Codex* is most specific: `GitContextResolver.resolve` deliberately traps on the main queue (`GitContextResolver.swift:264-280`), `TerminalController` is `@MainActor`, and `agent.launch` is absent from `socketWorkerV2Methods`. A naive implementation either blocks the UI thread, traps, or probes the wrong cwd. Moving the call off-main and synchronously waiting converts the trap into an app stall.
   - *Codex* also identifies the deadline interaction: 5s per-call git timeout against a 10s CLI socket deadline (`cli/c11.swift:942-969`). A slow probe can time out the client while the server later creates the agent, and an orchestrator retry then creates duplicates.
   - *Claude:* ~6 `rev-parse` subprocesses via the full `resolve()` path; the launch-agent reference explicitly warns the app-process PATH is poorer than a pane's login-shell PATH.
   - *Gemini:* latency on deep trees and network mounts violates the "fast, fluid, effective" mission.
   - **The undecided fail-open/fail-closed fork is called out by all three as the single most important missing decision.**

4. **Linked-worktree detection is a proxy for ownership, not a proof of it.**
   - *Claude:* in this repo the inference is usually wrong. 38 live worktrees exist because `lattice-orchestrator` mandates one per delegator, and a delegator launching its own reviewer into its own worktree is the sanctioned pattern. False-positive rate on the repo's primary workflow approaches 100%.
   - *Codex:* git records topology, not ownership or liveness. The implementation cannot make the stronger claim the message will imply.
   - *Gemini:* human operators use worktrees heavily; this penalizes standard git usage to protect one Lattice automation pattern.

5. **Submodule false positives.**
   - *Gemini:* submodules also use a file-based `.git` pointer; any flaw in the probe blocks launches inside submodules, a major usability regression.
   - *Claude:* verified that `git-dir == git-common-dir` inside `ghostty/`, so a submodule correctly classifies as not-a-linked-worktree, but notes a fresh probe "might get this right by luck."
   - *Codex:* the existing resolver deliberately resolves the outer superproject before the inner submodule (`GitContextResolver.swift:295-317`), which a cwd-local two-command probe would miss.

### 1.2 Strong majority (2/3)

6. **Step 2 duplicates production logic that already handles the plan's hardest cases.** (Claude, Codex.) `GitContextResolver.resolveOuter` (`GitContextResolver.swift:322-364`) performs the exact comparison with absolute-path normalization; `resolveBranch` (`:475-493`) models attached/detached/no-branch; `.stale` covers the `git worktree remove` race; the `GitRunner` seam is injectable and already exercised in tests (`c11Tests/GitContextResolverCacheWiringTests.swift:72-181`). Both reviewers demand either reuse through a thin policy adapter or a written justification for a bounded derivative.

7. **The wire contract is undefined: no error code, no structured data, no human-visible warning path.** (Claude, Codex.)
   - Claude: `docs/launch-agent-reference.md` maintains a structured error table; a refusal needs a code and a row. "Callers cannot branch on prose."
   - Codex: the `warnings` array exists (`SocketDispatch.swift:1114-1117`) but `printV2Payload` discards it outside `--json` (`cli/c11.swift:2340-2344, 5006-5016`). The promised "acknowledgement" is therefore invisible to ordinary human CLI users, and automation would be left parsing unstable prose.

8. **Docs and skill deliverables are missing, against explicit hard rules.** (Claude, Codex.) CLAUDE.md makes CLI/socket changes incomplete until the skill is updated **and** `scripts/sync-installed-skills.sh` is run. Neither `docs/launch-agent-reference.md` nor any skill file nor the sync step appears in the plan. Claude notes the sibling C11-194 plan remembers all of it, and reads the asymmetry as evidence C11-193 was written faster.

9. **The test gate proves the predicate, not the behavior.** (Claude, Codex.) Four pure-logic assertions about a boolean and a message string cannot show that a launch is refused, that no surface/stats/metadata were created before the refusal, that the error reaches the caller legibly, or that an allowed launch lands in the intended directory. Both invoke the repo's "Green Tests ≠ Working Product" rule and demand a tagged build plus a real `c11 launch-agent` from a real worktree.

10. **Entry-point scope is undeclared.** (Claude, Codex.) The guard in `v2AgentLaunch` covers `c11 launch-agent` and `config launch` (which delegates to it, `ConfigHandlers.swift:130-195`). It does **not** cover the A button or `default-agent launch` (`TerminalController.swift:8989+`), nor `new-pane` / `new-split` / `new-workspace`. Claude notes this is arguably backwards: the programmatic path gets guarded while the higher-frequency human path stays open. Codex adds that `config launch` may inherit the guard silently, and saved configs may legitimately encode worktree launches.

11. **Branch capture is not "straightforward," and detached HEAD ships a visible bug.** (Claude, Codex.) `rev-parse --abbrev-ref HEAD` returns the literal string `HEAD` when detached. Claude counted **four of the 38 live worktrees currently detached** (`c11-183-autosave`, `c11-183-staging-main`, `c11-188-rereview-94aeb59c`, `acb-05-persistence`), producing the message `cwd is a linked git worktree on 'HEAD'`. Codex adds that branch is context, not identity: the durable facts are normalized cwd and worktree root/name, with branch rendered as an attached/detached/no-branch supplement.

12. **The guard does not enforce the invariant the ticket declares.** (Claude, Codex.) "NO TWO AGENTS MUTATE THE SAME TREE" is not achievable from one launch site. It permits main checkouts, explicit overrides, multiple explicit helpers in one worktree, non-git directories, post-launch `cd`, and every unguarded entry point. Both insist the claim be narrowed honestly to "prevents one class of accidental inherited-cwd launch."

---

## 2. Unique Concerns (single-model, worth investigating)

### From Claude

1. **The plan removes its own reason to exist.** The ticket prefers a guard to a default because a guard also holds on explicit `--cwd`. Step 3 permits explicit `--cwd`. Two coherent positions remain: enforce on both paths with a real `--allow-worktree` override, or admit this is a loud default and fold it into C11-194. The plan picks neither. **This is the highest-leverage unique finding in the pack: it questions whether the ticket should exist separately at all.**
2. **c11 already knows the direct signal.** `SurfaceMetadataStore` holds `MetadataKey.worktree` per surface, written by `TabManager.applyDerivedWorktreeBranchMetadata` (`TabManager.swift:2481-2542`), and `c11 tree` exposes cwd. "Is another live surface already in this tree, and is it not me?" is answerable in-process with no subprocess, no timeout, no PATH dependency, and near-zero false positives, and it enforces the actual invariant rather than a correlate. The plan does not mention, reject, or appear to know about it.
3. **No escape hatch, despite an established repo idiom.** `pane.create` already ships `--allow-undersized` / `--force` (`cli/c11.swift:2218`), eleven lines above the `launch-agent` case. `--cwd` is not an override because it changes where the agent runs.
4. **No rollout thought for 38 live worktrees.** No warn-then-refuse phase, no measurement. `AgentLaunchStatsStore` records every launch; a two-line "would have blocked" counter would have produced the false-positive rate as a number within a day.
5. **No mechanism to detect being trained around.** If `--cwd` becomes reflexive in prompt templates, the fire rate goes to zero and a dead guard is indistinguishable from a working one. Claude lists five early-warning signs, none of which are observable because the plan adds no counter, log line, or metric.
6. **`--cwd inherit` is silently broken on `launch-agent`.** `new-pane` and `new-split` accept the literal keyword (`cli/c11.swift:2117, 2215`); `launch-agent` line 2328 is a bare `resolvePath(v)`, so `--cwd inherit` becomes `<cwd>/inherit` and errors `not_found`. Pre-existing, but the plan is about to make `--cwd` the load-bearing escape hatch on the command whose `--cwd` handling is the least consistent.
7. **Step 5 instructs a local `c11-logic` run**, cutting against the operator-reinforced rule to defer all local `xcodebuild` to CI (hardened after C11-181, when the operator interrupted exactly such a run).
8. **Nested worktrees complicate the remedy text.** Six worktrees live inside the main checkout at `code/c11/c11-worktrees/*`, so "pass `--cwd` pointing at the project root" is ambiguous and a naive "use the repo root" reflex drops agents into the wrong tree from the other direction.
9. **The triggering incident had zero damage.** One agent only read files, the parent committed before re-briefing, and two of three agents were derailed by a Codex version-update prompt swallowing their briefs, a failure this guard does not touch. The severity is carried by near-miss narrative, which is the emotional state in which teams over-build guards that later get bypassed.
10. **`--new-workspace` with no `--cwd` is never mentioned**, and is plausibly the exact shape of the triggering incident.

### From Codex

11. **Side-effect ordering is unspecified.** Rejection must provably precede surface creation, identity/attention stamping, launch stats, recent-config mutation, delayed prompt scheduling, and command delivery. Otherwise an "empty surface survives a rejection" and retries become confusing. Codex demands an integration test that asserts zero mutation on refusal.
12. **Main-actor threading is a hard blocker, not a detail.** `agent.launch` is not in `socketWorkerV2Methods` (`TerminalController.swift:1964-1991`) and the correct resolver traps on the main queue by design. The plan needs a stated worker/continuation design that keeps subprocess I/O off-main without stealing focus.
13. **Timeout can produce a late launch after the client received failure**, and an orchestrator retry then duplicates the agent. Codex asks for a proof that timeout cancellation is terminal before any mutation.
14. **Make cwd source a first-class enum** so C11-194 can add `.workspaceRoot` without silently changing safety semantics. Codex's own answer: workspace root should count as inherited and be guarded unless the operator explicitly supplied `--cwd`, but it must be written down.
15. **Wire-form ambiguity for "explicit."** The server currently collapses absent, empty, and `inherit` forms. Which of `--cwd <path>`, `--cwd .`, `--cwd inherit`, empty string, and cwd supplied via `config launch` count as intentional acknowledgement? "We infer it from non-nil later" is not a contract.
16. **TOCTOU:** the pane cwd can change between snapshot and surface creation. A rule is needed.
17. **Runtime validation hygiene:** a check that actually launches an agent needs a harmless command strategy, explicit surface cleanup, scratch-only git fixtures, and proof the operator's live checkout was untouched.
18. **Debug telemetry shape:** record `{cwd_source, normalized_cwd, git_outcome, decision, elapsed_ms}` debug-only, with no branch-path telemetry sent externally, and assert the recorded normalized cwd equals the new surface's observed cwd.

### From Gemini

19. **Architectural objection: this violates c11's stated "unopinionated about the terminal" principle.** Injecting a Lattice-specific git-workflow guard into the general-purpose launch primitive is the kind of opinion CLAUDE.md says c11 does not hold. Gemini's proposed alternative is to enforce it in the `lattice-orchestrator` skill, before the launch command is issued.
20. **Baking a moving definition into compiled Swift.** As the Lattice workflow evolves, the definition of a "dangerous" directory changes. A skill-layer check evolves with a file edit; a compiled check evolves with a release.
21. **Subprocess-free probe alternative.** Read the `.git` node directly: if it is a file containing `gitdir:`, read the target and check for `/worktrees/`. Instantaneous, zero subprocess. Gemini acknowledges it is more fragile and poses it as an explicit tradeoff question rather than a recommendation. **Note the direct tension with Claude and Codex, who both want reuse of the subprocess-based `GitContextResolver`.** The author must resolve this three-way: reuse the mature resolver, write a bounded filesystem probe, or use the in-process metadata store.
22. **The shell alias bypass.** `alias agent="c11 launch-agent --cwd ."` permanently and invisibly disables the guard. This is the human-side twin of Claude's `--cwd` reflex finding, and together they form the strongest available argument that `--cwd` cannot be both the sanctioned override and the only override.

---

## 3. Assumption Audit (merged and deduplicated)

Load-bearing assumptions are those whose falsity collapses the plan. Sources in brackets: [C]laude, [X] Codex, [G]emini.

### Load-bearing and demonstrated false

1. **"There is an existing launch-agent cwd resolution seam."** [C, X] False for the inherited case. `v2ResolveCwdParam` handles the explicit param only; absent `--cwd`, resolution returns `.inherit`, `cwdOverride` stays `nil`, and inheritance happens downstream of the handler. Step 1 sends an implementer hunting for a seam that is not there, and the real work (materializing the inherited cwd) is unbudgeted.
2. **"The inherited cwd is one well-defined thing."** [C, X, G] False. At least four candidates diverge: CLI caller's shell cwd (never transmitted), target pane's parent-surface cwd, app-process cwd (already used for project-config lookup), and post-C11-194 workspace root. They diverge under `--pane`, `--workspace`, `--new-workspace`, cold surfaces, and browser-selected panes.
3. **"Linked worktree implies another agent's tree."** [C, X, G] False in this repo's dominant workflow. 38 worktrees exist so each delegator has one; a delegator launching its own helper into its own tree is sanctioned. Human operators also use worktrees normally.
4. **"Capturing the branch name is straightforward."** [C, X] False. Four of 38 live worktrees are detached; `--abbrev-ref HEAD` returns the literal `HEAD`. Unborn, deleted, and broken HEAD states also exist. `BranchValue` in the existing resolver already models all of them.
5. **"A new two-command git probe is harmless / cheap."** [C, X] False. Equivalent mature logic exists, subprocess calls are bounded but not free, the handler is main-actor routed, and the correct resolver traps on the main queue.
6. **"C11-194 can land independently without changing this design."** [C, X, G] False. It changes the very precedence this guard must inspect.

### Load-bearing and unverified

7. **"`git` is reachable, fast, and safe to run from the guard's execution context."** [C, X, G] Unstated in the plan, entirely load-bearing. `ProcessGitRunner` uses `/usr/bin/env git`; the app-process PATH is documented as poorer than a pane's. Sidebar chips degrade gracefully to "no chips," an acceptable degradation for decoration and an unacceptable one for a safety guard.
8. **"The system can reliably distinguish inherited from explicit cwd across the CLI/socket boundary."** [G, X] Unproven. The server currently collapses absent, empty, and `inherit` forms; which wire forms count as intentional override is undefined.
9. **"Explicit `--cwd` is a meaningful acknowledgement."** [C, X, G] Weak. The ticket's entire diagnosis is that the failure is silent, and the acknowledgement lands in a `warnings` array that non-JSON CLI output discards and most callers ignore. A shell alias or a prompt template makes it permanent and invisible.
10. **"Probe failure means not-a-linked-worktree."** [X] Unsafe fail-open. The inverse (treat every nil as unsafe) blocks non-git directories. A richer result type is required.
11. **"`git-dir != git-common-dir` can be compared as returned."** [X] Only after path normalization, which the existing resolver already performs. Submodules additionally require probing the outer superproject.
12. **"Guarding `c11 launch-agent` guards all programmatic agent launches."** [C, X] False. `config.launch`, direct `agent.launch` socket calls, `default-agent launch`, and the A button are separate surfaces.
13. **"Pure logic tests prove the safety invariant."** [C, X] False. They cannot prove target resolution, mutation ordering, output rendering, deadline behavior, or the child's actual spawned cwd.
14. **"The cwd resolution seam is stable enough to build on."** [G] Vulnerable while C11-194 is in flight.

### Cosmetic or safe

15. Non-goal "not mutating tenant git state." [C] Nobody proposed it; costs nothing, adds nothing.
16. Non-goal "not changing launch focus behavior." [C] Correct and consistent with the socket focus policy.
17. "Explicit `--cwd` is an intentional override" as a principle. [C, X] Reasonable in isolation; it is the ticket-level consequence (guarded default vs guard) that is contested, not the principle.

---

## 4. The Uncomfortable Truths (recurring hard messages)

1. **The guard cannot make the claim its error message will make.** [C, X, G] Git records topology, not ownership or liveness. "Likely another agent's active tree" is a correlation the implementation cannot verify. Every reviewer said a version of this.
2. **The guard does not enforce "no two agents mutate the same tree," and should stop saying it does.** [C, X] It permits main checkouts, explicit overrides, multiple explicit helpers in one worktree, non-git directories, post-launch `cd`, the A button, and every non-`launch-agent` entry point. Claude: "it's a speed bump on one road." Codex: "describe it honestly as that."
3. **The codebase was not read before the plan was written.** [C, X] Proposing to "add a testable linked-worktree probe" in a repo that already ships `GitContextResolver` with an injectable runner, submodule handling, stale detection, and detached-HEAD modeling is the clearest available evidence. Claude: "Everything else in this review follows from that."
4. **The plan is thin in a way that transfers every hard decision to the implementer.** [C, X] Five imperative lines, no file paths, no error code, no threading note, no timeout policy, no fail-open/fail-closed call, no doc deliverable. Claude's comparison to the sibling C11-194 plan (same length, but names surfaces, remembers the skill contract, remembers the sync step) is the sharpest form: "the gap is not style, it is how much thinking was done before the writing stopped."
5. **The bypass will become the norm, and the plan cannot detect it.** [C, G] Claude's `--cwd` reflex in prompt templates and Gemini's shell alias are the same failure from two directions. A guard whose fire rate silently goes to zero is indistinguishable from a guard that works.
6. **This may be the wrong layer, and nobody asked.** [G, plus C's variant] Gemini: hardcoding a Lattice workflow guard into a general-purpose multiplexer violates c11's own "unopinionated about the terminal" principle, and the check belongs in `lattice-orchestrator`. Claude's variant is the ticket-boundary form: given the plan permits `--cwd`, C11-193 may not be separable from C11-194 at all. Both are "does this belong here?", asked at different altitudes.
7. **`--cwd` proves intent only syntactically.** [X] An orchestrator can explicitly pass the wrong linked worktree. The warning is a breadcrumb, not safety proof.
8. **The triggering incident does not carry the weight being placed on it.** [C] Zero damage, different repo, and two of three derailments traced to a Codex update prompt swallowing briefs, which this guard does not touch. The cwd inheritance was real and worth fixing; the severity is narrative.

---

## 5. Consolidated Hard Questions for the Plan Author

Deduplicated across all three reviews and grouped. Questions marked **[BLOCKING]** were flagged by two or more reviewers as must-answer before implementation starts.

### A. Cwd resolution and the missing seam

1. **[BLOCKING]** What exactly is "the existing launch-agent cwd resolution seam" in step 1? `v2ResolveCwdParam` only sees the explicit param; when `--cwd` is absent, `cwdOverride` is `nil` and inheritance happens downstream. Where will the inherited cwd be materialized, and is that work in scope? [C3, X1]
2. **[BLOCKING]** Which cwd does the guard read: the CLI caller's shell cwd, the target pane's parent-surface cwd, the app-process cwd, or (post-194) the workspace root? They diverge under `--pane`, `--workspace`, and `--new-workspace`. Note the CLI never transmits the caller's shell cwd and the server already uses the app-process cwd for project-config lookup. [C2, X1, G1]
3. **[BLOCKING]** What exact function returns the cwd that will be passed to PTY creation for each placement mode, and how do you prove the probe and the spawn consume the same normalized string? [X1]
4. How will the server differentiate inherited from explicit if the CLI resolves and forwards an absolute path? Which wire forms count as explicit acknowledgement: `--cwd <path>`, `--cwd .`, `--cwd inherit`, empty string, cwd via `config launch`? [G1, X6]
5. What is the TOCTOU rule if the target pane's cwd changes between snapshot and surface creation? [X]
6. Does the guard apply to `--new-workspace` with no `--cwd`, where `addWorkspace(workingDirectory: nil)` decides? This is plausibly the exact shape of the triggering incident. [C11]

### B. Ticket boundary and C11-194

7. **[BLOCKING]** C11-193 and C11-194 modify the same resolution and neither plan names the other. What is the merge order, which ticket owns the shared precedence chain and its tests, and should 193 simply depend on 194's centralized resolver landing first? [C14, X3, G4]
8. **[BLOCKING]** Does C11-194's `.workspaceRoot` count as inherited and therefore trigger the guard? If yes, the plan's explicit/inherited binary has no slot for "configured." If no, why is a silently selected linked root safer than a silently selected linked surface cwd? [C15, X2, G4]
9. **[BLOCKING]** Given the plan permits explicit `--cwd`, what does C11-193 deliver that C11-194's loud default does not? If the honest answer is "not much," should the tickets merge? [C20]
10. Will you make cwd source a first-class enum (`{path, source, isExplicit}`) so future precedence sources cannot change safety semantics by accident? [X2]

### C. The probe: build, reuse, or replace

11. **[BLOCKING]** `GitContextResolver.resolveOuter` already performs the exact `--git-dir` vs `--git-common-dir` comparison with path normalization, models attached/detached/no-branch via `BranchValue`, resolves the outer superproject before an inner submodule, detects stale worktrees, and has an injectable `GitRunner` already exercised in tests. Why is step 2 building a new probe? If there is a layering or latency reason, name it with a measurement. [C1, X2, X4]
12. Have you considered the two non-git alternatives, and on what grounds are they rejected?
    - **In-process:** c11 already stores `MetadataKey.worktree` per surface (`TabManager.swift:2481`) and knows every live surface's cwd. "Is another live surface already in this tree, and is it not me?" needs no subprocess, no timeout, no PATH, and answers the actual invariant rather than a correlate. [C5]
    - **Filesystem-direct:** read the `.git` node, check for a `gitdir:` file, and inspect the target path for `/worktrees/`. Zero subprocess, more fragile. [G]
13. How will your test suite definitively prove that launching inside a submodule is not blocked, including a submodule of a linked superproject? [G5, X]
14. Four of the 38 live worktrees are on detached HEAD, where `--abbrev-ref HEAD` returns the literal string `HEAD`. What does the "actionable" message say then, and will normalized cwd plus worktree root/name carry the message when no branch exists? [C10, X]

### D. Failure policy, threading, and latency

15. **[BLOCKING]** When the probe times out, `git` is missing from the app-process PATH, the repo is corrupt, or permissions fail: does the launch proceed or abort? Answer separately for inherited and explicit cwd. Fail-open reinstates the silent failure the ticket exists to eliminate; fail-closed breaks all launches. [C6, X5, G3]
16. **[BLOCKING]** Will `agent.launch` and `config.launch` move to socket-worker execution, or what non-blocking continuation keeps git subprocess I/O off the main actor without changing focus behavior? Note `GitContextResolver.resolve` traps on the main queue by design and `agent.launch` is not currently in `socketWorkerV2Methods`. [X3, G2]
17. What is the pre-registered end-to-end latency budget, and how does it sit under the 10s CLI socket deadline given a 5s per-call git timeout? What guarantees a timeout cannot produce a late launch after the client already received failure, which an orchestrator retry would turn into duplicate agents? [X3, X5, C18]
18. Provide the full outcome table: main checkout, linked worktree, non-repo, stale worktree, detached HEAD, unborn/no branch, git missing, permission failure, timeout, crossed with inherited vs explicit. [X5]

### E. Contract, scope, and side effects

19. **[BLOCKING]** What is the new stable structured error code (not `invalid_params`), what structured data accompanies it (normalized cwd, worktree root/name, branch representation), and where does its row go in `docs/launch-agent-reference.md`'s error table? [C7, X4]
20. **[BLOCKING]** How will an ordinary human `launch-agent` or `config launch` user see the explicit-override warning, given `printV2Payload` discards the `warnings` array outside `--json`? [X4]
21. **[BLOCKING]** Which side effects are guaranteed absent after an inherited rejection (surface creation, launch stats, recent-config mutation, identity/attention metadata, delayed prompt scheduling, command delivery), and which integration test proves it? [X8]
22. **[BLOCKING]** Which entry points remain able to create an agent in an inherited linked worktree: the A button and `default-agent launch` (`TerminalController.swift:8989+`), direct socket `agent.launch`, `config launch`, `new-pane` / `new-split` / `new-workspace`? Is each inclusion or exclusion deliberate and documented as a non-goal? Is it intentional that the programmatic path is guarded while the operator clicking A in a worktree pane is not? [C12, C13, X9]

### F. Usability, override, and rollout

23. **[BLOCKING]** This repo has 38 live worktrees and a house workflow that gives every delegator its own. A delegator launching its own reviewer from its own worktree is legitimate and common. Why should that be refused, what is the expected false-positive rate, and why was it not measured first via `AgentLaunchStatsStore` in a warn-only pass? [C4]
24. What is the real override? `--cwd` is not one, because it changes where the agent runs. The repo already ships the idiom (`--allow-undersized` / `--force` on `pane.create`, `cli/c11.swift:2218`). Why is there no `--allow-worktree`? [C9]
25. How will you know if the guard is being trained around? If `--cwd` becomes reflexive in prompt templates, or an operator aliases `agent="c11 launch-agent --cwd ."`, the fire rate goes to zero and a dead guard looks identical to a working one. What counter or debug record makes that visible? [C19, G]
26. Is there a staged rollout (warn, measure, then refuse) or a kill switch for a fleet already mid-run when this ships? [C]
27. `--cwd inherit` is silently broken on `launch-agent` (line 2328 is a bare `resolvePath(v)`, unlike `new-pane` and `new-split`). Will you fix it, given this plan makes `--cwd` the load-bearing escape hatch on that exact command? [C]
28. The error message's implied remedy ("pass `--cwd` pointing at the project root") is ambiguous when six worktrees live inside the main checkout at `c11-worktrees/*`. What does the message actually tell the caller to do? [C]

### G. Validation and shipped contract

29. **[BLOCKING]** What validates the refusal end-to-end? Name the exact narrow and full `c11-logic` invocations, plus the tagged-build runtime scenario that proves rejection, explicit allowance, main-checkout and non-git allowance, warning visibility, no focus steal, bounded latency, and the child surface's actually observed cwd. [C17, X6, X10]
30. **[BLOCKING]** Which files update the public contract (`cli` help, `docs/launch-agent-reference.md`, `skills/c11/SKILL.md`), and where does the plan require `scripts/sync-installed-skills.sh c11` plus live-copy verification? CLAUDE.md makes both a hard rule, and the sibling C11-194 plan remembers them. [C8, X6, X11]
31. Step 5 instructs a local `c11-logic` run, which cuts against this repo's operator-reinforced rule to defer all local `xcodebuild` to CI (hardened after C11-181, when the operator interrupted exactly such a run). Deliberate, or carried over unexamined? [C16]
32. If runtime validation actually launches agents, what is the harmless-command strategy, the surface cleanup plan, and the proof that scratch-only git fixtures were used and the operator's live checkout was untouched? [X]

### H. The layer question

33. **[BLOCKING]** Why does git-workflow-specific logic belong in the `c11` core binary rather than in the `lattice-orchestrator` skill, which issues the launch command and already owns the one-worktree-per-delegator rule? c11's own CLAUDE.md states the project is "unopinionated about the terminal, host and primitive, not configurator." A skill-layer check also evolves with a file edit rather than a release, which matters because the definition of a "dangerous" directory will change as Lattice evolves. [G6, G]
34. If the project goal is truly "no two agents mutate the same tree," what complementary ownership or liveness mechanism covers main checkouts, explicit overrides, post-launch `cd`, and the unguarded entry points? Or will the ticket explicitly narrow its claim to "accidental inherited linked-worktree launches"? [X12, C]

---

## Recommended Sequencing (synthesis, not from any single review)

The reviews converge on an implicit ordering. If the author intends to proceed:

1. **Answer Q9 and Q33 first.** They are existential: does this ticket survive as a separate deliverable in the c11 binary? Every other question is wasted effort if the answer is "merge into C11-194" or "move to the skill."
2. **Then Q7 and Q8.** The shared cwd-source contract with C11-194 must exist before either ticket's implementation, or the merge order silently decides product behavior.
3. **Then Q11, Q12, Q15, Q16.** Probe choice and failure policy are coupled: the in-process metadata signal makes Q15 through Q18 mostly moot, which is a strong argument for evaluating it before committing to a git subprocess.
4. **Then Q23.** Measure the false-positive rate with a warn-only pass before shipping a refusal into 38 live worktrees.
5. **Only then** the contract, scope, and validation questions (Sections E and G), which are ordinary plan-completeness work.
