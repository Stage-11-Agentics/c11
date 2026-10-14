# Standard Plan Review — C11-193

Plan ID: `c11-193-plan`  
Model: `codex`

### Executive Summary

The product decision is sound: an omitted `--cwd` should not silently launch a new agent into a linked worktree, while an explicit `--cwd` should remain a deliberate escape hatch. That directly addresses the reported fleet-safety failure without banning legitimate helper agents or mutating git state.

The plan is not ready to hand to an implementer, though. Its most important missing concept is an **effective cwd resolution result that includes provenance**. Today `v2ResolveCwdParam` collapses omitted/blank/`inherit` to `nil`, and `v2AgentLaunch` passes that `nil` onward to placement-specific creation paths (`Sources/TerminalController.swift:2753-2779`, `Sources/SocketHandlers/SocketDispatch.swift:1067-1075,1141-1188`). There is therefore no single concrete “inherited cwd” in the handler for the proposed probe to inspect. The implementation must first resolve the exact directory that will be used, record whether it came from an explicit request or an inherited/default source, and then use that same captured directory for the actual spawn. Otherwise the guard can inspect one directory and launch into another.

Three other omissions are blocking:

1. c11 already has a robust, pure-logic `GitContextResolver` that performs the exact normalized `--git-common-dir` versus `--git-dir` comparison and captures attached, detached, and missing branch state (`Sources/Metadata/GitContextResolver.swift:257-364,475-520`). Adding a second linked-worktree probe would duplicate policy and likely lose its normalization, submodule, stale-worktree, timeout, and branch-label behavior.
2. `agent.launch` currently runs under the main-actor socket policy, while `GitContextResolver.resolve` explicitly traps if invoked on the main queue (`Sources/TerminalController.swift:1964-1991,2033-2037`; `Sources/Metadata/GitContextResolver.swift:264-280`). The plan must specify an off-main probe architecture and bounded main-actor snapshots/mutations.
3. Adding a warning to the socket result's existing `warnings` array does not satisfy “surface one actionable acknowledgement” for the default CLI path. `printV2Payload` prints only the ordinary `OK …` summary unless `--json` is used, and `v2OKSummary` ignores warnings (`cli/c11.swift:5006-5016,13134-13142`). The human CLI needs an explicit warning-to-stderr path and a behavioral check.

My verdict is **Needs revision**. The direction should remain, but the plan needs a concrete cwd/source seam, threading design, diagnostic contract, C11-194 integration rule, and runtime validation before implementation starts.

### The Plan's Intent vs. Its Execution

The real intent is not merely “detect a worktree.” It is to turn an accidental, invisible inheritance decision into either:

- a refusal before any surface or agent state is created, or
- an explicit, observable choice when the caller supplied `--cwd`.

The plan captures that distinction well in steps 3–4 and keeps the scope narrow in its non-goals. It also correctly treats C11-194 as complementary: a better default reduces how often the hazard is encountered, while this guard makes a hazardous fallback non-silent.

Execution drifts from intent in two places. First, “inherited cwd resolution” is described as though it were already a value at a pure seam. It is currently represented as the absence of an override, with final behavior delegated to workspace/surface creation. For a new workspace, `TabManager.addWorkspace` derives a directory from the selected workspace's focused panel/current directory (`Sources/TabManager.swift:1367-1395,2327-2339`). For an existing workspace, `v2AgentLaunch` passes `nil` into `newTerminalSurface` (`Sources/SocketHandlers/SocketDispatch.swift:1164-1188`; `Sources/Workspace.swift:8712-8738`). The plan must define which placement's state is authoritative and capture it before probing.

Second, the ticket's broad invariant—“no two agents mutate the same tree”—is stronger than this guard can enforce. A main checkout can also be shared, an explicit override can intentionally share a linked worktree, and c11 has no ownership registry proving that a given tree belongs to another live agent. The proposed guard is still valuable, but its copy and acceptance criteria should honestly describe it as a high-signal accidental-linked-worktree guard, not a complete mutual-exclusion mechanism.

### Architectural Assessment

The right decomposition is a small policy layer over existing primitives, not a new git subsystem:

