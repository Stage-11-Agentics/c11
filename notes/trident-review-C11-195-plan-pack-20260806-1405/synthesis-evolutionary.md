# Evolutionary Review Synthesis — C11-195 Plan

Sources: `evolutionary-claude.md`, `evolutionary-codex.md`, `evolutionary-gemini.md`
Plan under review: `.lattice/plans/task_01KZBZY4WBCMG252XSJPJC1CPA.md` (C11-195, launch-agent cwd config lookup)
Synthesized: 2026-08-06. Read-only review; this file is the only artifact written.

---

## Executive Summary

All three models converge on the same verdict with unusual force: **C11-195 as written fixes one call site, and the version worth building fixes the bug class.** The plan treats "resolved launch cwd" as a value to pass along; all three reviewers argue it must become a *type* that is the only way to ask the question, carried immutably from resolution through config lookup, child cwd, policy checks, and the response envelope.

Four points of unanimous agreement:

1. **Pass the resolution object, not a `String?`.** Claude calls it `find(for: AgentLaunchWorkingDirectoryResolution)` with the raw-string overload deleted; Codex calls it `PreparedAgentLaunch`; Gemini calls it "context-aware resolution object." Same idea, three names. This is the single highest-leverage change identified.
2. **The upward walk needs a stop point.** `find(from:)` walks up to 64 levels toward `/`. Moving the start point silently changes which ancestors are reachable. All three want the walk clamped at the workspace root. Claude names the specific hazard: `~/.c11/agents.json` is a real file on this machine and is the exact artifact behind the historical A-button pin bug.
3. **Expose where the config came from.** `config_source` (Claude) / `project_config_source` (Codex) / `source_config_path` (Gemini). The bug's defining property was silence; this converts the class into a one-command diagnosis and gives step 4 an oracle it currently lacks.
4. **The proposed test does not bind the bug.** It re-proves the walker, which `c11Tests/DefaultAgentConfigTests.swift:343-383` already covers. What binds it is a *negative* test with a decoy config at the process cwd.

Beyond consensus, two findings are near-blocking and only one model each caught them:

- **Claude:** the branch's resolver still `.reject(...)`s inherited linked-worktree cwd while C11-193 rev 3 is a binding operator decision to warn-and-proceed. Since every lattice-orchestrator delegator runs in a linked worktree, **step 4's validation cannot pass in the delegator's own environment** until C11-193's flip lands. Also: the plan reads as if steps 1 and 2 are unstarted, but they are already done on `fix/C11-193-launch-agent-cwd`. Rebase the plan or an implementer will re-litigate landed work.
- **Codex:** the branch has a live contradiction in the nil case: `lookupCwd = cwdResolution.path ?? FileManager.default.currentDirectoryPath` while terminal creation receives `cwdResolution.path`. When the path is nil, config lookup and execution diverge, which is the original bug preserved in the fallback branch.

And one framing only Gemini raised, which is arguably the largest long-term question in the pack: **automatic, silent ingestion of `.c11/agents.json` from a cloned repository is a supply-chain surface.** This ticket is where a workspace-trust boundary would naturally live.

Bottom line: roughly a day of extra work (typed lookup + `config_source` + clamp decision + negative test) converts a two-call-site patch into a durable rail. Three independent models arrived at that same estimate of the trade.

---

## 1. Consensus Direction

Ranked by strength of agreement.

| # | Direction | Claude | Codex | Gemini |
|---|---|---|---|---|
| 1.1 | Replace the `String?` lookup with a typed, frozen resolution/context object | M1 | §1, PreparedAgentLaunch | HCIBB #2 |
| 1.2 | Clamp the ancestor walk at the workspace root | §2 | via trust framing | HCIBB #1 + signature |
| 1.3 | Surface the winning config's path in the response / diagnostics | M2 | Suggestion 8 | HCIBB #3, Suggestion 2 |
| 1.4 | Test the composed wiring with a decoy, not the file walker | §3 | §4 | (not raised) |
| 1.5 | Ship an `explain` / dry-run launch path | M3 | Launch explain mode | (implied) |
| 1.6 | Resolve entry-point scope ambiguity (`defaultAgentLaunch`, A button) | §1, Q1 | §3, Q2 | (not raised) |
| 1.7 | Flywheel runs on explainable provenance, not telemetry volume | The Flywheel | The Flywheel | Configuration Flywheel |

