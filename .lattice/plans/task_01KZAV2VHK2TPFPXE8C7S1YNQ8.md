# C11-193 plan (rev 2 — post-trident revision, 2026-08-06)

Trident plan review verdict: **revise-then-proceed** (8/9 reviewers; pack at
`notes/trident-review-C11-193-plan-pack-20260806-1200/`, action contract in
`synthesis-action.md` there). The thesis is unanimously endorsed and preserved:
guard-over-default, refuse-inherited / permit-explicit. This revision replaces the
plumbing, not the bet.

**Honest scope (M2):** this ticket delivers a high-signal guard against *accidental
inherited* launches into a linked git worktree. It is a tripwire, not an enforcement of
"no two agents mutate the same tree" — it does not cover main-checkout collisions,
explicit overrides, or an agent that `cd`s into a contested tree after launch. Error
copy must make the same limited claim.

## Steps

1. **Sequencing contract with C11-194 (B6 — flagged by all nine reviewers).**
   C11-194 lands first: its centralization of cwd precedence (explicit `--cwd` →
   workspace root → launching-surface cwd) creates the single point where the effective
   cwd exists as a value, which this guard needs. C11-194 owns the shared
   provenance-carrying resolution type; C11-193 consumes it and owns the guard policy,
   its tests, and its docs. If ordering must flip, C11-193 introduces the shared
   resolver and C11-194 extends rather than replaces it. Cross-ticket matrix cases
   required either way: linked workspace root with safe surface cwd; safe root with
   linked surface cwd; no root configured; explicit linked override; `--new-workspace`.

2. **One authoritative effective-cwd value with provenance (B2, I4).**
   Introduce/consume `ResolvedAgentLaunchCwd { path; origin: .explicit | .workspaceRoot
   | .inheritedSurface | .processFallback }`, resolved server-side in `v2AgentLaunch`
   using the same precedence surface creation uses. Today `v2ResolveCwdParam` collapses
   the inherited case to `nil` and the path materializes downstream at surface creation
   — there is currently nothing to probe. The guard probes the snapshotted path, and
   **that same snapshotted path is passed into surface/workspace creation** (no
   re-derivation; closes the time-of-check/time-of-use hole). Placement matrix the
   resolver must cover: default pane, explicit `--pane`, explicit `--workspace`,
   `--new-workspace`. Wire-level definition of "explicit": a non-empty validated `cwd`
   param only; absent, empty-string, and literal `"inherit"` all classify as inherited
   (note: `launch-agent --cwd inherit` currently resolves to `<cwd>/inherit` and fails
   `not_found` — fix that inconsistency here). `cwd` stored in a saved config and sent
   via `config.launch` counts as explicit (a deliberately authored choice); state this
   in docs.

3. **Classification reuses `GitContextResolver` — no second probe (B1).**
   Consume `Sources/Metadata/GitContextResolver.swift` (`mainCheckout` /
   `linkedWorktree(basename:absolutePath:branch:)` / `stale`; `BranchValue.attached /
   .detached(shortSHA:) / .noBranch`) through a thin pure policy adapter, e.g.
   `AgentLaunchCwdGuard: {path, origin, gitContext} → .allow | .allowWithWarning |
   .reject(code, message, data)`. The injectable `GitRunner` seam gives deterministic
   pure-logic tests. Do not author a second `--git-dir`/`--git-common-dir` comparison.
   If measured launch latency forces a narrower dedicated probe, say so explicitly and
   derive it from the same shared primitives.

4. **Threading (B3).** Route `agent.launch` (and `config.launch`, which delegates to
   it) through the socket worker: parsing, config lookup, and git I/O run off-main, with
   bounded `@MainActor` hops only for the workspace/pane snapshot and surface creation.
   `GitContextResolver.resolve` traps on the main queue by design; git/process I/O on
   main is prohibited (per CLAUDE.md socket threading policy). Focus behavior unchanged.
   Add a routing/threading test.

5. **Decision table for degraded states (B5).** Explicit outcome per state — non-repo,
   main checkout, linked worktree (attached / detached / no branch), stale worktree, git
   executable missing, permission failure, timeout — resolved separately for inherited
   and explicit cwd. Default policy: fail-open **with a visible warning** on an
   indeterminate inherited probe. Pre-register an end-to-end latency budget below the
   CLI socket deadline; a timeout is terminal before any mutation — no late launch after
   the caller has been told it failed. The guard runs before surface/workspace creation,
   identity metadata, attention/flag stamping, launch-stats recording, recent-config
   mutation, and command delivery.

