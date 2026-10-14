### Executive Summary

**Verdict: REVISE — do not hand this plan to an implementer yet.** The desired guard is sound, but the five steps are an issue decomposition, not an executable implementation plan. The single biggest gap is that the plan never defines how to obtain and freeze the **exact cwd the new PTY will actually use** before any surface is created. Today, `agent.launch` turns an omitted cwd into `nil` and lets workspace/Ghostty inheritance happen later (`Sources/SocketHandlers/SocketDispatch.swift:1067-1070, 1150-1152, 1183-1188`). Probing some earlier approximation can therefore reject the wrong directory or approve one directory while spawning in another.

The proposed “testable linked-worktree probe” also duplicates a mature resolver already in the repository. `GitContextResolver` already normalizes `--git-dir` and `--git-common-dir`, understands a linked superproject when cwd is inside a submodule, represents attached/detached/no-branch states, detects stale worktrees, injects its Git runner, and enforces off-main execution (`Sources/Metadata/GitContextResolver.swift:257-318, 322-364, 475-520`). A second detector would be immediate semantic drift.

The plan must be rewritten around one shared effective-cwd contract with C11-194, reuse the existing Git-context machinery or explicitly justify a narrower bounded derivative, define threading/timeouts/failure policy and wire-visible error/warning behavior, update the docs and c11 skill, and add handler/runtime validation. Until then, a locally green pure-logic test would not prove the guard protects the real launch path.

### Blocking Findings

1. **[P1] The plan has no implementable effective-cwd seam and ignores the main-thread boundary.**  
   **Evidence:** Plan steps 1 and 3 say to “locate” a seam and reject inherited cwd (`.lattice/plans/task_01KZAV2VHK2TPFPXE8C7S1YNQ8.md:3-5`) but never name the resolution contract. `v2ResolveCwdParam` collapses omission/inheritance to `nil` (`Sources/TerminalController.swift:2753-2779`); `v2AgentLaunch` then passes that `nil` into either `TabManager.addWorkspace` or `Workspace.newTerminalSurface` (`Sources/SocketHandlers/SocketDispatch.swift:1067-1070, 1150-1152, 1183-1188`). For a fresh workspace, the eventual fallback is selected-workspace state (`Sources/TabManager.swift:1367-1384, 2327-2338`). For an existing pane, Ghostty config inheritance chooses among selected/focused/remembered terminal candidates (`Sources/Workspace.swift:8355-8421`). There is no single preexisting scalar called “inherited launch cwd” at the point the plan assumes. Separately, `TerminalController` is `@MainActor` and `agent.launch` is absent from `socketWorkerV2Methods` (`Sources/TerminalController.swift:120-121, 1964-1991`), while `GitContextResolver.resolve` deliberately traps on the main queue (`Sources/Metadata/GitContextResolver.swift:264-280`).  
   **Failure:** A naive implementation either shells out to Git on the UI thread, traps immediately by reusing the correct resolver, or probes a cwd that is not the one used at PTY birth. Moving the Git call to a global queue and synchronously waiting from main merely turns the trap into an app stall.  
   **Required resolution:** Define a single `AgentLaunchCwdResolution`-style value containing at least `{path, source, isExplicit}`. Resolve/snapshot target placement and its effective cwd in a bounded main-actor slice, probe Git off-main, then guarantee the same path is passed explicitly into surface/workspace creation or revalidate it immediately before creation. Specify how `agent.launch` and its `config.launch` wrapper move onto a worker/continuation path without changing focus behavior. Add a TOCTOU rule for a pane cwd that changes between snapshot and creation.  
   **Confidence:** High.

