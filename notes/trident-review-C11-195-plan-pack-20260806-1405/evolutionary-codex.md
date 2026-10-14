# Evolutionary Review — C11-195 Plan

Plan ID: `C11-195-plan`  
Model: `Codex`

### Executive Summary

C11-195 can become more than a correction to one bad fallback. Its larger opportunity is to establish a **launch-provenance contract**: c11 resolves launch context once, freezes it, and uses that exact value for project configuration, policy checks, terminal creation, the response envelope, and later diagnostics. That is the abstraction that prevents this bug class from returning.

The current plan points in that direction with “that same resolved path,” but it does not yet make the invariant structural. In particular, steps 1 and 2 still leave an empty-context contradiction: project lookup may fall back to the app-process cwd while surface creation receives no resolved path. Those are not necessarily the same directory, so the plan can retain the original divergence in its final fallback case. A GUI process cwd is also not a trustworthy project identity; if there is no effective launch cwd, the safer behavior is to apply no project config. If compatibility requires retaining process-cwd fallback, it must become an explicit resolution source and must also be the child cwd.

The best evolution is therefore small in code but large in leverage: make C11-194 return a typed, immutable launch context rather than a path-shaped convenience; prepare the launch once off-main; commit that exact preparation on main; and migrate every named entry point through the same seam. The scratch test should exercise the preparation result, not merely prove that `DefaultAgentProjectConfig.find(from:)` can find a file. This turns C11-195 from a two-call-site patch into a durable rail for future launch policy.

### What's Really Being Built

At the surface, the ticket makes `.c11/agents.json` discoverable when `--cwd` is omitted. Underneath, it is building a compiler from mutable runtime state into an immutable launch decision:

`request + caller surface + target workspace -> effective cwd + provenance + project config + launch plan -> committed surface`

That decision boundary is more important than configuration lookup itself. C11-193 needs the resolved directory and its intent provenance for linked-worktree warnings. C11-194 owns precedence among explicit cwd, workspace root, and launching-surface cwd. C11-195 makes project configuration another consumer. Future consumers will include launch explanations, auditing, resume diagnostics, environment policy, and perhaps trust decisions. If each consumer receives loose optionals and calculates fallbacks independently, the system will repeatedly rediscover variants of this bug.

The in-flight `fix/C11-193-launch-agent-cwd` branch already shows the capability trying to emerge. `AgentLaunchWorkingDirectoryResolution` carries `path` and `source`; `v2AgentLaunch` uses its path for config lookup and new-surface creation; and the response reports `cwd` and `cwd_source`. But it also shows why the plan should name the abstraction now:

- The v2 path currently computes `lookupCwd = cwdResolution.path ?? FileManager.default.currentDirectoryPath`, while terminal creation still receives `cwdResolution.path`. When the path is nil, lookup and execution can diverge.
- `TerminalController.defaultAgentLaunch` still derives lookup from `cwdArg ??` process cwd.
- `Workspace.launchAgentSurface` separately calls `resolverCwdForAgentLaunch()` for config discovery and then creates a terminal without passing that value as `workingDirectory`.

These are not three isolated bugs. They are three manifestations of missing launch context custody.

### How It Could Be Better

#### 1. Make equality structural, not conventional

Introduce a value such as `AgentLaunchContext` or `PreparedAgentLaunch` containing at least:

- the normalized effective directory;
- its provenance (`explicit`, `workspaceRoot`, `launchingSurface`, or an intentional no-context/fallback state);
- the loaded project configuration and, internally, the file path it came from;
- the composed launch plan.

Resolve and load it once. After that point, no launch call site should invoke `FileManager.default.currentDirectoryPath`, re-read workspace focus, or re-run directory precedence. Surface mutation should consume the frozen preparation directly. “Same resolved path” then becomes a type-level property rather than reviewer vigilance.

An acceptance invariant worth putting verbatim into the plan is:

> For every new-surface agent launch, one resolution `R` is captured before mutation. Project-config discovery starts at `R.path`, the terminal's requested working directory is `R.path`, and the response reports `R.path` plus `R.source`. No downstream consumer re-resolves cwd. If `R.path` is absent, project config is absent unless a compatibility fallback is first promoted into `R` and used by all three consumers.

#### 2. Decide the no-context behavior explicitly

The plan currently inherits the suspect app-process cwd as a last resort without explaining what directory the child will actually use. There are two coherent policies:

