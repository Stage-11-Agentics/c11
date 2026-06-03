## Evolutionary Code Review
- **Date:** 2026-05-12T17:07:17Z
- **Model:** Ucodex
- **Branch:** fix/claude-agents-wrapper-passthrough
- **Latest Commit:** 0fdb91e653b37da65dfab68fd83b5859691378b7
- **Linear Story:** claude-agents-passthrough
- **Review Type:** Evolutionary/Exploratory
---

Note: I did not run `git fetch` or `git pull`. The wrapper prompt explicitly limited this task to a read-only review with one allowed write, so this review uses the local refs already present in the workspace. Local branch context shows one commit over `origin/main`: `0fdb91e65 claude wrapper: pass through Agent View subcommands`.

## What's Really Being Built

This branch looks like a seven-token passthrough fix, but the real object under construction is c11's **agent launch policy layer**.

`Resources/bin/claude` is not just a shell wrapper. It is the only c11-owned code that sees a Claude invocation before Claude exists. It decides whether c11 should stay invisible, inject session-resume machinery, declare an agent surface, install lifecycle hooks, or now step aside for Agent View supervisor commands. That is policy, not plumbing.

PR #150 adds the newest policy class: **supervisor-pool verbs**. `agents`, `attach`, `logs`, `stop`, `kill`, `respawn`, and `rm` do not describe a new foreground Claude session. They describe operations against Claude Code's background-agent supervisor. Passing them through is correct for the immediate bug, but the new class is architecturally important: c11 now has to distinguish "foreground agent session" from "agent supervisor operation" from "auxiliary CLI command".

The capability being protected is the session-resume rail: wrapper -> hooks -> surface metadata -> `AgentRestartRegistry.phase1` -> restored command. The capability being foreshadowed is larger: c11 can become the stable room where foreground surfaces and background agent supervisors both remain legible.

## Emerging Patterns

The branch extends an existing pattern at [Resources/bin/claude](/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:125): classify `argv[0]` with a bash `case`, then either passthrough or fall through to c11 injection.

That same pattern exists in the sibling [Resources/bin/codex](/Users/atin/Projects/Stage11/code/c11/Resources/bin/codex:79), with a larger list of non-interactive/auxiliary commands. The pattern is converging across wrappers, but the classification vocabulary is still embedded as shell literals.

Three categories are now mixed together:

1. Auxiliary commands: `mcp`, `config`, `api-key`, `rc`, `remote-control`.
2. Foreground sessions: default fallthrough that receives `--session-id`, hooks, and `set-agent`.
3. Supervisor-pool commands: the seven Agent View verbs added here.

The anti-pattern to catch early is **unnamed launch classes**. The code has classes, but the code does not name them. The comment names Agent View, but the executable shape still says "one passthrough list." As more TUIs gain background/supervisor models, this will become the wrong abstraction to maintain.

A strong positive pattern is the wrapper's latency discipline. Socket checks are bounded at 0.75s in [Resources/bin/claude](/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:90), c11 writes are backgrounded in [Resources/bin/claude](/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:166), and real Claude is always allowed to launch. That should remain sacred.

## How This Could Evolve

The next step is not a large refactor. It is to make launch policy explicit.

Start by splitting the shell code into small named predicates:

```bash
is_auxiliary_subcommand() { ... }
is_supervisor_subcommand() { ... }
is_foreground_session_invocation() { ... }
```

That would keep this branch's conservative bash shape while giving future reviewers a vocabulary. It also makes flag-shaped cases possible. The existing `case "${1:-}"` cannot classify `claude --bg "prompt"` because `--bg` is a flag, not a subcommand. A named `classify_claude_invocation "$@"` can.

The bigger evolution is a shared wrapper policy manifest:

```yaml
tool: claude
auxiliary:
  - mcp
  - config
  - api-key
  - rc
  - remote-control
supervisor_pool:
  - agents
  - attach
  - logs
  - stop
  - kill
  - respawn
  - rm
session_flags:
  detached:
    - --bg
default: foreground_session
```