1. **Resolve the launch cwd and its source.** Introduce a value such as `AgentLaunchCwdResolution { path, source }`, where source can distinguish at least explicit request from inherited/default resolution. Ideally C11-194 owns the shared precedence enum—explicit `--cwd`, workspace root, launching-surface cwd—and C11-193 consumes it. If C11-193 lands first, its seam should be shaped so C11-194 can extend it without replacing it.
2. **Classify git context with the existing resolver.** Call `GitContextResolver.resolve` off-main and map its `outer` result into the launch policy. A linked outer worktree should be caught even when the cwd is inside a submodule. Attached, detached, and no-branch values already exist and can generate bounded actionable copy.
3. **Make a pure decision.** A testable `AgentLaunchCwdGuard` should take `{resolved path, source, git classification}` and return something like `.allow`, `.allowWithWarning`, or `.reject(code, message, data)`. This is the unit-test seam; the git plumbing does not need to be reinvented.
4. **Apply the decision before mutation.** Resolve/snapshot the cwd, probe it off-main, then create the surface using that same captured path. On rejection there must be no new workspace/surface, no identity metadata, no delayed prompt, and no launch-stats record. If mutable workspace state is read before the probe, either revalidate it or intentionally pin the captured path for the spawn so there is no time-of-check/time-of-use mismatch.
5. **Wire both diagnostic channels.** Return a stable structured error for inherited rejection, with path/branch/worktree context in `data`; append one warning for explicit linked-worktree allowance; print successful launch warnings once to stderr in human mode while retaining them in JSON.

The socket threading point needs to be explicit. `agent.launch` is absent from `socketWorkerV2Methods`, so the entire handler currently enters on main. Moving the git call onto a background queue from inside a synchronous main-actor handler and waiting would risk a deadlock or UI stall. A clean approach is to route `agent.launch`—and `config.launch`, which delegates to it—through the socket worker, keep parsing/config/git I/O there, and use the existing bounded main hops only for workspace snapshot and creation. Whatever implementation is chosen, the plan must prohibit git/process I/O on main and add a routing/threading test.

### Is This the Move?

Yes, with the architecture above. Server-side enforcement at `agent.launch` is stronger than a CLI-only check because direct socket clients and `c11 config launch` share the same behavior. It also lets the guard reason about the actual target workspace rather than assuming the CLI process's own cwd is the launch cwd.

The guard should remain narrow. Building a global worktree lease/ownership service would be a fundamentally different project with lifecycle, stale-owner, crash-recovery, and cross-process coordination costs. This ticket does not need that machinery to eliminate the observed silent failure. Conversely, merely updating the default through C11-194 would leave other inheritance paths and future regressions unguarded. The proposed refuse/explicit-override policy is the appropriate middle ground.

The main sequencing risk is C11-194. Both tickets necessarily touch cwd precedence in `v2AgentLaunch`; implementing them as separate ad hoc branches invites a merge that compiles while subtly changing what “inherited” means. They should share one resolution type and have an explicit merge order or integration owner.

### Key Strengths

- **Correct safety boundary.** Refusing only accidental inheritance preserves legitimate helper-agent workflows via explicit `--cwd`.
- **Actionable recovery.** Naming the branch and telling the caller exactly how to override converts a silent placement bug into a one-command correction.
- **No tenant mutation.** The plan observes git state without writing worktrees, branches, config, or dotfiles.
- **Good scope discipline.** Focus behavior and unrelated launch composition remain non-goals.
- **Behavior-oriented core matrix.** Inherited rejection, explicit allowance, and main-checkout allowance are the essential policy cases.
- **Complementary relationship to C11-194.** Default selection and safety enforcement solve different layers of the problem.

### Weaknesses and Gaps

1. **The proposed probe duplicates existing code.** `GitContextResolver` already handles normalized relative/absolute git-dir paths, submodules, detached HEAD, no branch, stale worktrees, bounded process execution, and label truncation. The plan should say “reuse/extract policy from” rather than “add a probe.”

2. **No effective-cwd/source contract is defined.** Presence of `params["cwd"]` cannot by itself stand in for the actual directory or its provenance, especially once C11-194 adds workspace-root precedence. The plan needs a named result type and precedence table.

3. **The threading design is unsafe if implemented literally.** The current handler is main-actor routed, while the existing resolver forbids main-thread use and can wait up to five seconds per git command. This is a product-performance constraint, not an implementation detail.

4. **The plan does not prevent check/spawn drift.** If it probes a live panel cwd and later passes `nil` to surface creation, a cwd update during the probe can invalidate the decision. Probe and spawn must use the same resolved path, or the source state must be revalidated.

5. **“One acknowledgement” has no output contract.** Define whether it is `warning:` on stderr, an element in JSON `warnings`, or both. Existing default output suppresses the warnings array, so socket-only tests would miss the user-visible failure.

6. **No stable error schema is specified.** Add an error code such as `linked_worktree_requires_explicit_cwd` (exact name to be decided) and structured fields for `cwd`, `worktree`, and branch state. Automation should not have to parse prose.

7. **Probe failure policy is undefined.** The current `GitRunner` returns `nil` for non-repo, non-zero exit, timeout, exec failure, and empty output. Those cases are not equivalent for a safety guard. The plan must decide whether an inconclusive inherited probe fails open, fails closed, or emits a distinct error/warning. It must also decide what to do with `.stale` worktrees.

