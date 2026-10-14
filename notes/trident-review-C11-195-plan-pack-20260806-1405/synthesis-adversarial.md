# Adversarial Review Synthesis: C11-195 Plan

**Sources:** `adversarial-claude.md`, `adversarial-codex.md`, `adversarial-gemini.md`
**Plan under review:** `.lattice/plans/task_01KZBZY4WBCMG252XSJPJC1CPA.md` (C11-195)
**Synthesized:** 2026-08-06

---

## Executive Summary

Three independent adversarial reviewers converged on the same verdict: **the plan needs revision before implementation.** Codex states it formally (`VERDICT: NEEDS REVISION`); Claude rates concern "high, but not for the reasons the plan anticipates"; Gemini calls the solution "built on a shaky dependency" with an unexamined trust model.

The convergence is unusually tight. All three reviewers, working independently, identified the same three top-line problems:

1. **The process-cwd fallback should be deleted, not re-plumbed.** All three reviewers independently reached the identical conclusion: when no explicit, workspace-root, or launching-surface path exists, the correct move is to pass `nil` and skip project-config discovery entirely. The plan's step 1 preserves the fallback. All three call this a default masquerading as a decision, and Codex names it precisely: "the proposed process fallback preserves the root cause under a rarer label."

2. **`.c11/agents.json` is executable configuration and the plan is silent on trust.** The file carries `command` and `envOverridesText`. After this fix, discovery becomes live on the rail explicitly designed to point at trees the operator did not author (worktrees, clones). All three reviewers flag this as a code-execution boundary the plan does not acknowledge. Gemini calls it the single biggest issue; Claude calls it the moment the question becomes load-bearing; Codex classifies it as "a code-execution boundary, not merely a cosmetic default."

