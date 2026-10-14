# Evolutionary Review — C11-193

## Executive Summary

The plan is aimed at a small guard, but the valuable thing underneath it is larger: a trustworthy intent boundary around where a newly launched agent is allowed to work. Today, absence of `--cwd` is merely represented as `nil`; after C11-193, cwd needs provenance — explicit caller intent versus a default inherited from c11 state — because the exact same path must be allowed in one case and rejected in the other.

That is the evolutionary opportunity: make effective launch cwd a first-class, inspectable decision rather than add a one-off Git check. Done that way, C11-193 composes cleanly with C11-194's workspace-root precedence, closes the cross-workspace targeting hole, and creates a reusable policy seam for future launch safety.

The proposed policy is sound and appropriately conservative, but the current five-step plan is not yet implementation-ready. It needs to specify:

- how the exact effective cwd and its provenance are resolved for the target workspace/pane;
- where the Git subprocess runs, since `agent.launch` currently follows the main-actor socket policy;
- how the checked cwd is pinned through surface creation to avoid a check/use race;
- whether to reuse or extract from the existing `GitContextResolver`, which already compares `--git-common-dir` with `--git-dir` and resolves branch state;
- the structured error and documentation contract; and
- the landing order or shared seam with C11-194.

Verdict: revise before handing to an implementer. The missing pieces are architectural, not cosmetic, but they can be resolved without making this a large ticket.

## What's Really Being Built

At its core, this is not worktree detection. It is **launch-context custody**: c11 is distinguishing a directory the caller deliberately named from one c11 selected on the caller's behalf.

That distinction matters because “linked worktree” is not proof that another agent owns the checkout. It is only a useful risk signal. The actual safety property is:

> c11 must not silently place a new agent into a risky checkout; it may do so when the caller explicitly takes responsibility for that path.

Model that property directly. A useful seam would return something like:

```swift
struct ResolvedAgentLaunchCwd: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        case explicitCLI
        case workspaceRoot
        case inheritedSurface
        case processFallback
    }

    let path: String
    let origin: Origin
}
```

The precise cases may change with C11-194, but provenance must survive resolution. Reducing everything to `String?` too early makes the guard brittle and invites the explicit-override exception to leak.

## How It Could Be Better

### Resolve the target's cwd, not the CLI process cwd

`cli/c11.swift` preserves the one fact C11-193 needs: it includes the socket `cwd` field only when `--cwd` was supplied. The server then validates it through `CwdParamResolution`, but when the field is absent `v2AgentLaunch` currently carries only `cwdOverride == nil` into surface creation.

The effective inherited directory is target-dependent. A launch aimed at another `--workspace` or `--pane` can inherit from that target even though the CLI process is running elsewhere. Probing `FileManager.default.currentDirectoryPath`, or probing CLI-side before target resolution, would therefore inspect the wrong checkout. Direct `agent.launch` socket callers would also bypass a CLI-only guard.

The authoritative sequence should be server-side:

1. Preserve whether `cwd` was explicitly supplied and validated.
2. Resolve the target workspace, pane, and effective cwd using the same precedence that surface creation will use.
3. Snapshot the path plus provenance.
4. If the origin is guarded, inspect that exact path off-main.
5. Create the surface using the snapshotted path, not a fresh dynamic inheritance lookup.

The last step closes a subtle time-of-check/time-of-use hole. While Git is being probed, the focused surface can change directory or the target pane can change. Passing the checked path into creation makes the command atomic at the semantic level: the directory inspected is the directory launched.

### Build on the Git capability that already exists

`Sources/Metadata/GitContextResolver.swift` already has:

- a pluggable `GitRunner` and bounded `ProcessGitRunner`;
- absolute normalization before comparing `--git-common-dir` and `--git-dir`;
- `mainCheckout` versus `linkedWorktree` classification;
- attached, detached, and no-branch states; and
- behavioral fake-runner tests plus real-repository fixtures.

The plan's step 2 currently reads as if that capability does not exist. A second independent detector would create two definitions of “linked worktree” that will drift. Either reuse `GitContextResolver` directly or extract the minimal shared classifier/probe from it. C11-193 should add launch policy, not duplicate Git semantics.

The existing resolver also has an explicit off-main precondition. That is important because `agent.launch` is currently absent from `socketWorkerV2Methods`, so its handler runs on the main actor. Running up to several bounded Git subprocesses there would violate the repo's socket-threading and typing-latency rules. The plan must name the threading shape: socket-worker orchestration with short main-actor snapshots/mutations is the clean direction.

