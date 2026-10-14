# Adversarial Plan Review: C11-195-plan (Claude)

Reviewed: 2026-08-06 14:05
Plan: `.lattice/plans/task_01KZBZY4WBCMG252XSJPJC1CPA.md`
Reviewer role: designated adversary. Not balanced by construction.

---

### Executive Summary

**Concern level: high, but not for the reasons the plan anticipates.**

This plan is five lines long and reads as if the work is a one-line change: swap
`FileManager.default.currentDirectoryPath` for C11-194's resolved path. Two things
are wrong with that framing.

**First, most of the plan is already implemented on the branch it depends on.** On
`origin/fix/C11-193-launch-agent-cwd`, `Sources/SocketHandlers/SocketDispatch.swift`
already reads `let lookupCwd = cwdResolution.path ?? FileManager.default.currentDirectoryPath`
and already passes `cwdResolution.path` into both `addWorkspace` and
`newTerminalSurface`. Steps 1 and 2 of this plan, for the socket path, are done.
The only call site named in the ticket that is *not* fixed on the branch is
`TerminalController.defaultAgentLaunch` (line 9074, still `cwdArg ?? processCwd`),
and this plan's own non-goal ("changing ... the A-button/default-agent entry point
beyond shared helper reuse") reads like it excludes exactly that. **As written, this
ticket can be closed with a zero-line diff and nobody will notice.** That is the
single most likely failure mode.