8. **The tests stop one layer too early.** Pure decision tests are necessary, but they do not prove handler wiring, pre-mutation refusal, CLI warning visibility, or the real git behavior. Add a real temporary-repo/worktree test and a tagged-build CLI/socket smoke that verifies: inherited launch fails, surface count is unchanged, explicit launch succeeds in that exact cwd, the warning appears once in human mode, and JSON carries the same warning.

9. **The proposed gates may not compile the changed CLI.** `c11-logic` exercises the app's logic target; `cli/c11.swift` is a separate CLI target. If warning printing changes there, the plan needs an explicit CLI build/test gate in addition to the logic suite.

10. **Documentation and skill contracts are missing.** `docs/launch-agent-reference.md` currently says only that `--cwd` sets the directory and enumerates existing errors (`docs/launch-agent-reference.md:121-125,186-205`). The new refusal/override/warning semantics and error code must be documented. Because `skills/c11/references/api.md` and `skills/c11/references/orchestration.md` teach agents to use `launch-agent`, update the relevant skill reference and run `scripts/sync-installed-skills.sh c11` if the installable skill changes, per the repo's hard rule.

11. **Edge cases are under-specified.** Add cases for a nested directory inside a linked worktree, detached HEAD, missing/deleted branch, cwd outside git, explicit linked worktree with warning, explicit main checkout without warning, and submodule-inside-linked-worktree. These are already representable through the existing resolver.

### Alternatives Considered

**CLI-side preflight.** This is simpler and naturally off-main, but it is weaker: direct `agent.launch` and `config.launch` callers bypass it, and the CLI process cwd is not necessarily the target's effective inherited cwd. It is not the right enforcement boundary.

**Use existing derived sidebar metadata.** This avoids launching git, but derived worktree/branch state is asynchronous, cacheable, and tied to reported surface cwd. Missing or stale metadata would recreate the silent failure the guard is meant to remove. It can enrich diagnostics, not authorize launch.

**Create a new dedicated linked-worktree detector.** A narrower typed detector could distinguish non-repo from operational failure better than the current optional `ResolvedGitContext`, but duplicating git-dir normalization and branch handling is undesirable. If the existing resolver's `nil` failure collapse is insufficient, extend its runner/result typing or add a thin status-returning adapter around the same implementation rather than maintaining two git classifiers.

**Global worktree ownership/lease registry.** This could enforce the ticket's broad “no two agents mutate the same tree” invariant, including main checkouts, but it requires reliable agent lifecycle ownership and stale-lease recovery. That is much larger than the observed bug and should not block this guard.

### Readiness Verdict

**Needs revision.** The policy is approved in spirit, but implementation should not begin from this plan as written.

It becomes ready when the plan:

1. names the effective-cwd-with-source seam and its precedence/placement behavior;
2. reuses `GitContextResolver` or explicitly justifies a shared typed extension;
3. specifies off-main execution and main-actor snapshot/mutation boundaries;
4. guarantees the probed cwd is the spawned cwd and rejection is pre-mutation;
5. defines structured error data plus once-only human/JSON warning output;
6. states the inconclusive/stale probe policy and C11-194 merge contract;
7. adds CLI compilation, real git worktree behavior, and tagged runtime/socket validation; and
8. includes docs plus skill sync where applicable.

### Questions for the Plan Author

1. After C11-194, does a configured workspace root count as “inherited” and therefore get blocked when it is a linked worktree, or as an operator-approved source equivalent to explicit `--cwd`?
2. Should the guard apply identically to direct `agent.launch` socket calls and `config.launch`, with the presence of a valid socket `cwd` field treated as the explicit override? I recommend yes.
3. What is the required policy when git classification is inconclusive because `git` times out, cannot execute, or returns malformed output? Is silent fail-open acceptable for inherited cwd?
4. Should a `.stale` worktree be rejected with the same error, rejected with a distinct repair message, or allowed?
5. Is the intended structured error code `linked_worktree_requires_explicit_cwd`, and which fields must be stable in `error.data`?
6. For an explicit linked-worktree override, should the acknowledgement be both one stderr line in human mode and one `warnings` element in JSON? I recommend both, emitted once by the CLI.
7. Should detached/no-branch diagnostics render the existing canonical forms—`(detached @ <sha>)` and `(no branch)`—rather than omitting branch context?
8. Which ticket owns the shared cwd resolution seam, and what is the required merge order between C11-193 and C11-194?
9. Is the guard deliberately limited to linked worktrees, with main checkouts allowed even though that does not fully enforce “no two agents mutate the same tree”? The plan and user-facing copy should state that limitation plainly.
10. Is tagged runtime validation authorized for this ticket so the implementer can prove no surface is created on rejection and the explicitly overridden child actually starts in the requested linked worktree?