### Define degraded behavior

The guard needs explicit outcomes for more than the four happy cases listed:

- not a Git repository: allow;
- ordinary main checkout: allow;
- linked worktree with attached branch: reject inherited use and report the branch;
- linked worktree with detached HEAD: reject and report the short SHA;
- linked worktree with no resolvable branch: reject with a stable `(no branch)` description;
- missing Git executable, timeout, permission failure, or malformed output: decide whether to fail open or fail closed.

Fail-open on an indeterminate probe is probably the proportionate compatibility choice, with a diagnostic/warning if one exists, but it must be a deliberate contract. Quietly treating missing probe output as “main checkout” would hide a meaningful implementation decision.

Submodules need a decision too. The current resolver deliberately resolves the outer superproject and an inner submodule. If a cwd is inside a submodule of a linked superproject, the safety intent suggests rejection, but the plan should state this rather than leave it to whichever pair of Git paths the implementer happens to compare.

### Make the refusal a stable API

“One actionable acknowledgement” is underspecified. Give the error a stable code and structured data, for example:

```json
{
  "code": "inherited_linked_worktree",
  "message": "Refusing to launch an agent in an inherited linked worktree. Pass --cwd only if you intend to share this checkout.",
  "data": {
    "cwd": "/path/to/tree",
    "branch": "fix/C11-193-launch-agent-cwd",
    "cwd_origin": "inherited_surface"
  }
}
```

Human output can show the acknowledgement, but callers should not have to parse prose. The success payload should also consider reporting `cwd` and `cwd_origin`; this turns launch placement from an inference into evidence.

The documentation work is load-bearing. `docs/launch-agent-reference.md` currently lists the launch error taxonomy without this refusal and describes `--cwd` only as a placement override. Because this changes CLI/socket behavior, the relevant c11 skill/reference must change too, followed by the required installed-skill sync. The skill should explicitly say not to auto-retry this error by mechanically echoing the suggested `--cwd`; that would erase the guard's intent boundary.

## Mutations and Wild Ideas

### From heuristic to lease-aware ownership

The linked-worktree heuristic deliberately produces false positives: an orchestrator may be launching a second agent into its own assigned worktree. A future, more precise variant could attach an ephemeral worktree lease to `{workspace, surface, task, branch, path}`. c11 could then reject “foreign active lease” rather than “any linked worktree,” while still retaining the conservative heuristic when no ownership data exists.

This should not be pulled into C11-193, but C11-193's structured provenance and error data are the substrate for it.

### A launch-context receipt

Every successful `launch-agent --json` response could include the resolved cwd, its source, Git classification, and target surface. Orchestrators would then be able to record immutable evidence of where a worker actually started. This is more useful than a guard alone: it makes post-run audits and mislaunch diagnosis straightforward.

### Explain without launching

A future `launch-agent --dry-run --json` or `launch-agent explain` could return the target, effective cwd, provenance, resolved agent config, and policy decision without creating a surface. That would let orchestrators preflight fleets and would provide a safe runtime-validation seam for policy changes.

### General launch-policy hooks

Once cwd resolution carries provenance, linked-worktree refusal can become the first policy in a small launch-policy pipeline. Other policies might check stale/missing directories or remote/local mismatches. Avoid broadening this ticket, but choose names and types that do not hard-code the pipeline to Git forever.

## What It Unlocks

- C11-194's workspace root becomes more than a convenience: it becomes a stable way to keep inherited launches out of transient agent worktrees.
- Cross-workspace and direct-socket launches gain the same safety semantics as local CLI launches.
- Orchestrators can distinguish “the operator chose this checkout” from “c11 happened to inherit this checkout.”
- Structured cwd provenance gives tests and diagnostics a common truth source.
- A later ownership/lease layer can become more precise without replacing the launch API again.
- Returning resolved cwd in launch results would let Lattice and other fleet controllers preserve launch evidence alongside task lineage.

## Sequencing and Compounding

The best sequence is:

