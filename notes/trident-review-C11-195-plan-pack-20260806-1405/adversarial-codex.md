# Adversarial Review — C11-195 Plan

PLAN_ID: C11-195-plan  
MODEL: Codex  
VERDICT: NEEDS REVISION

### Executive Summary

Concern is high. The plan identifies the desired invariant—configuration lookup and the child process must use the same effective cwd—but it does not define a coherent contract that can enforce it across the actual launch paths.

The single biggest issue is the process-cwd fallback. C11-194 defines a three-source resolution (`explicit` → `workspaceRoot` → `launchingSurface`) and returns no path when none exists. C11-195 then proposes using the app process cwd when all three are absent. That creates a fourth source with no provenance in C11-194 or C11-193. If the app cwd is used only for `DefaultAgentProjectConfig.find`, config and child cwd still diverge. If it is also passed into surface creation, a contextless launch is silently moved to the GUI app's arbitrary cwd—the very value this ticket identifies as unsafe. The plan does not choose between those outcomes or justify either one.

The scope is also underdefined. Main currently has at least three materially different rails:

- `agent.launch` / `config.launch`, which plan off-main and create a new surface;
- `default_agent launch --in-surface`, which starts an agent inside an existing PTY and does not create a surface;
- `default_agent launch` without `--in-surface`, which resolves once in `TerminalController.defaultAgentLaunch`, then delegates to `Workspace.launchAgentSurface`, which resolves project config again and creates a terminal without an explicit working directory.

The plan can be implemented “successfully” on the first rail while leaving the second wrong and the third double-resolved. The non-goal excluding the A-button/default-agent entry point “beyond shared helper reuse” is not a boundary; it is an unresolved contradiction with the ticket context, which explicitly names `defaultAgentLaunch` as another occurrence.

Before implementation, the plan needs an explicit launch-context object, exact call-site ownership, a decision on no-context behavior, target-identity stability, a behavior-level test matrix, and a delivery gate tied to an exact PR #407 head.

### How Plans Like This Fail

Plans for cwd/config plumbing usually fail in four ordinary ways, all visible here.

1. **They fix a value at one call site, not the lifecycle.** `SocketDispatch.swift` currently looks up project config before surface creation. The open branch already demonstrates a two-phase design: snapshot UI context on main, do config/git I/O off-main, then return to main to create the surface. A string named `resolvedPath` is insufficient unless the same immutable context also pins the target workspace/pane. Otherwise a focus or selection change during I/O can produce config from workspace A and a surface in workspace B.

2. **They retain the old fallback in a supposedly exceptional branch.** “Only when no path exists” sounds safe, but missing caller identity, a rootless restored workspace, a closed caller surface, or an empty/stale directory are normal degradation cases. A fallback to the app cwd is still arbitrary and still capable of finding an unrelated `.c11/agents.json` whose command and environment will then execute.

3. **They test discovery instead of wiring.** `DefaultAgentProjectConfig.find(from:)` already has scratch-backed tests for exact-directory and upward discovery. Another test that merely calls it with a resolved path proves no new behavior. The regression lives in the handoff among context resolution, config loading, launch planning, and surface creation.

4. **They conflate one shared branch with ordered delivery.** C11-193, C11-194, and C11-195 share PR #407. Saying C11-194 “must land first” is not actionable when C11-194 is reset/in progress and the PR branch already contains an earlier resolver implementation with superseded C11-193 refusal semantics. Without an exact commit/API gate, C11-195 can be reviewed against the wrong foundation and the combined PR can still ship stale policy.

### Assumption Audit

#### Load-bearing assumptions

1. **C11-194 will expose one reusable, provenance-carrying resolution.** Likelihood: medium. The plan says this but does not name the type/API or require C11-195 to consume it without re-resolution. The current PR branch has only the three sources above; it has no process-fallback source.

2. **The resolved target remains the target through the off-main lookup.** Likelihood: low without an explicit guard. On the inspected PR branch, the initial context snapshot captures cwd inputs, but the final commit resolves the target workspace again. A background launch or operator focus change can invalidate the assumption.

