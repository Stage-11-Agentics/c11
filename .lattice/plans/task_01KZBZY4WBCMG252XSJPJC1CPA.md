# C11-195 plan

Rev 2 — revised per the trident plan review
(`notes/trident-review-C11-195-plan-pack-20260806-1405/synthesis-action.md`).

Goal: project `.c11/agents.json` lookup must use the effective launch cwd —
the directory the child will actually run in — never the app-process cwd, on
every launch rail.

## Baseline on `fix/C11-193-launch-agent-cwd` (verified 2026-08-06)

Much of rev 1's work already exists on the shared branch. Do not re-implement:

- `SocketDispatch.swift:1190` already computes
  `lookupCwd = cwdResolution.path ?? FileManager.default.currentDirectoryPath`,
  and surface creation already receives `cwdResolution.path` (the pre-fallback
  optional) — this split-brain is what step 1 removes.
- `TerminalController.swift:9080` (`defaultAgentLaunch`, v1 `default_agent`)
  is still `cwdArg ?? FileManager.default.currentDirectoryPath` — unfixed, and
  the only ticket-named site the branch does not fix.
- `AgentLaunchWorkingDirectoryResolver.decision` still REJECTS inherited
  linked-worktree cwds (C11-193 rev 3 supersedes this with warn-only) and runs
  before the config lookup.

C11-195 verifies and hardens the invariant (config lookup path == child cwd ==
reported cwd); it does not redo C11-194's plumbing (see C11-194 plan item 1).

## Dependency gate

"C11-194 must land first" is unenforceable on a shared branch. The concrete
gate: implementation starts from the commit on `fix/C11-193-launch-agent-cwd`
that contains the final C11-194 resolver semantics AND C11-193's warn-only
rewrite (no `.reject` for inherited linked worktrees). Record that exact
commit SHA in the evidence at step 9; a bare PR #407 link is not sufficient.

## Per-site disposition — all five `DefaultAgentProjectConfig.find` call sites

| Site | Disposition |
|---|---|
| `SocketDispatch.swift:1192` (v2 `agent.launch`) | Fix here: apply the step-1 no-context contract; verify the step-2 invariant |
| `TerminalController.swift:9082` (v1 `default_agent` / `defaultAgentLaunch`) | IN SCOPE — fix here, same contract (this supersedes rev 1's non-goal wording) |
| `Workspace.swift:12488` (A button, via `resolverCwdForAgentLaunch()`) | Deferred to C11-201 (filed): consult `workspace.rootDirectory` so the A button and CLI stop diverging in rooted workspaces |
| `GhosttyTerminalView.swift:3471` (falls back to `$HOME`) | Verified, unchanged — out of scope |
| `AppDelegate.swift:6764` | Verified, unchanged — out of scope |

## Steps

1. **No-context contract: drop the process-cwd fallback.** When resolution
   yields no path (no explicit `--cwd`, no workspace root, no
   launching-surface path), pass the optional through: `find(from:)` already
   handles nil/empty, and the launch falls back to the user default config.
   The app-process cwd is never consulted for config lookup on any rail. This
   removes the current three-way split (config from process cwd, child cwd
   from terminal default, response `cwd: null`). The replacement value (nil
   vs `$HOME`) is flagged to the operator as review item S3; this plan takes
   the reviewer-converged default, nil.

2. **The invariant, verified and hardened:** for every launch, config lookup
   origin == the directory the child actually runs in == the response `cwd`.
   For `default-agent launch --in-surface` the child runs in the TARGET
   surface's current directory, so the lookup rule there is
   `cwdArg ?? <target surface's current directory>` — NOT the generic
   new-surface resolution, which would re-create the divergence.

3. **Walk semantics: unchanged, and stated.** Moving the walk's start point
   newly exposes ancestor configs — including the `~/.c11/agents.json` class
   hazard behind the PR #217 A-button pin bug. Decision: walk bound and
   precedence unchanged; the ancestor-reachability shift is accepted and
   documented in `docs/launch-agent-reference.md`. Malformed
   `.c11/agents.json` stays silently ignored — also documented there.

4. **Test — `c11LogicTests`, through a pure seam.** Extract a pure function
   taking the C11-194 resolution plus an injected process-fallback path and
   returning the effective lookup path (ideally `(config, sourcePath)`).
   Prefer adding to an existing logic-target file over a new file (pbxproj
   normalization churn). Cases: positive (config under the resolved path is
   found); NEGATIVE (a valid decoy config under the injected process-fallback
   path is NOT applied when resolution is empty); the `--in-surface` rule
   from step 2. Use realpath'd scratch paths on both sides of every assertion
   (`/tmp` is a symlink to `/private/tmp`; `find` uses `standardizedFileURL`,
   which does not resolve symlinks). Demonstrate the test red with the fix
   reverted and record that in the step-9 evidence. Do not reach
   `defaultAgentLaunch` through `TerminalController.shared` in a logic test
   (the C11-105 socket-unlink pattern).

5. **Observability: add `config_source`** — the resolved `.c11/agents.json`
   path, or null — beside the existing `cwd`/`cwd_source` in the
   `agent.launch` response. Land this BEFORE step 8 so validation can assert
   on it. Update `docs/socket-api-reference.md`,
   `docs/launch-agent-reference.md`, `skills/c11/references/api.md`, then run
   `scripts/sync-installed-skills.sh c11`.

6. **Threading contract:** project-config and git I/O stay off-main on the v2
   socket-worker path. The v1 `default_agent` command runs on the main actor:
   fixing `defaultAgentLaunch` must not drag `GitContextResolver` subprocess
   I/O onto the main thread (C11-200 lesson); state the approach taken in the
   PR description.

7. **Docs / CHANGELOG:** CHANGELOG entry for the user-visible change (project
   agent config now actually applies on default launches); doc updates per
   steps 3 and 5; `scripts/sync-installed-skills.sh` for any installable
   skill text touched.

8. **Tagged-app validation, with a real oracle.** Run from a MAIN checkout,
   or only after the C11-193 warn-only flip is on the branch — inherited
   linked-worktree launches currently hard-reject before the config lookup
   ever runs. Launch via `scripts/launch-tagged-automation.sh <tag> --qa
   fresh`. Fixture: a scratch project whose `.c11/agents.json` carries an
   unmistakable sentinel (e.g. `command: echo C11-195-PROJECT-CONFIG`), plus
   a conflicting decoy config at the app-process cwd. Assert all of: the
   response `cwd`/`cwd_source` match expectations; `config_source` names the
   sentinel file, never the decoy; the child's actual `pwd` equals the config
   lookup origin. Cover both no-`--cwd` branches (workspace root wins;
   rootless falls back to the launching surface). Negative controls: a
   workspace with no project config uses the user default; a config omitting
   `defaultAgent` does not displace the Settings pick (the PR #217
   `overrideDefaultAgent` invariant); the decoy never wins.

9. Record review + runtime evidence on C11-195, pin the exact branch head
   from the dependency gate, and link PR #407.

## Non-goals

- Changing project-config precedence or walk semantics (stop point explicitly
  unchanged — step 3).
- The A-button entry point beyond shared helper reuse — deferred to C11-201.
- Trust gating for `.c11/agents.json` (executable config from possibly
  unauthored trees). The exposure class predates this ticket; posture is the
  operator's call — surfaced as review item S2, not decided here.

## Reset 2026-08-06 by agent:trident-pane-C11-195