1. **Decide semantics first.** Define which cwd origins are guarded, especially whether a configured C11-194 workspace root counts as explicit intent or as a non-explicit default. Define submodule and probe-failure behavior.
2. **Land or jointly define C11-194's cwd resolver.** C11-194 already proposes centralized precedence: explicit `--cwd`, workspace root, launching-surface cwd. Add provenance to that result. If C11-193 must land first, introduce the same result type now so C11-194 extends it rather than rewrites it.
3. **Extract/reuse the Git classifier.** Keep one `GitRunner`, one normalization rule, and one branch-state vocabulary.
4. **Add the pure decision matrix.** Given `ResolvedAgentLaunchCwd` plus Git classification, assert allow/reject behavior and the structured error.
5. **Wire the handler with correct threading.** Snapshot target state on main, probe off-main, then create on main using the checked path. Revalidate that target IDs still exist before mutation.
6. **Add adapter-level behavioral coverage.** Prove that rejection occurs before surface creation and that an explicit path bypasses the guard. If the current handler has no practical non-host seam, add a small runtime harness rather than a source-shape test.
7. **Update docs and the c11 operating contract.** Add the error, acknowledgement semantics, and anti-auto-retry guidance; sync installed skills if an installable skill changes.
8. **Validate proportionately.** Run the narrowed pure-logic slice and broader `c11-logic` gate, then exercise a tagged build or handler harness against a real linked worktree for the refusal path. Keep runtime validation side-effect-free: the refusal case should create no surface or start no agent.

This order compounds: C11-194 supplies one authoritative cwd decision; C11-193 adds policy to it; later ownership logic consumes the same provenance instead of reopening resolution.

## The Flywheel

The flywheel is **resolution → evidence → better defaults → fewer unsafe launches**:

1. Every launch resolves a cwd and records why that path won.
2. The guard turns risky inherited choices into structured feedback.
3. That feedback encourages setting safe workspace roots or naming deliberate `--cwd` values.
4. More launches become deterministic and auditable.
5. Deterministic launches make higher-level orchestration safer, which increases use of `launch-agent` rather than hand-composed surface setup.
6. More launches through the canonical primitive make future policy improvements effective across the fleet.

The small change that starts this flywheel is not telemetry; it is preserving `cwd_origin` through the whole launch path and returning it in structured results/errors.

## Concrete Suggestions

1. Replace plan step 1 with: “Trace target placement and extract one authoritative effective-cwd resolver that returns both path and origin; coordinate its shape with C11-194.”
2. Replace plan step 2 with: “Reuse or extract from `GitContextResolver` a bounded, off-main linked-worktree classification; do not add a second Git runner or path-comparison implementation.”
3. Add a threading/atomicity step: “Snapshot target IDs and cwd on main, probe off-main, then create with the checked path on main; fail `not_found` if the target disappeared.”
4. Name a structured error code and fields. Include cwd, cwd origin, worktree basename, and attached/detached/no-branch display state.
5. Expand the test matrix to cover target-vs-caller cwd, direct socket callers, detached/no-branch worktrees, submodules, probe failure/timeout, and a no-creation-on-rejection adapter test.
6. Explicitly assert that an explicit `--cwd` path skips the refusal even when it is the same linked-worktree path; also assert that an absent/empty/inherit socket value is not treated as acknowledgement.
7. Decide and test whether a C11-194 workspace root is guarded. Encode that decision in the origin enum, not in ad hoc conditionals.
8. Update `docs/launch-agent-reference.md` and the relevant c11 skill/API reference; sync the installed skill copy if edited.
9. Add resolved `cwd` and `cwd_origin` to successful JSON output if compatibility permits. The fields are additive and greatly improve auditability.
10. Keep worktree leases, auto-selection of a safe root, and dry-run/explain mode as follow-up tickets. They are valuable mutations, not prerequisites for this guard.

## Questions for the Plan Author

1. Does a configured workspace root from C11-194 count as explicit operator intent, or should every launch without `--cwd` remain subject to the linked-worktree guard?
2. Must direct `agent.launch` socket callers receive the same guard, or is this intentionally CLI-only?
3. Which exact target supplies the inherited cwd for `--workspace`, `--pane`, and `--new-workspace`, and how is that target pinned while the probe runs?
4. Should a cwd inside a submodule of a linked superproject be rejected based on the outer worktree?
5. Is probe failure fail-open or fail-closed? Should the caller receive a warning when c11 cannot classify the directory?
6. What are the stable error code and JSON data fields?
7. How should detached HEAD and deleted/no-branch worktrees appear in the actionable message?
8. Should the successful launch response expose the effective cwd and its provenance?
9. Is C11-194 a merge prerequisite, or should C11-193 define the shared cwd-resolution type that C11-194 will extend?
10. Is an agent allowed to automatically retry by adding `--cwd`, or must acknowledgement require an operator/owner decision? Where will that rule be documented?
11. What runtime evidence, beyond pure logic tests, will prove that the rejection path creates no surface and starts no process?