3. **C11-194 is not a stable foundation.** It was completed and then reset on 2026-08-06, the same day this plan was written. All three tickets share one branch behind one PR (#407), which still carries C11-193's *superseded* refusal semantics. All three reviewers reject "C11-194 must land first" as a non-actionable gate, and two (Claude, Gemini) argue the standalone fix is a one-liner that need not be coupled to the refactor at all.

Beyond those three, the reviews split into complementary rather than contradictory findings. **Claude's distinctive contribution** is the discovery that most of the plan may already be implemented on the dependency branch (a real zero-line-diff risk), plus the `~/.c11/agents.json` ancestor-walk hazard with documented precedent (PR #217). **Codex's distinctive contribution** is architectural: the demand for an immutable launch-context object with pinned target identity, and the TOCTOU race between context snapshot and surface creation. **Gemini's distinctive contribution** is operational: network-filesystem latency on the socket worker, and the relative-path breakage when config root and launch cwd differ.

The aggregate message: this is framed as a two-line bug fix, but it is a **behavior activation** on a dormant code-execution path, and it is planned with none of the ceremony an activation gets. No blast-radius analysis, no walk boundary, no trust decision, no observability, no changelog, no rollback.

---

## 1. Consensus Risks (Flagged by Multiple Models)

Ordered by severity and by number of models flagging.

### 1.1 The process-cwd fallback is the root cause, not a safety net (3/3)

- **Claude:** "It is not harmless, it is the mechanism by which this bug is invisible in development and live in production... `find(from:)` already handles `nil` and `""` correctly by returning `nil`. **The fallback should be deleted, not re-plumbed.**"
- **Codex:** "If it is used only for `find`, config and child cwd still diverge. If it is also passed into surface creation, a contextless launch is silently moved to the GUI app's arbitrary cwd, the very value this ticket identifies as unsafe. The plan does not choose between those outcomes or justify either one."
- **Gemini:** "The app-process cwd should *never* be used for project config lookup... Searching for a project config starting from the GUI app's root is a logic error treated as a fallback."

**Sharpest framing (Claude):** keeping the fallback preserves the dev/prod behavioral split that hid the bug for months. A dev build launched from a terminal in the checkout inherits a useful cwd; a Finder-launched `/Applications/c11.app` gets `/`. Every future report of "project config did/didn't apply" stays unreproducible across machines.

**If the fallback is kept anyway**, Codex sets the bar: it must become a first-class `.processFallback` resolution source with provenance, passed to every consumer, represented in C11-193's `cwd_source` warning model, exposed in diagnostics, and tested. A hidden `?? FileManager.default.currentDirectoryPath` after the shared resolver is the split-brain pattern the ticket exists to eliminate.

### 1.2 No trust boundary for repository-supplied executable config (3/3)

- **Gemini (headline):** "any `cd` into a malicious downloaded directory followed by a `c11 launch-agent` could silently execute a malicious `command_override`." Proposes a VSCode-style "Trust Workspace" prompt as the concrete remedy.
- **Claude:** "`AgentConfig` carries `command` (the shell line c11 types into a PTY) and `envOverridesText` (environment injected at spawn)... There is no first-use confirmation, no 'this project wants to run X, allow?', no display of the resolved command, and no allowlist. The plan does not mention trust once."
- **Codex:** "Because project config selects executable commands and environment, choosing an unrelated config is a code-execution boundary."

**Nuance from Claude:** the A-button path already has this exposure, so it is not net-new *as a class*. What is new is extending it to the rail explicitly designed to point at other people's trees. That reframes the ask from "add a security feature" to "make a written decision and document it," which is achievable inside this ticket.

**Minimum acceptable outcome (consensus):** a stated, written decision plus a changelog note. Anything less leaves the question undecided in code.

### 1.3 The C11-194 dependency is unstable and the sequencing gate is fictional (3/3)

- **Gemini:** "Dependency Quicksand... C11-194 was reset on 2026-08-06. If C11-195 strictly assumes C11-194's exact resolution interface, it will break or block indefinitely." Names it as the early warning sign: "the underlying shared foundation is not stable enough to build on."
- **Claude:** "There is no 'first.' All three tickets are on one branch behind one open PR... Sequencing language creates a false gate: there is nothing to observe 'landing.'"
- **Codex:** "Saying C11-194 'must land first' is not actionable when C11-194 is reset/in progress and the PR branch already contains an earlier resolver implementation with superseded C11-193 refusal semantics."

**Two reviewers propose decoupling.** Claude: `lookupCwd = cwdOverride ?? nil`, delete the process-cwd fallback, one line, no dependency, independently reviewable. Gemini: `lookupCwd = cwdOverride ?? resolveSurfaceCwd() ?? nil`, without waiting for the grand unified resolver. Both argue the C11-194 dependency buys *better* behavior at the cost of coupling a small correctness fix to a reset, policy-churning ticket on a shared branch.

**Codex's alternative** if the coupling stays: name the exact commit/API gate, and prove before completion that the PR head no longer contains C11-193's superseded refusal behavior.

### 1.4 Scope ambiguity: the non-goal contradicts the ticket (2/3, both emphatic)

The ticket names `TerminalController.defaultAgentLaunch` (line 9074, still `cwdArg ?? processCwd`) as a second occurrence of the bug. The plan's non-goal excludes "the A-button/default-agent entry point beyond shared helper reuse."

- **Claude:** "A reader cannot tell whether `default_agent launch` is in scope. That ambiguity will be resolved by whoever implements it, in the direction of less work."
- **Codex:** "The non-goal excluding the A-button/default-agent entry point 'beyond shared helper reuse' is not a boundary; it is an unresolved contradiction with the ticket context... 'Beyond shared helper reuse' leaves the implementer free to preserve the double resolution and process-cwd lookup."

Both demand the same resolution: fix it here and test it, or explicitly move it to a named follow-up. A vague non-goal is not a scope decision.

### 1.5 The call-site / rail inventory is incomplete (2/3, with different but overlapping maps)

**Claude's map (five `DefaultAgentProjectConfig.find` call sites):**

| Site | Status in plan |
| --- | --- |
| `SocketHandlers/SocketDispatch.swift:1075` (v2 `agent.launch`) | in scope |
| `TerminalController.swift:9076` (v1 `default_agent launch`) | ambiguously scoped |
| `Workspace.swift:12448` (A button, via `resolverCwdForAgentLaunch()`) | excluded |
| `GhosttyTerminalView.swift:3557` (exports `C11_DEFAULT_AGENT_LAUNCH`, falls back to **home directory**) | not mentioned |
| `AppDelegate.swift:6764` (workspace-creation-with-agent) | not mentioned |

**Codex's map (three materially different rails plus a double-resolution defect):**
- `agent.launch` / `config.launch`: plans off-main, creates a new surface.
- `default_agent launch --in-surface`: starts an agent inside an existing PTY, **no surface-creation phase at all**.
- `default_agent launch` without `--in-surface`: resolves once in `TerminalController.defaultAgentLaunch`, then delegates to `Workspace.launchAgentSurface`, **which resolves project config a second time** and creates a terminal without an explicit working directory.

**The shared consequence (Claude):** after this plan, c11 has two competing notions of "the cwd an agent launch is about." A workspace with root `/repo` whose focused panel has `cd`'d to `/other` resolves the A button's config from `/other` and `launch-agent`'s config from `/repo`. Same operator, same workspace, two different agents. Nondeterministic from the operator's point of view, and worse than the bug being fixed.

**Codex's early warning sign for this exact class:** "more than one `DefaultAgentProjectConfig.find` call in agent-launch code."

### 1.6 `--in-surface` has no defined semantics (2/3)

- **Claude:** "On that path the child runs in the **target** surface's cwd (`launchInExistingSurface` composes `cd <cwd> && <launcher>`, and when `cwd` is nil the child simply inherits the target PTY's directory). The C11-194 resolver keys on the **caller** surface and the target *workspace* root. Feeding the resolver's path into the config lookup for `--in-surface` introduces precisely the divergence step 2 claims to eliminate: config from the caller's tree, execution in the target's tree."
- **Codex:** "With no explicit `--cwd`, should config be discovered from the target surface's current cwd, the caller's workspace root, or the caller surface? Should the command omit `cd` while still loading config from the target cwd? The generic new-surface rule does not answer this."

This is the one rail where the plan's own stated invariant ("configuration lookup and the child cwd cannot diverge") is **provably violated** by the proposed mechanism.

### 1.7 Path normalization and symlink divergence (3/3)

- **Gemini:** "`DefaultAgentProjectConfig.find` uses `standardizedFileURL` which resolves `..` but does NOT resolve symlinks to their physical paths. If the workspace is symlinked, config discovery might fail or traverse differently than the shell." Also: "the PTY/shell initialization often does its own physical/logical path resolution."
- **Claude:** "macOS `/tmp` is a symlink to `/private/tmp`. If C11-194's resolver normalizes with `resolvingSymlinksInPath` anywhere (or if the surface reports a realpath'd cwd while the test seeds a `/tmp` path), a scratch-backed assertion can pass or fail for reasons unrelated to the fix."
- **Codex:** "Symlink normalization can also make lexical lookup and physical `pwd` disagree."

Two distinct failure modes here: **runtime divergence** (lexical config walk vs. physical shell `pwd`) and **test flakiness** (scratch fixtures under `/tmp`). Both deserve a sentence in the plan; the runtime one deserves a decision.

### 1.8 The proposed test proves nothing (2/3)

- **Codex:** "`DefaultAgentProjectConfig.find(from:)` already has scratch-backed tests for exact-directory and upward discovery. Another test that merely calls it with a resolved path proves no new behavior. The regression lives in the handoff among context resolution, config loading, launch planning, and surface creation."
- **Claude:** "`DefaultAgentConfigTests.swift` already has five tests of exactly the `find(from:)` shape. Adding a sixth proves nothing new." Plus: the process cwd is read inline inside a 400-line socket handler requiring a live `TabManager` and a main-actor snapshot. **There is no seam to inject it**, and `chdir` is a process-global mutation hostile to a parallel XCTest bundle. Plus: the existing sibling tests live in `c11Tests/` (host-required, `c11-unit`), not `c11LogicTests/`; the plan says "logic test" without naming a target.

**Both propose the same remedy shape:** extract a named pure function (Claude suggests `agentLaunchProjectConfigLookupPath(resolution:) -> String?`), test *that*, and additionally assert the same value reaches surface creation. Codex adds an injected config loader plus a surface-creation recorder.

**Claude adds a gate nobody else names:** require a demonstration that the test **fails without the fix**. For a wiring change this is the only meaningful regression gate, and it is absent.

### 1.9 Threading is unaddressed in a repo that just shipped a main-thread deadlock fix (2/3, plus a Gemini variant)

- **Claude:** "v1 `default_agent` is not in `socketWorkerV1Commands`/`socketWorkerV2Methods`, so `defaultAgentLaunch` runs on the main actor. If 'shared helper reuse' means calling C11-194's resolution path there, that path does a `GitContextResolver` probe, which is subprocess/filesystem git I/O... precisely the shape of C11-200 / the `ghostty_surface_set_display_id` deadlock just fixed in `8c7422b4f`. C11-193's plan has a dedicated step for it (step 6); this one inherits the requirement and drops it."
- **Codex:** "Project-config file I/O must stay off-main for the canonical socket path. Reusing that helper from the main-actor v1 path without a designed boundary can add launch-time UI stalls or deadlock-prone sync hops."
- **Gemini (adjacent):** synchronous directory walking "will fail catastrophically (socket timeouts) if the inherited cwd is on a slow SMB/NFS mount."

### 1.10 The validation oracle is unobservable as written (2/3)

Step 4's stated oracle, "uses the project-level agent configuration," is not checkable by looking at a pane.

- **Claude:** "Name the observable: seed the scratch project's config with a visually distinct `command` (e.g. `echo C11-195-PROJECT-CONFIG`) and screenshot the pane. Otherwise 'validated' means 'the agent launched,' which was already true."
- **Codex:** "Agent type or stamped metadata alone is not proof: an explicit `--type`, user defaults, saved-config overlays, or a second config resolution can yield the same visible result." Demands proof of both the actual child `pwd` **and** the actual fixture-selected command/env.

### 1.11 Docs, changelog, and skill sync are missing (2/3)

- **Claude:** C11-193 (step 9) and C11-194 (step 5) both carry doc and skill-sync steps; C11-195 has none, yet `docs/launch-agent-reference.md` and `skills/c11/references/api.md` are already in PR #407's file list. The repo CLAUDE.md carries a **hard rule** that editing an installable skill is incomplete until `scripts/sync-installed-skills.sh` runs. No CHANGELOG entry for a user-visible behavior change.
- **Codex:** "If C11-194's launch docs describe cwd precedence, they should also say that `.c11/agents.json` discovery uses that exact cwd. If no docs change is intended, the plan should justify that explicitly."

### 1.12 PR #407 is a moving integration vehicle, not evidence (2/3)

- **Codex:** "PR #407 is a moving, shared integration vehicle, not immutable evidence. The plan must record the exact remote head containing all three ticket contracts, show superseded refusal behavior is gone, resolve review findings, and wait for terminal CI. A link alone proves none of that."
- **Claude:** "The C11-195 delta is a handful of lines buried in a 634-line diff. Nobody reviews it independently, nobody validates it independently, and the ticket closes on the parent's evidence." Adds the split/force-rebase hazard: if the PR is split per ticket, C11-195's delta is the one most likely to be dropped because it is the smallest and lives in the middle of the other two's hunks.

---

## 2. Unique Concerns (Single-Model, Worth Investigating)

### From Claude

**2.1 The plan may already be satisfied by existing code (zero-line-diff risk).**
On `origin/fix/C11-193-launch-agent-cwd`, `SocketDispatch.swift` already reads `let lookupCwd = cwdResolution.path ?? FileManager.default.currentDirectoryPath` and already passes `cwdResolution.path` into both `addWorkspace` and `newTerminalSurface`. Steps 1 and 2, for the socket path, are done. The only named site not fixed on the branch is `TerminalController.defaultAgentLaunch`, which the non-goal appears to exclude. **"As written, this ticket can be closed with a zero-line diff and nobody will notice."** Claude names the process smell: the plan was written from the ticket text, not from the branch, and the same three-ticket pack will keep producing that.

*Verification priority: highest. This is cheap to check and invalidates or reshapes most of the plan.*

**2.2 `$HOME/.c11/agents.json` is an ancestor of nearly every launch cwd, with documented precedent.**
`DefaultAgentProjectConfig.find` walks up to **64 levels** with no repo-root and no `$HOME` stop. Today the walk starts at `/` on the affected rails and finds nothing. After the fix it starts at a real path under `$HOME` and will find `~/.c11/agents.json` if one exists. **PR #217 (merged as `6dfeef923`) exists because exactly that file pinned the A button permanently to Claude.** That fix hardened the *decoder* against the legacy array shape; it did nothing about a modern, well-formed `~/.c11/agents.json`, which will now be treated as a project config for every launch under the home directory.

Claude frames the required decision as a four-way choice: stop the walk at a repo/workspace root, stop at `$HOME`, require the file to be below the resolved path's git root, or explicitly accept it and say so.

*Verification priority: highest. This is the change's largest blast radius and the plan does not know the question exists.*

**2.3 No observability for which config won.**
There is no way, from a launch response or from any CLI, to see whether a project config was found and from which path. `c11 default-agent` exposes no read-only `get`/`current`. Every future "why did it launch codex" report requires a maintainer to mentally simulate a 64-level walk from a path the operator cannot see. Claude's assessment: a `project_config_path` field in the `agent.launch` JSON payload plus a warning line when a project config overrides the user default "would make this class of bug self-diagnosing forever. This is the highest-leverage thing missing from the plan and it costs roughly ten lines."

**2.4 Cross-workspace targeting mixes provenance.**
On the branch, `workspaceRoot` comes from the *target* workspace (`v2ResolveWorkspace`) while `launchingSurfaceCwd` comes from `callerWorkspace ?? fallbackWorkspace`. A background caller in workspace A launching into workspace B with no roots set resolves to A's surface cwd, then creates the surface in B's pane with `workingDirectory: <A's cwd>`. The step-2 invariant holds *trivially*, but the combined value is a cross-workspace hybrid nobody chose. No test is proposed for cross-workspace targeting.

**2.5 No negative controls in validation.**
Step 4 validates the positive case only. Missing: no-project-config still uses the user default; malformed `.c11/agents.json` still falls back silently; a config omitting `defaultAgent` does not displace the Settings pick (the `overrideDefaultAgent` invariant from PR #217, put back under load for the first time by this change); and whichever `$HOME` decision is made.

**2.6 No rollback / kill switch.**
If a fleet of operators suddenly gets a different agent on every launch because of a stale home-directory file, the only remedy is a new release. Claude judges an env var or settings toggle probably overkill, but a warning line naming the file that won is not.

**2.7 Step 5 is not a step.**
"Record review and runtime evidence and link PR #407" is bookkeeping. Of five numbered items, two (4 and 5) are process and one (1) is already done upstream. "The actual engineering content of this plan is one and a half lines of Swift plus a test that cannot currently be written."

**2.8 Make the diff self-identifying against a PR split.**
Mitigation for the rebase/split hazard: include the lookup helper as a **named symbol** so its absence is a compile error rather than a silent revert, and reference the ticket in a comment at each changed call site.

### From Codex

**2.9 No immutable launch-context object; TOCTOU between snapshot and creation.**
This is Codex's central architectural demand and the most substantive single addition across all three reviews. "A string named `resolvedPath` is insufficient unless the same immutable context also pins the target workspace/pane. Otherwise a focus or selection change during I/O can produce config from workspace A and a surface in workspace B." The resolved context should carry: normalized path, provenance/source, pinned target window/workspace/pane (or new-workspace intent), and the no-context outcome. Final surface creation must either use that same identity or fail if it disappeared.

**Codex's early warning sign:** "any second call to resolve workspace/pane after the launch-context snapshot." This is observable on the current PR branch, where the initial context snapshot captures cwd inputs but the final commit resolves the target workspace again.

**2.10 Double resolution in the `default_agent` new-surface branch.**
`TerminalController.defaultAgentLaunch` resolves config, then the new-surface branch **discards that resolved launch** and lets `Workspace.launchAgentSurface` resolve again, creating a terminal without an explicit working directory. A test that only exercises `agent.launch` will never see this.

**2.11 `C11_DEFAULT_AGENT_LAUNCH` is recomputed downstream from `workingDirectory ?? HOME`.**
Terminal creation in `GhosttyTerminalView.swift` separately derives this env var. Passing a working-directory string downstream does not make the exported value consistent by itself. Codex demands a test proving the launched command, actual `pwd`, and exported default-launch config all agree. (Claude independently flagged the same site for a different reason: its **home-directory** fallback is the most dangerous possible start for a 64-level upward walk. Together these two observations make `GhosttyTerminalView.swift:3557` the highest-value unexamined site in the tree.)

**2.12 No stale-path policy.**
Workspace roots persist and can be edited; directories move or are deleted. `DefaultAgentProjectConfig.find` does not require the starting directory to exist, while the terminal runtime may reject or fall back from that path. The plan needs a policy for a nonexistent root *before* config discovery and process spawn, covering: missing, is-a-file, unreadable, and symlink-to-a-different-tree.

**2.13 The branch still carries superseded C11-193 refusal policy.**
Rev 3 of the C11-193 plan superseded `.reject(...)` to warn-only, but the branch head still implements refusal. Codex makes "prove the PR head no longer contains the superseded behavior" an explicit completion gate. (Claude notes the same fact as evidence that C11-195 builds on known-stale code.)

**2.14 Explicit-precedence regression risk.**
The precedence ladder is explicit → workspaceRoot → launchingSurface (→ proposed no-context). Tests must assert **explicit beats root** and **root beats surface**, and prove the unrelated process directory is ignored in each case. A change that fixes the fallback can silently reorder the ladder above it.

### From Gemini

**2.15 Network filesystem latency on the socket worker.**
"How does `DefaultAgentProjectConfig.find` behave when the resolved cwd is on a high-latency network file system, given it executes synchronously on the socket worker?" Today the walk starts at `/` and terminates fast. After the fix, a 64-level synchronous walk over SMB/NFS is a plausible socket timeout. Gemini's hindsight line: *"Why did we block the socket worker for 5 seconds when a user launched an agent from a disconnected network drive?"*

*This composes badly with consensus item 1.9 (threading). Nobody else costed the walk itself.*

**2.16 Config root vs. launch cwd misalignment breaks relative paths.**
"If a user is in `/project/deep/subdir` and launches an agent, the config is found at `/project/.c11/agents.json`. The agent launches in `/project/deep/subdir` with the project config applied. If the project config contains paths (templates, scripts) that are relative to the project root, they will break." Gemini asks the design question directly: **should the launch cwd be aligned to the project config root?**

*This is the only review that questions whether "same path for lookup and execution" is even the right invariant. The plan's central invariant may be under-specified rather than merely under-enforced. Worth a decision either way.*

**2.17 VSCode-style Workspace Trust as the named remedy.**
Gemini is the only reviewer to name a concrete, precedented UX pattern for the trust problem rather than describing the gap abstractly. Useful if the trust decision goes beyond "document it."

---

## 3. Assumption Audit (Merged and Deduplicated)

Load-bearing assumptions surfaced across all three reviews, with the reviewers who flagged each and a consolidated confidence read.

| # | Assumption | Flagged by | Load-bearing? | Holds? | Note |
| --- | --- | --- | --- | --- | --- |
| A1 | C11-194's resolver is the natural fix point and "must land first" | Claude, Codex, Gemini | Yes | **Low** | No "first" exists: one branch, one PR. C11-194 reset 2026-08-06. Branch still carries superseded C11-193 refusal policy. |
| A2 | C11-194 will expose one reusable, provenance-carrying resolution with a stable interface | Codex, Gemini | Yes | **Medium/Low** | Plan names no type or API. Current branch has three sources and no process-fallback source. Gemini: may return an enum, not a string. |
| A3 | The app-process cwd is a harmless last-resort fallback | Claude, Codex, Gemini | Yes | **Low, and conceptually wrong** | It is the mechanism that hid the bug. `find(from:)` already handles `nil`. Unanimous: delete it. |
| A4 | The upward walk terminating on the first `.c11/agents.json` is the right semantics once the start path is correct | Claude | Yes | **Unexamined** | 64 levels, no repo-root stop, no `$HOME` stop. `~/.c11/agents.json` is an ancestor of nearly every launch cwd. PR #217 precedent. |
| A5 | One resolved path can serve both "where to look for config" and "where the child runs" | Claude, Codex, Gemini | Yes | **False for `--in-surface`**; questionable generally | Claude: `--in-surface` child runs in the *target*'s cwd, resolver keys on the *caller*. Gemini: config root and launch cwd may need to be aligned, not merely equal to each other. |
| A6 | The resolved target remains the target through the off-main lookup | Codex | Yes | **Low without an explicit guard** | Branch snapshots context, then re-resolves target workspace at commit. Focus change or background caller invalidates it. |
| A7 | Every named entry point can consume the same helper | Codex, Claude | Yes | **Low** | `agent.launch` is socket-worker; `defaultAgentLaunch` is main-actor v1; `--in-surface` has no surface-creation phase; `Workspace.launchAgentSurface` re-resolves. "Shared helper reuse" does not erase lifecycle differences. |
| A8 | A string passed to config lookup and surface creation becomes the same real cwd | Codex, Gemini, Claude | Yes | **Medium** | Lexical `standardizedFileURL` vs. physical shell `pwd`; symlinks not resolved; persisted roots and shell-reported paths can be stale. |
| A9 | The caller's reported cwd is accurate | Claude | Yes | **Often false** | `panelDirectories` is populated by OSC 7 shell integration. Full-screen TUIs that `cd`, shells without integration, remote/ssh surfaces, and stale reports all yield wrong paths. Today that means a mildly wrong child cwd; after the change it also selects a different binary and env. |
| A10 | Synchronous directory walking is safe on the socket worker | Gemini | Yes | **High on NVMe, fails on network FS** | 64-level synchronous walk over SMB/NFS is a socket-timeout candidate. |
| A11 | Project-config I/O can stay off-main while being reused from the main-actor v1 path | Claude, Codex | Yes | **Undesigned** | `default_agent` is not in the socket-worker method sets. `GitContextResolver` is subprocess git I/O. Same shape as the just-fixed `8c7422b4f` deadlock. |
| A12 | A "scratch-backed logic test" is writable for this behavior | Claude, Codex | Yes | **No seam exists today** | Process cwd read inline in a 400-line handler requiring live `TabManager` + main-actor snapshot. `chdir` is process-global and hostile to parallel XCTest. Sibling tests live in `c11Tests` (host-required), not `c11LogicTests`. |
| A13 | One positive test is enough | Codex, Claude | Yes | **Low** | Precedence ladder has four outcomes; both main source paths need coverage; explicit precedence must not regress; no negative controls proposed. |
| A14 | "Uses project-level agent configuration" is observable in a tagged run | Codex, Claude | Yes | **Only with a unique sentinel** | Agent type and stamped metadata are not proof: `--type`, user defaults, saved-config overlays, or a second resolution produce identical visible results. |
| A15 | A workspace root should override a more deeply nested config under the launching-surface cwd | Codex | Secondary | Unstated | Because the child launches at the root. Never written down. |
| A16 | A targeted rootless workspace should inherit from the invoking surface, not the target workspace's focused surface | Codex | Secondary | Unstated | |
| A17 | A missing or closed `caller_surface_id` should degrade to another cwd source rather than fail | Codex | Secondary | Unstated | |
| A18 | Malformed/unreadable project config may continue to fail silently | Codex, Claude | Secondary | **Acceptable today, ambiguous after** | Claude rates the existing silent-swallow as fine; Codex notes it makes runtime evidence ambiguous during validation. |
| A19 | `C11_DEFAULT_AGENT_LAUNCH` stays consistent because a working-directory string is passed downstream | Codex | Secondary | **False** | Recomputed in `GhosttyTerminalView.swift` from `workingDirectory ?? HOME`. |
| A20 | `AgentLaunchPlanner` correctly consumes a non-nil `projectConfig` | Claude | Cosmetic | **Fine** | Well covered by existing tests. |

---

## 4. The Uncomfortable Truths (Recurring Hard Messages)

Ranked by how many reviewers said a version of it and how sharply.

**4.1 This is a feature activation dressed as a bug fix, and it is being shipped with none of a flag flip's ceremony.** (3/3)
Claude states it directly: "no blast-radius analysis, no changelog, no rollout note, no observability, no rollback." Gemini reaches it from the security side: "We are building a feature that dynamically searches for and executes configuration overrides based on whatever directory the user's terminal happens to be in, without any security gating." Codex reaches it from the contract side: the plan "lacks the API contract, call-site map, race policy, fallback semantics, test matrix, and lifecycle gate needed for a bug that can select executable project configuration." Nobody framed it as a feature, so nobody asked the feature questions.

**4.2 The proposed fallback preserves the root cause under a rarer label.** (3/3)
Codex's phrasing is the sharpest. Claude's is the most operational: it keeps the dev/prod split that hid the bug for months, so every future report stays unreproducible across machines. Gemini's is the bluntest: it is "a logic error treated as a fallback."

**4.3 A straightforward variable fix has been tethered to an unstable architectural refactor.** (3/3)
Gemini states it as a truth outright. Claude and Codex reach the same place via the shared-branch analysis. All three note C11-194's same-day reset. Two propose a decoupled one-line fix as the alternative.

**4.4 The plan appears to have been written from the ticket text rather than from the branch.** (2/3, Claude sharpest)
Claude: "A plan written against the branch it depends on should have said 'the socket path is already done on `origin/fix/C11-193-launch-agent-cwd`; the remaining delta is X.' That it does not suggests the plan was written from the ticket text... That is a process smell worth naming because the same three-ticket pack will keep producing it." Codex reaches the same conclusion from the other end: "The open PR already contains a partial version of the desired v2 wiring, but the legacy path still uses the old lookup... Treating PR #407 as a stable dependency would be wishful thinking."

**4.5 If the plan will not own `defaultAgentLaunch`, the ticket overstates what will be fixed.** (2/3)
Codex: "That needs an explicit scope correction or a follow-up ticket, not a vague non-goal." Claude: "The ambiguity will be resolved by whoever implements it, in the direction of less work."

**4.6 A green logic test cannot substitute for observing the launched process.** (2/3)
Codex: "A green logic test cannot substitute for observing the launched process's cwd and fixture-selected command in a tagged app." Claude ties it to the repo's own CLAUDE.md: "a wall of green tests can pass while the shipped path is inert. This bug is itself an instance of that pattern." Repeating the pattern here is easy, because the only end-to-end oracle the plan names is unobservable.

**4.7 Nobody has written down whether c11 trusts repository-supplied launch commands.** (2/3 explicit, 3/3 implied)
Claude: "This ticket is the moment that question becomes load-bearing on the rail explicitly designed to point at other agents' worktrees, and the plan is silent." Gemini's hindsight line: *"Why did we let an arbitrary directory's config override the execution command without a VSCode-style 'Trust Workspace' prompt?"*

**4.8 "Pass the same path" is not enough.** (2/3)
Codex: not enough "when the target workspace can change between lookup and creation and when the runtime may reject a stale path." Claude adds the `--in-surface` case where the invariant is violated by construction. Gemini adds the case where the invariant may be the *wrong* invariant (config root vs. launch cwd).

**4.9 The plan's engineering content is smaller than its step count suggests.** (1/3, Claude, but unrebutted)
"Of five numbered items, two (4 and 5) are process and one (1) is already done upstream. The actual engineering content of this plan is one and a half lines of Swift plus a test that cannot currently be written." Codex's independent verdict: "This is a five-step patch sketch, not an implementation plan."

---

## 5. Consolidated Hard Questions for the Plan Author

Deduplicated across all three reviews (40 raw questions → 24). **[BLOCKING]** marks questions all reviewers or Codex explicitly treat as gating implementation.

### A. Scope and baseline

1. **[BLOCKING]** Have you read `origin/fix/C11-193-launch-agent-cwd`? `SocketDispatch.swift` already has `lookupCwd = cwdResolution.path ?? FileManager.default.currentDirectoryPath` and already passes `cwdResolution.path` to `addWorkspace` and `newTerminalSurface`. **What is the remaining diff for this ticket, in lines?** If the answer is "zero for the socket path," say so in the plan and re-scope. *(Claude Q1)*

2. **[BLOCKING]** Is `TerminalController.defaultAgentLaunch` (line 9074) in scope or not? The ticket names it; the non-goal appears to exclude it. Pick one, in writing. If out of scope, which ticket owns it, and why is C11-195 complete with the bug still present at a site the ticket text cites? *(Claude Q2, Codex Q20)*

3. **[BLOCKING]** Which exact rails are acceptance scope: `agent.launch`, delegated `config.launch`, `default_agent launch --in-surface`, `default_agent launch` new-surface, UI A-button, `AppDelegate` workspace-creation-with-agent, and saved-config launches? Produce the call-site inventory explicitly. *(Codex Q4, Claude Q12)*

4. What happens to the three call sites nobody has scoped? `GhosttyTerminalView.swift:3557` exports `C11_DEFAULT_AGENT_LAUNCH` and falls back to the **home directory**, the most dangerous possible start for a 64-level upward walk. `Workspace.swift:12448` (`resolverCwdForAgentLaunch()`) ignores the new workspace root entirely. After C11-194 lands, the A button and `launch-agent` will resolve config from different places in the same workspace. Acceptable? If yes, why. If no, which ticket fixes it. *(Claude Q12)*

5. How will the `default_agent` new-surface test catch its current **double resolution**, where `TerminalController` resolves one config and `Workspace.launchAgentSurface` resolves another? *(Codex Q11)*

### B. The fallback decision

6. **[BLOCKING]** Why keep the process-cwd fallback at all? `find(from:)` handles `nil`. What correct behavior does the fallback produce that `nil` does not? If the answer is "none," delete it and say the plan deletes it. *(Claude Q3, Gemini Q1, Codex Q1)*

7. **[BLOCKING]** Is the app process cwd an *authorized* launch/config source? If yes, why is an arbitrary GUI-process directory safe to search for executable project configuration? *(Codex Q1)*

8. **[BLOCKING]** Does "that same resolved path" include the process fallback? If yes, where is `.processFallback` represented, and how do C11-193's warning details classify it in `cwd_source`? If no, why is config/child divergence acceptable in that case? *(Codex Q2)*

### C. The walk, trust, and blast radius

9. **[BLOCKING]** What stops the upward walk from reaching `~/.c11/agents.json`? Nothing today. PR #217 (`6dfeef923`) exists because that exact file broke default-agent resolution on this machine. Do you scope the walk to the resolved path's git root, to `$HOME`, to the workspace root, or do you accept it? *(Claude Q4)*

10. **[BLOCKING]** What is the trust model for `.c11/agents.json`? It carries `command` and `envOverridesText`. After this fix, `c11 launch-agent --cwd <cloned-repo>` executes that repo's chosen shell command in the operator's shell with their environment. Is that intended? Documented? Is there a confirmation, an allowlist, or at minimum a warning? *(Claude Q5, Gemini Q2)*

11. Does a project config that omits `defaultAgent` still leave the Settings pick intact? PR #217's `overrideDefaultAgent` invariant is put back under real load for the first time by this change, and no test is proposed for it. *(Claude, negative-controls blind spot)*

### D. Contract and target identity

12. **[BLOCKING]** What exact immutable type does C11-194 hand to C11-195? Does it include **target workspace/pane identity** as well as path and source, or only a path string? *(Codex Q3)*

13. What happens if the target workspace/pane closes, or selection changes, after the context snapshot but before surface creation: fail, re-resolve, or silently retarget? *(Codex Q7)*

14. For an explicit target workspace with no root, does fallback use the caller surface or the target workspace's focused surface? Why? Note the current branch produces a cross-workspace hybrid: caller workspace A's surface cwd used to create a surface in workspace B. *(Codex Q6, Claude blind spot 4)*

15. For `--in-surface` with no `--cwd`, which surface's cwd selects `.c11/agents.json`: the caller's or the target's? The child executes in the target's directory while the resolver knows only the caller and the target workspace root. Should the command issue a `cd` at all? *(Claude Q7, Codex Q5)*

### E. Paths, staleness, and filesystem reality

16. What happens when a persisted workspace root is missing, is a file, becomes unreadable, or resolves through a symlink to a different physical tree? `find` does not require the starting directory to exist; the terminal runtime may reject or fall back from it. *(Codex Q8, Gemini symlink blind spot)*

17. If the terminal is in `/project/src/lib` and the config is found at `/project/.c11/agents.json`, the agent spawns in the subdirectory while the config was authored for the root. Relative paths in that config break. **Should the launch cwd be aligned to the project config root instead?** *(Gemini Q3)*

18. `find(from:)` uses `standardizedFileURL`, which resolves `..` but not symlinks, while the shell reports a physical `pwd`. How do lexical lookup and physical `pwd` stay in agreement at runtime, and how does the scratch test avoid the macOS `/tmp` → `/private/tmp` trap? *(Gemini, Claude blind spot 8, Codex A4)*

19. How does `DefaultAgentProjectConfig.find` behave when the resolved cwd is on a high-latency network filesystem, given a 64-level synchronous walk on the socket worker? *(Gemini Q4)*

### F. Threading

20. **[BLOCKING for the v1 path]** On which thread does the fix run for v1? `default_agent` is not in `socketWorkerV1Commands`/`socketWorkerV2Methods`, so `defaultAgentLaunch` is main-actor. If "shared helper reuse" drags `GitContextResolver` or a main-thread snapshot in there, you are adding git subprocess I/O to the main thread days after `8c7422b4f` fixed a main-thread deadlock. C11-193's plan has a dedicated threading step; this one dropped it. What is the threading design for both rails? *(Claude Q11, Codex Q14)*

### G. Tests and observability

21. **[BLOCKING]** Which test target, and what seam? `DefaultAgentConfigTests.swift` lives in `c11Tests` (host-required), not `c11LogicTests`. How do you inject "a different process fallback" without `chdir`? **Name the pure function you will extract** (e.g. `agentLaunchProjectConfigLookupPath(resolution:) -> String?`), or admit the test is a re-test of `find(from:)` and therefore worthless as a regression gate. *(Claude Q8, Codex Q9)*

22. Will you demonstrate the test **fails without the fix**? For a wiring change this is the only meaningful gate. Add it as an explicit step. *(Claude Q9)*

23. Will tests assert the full precedence ladder (explicit over root, root over surface, rootless surface fallback) and prove the unrelated process directory is ignored in each case? Will they include the negative controls: no config → user default; malformed config → silent fallback; background/non-selected workspace; deleted root; caller surface closed; selection mutated between snapshot and commit? *(Codex Q10 + Q13, Claude blind spot 7)*

24. What is the observable in step 4? "Uses the project-level agent configuration" is not checkable by looking at a pane. State the fixture (a project config with a visibly distinct sentinel command such as `echo C11-195-PROJECT-CONFIG`) and the artifact (screenshot, `read-screen` output, or a `launch-agent --json` field). Must the run prove **both** the actual child `pwd` **and** the fixture-selected command/env, rather than infer success from agent metadata? *(Claude Q10, Codex Q12)*

25. How does an operator find out which config file was used? If the answer is "read the source and simulate a 64-level walk," will you add a `project_config_path` / `config_source` field to the `agent.launch` JSON payload and a warning line when a project config overrides the user default? Roughly ten lines that eliminate the entire future diagnostic class. *(Claude Q6)*

26. Must `C11_DEFAULT_AGENT_LAUNCH` inside the spawned shell reflect the same project config? It is recomputed in `GhosttyTerminalView.swift` from `workingDirectory ?? HOME`. Where is that asserted? *(Codex Q15)*

### H. Delivery, docs, and rollback

27. **[BLOCKING]** Given C11-194 was reset today and C11-193's policy flipped from refuse to warn under it, on what evidence do you claim C11-194 "must land first"? There is one branch and one PR. What observable event constitutes "landed"? What exact commit/API is the prerequisite? What do you do if the resolver signature changes after you consume it? *(Claude Q15, Codex Q16, Gemini Q5)*

28. Before C11-195 is declared done, how will you prove the PR head no longer contains C11-193's superseded refusal behavior? *(Codex Q17)*

29. What are the required local test command, tagged-app tag and QA launch mode, remote-head check, review-resolution gate, and terminal CI jobs? "Link PR #407" proves none of these. *(Codex Q18)*

30. What is the changelog entry and the docs delta? C11-193 and C11-194 both have doc steps; this one has none, and `docs/launch-agent-reference.md` plus `skills/c11/references/api.md` are already touched by PR #407. This repo treats "edited an installable skill without running `scripts/sync-installed-skills.sh`" as a hard-rule violation. Where is that step? If no docs change is intended, where is the existing user-facing contract stating that project-config discovery follows the exact effective launch cwd? *(Claude Q13, Codex Q19)*

31. What is the rollback if a fleet of operators gets the wrong agent? Currently: ship a new release. Is that acceptable, or does the warning line from Q25 suffice as mitigation? *(Claude Q14)*

---

## 6. Recommended Revision Shape

Synthesizing the three reviews' constructive proposals, the smallest revision that answers the consensus objections:

1. **Read the branch first and restate the actual delta.** Answer Q1 in the plan text.
2. **Delete the process-cwd fallback.** Pass `nil`; skip project-config discovery when no authoritative source exists. Unanimous recommendation.
3. **Decide the walk boundary** (repo root / `$HOME` / workspace root / accept), and write the decision down. This is the largest unexamined blast radius.
4. **Write the trust decision down**, even if the decision is "accept for now." Add a changelog line either way.
5. **Resolve the `defaultAgentLaunch` scope contradiction** in writing: fix here with a test, or file a named follow-up.
6. **Add ten lines of observability**: `project_config_path` in the launch payload plus a warning when project config overrides the user default. Highest leverage item in the review pack, and it doubles as the rollback mitigation.
7. **Name the extracted pure helper** and test the wiring through it, with an explicit "prove it fails without the fix" step and the negative controls.
8. **State the tagged-app fixture as a unique sentinel command** and require both `pwd` and command evidence.
9. **Add the threading step** that C11-193's plan has and this one dropped.
10. **Decide `--in-surface` semantics** explicitly, since the plan's own invariant is violated there by construction.