3. **Every named entry point can consume the same helper.** Likelihood: low. `agent.launch` is a socket-worker flow; `defaultAgentLaunch` is a main-actor v1 flow; `--in-surface` has no surface-creation phase; and `Workspace.launchAgentSurface` performs its own lookup and launch composition. “Shared helper reuse” does not erase those lifecycle differences.

4. **A string passed to config lookup and surface creation becomes the same real cwd.** Likelihood: medium. Explicit cwd validation checks existence and directory type, but persisted workspace roots and shell-reported paths can be stale. `DefaultAgentProjectConfig.find` does not first require the starting directory to exist, while the terminal runtime may reject or fall back from that path. Symlink normalization can also make lexical lookup and physical `pwd` disagree.

5. **Using the process cwd in the no-context case is harmless compatibility.** Likelihood: low. The ticket itself says a GUI app's process cwd is essentially arbitrary. Because project config selects executable commands and environment, choosing an unrelated config is a code-execution boundary, not merely a cosmetic default.

6. **One positive test is enough.** Likelihood: low. The precedence ladder has explicit, workspace-root, launching-surface, and proposed no-context outcomes; the two main source paths need separate coverage, and explicit precedence must not regress.

7. **“Uses project-level agent configuration” will be observable in a tagged run.** Likelihood: medium unless the fixture uses a unique harmless command/env sentinel. Agent type or stamped metadata alone is not proof: an explicit `--type`, user defaults, saved-config overlays, or a second config resolution can yield the same visible result.

#### Secondary assumptions

- A workspace root should intentionally override a more deeply nested config under the launching surface cwd because the child will launch at the root.
- A targeted rootless workspace should inherit from the invoking surface rather than the target workspace's focused surface.
- A missing or closed `caller_surface_id` should degrade to another cwd source rather than fail.
- A malformed/unreadable project config may continue to fail silently without making runtime evidence ambiguous.
- `C11_DEFAULT_AGENT_LAUNCH`, recomputed again during terminal creation in `GhosttyTerminalView.swift`, will stay consistent merely because a working-directory string is passed downstream.

Every one of those assumptions can change user-visible launch behavior; none is stated or tested in the plan.

### Blind Spots

1. **No exact call-site inventory.** The plan must name `agent.launch`, delegated `config.launch`, both `default_agent launch` branches, and `Workspace.launchAgentSurface`; then say which are in scope and why. Today `TerminalController.defaultAgentLaunch` resolves config before branching, while the new-surface branch discards that resolved launch and lets `Workspace.launchAgentSurface` resolve again.

2. **No immutable target identity.** The resolved context should carry the target window/workspace/pane (or new-workspace intent), path, and source. Final surface creation must either use that same identity or fail if it disappeared. Re-reading the selected workspace after file I/O reintroduces divergence at a different layer.

3. **No `--in-surface` semantics.** With no explicit `--cwd`, should config be discovered from the target surface's current cwd, the caller's workspace root, or the caller surface? Should the command omit `cd` while still loading config from the target cwd? The generic new-surface rule does not answer this.

4. **No no-context contract.** The safe choices are not interchangeable: return no project config and preserve terminal-native inheritance, fail with an actionable error, or introduce an explicit `.processFallback` source and pass it to every consumer. The plan currently gestures at the last option without adding provenance or confronting the behavior change.

5. **No stale-path behavior.** Workspace roots persist and can be edited; directories can move or be deleted. The plan needs a policy for a nonexistent root before config discovery and process spawn.

6. **No threading contract.** Project-config file I/O must stay off-main for the canonical socket path. Reusing that helper from the main-actor v1 path without a designed boundary can add launch-time UI stalls or deadlock-prone sync hops.

7. **No downstream consistency check.** Terminal creation separately derives `C11_DEFAULT_AGENT_LAUNCH` from `workingDirectory ?? HOME`. The test should prove the launched command, actual `pwd`, and exported default-launch config all agree where that environment contract applies.

