# Standard Plan Review — C11-195-plan

Reviewer: Codex  
Verdict: **Needs revision**

## Executive Summary

The plan has the right architectural instinct: C11-195 should consume C11-194's single cwd resolution rather than inventing another lookup rule, and project-config discovery and PTY creation must be driven by the same effective directory. That is the move.

It is not execution-ready yet. The most important missing detail is that “the same resolved path” is still ambiguous when C11-194 returns no explicit, workspace-root, or launching-surface path. On the current shared branch (`fix/C11-193-launch-agent-cwd` at `4ec750670`), config lookup materializes the app-process fallback while surface creation and the response continue to use the optional pre-fallback path. That is precisely the split-brain state this ticket should eliminate. Materializing the fallback also raises a provenance issue: it must not accidentally become a persisted workspace root.

The plan also needs an explicit decision about `default-agent launch --in-surface`. The ticket context calls out the same app-cwd bug in `TerminalController.defaultAgentLaunch`, but the plan's non-goal leaves it unclear whether shared-helper reuse fixes that public path or silently excludes it. Finally, the proposed logic test can too easily prove `DefaultAgentProjectConfig.find(from:)` in isolation without proving the launch path supplies the correct directory.

This needs a focused revision, not a reframe: define one effective-cwd contract, name every consumer, test the composition seam, and make the tagged-app evidence concrete.

## The Plan's Intent vs. Its Execution

The underlying intent is stronger than “look up one file from a different directory.” It is to establish an invariant:

> A launch's project configuration, spawned PTY cwd, reported cwd, and cwd provenance all describe the same launch context.

Steps 1 and 2 point toward that invariant, and the dependency on C11-194 is correct. C11-194 already owns precedence and provenance: explicit `--cwd` → workspace root → launching-surface cwd. C11-195 should be a downstream consumer, not a second resolver.

The plan drifts at the fallback boundary. It says to use the app-process cwd only when all three meaningful sources are absent, but does not say whether that fallback becomes the effective path passed to surface creation and returned to the caller. The current branch makes the risk concrete:

- `SocketDispatch.swift` computes `lookupCwd = cwdResolution.path ?? FileManager.default.currentDirectoryPath` for project config.
- The new workspace/surface is still created with `cwdResolution.path`.
- The response's `cwd` is also still `cwdResolution.path`.

When the resolution is empty, those are not one value. A successful response can report `cwd: null`, the config can come from the app cwd, and the child can inherit a third fallback from surface construction. Step 2 needs to close this case explicitly.

The intent also covers more than the v2 `agent.launch` handler unless the ticket is narrowed. `TerminalController.defaultAgentLaunch` performs the same process-cwd lookup before its `--in-surface` path and then launches into the existing shell's ambient cwd when `--cwd` is omitted. C11-194's v2 resolver does not automatically fix that code path. The plan cannot both cite it as the same bug and leave its disposition implicit.

## Architectural Assessment

The right decomposition is:

1. C11-194 resolves target/caller context and precedence.
2. A small downstream launch-directory context materializes the effective path once.
3. C11-195 uses that context for project-config lookup, spawn creation, response data, and any legacy helper reuse.

That context needs to preserve at least:

- `effectivePath`: the non-optional directory actually used, including the last-resort process fallback;
- `source`: explicit, workspace root, launching surface, or an explicit representation of compatibility fallback;
- `establishesWorkspaceRoot`: true only for sources intended to seed a root, not merely for every source other than `.launchingSurface`.

The exact type name is not important; making the contract explicit is. If the existing optional source must remain for compatibility, a separate `effectivePath` plus an `isExplicitIntent`/`establishesRoot` decision is enough. What is unsafe is deriving these facts independently at each consumer.

The root-persistence point is subtle and blocking. If the process fallback is materialized as a non-nil working directory while the current `establishRootFromWorkingDirectory: cwdResolution.source != .launchingSurface` condition remains, a `nil` source can be treated as root-establishing. A compatibility fallback must not silently turn the GUI app's arbitrary cwd into a durable workspace root. The plan needs to state this behavior.

Keep config and filesystem I/O off-main. The shared branch correctly moves launch planning to the socket worker, takes a bounded main-actor context snapshot, and returns to the main actor only for surface mutation. C11-195 should preserve that boundary.

## Is This the Move?

Yes, with the contract tightened. Fixing this at the C11-194 resolver boundary is better than teaching `DefaultAgentProjectConfig.find(from:)` about workspaces or callers. The project-config walker should remain a simple filesystem operation; it should not acquire UI/model knowledge.

The common failure pattern here is a “correct lookup” patch that leaves the spawned process on a different cwd. That looks green in a unit test and still gives the operator an agent configured for project A while running in project B. The plan recognizes this risk in step 2, but it must make the fallback case and response truth part of the acceptance criteria.

The second likely failure is a test that manually calls `find(from: resolvedPath)` and passes. That proves the already-working walker, not that `agent.launch` selected and propagated the path. The test must cross the new composition seam.

## Key Strengths

- **One owner for cwd precedence.** Making C11-195 consume C11-194 prevents policy drift and preserves provenance.
- **Parity between configuration and execution.** Step 2 identifies the essential behavioral invariant rather than treating lookup as an isolated fix.
- **Behavior-oriented fixtures.** A scratch `.c11/agents.json` with a decoy fallback is the right shape for detecting silent wrong-directory lookup.
- **Runtime proof is included.** Project config is user-visible launch behavior; tagged-app evidence is appropriate in addition to logic coverage.
- **Scope restraint is mostly sound.** Project-config precedence and A-button UX do not need redesign for this bug.

