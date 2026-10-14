# Evolutionary Plan Review: c11-193-plan (Claude)

**Plan:** `.lattice/plans/task_01KZAV2VHK2TPFPXE8C7S1YNQ8.md` (C11-193)
**Ticket:** launch-agent: refuse to start an agent in another agent's linked worktree
**Sibling:** C11-194 (`task_01KZAV3DFHX3WHKJG4F5075C66`), workspace root directory + launch-agent cwd default
**Reviewer model:** Claude
**Written:** 2026-08-06

---

## Executive Summary

The ticket is excellent. The plan is not yet executable.

C11-193's description is one of the better tickets in this repo: a real incident, a verified one-line detection method, a crisp argument for why a guard beats a default, and an explicit statement of the invariant the fleet actually depends on ("no two agents mutate the same tree"). The plan that came out of it is five bullets that compress all of that into abstractions, and in doing so it (a) asserts a seam that does not exist in the shape it describes, (b) discards the cheaper detection signal the ticket handed it, (c) omits the doc/skill sync that CLAUDE.md makes a hard rule for any CLI or socket change, and (d) does not name its ordering dependency on the sibling ticket that is assigned to the same actor and is in progress right now.

The biggest opportunity is not in fixing those gaps, though they must be fixed. It is in noticing what this ticket is a first instance of. c11 has no model of *which agent owns which tree*. This guard is the first territorial invariant in the fleet. If the implementation stamps the tree and branch as surface metadata on the way past, rather than merely consulting them and throwing them away, the same effort produces a fleet map instead of a tripwire, and the map is what unlocks auto-worktree provisioning, collision telemetry, and a materially better `c11 tree`. That is a small delta in the diff and a large delta in what exists afterward.

There is also a strictly better guard hiding in plain sight. "Is this cwd a linked worktree?" is a proxy. The precise rule the ticket actually wants is "is another live c11 surface already rooted in this tree?" c11 already knows every live surface. Using that data eliminates the false-positive class (an operator legitimately working alone inside a worktree gets refused today under the proposed rule) and makes the message dramatically more actionable: it can name the surface, not just the branch.

---

## What's Really Being Built

**Stated deliverable:** a refusal in `c11 launch-agent` when the inherited cwd is a linked git worktree.

**Actual capability:** the first assertion in c11 that *surfaces have territory*, and that territory can be contested.

Everything c11 knows about a surface today is presentational or identity-shaped: `terminal_type`, `model`, `task`, title, attention state. Nothing describes where the surface *stands* in a way another part of the system can reason about. The launch path resolves a working directory, hands it to a PTY, and forgets it. `c11 tree` cannot tell you that four of your surfaces are all sitting in the same dirty branch, because nothing ever recorded that they were.

This ticket forces c11 to compute, for the first time, a fact of the form "this surface is standing in git tree T on branch B." The plan then throws that fact away after a single boolean comparison. That is the evolutionary miss. The comparison is the cheap part; the fact is the asset.

Second thing being built, quieter: **the precedent that c11 may refuse a launch on policy grounds.** Today every `agent.launch` error is a validation error (bad type, bad path, bad flag combination). This introduces the first *judgment* error, where the inputs are all well-formed and c11 declines anyway because it believes the operator is about to hurt themselves. That is a category with real weight for a tool whose whole posture is "unopinionated about the terminal" (CLAUDE.md). Worth being deliberate that this is the seam where opinion is allowed, and writing down why: it guards c11's own multi-agent invariant, not the tenant's tooling.

---

## How It Could Be Better

### 1. The seam the plan names does not carry the data the plan needs

Plan step 3: "Reject only inherited cwd resolution when it points at a linked worktree."

At the server, in `Sources/SocketHandlers/SocketDispatch.swift` (inside `v2AgentLaunch`, around line 1067), the code is:

```swift
var cwdOverride: String?
if let err = v2ResolveCwdParam(params, resolved: &cwdOverride) { ... }
let lookupCwd = cwdOverride ?? FileManager.default.currentDirectoryPath
```

`v2ResolveCwdParam` (`Sources/TerminalController.swift:2768`) documents its contract explicitly: no `cwd` param, or the literal `"inherit"`, yields `resolved = nil`, and "a nil working directory falls through to the existing inheritance chain (parent panel cwd → workspace cwd → $HOME)."