6. **Wire contract (B4, I5).** Stable error code `inherited_linked_worktree` with
   `error.data` carrying at minimum: normalized `cwd`, worktree root and basename,
   branch representation, and `cwd_origin`. Add the row to
   `docs/launch-agent-reference.md`'s error table. Explicit-override acknowledgement is
   **both** one element in the JSON `warnings` array **and** one line printed once to
   stderr in human mode (follow the `printSizeWarning` precedent, `cli/c11.swift:5022`
   — `printV2Payload` discards `warnings` outside `--json`, so the array alone is
   invisible to humans). Message contract: the normalized cwd and worktree basename are
   the durable identifying facts; branch renders as a supplement in canonical forms
   (attached name, `(detached @ <sha>)`, `(no branch)`).

7. **Entry-point scope (I2).** Guarded: direct socket `agent.launch`,
   `c11 launch-agent`, and `config.launch`. Explicitly *not* guarded (added to
   non-goals): the A button / `default-agent launch` path, and `new-pane` /
   `new-split` / `new-workspace` surface creation. `--new-workspace` behavior: the guard
   evaluates the effective cwd the new workspace will inherit, via the step 2 resolver.

8. **Tests (I3, M1).**
   a. Pure policy tests through the injectable `GitRunner`. Prefer extending
      `c11Tests/CwdParamResolutionTests.swift` in place (no pbxproj edit). If a new file
      is genuinely needed, name its path and *target* explicitly and verify membership
      in the pbxproj (C11-105 class of bug), noting the xcodeproj-gem diff-bloat gate
      for reviewers.
   b. Handler/adapter-level test proving **zero side effects on rejection**: no surface,
      no workspace, no identity metadata, no attention/flag stamping, no launch-stats
      record, no recent-config mutation, no command delivery.
   c. Real temporary-repo/linked-worktree fixture test for the classification path
      (scratch fixtures only).
   d. Behavioral check that the explicit-override warning appears once on human stderr
      and once in JSON. CLI build gate if `cli/c11.swift` changes (separate target from
      the logic suite).
   e. One tagged-build runtime validation inspecting the actually-spawned surface's cwd:
      inherited launch refused with surface count unchanged; explicit launch lands in
      the exact requested worktree; harmless command; explicit surface cleanup.

9. **Docs + skill (I1 — CLAUDE.md hard rule).** Update
   `docs/launch-agent-reference.md` (`--cwd` semantics, new error row, override
   warning); update `skills/c11/SKILL.md` and `skills/c11/references/api.md` /
   `references/orchestration.md` so agents know the refusal exists and what the
   sanctioned response is — including an explicit instruction **not** to auto-retry the
   error by mechanically appending `--cwd`, which would erase the guard's intent
   boundary. Run `scripts/sync-installed-skills.sh c11` and verify the installed copy.

10. **Gates.** Defer `xcodebuild` test execution to CI (the `build` job is the
    compile-plus-logic gate) for delegator/headless runs, per the standing operator
    instruction from C11-181; local runs only when the operator drives them. Runtime
    proof comes from step 8e's tagged-build validation.

## Non-goals

Blocking explicit worktree helpers; mutating tenant git state; changing launch focus
behavior; post-launch `cd` into a contested tree; main-checkout collisions; guarding the
A button / `default-agent launch` path; guarding `new-pane` / `new-split` /
`new-workspace` surface creation.

## Open product decisions (needs-human — resolve before implementing past step 1)

- **S1 — Is a C11-194 workspace root "explicit"?** An operator may deliberately set a
  workspace root that *is* a linked worktree. Reviewers split cleanly (allow: it was
  configured on purpose; guard: only `--cwd` proves per-launch intent). The `.workspaceRoot`
  provenance case exists either way; which side it falls on is a product call.
- **S2 — The guard fires on the house workflow.** This checkout has 38 linked worktrees
  and lattice-orchestrator mandates one per delegator, so a delegator launching its own
  helper from its own tree — the sanctioned dominant shape — gets refused. Remedies
  proposed, no consensus: (a) an explicit `--allow-worktree`/`--force` flag (matches the
  `pane.create --allow-undersized` idiom); (b) replace the linked-worktree proxy with
  the precise rule "is another *live surface* already rooted in this tree" via existing
  `MetadataKey.worktree` (no subprocess; names the offender; would change the guard's
  shape → re-review if chosen); (c) ship warn-and-count for a week via
  `AgentLaunchStatsStore` and let the measured false-positive rate decide (E2).
- **S4 — What does 193 deliver if explicit `--cwd` passes?** The ticket justified a
  guard over a default because it "holds even on explicit `--cwd`"; permitting `--cwd`
  with an acknowledgement trades enforcement for visibility. Confirm that trade or pick
  a harder override (ties into S2a).