2. **[P1] Step 2 proposes a duplicate of production Git logic that already handles the plan's hardest edge cases.**  
   **Evidence:** The plan asks for a new probe based on `--git-dir` versus `--git-common-dir` plus branch capture (`.lattice/plans/task_01KZAV2VHK2TPFPXE8C7S1YNQ8.md:4`). Existing `GitContextResolver.resolveOuter` performs that exact comparison with absolute path normalization (`Sources/Metadata/GitContextResolver.swift:322-364`), and `resolveBranch` covers attached, detached, and no-branch states (`Sources/Metadata/GitContextResolver.swift:475-493`). It also deliberately resolves the outer superproject before an inner submodule (`Sources/Metadata/GitContextResolver.swift:295-317`), which a cwd-local two-command probe would otherwise miss. Existing tests already exercise linked-worktree and linked-worktree-plus-submodule behavior (`c11Tests/GitContextResolverCacheWiringTests.swift:72-181`).  
   **Failure:** Two implementations will disagree on relative Git paths, submodules, stale worktrees, detached HEAD, timeouts, and future fixes. The safety guard is the worse place to carry the less-complete copy.  
   **Required resolution:** Reuse `ResolvedGitContext.outer` through a small pure policy layer. If latency forces a dedicated guard probe, derive it from shared path/branch primitives and document why the full resolver is unsuitable; do not independently reimplement the comparison. Pin normalization, submodule-superproject, detached/no-branch, stale, and non-repository semantics in tests.  
   **Confidence:** High.

3. **[P1] C11-193 and C11-194 can race into mutually incorrect behavior.**  
   **Evidence:** C11-194 explicitly plans to centralize cwd precedence as explicit `--cwd`, workspace root, then launching-surface cwd (`.lattice/plans/task_01KZAV3DFHX3WHKJG4F5075C66.md:3-7`). C11-193 merely labels the tickets complementary and has no dependency, merge order, shared type, or cross-ticket acceptance (`.lattice/plans/task_01KZAV2VHK2TPFPXE8C7S1YNQ8.md:3-9`). Both necessarily touch the `agent.launch` cwd path.  
   **Failure:** C11-193 can probe the surface cwd while C11-194 launches from a workspace root, causing a false refusal or a missed linked root. Separate implementations can also conflict mechanically in `SocketDispatch.swift` and semantically in tests while each branch stays green.  
   **Required resolution:** Make C11-193 depend on C11-194's centralized resolver, or define and land the shared resolver first. Add cross-ticket matrix cases: linked workspace root with safe surface cwd; safe root with linked surface cwd; no root; explicit linked override; and `--new-workspace`. State the merge order and which ticket owns the shared tests/docs.  
   **Confidence:** High.

4. **[P1] The wire contract and the promised explicit-override acknowledgement are undefined.**  
   **Evidence:** Plan step 3 says to “surface one actionable acknowledgement,” and step 4 mentions branch/error text (`.lattice/plans/task_01KZAV2VHK2TPFPXE8C7S1YNQ8.md:5-6`), but it specifies no error code, structured data, response field, output stream, or consumer behavior. `agent.launch` already returns a `warnings` array (`Sources/SocketHandlers/SocketDispatch.swift:1114-1117, 1276-1288`), but ordinary `c11 launch-agent` output discards it because `printV2Payload` prints only the fallback summary outside JSON mode (`cli/c11.swift:2340-2344, 5006-5016`). The same server primitive is called by direct socket clients and `config.launch` (`Sources/SocketHandlers/ConfigHandlers.swift:130-195`), not only the named CLI command.  
   **Failure:** An explicit override may be “acknowledged” only in hidden JSON, automation may parse unstable prose, or `config launch` may bypass/diverge from the guard. A refusal could also occur after surface creation unless ordering is made explicit.  
   **Required resolution:** Define a stable error code (not just `invalid_params`) and error data such as normalized cwd, worktree root/name, and branch representation. Define the explicit-linked warning in the JSON `warnings` array and print it once to stderr for human `launch-agent` and `config launch` output while keeping stdout machine-safe. State that the guard runs before surface creation, identity/attention stamping, launch stats, recent-config mutation, or command delivery. Decide and test whether direct `agent.launch`, `config.launch`, and any other wrapper share the policy.  
   **Confidence:** High.

5. **[P1] Failure policy, latency budget, and degraded Git states are missing.**  
   **Evidence:** The plan treats the two Git commands as an infallible comparison. Production Git execution is subprocess I/O with a five-second timeout **per call** (`Sources/Metadata/GitContextResolver.swift:189-253`), while the CLI's default socket deadline is ten seconds (`cli/c11.swift:942-969`). The existing resolver can also produce `.stale`, detached, and no-branch outcomes (`Sources/Metadata/GitContextResolver.swift:106-136, 475-493`). None appears in plan steps 2-4.  
   **Failure:** A slow or wedged Git process can make the CLI time out while the server later creates an agent; an orchestrator retry can then create duplicates. A fail-open probe silently defeats the guard; a fail-closed probe that cannot distinguish “not a repo” from “Git failed” can block legitimate launches. Branch-only prose becomes blank or misleading on detached/unborn/broken HEAD.  
   **Required resolution:** Pre-register an end-to-end latency budget below the socket deadline and a distinct outcome table for main checkout, linked worktree, non-repo, stale worktree, detached HEAD, no branch, Git executable failure, permission failure, and timeout. Decide fail-open/fail-closed behavior for inherited and explicit launches separately. Preserve structured branch variants and include worktree path/name so the message remains actionable without an attached branch. Prove that a timeout cannot produce a late launch after the client has received failure.  
   **Confidence:** High.