### 1.1 The real deliverable is launch-context custody

Every reviewer independently reframed the ticket the same way. Claude: "convert 'resolved launch cwd' from a local variable into a type that is the only way to ask the question." Codex: "a compiler from mutable runtime state into an immutable launch decision." Gemini: "spatial configuration," the agent as a spatially aware entity.

The operational form all three want in the plan is an acceptance invariant. Codex states it most precisely:

> For every new-surface agent launch, one resolution `R` is captured before mutation. Project-config discovery starts at `R.path`, the terminal's requested working directory is `R.path`, and the response reports `R.path` plus `R.source`. No downstream consumer re-resolves cwd.

Claude's supporting evidence is the call-site inventory: **five production callers of `find(from:)`, three different fallbacks (process cwd, `$HOME`, focused-panel directory), and the branch fixes exactly one.**

| Site | Starting path | Fallback |
|---|---|---|
| `SocketDispatch.swift:1075` (`v2AgentLaunch`) | `cwdResolution.path` (fixed on branch) | process cwd |
| `TerminalController.swift:9076` (`defaultAgentLaunch`) | `cwdArg` | process cwd, untouched on branch |
| `Workspace.swift:12448` (`launchAgentSurface`, A button) | `resolverCwdForAgentLaunch()` | panel dir → workspace `currentDirectory` → process cwd |
| `AppDelegate.swift:6764` (workspace-creation launch) | `workingDirectory` | none |
| `GhosttyTerminalView.swift:3557` (env stamp) | `workingDirectory` | `$HOME` |

Codex reaches the same conclusion from the other end: "These are not three isolated bugs. They are three manifestations of missing launch context custody."

### 1.2 The walk's stop point is an unstated behavior change

The plan's non-goal says it will not change "project-config precedence." All three note that the *walk bound* is not precedence, and it is being changed implicitly by moving the start point.

- Gemini frames it as leakage: "Walking blindly all the way to `/` or `~` risks leaking configurations from generic parent directories into isolated workspaces."
- Claude names the concrete artifact: under `~/Projects/Stage11/code/c11/…` the walk passes `~/Projects/Stage11/code/`, `~/Projects/Stage11/`, and `~/`. `~/.c11/agents.json` exists on this machine and is the file the decoder at `DefaultAgentConfig.swift:305` was written to reject.
- Codex frames it as trust: retain the config's origin now so a trust policy is possible later.

Claude's framing of the decision is the one to adopt: either "walk semantics unchanged, ancestor reachability shift accepted" with a test pinning it, or "walk clamps at workspace root when one exists." **Silent is the one unacceptable answer.**

### 1.3 A new divergence this arc creates

Claude alone spotted it, and it is worth elevating to consensus status because it undercuts the arc's premise. After C11-194 lands, `resolverCwdForAgentLaunch()` (the A button) reads the focused panel's directory and **never consults `workspace.rootDirectory`**. So a workspace with an explicit root will resolve project config from the *root* via the CLI and from the *shell's wandered cwd* via the A button. That is a new inconsistency, in the surface the operator uses most, introduced by the very arc meant to unify resolution. Codex asks the same thing from the scope angle (Q2: "Which A-button/picker paths are guaranteed equivalent after this ticket?").

---

## 2. Best Concrete Suggestions

Ranked by leverage-per-line, with attribution.

