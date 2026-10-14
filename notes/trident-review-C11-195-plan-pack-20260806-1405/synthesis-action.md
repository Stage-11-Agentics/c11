# Action-Ready Synthesis: C11-195-plan

## Verdict

**revise-then-proceed**

Reviewer disagreement, documented per the rules: 8 of 9 reviewers returned "needs
revision" or worse (all three adversarial reviewers rated concern **high**).
Only `standard-gemini` returned "ready to execute, pending minor clarifications
on threading." Biasing to the more cautious side, the plan is not executable as
written. No reviewer challenged the plan's *direction* (fix at C11-194's
resolver, consume rather than re-derive); every reviewer endorsed it explicitly.
The problem is entirely under-specification: as written, a competent delegator
can execute all five bullets faithfully and close the ticket with a near-zero
diff, half the reported bug still live, and a test that cannot fail.

The revision is substantial (effectively a rewrite of all five bullets) but it is
in-place: no reframe, no new fix point. Two blockers (B1 scope, B4 fallback
policy) encode a decision the plan author/operator must make; if their answers
differ from the reviewer-converged default noted in each item, the revised plan
warrants a quick re-read before implementation.

### Branch facts verified during synthesis (read-only)

These were checked against `origin/fix/C11-193-launch-agent-cwd` and are relied on
by several items below. A downstream agent can trust them without re-verifying.

- `Sources/SocketHandlers/SocketDispatch.swift:1190` already reads
  `let lookupCwd = cwdResolution.path ?? FileManager.default.currentDirectoryPath`;
  line 1192 calls `DefaultAgentProjectConfig.find(from: lookupCwd)`.
- Surface creation in the same handler already receives `cwdResolution.path`
  (i.e. the **pre-fallback optional**) via `tabManager.addWorkspace(workingDirectory:)`
  and `target.newTerminalSurface(workingDirectory:)`.
- `Sources/TerminalController.swift:9080` still reads
  `let lookupCwd = cwdArg ?? FileManager.default.currentDirectoryPath` — **unfixed**.
- `AgentLaunchWorkingDirectoryResolver.decision(...)` (in `Sources/DefaultAgentResolver.swift`)
  still returns `.reject(...)` for an inherited linked-worktree cwd, and
  `v2AgentLaunch` evaluates it **before** the config lookup, returning
  `err(code: "linked_worktree_cwd")`. C11-193 rev 3 supersedes this to warn-only.
- `AgentLaunchWorkingDirectoryResolution` is `{ path: String?, source: AgentLaunchWorkingDirectorySource? }`
  with sources `explicit` / `workspaceRoot` / `launchingSurface`. There is **no**
  process-fallback source. Both fields are `nil` in the no-context case.
- New-workspace creation passes `establishRootFromWorkingDirectory: cwdResolution.source != .launchingSurface`
  — which evaluates **true** when `source` is `nil`.
- `DefaultAgentProjectConfig.find(from:)` (`Sources/DefaultAgentProjectConfig.swift`)
  walks up to 64 levels toward `/` with no `$HOME`/repo-root stop, uses
  `standardizedFileURL` (does **not** resolve symlinks), returns `nil` for a nil or
  empty path, and silently swallows parse failures.
- There are exactly **five** production call sites of `DefaultAgentProjectConfig.find`
  on the branch: `SocketDispatch.swift:1192`, `TerminalController.swift:9082`,
  `Workspace.swift:12488` (via `resolverCwdForAgentLaunch()`),
  `GhosttyTerminalView.swift:3471` (falls back to `$HOME`), `AppDelegate.swift:6764`.
- `launchInExistingSurface` is called with `cwd: cwdArg` — so on `--in-surface`
  with no `--cwd`, the child inherits the **target** surface's directory.
- `~/.c11/agents.json` does **not** currently exist on this machine (only
  `~/.c11/runtime/`). The `$HOME`-ancestor hazard in I2 is a class hazard, not a
  live one today.

---

## Apply by default

### Blockers (plan is not yet executable as written)