6. **[P1] The planned test gate is too shallow and omits the required shipped contract and runtime proof.**  
   **Evidence:** The plan asks only for pure “behavioral logic tests” and two vague logic gates (`.lattice/plans/task_01KZAV2VHK2TPFPXE8C7S1YNQ8.md:6-7`). Those can prove a policy enum but not that the handler resolves the correct target cwd, refuses before mutation, renders the warning, or launches in the allowed directory. Repository policy requires runtime-behavior tests rather than source-shape assertions, a tagged reload after code changes, and skill synchronization when the CLI/socket contract changes (`AGENTS.md:37-50, 108-112, 145-150`). The canonical launch reference currently documents only the old cwd behavior and error table (`docs/launch-agent-reference.md:109-125, 186-205, 275-302`).  
   **Failure:** The pure seam passes while production wiring still probes `FileManager.default.currentDirectoryPath`, warnings remain invisible, or an inherited refusal creates an empty surface before returning an error. Operators and agents continue following stale recovery instructions.  
   **Required resolution:** Name the exact narrow and full `c11-logic` commands. Add a handler/integration seam that proves zero surface/stats/attention mutation on refusal, exact cwd on allowed launches, human stderr plus JSON warning behavior, focus preservation, and placement variants (default pane, explicit pane, explicit workspace, new workspace). Validate against a tagged QA build using disposable main/linked worktrees and inspect the actual spawned surface cwd; record a bounded harmless launch strategy. Update `docs/launch-agent-reference.md`, CLI help/error tables, and `skills/c11/SKILL.md`; then run `scripts/sync-installed-skills.sh c11` and verify the installed copy.  
   **Confidence:** High.

### How Plans Like This Fail

- The guard checks the caller's shell cwd because it is easy to obtain, while the server later chooses a target workspace root or pane-inherited cwd. The protection becomes correlated with the right answer rather than causal.
- A safety check is placed after allocation. The command does not run, but an empty surface, attention state, launch-stat record, or recent-config pointer survives the rejection and makes retries confusing.
- A subprocess check is inserted into a synchronous UI handler. It works on a warm local repository, then beachballs the app or exceeds the socket deadline on a network volume, stale worktree, or contended machine.
- “Warn loudly” becomes a field only `--json` users can see. Humans receive `OK surface:…`; automation cannot distinguish an intentional override from an ordinary launch.
- Two related tickets independently encode cwd precedence. Each unit suite passes, but their merge order decides the product behavior.
- A linked-worktree detector is mistaken for proof of exclusive ownership. Main checkouts, explicit overrides, two launches in the same linked tree, and non-Git directories remain shareable.

### Assumption Audit

| Assumption | Load-bearing? | Adversarial read |
|---|---:|---|
| The exact inherited cwd exists as a pure value before launch. | Yes | It does not today; omission becomes `nil` and later workspace/Ghostty inheritance determines the PTY cwd. |
| The caller's cwd, target workspace cwd, selected pane cwd, and eventual PTY cwd are equivalent. | Yes | False for `--workspace`, `--pane`, `--new-workspace`, cold surfaces, browser-selected panes, and after C11-194 adds workspace roots. |
| A new two-command Git probe is harmless. | Yes | False: equivalent mature logic already exists, subprocess calls are bounded but not free, and the current handler is main-actor routed. |
| `git-dir != git-common-dir` can be compared as returned. | Yes | Only after path normalization; the existing resolver already does this. Submodules require probing the outer superproject. |
| Every linked worktree has a normal branch name. | No, but user-visible | Detached, unborn, deleted, and broken HEAD states exist; the existing `BranchValue` models them. |
| Probe failure means “not a linked worktree.” | Yes | Unsafe fail-open. Conversely, treating every nil as unsafe blocks non-Git directories. The plan needs a richer result. |
| Explicitness is equivalent to `cwdOverride != nil`. | Yes | The server currently collapses absent, empty, and `inherit` forms; the policy must define which wire forms count as intentional override. |
| Guarding `c11 launch-agent` guards all programmatic agent launches. | Yes for the stated invariant | `config.launch`, direct `agent.launch`, `default-agent launch`, and the A button are separate entry surfaces; scope is unmade. |
| Pure logic tests prove the safety invariant. | Yes | They do not prove correct target resolution, mutation ordering, output rendering, deadlines, or actual spawned cwd. |
| C11-194 can land independently without changing this design. | Yes | False; it changes the very precedence this guard must inspect. |

