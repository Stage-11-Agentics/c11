# Trident Evolutionary Synthesis: C11-193

**Ticket:** launch-agent: refuse to start an agent in another agent's linked worktree
**Plan:** `.lattice/plans/task_01KZAV2VHK2TPFPXE8C7S1YNQ8.md`
**Sibling:** C11-194 (`task_01KZAV3DFHX3WHKJG4F5075C66`), workspace root + launch-agent cwd default
**Sources:** `evolutionary-claude.md`, `evolutionary-codex.md`, `evolutionary-gemini.md`
**Synthesized:** 2026-08-06

---

## Executive Summary

All three reviewers converge on one verdict and one insight.

**The verdict:** the ticket is good, the plan is not yet executable. Every model independently found that the plan's five bullets defer the actual design decisions to the implementer. Claude and Codex both identified the same architectural hole from different angles: the plan names a seam (`v2ResolveCwdParam` / `v2AgentLaunch`) where the inherited cwd does not exist as a value, so an implementer arrives at the named location, finds `nil`, and has to invent the design on the spot. Codex adds the threading dimension: `agent.launch` is absent from `socketWorkerV2Methods`, so its handler runs on the main actor, and firing git subprocesses there violates this repo's socket-threading and typing-latency rules.

**The insight, stated three ways:** the probe computes a fact the plan then throws away. Claude calls it "stamp the tree, do not just consult it." Codex calls it "preserve `cwd_origin` through the whole launch path." Gemini calls it "you do the work to find the git-dir, don't throw it away." Three models, three vocabularies, one recommendation: the boolean comparison is the cheap part, the *fact* is the asset. Persisting it turns a tripwire into a fleet map, and the map is what makes the next four tickets obvious and cheap.

**One factual conflict, now resolved.** Claude proposed building a new pure-filesystem `WorktreeProbe` (no subprocess, testable on `c11-logic`). Codex pointed out that `Sources/Metadata/GitContextResolver.swift` already does exactly this classification. Verification during synthesis confirms Codex: the file exists (32 KB, 2026-07-06), declares `public protocol GitRunner: Sendable` with an explicit off-main precondition ("Implementations MUST trap main-thread invocation"), compares `rev-parse --git-common-dir` against `--git-dir` at line 336-340, classifies `mainCheckout(branch:)` versus `linkedWorktree(basename:absolutePath:branch:)` with a `BranchValue` that already models the branch states, and ships three test files including `GitContextResolverTests.swift` and `ProcessGitRunnerTimeoutTests.swift`. **Codex is right and this materially changes the plan.** Step 2 as written would create a second, drifting definition of "linked worktree." The injectable `GitRunner` also dissolves Claude's testability objection: a fake runner gives pure-logic tests without a subprocess, so the plan gets both single-source semantics and a `c11-logic` test slice.

**The strategic frame:** this is c11's first *policy* refusal, where every input is well-formed and c11 declines anyway. That is a real posture decision for a tool whose CLAUDE.md says "unopinionated about the terminal." It deserves to be named and justified in the plan, not stumbled into.

---

## 1. Consensus Direction

Evolution paths that two or three models identified independently.

1. **Preserve the git fact instead of discarding it (3/3, unanimous).** Claude: stamp `git_root` / `git_branch` / `git_worktree_kind` as surface metadata at birth. Codex: return `cwd` and `cwd_origin` in the success payload so launch placement becomes evidence rather than inference. Gemini: enrich the probe to a structured `GitContext` and inject it into the agent's initialization payload. The delta over the plan as written is one field on a return type plus one call to stamping the launch path already performs.

2. **Model cwd *provenance*, not just cwd (2/3, Codex leading, Claude implicit).** The same path must be allowed when the caller named it and refused when c11 inherited it, so `String?` is the wrong type. Codex's proposed `ResolvedAgentLaunchCwd { path, origin: .explicitCLI | .workspaceRoot | .inheritedSurface | .processFallback }` makes the guard a lookup on an enum rather than a chain of ad hoc conditionals, and it is the type C11-194 wants anyway.