So in the inherited case, **the inherited directory is never materialized as a string at this seam.** There is nothing to probe. It is resolved later, downstream, at surface creation. An implementer handed this plan will reach the seam the plan points at, find `nil`, and have to invent the design on the spot.

This is the single most important gap. The plan must choose, and say which:

- **(a) CLI-side guard.** The `c11` CLI process runs *in the launching agent's actual shell cwd*. `FileManager.default.currentDirectoryPath` in `cli/c11.swift` is exactly the contested directory. Shelling out to `git rev-parse` there is free (short-lived process, no socket threading policy concern), the error reaches the launching agent's terminal immediately, and it composes naturally with the existing CLI-side rejections in the `launch-agent` case (mutually-exclusive flags, `--by` without `--flag`, unreadable `--prompt-file`). Downside: a direct socket caller bypasses it.
- **(b) Server-side guard.** Requires plumbing the parent panel's cwd up *before* the surface is created, which today happens after. Covers direct socket callers. Costs a subprocess in the app process on a path governed by the socket threading policy (parse/validate off-main), so the `git` invocation has to be off-main and bounded.
- **(c) Both.** CLI-side for the message quality and the fast path; server-side as the actual invariant.

My read: **(a) plus a documented note that the socket method is deliberately unguarded, or (c) if the invariant is meant seriously.** The reference doc says `launch-agent` is the primitive external controllers use, and names Sekhem Prime as first consumer, which shells out to the CLI. So (a) covers every real caller today. But the ticket's own framing ("a guard enforces the invariant the fleet actually depends on") argues for (c). Either is defensible; silence is not.

### 2. The plan discarded the cheaper detection signal the ticket supplied

The ticket says, in caps: "DETECTION IS ONE COMPARISON: a linked worktree has a `.git` FILE, not a directory." Then it also offers the `rev-parse --git-dir` vs `--git-common-dir` comparison.

The plan takes the subprocess comparison and drops the filesystem signal. That is backwards for a plan whose steps 4 and 5 promise **pure-logic tests on the `c11-logic` scheme**. A `git rev-parse` probe is a subprocess: it requires a git binary, a real repo fixture, and it is not pure logic. To be testable at all it must be split into a pure decision function over `(gitDir, gitCommonDir, branch)` plus a shell adapter, and the plan's step 2 ("add a testable linked-worktree probe") does not say that split exists.

The `.git`-is-a-file check needs no subprocess, needs no git binary, and is trivially testable against a temp-directory fixture. Its one real complexity is that `.git` is a file only at the worktree *root*, so a cwd inside a subdirectory needs a walk-up, and reading the branch name means parsing `.git/worktrees/<name>/HEAD`. Both are pure logic over a filesystem and both fixture cleanly.

Suggested restructure of step 2:

> Add `WorktreeProbe`, a pure walk-up over a directory path that returns `.mainCheckout`, `.linkedWorktree(root:, branch:, commonDir:)`, or `.notARepo`, reading only `.git` (file or directory) and `<commonDir>/worktrees/<name>/HEAD`. No subprocess. Tested in `c11LogicTests` against temp-directory fixtures that mimic both layouts.

If the team prefers `git rev-parse` for robustness against exotic layouts (submodules, `GIT_DIR` overrides, `.git` files that are not worktrees), that is a legitimate call: say so, and then be honest that step 4's tests are host-or-integration tests, not logic tests, and that step 5's "narrowed `c11-logic` slice" will not cover the probe.

### 3. The precise rule is available and better than the proxy

"Is this a linked worktree" is a proxy for "is another agent working here." It has a real false-positive class: an operator or a lone agent working inside a single worktree, launching a helper, gets refused for no reason. Under the plan's rule, `--cwd $PWD` becomes ritual noise in exactly the workflow the repo uses most (the lattice-orchestrator pattern puts *every delegator* in its own worktree, per CLAUDE.md).

c11 already knows every live surface. The precise rule is:

> Refuse when the resolved-inherited cwd resolves to a git tree that **another live surface is already rooted in**, and name that surface.

Message quality goes from:

> cwd is a linked git worktree on 'fix/ACE-791-whisper-tuning', this is likely another agent's active tree.

to:

> cwd is `…/acetate-worktrees/lyrics-accuracy` (branch `fix/ACE-791-whisper-tuning`), already held by `surface:341` (codex, task ACE-791). Pass `--cwd` explicitly to override.