1. **Recommended:** no effective launch cwd means no project config lookup; let the terminal retain its ordinary nil-cwd behavior and use the user default.
2. **Compatibility option:** resolve one concrete fallback, label it `.processFallback` (or preferably the terminal's real default, if known), pass it to both config discovery and terminal creation, and expose the source in diagnostics.

What should not survive is an untyped `?? processCwd` used only by config discovery. A decoy `.c11/agents.json` near the app cwd could otherwise silently configure an unrelated project launch.

#### 3. Clarify entry-point ownership

The ticket context names both `v2AgentLaunch` and `defaultAgentLaunch`, while the non-goal excludes changing the “A-button/default-agent entry point beyond shared helper reuse.” That wording is ambiguous enough to produce a partial fix. Shared-helper reuse is the desired change, but the plan should enumerate which callers must adopt it now:

- `agent.launch` / `v2AgentLaunch`;
- `default-agent launch` new-surface behavior;
- `default-agent launch --in-surface`, whose effective cwd semantics differ because it may not create a surface;
- `Workspace.launchAgentSurface` for the A-button/picker lineage, if it is intended to share the invariant.

The cleanest long-term mutation is to make legacy/default-agent launch an adapter into the same preparation pipeline as `agent.launch`, guarded by parity tests for its existing response and prompt behavior. If that is too much for C11-195, name a follow-up and state exactly which paths remain outside the guarantee. Do not leave the scope implicit.

#### 4. Test the composed behavior, not the file walker

The proposed scratch-backed test is necessary but too close to the lookup implementation. A stronger pure seam would accept a cwd resolution plus injected user/process fallbacks and return a preparation. The test should place:

- a sentinel project config under the resolved root/surface path;
- a conflicting decoy config under the process fallback;
- a distinct user default.

Then assert that the resulting launch command or environment contains the project sentinel, that the preparation's terminal cwd equals the config search origin, and that the decoy never wins. Add matrix rows for explicit cwd, workspace root, launching surface, and no usable path. This validates observable launch planning, not merely that one checked-in method was called.

Because the in-flight C11-194 work recently required a correction for background callers, include a row where the caller surface belongs to a background workspace different from the selected workspace. C11-195 should prove that the same caller-owned resolution drives both configuration and execution.

#### 5. Turn runtime validation into a two-signal proof

“Reports the expected cwd and uses the project-level agent configuration” should specify independent observations. In a tagged QA build backed by scratch data:

- make the project config contribute a harmless, unique command or environment sentinel;
- launch from a surface path and from a workspace root path;
- observe the returned `cwd`/`cwd_source` and the new surface's actual `pwd`;
- observe the sentinel in the composed command, child environment, or screen output;
- keep a conflicting config at the app-process fallback to prove it was not selected.

This demonstrates both halves of the invariant. A response that merely echoes a planned cwd is not proof that the PTY started there, and a found config is not proof that it governed the launched agent.

### Mutations and Wild Ideas

#### Launch explain mode

Add a future `c11 launch-agent --explain` or `agent.launch.prepare` dry run that returns the effective cwd, provenance, discovered config path, chosen harness/model/effort, warnings, and a redacted command without creating a surface. The launch bug existed because resolution was silent; an explain path makes this class of problem operator-debuggable before mutation. It should call the exact same preparation code as a real launch, not a diagnostic reimplementation.

#### A durable launch receipt

Attach a small immutable receipt to each agent surface: cwd, cwd source, project-config path plus content hash, caller surface, launch source, and timestamp. Exclude prompts, secrets, and raw environment values. This would let resume and bug reports answer “why did this agent launch this way?” even after focus, workspace state, or config files change.

The receipt could later power `c11 inspect-launch --surface …`, tagged runtime assertions, and safe fleet auditing. A config hash also distinguishes “the launch was wrong” from “the project config changed after launch.”

#### Configuration as a traced policy stack

Today the effective result combines request fields, project config, user defaults, and factory behavior, but the explanation is mostly implicit. C11-195 could be the seed of a traced policy stack where each resolved field carries its source. This is especially valuable for saved-config overlays and project defaults: the operator can see that cwd came from the workspace root while model came from `.c11/agents.json` and effort came from user settings.

This should remain an internal trace first. A broad UI is unnecessary for this ticket; an API/debug representation is enough to validate the model before productizing it.

#### Trust-aware project configuration

Once project config origin is explicit, c11 can eventually distinguish configuration loaded from the intended workspace tree from configuration inherited from an unexpected ancestor. That opens a future trust policy or warning without changing current precedence. The important mutation now is retaining origin; trust UX can wait.

### What It Unlocks

- **Deterministic agent dispatch.** The command, model, environment, warnings, and PTY cwd all derive from one snapshot.
- **Reproducible bug reports.** A launch receipt or explain output can recreate why a launch chose a configuration without relying on current focus or current files.
- **Safer policy composition.** C11-193's worktree warning and C11-195's project lookup can share the same provenance rather than infer intent separately.
- **Honest background orchestration.** Caller-owned context remains stable even when the selected workspace changes between planning and commit.
- **Portable project behavior.** Teams can rely on `.c11/agents.json` as code-native project configuration instead of a best-effort overlay that only works when the app happens to have a favorable cwd.
- **A migration path away from duplicate launchers.** Legacy, A-button, picker, and v2 launch paths can become adapters around one composer while preserving their UI-specific behavior.

### Sequencing and Compounding

The strongest order is:

1. **Make two binding decisions first:** define no-context fallback behavior and enumerate the entry points covered by C11-195.
2. **Finish C11-194's revised resolver contract:** one normalized path plus provenance, including the operator's updated warning-not-refusal semantics. C11-195 should consume the final interface, not patch the stale hard-refusal shape currently visible on the branch.
3. **Add the pure preparation seam and matrix tests:** establish the equality invariant before touching production callers. Include the process-cwd decoy and background-caller case.
4. **Migrate `agent.launch`:** use one frozen preparation for config lookup, worktree policy, surface creation, and response. Keep disk/git work off-main and main-actor mutation bounded.
5. **Migrate or explicitly defer the legacy/A-button paths:** parity-test each adapter so prompt delivery, focus behavior, launch stats, and saved-config overlays do not regress.
6. **Run the tagged scratch validation:** prove actual PTY cwd and actual project sentinel for surface-inherited and workspace-root launches, plus the no-context decision.
7. **Record immutable evidence on C11-195 and PR #407:** pin the tested head and distinguish logic proof from observed tagged-app proof.
8. **Only then consider explain/receipt work:** the foundation should ship in C11-195; productized diagnostics can be a follow-up.

This ordering does slightly more design work before implementation but less total work: every later consumer reuses the context instead of reopening cwd semantics.

### The Flywheel

The current plan fixes a silent failure but does not create a feedback loop. A small provenance seam can:

1. Projects encode their intended agent setup in `.c11/agents.json`.
2. A single resolver makes launches predictable, so operators trust and use project configuration more often.
3. Explain output or launch receipts reveal real edge cases with exact sources rather than anecdotes.
4. Those receipts become deterministic matrix fixtures and tagged scenarios.
5. Better coverage makes the shared launcher safer to adopt across A-button, picker, legacy CLI, and orchestration paths.
6. Broader adoption produces more high-quality evidence, strengthening the resolver again.

The accelerant is not telemetry volume; it is **explainable provenance**. Without it, failures remain “wrong agent launched somewhere.” With it, each failure arrives already decomposed into cwd source, config source, and committed surface state.

### Concrete Suggestions

1. Replace steps 1 and 2 with the explicit equality invariant above and make the no-path policy binding.
2. Have C11-194 expose a frozen `AgentLaunchWorkingDirectoryResolution`; have C11-195 wrap it with loaded configuration into `PreparedAgentLaunch` rather than passing a loose `String?` among callers.
3. Preserve the discovered config URL internally. It costs almost nothing during the existing filesystem walk and enables tests, debugging, receipts, and future trust policy.
4. Change the scratch test to assert the composed launch sentinel and terminal working-directory value together. Include a decoy process-cwd config and a no-path row.
5. Add a background-caller/selected-workspace mismatch case because caller attribution is part of correct config ownership, not just cwd selection.
6. Rewrite the non-goal to list covered and deferred entry points. At minimum, do not describe `defaultAgentLaunch` as out of scope while the ticket cites its process-cwd bug.
7. Make the tagged test observe the child with `pwd` and a harmless project-config sentinel. Record the response envelope separately as planning evidence.
8. Add `project_config_source` or a redacted `project_config_path` to debug/runtime evidence now if API compatibility permits; otherwise retain it internally for a follow-up `--explain` command.
9. Keep the immediate PR bounded: context object, adapters, tests, and evidence now; launch inspector/UI/trust policy later.

### Questions for the Plan Author

1. When explicit cwd, workspace root, and launching-surface cwd are all absent, should c11 intentionally load any project config at all? If yes, what exact directory will the child use, and can that same value become a named resolution source?
2. Is C11-195 required to fix both cited sites (`v2AgentLaunch` and `defaultAgentLaunch`), or only the v2 path? Which A-button/picker paths are guaranteed equivalent after this ticket?
3. Does “pass that same resolved path” mean the exact frozen value, or is a downstream helper allowed to re-resolve from then-current focus/workspace state? The latter should be prohibited.
4. Can project-config discovery return its source path alongside the decoded value so tests and diagnostics can explain the choice without exposing file contents?
5. Should `default-agent launch --in-surface` use the caller surface's live cwd for config selection when `--cwd` is absent, or preserve its current target-surface semantics? This deserves an explicit rule because no new PTY cwd is established.
6. What is the binding runtime matrix: explicit cwd, workspace root, launching surface, no-context fallback, and background caller? Which rows must be observed rather than inferred from tests?
7. Is the current C11-194 API considered stable after its reset and warning-policy revision, or should C11-195 wait for a new exact head before implementation begins?
8. May the launch response expose config provenance now, or should that remain internal until an `--explain` surface is designed?
9. What compatibility behavior must remain identical when legacy/default-agent launch becomes an adapter: focus, prompts, saved-config overlays, stats attribution, warnings, and response text?
10. Should project config be snapshotted for the whole prepare/commit transaction so edits after preparation affect only future launches? That is the cleanest deterministic rule.