3. **The linked-worktree test is a proxy, and the precise rule is ownership (2/3, Claude and Codex).** Claude: refuse when another *live surface* is already rooted in the tree, which has no false positives, names the offending surface in the message, and extends to main-checkout collisions the proxy waves through. Codex: an ephemeral worktree *lease* over `{workspace, surface, task, branch, path}`, refusing "foreign active lease" rather than "any linked worktree." Both agree the heuristic deliberately produces false positives, and both agree the structured provenance from item 2 is the substrate for the precise version later.

4. **The false-positive class lands hardest on this repo's own workflow (2/3).** The lattice-orchestrator pattern puts *every delegator* in its own worktree per CLAUDE.md. Under the proposed rule, `--cwd $PWD` becomes ritual noise in the dominant local pattern: a lone agent working legitimately inside its own worktree gets refused for no reason.

5. **Sequence with C11-194, and say so in writing (3/3).** Both tickets are `in_progress`, both assigned to `agent:codex-c11-launch-cwd`, both modify launch-agent cwd resolution. Claude and Codex both conclude 194-first is cheaper because its centralization is what makes the inherited cwd exist as a value at a single point, which is exactly what 193 discovered it lacks. Gemini arrives from the semantics side: what happens when a C11-194 workspace root points *inside* a linked worktree? Neither plan currently states the ordering.

6. **A structured, stable error contract, not prose (2/3).** `docs/launch-agent-reference.md` carries an error table (`unknown_agent_type`, `invalid_params`, `not_found`) and a documented `--json` envelope. The refusal needs its own code (`cwd_contested_worktree` per Claude, `inherited_linked_worktree` per Codex), a table row, and a `data` payload. Codex: "callers should not have to parse prose."

7. **Docs and skill sync are load-bearing, and the plan omits them (2/3).** CLAUDE.md makes this a hard rule for any CLI or socket change: update `skills/c11/SKILL.md`, then run `scripts/sync-installed-skills.sh`. Claude's sharpest observation here: the sibling C11-194 plan remembers this and C11-193 does not, same author, same seam, and the one that omits it is the one that needs it more, because it introduces **a new way for an agent's launch to fail**. An agent that has not read about it will thrash against a refusal it does not understand.

8. **The error message should teach, not merely block (2/3).** Gemini and Claude both want the message to carry probe data and name the two likely intents with copy-pasteable commands. Claude's version additionally names the holding surface so the launching agent can `c11 read-screen surface:341` and find out what is actually happening there.

9. **Branch-state edge cases need explicit answers (2/3).** Detached HEAD, no resolvable branch, and submodule-of-a-linked-superproject all need stated behavior. `GitContextResolver`'s existing `BranchValue` already models attached/detached/no-branch, so this is a matter of deciding display and policy, not building machinery.

---

## 2. Best Concrete Suggestions

Ranked by leverage per unit of diff.

1. **Reuse `GitContextResolver`; do not write a second probe.** (Codex, verified.) It already has the `--git-common-dir` versus `--git-dir` comparison with absolute normalization, `mainCheckout` versus `linkedWorktree` classification, `BranchValue` for attached/detached/no-branch, a bounded `ProcessGitRunner` with a timeout test, and behavioral fake-runner tests. Rewrite plan step 2 as "reuse or extract the minimal shared classifier; add launch policy, not Git semantics."

2. **Inject a fake `GitRunner` for the decision tests.** This gets Claude's pure-logic testability *and* Codex's single-source semantics at the same time, dissolving the plan's step 4/5 tension without a filesystem-only reimplementation. The pure decision function is `(ResolvedAgentLaunchCwd, GitClassification) -> Allow | Reject(code, data)`, and it is trivially table-testable.

3. **Introduce `ResolvedAgentLaunchCwd { path, origin }` and thread it end to end.** (Codex.) It is the type C11-194 needs, the type the guard needs, the type the success payload should report, and the type a later lease layer consumes. If 193 lands first, it should define this type so 194 extends rather than rewrites it.

4. **Snapshot the checked path and create the surface from *that*.** (Codex, unique and important.) Sequence: snapshot target IDs and cwd on main, probe off-main, then create on main using the snapshotted path, failing `not_found` if the target vanished. Without this there is a genuine time-of-check/time-of-use hole: while git is being probed, the focused surface can `cd` or the target pane can change, and the directory launched is not the directory inspected.