That second message is actionable in a way the first is not: the launching agent can `c11 read-screen surface:341` and find out what is happening there. It also has no false positives, and it *extends to the main checkout*, which the proxy rule cannot: two agents both mutating the main checkout is the same bug and the plan's rule waves it through.

The cost is that it requires per-surface tree stamping, which is item 4 below and which you want anyway.

### 4. Stamp the tree, do not just consult it

Whichever detection method wins, the launch path will, for the first time, know the git tree and branch of a surface at birth. Record it: `git_root`, `git_branch`, `git_worktree_kind` as surface metadata alongside `terminal_type` / `model` / `task`, using the same identity-at-birth stamping already described in `docs/launch-agent-reference.md`.

The delta is small (the fact is already computed) and it is what everything downstream needs. See "The Flywheel."

### 5. Missing contract surface: error code, JSON shape, docs, skill

`docs/launch-agent-reference.md` carries a structured error table (`unknown_agent_type`, `invalid_params`, `not_found`, …) and a documented `--json` envelope. A new refusal needs:

- a new code, something like `cwd_contested_worktree`, distinct from `invalid_params` so callers can branch on it,
- a row in the error table,
- the `data` payload shape (branch, worktree root, and, under the item-3 rule, the holding surface ref),
- the explicit-override behavior documented (allowed, emits a one-line warning through the existing `warnings` array, which already exists for the binary-not-found case and is the perfect precedent).

That last point is worth calling out: **the plan does not need to invent a warning channel.** `launch-agent` already returns `"warnings": [...]`. The explicit-`--cwd`-into-a-worktree acknowledgement the ticket asks for is one more entry in that array. Plan step 3's phrase "surface one actionable acknowledgement" is ambiguous about whether that is an error or a warning; naming the existing array resolves it.

And per CLAUDE.md's hard rule: any CLI or socket change is incomplete until `skills/c11/SKILL.md` is updated *and* `scripts/sync-installed-skills.sh` is run. This plan is exactly the kind of change where a stale skill hurts most: it introduces a **new way for an agent's launch to fail**, and an agent that has not read about it will thrash against a refusal it does not understand. The sibling C11-194 plan remembers this ("update the c11 skill contract for any CLI/socket changes… sync installed skills if edited"); C11-193 does not. Same author, same seam, and the one that omits it is the one that needs it more.

### 6. Test-target reality the plan glosses

There is no `c11LogicTests/` directory on disk. Logic tests live in `c11Tests/` and are members of the `c11LogicTests` target (see `CwdParamResolutionTests.swift`, `DefaultAgentLaunchCompositionTests.swift`, both in `c11Tests/`, both wired into the logic target in `project.pbxproj`). So step 4 implies a pbxproj edit, and this repo has two recorded landmines there:

- CLAUDE.md pitfall: pbxproj edits via the `xcodeproj` Ruby gem normalize formatting and produce multi-thousand-line diffs from small semantic edits. Reviewers should be told to expect it and gate on `xcodebuild -list` plus file-membership counts.
- C11-105: a test file that lived in `c11Tests/` but was a member of `c11LogicTests` unlinked the production c11 socket on every local test run. Target membership here is not a formality.

The plan should either name the file it is adding and its target, or say it is extending `CwdParamResolutionTests.swift` in place (which needs no pbxproj change at all, and is the cheaper path).

### 7. Ordering collision with C11-194 is unnamed

Both tickets are `in_progress`, both assigned to `agent:codex-c11-launch-cwd`, and both modify launch-agent cwd resolution. C11-194 step 4 says "Centralize and test cwd precedence: explicit `--cwd`, workspace root, then launching-surface cwd." C11-193 adds a guard to that same resolution.

If 193 lands first against the un-centralized seam, 194 moves it. If 194 lands first, 193 gets a clean, already-tested, already-centralized precedence function to hook into, and 193's diff shrinks to the probe plus one branch. **194 first is clearly cheaper**, and 194's centralization is also what makes the inherited cwd available as a value at a single point, which is precisely what 193 discovered it was missing (item 1).

Neither plan says this. It should be stated in one of them.

### 8. Adjacent latent bug found while reading

`let lookupCwd = cwdOverride ?? FileManager.default.currentDirectoryPath` (SocketDispatch, `v2AgentLaunch`) uses the **c11 app process's** cwd to find `.c11/agents.json` via `DefaultAgentProjectConfig.find(from:)` when no explicit `--cwd` is given. The app process cwd is essentially arbitrary (`/` or wherever Finder launched it), so project-level agent configuration is silently not applied on the default path. The same pattern appears in `defaultAgentLaunch` (`Sources/TerminalController.swift`, around line 9075).

