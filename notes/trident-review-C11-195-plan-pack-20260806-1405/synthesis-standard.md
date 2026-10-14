# Trident Standard Review Synthesis — C11-195 Plan

**Pack:** `notes/trident-review-C11-195-plan-pack-20260806-1405/`
**Sources:** `standard-claude.md`, `standard-codex.md`, `standard-gemini.md`
**Plan under review:** `.lattice/plans/task_01KZBZY4WBCMG252XSJPJC1CPA.md` (C11-195, 5 items + 1 non-goal)
**Synthesized:** 2026-08-06

---

## Executive Summary

1. **All three models endorse the direction.** C11-195 should consume C11-194's single cwd resolution rather than inventing a second lookup rule, and `DefaultAgentProjectConfig.find(from:)` should stay a context-free filesystem walker. No reviewer proposed a reframe. This is the strongest consensus in the pack.

2. **Two of three call it not execution-ready.** Claude and Codex both return **Needs revision**; Gemini returns **Ready to execute, pending minor clarifications**. The split tracks depth of context, not judgment: Claude and Codex each inspected the live branch (`fix/C11-193-launch-agent-cwd`) and the real call sites, Gemini reviewed the plan text largely on its own terms. Every substantive gap Claude and Codex found is invisible from the plan text alone, which means Gemini's verdict should be treated as a review of the plan's *intent* and the other two as reviews of its *executability*.

3. **The single highest-confidence finding, independently derived by Claude and Codex, is that "the same resolved path" is under-specified at the fallback boundary and the invariant it protects is maintained only by convention.** Both models arrived at the same remedy without coordination: materialize one launch-directory context value carrying `effectivePath` + provenance, constructed once, consumed by config lookup, surface creation, and the response. Convergent independent derivation of the same fix is the pack's strongest signal.

4. **The proposed test (item 3) is the pack's sharpest disagreement.** Gemini lists it as a key strength; Claude calls it a tautology that "cannot fail"; Codex says it re-proves a walker that already works. Claude and Codex are correct on the mechanics: `find(from:)` already takes a path and walks up, so asserting `find(from: resolvedPath)` finds the file tests nothing about the defect, which lives entirely in the caller's choice of path.

5. **Two blocking findings are single-model and specific enough to act on immediately.** Codex found that a materialized process fallback can be silently persisted as a durable workspace root through the existing `establishRootFromWorkingDirectory: cwdResolution.source != .launchingSurface` condition. Claude found that most of plan items 1 and 2 are *already implemented* on the branch the plan targets, meaning the plan does not know its own baseline.