5. **Resolve the *target's* cwd, not the CLI process cwd.** (Codex, and the sharpest correction to Claude's CLI-side proposal.) A launch aimed at another `--workspace` or `--pane` inherits from that target even though the CLI process is running elsewhere, so a CLI-side probe inspects the wrong checkout. Direct `agent.launch` socket callers also bypass a CLI-only guard. Claude's counterargument stands only for the local-launch case, and Claude concedes option (c), both, if the invariant is meant seriously.

6. **Stamp `git_root` / `git_branch` / `git_worktree_kind` on the surface at birth.** (Claude, echoed by Gemini's context injection.) Uses the identity-at-birth stamping already described in `docs/launch-agent-reference.md`. This is the flywheel engine (section 4) and the cheapest high-value item on the list.

7. **Ship warn-only first, refuse second.** (Claude.) `AgentLaunchStatsStore` already exists and is wired at four sites. One week of real fleet data settles the proxy-versus-precise-rule debate empirically instead of by argument, and tells you whether the false-positive rate is 2% or 60% before you make it a refusal. Steps 2a and 2b are the same diff split at a boolean.

8. **Use the existing `warnings` array for the explicit-override acknowledgement.** (Claude.) `launch-agent` already returns `"warnings": [...]` (precedent: binary-not-found), so the plan does not need to invent a channel. This also resolves the plan's ambiguous phrase "surface one actionable acknowledgement," which currently does not say whether it means an error or a warning.

9. **Decide fail-open versus fail-closed on an indeterminate probe.** (Codex.) Missing git binary, timeout, permission failure, malformed output. Fail-open is probably the proportionate compatibility choice with a diagnostic, but silently treating an unclassifiable directory as "main checkout" would hide a real decision.

10. **Document the anti-auto-retry rule in the skill.** (Codex, subtle and high-value.) If the skill teaches agents to mechanically retry with `--cwd` on this error, the guard's entire intent boundary evaporates within one release. The skill must say: this refusal requires a decision, not an echo.

11. **Add resolved `cwd` and `cwd_origin` to the success payload.** (Codex.) Additive, compatible, and turns every launch into an auditable receipt. Orchestrators get immutable evidence of where a worker actually started, which makes mislaunch diagnosis a lookup instead of an investigation.

12. **Extend `CwdParamResolutionTests.swift` in place rather than adding a file.** (Claude.) There is no `c11LogicTests/` directory on disk; logic tests live in `c11Tests/` as members of the `c11LogicTests` target. A new file means a pbxproj edit, and this repo has two recorded landmines there: the `xcodeproj` gem's multi-thousand-line normalization diffs, and C11-105, where a test in `c11Tests/` that was a member of `c11LogicTests` unlinked the production c11 socket on every local run. Extending in place needs no pbxproj change at all.

13. **Write the honest framing into the non-goals.** (Claude.) This is a tripwire on the dominant accidental path, not an invariant. An agent can `cd` into a sibling worktree one second after launch and nothing notices. The real invariant lives in periodic reconciliation over surface cwds, which is a different and larger ticket. Say so, or a future reader will believe they are protected when they are not.

14. **File the adjacent latent bug found during review.** (Claude.) `let lookupCwd = cwdOverride ?? FileManager.default.currentDirectoryPath` in `v2AgentLaunch` uses the *c11 app process's* cwd to find `.c11/agents.json`, and the app process cwd is essentially arbitrary. Project-level agent configuration is therefore silently not applied on the default path. Same pattern near `Sources/TerminalController.swift:9075`. Out of scope for 193, same root cause, natural fix inside C11-194's centralization.

---

## 3. Wildest Mutations

Ordered roughly by ambition. Several are explicitly flagged by their authors as follow-ups rather than scope creep.

1. **`--worktree new` (Claude).** The most transformative idea in the pack, and the ticket's own reasoning contains it without naming it. Every delegator in the lattice-orchestrator workflow does the same three manual steps: `git worktree add`, provision submodules and the GhosttyKit symlink (a documented first-build trap in CLAUDE.md), then launch. Collapse it: `c11 launch-agent --type codex --worktree new --branch feat/C11-201 --new-workspace`. The guard becomes almost vestigial, because the reason agents land in each other's trees is that getting their own is manual. **This removes the failure mode instead of detecting it**, and 193's probe plus 194's workspace root are precisely its two prerequisites.

2. **Territory as a general socket concept (Claude).** Generalize "surface is rooted in tree T" to "surface holds resource R," where R is a git tree today and could be a port, a database, a device, or a simulator tomorrow. A `holds` field on each surface in `c11 tree --json`, plus a `c11 who-holds <resource>` query, turns collision detection into a lookup. The shape of the problem (N agents, shared mutable resources, silent collisions, damage attributed to the wrong agent) is not going to stay confined to git worktrees, and this repo is where it gets solved first because it is where the fleet lives.

3. **Worktree-scoped ephemeral agent state (Gemini).** When explicitly launching into a worktree, the agent shifts to worktree-scoped memory and session state, so deleting the worktree garbage-collects the task's agent state. The worktree becomes the definitive lifecycle boundary for a sub-agent. Highest conceptual ambition in the pack: it reframes the worktree from "a directory" to "the unit of agent existence."

4. **Lease-aware ownership (Codex).** An ephemeral lease over `{workspace, surface, task, branch, path}` so c11 refuses "foreign active lease" rather than "any linked worktree," while retaining the conservative heuristic when no ownership data exists. Converges with Claude's live-surface rule but is durable across restarts and expressible to external controllers.

5. **A general launch-policy pipeline (Codex).** Once cwd carries provenance, linked-worktree refusal becomes the *first* policy in a small pipeline. Others: stale or missing directories, remote/local mismatches, port collisions, duplicate task IDs, two agents on one Lattice ticket. Do not broaden this ticket, but choose names and types that do not hard-code the pipeline to Git forever.

6. **`launch-agent --dry-run` / `explain` (Codex).** Return target, effective cwd, provenance, resolved agent config, and policy decision without creating a surface. Lets orchestrators preflight an entire fleet, and gives policy changes a safe runtime-validation seam that creates no side effects.

7. **The guard as a census first, an enforcer second (Claude).** Ship detection and stamping with the refusal *disabled*, emitting only a warning plus a counter. Listed under mutations rather than suggestions because the real move is philosophical: it converts a policy argument into a measurement. Cost is one extra ship; benefit is that the operator running the fleet does not eat a 60% false-positive rate to find out it was 60%.

8. **Auto-redirect to the common dir instead of refusing (Gemini).** When invoked implicitly inside a worktree, silently resolve cwd to `--git-common-dir` with a warning. **The most contested idea in the pack:** it directly contradicts the ticket's refusal posture and Claude's and Codex's shared "never silently place an agent somewhere" property. Worth stating as a rejected alternative in the plan, because a future reader will propose it.

9. **Interactive TTY clarification (Gemini).** If the guard trips on an interactive terminal, prompt rather than refuse: launch here, or launch in the main checkout? Ergonomically appealing for humans, dangerous for agents, and it splits the CLI's behavior by TTY-ness, which is a new axis this codebase does not currently have.

10. **Dirty-tree severity grading (Claude).** The incident description carefully notes the parent's tree had uncommitted changes. A clean worktree is a much cheaper collision than a dirty one, so refuse on dirty and warn on clean. Author explicitly recommends *against* v1 (it multiplies the test states) while noting it argues for the probe returning a struct rather than a boolean, which the plan should do regardless.

---

## 4. Flywheel Opportunities

All three models found a flywheel. They are the same wheel described at three altitudes, and all three name the same engine.

**4.1 Claude: territory becomes visible, then automatic.**

```
launch stamps tree + branch on the surface
  -> c11 tree / sidebar shows branch per agent
  -> operator SEES the fleet's territory for the first time
  -> collisions and near-misses become visible and countable
  -> guard gains precision (real surfaces, not proxies) and credibility (data, not one incident)
  -> "give this agent its own tree" becomes the obvious next primitive
  -> --worktree new removes the manual step that CAUSES the collisions
  -> more agents per operator-minute, more territory to track  (loop, with more data)
```

**4.2 Codex: resolution becomes evidence, then better defaults.**

```
every launch resolves a cwd and records why that path won
  -> the guard turns risky inherited choices into structured feedback
  -> feedback pushes operators toward safe workspace roots and deliberate --cwd values
  -> launches become deterministic and auditable
  -> deterministic launches make higher-level orchestration safer
  -> orchestrators use launch-agent instead of hand-composed surface setup
  -> more launches through the canonical primitive make future policy improvements fleet-wide
```

**4.3 Gemini: safety becomes trust, then parallelism.**

```
explicit context -> safer actions -> higher operator trust
  -> more delegated parallel tasks -> more worktrees, more agents
  -> greater need for robust environmental guards  (loop)
```

**4.4 The shared engine.** All three name the *same* small change as the thing that starts the wheel, and all three note that the plan as written does not make it:

> **Make the probe return a value that gets persisted, not a boolean that gets discarded.**

Claude states it as one extra field on the return type plus one extra call to the metadata stamping the launch path already performs. Codex states it as "the small change that starts this flywheel is not telemetry; it is preserving `cwd_origin` through the whole launch path and returning it in structured results and errors." Gemini states it as "you do the work to find the git-dir, don't throw it away."

**4.5 The anti-flywheel.** Codex identifies the one thing that would spin the wheel backwards: if the c11 skill teaches agents to auto-retry the refusal by mechanically appending `--cwd`, then every guarded launch trains the fleet to bypass the guard, the false-positive data goes to zero, and the refusal becomes a latency tax with no safety value. The skill wording is therefore not documentation cleanup, it is load-bearing on whether the feature works at all.

---

## 5. Strategic Questions for the Plan Author

Deduplicated from 26 questions across three reviews. Ordered: blockers first, then contract, then direction.

### Blockers (an implementer cannot start without these)

1. **Where does the guard live: CLI, server, or both?** The plan's stated seam has the inherited cwd as `nil` by contract; it is resolved downstream at surface creation. Claude argues CLI-side, where the process cwd *is* the launching agent's shell cwd. Codex argues that is wrong for `--workspace` / `--pane` targets (the CLI process is running elsewhere) and bypassable by direct socket callers. Both concede "both" is defensible. Silence is not.

2. **Reuse `GitContextResolver` or build a new probe?** Verification confirms it already exists at `Sources/Metadata/GitContextResolver.swift` with the `--git-common-dir` versus `--git-dir` comparison, `mainCheckout`/`linkedWorktree` classification, `BranchValue` states, an injectable `GitRunner`, a bounded `ProcessGitRunner`, and three test files. Is there a reason to add a second definition of "linked worktree," given they will drift?

3. **What is the threading shape?** `agent.launch` is absent from `socketWorkerV2Methods`, so its handler runs on the main actor, while `GitRunner` has an explicit off-main precondition and traps main-thread invocation. Socket-worker orchestration with short main-actor snapshots and mutations is the clean direction, but the plan must name it.

4. **How is the checked path pinned through surface creation?** While the probe runs, the focused surface can `cd` and the target pane can change. Does creation consume the snapshotted path (closing the check/use race), and does it revalidate that the target IDs still exist?

5. **Which ticket lands first, 193 or 194?** Both `in_progress`, both assigned to `agent:codex-c11-launch-cwd`, both touching launch-agent cwd resolution. If 194 first, 193 shrinks to a probe plus one branch on an already-centralized resolver. If 193 first, does it define the shared `ResolvedAgentLaunchCwd` type that 194 then extends?

### Contract and semantics

6. **Does a configured C11-194 workspace root count as explicit intent, or is it a guarded origin?** Asked independently by Codex and Gemini. Gemini argues it logically should bypass, since the root represents deliberate operator configuration. Encode the answer in the origin enum, not in ad hoc conditionals.

7. **Proxy rule or precise rule?** "Any linked worktree" refuses an operator or lone agent working legitimately inside a worktree, which is the dominant pattern in this repo's own lattice-orchestrator workflow. "A tree another live surface already holds" has no false positives, names the offending surface, and extends to main-checkout collisions the proxy waves through. Ship the proxy now with the precise rule as v2, or pay the plumbing today?

8. **Refuse immediately, or warn-and-count for one release?** The `AgentLaunchStatsStore` rail already exists. A week of fleet data settles question 7 empirically. Is the incident urgent enough to skip that?

9. **What is the stable error code and `data` payload?** Candidates: `cwd_contested_worktree` (Claude) or `inherited_linked_worktree` (Codex). Fields under discussion: cwd, cwd_origin, worktree root, worktree basename, branch display state, and (under question 7's precise rule) the holding surface ref. The reference doc's error table needs the row either way.

10. **Is `--cwd $PWD` the intended override, or do you want an explicit `--allow-worktree`?** The former overloads a path flag with a policy meaning; the latter is one more flag but reads as intent and is greppable in fleet logs.

11. **Fail-open or fail-closed on an indeterminate probe?** Missing git binary, timeout, permission failure, malformed output. Does the caller get a warning when c11 cannot classify the directory?

12. **How do detached HEAD, no-branch, and submodules behave?** `BranchValue` already models the first two, so this is a policy and display decision. For a cwd inside a submodule of a linked superproject, does the outer worktree's status drive the refusal?

13. **Should the success payload expose resolved `cwd` and `cwd_origin`?** Additive and compatible. It turns launch placement from an inference into evidence and gives Lattice and other fleet controllers launch provenance alongside task lineage.

### Direction

14. **Should the fact be persisted to surface metadata?** Stamping `git_root` / `git_branch` / `git_worktree_kind` is a small delta over merely computing it, and it is the input to `c11 tree` visibility, collision telemetry, the precise rule in question 7, and auto-worktree provisioning. All three reviewers asked this. Is there a reason not to?

15. **Does the skill get updated in this ticket, and does it forbid auto-retry?** CLAUDE.md makes the skill update plus `scripts/sync-installed-skills.sh` a hard rule for CLI and socket changes, and the sibling 194 plan already includes it. Beyond presence: does the skill explicitly tell agents not to mechanically retry with `--cwd`? If it does not, the guard trains the fleet to bypass it.

16. **Is `--worktree new` on the roadmap?** If yes, 193 and 194 are both prerequisites and should be scoped with that destination in view, since it removes the failure mode rather than detecting it. If no, say so, because it changes how much structure is worth building into the probe now.

17. **Is worktree-lifecycle-scoped agent state (ephemeral task memory tied to the worktree) a direction you want?** Gemini's most ambitious mutation. It reframes the worktree as the unit of sub-agent existence and would make the provenance work in this ticket foundational rather than incidental.

18. **Is c11 comfortable owning its first *policy* refusal?** Every `agent.launch` error today is a validation error (bad type, bad path, bad flag combination). This is the first *judgment* error: inputs well-formed, c11 declines anyway. For a tool whose CLAUDE.md declares it "unopinionated about the terminal," it is worth writing down why this seam is where opinion is allowed: it guards c11's own multi-agent invariant, not the tenant's tooling.

19. **What runtime evidence will prove the rejection path creates no surface and starts no process?** Pure logic tests cannot show this. Codex asks for adapter-level or tagged-build validation against a real linked worktree, with the refusal case verified side-effect-free.

---

## Appendix: Where the Reviews Disagreed

Recorded so the plan author does not have to reconcile three documents.

| Question | Claude | Codex | Gemini | Resolution |
|---|---|---|---|---|
| Guard location | CLI-side (a), or both (c) | Server-side, authoritative | Not addressed | Codex, on the merits: CLI-side probes the wrong checkout for `--workspace` / `--pane` targets and misses socket callers |
| Probe implementation | New pure-filesystem `WorktreeProbe` | Reuse `GitContextResolver` | Enrich existing probe | Codex, verified: the resolver exists with an injectable `GitRunner`, which also gives Claude the pure tests it wanted |
| Refuse or redirect | Refuse | Refuse | Consider auto-redirect to common dir | Refuse. Record redirect as a rejected alternative; it violates the "never silently place an agent" property both other reviewers named |
| Ship refusal in v1 | Warn-and-count first | Refuse, contract fully specified | Refuse with a teaching message | Open. Question 8 |
| New test file | Extend `CwdParamResolutionTests.swift`, avoid pbxproj | Add adapter-level behavioral coverage | Not addressed | Compatible: extend in place for the decision matrix, add the adapter test wherever it can live without a pbxproj edit |