That manifest could start as documentation plus tests. Later it can drive a tiny `c11 wrapper-policy claude "$@"` helper, or a compiled Swift launch helper. The direction matters more than the first implementation: one policy vocabulary shared by Claude, Codex, Opencode, Kimi, tests, and skills.

## Mutations and Wild Ideas

**Agent View as a sidebar source.** Today this PR makes c11 step aside for Agent View. A more ambitious move is for c11 to understand that a surface is showing a supervisor TUI. `claude agents` could mark the surface as `terminal_type=claude-code` plus `agent_mode=supervisor`. `claude attach abc123` could mark `claude.agent_view_session=abc123`. The sidebar could then distinguish "foreground Claude session" from "Claude supervisor view" without pretending both are resumable in the same way.

**Launch policy explainability.** Add `c11 wrapper-explain claude attach abc123`, returning something like: `policy=supervisor_pool passthrough=true inject_session=false inject_hooks=false metadata=optional`. Agents debugging their own environment would stop reading bash and ask c11 what c11 thinks.

**Wrapper telemetry as an operator timeline.** With strict privacy boundaries, the wrapper could emit low-cardinality launch events: tool, policy class, c11 socket present, passthrough vs injected. Not full prompts, not arbitrary argv. This would make regressions obvious: "Claude 2.1.140 introduced an unknown subcommand that c11 treated as foreground_session." It also creates an operator-level view of agent usage without touching tenant config.

**Supervisor sessions as surfaces-adjacent objects.** c11's model is "workspace contains panes, panes contain surfaces." Agent View introduces another object: a background session that may or may not be attached to a surface. If those become common across TUIs, c11 may want a first-class "agent process" model alongside surfaces, with surfaces as views into those processes.

## Leverage Points

The highest leverage line is [Resources/bin/claude](/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:126). That one arm is now the choke point for every upstream Claude CLI verb that should not receive c11's session/hook injection.

The second leverage point is [tests/test_claude_wrapper_hooks.py](/Users/atin/Projects/Stage11/code/c11/tests/test_claude_wrapper_hooks.py:38). The existing fake-real-Claude harness already creates a wrapper dir, fake real binary, fake c11 ping command, and controllable live/stale/missing socket cases. That is enough to test this branch behaviorally: invoke `claude agents`, `claude attach abc123`, etc., and assert the fake real binary receives exactly the original argv with no `--session-id` or `--settings`.

The third leverage point is [Resources/bin/claude](/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:151), where the wrapper already writes agent identity after classification. Agent View commands bypass this today because they exec before line 151. That is right for session-resume capture, but it may be too coarse for UI state. Optional supervisor metadata can live before the passthrough exec without injecting hooks.

The fourth leverage point is [Sources/AgentRestartRegistry.swift](/Users/atin/Projects/Stage11/code/c11/Sources/AgentRestartRegistry.swift:143). The restore side already encodes terminal-type-specific resume policy. Launch-time policy and restore-time policy are separate today. They should remain independently deployable, but they should share names and concepts.

## The Flywheel

The flywheel is: upstream TUI adds capability -> c11 classifies it -> tests lock the classification -> skill/docs teach agents the behavior -> c11 UI can expose the new state -> future upstream changes are vocabulary additions, not emergency wrapper patches.

This PR is a useful trigger because Agent View is not just another subcommand. It is an upstream product move toward background agents. If c11 names that category now, every later background-agent feature becomes easier to absorb.

## Concrete Suggestions

1. **High Value - Add behavioral coverage for Agent View passthrough.** ✅ Confirmed — [tests/test_claude_wrapper_hooks.py](/Users/atin/Projects/Stage11/code/c11/tests/test_claude_wrapper_hooks.py:38) already has the harness shape needed. Extend it with a live-socket case for all seven new commands. Expected result: fake real Claude receives the original argv exactly; `--session-id` and `--settings` are absent; bounded c11 ping still occurs. This is not a source-text test; it verifies executable wrapper behavior through a fake binary.

2. **High Value - Name the launch policy classes in the wrapper.** ✅ Confirmed — the current executable policy is concentrated in [Resources/bin/claude](/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:114). A small follow-up can introduce `is_auxiliary_subcommand`, `is_supervisor_subcommand`, and later `has_detached_session_flag` without changing behavior. Risk: shell predicate drift; mitigation is the behavioral test corpus above.