1. **Change the lookup signature to take the resolution type and delete the `String?` entry point.** (Claude M1; Codex §1; Gemini HCIBB #2.) Five mechanical call-site edits. Call site number six then costs a compile error instead of a bug report. Cheapest permanent fix in the arc.

2. **Add `config_source` to the `agent.launch` response**, next to the existing `cwd` and `cwd_source`. (Claude M2; Codex #8; Gemini #2.) Do it *before* validation, not after: it is what turns step 4 from a squint into a one-line assertion. Carries doc obligations: `docs/socket-api-reference.md`, `docs/launch-agent-reference.md`, `skills/c11/references/api.md`, then `scripts/sync-installed-skills.sh c11` per the repo hard rule.

3. **Add the boundary parameter to `find`.** (Gemini, with the only concrete signature in the pack.)
   ```swift
   static func find(
       from cwd: String?,
       stoppingAt workspaceRoot: String? = nil,
       fileManager: FileManager = .default
   ) -> DefaultAgentConfig?
   ```
   Note this composes with suggestion 1 rather than competing: the resolution object can carry both start and clamp.

4. **Rewrite the test as positive plus negative, against a pure seam, in `c11LogicTests`.** (Claude §3; Codex §4.) The negative case is the one that binds the bug: seed a valid `.c11/agents.json` at the *process cwd* and none in the resolved path's tree, then assert the process-cwd config is **not** applied. The positive-only test would have passed under the buggy code whenever the two paths coincided. Claude adds a target argument worth heeding: putting it in `c11LogicTests` forces the seam to be host-free, so the right test target and the right architecture are the same decision.

5. **Add matrix rows the plan currently lacks.** (Codex §4, §5.) Explicit cwd / workspace root / launching surface / no usable path / **background caller whose surface belongs to a different workspace than the selected one**. The last row matters because C11-194's in-flight work already needed a correction for background callers; caller attribution is part of correct config ownership, not just cwd selection.

6. **Decide the no-context (nil path) policy explicitly.** (Codex §2.) Recommended: no effective launch cwd means no project config lookup, terminal keeps ordinary nil-cwd behavior, user default applies. Compatibility alternative: promote the fallback into a named resolution source (`.processFallback`) used by *all three* consumers. What must not survive is an untyped `?? processCwd` used only by config discovery.

7. **Put `rootDirectory` at the front of `resolverCwdForAgentLaunch()`'s ladder.** (Claude #6.) One line. If genuinely out of scope, file it before merging, because it is a regression this arc creates.

8. **Preserve the discovered config URL internally regardless of whether it is exposed.** (Codex #3.) It costs almost nothing during the walk that is already happening, and it is the precondition for tests, diagnostics, receipts, and any future trust policy.

9. **Stop silently swallowing parse errors.** (Gemini #3, unique to Gemini.) The plan notes "Parse failures are silently swallowed" as existing behavior and moves on. A malformed `agents.json` that silently does nothing is a brutal debugging experience, and it becomes *more* likely the moment project configs actually start being applied. Surface it as a non-fatal warning in launch output or diagnostics.

10. **Enumerate all five call sites in step 1 with an explicit disposition each: fix / defer-with-ticket / verified-correct.** (Claude #1; Codex #6.) Both models flag the same specific trap: the ticket text names `defaultAgentLaunch` as carrying the bug while the non-goal line reads as excluding it. Codex: "do not describe `defaultAgentLaunch` as out of scope while the ticket cites its process-cwd bug." Silence about a site is how a ticket closes green half-fixed.

11. **Make tagged validation a two-signal proof.** (Codex §5; Claude #7.) Observe the child's actual `pwd` *and* a unique sentinel contributed by the project config, with a conflicting decoy config left at the process fallback. A response echoing a planned cwd is not proof the PTY started there; a found config is not proof it governed the launch.

12. **Name a validation environment that is not a linked worktree, or gate on C11-193's warn-only flip.** (Claude, sequencing hazard.) See section 5, question 6.

---

## 3. Wildest Mutations

Ordered roughly by ambition. All are out of scope for C11-195 itself; the value is in deciding which ones the seam should be shaped to accommodate.

1. **Workspace trust boundary for `.c11/agents.json`.** (Gemini, the boldest idea in the pack.) Cloning a repo and launching an agent inside it currently loads that repo's agent configuration silently: model, system prompt, potentially tool configuration. This is the VS Code Workspace Trust problem, arriving in c11. Gemini argues C11-195 is the exact right place to introduce untrusted-workspace consent, because it is the ticket that makes project config actually load. Codex reaches the same destination more conservatively: retain config origin now, defer trust UX. **The cheap move today is Codex's: keep the origin. The expensive-but-important move is Gemini's gate.** Worth a named decision either way, because the flywheel in section 4 is explicitly a plan to get more people committing these files to public repos.

2. **Cascading / merged configurations instead of first-match-wins.** (Gemini.) Workspace root sets model and cost limits; a nested microservice directory *appends* architectural instructions to the system prompt. This is a precedence change and the plan's non-goal correctly forbids it for now, but it is the natural end state of spatial configuration and it changes what data model the resolver should return (a merged trace, not a single decoded value).

3. **Sub-project personas in a monorepo.** (Gemini.) The backend directory declares a Rust expert; the frontend declares a React expert; the operator summons the right one by navigating. This is the user-visible payoff that justifies mutations 1 and 2, and it is the clearest articulation in the pack of *why* anyone should care about this bug fix.

4. **Promote the walk into a `ProjectProfileResolver`.** (Claude M4.) `DefaultAgentProjectConfig` and `WorkspaceBlueprintStore` already perform the same bounded upward walk against the same `.c11/` directory. One resolver, one walk, one clamp rule, one cache keyed on workspace root. Halves filesystem work per launch immediately and gives every future project-scoped setting (ports, blueprints, skill pins, sidebar defaults, launch policy) a home that is already correct. Claude's "layer 3" argument: this ticket is quietly the first client of a project-profile resolver that does not exist yet, and naming that out loud changes what "shared helper reuse" means in the non-goals from an afterthought into the deliverable.

5. **A durable launch receipt per surface.** (Codex.) Immutable record of cwd, cwd source, project-config path **plus content hash**, caller surface, launch source, timestamp. Excludes prompts, secrets, raw env. Powers `c11 inspect-launch --surface …`, resume diagnostics, and fleet auditing. The content hash is the sharp bit: it distinguishes "the launch was wrong" from "the config file changed after launch."

6. **Configuration as a traced policy stack.** (Codex.) Every resolved field carries its own source, so the operator can see cwd came from workspace root, model came from `.c11/agents.json`, effort came from user settings. Internal/API representation first; no UI needed to validate the model.

7. **`c11 explain-launch [--cwd X] [--workspace W]`.** (Claude M3; Codex "launch explain mode.") A dry run printing the whole ladder without mutating anything: which rung won, which `.c11/agents.json` files were probed, which matched, the final resolved command. Both models insist it must call the *same* preparation code as a real launch, not a diagnostic reimplementation. Claude's justification is the tightest sentence in the pack: "This ticket exists because a resolution chain was invisible; the durable answer to an invisible chain is a command that prints it."

8. **Stamp provenance into the launched child's environment.** (Claude M6.) Export `C11_LAUNCH_CWD_SOURCE` and `C11_PROJECT_CONFIG_PATH` at spawn (the env-stamping site already exists at `GhosttyTerminalView.swift:3557`). The agent then *knows* where it was launched from and can report it in its own sidebar line. Turns provenance from a debug field into something an agent can act on: a delegator that notices it inherited a linked-worktree cwd and says so in its first line.

9. **Watch `<root>/.c11/` and hot-apply.** (Claude M5.) Once discovery is root-anchored, an FSEvents watch is roughly 30 lines on top of mutation 4. Edit `agents.json`, next A-button click reflects it, sidebar toast confirms.

10. **Negative-space telemetry.** (Claude M7.) Record cheaply and off-main when a project config *would* have been found under a different rung than the one that won. That single counter would have surfaced this bug in its first week instead of during a plan review. It generalizes to the whole family of silent-resolution defects.

**Named anti-mutation, flagged so it gets rejected deliberately:** falling back to the git toplevel of the resolved path when no `.c11/` is found. (Claude.) Tempting, plausible, and a silent precedence change for every existing user. The plan's non-goal already forbids it. Keep it forbidden.

---

## 4. Flywheel Opportunities

All three models found a flywheel, and they are three views of the same wheel.

1. **The adoption flywheel** (Gemini, cleanest statement). Spatial configs resolve correctly → more teams commit `.c11/agents.json` → more cloned repos arrive pre-configured → out-of-box experience improves for everyone → less config friction → better agent interactions → teams invest further in their config files and advocate for them. Claude's version of the payoff: today `.c11/agents.json` only works if you pass `--cwd`, so effectively nobody relies on it; after this, "check in your `.c11/agents.json`" becomes a legitimate team convention rather than a trap.

2. **The provenance flywheel** (Codex, most mechanically specific). Projects encode intent → a single resolver makes launches predictable → explain output and receipts reveal real edge cases with exact sources instead of anecdotes → those receipts become deterministic matrix fixtures and tagged scenarios → better coverage makes the shared launcher safe to adopt across A-button, picker, legacy CLI, and orchestration paths → broader adoption produces more high-quality evidence. Codex's key insight: **the accelerant is not telemetry volume, it is explainable provenance.** Without it, failures stay "wrong agent launched somewhere." With it, every failure arrives pre-decomposed into cwd source, config source, and committed surface state.

3. **The type-safety flywheel** (Claude, most immediately actionable). *Type forces correctness → response field makes it observable → `explain-launch` makes it diagnosable → the next project-scoped setting rides the same rail for free.* Claude's sharp observation is that **the loop currently runs backwards**: every new launch entry point costs a fresh bug (five sites, three fallbacks, two wrong), each found by a human reading code during a plan review. Flip it and every new entry point costs a compile error caught in seconds. The accelerant is M1 plus M2 together, roughly a day of work.

4. **The platform-namespace flywheel** (Claude, longest arc). Once `.c11/` under a workspace root has a working resolver, it becomes the obvious home for blueprints, port policy, launch defaults, and sidebar config. Each new tenant makes the namespace more valuable and the resolver more load-bearing. That is a platform seam rather than a setting.

**Flywheel risk, worth stating plainly:** flywheels 1 and 4 are explicitly plans to get more executable configuration committed into more repositories, including public ones. That is exactly the condition under which Gemini's trust-boundary concern (mutation 1) stops being theoretical. The flywheel and the security question are the same question viewed from opposite ends.

---

## 5. Strategic Questions for the Plan Author

Deduplicated across all three reviews, ordered by decision urgency. Attribution in parentheses.

**Blocking or near-blocking**

1. **Is `defaultAgentLaunch` (`TerminalController.swift:9076`) in scope?** The ticket names it, the non-goal line can be read as excluding it, and the branch does not fix it. One of those three has to change. (Claude Q1, Codex Q2)

2. **Should the upward walk clamp at the workspace root when one exists?** This is the highest-consequence unstated decision in the plan, and it is a behavior change either way once the start point moves. Was the reachability of `~/.c11/agents.json`, the legacy A-button-pin file, considered and accepted? (Claude Q2, Gemini Q1)

3. **When explicit cwd, workspace root, and launching-surface cwd are all absent, should c11 load any project config at all?** If yes, what exact directory does the child use, and can that same value become a named resolution source consumed by all three downstream readers? The branch currently has lookup falling back to process cwd while terminal creation receives nil, which preserves the original divergence in the fallback case. (Codex Q1)

4. **What is the validation environment for step 4**, given the branch's resolver currently *rejects* inherited linked-worktree launches and every lattice-orchestrator delegator runs inside one? Does C11-193's warn-only flip land before C11-195's validation, or does step 4 name a non-worktree environment? (Claude Q6)

5. **Is the C11-194 API considered stable after its reset and warning-policy revision**, or should C11-195 wait on a specific new head? Relatedly: the plan reads as if steps 1 and 2 are unstarted, but `SocketDispatch.swift` already passes `cwdResolution.path` and the response already carries `cwd`/`cwd_source`. Will the plan be rebased against the branch? (Codex Q7, Claude sequencing)

**Design shape**

6. **Is there appetite for the resolution-typed lookup in this ticket, or is it a follow-up?** It is the difference between fixing this bug and ending this bug class, and it is cheaper now than after call site six exists. (Claude Q7, Codex Q2/Q3, Gemini HCIBB #2)

7. **Does "pass that same resolved path" mean the exact frozen value**, or may a downstream helper re-resolve from then-current focus/workspace state? The latter should be explicitly prohibited in the plan text. (Codex Q3)

8. **Should the A button (`resolverCwdForAgentLaunch()`) consult `rootDirectory`?** If not, is CLI/A-button divergence inside a rooted workspace an accepted outcome of this arc? (Claude Q3)

9. **How should `default-agent launch --in-surface` behave?** Its effective-cwd semantics differ because it may not create a surface and establishes no new PTY cwd. Caller surface's live cwd, or preserve current target-surface semantics? Deserves an explicit rule. (Codex Q5)

10. **Should project config be snapshotted for the whole prepare/commit transaction**, so edits landing mid-launch affect only future launches? That is the cleanest deterministic rule. (Codex Q10)

**Observability and API**

11. **Will `config_source` be added to the launch response now, or held internal until an `--explain` surface is designed?** If not exposed, how does step 4 distinguish "project config applied" from "user default happened to match"? Note that exposing it makes this ticket carry a documented API addition plus a skill sync. (Claude Q4, Codex Q4/Q8, Gemini Q4)

12. **Should `.c11/agents.json` parse failures continue to be swallowed silently?** Applying project configs far more often makes malformed-file confusion far more likely. (Gemini Q5)

**Testing**

13. **Where does the new test live: `c11LogicTests` (fast, requires the seam) or `c11Tests` (host-bound, matches the existing file)?** Repo testing policy points at the first; the plan says "logic test" while the existing coverage sits in the second. (Claude Q5)

14. **What is the binding runtime matrix, and which rows must be *observed* in a tagged build rather than inferred from unit tests?** Candidate rows: explicit cwd, workspace root, launching surface, no-context fallback, background caller with a workspace mismatch. (Codex Q6)

**Scope and arc**

15. **What compatibility behavior must remain identical** if legacy/default-agent launch becomes an adapter over the shared preparation: focus, prompt delivery, saved-config overlays, launch-stats attribution, warnings, response text? (Codex Q9)

16. **Is silent ingestion of `.c11/agents.json` from a cloned, untrusted repository acceptable?** Does this plan need a workspace-trust gate, or at minimum a decision recorded that the risk is accepted for now? (Gemini Q2)

17. **Merge versus override:** is first-match-wins the intended permanent semantic, or is there a future where a global model preference merges with a project-specific system prompt? The answer determines whether the resolver should return a decoded value or a traced stack. (Gemini Q3, Codex traced-policy-stack)

18. **Do you want `.c11/` to become the general project-profile namespace** (agents, blueprints, ports, launch policy) behind one resolver? If yes, C11-195 should be built as its first client rather than a standalone patch. Small change to how step 1 is written, large change to what it is worth. (Claude Q8)

---

## Appendix: Divergences Between Reviewers

Where the models did not agree, and it matters:

1. **Security posture.** Gemini treats untrusted-repo config ingestion as a first-class concern warranting a consent gate in this ticket. Codex treats it as a later trust policy for which only the *origin data* need be preserved now. Claude does not raise it at all. Gemini's concern is the one the flywheel makes urgent; Codex's sequencing is the one that ships.

2. **Precedence changes.** Gemini floats cascading/merged configs as an attractive mutation. Claude explicitly names a related precedence change (git-toplevel fallback) as an *anti*-mutation to reject on purpose. Both cannot be right about the appetite for touching precedence in this arc; the plan's non-goal currently sides with Claude.

3. **Depth on entry points.** Claude and Codex both spent significant effort on the call-site inventory and the `defaultAgentLaunch` scope ambiguity. Gemini did not address it. If only one section of this synthesis is acted on, sections 2.10 and question 1 are where two of three reviewers independently landed hardest.

4. **Awareness of branch state.** Only Claude and Codex read the in-flight `fix/C11-193-launch-agent-cwd` branch and caught that the plan is stale relative to it. Both of the near-blocking findings in the executive summary come from that reading, which suggests the plan should be rebased against the branch before implementation regardless of any other change adopted here.