6. **Consolidated verdict: Needs revision (2 of 3 explicit, and the third's "ready" rests on a materially thinner evidence base).** The revision is focused, not structural. Six edits close it, listed in §5.

---

## 1. Where the Models Agree (Highest Confidence)

### 1.1 Unanimous (3 of 3)

1. **The fix point is correct.** C11-194's resolver is the right seam. Consuming it beats patching individual `find(from:)` call sites (Claude), beats teaching the walker about workspaces/callers (Codex), beats re-implementing cwd inheritance for config lookup (Gemini). All three explicitly rejected the duplicate-resolver alternative.

2. **Keep `DefaultAgentProjectConfig.find` context-free.** No reviewer wants launch semantics pushed down into the filesystem walker.

3. **The `?? FileManager.default.currentDirectoryPath` fallback is a defect, not a safety net.** All three flag it independently. For a Finder-launched GUI app that value is `/` or the bundle directory; it is either equivalent to nil or actively harmful (picking up a stray `/.c11/agents.json`). They disagree on the remedy (see §2.2) but not on the diagnosis.

4. **Dependency sequencing on C11-194 is correct but under-enforced.** All three raise the shared-branch/PR-#407 question. Claude notes prose is not a Lattice `blocked_by`; Codex notes "must land first" is ambiguous when three tickets share one branch and one PR; Gemini asks directly whether C11-195 stacks on C11-194's WIP or waits for merge. C11-194 having been reset today makes this live, not theoretical.

5. **The plan correctly identifies the real invariant** (config-lookup path must equal child-process cwd) and gets credit for it from all three. The disagreement is only over whether the plan *delivers* it.

### 1.2 Strong Agreement (2 of 3, both code-grounded)

6. **The invariant needs a type, not adjacent lines.** Claude proposes `AgentLaunchContext { cwd, source, projectConfig }`; Codex proposes a launch-directory context with `effectivePath`, `source`, and `establishesWorkspaceRoot`. Same shape, same reasoning: divergence should be unrepresentable rather than currently-absent. Cheap (roughly a dozen lines) and it converts item 2 from a hope into a verifiable deliverable.

7. **Item 3's test does not test the bug.** Both demand a pure composition seam that accepts the C11-194 resolution plus an injected process fallback and returns the effective lookup path. Claude's framing: "what change to production code would make it go red?" If the answer is "none," it is theater. Codex adds: do not mutate the process-wide cwd inside a parallel XCTest to build the decoy; inject it.

8. **`TerminalController.defaultAgentLaunch` / `--in-surface` has no disposition, and that is blocking.** The ticket names this site explicitly; the plan's non-goal ("the A-button/default-agent entry point beyond shared helper reuse") reads most naturally as excluding it. Claude's downstream prediction: the ticket closes, the CLI path stays broken, the next person re-files it because the closed ticket's text says it was covered. Codex: "Leaving the known public-path bug implicit is not acceptable." Either scope it in or narrow the plan and file a linked follow-up. Silence is the failure mode.

9. **Item 4's tagged-app validation has no falsifiable oracle.** "Uses the project-level agent configuration" is not observable from the UI. Both models want a named sentinel: a scratch `.c11/agents.json` whose `defaultAgent`/command/model differs unmistakably from the user default, then read the result from a concrete surface (the composed launch line, the `--json` payload, the binary that actually starts, or a `pwd` read from the spawned surface).

10. **Item 2 is duplicative or already done.** Claude: item 2 restates C11-194 plan item 1 verbatim in substance and is already on the branch. Codex: C11-195 should be a downstream consumer, not a second resolver. Both want item 2 restated as an *assertion C11-195 verifies* rather than work it performs.

---

## 2. Where the Models Diverge (The Disagreement Is Signal)

### 2.1 Readiness verdict: 2 "needs revision" vs 1 "ready"

| Model | Verdict | Evidence base |
|---|---|---|
| Claude | Needs revision | Read live `origin/fix/C11-193-launch-agent-cwd`, all 5 `find` call sites, sibling plans, C11-105 history |
| Codex | Needs revision | Read shared branch at `4ec750670`, response/`cwd_source` wire behavior, root-persistence condition |
| Gemini | Ready to execute | Plan text plus general knowledge of `v2AgentLaunch` |

**Reading the split:** this is not three opinions on the same facts. Gemini's review contains no finding that requires branch inspection, and correspondingly no finding that would block. The lesson is procedural: a Standard review that does not check the plan's baseline against the branch will systematically under-call readiness on a ticket sitting on an actively-moving shared branch. Weight Claude and Codex here.

### 2.2 The fallback remedy: three different answers

1. **Claude: delete it.** Its only possible behaviors are "identical to nil" or "apply a machine-root config to an unrelated launch." `find(from:)` already returns nil for nil. Deleting strictly increases determinism and shortens the diff. If a net is wanted, use `home` (as `GhosttyTerminalView` already does).
2. **Codex: keep it but materialize it once**, represent it explicitly in `cwd_source`, and guarantee it never establishes a workspace root.
3. **Gemini: question it, suggest `~`**, but defer to whatever C11-194 already does.

**Why the disagreement matters:** Claude's and Codex's positions are not compatible. Claude wants the fallback gone so the invariant has fewer states; Codex wants it present and honest so config, spawn, and response can never be three different values. Codex's position is safer if the CLI/direct-socket callers can genuinely reach a fully-empty resolution; Claude's is cleaner if they cannot. **This needs an operator/author decision, not a merge.** (Note both agree the *current* behavior, where lookup materializes the fallback but surface creation and the response do not, is the worst of the three options.)

### 2.3 Should the CLI send its own cwd? Direct head-to-head contradiction

- **Claude: yes.** The CLI process knows its own cwd exactly and always. Server-side inference from `caller_surface_id` + `panelDirectories` depends on OSC 7 / shell integration being live and current, so it has a staleness window and a hard dependency. A `caller_cwd` param with inherited (not explicit) provenance is strictly more accurate and does not disturb C11-193's explicit-vs-inherited warning distinction.
- **Codex: no.** "Works only for a local caller targeting its own workspace. It is wrong for `--workspace`, `--pane`, background callers, and direct socket callers. Server-side target-context resolution is the stronger boundary."

**Assessment:** the two are arguing about different launches. Codex is right that `caller_cwd` must not *override* an explicit `--workspace`/`--pane` target. Claude is right that when the launch *is* local-and-inherited, server-side inference is a strictly weaker signal than the caller's own ground truth. A reconciliation exists: send `caller_cwd` as an additional low-precedence input consumed only on the `.launchingSurface` branch, never as an implicit `--cwd`. But this is C11-194's decision surface, and it determines whether C11-195's fix actually finds the file in practice. Escalate rather than silently pick.

### 2.4 Threading: a real question that the branch may have already answered

- **Gemini** makes this its headline technical concern: config lookup runs off-main today, but C11-194's resolver must read `@MainActor` state (TabManager, TerminalPanel), so how are they sequenced?
- **Codex** reports the branch already solves it: launch planning moved to the socket worker, a bounded main-actor context snapshot is taken, and it returns to the main actor only for surface mutation. C11-195's job is to *preserve* that boundary.

**Assessment:** Gemini's question is legitimate and Codex supplies the answer. Carry it forward as a constraint ("preserve the snapshot boundary, keep filesystem I/O off-main") rather than an open question. Also relevant: CLAUDE.md's socket threading policy forbids `DispatchQueue.main.sync` on telemetry hot paths and defaults new socket work off-main.

### 2.5 Ticket topology: fold, split, or just document?

- **Claude:** the current shape (3 tickets, 1 branch, 1 PR) maximizes coupling for no visible benefit. Either fold C11-195's socket-path line into C11-194 as an acceptance criterion (leaving C11-195 to own only the CLI/`--in-surface` site), or split PR #407 so the uncontroversial config-lookup fix can merge while C11-193's warning-policy churn continues.
- **Codex:** does not want restructuring; wants the *evidence* to be durable, naming the exact commit/range on PR #407 that contains the final C11-194 resolver semantics, since linking a shared PR is not proof this ticket completed.
- **Gemini:** simply asks whether the branch stacks on WIP or waits for merge.

These are compatible in principle (Codex's ask survives either topology), but Claude's is a larger process change and should be answered first.

---

## 3. Unique Insights (Single-Model Findings)

### 3.1 Claude only

1. **Baseline drift, the most consequential single finding.** Most of item 1 and all of item 2 are *already on* `origin/fix/C11-193-launch-agent-cwd`: `SocketDispatch.swift:1190` already reads `cwdResolution.path ?? FileManager.default.currentDirectoryPath`, and `cwdResolution.path` is already passed to both `addWorkspace` and `newTerminalSurface`. A plan that does not know its starting state will either redo the work or conclude "already done" and skip the parts that genuinely are not.
2. **The five-call-site census.** `SocketDispatch.swift:1190` (fixed on branch), `TerminalController.swift:9080` (still buggy, named in ticket), `Workspace.swift:12488` via `resolverCwdForAgentLaunch()` (latent same bug in its last fallback), `GhosttyTerminalView.swift:3471` (different rule, not process cwd), `AppDelegate.swift:6764` (fine). The plan needs a per-site disposition even where the disposition is "out of scope, documented."
3. **The implicit precedence regression.** C11-194 ranks workspace root *above* launching-surface cwd, and `find(from:)` walks *upward*. Composed: a surface `cd`'d into `<root>/packages/foo` that owns its own `.c11/agents.json` will resolve from `<root>` and never see the subproject file once a root is set. The plan's non-goal claims precedence is out of scope, but this *is* a precedence change delivered implicitly. It may be the desired semantics ("root defines the project"), but it should be a decision and a documented one, not a side effect.
4. **The C11-105 landmine.** `defaultAgentLaunch` is `private` on `TerminalController`; reaching it means going through the dispatcher on `TerminalController.shared`, which is exactly the pattern that unlinked the production socket from a logic-target test. Any "add a logic test" instruction that does not name a pure seam walks toward this.
5. **Test-target placement and pbxproj churn.** `c11LogicTests` sources live in `c11Tests/` on disk with membership set in `project.pbxproj`; wrong-target placement silently makes the test host-bound, and Ruby-gem pbxproj edits produce multi-thousand-line normalization diffs. Prefer adding to an existing logic-target file. (Note the existing `DefaultAgentResolverTests.swift` sits in the *host* target.)
6. **Item 4 may fail for reasons unrelated to C11-195.** The branch still contains C11-193's *reject* implementation (`decision()` returns `.reject` for inherited linked worktrees; SocketDispatch returns `err(code: "linked_worktree_cwd")`) even though C11-193 rev 3 flipped to warn. Validating from a linked worktree, which is the normal lattice-orchestrator shape, will be rejected outright.
7. **Missing docs/CHANGELOG/installed-skill sync.** Both sibling plans have explicit doc steps (C11-194 item 5, C11-193 item 9); C11-195 has none despite being the ticket that makes `.c11/agents.json` actually work on the default path, arguably the most user-visible of the three. `docs/launch-agent-reference.md` should state which path config resolves from, and CLAUDE.md's hard rule requires `scripts/sync-installed-skills.sh` after any skill edit.
8. **Malformed `.c11/agents.json` is silently swallowed** by `find(from:)` by design. Once this path actually works, users will start hitting it and a broken file will look identical to no file.
9. **Duplicate config resolution on the A-button mimic branch.** The `projectConfig` computed at `TerminalController.swift:9082` is used only for the empty-command guard and then discarded; `tab.launchAgentSurface` re-derives config from `resolverCwdForAgentLaunch()`.
10. **No regression guard against a sixth call site.** Per-site fixes do not close this class. A single documented entry point, or making raw `find` internal to one helper, would be the durable close-out.

### 3.2 Codex only

11. **The root-persistence hazard, blocking and precise.** If the process fallback is materialized as a non-nil working directory while `establishRootFromWorkingDirectory: cwdResolution.source != .launchingSurface` stands, a `nil` source is treated as root-establishing. A compatibility fallback must not silently turn the GUI app's arbitrary cwd into a durable workspace root. This is a data-corruption-class bug, not a cosmetic one, and no other reviewer saw it.
12. **Three-way split brain in the response, not two-way.** On the current branch a successful launch can report `cwd: null`, resolve config from the app cwd, and hand the child a third fallback inherited from surface construction. The plan's item 2 addresses lookup-vs-child but not response truth.
13. **Wire-format question for provenance.** How does the compatibility fallback appear in `cwd_source`: `null`, a new stable `process_fallback` value, or something else? This is an API-surface decision that outlives the ticket.
14. **Test-hygiene warning.** Do not mutate the process-wide current directory in a parallel XCTest to create the decoy; inject the fallback into the pure seam.
15. **Table-driven case coverage.** C11-194 introduced *two* new no-`--cwd` behaviors that need separate assertions: (a) workspace root exists and wins, (b) rootless workspace falls back to launching surface. Plus (c) total absence, verifying the compatibility fallback without persisting it as a root. The plan's "inherited/root" wording permits covering only one.
16. **Evidence durability under a reset dependency.** Because C11-194 was reset, C11-195's evidence must name the exact reviewed commit/range containing the *final* C11-194 resolver semantics. Linking PR #407 alone is not durable proof.
17. **Missing verification gates.** Name the narrowed safe `c11-logic` invocation, the compile/build gate, and the tagged runtime scenario explicitly.

### 3.3 Gemini only

18. **The threading-boundary framing** (see §2.4). Even though Codex reports the branch handles it, Gemini is the only model that treated the main-actor/off-main seam as a first-class design question for C11-195 rather than an inherited property. Worth carrying as an explicit constraint in the revised plan.
19. **A cleanly-rejected alternative worth recording:** look up config *after* surface creation, on the surface's final cwd. Gemini correctly rejects it because the surface needs the config to know *how* to launch (command resolution). This is the kind of alternative a future reader will propose, so documenting the rejection has value.

---

## 4. Consolidated Questions for the Plan Author

Deduplicated across all three reviews. Ordered roughly by blocking weight. Attribution in brackets: **[C]** Claude, **[X]** Codex, **[G]** Gemini.

### Scope

1. **Is `TerminalController.defaultAgentLaunch` (~line 9080) in scope?** The ticket names it; the non-goal appears to exclude it. One-word answer plus a corresponding plan edit. If out of scope, file and link the follow-up now. **[C, X]**
2. If it is in scope, **what lookup rule applies to `--in-surface`?** The agent boots in the target surface's existing directory, so C11-194's root/caller resolution is the wrong input. Should the rule be `cwdArg ?? <target surface's directory>`? Note that mechanically applying the resolver here reintroduces exactly the divergence item 2 exists to prevent, just with a less obviously-wrong path than `/`. **[C, X]**
3. **Is the duplicate config resolution on the A-button mimic branch in scope** (the `projectConfig` at `TerminalController.swift:9082` used only for the empty-command guard, then discarded while `tab.launchAgentSurface` re-derives from `resolverCwdForAgentLaunch()`), or explicitly deferred? **[C]**
4. **What is the disposition of each of the five `DefaultAgentProjectConfig.find` call sites?** Including `Workspace.swift:12488`, which carries the same latent process-cwd bug in its final fallback. "Out of scope, documented" is an acceptable answer; silence is not. **[C]**

### Baseline

5. **Are you aware the socket-path change is already on `origin/fix/C11-193-launch-agent-cwd`?** `SocketDispatch.swift:1190` already reads `cwdResolution.path ?? processCwd`, and surface creation already receives `cwdResolution.path`. If so, what is the *residual* work described by items 1 and 2? **[C]**

### The fallback and the invariant

6. **Keep or drop `?? FileManager.default.currentDirectoryPath`?** Is there any launch path where the app's process cwd is a meaningful project root? If keeping, is `home` the safer net? **[C, G; X prefers keep-but-honest]**
7. **When all three C11-194 sources are absent, does the child PTY actually start in the app-process cwd, or is the fallback for config lookup only?** If lookup-only, how is config/execution divergence acceptable given item 2? **[X]**
8. **How does the compatibility fallback appear in the response:** `cwd_source: null`, a new stable `process_fallback` value, or another representation? **[X]**
9. **Should a process-fallback launch ever establish or persist a workspace root?** The existing `establishRootFromWorkingDirectory: cwdResolution.source != .launchingSurface` condition will treat a `nil` source as root-establishing once the fallback is materialized. Safe default is no. **[X]**
10. **Will you materialize a single launch-context value** (`effectivePath` + `source` + `establishesWorkspaceRoot`, config resolved from the stored path) so lookup/spawn/response divergence is unrepresentable rather than merely currently-absent? Both code-grounded reviewers independently recommended this. **[C, X]**

### Testing

11. **What composition seam does the logic test call, and what production change would turn it red?** If the answer is `DefaultAgentProjectConfig.find`, the test cannot detect this regression. Proposal: a pure `agentConfigLookupPath(explicit:workspaceRoot:surfaceCwd:targetSurfaceCwd:processFallback:) -> String?`. **[C, X]**
12. **Which target, `c11LogicTests` or `c11Tests`?** And a new file (a `project.pbxproj` edit with known normalization churn) or an addition to an existing logic-target file? Note `DefaultAgentResolverTests.swift` currently sits in the host target, and reaching `defaultAgentLaunch` through `TerminalController.shared` from a logic target is the C11-105 failure mode. **[C]**
13. **Does acceptance require all three no-`--cwd` cases** (workspace-root wins, rootless falls back to launching surface, total absence hits compatibility fallback without persisting a root), or only one? Current wording permits either. **[X]**

### Validation

14. **What is the observable oracle for item 4?** Which field of the scratch `.c11/agents.json` will be made unmistakably distinguishable from the user default (agent/command, model/effort, environment), and where is the result read: composed launch line, `--json` payload, the binary that actually starts, a `pwd` from the spawned surface? Include the `cwd` and `cwd_source` assertions. **[C, X]**
15. **Where is item 4 run from?** If a linked worktree, the branch's current `decision()` still *rejects* inherited launches (`err(code: "linked_worktree_cwd")`) despite C11-193 rev 3 flipping to warn, so the step cannot pass. Sequence validation after the warn-only rewrite, or run from a main checkout, and say which. Use the QA launch flag so startup dialogs do not block. **[C]**
16. **What are the named verification gates:** the narrowed `c11-logic` invocation, the compile/build gate, and the tagged runtime scenario? **[X]**

### Threading

17. **How are cwd resolution and config lookup sequenced across the main-actor boundary?** The branch appears to take a bounded main-actor snapshot and return to main only for surface mutation. Confirm C11-195 preserves that boundary and keeps filesystem I/O off-main, per the repo's socket threading policy. **[G, X]**

### Semantics and documentation

18. **The implicit precedence shift:** with a workspace root set, a surface `cd`'d into a subdirectory owning its own `.c11/agents.json` will resolve from the root and never see the subproject file. Intended ("root defines the project")? If yes, document it in `docs/launch-agent-reference.md`. If no, should launching-surface cwd win for *config lookup* even when root wins for *child cwd*, and does that violate item 2's invariant? **[C]**
19. **Malformed `.c11/agents.json` is silently ignored today.** Once this path works, users will hit it. Add a log/warning, or keep silent and document? **[C]**
20. **Docs, CHANGELOG, and installed-skill sync are absent** from this plan but present in both siblings. Intentional (covered by C11-194's doc step) or an omission? **[C]**

### Sequencing and topology

21. **Should C11-195's socket-path line fold into C11-194** as an acceptance criterion, leaving C11-195 to own only the CLI/`--in-surface` site? Or should PR #407 split so the uncontroversial config-lookup fix can merge while C11-193's warning-policy churn continues? **[C]**
22. **What exact commit/range on PR #407 attaches to C11-195** once the reset C11-194 implementation reaches final form? Linking the shared PR alone is not durable per-ticket evidence. **[X]**
23. **Does "C11-194 must land first" mean commit order inside the shared PR, or a separate merge?** And will you stack on C11-194's WIP branch or wait? If the delegator model ever splits these across worktrees, this needs a real Lattice `blocked_by`, not prose. **[C, X, G]**

### Design surface (escalate, do not silently pick)

24. **Should the CLI send `caller_cwd` directly** rather than the server inferring the caller's directory from `caller_surface_id` + shell-reported `panelDirectories`? Claude argues the CLI always knows its own cwd with no shell-integration dependency and no staleness window; Codex argues server-side target-context resolution is the stronger boundary because `caller_cwd` is wrong for `--workspace`, `--pane`, background, and direct-socket callers. Possible reconciliation: accept `caller_cwd` as a low-precedence input consumed only on the `.launchingSurface` branch, never as an implicit `--cwd`. This is C11-194's decision but it determines whether C11-195's fix finds the file in practice. **[C vs X, direct disagreement]**
25. **What prevents a sixth ad-hoc `DefaultAgentProjectConfig.find(from:)` call site from appearing?** A single documented entry point, or making raw `find` internal to one helper, is the durable close-out; per-site fixes are not. **[C]**

---

## 5. Overall Readiness Verdict

### 5.1 The synthesized call

**Needs revision. Focused, not structural. Do not reframe.**

Vote: 2 × Needs revision (Claude, Codex), 1 × Ready with minor clarifications (Gemini). The synthesis follows the majority, and the minority position is further discounted because Gemini's review contains no finding requiring branch inspection while the two blocking findings (root persistence, baseline drift) both do. On a plan targeting an actively-moving shared branch whose primary dependency was reset today, the plan-text-only read is structurally unable to catch what matters.

### 5.2 What is settled and should not be relitigated

1. The fix point (C11-194's resolver) is right.
2. The decomposition across 193/194/195 is right: one provenance-carrying resolution consumed by several policies.
3. `find(from:)` stays a context-free walker.
4. Config lookup stays *before* surface creation.
5. Runtime evidence in a tagged app is the correct bar for this repo, not a green logic suite alone.

### 5.3 Minimum edits that flip this to "ready to execute"

1. **State the baseline.** Name what is already on `origin/fix/C11-193-launch-agent-cwd` and restate items 1 and 2 as the residual work plus a verification of C11-194's invariant, not as fresh work.
2. **Give every call site a disposition,** and resolve the contradiction between the non-goal and the ticket's explicit `TerminalController.swift:9074` mention. If `--in-surface` is out, file the follow-up in the same breath.
3. **Specify one effective cwd end to end:** materialized once, including the fallback decision (drop / `home` / keep-and-represent), driving config lookup, surface creation, and the response, with an explicit `cwd_source` representation and an explicit guarantee that a fallback never establishes a workspace root.
4. **Name the test seam** (a pure lookup-path function), name the target (`c11LogicTests`, preferring an existing file to avoid pbxproj churn), and specify table-driven coverage of root / rootless / total-absence. Drop the tautological `find(from:)` assertion. Inject the decoy fallback rather than mutating process cwd.
5. **Make item 4 falsifiable:** name the sentinel config field, the read surface, the `cwd` + `cwd_source` assertions, and where the validation runs from, sequenced after C11-193's warn-only rewrite (or from a main checkout).
6. **Add the docs / CHANGELOG / installed-skill-sync line,** and document the implicit precedence semantics in `docs/launch-agent-reference.md` if the root-wins behavior is intended.

Items 1 through 5 are blocking. Item 6 is required for close-out but not for starting work.

### 5.4 Decisions the author cannot resolve alone

These need the operator, because two competent reviewers reached opposite conclusions or the decision spans tickets:

1. **The fallback:** delete (Claude) vs keep-and-represent (Codex). Both agree the current half-materialized state is worst.
2. **`caller_cwd` from the CLI:** more accurate (Claude) vs wrong boundary for non-local targets (Codex). A precedence-scoped reconciliation exists.
3. **Ticket topology:** fold C11-195's socket line into C11-194 and/or split PR #407 (Claude) vs keep the shape and tighten the evidence (Codex).

### 5.5 Risk if executed as written

The convergent prediction from both code-grounded reviews: a delegator can execute all five bullets faithfully and ship a change that (a) leaves the second reported site broken while the ticket text reads as satisfied, (b) carries a test that is permanently green and cannot detect reintroduction of `?? processCwd`, (c) fails its own validation step for reasons unrelated to C11-195, and (d) in the empty-resolution case, silently persists the GUI app's arbitrary cwd as a durable workspace root. Of these, (b) is the most corrosive because it manufactures confidence exactly at the point of regression, and (d) is the most severe because it writes bad state to disk.
