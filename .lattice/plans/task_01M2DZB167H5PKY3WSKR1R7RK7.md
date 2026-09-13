# C11-224 plan

Delegator brief (authoritative): `plans/C11-224-delegator-brief.md`.

## The fix

Ask the kernel for only the pids on that tty:

```swift
proc_listpids(UInt32(PROC_TTY_ONLY), UInt32(truncatingIfNeeded: dev), buf, size)
```

`PROC_TTY_ONLY` (libproc.h) takes the tty `dev_t` as `typeinfo` and returns just
the pids whose controlling tty matches. Keep the existing "highest pid wins"
selection over that (much shorter) list, or, if you can get the pty fd cheaply,
prefer `tcgetpgrp` for the exact foreground process group. Do not change the
sampler cadence or the sidebar behavior; the win is cost per call, from
O(processes) to O(pids on this tty).

Preserve the existing semantics the callers rely on: `nil` when the tty has no
process, the same `dev_t` handling comments (the `e_tdev`/`dev_t` sign note is
no longer needed once you stop comparing `e_tdev` yourself; delete it rather
than leave it stale).

## Tests

Existing coverage is in `c11Tests/SurfaceLifecycleTests.swift` around line 333
(`foregroundPID(forTTYName: "/dev/tty")` and a not-a-real-device case). Keep
those green and add a behavioral case if one is cheap: resolving the current
process's own tty (`ttyname(STDIN)` when it exists) must return a pid that is
this process or an ancestor in its process group. No source-text or
signature-shape tests (see "Test quality policy" in CLAUDE.md).

**Do not run `xcodebuild` locally in any form** (build or test, any scheme). The
operator's machine is under heavy load and a build here starves every other
agent. CI's `build` job compiles and runs the logic gate; `c11-unit` runs on
CI too. Push and read CI.

## Worktree

```bash
cd /Users/atin/Projects/Stage11/code/c11
git worktree add ../c11-worktrees/c11-224-tty-only-pid -b fix/C11-224-tty-only-pid origin/main
cd ../c11-worktrees/c11-224-tty-only-pid
git submodule update --init --recursive ghostty vendor/bonsplit
```

You do not need the GhosttyKit symlink because you will not build locally.

## Lattice discipline

- `lattice status C11-224 in_progress` when you start, `review` when the PR is
  open, `pr_open` after you have self-reviewed the diff, and attach the PR URL
  as an artifact. Comment with the CI run URL when it is green.
- Do not merge. The operator or orchestrator merges; this ships in the next
  patch release alongside C11-225.
- Report completion and recoverable blockers to your parent (the
  "Load Diagnosis" surface in workspace `c11`, `surface:115`, via
  `c11 send --workspace workspace:5 --surface surface:115 "<one-line status>"`).
  Raise a c11 flag only when operator action is required.

## PR description

Include the before/after syscall count reasoning and cite the ticket. End with
the attribution lines your harness supplies.