### Blind Spots

1. **Placement semantics:** The plan has no matrix for default placement, explicit pane, explicit workspace, new workspace, cross-window targets, unselected workspaces, or panes whose selected surface is not a terminal.
2. **Cold/stale cwd reporting:** It does not specify precedence when shell integration has not reported `panel.directory`, when only `requestedWorkingDirectory` exists, when the path was deleted, or when cwd changes during the probe.
3. **Side-effect ordering:** It never states that rejection must precede surface creation, config/recent mutation, stats, identity metadata, suppression/flag stamping, delayed prompt scheduling, and command delivery.
4. **Consumer scope:** It does not say whether direct socket calls and `config launch` are protected, or explicitly document why A-button/default-agent launches remain out of scope.
5. **Output contract:** It omits a stable code/data schema, human stderr behavior, JSON parity, branch escaping/length policy, and the worktree path/name needed when branch is absent.
6. **Probe operations:** No timeout budget, cancellation rule, late-completion behavior, executable-not-found behavior, permission behavior, or telemetry/debug evidence is specified.
7. **Repository topology:** It misses cwd inside a submodule of a linked superproject, nested independent repositories, symlinked paths, bare repositories, stale worktree admin state, detached HEAD, and unborn HEAD.
8. **Documentation lifecycle:** It omits CLI help, canonical docs, c11 skill changes, installed-skill synchronization, and version/compatibility notes for socket consumers.
9. **Validation cleanup:** A runtime check that actually launches an agent needs a harmless command strategy, explicit surface cleanup, scratch-only Git fixtures, and proof that the operator's live checkout/data were untouched.

### Challenged Decisions

**Adding a new worktree probe.** The default should be a policy adapter over `GitContextResolver`, not a second Git implementation. If the existing resolver's multi-call worst case is too slow for launch, the architectural decision is to extract a shared, strictly bounded classification primitive—not to copy its happy path.

**Describing the guard as “inherited versus explicit” without a source enum.** That is too implicit. Make cwd source a first-class value so C11-194 can add `.workspaceRoot` without changing safety semantics by accident. The policy question then becomes explicit: is workspace root inherited and therefore guarded? The answer should be yes unless the operator explicitly supplied `--cwd`, but it must be written down.

**Warning rather than requiring a second confirmation flag for explicit linked cwd.** Allowing `--cwd` as the acknowledgement is reasonable for non-interactive orchestration; adding an interactive prompt would break automation. But the warning must be visible on stderr and in JSON, and explicit `--cwd` must be preserved as an intentional source through every wrapper.

**Putting branch text at the center of the error.** Branch is useful context, not identity. Worktrees may be detached or broken, branch names can be long, and multiple worktrees can involve related refs. The normalized cwd and worktree root/name are the durable facts; render branch as an attached/detached/no-branch supplement.

**Treating the guard as CLI-only.** The invariant belongs at the atomic server launch boundary so wrappers cannot bypass it. The CLI owns relative-path resolution and human rendering; the server owns final cwd resolution, classification, rejection ordering, and structured response.

### Hindsight Preview

The likely future regret is not “we forgot one unit test.” It is: “C11-194 changed cwd precedence, but C11-193 kept checking the old surface cwd, so the guard looked green while launching somewhere else.” The prevention is one shared effective-cwd result used both by the guard and by PTY creation.

The second likely regret is a duplicated worktree classifier. The sidebar resolver gains a fix for stale worktrees or submodule layout, while the launch guard retains the old comparison and silently diverges. Reuse one semantic source now.