8. **No negative/adversarial tests.** Missing are: explicit cwd beats root; root beats surface; rootless surface fallback; unrelated process fallback is not consulted when any legitimate source exists; background/non-selected workspace; selection mutation between snapshot and commit; deleted root; caller surface closed; and both default-agent branches.

9. **No exact verification or CI gate.** “Validate in the tagged app” omits the tag, QA launch mode, fixture setup, commands, expected output, and artifact capture. “Link PR #407” omits commit/push, exact remote head, review resolution, and terminal CI.

10. **No documentation decision.** Project config selection is user-visible launch behavior. If C11-194's launch docs describe cwd precedence, they should also say that `.c11/agents.json` discovery uses that exact cwd. If no docs change is intended, the plan should justify that explicitly.

### Challenged Decisions

#### Keep the app-process cwd as a final fallback

Pushback: remove it. When no authoritative launch path exists, return `projectConfig = nil` and let the terminal's established inheritance/default behavior decide cwd. That avoids loading executable configuration from an unrelated directory. If compatibility requires a process fallback, make it a first-class resolution source, pass it to the child, expose it in diagnostics, update C11-193's source/intent model, and test it. A hidden `?? FileManager.default.currentDirectoryPath` after the shared resolver is precisely the split-brain pattern this ticket is meant to eliminate.

#### Fix at “C11-194's resolver” without defining the returned contract

Pushback: resolve a complete launch context, not only a path. It should include normalized path, provenance, pinned target identity, and the no-context outcome. Project config, worktree warning logic, and surface creation should consume the same value. Significant choices should not be reconstructed at each stage.

#### One scratch-backed logic test

Pushback: use a behavior-level seam that accepts a resolved launch context plus injected config loader and surface-creation recorder, then assert the same path reaches both consumers and the resulting launch plan contains the fixture's unique command/env. Keep the existing filesystem-backed `find` tests, but do not mistake another discovery test for launch-pipeline coverage.

#### Exclude the A-button/default-agent path except for helper reuse

Pushback: split the decision. The UI A-button may remain behaviorally unchanged, but the ticket's duplicate `defaultAgentLaunch` defect must either be fixed and tested here or explicitly moved to a follow-up. “Beyond shared helper reuse” leaves the implementer free to preserve the double resolution and process-cwd lookup.

#### Link the existing PR as the completion step

Pushback: PR #407 is a moving, shared integration vehicle, not immutable evidence. The plan must record the exact remote head containing all three ticket contracts, show superseded refusal behavior is gone, resolve review findings, and wait for terminal CI. A link alone proves none of that.

### Hindsight Preview

Two years from now, the likely “we should have known” failures are mundane:

- A background agent launches into a different workspace after selection changes during config I/O, and executes the wrong project's command. The early warning is any second call to resolve workspace/pane after the launch-context snapshot.
- A restored workspace points at a moved directory; config discovery walks an ancestor while Ghostty falls back elsewhere. The early warning is a non-explicit path that was never checked for existence immediately before planning.
- A later caller adds another launch rail and reads `FileManager.default.currentDirectoryPath` because the shared type represents only three happy-path sources. The early warning is any app-process cwd use outside a single, documented resolver.
- The canonical `launch-agent` test is green while `default-agent --in-surface` remains wrong because the plan never enumerated it. The early warning is more than one `DefaultAgentProjectConfig.find` call in agent-launch code.
- Runtime evidence reports the expected model/type but never proves which command actually ran. The early warning is validation that relies on metadata rather than a unique fixture sentinel and observed `pwd`.

### Reality Stress Test

Assume three likely disruptions happen together:

1. C11-194 changes again after its reset, replacing or reshaping the resolver.
2. The operator launches from a background caller into a rootless, non-selected target workspace while UI selection changes.
3. The caller/root directory is stale or absent after session restore.

Under the current plan, the implementation can fall back to the app cwd for config, re-resolve a different target for creation, and let the terminal choose yet another cwd when the stale path fails. C11-193's warning layer then receives either `nil` or an unmodeled process path, so its structured `cwd_source` and explicit-intent claims become inaccurate. The launch still appears successful, but it can execute the wrong config in the wrong directory with misleading warning provenance. No proposed test or runtime check would catch the combined failure.