## Weaknesses and Gaps

### 1. The fallback path is not fully specified

The plan must say that the last-resort process cwd is materialized once and drives config lookup, surface creation, and response output. It must also say how `cwd_source` represents that fallback and that it does not establish a workspace root.

### 2. The proposed test can miss the integration bug

“Assert the project config is found from the resolved path” is not enough if the test supplies that path directly to `find(from:)`. The regression lives in the caller. Extract or expose a pure composition seam that accepts the C11-194 resolution plus an injected process fallback and returns the effective path/config launch inputs. Assert both the sentinel project configuration and the working directory handed to creation.

Do not mutate the process-wide current directory in a parallel XCTest merely to create the decoy. Inject the fallback path into the pure seam.

### 3. Root and rootless cases are conflated

“Resolved surface/root path” and “an inherited/root launch” are ambiguous. C11-194 introduced two new no-`--cwd` behaviors that need separate coverage:

- workspace root exists and wins;
- rootless workspace falls back to the launching surface.

A table-driven scratch test should cover both, with a different config under the process fallback. A third case should cover total absence and verify the compatibility fallback without persisting it as a root.

### 4. `default-agent launch --in-surface` has no disposition

The plan's non-goal says “A-button/default-agent entry point beyond shared helper reuse,” but never says what reuse occurs. The new-surface default-agent path delegates to `Workspace.launchAgentSurface` and recomputes configuration; the `--in-surface` path uses the process-cwd lookup directly. Either include that path in C11-195 with focused coverage, or explicitly narrow C11-195 and create/link a follow-up. Leaving the known public-path bug implicit is not acceptable.

### 5. Tagged-app validation is not yet falsifiable

The validation should name observable sentinels, not merely say the launch “uses” project config. Use a scratch project config with an inert, unmistakable command or environment sentinel, launch without `--cwd`, and prove all of:

- JSON reports the expected `cwd` and `cwd_source`;
- the returned command/agent axes came from the scratch project config rather than the decoy;
- the child visibly runs in the exact same directory (for example, a sentinel plus `pwd` read from the returned surface);
- workspace-root and rootless launching-surface cases both pass.

Run this against a tagged QA launch with startup dialogs suppressed. No computer-use pass is necessary if the socket/PTY observations are sufficient.

### 6. Shared-branch sequencing is vague

“C11-194 must land first” is ambiguous because C11-193/194/195 share branch `fix/C11-193-launch-agent-cwd` and PR #407. State whether “first” means commit/implementation order inside the shared PR or a separate merge. Since C11-194 was reset, C11-195 evidence should name the exact reviewed commit/range that contains the final C11-194 resolver semantics; linking the shared PR alone is not durable proof of this ticket's completion.

### 7. Verification commands and failure gates are absent

Name the narrowed safe `c11-logic` test that executes the scratch-backed behavior, the compile/build gate, and the tagged runtime scenario. The implementation touches socket dispatch and surface creation, so a passing standalone config-walker test is insufficient.

## Alternatives Considered

### Patch only `lookupCwd`

Smallest diff, but wrong architecture. It preserves divergence between config, child cwd, and response when the resolver is empty.

### Send the CLI process cwd as implicit `--cwd`

This works only for a local caller targeting its own workspace. It is wrong for `--workspace`, `--pane`, background callers, and direct socket callers. Server-side target-context resolution is the stronger boundary.

### Put fallback logic inside `DefaultAgentProjectConfig.find`

That hides launch semantics inside a filesystem walker and still does not make surface creation or response output agree. Keep the walker context-free.

### Materialize one launch-directory context

This is the recommended option. It is a small extension of C11-194's design, preserves provenance, keeps I/O off-main, and gives tests a clean behavioral seam.

## Readiness Verdict

**Needs revision.** It becomes ready to execute when the plan:

1. defines a single effective cwd, including process fallback, used by config lookup, creation, and response;
2. preserves provenance and explicitly prevents compatibility fallback from establishing a workspace root;
3. decides and documents the scope of `default-agent launch --in-surface`;
4. replaces the loose test description with composition-level coverage for workspace-root, rootless-surface, and total-fallback cases;
5. specifies falsifiable tagged-app evidence and exact shared-branch review/commit evidence.

The central approach should remain unchanged.

## Questions for the Plan Author

1. Is `c11 default-agent launch --in-surface` part of C11-195, or should its independently confirmed process-cwd lookup become a linked follow-up ticket?
2. When all three C11-194 sources are absent, must the child PTY actually start in the app-process cwd, or is that fallback intended only for config lookup? If only for lookup, how is config/execution divergence acceptable?
3. How should the compatibility fallback appear in the response: `cwd_source: null`, a new stable `process_fallback` value, or another representation?
4. Should a process-fallback launch ever establish or persist a workspace root? The safe default is no.
5. Does acceptance require both no-`--cwd` branches—workspace root and rootless launching surface—or only one? The plan's current “inherited/root” wording permits either.
6. What composition seam will the logic test call so it proves the launch handler supplies the path, rather than re-proving `DefaultAgentProjectConfig.find(from:)`?
7. Which project-config field will serve as the runtime sentinel: command, model/effort, environment, or more than one?
8. What exact commit/range on shared PR #407 will be attached to C11-195 after the reset C11-194 implementation reaches its final form?