**Second, the risk this change actually carries is not addressed at all.** Fixing
this lookup does not merely "apply project config where it should have applied." It
switches on an unbounded 64-level upward filesystem walk from a *real* path for the
first time on these launch rails. Today the walk starts from a GUI process cwd,
which for a Finder/`open`-launched app is `/`, so it finds nothing and the feature
is inert. After the fix, every CLI agent launch under `$HOME` walks through
`$HOME/.c11/agents.json`. **That file is the exact artifact that caused C11's
default-agent pinning bug in 2026-05/06 (PR #217).** It is a plausible leftover on
operator machines. `.c11/agents.json` carries `command` and `envOverridesText`, which
means whatever file wins that walk dictates the shell command c11 executes and the
environment it executes in. The plan has no word about scoping the walk, about the
home-directory ancestor, about trust, or about telling the operator which file won.

The plan's third weakness is that its verification story does not survive contact
with the code. Step 3 asks for a "scratch-backed logic test ... with a different
process fallback," but the process cwd is read inline inside a 400-line socket
handler that requires a live `TabManager` and a main-actor snapshot. There is no
seam to inject it, and `chdir` is a process-global mutation hostile to a parallel
XCTest bundle. Without naming a new pure helper, this test either cannot be written
or degrades into a re-test of C11-194's resolver, which proves nothing about the
lookup.

---

### How Plans Like This Fail

Patterns that apply to "small correctness fix riding on a bigger refactor":

1. **The dependent ticket becomes a rounding error in the parent's PR.** Three
   tickets, one branch, one PR (#407). The C11-195 delta is a handful of lines
   buried in a 634-line diff. Nobody reviews it independently, nobody validates it
   independently, and the ticket closes on the parent's evidence. The plan's step 5
   ("record review and runtime evidence on C11-195") is the only defense and it is
   the weakest kind: a promise to write a note.

2. **"Fix the fallback" quietly becomes "turn on a dormant feature."** Nobody frames
   it that way, so nobody asks the questions you ask when turning on a feature:
   blast radius, opt-out, announcement, rollback. This plan is framed entirely as a
   bug fix. It is a behavior activation. Users who have a `.c11/agents.json`
   anywhere above their working tree will get a different harness, different model,
   different initial prompt, and different environment variables than they got
   yesterday, with no changelog line and no way to tell why.

3. **One-path fixes on a multi-path surface.** There are five call sites of
   `DefaultAgentProjectConfig.find` in the tree:
   - `SocketHandlers/SocketDispatch.swift:1075` (v2 `agent.launch`) - in scope
   - `TerminalController.swift:9076` (v1 `default_agent launch`) - ambiguously scoped
   - `Workspace.swift:12448` (A button, via `resolverCwdForAgentLaunch()`) - excluded
   - `GhosttyTerminalView.swift:3557` (exports `C11_DEFAULT_AGENT_LAUNCH` per shell,
     falls back to **home directory**) - not mentioned
   - `AppDelegate.swift:6764` (workspace-creation-with-agent) - not mentioned

   After this plan, c11 has two competing notions of "the cwd an agent launch is
   about": C11-194's provenance-carrying resolver, and `resolverCwdForAgentLaunch()`
   / bare `workingDirectory` at the other three sites. Divergence between them is
   guaranteed the moment workspace roots exist: a workspace with root `/repo` whose
   focused panel has `cd`'d to `/other` resolves the A button's config from `/other`
   and `launch-agent`'s config from `/repo`. Same operator, same workspace, two
   different agents. That is a worse bug than the one being fixed, because it is
   nondeterministic from the operator's point of view.

4. **Testing the pure function instead of the wiring.** C11-194 will have thorough
   resolver tests. It is very easy to add a test that calls
   `DefaultAgentProjectConfig.find(from: resolvedPath)` with a scratch fixture, watch
   it go green, and believe the lookup is fixed, when what needed proving is that
   `v2AgentLaunch` *passes* the resolved path. `DefaultAgentConfigTests.swift` already
   has five tests of exactly the `find(from:)` shape. Adding a sixth proves nothing new.

5. **Green tests, dead feature.** Per this repo's own CLAUDE.md: a wall of green
   tests can pass while the shipped path is inert. This bug is itself an instance of
   that pattern (the feature has been documented and shipped and never worked on
   this rail). Repeating the pattern is easy here because the only end-to-end oracle
   the plan names is vague ("uses the project-level agent configuration") with no
   stated observable.

---

### Assumption Audit

**Load-bearing, and shaky:**

1. *"C11-194's resolver is the natural fix point and must land first."*
   There is no "first." All three tickets are on one branch behind one open PR.
   C11-194 was completed, then reset on 2026-08-06, and is in progress again. The
   branch head still implements C11-193's **refusal** policy
   (`AgentLaunchWorkingDirectoryResolver.decision` returns `.reject(...)`) which
   rev 3 of the C11-193 plan explicitly superseded to warn-only. So the code this
   plan builds on is known-stale and will be rewritten under it. Sequencing language
   creates a false gate: there is nothing to observe "landing."

2. *The process-cwd fallback is a harmless last resort.*
   It is not harmless, it is the mechanism by which this bug is invisible in
   development and live in production. A dev build launched from a terminal in the
   checkout inherits a useful cwd; a Finder-launched `/Applications/c11.app` gets `/`.
   Keeping the fallback keeps the dev/prod behavioral split that hid the bug for
   months, and it means every future report of "project config did/didn't apply" is
   unreproducible across machines. `find(from:)` already handles `nil` and `""`
   correctly by returning `nil`. **The fallback should be deleted, not re-plumbed.**
   The plan explicitly preserves it (step 1: "use the app-process cwd only when no
   ... path exists at all"). That is a default masquerading as a decision.

3. *The upward walk terminating on the first `.c11/agents.json` is the right
   semantics once the start path is correct.* Unexamined. The walk is bounded only
   by 64 levels, not by a repo root, not by `$HOME`. See "Blind Spots" below.

4. *One resolved path can serve both "where to look for config" and "where the child
   runs."* False for `--in-surface`. On that path the child runs in the **target**
   surface's cwd (`launchInExistingSurface` composes `cd <cwd> && <launcher>`, and
   when `cwd` is nil the child simply inherits the target PTY's directory). The
   C11-194 resolver keys on the **caller** surface and the target *workspace* root.
   Feeding the resolver's path into the config lookup for `--in-surface` introduces
   precisely the divergence step 2 claims to eliminate: config from the caller's
   tree, execution in the target's tree.

5. *The caller's reported cwd is accurate.* `inheritedCwdForAgentLaunch` reads
   `panelDirectories`, which is populated by shell integration (OSC 7). A full-screen
   TUI that `cd`s, a shell without integration, a remote/ssh surface, or a surface
   whose last report predates a `cd` all yield a stale path. Today a stale path
   causes a mildly wrong child cwd. After this change it also silently selects a
   different agent binary and different env. The failure gets louder and less
   traceable.

6. *A "scratch-backed logic test" is writable for this behavior.* See executive
   summary. No seam exists. Also, the existing sibling tests live in
   **`c11Tests/`** (host-required, `c11-unit`), not `c11LogicTests/`. The plan says
   "logic test" without naming a target; if it lands next to its siblings it is not
   in the fast local loop and, per the operator's standing instruction in this repo,
   will not be run locally at all.

**Cosmetic (fine to assume):**
- `.c11/agents.json` parse failures stay silently swallowed. Fine, existing behavior.
- `AgentLaunchPlanner` correctly consumes a non-nil `projectConfig`. Well covered.

---

### Blind Spots

**1. `$HOME/.c11/agents.json` is an ancestor of nearly every launch cwd.**
This is the highest-severity omission. `DefaultAgentProjectConfig.find` walks up to
64 levels with no repo-root and no `$HOME` stop. Today the walk starts at `/` on the
affected rails and finds nothing. After the fix it starts at a real path under
`$HOME` and will find `~/.c11/agents.json` if one exists. This repo has already
been bitten by exactly that file: PR #217 (merged as `6dfeef923`) fixed the A button
being permanently pinned to Claude because a legacy `~/.c11/agents.json` decoded as
a valid project override. That fix hardened the *decoder* against the legacy array
shape; it did nothing about a modern, well-formed `~/.c11/agents.json`, which will
now be treated as a project config for every launch under the home directory.
The plan must decide: stop the walk at a repo/workspace root, stop at `$HOME`,
require the file to be below the resolved path's git root, or explicitly accept this
and say so. Currently it does not know the question exists.

**2. Trust boundary. `.c11/agents.json` is executable configuration.**
`AgentConfig` carries `command` (the shell line c11 types into a PTY) and
`envOverridesText` (environment injected at spawn). Making the lookup work means a
cloned repository's checked-in file can dictate what command runs on the operator's
machine, in their shell, with their credentials in env. C11-193's whole premise is
launching agents into worktrees and trees the operator did not necessarily author.
There is no first-use confirmation, no "this project wants to run X, allow?", no
display of the resolved command, and no allowlist. The plan does not mention trust
once. At minimum this needs a stated decision and probably a changelog note; at most
it needs a confirmation gate. The A-button path already has this exposure, so it is
not net-new as a class, but this change extends it to the rail that is explicitly
designed to point at other people's trees.

**3. No observability for which config won.**
There is no way, from a launch response or from any CLI, to see whether a project
config was found and from which path. `c11 default-agent` exposes no read-only
`get`/`current` (noted in prior investigation of this same subsystem). Every future
"why did it launch codex" report will require a maintainer to reason about a 64-level
walk from a path the operator cannot see. A `config_source` / `project_config_path`
field in the `agent.launch` JSON payload, and in the `warnings` stream when a project
config overrides the user default, would make this class of bug self-diagnosing
forever. This is the highest-leverage thing missing from the plan and it costs
roughly ten lines.

**4. Cross-workspace targeting mixes provenance.**
On the branch, `workspaceRoot` comes from the *target* workspace
(`v2ResolveWorkspace`) while `launchingSurfaceCwd` comes from `callerWorkspace ??
fallbackWorkspace`. A background caller in workspace A launching into workspace B
with no roots set resolves to A's surface cwd, then creates the surface in B's pane
with `workingDirectory: <A's cwd>`. The plan's step-2 invariant ("configuration
lookup and the child cwd cannot diverge") holds trivially, but the *combined* value
is a cross-workspace hybrid that nobody chose. No test is proposed for cross-workspace
targeting.

**5. Threading, in a repo that just shipped a main-thread deadlock fix.**
v1 `default_agent` is not in `socketWorkerV1Commands`/`socketWorkerV2Methods`, so
`defaultAgentLaunch` runs on the main actor. If "shared helper reuse" means calling
C11-194's resolution path there, that path (per C11-193's design) does a
`GitContextResolver` probe, which is subprocess/filesystem git I/O. Putting that on
the main thread violates this repo's own socket threading policy and is precisely
the shape of C11-200 / the `ghostty_surface_set_display_id` deadlock just fixed in
`8c7422b4f`. The plan says nothing about threading. C11-193's plan has a dedicated
step for it (step 6); this one inherits the requirement and drops it.

**6. No docs, no changelog, no skill sync.**
C11-193 (step 9) and C11-194 (step 5) both carry doc and skill-sync steps.
C11-195 has none, yet `docs/launch-agent-reference.md` and
`skills/c11/references/api.md` are already in PR #407's file list and both describe
launch cwd/config semantics. This repo's CLAUDE.md carries a **hard rule**: editing
an installable skill is incomplete until `scripts/sync-installed-skills.sh` runs. If
this change alters what the documented `.c11/agents.json` behavior actually is (it
does: from "documented but inert on this rail" to "live"), the docs need a line and
the skill needs a sync. Also no CHANGELOG entry for a user-visible behavior change.

**7. No negative controls in the validation.**
Step 4 validates the positive case only. Missing: a workspace with no project config
still uses the user default; a malformed `.c11/agents.json` still falls back
silently; a `.c11/agents.json` that omits `defaultAgent` does not displace the
Settings pick (the `overrideDefaultAgent` invariant from PR #217, which this change
puts back under load for the first time); `$HOME/.c11/agents.json` does or does not
apply (whichever you decide).

**8. Path normalization in the scratch test.**
`find(from:)` uses `standardizedFileURL`, which does not resolve symlinks. macOS
`/tmp` is a symlink to `/private/tmp`. If C11-194's resolver normalizes with
`resolvingSymlinksInPath` anywhere (or if the surface reports a realpath'd cwd while
the test seeds a `/tmp` path), a scratch-backed assertion can pass or fail for
reasons unrelated to the fix. Worth one sentence in the plan; worth more if the test
turns flaky in CI and someone spends an afternoon on it.

**9. Rollback.** There is no kill switch. If a fleet of operators suddenly gets a
different agent on every launch because of a stale home-directory file, the only
remedy is a new release. An env var or a settings toggle is probably overkill; a
warning line naming the file that won is not.

---

### Challenged Decisions

| Decision | Counterargument |
| --- | --- |
| Keep the process-cwd fallback | It is the mechanism that hid the bug, it makes behavior machine-dependent, and `find(from:)` already handles nil. Pass nil. The plan's phrasing ("only when no ... path exists at all") is a default, not a choice. |
| Non-goal: "A-button/default-agent entry point beyond shared helper reuse" | The ticket text explicitly names `defaultAgentLaunch` in `TerminalController.swift:9074` as the second site of the bug. The non-goal appears to exclude the ticket's own stated scope. Either the non-goal is wrong or the ticket is half-fixed. This must be resolved before implementation, not discovered in review. |
| Depend on C11-194 rather than fixing the lookup standalone | The standalone fix (`lookupCwd = cwdOverride ?? nil`, delete the process-cwd fallback) is one line, has no dependency, is independently reviewable, and removes the wrong behavior immediately. The C11-194 dependency buys *better* behavior (workspace-root and surface-cwd inheritance) at the cost of coupling a small correctness fix to a reset, in-flight, policy-churning ticket on a shared branch. Consider landing the safe deletion first, then the enrichment. |
| Only 2 of 5 call sites in scope | Leaves c11 with two competing definitions of launch cwd. `GhosttyTerminalView.swift:3557` is the one agents actually read (`C11_DEFAULT_AGENT_LAUNCH`) and it falls back to the **home directory**, which is the worst possible start for a 64-level upward walk. If the walk is not scoped, that site is a latent version of the same bug with a *more* dangerous fallback than the one being fixed. |
| One "logic test" as the whole automated gate | The behavior needing protection is wiring, not logic. Protect it with an assertion on the handler's chosen lookup path (extract `agentLaunchProjectConfigLookupPath(resolution:) -> String?` as a pure function and test that), plus an assertion that the same value reaches surface creation. |
| Validation via tagged app only | Fine as a smoke gate, but the stated oracle ("uses the project-level agent configuration") is unobservable today. Name the observable: seed the scratch project's config with a visually distinct `command` (e.g. `echo C11-195-PROJECT-CONFIG`) and screenshot the pane. Otherwise "validated" means "the agent launched," which was already true. |

---

### Hindsight Preview

Two years from now, the likely retrospective lines:

- *"We shipped it and then spent a week on tickets where the A button and
  `launch-agent` picked different agents in the same workspace."* Because the plan
  fixed two of five call sites and left `resolverCwdForAgentLaunch()` unaware of
  workspace roots.
- *"Somebody's stale `~/.c11/agents.json` pinned their whole machine again."*
  Because we fixed the decoder in PR #217 and never fixed the walk. The second
  occurrence will be harder to diagnose than the first, since the first one had a
  single obvious symptom (A button always Claude) and this one will be intermittent
  across rails.
- *"Why didn't we just print which config file won?"* Ten lines that would have
  eliminated the entire diagnostic class.
- *"We closed C11-195 with a zero-line diff."* Because the branch already did steps
  1 and 2 and the non-goal excluded step 3.

**Early warning signs the plan has no mechanism to detect:**
- The implementer opens the branch, finds `lookupCwd = cwdResolution.path ?? ...`
  already present, and reports the ticket complete. Nothing in the plan requires a
  before/after demonstration.
- The added test passes on a clean checkout *and* on a revert of the fix. There is
  no requirement to show the test fails without the change. For a wiring fix this is
  the single most important gate and it is absent.
- CI stays green because none of the affected rails are exercised end to end.

---

### Reality Stress Test

**Disruption 1: C11-194 changes shape again.**
It has already been completed and reset once today, and C11-193's policy flipped
from refuse to warn under it. If the resolver's return type gains provenance
plumbing or the workspace-root snapshot moves, C11-195's two-line consumption is
trivially re-pointable, but its *test* (if written against the resolver rather than
a lookup seam) rots and gets deleted rather than repaired. Mitigation: write the
test against a lookup-path helper that has its own signature.

**Disruption 2: PR #407 gets split or force-rebased.**
Three tickets, one branch, an open PR with `mergeable: UNKNOWN`, and a repo where
"CONFLICTING PR gets no CI" is a known trap. If the PR is split per ticket to get
independent review, C11-195's delta is the one most likely to be dropped in the
split because it is the smallest and lives in the middle of the other two's hunks.
If it is force-rebased, the same. Mitigation: make C11-195's diff self-identifying
(a comment referencing the ticket at each changed call site) and include the lookup
helper as a named symbol so its absence is a compile error, not a silent revert.

**Disruption 3: An operator with a home-directory `.c11/agents.json` upgrades.**
Every CLI-launched agent on their machine changes harness and env overnight. They
report "c11 launches the wrong agent since the update." Because there is no
observability of which config won, and because the change shipped with no changelog
line, triage starts from zero. Combined with Disruption 2 (the change landed inside
a 634-line PR titled "Make agent launch cwd worktree-safe"), nobody connects the
symptom to the cause quickly. This is the scenario that turns a 2-line fix into a
multi-day incident, and it is entirely preventable with a warning line and a walk
boundary.

**All three at once:** the resolver reshapes, the PR splits, the ticket's change
survives only in the half of the split that also carries the policy flip, and the
home-directory regression ships without a changelog. The plan has no artifact that
would survive that sequence intact.

---

### The Uncomfortable Truths

1. **This plan may already be satisfied by code that exists, and it does not know
   that.** A plan written against the branch it depends on should have said "the
   socket path is already done on `origin/fix/C11-193-launch-agent-cwd`; the
   remaining delta is X." That it does not suggests the plan was written from the
   ticket text rather than from the branch. That is a process smell worth naming
   because the same three-ticket pack will keep producing it.

2. **The non-goal contradicts the ticket.** The ticket names
   `TerminalController.swift:9074` as an instance of the bug. The non-goal excludes
   "the A-button/default-agent entry point." A reader cannot tell whether
   `default_agent launch` is in scope. That ambiguity will be resolved by whoever
   implements it, in the direction of less work.

3. **"Fix the lookup" is a feature flag flip dressed as a bug fix,** and it is being
   shipped with none of the ceremony a flag flip gets: no blast-radius analysis, no
   changelog, no rollout note, no observability, no rollback.

4. **The riskiest thing about `.c11/agents.json` is that it executes.** Nobody has
   written down whether c11 trusts repository-supplied launch commands. This ticket
   is the moment that question becomes load-bearing on the rail explicitly designed
   to point at other agents' worktrees, and the plan is silent.

5. **Step 5 is not a step.** "Record review and runtime evidence and link PR #407"
   is bookkeeping. Of five numbered items, two (4 and 5) are process and one (1) is
   already done upstream. The actual engineering content of this plan is one and a
   half lines of Swift plus a test that cannot currently be written.

---

### Hard Questions for the Plan Author

1. Have you read `origin/fix/C11-193-launch-agent-cwd`? `SocketDispatch.swift`
   already has `lookupCwd = cwdResolution.path ?? FileManager.default.currentDirectoryPath`
   and already passes `cwdResolution.path` to `addWorkspace` and `newTerminalSurface`.
   **What is the remaining diff for this ticket, in lines?** If the answer is "zero
   for the socket path," say so in the plan and re-scope.

2. **Is `TerminalController.defaultAgentLaunch` (line 9074) in scope or not?** The
   ticket names it; your non-goal appears to exclude it. Pick one, in writing. If it
   is out of scope, which ticket covers it and why is the ticket being closed with
   the bug still present at a site the ticket text cites?

3. **Why keep the process-cwd fallback at all?** `find(from:)` handles nil. What
   correct behavior does the fallback produce that nil does not? If the answer is
   "none," delete it and say the plan deletes it.

4. **What stops the upward walk from reaching `~/.c11/agents.json`?** Nothing today.
   PR #217 exists because that exact file broke default-agent resolution on this
   machine. Do you scope the walk to the resolved path's git root, to `$HOME`, to
   the workspace root, or do you accept it? *Current answer appears to be "we don't
   know," and that is a problem: this is the change's largest blast radius.*

5. **What is the trust model for `.c11/agents.json`?** It carries `command` and
   `envOverridesText`. After this fix, `c11 launch-agent --cwd <cloned-repo>` will
   execute that repo's chosen shell command. Is that intended? Is it documented? Is
   there a confirmation, an allowlist, or at minimum a warning?

6. **How does an operator find out which config file was used?** If the answer is
   "read the source and simulate a 64-level walk," add a `project_config_path` to
   the `agent.launch` JSON payload and a warning line when a project config
   overrides the user default. Will you?

7. **For `--in-surface`, whose cwd should the project config come from: the caller's
   or the target surface's?** The child executes in the target's directory. The
   C11-194 resolver knows only the caller and the target workspace root. Feeding the
   resolver into that path creates the exact lookup/execution divergence step 2
   claims to eliminate. What is the answer?

8. **Which test target, and what seam?** `DefaultAgentConfigTests.swift` (the
   existing home for these) is in `c11Tests` (host-required). You say "logic test."
   And how do you inject "a different process fallback" without `chdir`? Name the
   pure function you will extract, or admit the test is a re-test of
   `find(from:)` and therefore worthless as a regression gate.

9. **Will you demonstrate the test fails without the fix?** For a wiring change this
   is the only meaningful gate. Add it as an explicit step.

10. **What is the observable in step 4?** "Uses the project-level agent
    configuration" is not checkable by looking at a pane. State the fixture (a
    project config with a visibly distinct command) and the artifact (screenshot,
    `read-screen` output, or `launch-agent --json` field).

11. **On which thread does the fix run for the v1 path?** `default_agent` is not in
    the socket-worker method sets, so it is main-actor. If "shared helper reuse"
    drags `GitContextResolver` or a main-thread snapshot in there, you are adding
    git subprocess I/O to the main thread days after this repo fixed a main-thread
    deadlock. What is your threading plan?

12. **What happens to the other three call sites?** `GhosttyTerminalView.swift:3557`
    exports `C11_DEFAULT_AGENT_LAUNCH` and falls back to the **home directory**,
    which is the most dangerous possible start for the walk. `Workspace.swift:12448`
    (`resolverCwdForAgentLaunch()`) ignores the new workspace root entirely. After
    C11-194 lands, the A button and `launch-agent` will resolve config from
    different places in the same workspace. Is that acceptable? If yes, why? If no,
    which ticket fixes it?

13. **What is the changelog entry and the docs delta?** C11-193 and C11-194 both
    have doc steps; this one has none, and `docs/launch-agent-reference.md` plus
    `skills/c11/references/api.md` are already touched by PR #407. Also: this repo
    treats "edited an installable skill without running
    `scripts/sync-installed-skills.sh`" as a hard-rule violation. Where is that step?

14. **What is the rollback if a fleet of operators gets the wrong agent?** Currently:
    ship a new release. Is that acceptable, or does the warning-line answer to
    question 6 suffice as mitigation?

15. **Given C11-194 was reset today and C11-193's policy flipped from refuse to warn
    under it, on what evidence do you claim C11-194 "must land first"?** There is one
    branch and one PR. What observable event constitutes "landed," and what do you do
    if C11-194's resolver signature changes after you consume it?