The third is operational: a slow Git probe exceeds the ten-second client deadline, an orchestrator retries, and the first request later creates a second agent. Pre-register maximum probe and total command latency, and make timeout cancellation terminal before any mutation.

Early warning evidence should include debug-only records of `{cwd_source, normalized_cwd, git_outcome, decision, elapsed_ms}` with no branch-path telemetry sent externally by default. Runtime validation should assert the recorded normalized cwd equals the new surface's observed cwd.

### Reality Stress Test

1. **C11-194 lands first and sets a linked workspace root while the launching surface is in a safe main checkout.** A surface-only C11-193 probe allows the launch even though the PTY starts in the linked root. If C11-193 lands first, C11-194 can silently invalidate its assumptions. Only a shared resolver and cross-ticket tests survive both orders.
2. **Git is slow or the linked worktree admin directory is pruned mid-call.** Without a bounded worker path and explicit degraded-state policy, c11 either freezes, times out then launches late, or fail-opens. The plan currently has no acceptable outcome for this ordinary failure.
3. **An orchestrator uses `config launch --workspace …` instead of `launch-agent`.** Server-side policy may affect it unintentionally, or CLI-only policy may leave it unguarded. The warning can also vanish because both human output paths currently discard response warnings. The plan needs consumer parity, not a single command example.

### The Uncomfortable Truths

- This guard cannot prove that a linked worktree belongs to “another agent.” Git records topology, not ownership or liveness. The message may say “likely another agent's active tree,” but the implementation cannot make the stronger claim.
- This guard does **not** enforce “no two agents mutate the same tree.” It allows main checkouts, explicit linked overrides, multiple explicit helpers in one worktree, and non-Git directories. It prevents one expensive class of silent accident; describe it honestly as that.
- `--cwd` proves intent only syntactically. An orchestrator can explicitly pass the wrong linked worktree. The warning is a breadcrumb, not safety proof.
- The present plan is too small because the feature crosses cwd resolution, Git subprocess policy, socket threading, wire output, multiple launch consumers, docs/skill installation, and running-system validation. Five generic steps conceal rather than control that surface area.

### Hard Questions for the Plan Author

1. What exact function returns the cwd that will be passed to PTY creation for each placement mode, and how do you prove the probe and the spawn consume the same normalized string?
2. Does `.workspaceRoot` from C11-194 count as inherited and therefore require the guard? If yes, which ticket owns the shared source enum and merge order? If no, why is a silently selected linked root safer than a silently selected linked surface cwd?
3. Will `agent.launch` and `config.launch` move to socket-worker execution, or what non-blocking continuation design keeps Git subprocess I/O off the main actor? Where is the no-late-launch timeout guarantee?
4. Why add a new Git probe instead of consuming `GitContextResolver`'s linked/main/stale and `BranchValue` results? What measured latency or API limitation requires divergence?
5. What are the exact decisions for non-repo, main checkout, linked worktree, stale worktree, detached HEAD, no branch, Git missing, permission failure, and timeout—for inherited and explicit cwd separately?
6. Which wire forms count as explicit acknowledgement: a non-empty `cwd` param only, the literal `inherit`, an empty string, `--cwd .`, and cwd supplied through `config launch`? “We infer it from non-nil later” is not a sufficient contract.
7. What stable error code and structured data will direct socket clients receive, and how will ordinary human CLI users see the explicit-linked warning without `--json`?
8. Which side effects are guaranteed absent after inherited rejection, and which integration test proves no surface, stats record, recent-config update, metadata, attention state, or command delivery occurred?
9. Which launch entry points remain able to create an agent in an inherited linked worktree (`default-agent`, A button, direct socket, config launch), and is each inclusion/exclusion deliberate and documented?
10. What exact narrow/full test commands and tagged-runtime scenario prove rejection, explicit allowance, main/non-Git allowance, C11-194 precedence, warning visibility, no focus steal, bounded latency, and the child's observed cwd?
11. Which files update the public contract (`cli` help, `docs/launch-agent-reference.md`, c11 skill), and where does the plan require `scripts/sync-installed-skills.sh c11` plus live-copy verification?
12. If the project goal is truly “no two agents mutate the same tree,” what complementary ownership/liveness mechanism covers main checkouts and explicit overrides, or will the ticket explicitly narrow its claim to accidental inherited linked-worktree launches?