- **B1: The plan's non-goal contradicts the ticket about `TerminalController.defaultAgentLaunch`, and no call site is enumerated**
  - Where in the plan: item 1 ("Use the resolved effective launch cwd for `DefaultAgentProjectConfig.find(from:)`" — singular) and the Non-goals line ("changing project-config precedence or the A-button/default-agent entry point beyond shared helper reuse").
  - Problem: the ticket explicitly names `TerminalController.swift` `defaultAgentLaunch` as a second site of the same bug, and it is verifiably still `cwdArg ?? processCwd` on the branch. The non-goal reads most naturally as excluding exactly that site. An implementer resolves the ambiguity in the direction of less work, closes C11-195 green, and leaves half the reported bug live at a line the ticket text cites.
  - Revision: replace item 1 with an explicit per-site disposition table covering all five `DefaultAgentProjectConfig.find` call sites listed in "Branch facts" above — each marked *fix here* / *verified already correct* / *deferred to ticket X*. Rewrite the Non-goals line so it no longer reads as excluding `defaultAgentLaunch`; state in one sentence whether that site is in scope (the reviewer-converged default: **yes, it is in scope** — it is the only site the ticket names that the branch does not fix). If it is deliberately deferred, name the follow-up ticket in the plan.
  - Sources: standard-claude (exec summary #1, weakness #1, Q1), standard-codex (weakness #4, Q1), adversarial-claude (exec summary, uncomfortable truth #2, Q2), adversarial-codex (exec summary, blind spot #1, challenged decision, Q4/Q20), evolutionary-claude (#1, Q1), evolutionary-codex (#3, Q2). 6 of 9 reviewers, all three lenses.

- **B2: The plan does not know its own starting state — items 1 and 2 are already implemented on the branch it targets**
  - Where in the plan: items 1 and 2 ("Use the resolved effective launch cwd…", "Pass that same resolved path into surface creation…").
  - Problem: both are already on `origin/fix/C11-193-launch-agent-cwd` for the socket path (see Branch facts). The plan describes them as work to be done. The two failure modes are symmetric and both bad: the implementer re-does landed work and reverts a sibling's change during rebase, or reads "already done" and skips the parts that genuinely are not. The plan was evidently written from the ticket text rather than from the branch.
  - Revision: add a short "Baseline on `fix/C11-193-launch-agent-cwd`" section stating what already exists (quote the two facts: `lookupCwd = cwdResolution.path ?? processCwd` at SocketDispatch.swift:1190, and surface creation already receiving `cwdResolution.path`), then restate item 2 as an **invariant C11-195 verifies and hardens** (lookup path == child cwd == reported cwd), not as work it performs. Item 2's original content belongs to C11-194 plan item 1; cite it rather than duplicating it.
  - Sources: standard-claude (exec summary #2, weakness under "Item 2 is C11-194's work", Q4), adversarial-claude (exec summary "already implemented", uncomfortable truth #1, Q1, hindsight "zero-line diff"), evolutionary-claude (exec summary, Sequencing "the plan reads as if none of this exists"), evolutionary-codex ("the in-flight branch already shows the capability trying to emerge"). 4 reviewers, all three lenses. Verified in branch.

- **B3: The specified test is tautological — it re-proves `find(from:)` instead of the wiring that is broken**
  - Where in the plan: item 3 ("Add a scratch-backed logic test with project `.c11/agents.json` data under the resolved surface/root path and a different process fallback. Assert the project config is found from the resolved path, not the app cwd.").
  - Problem: `DefaultAgentProjectConfig.find(from:)` is already correct and already has scratch-backed upward-walk tests (`c11Tests/DefaultAgentConfigTests.swift`). The defect lives entirely in the caller's choice of path, so a test that hands `find(from:)` the resolved path proves nothing, and "not the app cwd" is a tautology against a function that never reads the app cwd. Worse, there is no seam to inject a "different process fallback": the process cwd is read inline inside a large socket handler that needs a live `TabManager`, and `chdir` is a process-global mutation hostile to a parallel XCTest bundle.
  - Revision: rewrite item 3 to (a) name the pure seam to extract — a function taking the C11-194 resolution plus an injected process-fallback path and returning the effective lookup path (and, ideally, `(config, sourcePath)`); (b) state the test target explicitly as **`c11LogicTests`**, and prefer adding to an existing logic-target file over a new file (a new file means a `project.pbxproj` edit, which per CLAUDE.md produces multi-thousand-line normalization churn); (c) require a **negative** case — a valid `.c11/agents.json` under the injected process fallback and none under the resolved path, asserting the process-cwd config is *not* applied; (d) require the demonstration that the test goes red when the fix is reverted. Do not reach `defaultAgentLaunch` through `TerminalController.shared` in a logic test — that is the C11-105 socket-unlink pattern.
  - Sources: standard-claude (exec summary #3, weaknesses #2/#3/#4, Q6/Q7), standard-codex (weakness #2, Q6), adversarial-claude (exec summary, fail pattern #4, assumption #6, challenged decision, Q8/Q9), adversarial-codex (fail pattern #3, challenged decision, Q9), evolutionary-claude (#3, suggestion 4, Q5), evolutionary-codex (#4, suggestion 4). 6 of 9 reviewers, all three lenses.

- **B4: The process-cwd fallback is under-specified and currently produces a split-brain in exactly the case the ticket is about**
  - Where in the plan: item 1, "use the app-process cwd only when no explicit, workspace-root, or launching-surface path exists at all," combined with item 2's claim that lookup and child cwd "cannot diverge."
  - Problem: on the branch, when the resolution is empty, config lookup materializes the process cwd while surface creation and the response still receive the pre-fallback `nil`. Those are three different values in one launch: config from the app's arbitrary cwd, child from whatever the terminal defaults to, response reporting `cwd: null`. That is precisely the divergence item 2 claims to eliminate, preserved under a rarer label. Because `.c11/agents.json` carries `command` and `envOverridesText`, choosing an unrelated config is a code-execution choice, not a cosmetic default.
  - Revision: make item 1 state a binding contract for the no-context case. The reviewer-converged default (5 of 6 reviewers who took a position) is **drop the fallback**: pass the optional path through, let `find(from:)` return `nil`, and fall back to the user default — `find` already handles nil/empty correctly. If the fallback is retained for compatibility instead, the plan must require that it become a first-class resolution source (e.g. `.processFallback`) that is used by **all three** consumers (config lookup, surface creation, response `cwd`/`cwd_source`) and is represented in C11-193's `warning_details` provenance. State whichever is chosen in one sentence; silence is the one unacceptable answer. (One dissent on the replacement value: `standard-gemini` floats `$HOME` rather than `nil`; see S3.)
  - Sources: standard-codex (exec summary — the "single biggest missing detail", weakness #1, Q2/Q3), adversarial-codex (exec summary — "biggest issue", challenged decision, Q1/Q2 both marked *blocking*), adversarial-claude (assumption #2, challenged decision, Q3), adversarial-gemini (challenged decision, hard Q1), evolutionary-codex (#2), standard-claude (architectural assessment (c), Q5), standard-gemini (weakness "App-process cwd Fallback", Q2). 7 of 9 reviewers. Split-brain verified in branch code.

- **B5: `default-agent launch --in-surface` needs its own lookup rule; applying C11-194's resolution there re-creates the divergence**
  - Where in the plan: item 1's single rule ("the resolved effective launch cwd") applied uniformly, with no mention of `--in-surface`.
  - Problem: verified in branch code, `launchInExistingSurface` is called with `cwd: cwdArg`. With no `--cwd`, the agent starts in the **target** surface's existing directory — not the workspace root and not the caller's cwd. Mechanically feeding C11-194's caller/root resolution into the config lookup on that path resolves configuration against one tree while the agent executes in another: the same class of bug as the one being fixed, with a less obviously-wrong path than `/`. A delegator handed "use the resolved effective launch cwd" will not discover this.
  - Revision: add an explicit `--in-surface` rule to the plan. The reviewer-converged rule is **`cwdArg ?? <target surface's current directory>`**, preserving the item-2 invariant (config lookup origin == the directory the child actually runs in) rather than the generic new-surface resolution. If `--in-surface` is instead being deferred, say so and name the follow-up.
  - Sources: standard-claude (architectural assessment (b), Q2), standard-codex (weakness #4, Q1), adversarial-claude (assumption #4, Q7), adversarial-codex (blind spot #3, Q5), evolutionary-codex (Q5). 5 of 9 reviewers, all three lenses.

- **B6: Item 4's validation has no observable oracle, so it cannot fail**
  - Where in the plan: item 4 ("Validate in the tagged app that an inherited/root launch reports the expected cwd and uses the project-level agent configuration").
  - Problem: "reports the expected cwd" is checkable (`cwd`/`cwd_source` are already in the response), but "uses the project-level agent configuration" is not directly observable — the launched harness can look identical whether the project config applied or the user default happened to match. As written, "validated" degrades to "the agent launched," which was already true before the fix. This repo's own CLAUDE.md names this exact failure mode (green tests, dead feature), and this bug *is* an instance of it.
  - Revision: specify the fixture and the artifacts. Seed a scratch project `.c11/agents.json` whose value is unmistakably distinct from the user default (e.g. a harmless sentinel `command` such as `echo C11-195-PROJECT-CONFIG`, or a harness/model the user default is not), seed a *conflicting decoy* config at the process-cwd fallback location, then require all of: the response's `cwd`/`cwd_source` match expectations; the composed launch line / `--json` payload carries the sentinel and not the decoy; the child's actual `pwd` equals the config search origin. Run both no-`--cwd` branches (workspace root wins; rootless falls back to launching surface). Launch via `scripts/launch-tagged-automation.sh <tag> --qa fresh` so the startup dialogs do not block automation.
  - Sources: standard-claude (weakness #5, Q8), standard-codex (weakness #5, Q7), adversarial-claude (fail pattern #5, challenged decision, Q10), adversarial-codex (assumption #7, blind spot #9, Q12), evolutionary-claude (#4, suggestion 7), evolutionary-codex (#5, suggestion 7). 6 of 9 reviewers, all three lenses.

### Important (revise before implementation starts)

- **I1: Item 4's validation cannot pass in the environment it will be run from**
  - Where in the plan: item 4, plus the opening line "C11-194's resolver … must land first."
  - Problem: verified — the branch's `AgentLaunchWorkingDirectoryResolver.decision` still returns `.reject` for an inherited linked-worktree cwd, and `v2AgentLaunch` evaluates it *before* the config lookup. Every lattice-orchestrator delegator runs inside a linked worktree, so an inherited launch there errors with `linked_worktree_cwd` and never reaches C11-195's code path. Item 4 will appear to fail for reasons unrelated to C11-195.
  - Revision: add one sentence to item 4 naming the validation environment — either "validate from a main checkout, not a linked worktree" or "sequence item 4 after C11-193's warn-only rewrite lands on the shared branch." Either is fine; silence is not.
  - Sources: standard-claude (weakness #7, Q9), evolutionary-claude (Sequencing hazard "not hypothetical; it is the current state of the shared branch", Q6), adversarial-claude (assumption #1). 3 reviewers, verified in branch code.

- **I2: The walk's stop point is being changed implicitly and needs a stated decision**
  - Where in the plan: item 1 (the start-path change) and the Non-goals line ("changing project-config precedence").
  - Problem: `find(from:)` walks up to 64 levels toward `/` with no repo-root or `$HOME` stop. Today the affected rails start the walk at the GUI process cwd (`/` for a Finder-launched app) and find nothing, so the feature is inert. After the fix the walk starts from a real path under `$HOME` and can newly reach ancestor configs — including `~/.c11/agents.json`, the exact artifact class behind the historical A-button pin bug fixed in PR #217. The walk bound is not "precedence," so the existing non-goal does not cover it; it is being changed as a side effect.
  - Revision: state the decision in one sentence — either "walk semantics unchanged; the ancestor-reachability shift is accepted" or "the walk clamps at the workspace root when one exists" — and pin whichever is chosen with a test. Reference the `~/.c11/agents.json` hazard explicitly so a reviewer can see it was considered rather than missed. (Note: that file does not currently exist on this machine; the hazard is class-level, not live.)
  - Sources: adversarial-claude (blind spot #1, "the highest-severity omission", Q4), evolutionary-claude (#2, suggestion 5, Q2), evolutionary-gemini (#1, concrete suggestion 1, Q1). 3 reviewers across two lenses.

- **I3: "C11-194 must land first" is unenforceable as written and must name an exact head**
  - Where in the plan: opening line, and item 5 ("link PR #407").
  - Problem: all three tickets share one branch and one open PR, so there is no observable "landing" event. C11-194 was completed, then reset on 2026-08-06 and is in progress again; C11-193's policy flipped from refuse to warn while the branch still carries the refuse implementation. C11-195 is therefore being planned against a base that is known-stale and will be rewritten underneath it. A bare PR link is not durable evidence of *this ticket's* completion.
  - Revision: replace "must land first" with a concrete gate — the exact commit/remote head on `fix/C11-193-launch-agent-cwd` that contains the final C11-194 resolver semantics and no longer contains C11-193's superseded refusal behavior — and state whether "first" means commit order inside the shared PR or a separate merge. Item 5's evidence must pin that head, not just the PR number.
  - Sources: standard-codex (weakness #6, Q8), adversarial-codex (fail pattern #4, challenged decision, Q16/Q17), adversarial-claude (assumption #1, Q15), adversarial-gemini (assumption audit, "Dependency Quicksand", Q5), standard-claude (process bet #2), standard-gemini (Q3), evolutionary-codex (Q7). 7 of 9 reviewers.

- **I4: No docs / CHANGELOG / installed-skill-sync step, unlike both sibling plans**
  - Where in the plan: the five items; nothing covers documentation.
  - Problem: C11-193's plan carries a doc + skill-sync step (item 9) and C11-194's does too (item 5). C11-195 has none, despite being the ticket that makes `.c11/agents.json` actually work on the default path — arguably the most user-visible of the three. `docs/launch-agent-reference.md` and `skills/c11/references/api.md` are already in PR #407's file list, and CLAUDE.md carries a hard rule that editing an installable skill is incomplete until `scripts/sync-installed-skills.sh` runs.
  - Revision: add a step covering `docs/launch-agent-reference.md` (state which path project config is resolved from, and the walk-bound decision from I2), a CHANGELOG entry for the user-visible behavior change, and `scripts/sync-installed-skills.sh c11` if any installable skill text is touched.
  - Sources: standard-claude (weakness #8, Q13), adversarial-claude (blind spot #6, Q13), adversarial-codex (blind spot #10, Q19), evolutionary-claude (suggestion 3). 4 reviewers across two lenses.

- **I5: No threading contract, on a repo that just shipped a main-thread deadlock fix**
  - Where in the plan: nothing addresses threading; item 1's "shared helper reuse" implies it.
  - Problem: the v2 path correctly does config/git I/O off-main on the socket worker with a bounded main-actor snapshot. But the v1 `default_agent` command is not in the socket-worker method sets, so `defaultAgentLaunch` runs on the main actor. If "shared helper reuse" drags C11-194's resolution (and with it `GitContextResolver`'s git subprocess/filesystem I/O) onto that path, the change adds blocking I/O to the main thread days after C11-200 / the `ghostty_surface_set_display_id` deadlock fix. C11-193's plan has a dedicated threading step (item 6); C11-195 inherits the requirement and drops it.
  - Revision: add one line stating that project-config and git I/O stay off-main on the v2 path, and specifying the threading approach for the main-actor v1 path if `defaultAgentLaunch` is in scope (per B1).
  - Sources: adversarial-claude (blind spot #5, Q11), adversarial-codex (blind spot #6, Q14), standard-gemini (weakness "Threading Subtlety", Q1 — its only substantive concern), standard-codex ("Keep config and filesystem I/O off-main"). 4 reviewers across all three lenses.

- **I6: The A button will newly diverge from the CLI once workspace roots exist — needs a named disposition**
  - Where in the plan: the Non-goals line excludes the A-button entry point.
  - Problem: `Workspace.swift:12488` resolves project config via `resolverCwdForAgentLaunch()`, which reads the focused panel's directory and never consults `workspace.rootDirectory`. After this arc lands, a workspace with an explicit root resolves project config from the **root** when launched via CLI and from the **shell's wandered cwd** when launched via the A button — same operator, same workspace, two different agents. This is a new inconsistency created by this arc, in the surface the operator uses most, not a pre-existing one.
  - Revision: give it an explicit disposition in the plan. Either scope in the one-line change (put `rootDirectory` at the front of `resolverCwdForAgentLaunch()`'s ladder) or file a follow-up ticket **before merging** and reference it by ID in the plan. Do not leave it unmentioned.
  - Sources: adversarial-claude (fail pattern #3, hindsight preview, challenged decision, Q12), evolutionary-claude (#1 site 3, suggestion 6, Q3), evolutionary-codex (#3), adversarial-codex (blind spot #1). 4 reviewers across two lenses. Divergence verified in branch code.

### Straightforward mediums

- **M1: Add negative controls to the tagged-app validation**
  - Where in the plan: item 4.
  - Problem: item 4 validates the positive case only.
  - Revision: add to item 4 the negative cases every reviewer who touched validation asked for: a workspace with no project config still uses the user default; a `.c11/agents.json` that omits `defaultAgent` does not displace the Settings pick (the `overrideDefaultAgent` invariant from PR #217, which this change puts back under load for the first time); a decoy config at the process-cwd fallback is not selected.
  - Sources: adversarial-claude (blind spot #7), evolutionary-claude (#3 "negative test"), standard-codex (weakness #3, table-driven matrix), evolutionary-codex (suggestion 4, decoy row).

- **M2: Name the symlink-normalization hazard in the test spec**
  - Where in the plan: item 3 ("scratch-backed logic test").
  - Problem: `find(from:)` uses `standardizedFileURL`, which resolves `..` but not symlinks. On macOS `/tmp` is a symlink to `/private/tmp`. If the resolver or a surface reports a realpath'd cwd while the test seeds a `/tmp` path (or vice versa), a scratch-backed assertion can pass or fail for reasons unrelated to the fix — a classic afternoon lost to a "flaky" CI test.
  - Revision: add one sentence to item 3 requiring scratch fixtures to use consistently normalized (realpath'd) paths on both sides of the assertion, and stating that symlink resolution semantics are not being changed.
  - Sources: adversarial-claude (blind spot #8), adversarial-gemini (blind spot "Symlinks"), adversarial-codex (assumption #4).

- **M3: State the malformed-`.c11/agents.json` behavior explicitly**
  - Where in the plan: nothing addresses it.
  - Problem: `find(from:)` silently swallows parse failures by design, so a project with a *broken* config looks identical to one with no config. Today this is invisible because the path is inert; after this fix users will start relying on it, and "my config isn't applying" becomes an undiagnosable report.
  - Revision: add one sentence choosing a behavior — "remains silent, documented in `docs/launch-agent-reference.md`" or "emit a non-fatal warning naming the unparseable file." Either is acceptable; the plan just needs to have decided. (Reviewers split: two argued for a warning, one explicitly rated continued silence as fine.)
  - Sources: standard-claude (weakness #6, Q12), evolutionary-gemini (concrete suggestion 3, Q5); adversarial-claude rated keeping it silent acceptable (assumption audit, "cosmetic").

- **M4: Require the test to be demonstrated red before the fix**
  - Where in the plan: item 3.
  - Problem: for a wiring fix this is the only meaningful gate, and the plan does not ask for it. Combined with B2 (the socket-path change already exists on the branch), a test written after the fact will pass on a clean checkout *and* on a revert, and nobody will notice.
  - Revision: add to item 3 an explicit requirement to show the new test failing with the fix reverted, and to record that in the evidence at item 5.
  - Sources: adversarial-claude (Q9, "Early warning signs" — the added test passes both with and without the fix); reinforced by evolutionary-claude (#3, the negative case is what would have caught the original bug) and adversarial-codex (fail pattern #3). Single-reviewer origin but concrete, well-scoped, and self-validating against B2/B3.

### Evolutionary clear wins

- **EW1: Add `config_source` (the resolved `.c11/agents.json` path, or null) to the `agent.launch` response**
  - Where in the plan: nowhere; the response already carries `cwd` and `cwd_source` from C11-194/193.
  - Problem: the defining property of this bug was **silence** — there is no way, from a launch response or any CLI, to see whether a project config was found or from which path. Every future "why did it launch codex" report requires a maintainer to mentally simulate a 64-level upward walk from a path the operator cannot see. Separately, this field is what makes B6's validation a one-line assertion instead of a squint, and gives B3's test a stable assertion target.
  - Revision: add a plan step introducing `config_source` next to the existing `cwd`/`cwd_source` in the `agent.launch` response, and sequence it **before** item 4 so validation can assert on it. It carries the doc/skill-sync work already required by I4 (`docs/socket-api-reference.md`, `docs/launch-agent-reference.md`, `skills/c11/references/api.md`, then `scripts/sync-installed-skills.sh c11`).
  - Sources: adversarial-claude (blind spot #3 — "the highest-leverage thing missing from the plan and it costs roughly ten lines", Q6), evolutionary-claude (M2 — "highest leverage per line of code", suggestion 3, Q4), evolutionary-gemini (concrete suggestion 2, Q4), evolutionary-codex (suggestion 3/8). 4 reviewers across two lenses; additive, ~10 lines, and it directly unblocks B6.

---

## Surface to user (do not apply silently)

- **S1: Should the whole arc adopt an immutable `AgentLaunchContext` / `PreparedAgentLaunch` type rather than passing a `String?` around?**
  - Why deferred: design-needed (changes C11-194's contract, not just C11-195's consumption)
  - Summary: five reviewers independently proposed replacing the loose resolved-path convention with a single frozen value carrying the normalized path, provenance, the loaded project config plus its source path, and (per adversarial-codex) the pinned target workspace/pane identity — so that "lookup path == child cwd" becomes a type-level property rather than two adjacent lines that both happen to read the same variable. Several framed it as the difference between fixing this bug and ending this bug class. It is genuinely cheap (a dozen lines by standard-claude's estimate), but it reshapes an interface C11-194 owns while C11-194 is mid-reset, and it expands a four-line fix into a cross-ticket refactor. The plan author should decide whether this lands in C11-195, folds into C11-194, or becomes a follow-up.
  - Sources: standard-claude (architectural assessment (a)), standard-codex (architectural assessment, "materialize one launch-directory context" — its recommended option), adversarial-codex (challenged decision, Q3), evolutionary-codex (#1 — with a verbatim acceptance invariant offered for the plan), evolutionary-claude (M1 — make the raw-`String?` `find` overload unrepresentable).

- **S2: Trust model for `.c11/agents.json` — it is executable configuration, and this ticket makes it live on the rail pointed at other people's trees**
  - Why deferred: design-needed + operator strategic call
  - Summary: `AgentConfig` carries `command` (the shell line c11 types into a PTY) and `envOverridesText` (environment injected at spawn). Once discovery actually works, a cloned repository's checked-in file can dictate what runs on the operator's machine, in their shell, with their credentials in env — and C11-193's whole premise is launching agents into trees the operator did not necessarily author. Four reviewers raised this; two proposed a VS Code-style workspace-trust gate, one proposed retaining config origin now and deferring trust UX. The exposure is not net-new as a class (the A-button path already has it), but this ticket extends it to the rail explicitly designed to point elsewhere. The minimum-cost resolution is one line in Non-goals stating the posture ("trust gating is pre-existing and out of scope for this ticket") plus a CHANGELOG note; a trust gate is a separate project. This is the operator's call, not a silent edit.
  - Sources: adversarial-claude (blind spot #2, uncomfortable truth #4, Q5), adversarial-gemini (exec summary "the single biggest issue", blind spot "Security & Trust", hard Q2), evolutionary-gemini (mutation "Workspace Trust Boundary", Q2), evolutionary-codex ("Trust-aware project configuration" — retain origin now, trust UX later).

- **S3: What should replace the process-cwd fallback — `nil`, or `$HOME`?**
  - Why deferred: disagreement on the correct value (the *decision must be made* is captured in B4; the value is not settled)
  - Summary: the reviewers who took a position overwhelmingly agree the app-process cwd should not be consulted, but they split on the replacement. Five argued for passing `nil` (skip the lookup, fall back to the user default — `find` already handles nil). `standard-gemini` and `standard-claude` both floated the user's home directory as a "safety net," noting `GhosttyTerminalView.swift` already falls back to `$HOME` — though standard-claude ultimately preferred nil, and adversarial-claude argued `$HOME` is *the worst possible* start for an unbounded upward walk (it maximizes the chance of picking up `~/.c11/agents.json`, which is I2's hazard). Given that tension, the value should be chosen deliberately.
  - Sources: nil — adversarial-claude (challenged decision), adversarial-codex (challenged decision), adversarial-gemini (Q1), evolutionary-codex (#2 "Recommended"), standard-codex (weakness #1). `$HOME` floated — standard-gemini (weakness, Q2), standard-claude (architectural assessment (c), as a distant second to nil).

- **S4: Should C11-195 be restructured relative to PR #407 — folded into C11-194, or split into its own PR?**
  - Why deferred: process/operator call, and reviewers propose different restructurings
  - Summary: two reviewers argue the current shape (three tickets, one branch, one PR, one of the dependencies actively being reworked) maximizes coupling for no benefit: C11-195's delta is a handful of lines buried in a large diff with no independent review surface and no independent revert, so an uncontroversial and shippable config-lookup fix is held hostage to worktree-policy churn. Proposed alternatives: (a) fold the socket-path line into C11-194 as an acceptance criterion, keeping C11-195 alive only for the `TerminalController` / `--in-surface` site; (b) split PR #407 so the resolver + config lookup can merge while policy churn continues. adversarial-claude separately notes that in any split, C11-195's delta is the one most likely to be silently dropped, and suggests making the change self-identifying (a named helper symbol whose absence is a compile error).
  - Sources: standard-claude ("Is This the Move?", alternatives table, Q14), adversarial-claude (fail pattern #1, reality stress test disruption 2).

- **S5: Should the CLI send its own `caller_cwd` instead of the server inferring the caller's directory?**
  - Why deferred: reviewers directly disagree
  - Summary: standard-claude argues the CLI process always knows its own cwd exactly, with no shell-integration dependency and no staleness window, whereas the server's inference from `caller_surface_id` + `panelDirectories` (OSC 7) is stale for full-screen TUIs that `cd`, shells without integration, and remote/ssh surfaces — and this directly determines whether C11-195's fix finds the file in practice. adversarial-codex argues the opposite: a caller-supplied cwd is wrong for `--workspace`, `--pane`, background callers, and direct socket callers, and server-side target-context resolution is the stronger boundary. Both note it is properly C11-194's decision.
  - Sources: standard-claude (alternative framing, alternatives table, Q11) vs. adversarial-codex (alternatives considered, "Send the CLI process cwd as implicit `--cwd`" — rejected). Also touched by adversarial-claude (assumption #5, stale `panelDirectories`).

- **S6: Target-identity race — the workspace is re-resolved on the main actor after off-main I/O**
  - Why deferred: ambiguous ownership (arguably C11-194's or a separate ticket), and it exists on the branch independent of C11-195
  - Summary: verified in branch code — `v2AgentLaunch` snapshots cwd inputs on main, does config/git I/O off-main, then in the `commit` block calls `v2ResolveWorkspace(params:tabManager:)` *again*. A background launch or an operator focus change during the I/O window can produce config resolved from workspace A and a surface created in workspace B. adversarial-codex proposes the resolved context carry pinned target identity and that commit either use it or fail; evolutionary-codex proposes at minimum a test row where the caller surface belongs to a background workspace different from the selected one. Related: adversarial-claude observes that on the branch `workspaceRoot` comes from the *target* workspace while `launchingSurfaceCwd` comes from `callerWorkspace ?? fallbackWorkspace`, so a cross-workspace launch can produce a hybrid path nobody chose.
  - Sources: adversarial-codex (fail pattern #1, blind spot #2, assumption #2, Q7/Q13), evolutionary-codex (#4 background-caller row, suggestion 5), adversarial-claude (blind spot #4).

- **S7: Stale / nonexistent resolved paths, and slow filesystems**
  - Why deferred: single-reviewer each, speculative severity, and policy is a design call
  - Summary: adversarial-codex notes persisted workspace roots can point at moved, deleted, unreadable, or file-not-directory paths, and that `find(from:)` does not require the starting directory to exist — so config discovery can walk an ancestor while the terminal falls back elsewhere; it asks for a stated policy. adversarial-gemini separately raises that the synchronous upward walk on the socket worker will stall if the inherited cwd lives on a slow SMB/NFS mount. Neither is corroborated by a second reviewer, and both would expand scope.
  - Sources: adversarial-codex (blind spot #5, Q8), adversarial-gemini (assumption audit, hard Q4).

- **S8: Should the launch cwd be aligned to the project-config root?**
  - Why deferred: single-reviewer, design-needed, and it contradicts the plan's stated invariant
  - Summary: adversarial-gemini observes that launching from `/project/deep/subdir` with config found at `/project/.c11/agents.json` means any relative paths inside that config (scripts, templates) resolve against the subdir and break, and asks whether the child should instead start at the config's root. This is a real ergonomic question, but adopting it would invert item 2's invariant (config lookup follows the child cwd, not the reverse) and change cwd semantics C11-194 owns. Relatedly, standard-claude flags a precedence side effect nobody has decided: with a workspace root set, a surface `cd`'d into a subproject that owns its own `.c11/agents.json` will resolve from the root and never see the subproject file — which may be the intended "root defines the project" semantics, but is currently arriving as a side effect rather than a decision.
  - Sources: adversarial-gemini (blind spot "Relative Path Context", hard Q3), standard-claude (architectural assessment (d), Q10).

---

## Evolutionary worth considering (do not apply silently)

- **E1: `c11 explain-launch` / `agent.launch --explain` — a dry run that prints the whole resolution ladder without launching**
  - Summary: a read-only mode returning the effective cwd and which rung won (explicit → workspace root → launching surface → fallback), which `.c11/agents.json` files were probed, which matched, the chosen harness/model/effort, warnings, and the composed command — calling the exact same preparation code as a real launch, not a diagnostic reimplementation. evolutionary-codex extends this to a durable per-surface "launch receipt" (cwd, cwd source, config path + content hash, caller surface, timestamp) so resume and bug reports can answer "why did this agent launch this way?" after the world has moved on.
  - Why worth a look: this ticket exists because a resolution chain was invisible; the durable answer to an invisible chain is a command that prints it, and every input is already a pure function.
  - Sources: evolutionary-claude (M3), evolutionary-codex ("Launch explain mode", "A durable launch receipt"), adversarial-claude (blind spot #3, as the larger version of EW1).

- **E2: Promote the `.c11/` walk into a shared `ProjectProfileResolver`**
  - Summary: `DefaultAgentProjectConfig` and `WorkspaceBlueprintStore` already perform the same bounded upward walk against the same `.c11/` directory with the same first-match-wins rule. One resolver, one walk, one clamp rule, one cache keyed on workspace root would halve the filesystem work per launch and give every future project-scoped setting (port ranges, blueprints, skill pins, sidebar defaults, launch policy) a home that is already correct. evolutionary-claude names this the plan's unstated third layer: once workspaces carry roots, c11 has for the first time a machine-readable notion of "the project this workspace is working on," and `.c11/agents.json` is its first tenant.
  - Why worth a look: it reframes "shared helper reuse" in the non-goals line from an afterthought into a platform seam, and it is the natural home for I2's clamp decision.
  - Sources: evolutionary-claude (M4/M5, "What's Really Being Built" layer 3, suggestion 8), evolutionary-gemini ("Spatial Configuration", cascading configs, sub-project personas), evolutionary-codex ("Configuration as a traced policy stack").

- **E3: Make the raw-`String?` lookup unrepresentable**
  - Summary: change the signature to `DefaultAgentProjectConfig.find(for: AgentLaunchWorkingDirectoryResolution)` (optionally with a `stoppingAt:` boundary per evolutionary-gemini) and remove the `String?` overload from the module's reachable surface. Five mechanical call-site edits; afterward a sixth ad-hoc lookup site costs a compile error rather than a bug report filed months later.
  - Why worth a look: it is the cheapest permanent end to this bug class, and it is strictly cheaper now than after a sixth call site exists — but it touches three sites the plan currently non-goals, so it is a scope decision rather than a silent edit.
  - Sources: evolutionary-claude (M1, suggestion 2, Q7), evolutionary-gemini (concrete suggestion 1), standard-claude (Q15, "what is the regression guard against re-introduction?").
