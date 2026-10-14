# Standard Plan Review — C11-195-plan (Claude) — 20260806-1409

Reviewed: `.lattice/plans/task_01KZBZY4WBCMG252XSJPJC1CPA.md` (C11-195)
Context read: ticket description, C11-193 plan (rev 3), C11-194 plan (rev 2), and the
**live state of `origin/fix/C11-193-launch-agent-cwd`** (PR #407), plus the five real
`DefaultAgentProjectConfig.find` call sites in `Sources/`.

---

## Executive Summary

The diagnosis is correct and the chosen fix point (C11-194's resolver) is right. As a
*direction*, this plan is sound and I would not reframe it.

But this plan is not yet a plan — it is a restatement of the ticket in five bullets, and
in the specific ways it is under-specified it will produce a partial fix that looks
complete. Three things dominate:

1. **The plan does not say which call sites it fixes, and its own non-goal appears to
   exclude the second site the ticket explicitly names.** The ticket says the bug appears
   in *both* `SocketDispatch.v2AgentLaunch` and `TerminalController.defaultAgentLaunch:9074`.
   The plan's non-goal — "changing … the A-button/default-agent entry point beyond shared
   helper reuse" — reads most naturally as *don't touch `defaultAgentLaunch`*. If the
   delegator reads it that way, C11-195 closes with half the reported bug still live, and
   the ticket text will read as satisfied. This is the single most important thing to fix
   before execution.

2. **Most of item 1 and all of item 2 are already implemented on the branch this plan
   targets.** `origin/fix/C11-193-launch-agent-cwd` already has
   `let lookupCwd = cwdResolution.path ?? FileManager.default.currentDirectoryPath`
   (SocketDispatch.swift:1190) and already passes `cwdResolution.path` into both
   `addWorkspace` and `newTerminalSurface`. The plan describes this as work to be done. A
   plan that doesn't know its own starting state will either re-do work or, worse, its
   author will conclude "already done" and skip the parts that genuinely aren't. State the
   baseline explicitly.

3. **The proposed test, as described, will almost certainly not test the bug.**
   `DefaultAgentProjectConfig.find(from:)` is already correct — it takes a path and walks
   up. The defect lives entirely in the *caller's choice of path*. A scratch-directory test
   that writes `.c11/agents.json` and asserts `find(from: resolvedPath)` returns it proves
   nothing that isn't already proven, and asserting "not the app cwd" against a function
   that never reads the app cwd is a tautology. Under this repo's test-quality policy
   ("verify observable runtime behavior through executable paths… if a behavior cannot be
   exercised end-to-end yet, add a small runtime seam or harness first"), this test needs a
   seam — a pure function that takes `(resolution, processCwd)` and returns the lookup path
   — or it is theater.

Everything else is refinement.

---

## The Plan's Intent vs. Its Execution

**Intent:** project-level agent configuration should apply on the default (no `--cwd`)
launch path, because today the GUI app's process cwd is `/` and `/.c11/agents.json` never
exists, so the feature is silently dead for every launch that doesn't pass `--cwd`.

**Where execution drifts:**

- *Site coverage.* Item 1 is written in the singular ("the resolved effective launch cwd
  for `DefaultAgentProjectConfig.find(from:)`") as though there is one call. There are
  five in `Sources/`:

  | Site | Lookup path today | Status |
  |---|---|---|
  | `SocketDispatch.swift:1190` | `cwdResolution.path ?? processCwd` | already fixed on branch |
  | `TerminalController.swift:9080` | `cwdArg ?? processCwd` | **still buggy — named in the ticket** |
  | `Workspace.swift:12488` | `resolverCwdForAgentLaunch()` (panel dir → workspace dir → **processCwd**) | latent same bug in the last fallback |
  | `GhosttyTerminalView.swift:3471` | `workingDirectory ?? home` | different rule, not process cwd |
  | `AppDelegate.swift:6764` | plan `workingDirectory` | fine |

  The plan needs a per-site disposition, even if the disposition for three of them is
  "out of scope, documented."

- *Item 2 is C11-194's work, not C11-195's.* "Pass that same resolved path into surface
  creation" is precisely C11-194 plan item 1 ("The exact resolved path must drive surface
  creation and downstream consumers"), and it is already on the branch. Two tickets
  claiming the same line on the same branch is how you get a delegator that reverts its
  sibling's work during a rebase. Either delete item 2 and cite C11-194, or restate it as
  an *assertion* C11-195 verifies rather than work it performs.

- *The stated non-goal contradicts the ticket.* See Executive Summary point 1. If the
  operator's actual intent is "socket path only, file a follow-up for the CLI path," say
  that in the non-goals and file the follow-up. Silence here is the failure mode.

---

## Architectural Assessment

**The decomposition (194 owns the resolver, 193 owns warnings, 195 owns config lookup) is
correct.** One provenance-carrying resolution consumed by several policies is the right
shape, and it's much better than three tickets each re-deriving a cwd. Credit where due.

Three structural observations:

**(a) The invariant deserves a type, not a convention.** Item 2's real content is an
invariant: *the path used for config lookup and the path the child process starts in must
be the same value.* Today that invariant is maintained by two adjacent lines both
happening to read `cwdResolution.path`. It will drift the first time someone adds a code
path between them. The stronger move is a tiny struct — call it
`AgentLaunchContext { cwd: String?, source: …, projectConfig: DefaultAgentConfig? }` —
constructed once from the resolution, where the config is resolved *from the same stored
path*. Then divergence is unrepresentable rather than merely currently-absent. This is
cheap (a dozen lines) and it's what makes item 2 a real deliverable instead of a hope.

**(b) `--in-surface` needs a different rule, and the plan would get it wrong.**
`defaultAgentLaunch --in-surface <ref>` types `cd <cwd> && <launcher>` into an *existing*
surface. If `--cwd` is absent, the agent starts in whatever directory that target surface
is already sitting in — which is neither the workspace root nor the calling surface's cwd.
So the correct lookup path for `--in-surface` is `cwdArg ?? <target surface's directory>`.
Mechanically applying C11-194's resolution here would resolve config against the workspace
root while the agent actually boots somewhere else, which *reintroduces the exact
divergence item 2 exists to prevent* — just with a less obviously-wrong path than `/`. The
plan must call this out; a delegator handed "use the resolved effective launch cwd" will
not discover it.

**(c) Item 1's fallback is the wrong default, and I'd delete it.** The plan preserves
`?? FileManager.default.currentDirectoryPath` for the case where nothing resolves. For a
Finder-launched GUI app that value is `/`, which means the fallback's only possible
behaviors are (i) return nil, identical to passing nil, or (ii) pick up a stray
`/.c11/agents.json` and apply a *machine-root* config to an unrelated launch. `find(from:)`
already handles nil by returning nil. Removing the fallback strictly increases determinism,
removes the only remaining path by which the reported bug can occur, and shortens the
diff. Keeping it preserves the bug in miniature and gives the next reader the impression
that process cwd is a meaningful input here. Recommend: drop it, and if the operator wants
a safety net, make it `home` (as `GhosttyTerminalView` already does) rather than cwd.

**(d) An un-discussed precedence side effect.** C11-194 orders workspace root *above*
launching-surface cwd. `find(from:)` walks *upward*. Composed, that means: a surface
`cd`'d into `<root>/packages/foo` which has its own `.c11/agents.json` will, once a
workspace root is set, resolve config from `<root>` and **never see the subproject file**.
Before this change it saw (nothing, because of the bug); after C11-194 alone it would see
the subproject file via launching-surface cwd; after a root is set it stops seeing it. The
plan's non-goal says "changing project-config precedence" is out of scope — but this *is*
a precedence change, delivered implicitly through the cwd change. For a monorepo with
per-package agent configs this is a regression relative to the naive expectation. It may
well be the desired semantics ("the workspace root defines the project"), but it should be
a decision, not a side effect, and it should be documented in `docs/launch-agent-reference.md`.

**Alternative framing worth one paragraph of consideration:** the CLI currently sends
`caller_surface_id` and lets the *server* infer the caller's cwd from `panelDirectories`
(OSC 7 / shell integration), falling back to `requestedWorkingDirectory` and then the
workspace's `currentDirectory`. But the CLI process **knows its own cwd exactly and
always**, with no shell-integration dependency and no staleness window. A `caller_cwd`
param carrying `.launchingSurface`-equivalent (inherited, not explicit) provenance would be
strictly more accurate than server-side inference, and would make config lookup right even
in surfaces where shell integration is off or the directory report is stale. This is mostly
C11-194's call, but it directly determines whether C11-195's fix actually finds the file in
practice, so it belongs in this review. It is additive and does not disturb C11-193's
explicit-vs-inherited warning distinction.

---

## Is This the Move?

Yes on substance. Two process bets I'd question:

**Three tickets, one branch, one PR (#407).** C11-195 is, in code, roughly a four-line
change gated behind two dependencies that are both *actively moving*: C11-194 was reset
today and is back in progress, and C11-193 flipped from refuse→warn (rev 3) while the
branch still contains the *reject* implementation
(`AgentLaunchWorkingDirectoryResolver.decision` returns `.reject` for inherited linked
worktrees, and SocketDispatch returns `err(code: "linked_worktree_cwd")`). So C11-195 is
being planned against a base that is known-stale and will be rewritten underneath it. With
all three sharing one PR there is no independent review surface and no independent revert:
if the worktree-warning policy needs another spin, the config-lookup fix — which is
uncontroversial and shippable today — is held hostage.

I'd either (a) fold C11-195's socket-path change into C11-194 as an acceptance criterion
(it's one line and one test, and C11-194 already owns the resolver), keeping C11-195 alive
only for the `TerminalController`/`--in-surface` site, or (b) split PR #407 so the cwd
resolver + config lookup can merge while the warning-policy churn continues. The current
shape maximizes coupling for no benefit I can see.

**Sequencing claim "must land first" is right but under-enforced.** The plan asserts the
dependency in prose. On a shared branch with a shared assignee that's fine; if the
delegator model ever splits these across worktrees, this needs to be a real Lattice
`blocked_by`, not a sentence.

---

## Key Strengths

- **Correct root-cause attribution.** "The launching surface's cwd is never plumbed to the
  server" is the real bug; `lookupCwd` is a symptom. Fixing at the resolver rather than
  patching the symptom is the right instinct and is why 193/194/195 compose instead of
  conflicting.
- **Item 2 names the right invariant** (lookup path == child cwd), even if it under-delivers
  on enforcing it. Most plans would have fixed the lookup and never noticed that divergence
  is the actual hazard class.
- **The non-goal on precedence is disciplined** in spirit — resisting the temptation to
  redesign project-config resolution while fixing a plumbing bug is correct. (It just needs
  to be honest about the implicit precedence shift described above.)
- **Item 4 insists on a tagged-app runtime check**, which is the right bar for this repo:
  every one of these five call sites is reachable only through real launch flows, and a
  green logic suite here would prove very little on its own.

---

## Weaknesses and Gaps

1. **Ambiguous scope → predictable partial fix.** (Executive Summary #1.) Downstream: the
   ticket closes, the CLI path stays broken, and the next person to hit it re-files it
   because the closed ticket's text says it was covered.

2. **Vacuous test.** (Executive Summary #3.) Downstream: a permanently green test that
   cannot fail if someone reintroduces `?? processCwd`. Worse than no test, because it
   creates false confidence at exactly the point of the regression.

3. **No test seam identified, and the obvious target is untestable.**
   `defaultAgentLaunch` is `private` on `TerminalController`. Reaching it means going
   through the command dispatcher on `TerminalController.shared` — which is precisely the
   pattern that caused **C11-105** (a logic-target test calling `TerminalController.shared`
   unlinked the production socket). Any plan that says "add a logic test" here without
   naming the seam is walking toward that mine. Extract a pure
   `agentConfigLookupPath(explicit:workspaceRoot:surfaceCwd:targetSurfaceCwd:) -> String?`
   and test *that*.

4. **Test-target placement unstated.** `c11LogicTests` is a target whose sources live in
   `c11Tests/` on disk; membership is set in `project.pbxproj`. A new file added to the
   wrong target silently becomes host-bound (slow, DEV.app-launching) — and per CLAUDE.md,
   pbxproj edits via the Ruby gem produce multi-thousand-line normalization diffs. The plan
   should either add the test to an existing logic-target file (strongly preferred, zero
   pbxproj churn) or budget for the pbxproj diff and the reviewer guidance that goes with it.

5. **Item 4's validation has no named oracle.** "Uses the project-level agent configuration"
   is not directly observable from the UI. It needs a concrete, distinguishable signal — e.g.
   a scratch project whose `.c11/agents.json` sets `defaultAgent` to a harness the user
   default is *not*, then observe which binary actually launches; or a per-agent `model`
   override visible in the composed launch line / `--json` payload. Without naming it, this
   step degrades into "looked right."

6. **No stated behavior for the malformed/absent-file case.** `find(from:)` swallows parse
   errors by design. After this fix, a project with a *broken* `.c11/agents.json` will look
   identical to one with no file — and users will now start relying on this path, so the
   silent-swallow is about to become much more visible. Worth at least a log line, or an
   explicit "still silent, documented" note.

7. **Nothing about the C11-193 reject→warn drift on the shared branch.** The plan builds on
   a resolver whose `decision()` still rejects. If C11-195's tagged-app validation (item 4)
   is run from a linked worktree — which is the normal lattice-orchestrator shape — the
   inherited launch will be *rejected* and item 4 cannot pass. The validation step will
   appear to fail for reasons that have nothing to do with C11-195. Sequence the validation
   after C11-193's warn-only rewrite, or validate from a main checkout, and say which.

8. **No CHANGELOG / docs line.** Both sibling plans have explicit doc-update steps
   (C11-194 item 5, C11-193 item 9). C11-195 has none, despite being the ticket that makes
   `.c11/agents.json` actually work on the default path — arguably the most user-visible of
   the three. `docs/launch-agent-reference.md` should state which path config is resolved
   from, and the installed skill should be synced per the hard rule in CLAUDE.md.

---

## Alternatives Considered

| Choice in plan | Alternative | Verdict |
|---|---|---|
| Fix at C11-194's resolver | Patch each `find(from:)` call site independently | Plan is clearly right. Per-site patching is how you end up with five subtly different rules — which is already the status quo. |
| Keep `?? processCwd` as last-resort fallback | Drop it (lookup returns nil), or fall back to `home` | **Alternative is better.** The fallback's only possible effects are "same as nil" or "apply `/.c11/agents.json`." Neither is worth a line of code. |
| Convention that lookup path == child cwd | A single `AgentLaunchContext` value carrying both | **Alternative is better** and cheap. Makes item 2 verifiable instead of aspirational. |
| Server infers caller cwd from `caller_surface_id` + `panelDirectories` | CLI sends its own `caller_cwd` with inherited provenance | Alternative is more accurate (no shell-integration dependency, no staleness). Mostly C11-194's decision, but it determines whether this fix works in practice. Worth raising. |
| C11-195 as a separate ticket on the shared branch | Fold the socket-path line into C11-194; keep C11-195 for the CLI site only | Alternative reduces coupling on a single-PR branch. Judgment call, but the current shape has real cost and no benefit. |
| Scratch-dir test of `find(from:)` | Pure `lookupPath(...)` seam test + one end-to-end assertion on the composed launch | **Alternative is much better**; the plan's version cannot fail. |

---

## Readiness Verdict

**Needs revision.** Not a rethink — the direction is right and the fix point is right. But
as written a delegator can execute all five bullets faithfully and ship a fix that (a)
leaves the second reported site broken, (b) has a test that cannot detect the regression,
and (c) may fail its own validation step for unrelated reasons.

Minimum changes that flip this to *ready to execute*:

1. Enumerate the call sites and give each an explicit in/out disposition. Resolve the
   contradiction between the non-goal and the ticket's `TerminalController.swift:9074`
   mention.
2. Restate item 2 as *verify C11-194's invariant* (and, ideally, harden it with a single
   context value) rather than as duplicate work.
3. Name the test seam — a pure lookup-path function — and state the target
   (`c11LogicTests`), preferring an existing file to avoid pbxproj churn. Drop the
   tautological `find(from:)` assertion.
4. Name the observable oracle for item 4, and state where it is run from (not a linked
   worktree, until C11-193's warn-only rewrite lands).
5. Decide the `?? processCwd` fallback question explicitly.
6. Add the doc/CHANGELOG/skill-sync line.

---

## Questions for the Plan Author

1. **Is `TerminalController.defaultAgentLaunch` (line ~9080) in scope or not?** The ticket
   names it; your non-goal appears to exclude it. This needs a one-word answer and a
   corresponding edit to the plan.
2. If it *is* in scope: what lookup path do you intend for the **`--in-surface`** path? The
   agent boots in the target surface's existing directory, so C11-194's
   root/caller resolution is the wrong input there. Do you agree the rule should be
   `cwdArg ?? <target surface's directory>`?
3. Note that on the A-button-mimic branch of `defaultAgentLaunch`, the `projectConfig`
   computed at line 9082 is used only for the empty-command guard and then discarded —
   `tab.launchAgentSurface` re-derives config from `resolverCwdForAgentLaunch()`. Is
   collapsing that duplicate resolution in scope, or explicitly deferred?
4. **Are you aware the socket-path change is already on `origin/fix/C11-193-launch-agent-cwd`**
   (SocketDispatch.swift:1190 already reads `cwdResolution.path ?? processCwd`, and surface
   creation already receives `cwdResolution.path`)? If so, what is the *residual* work item
   1 and item 2 describe?
5. **Keep or drop the `?? FileManager.default.currentDirectoryPath` fallback?** I'd drop it.
   Do you see a launch path where the app's process cwd is a meaningful project root?
6. **Which target does the new test go in**, `c11LogicTests` or `c11Tests`? (Note the
   existing `DefaultAgentResolverTests.swift` sits in the host target.) And will it be a new
   file — i.e. a `project.pbxproj` edit with the known normalization churn — or an addition
   to an existing file?
7. **What exactly does the test assert?** Concretely: what function does it call, and what
   change to production code would make it go red? If the answer is
   "`DefaultAgentProjectConfig.find`", the test does not cover this bug — do you agree a
   pure lookup-path seam is needed?
8. **What is the observable oracle for item 4?** Which field of the project
   `.c11/agents.json` will you make distinguishable from the user default, and where do you
   read the result (launch line, `--json` payload, the binary that actually starts)?
9. **Where will item 4's tagged-app validation be run from?** If it's a linked worktree, the
   branch's current `decision()` will *reject* the inherited launch and the step cannot pass
   until C11-193's warn-only rewrite lands. Is validation sequenced after that?
10. **The implicit precedence shift:** with a workspace root set, a surface `cd`'d into a
    subdirectory that owns its own `.c11/agents.json` will now resolve from the root and
    never see the subproject file. Is that the intended semantics ("root defines the
    project")? If yes, will you document it? If no, should launching-surface cwd win for
    *config lookup* even when workspace root wins for *child cwd* — and does that violate
    your own item-2 invariant?
11. **Should the CLI send `caller_cwd` directly** rather than having the server infer the
    caller's directory from `caller_surface_id` + shell-reported `panelDirectories`? The CLI
    always knows its own cwd; the server-side inference depends on shell integration being
    live and current. (C11-194's call, but it decides whether this fix finds the file.)
12. **Malformed `.c11/agents.json` is silently ignored today.** Once this path actually
    works, users will hit that. Add a log/warning, or keep it silent and document?
13. **Docs, CHANGELOG, and installed-skill sync** are absent from this plan but present in
    both siblings. Intentional (covered by C11-194's doc step) or an omission?
14. **Should C11-195's socket-path line simply fold into C11-194** as an acceptance
    criterion, leaving C11-195 to own only the CLI/`--in-surface` site? Given all three
    tickets share one branch and one PR, is there a reason to keep them separate that I'm
    not seeing?
15. **What is the regression guard against re-introduction?** After this lands, is there
    anything preventing a sixth `DefaultAgentProjectConfig.find(from: someAdHocPath)` call
    site from appearing? A single documented entry point (or making the raw `find` internal
    to one helper) would be a durable close-out; per-site fixes are not.
