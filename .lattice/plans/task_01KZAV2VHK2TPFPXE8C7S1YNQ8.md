# C11-193 plan (rev 3 — binding operator decision, 2026-08-06)

The operator superseded the refusal plan: **WARN, DO NOT REFUSE**. Linked
worktrees are the normal lattice-orchestrator shape, so every classified linked
worktree launch proceeds. C11-194 lands first and owns cwd resolution.

1. Consume C11-194's resolved cwd and provenance. Do not re-derive the path.
   `--cwd` and a workspace root are explicit intent; launching-surface cwd is
   inherited.
2. Reuse `GitContextResolver` off-main. When the resolved cwd belongs to a
   linked worktree, return one structured warning and proceed. Main checkouts,
   non-repos, stale/indeterminate contexts, and missing cwd remain warning-free
   and fail open.
3. Preserve the existing human-readable `warnings: [String]` response for
   compatibility. Add `warning_details` entries with stable code
   `linked_worktree_cwd`, message, resolved cwd, offending worktree path and
   basename, branch representation, cwd source, and explicit-intent boolean.
4. The warning message must name the offending absolute worktree path. Explicit
   `--cwd` remains permitted. Workspace-root provenance counts as explicit
   intent. Inherited-surface copy calls out inheritance; every case says the
   launch is proceeding.
5. Print each structured warning once to stderr in human mode and under
   `--json`; keep it in JSON at the same time. Deduplicate the corresponding
   legacy string so one warning never prints twice.
6. Keep git/config I/O on the socket worker and bounded model/UI snapshots on
   the main actor. Warning computation must precede surface mutation, while the
   result must not prevent creation, identity stamping, command delivery,
   launch stats, or recent-config recording.
7. Extend pure resolver tests for inherited, explicit `--cwd`, workspace-root
   explicit intent, branch variants, main checkout, code, path, and payload.
   Run the narrowed safe logic suite and CLI compile gate.
8. In a tagged app backed by a real temporary linked worktree, observe:
   inherited launch proceeds; explicit and workspace-root launches proceed;
   stderr carries exactly one coded warning; `--json` carries both the legacy
   string and structured detail; spawned cwd is exact; CLI remains responsive.
9. Update launch docs and the installable c11 API reference from refusal to
   warning-only semantics, then commit, sync the installed skill, push PR #407,
   and rerun the failed infrastructure jobs after the new head is visible.

Non-goals: detecting actual concurrent writers, blocking linked worktrees,
adding a force flag, mutating git state, or guarding non-agent surface creation.

## Reset 2026-08-06 by agent:codex-c11-launch-cwd