A robust plan must make these disruptions collapse to one deterministic outcome: either one pinned, validated context is used everywhere, or the launch fails/degrades without consulting project config.

### The Uncomfortable Truths

- This is a five-step patch sketch, not an implementation plan. It lacks the API contract, call-site map, race policy, fallback semantics, test matrix, and lifecycle gate needed for a bug that can select executable project configuration.
- The proposed process fallback preserves the root cause under a rarer label. “Only when nothing else exists” is not a safety argument.
- “Pass the same path” is not enough when the target workspace can change between lookup and creation and when the runtime may reject a stale path.
- The open PR already contains a partial version of the desired v2 wiring, but the legacy path still uses the old lookup and the branch includes superseded worktree-refusal policy. Treating PR #407 as a stable dependency would be wishful thinking.
- If the plan will not own `defaultAgentLaunch`, the ticket description overstates what will be fixed. That needs an explicit scope correction or a follow-up ticket, not a vague non-goal.
- A green logic test cannot substitute for observing the launched process's cwd and fixture-selected command in a tagged app.

### Hard Questions for the Plan Author

1. Is the app process cwd actually an authorized launch/config source? If yes, why is an arbitrary GUI-process directory safe to search for executable project configuration? **Current answer: unknown, and blocking.**
2. Does “that same resolved path” include the process fallback? If yes, where is `.processFallback` represented and how do C11-193 warning details classify it? If no, why is config/child divergence acceptable? **Current answer: contradictory, and blocking.**
3. What exact immutable type does C11-194 hand to C11-195, and does it include target workspace/pane identity as well as path/source?
4. Which exact rails are acceptance scope: `agent.launch`, delegated `config.launch`, `default_agent launch --in-surface`, `default_agent launch` new-surface, UI A-button, and saved-config launches? **Current answer: ambiguous, and blocking.**
5. For `--in-surface` with no `--cwd`, which surface's cwd selects `.c11/agents.json`, and should the command issue a `cd` at all?
6. For an explicit target workspace with no root, does fallback use the caller surface or the target workspace's focused surface? Why?
7. What happens if the target workspace/pane closes or selection changes after the context snapshot but before surface creation: fail, retry the entire resolution, or silently retarget?
8. What happens when a persisted workspace root is missing, is a file, becomes unreadable, or resolves through a symlink to a different physical tree?
9. How will the logic test exercise the launch pipeline rather than merely retest `DefaultAgentProjectConfig.find`?
10. Will tests assert all precedence cases—explicit over root, root over surface, rootless surface fallback—and prove the unrelated process directory is ignored in each?
11. How will the default-agent new-surface test catch its current double resolution, where `TerminalController` resolves one config and `Workspace.launchAgentSurface` resolves another?
12. How will the tagged-app fixture prove both the actual child `pwd` and the actual fixture-selected command/env, rather than infer success from agent metadata?
13. Will tagged validation include a background/non-selected workspace so caller identity and target pinning are exercised?
14. How will project-config I/O remain off-main on `agent.launch`, and what is the threading design for the main-actor v1 `default_agent` path?
15. Must `C11_DEFAULT_AGENT_LAUNCH` inside the spawned shell reflect the same project config, and if so, where is that asserted?
16. What exact C11-194 commit/API is the prerequisite when all three tickets share PR #407? Does “land first” mean a reviewed commit sequence or a separate merge?
17. Before C11-195 is declared done, how will the plan prove the PR head no longer contains C11-193's superseded refusal behavior?
18. What are the required local test command, tagged-app tag and QA mode, remote-head check, review-resolution gate, and terminal CI jobs?
19. If no documentation changes are needed, where is the existing user-facing contract that says project config discovery follows the exact effective launch cwd?
20. If the plan intentionally excludes one of the duplicate call sites named by the ticket, what follow-up owns it and why is C11-195 still considered complete?