Out of scope for 193, but it is the same root cause (the launching surface's cwd is not plumbed to the server) and 194's centralization is the natural place to fix it. Worth filing as a third sibling rather than letting it be rediscovered.

---

## Mutations and Wild Ideas

**Mutation 1: the guard as a census first, an enforcer second.** Ship the detection and the metadata stamping with the refusal *disabled*, emitting only a warning plus a counter, for one week of real fleet use. `AgentLaunchStatsStore` already exists in this codebase (the launch-stats rail is wired at four sites). You would learn, with numbers, how often the guard would fire, and how often it would have fired on a *legitimate* solo-worktree launch. That data settles the proxy-versus-precise-rule debate (item 3) empirically instead of by argument. Cost: one extra ship. Benefit: you find out whether the false-positive class is 2% or 60% before you make it a refusal, and the operator running the lattice-orchestrator fleet is the one who eats it if it is 60%.

**Mutation 2: `--worktree new`.** The ticket's own reasoning contains the destination without naming it. C11-194 observes that "the project root is where `git worktree add` is RUN FROM, so a child that needs its own tree is already standing in the right place." Every delegator in the lattice-orchestrator workflow does the same three steps by hand: `git worktree add`, provision submodules and the GhosttyKit symlink (CLAUDE.md documents this as a known first-build trap), then launch the agent there. That is a launch flag:

```
c11 launch-agent --type codex --worktree new --branch feat/C11-201 --new-workspace
```

which creates the worktree from the workspace root, runs the repo's provisioning hook if one is declared, and launches with cwd set to the fresh tree. The guard then becomes almost vestigial: the reason agents land in each other's trees is that getting their own is manual. This is the version of the ticket that removes the failure mode instead of detecting it, and 193's probe plus 194's workspace root are exactly the two prerequisites.

**Mutation 3: territory as a general socket concept.** Generalize "surface is rooted in tree T" to "surface holds resource R," where R is a git tree today and could later be a port, a database, a device, a simulator. `c11 tree --json` already exists as the fleet snapshot; a `holds` field on each surface, plus a `c11 who-holds <resource>` query, turns collision detection into a lookup. Speculative, but the shape of the problem ("N agents, shared mutable resources, silent collisions, damage attributed to the wrong agent") is not going to stay confined to git worktrees, and this repo is where that gets solved first because it is where the fleet lives.

**Mutation 4: dirty-tree severity.** The incident description is careful to note the parent's tree had *uncommitted changes*. A clean worktree is a much cheaper collision than a dirty one. Grading the response (refuse on dirty, warn on clean) is more precise than a flat refusal, and `git status --porcelain` is one more subprocess if you have already paid for one. I would not ship this in v1 (it multiplies the states to test), but it is the natural v2 and it argues for the probe returning a struct rather than a boolean.

**Mutation 5: the guard is a tripwire, not an invariant, and should say so.** The ticket claims "a guard enforces the invariant the fleet actually depends on." It does not, quite. An agent can `cd` into a sibling worktree one second after launch, and nothing notices. Launch-time checking covers the common accidental path, which is genuinely most of the value, but the honest framing is "tripwire on the dominant failure path." If you want the invariant, it lives in periodic reconciliation over surface cwds (c11 can poll a surface's cwd; the shell integration already knows it), which is a different and larger ticket. Worth writing the honest framing into the plan so nobody later believes they are protected when they are not.

---

## What It Unlocks

Once tree and branch are known at launch and (per suggestion 4) stamped:

- **`c11 tree` becomes a fleet map.** Branch per surface in the sidebar and in `--json`. For an operator running eight to thirty agents, "which branch is each one on" is currently unanswerable without asking each agent. This is the highest-value byproduct and it is nearly free.
- **Collision telemetry.** How often do agents converge on a tree? Which workflows cause it? That question cannot be asked today.
- **Auto-worktree provisioning** (mutation 2) has its prerequisite.
- **Attribution.** The incident's worst property was that damage would be "attributed to the wrong agent." With per-surface tree stamps, the reverse lookup exists: given a tree, which surfaces have ever been rooted in it.
- **A precedent for policy refusals** with a documented error code, so the next one (port collision, duplicate task id, two agents on one Lattice ticket) has a pattern to copy rather than inventing a fifth error taxonomy.
- **The lattice-orchestrator skill gets a hard guarantee to lean on.** Its per-delegator-worktree discipline is currently convention enforced by prose. This makes part of it mechanical.

---

## Sequencing and Compounding

The plan's own five steps are internally ordered fine. The problem is the ordering *across* tickets and the ordering of what to learn first.

Recommended sequence:

1. **C11-194 first** (workspace root plus centralized cwd precedence). It creates the single point where the resolved cwd exists as a value, which is the thing 193 needs and currently lacks. It also independently reduces the incidence of the bug 193 guards against. Fix the app-process-cwd config-lookup bug (item 8) inside that centralization while you are there.
2. **193a: probe plus stamp, warn-only.** Pure `WorktreeProbe`, surface metadata stamping, warning through the existing `warnings` array, counter through `AgentLaunchStatsStore`. Ships the asset and the observation with near-zero blast radius. Docs and skill updated to describe the warning.
3. **193b: refusal, informed by 2's data.** Flip warn to refuse for the inherited case. By now you know whether the proxy rule or the precise "another live surface holds this tree" rule is right, because you have counted the false positives. Error code, docs table, skill card.
4. **`c11 tree` surfaces branch/worktree** (small, and 193a already produced the data).
5. **`--worktree new`** (mutation 2), which is where the real ergonomic win lives.

Each step's output is the next step's input rather than its rework. Note especially that steps 2 and 3 are the same diff split at a boolean; the split costs almost nothing and buys the decision in item 3.

Where the current plan under-invests early: it treats the git fact as transient. Where it over-invests: it commits to a refusal semantics before anyone has measured how often it fires.

---

## The Flywheel

There is a real one available, and the plan as written does not spin it.

```
launch stamps tree + branch on the surface
        ↓
c11 tree / sidebar shows branch per agent
        ↓
operator SEES the fleet's territory for the first time
        ↓
collisions and near-misses become visible and countable
        ↓
guard gains precision (real surfaces, not proxies) and credibility (data, not one incident)
        ↓
"give this agent its own tree" becomes the obvious next primitive
        ↓
--worktree new removes the manual step that CAUSES the collisions
        ↓
more agents launched per operator-minute, more surfaces, more territory to track
        ↓  (back to the top, with more data)
```

The engine is the stamp. Without it, the loop never starts: a guard that consults and forgets produces no visibility, no counts, and no argument for the next step. With it, every single launch feeds the map, and the map is what makes the next four tickets obvious and cheap.

The small change that engineers the flywheel: **make step 2's probe return a value that gets persisted to surface metadata, not a boolean that gets discarded.** One extra field on the return type, one extra call to the metadata stamping that the launch path already performs.

---

## Concrete Suggestions

A rewritten plan. Same scope discipline, executable.

```
# C11-193 plan

DEPENDS ON: C11-194 lands first (it centralizes cwd precedence; this guard hooks
that single point). If 193 must go first, it creates the centralized resolver and
194 extends it.

1. Add `WorktreeProbe` (Sources/, pure, no subprocess): walk up from a directory
   to the nearest `.git` entry; return .notARepo | .mainCheckout(root:) |
   .linkedWorktree(root:, commonDir:, branch:). Reads `.git` (file or dir) and
   `<commonDir>/worktrees/<name>/HEAD`. Tested in the c11LogicTests target
   (file lives in c11Tests/ on disk, extend CwdParamResolutionTests.swift or add
   WorktreeProbeTests.swift and wire target membership deliberately) against
   temp-dir fixtures for both layouts, plus non-repo and nested-subdir cases.

2. Guard CLI-side in cli/c11.swift's `launch-agent` case, where the process cwd
   IS the launching agent's shell cwd, before the agent.launch call:
     - no --cwd + probe says .linkedWorktree  -> refuse, exit non-zero,
       error code `cwd_contested_worktree`, message names branch + worktree root
       + the --cwd override.
     - explicit --cwd + probe says .linkedWorktree -> proceed, emit one warning
       line (--json: append to the existing "warnings" array).
     - all other cases -> unchanged.
   Server-side agent.launch is deliberately NOT guarded in v1; note that in the
   reference doc (all current callers go through the CLI). Revisit if a direct
   socket caller appears.

3. Stamp `git_root` / `git_branch` / `git_worktree_kind` into the new surface's
   metadata at birth via the existing identity-at-birth stamping, so the fact the
   guard computed becomes queryable rather than discarded.

4. Docs + skill (HARD RULE): add `cwd_contested_worktree` to the error table in
   docs/launch-agent-reference.md with its data payload; document the explicit-
   --cwd warning; update skills/c11/SKILL.md so agents know the refusal exists
   and how to override; run scripts/sync-installed-skills.sh c11.

5. Behavioral tests: probe cases (step 1) in c11-logic; CLI-level refusal /
   allow / message-content cases at whatever seam the launch-agent arg parsing
   is testable from. Run the narrowed c11-logic slice, then the proportionate
   broader safe logic gate.

Non-goals: blocking explicit worktree helpers, mutating tenant git state,
changing launch focus behavior, guarding post-launch `cd`, guarding the raw
socket method.
```

Additional concrete items, each independently valuable:

- **Warn-only first release.** Split step 2 into 2a (warn + count) and 2b (refuse). One week of fleet data before the refusal.
- **File the app-process-cwd config bug** (item 8) as its own ticket so it does not vanish.
- **State the tripwire framing** in the non-goals: this covers accidental launch-time landing, not post-launch `cd`. Prevents a future reader from over-trusting it.
- **Decide the override surface.** `--cwd $PWD` works but reads as a workaround. Consider `--allow-worktree` as an explicit intent flag, or decide deliberately that `--cwd` is the only override and say so.
- **Reviewer note for the PR:** if a pbxproj edit is involved, gate on `xcodebuild -list` plus file-membership counts, not line-by-line diff review, per CLAUDE.md.

---

## Questions for the Plan Author

1. **Where does the guard live: CLI, server, or both?** The plan's stated seam (`v2ResolveCwdParam` / `v2AgentLaunch`) does not have the inherited cwd as a value; it is `nil` there by contract, resolved downstream at surface creation. This has to be answered before an implementer can start.

2. **Probe by filesystem or by `git rev-parse`?** The filesystem check is pure and testable on the `c11-logic` scheme that steps 4 and 5 promise. The subprocess is more robust against exotic layouts but makes the tests host-or-integration. Which do you want, and if the subprocess wins, do you accept that step 5's logic slice will not cover the probe?

3. **Proxy rule or precise rule?** "Any linked worktree" refuses an operator legitimately working solo inside a worktree, which is the dominant pattern in this repo's own lattice-orchestrator workflow. "A tree another live surface already holds" has no false positives, names the offending surface in the message, and extends to main-checkout collisions. Is the extra plumbing worth it, or worth deferring to a v2?

4. **Should the fact be persisted?** Stamping `git_root` / `git_branch` on the surface is a small delta over computing it, and it is the input to `c11 tree` visibility, collision telemetry, the precise rule in Q3, and auto-worktree. Is there a reason not to?

5. **Which ticket lands first, 193 or 194?** Both are `in_progress`, both assigned to `agent:codex-c11-launch-cwd`, both touch launch-agent cwd resolution. 194's centralization is what gives 193 the value it needs. Sequencing this explicitly avoids a self-inflicted merge conflict.

6. **Refuse immediately, or warn-and-count for one release?** You have the launch-stats rail already. A week of data would settle Q3 empirically. Is the incident urgent enough to skip that, or is warn-first acceptable?

7. **Error code name and payload?** `cwd_contested_worktree`? What rides in `data` (branch, root, holding surface ref)? The reference doc's error table needs the row either way.

8. **Is `--cwd $PWD` the intended override, or do you want an explicit `--allow-worktree`?** The former overloads a path flag with a policy meaning; the latter is one more flag but reads as intent.

9. **Does the skill get updated in this ticket?** CLAUDE.md makes it a hard rule for CLI/socket changes, and the sibling plan includes it. Omitting it here means agents hit a novel refusal with no documentation, which is exactly the thrash case.

10. **Is `--worktree new` (auto-provision a tree and launch into it) on the roadmap?** If yes, 193 and 194 are both prerequisites and should be scoped with that destination in view. If no, say so, because it changes how much structure is worth building into the probe now.

11. **Do you want to fix the app-process-cwd project-config lookup** (`lookupCwd = cwdOverride ?? FileManager.default.currentDirectoryPath`) as part of this work, as part of 194, or as a separate ticket? It is a real silent bug on the same seam.