3. **High Value - Explicitly decide `CLAUDECODE` behavior for passthrough commands.** ✅ Confirmed — passthrough exec happens at [Resources/bin/claude](/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:127), before `unset CLAUDECODE` at [Resources/bin/claude](/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:133). This may be deliberate for `mcp/config`, but Agent View is interactive enough that the decision should be named. Low-risk follow-up: unset `CLAUDECODE` before all in-c11 passthrough execs, or document why supervisor commands must preserve it.

4. **Strategic - Introduce a wrapper policy manifest or policy helper.** ❓ Needs exploration — [Resources/bin/claude](/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:125) and [Resources/bin/codex](/Users/atin/Projects/Stage11/code/c11/Resources/bin/codex:79) prove the duplicated taxonomy exists. The open question is implementation weight. A manifest gives reviewable data; a Swift helper gives better tests and parsing; plain bash predicates are the lowest-risk stepping stone.

5. **Strategic - Track supervisor mode separately from session resume.** ❓ Needs exploration — metadata writes are available through [Sources/TerminalController.swift](/Users/atin/Projects/Stage11/code/c11/Sources/TerminalController.swift:7849), and restore policy is terminal-type-driven in [Sources/AgentRestartRegistry.swift](/Users/atin/Projects/Stage11/code/c11/Sources/AgentRestartRegistry.swift:143). A future `agent_mode=supervisor` should not imply a resumable foreground session. Dependency: decide sidebar rendering and whether `claude attach <short-id>` is stable enough across restarts.

6. **Strategic - Update the c11 skill once Agent View behavior is intentional.** ✅ Confirmed — project guidance says agent-facing behavior changes should reach the skill. The useful note is short: Claude Agent View subcommands passthrough inside c11 and bypass the session-resume rail; they may later gain supervisor metadata. This prevents future agents from debugging a missing `claude.session_id` as if it were a hook failure.

7. **Experimental - Add `c11 wrapper-explain`.** ❓ Needs exploration — this becomes valuable after policy names exist. It would give agents and operators an executable oracle for launch classification, and it would make future reviews less dependent on reading wrapper internals.

8. **Experimental - Model background agent sessions as surface-adjacent entities.** ❓ Needs exploration — Agent View suggests a future where a surface is not always the process identity. A prototype could start with read-only metadata and sidebar display before any restore behavior changes.

## Validation Pass

- ✅ Confirmed — the branch diff is limited to [Resources/bin/claude](/Users/atin/Projects/Stage11/code/c11/Resources/bin/claude:114), one commit over local `origin/main`.
- ✅ Confirmed — the new Agent View commands bypass hook/session injection by execing before `unset CLAUDECODE`, `set-agent`, hook JSON construction, hook tempfile creation, and `--session-id` injection.
- ✅ Confirmed — [tests/test_claude_wrapper_hooks.py](/Users/atin/Projects/Stage11/code/c11/tests/test_claude_wrapper_hooks.py:38) can exercise wrapper behavior without the real Claude binary or local app launch.
- ✅ Confirmed — c11 metadata and restore architecture can support richer launch classes: `set-agent`/metadata writes exist, and [Sources/AgentRestartRegistry.swift](/Users/atin/Projects/Stage11/code/c11/Sources/AgentRestartRegistry.swift:143) already maps terminal types to restore commands.
- ❓ Needs exploration — whether Agent View short IDs are durable enough for restore or should only be displayed as live supervisor context.
- ❓ Needs exploration — whether `CLAUDECODE` affects `claude agents` or `claude attach` in real Claude Code 2.1.139+. The code ordering is verified; runtime sensitivity needs a tagged/manual check or CI environment with that binary.

## Closing

Ship this PR as the narrow fix. The evolution it points to is not "make the wrapper fancier"; it is "make c11's launch policy legible." Agent View is the first clear sign that c11 must reason about supervisor operations, not only foreground sessions. Name that class, test it through the existing wrapper harness, and the next upstream CLI change becomes an expected policy update instead of another surprise wedge.
