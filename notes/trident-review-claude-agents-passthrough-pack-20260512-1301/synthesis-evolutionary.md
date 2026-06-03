## Evolutionary Review Synthesis: claude-agents-passthrough

- **Date:** 2026-05-12
- **Branch:** fix/claude-agents-wrapper-passthrough (PR #150)
- **Sources:** evolutionary-claude.md (Claude Opus 4.7), evolutionary-codex.md (Codex)
- **Note:** Gemini unavailable (quota exhausted). Synthesis is across two reviewers, not three.

---

## Executive Summary: Biggest Opportunities

1. **The wrapper is becoming the agent-launch policy layer.** Both reviewers independently arrive at the same framing: `Resources/bin/claude` is no longer a one-shot session-id injector — it is the only c11-owned code that runs before the agent process exists, and it is starting to multiplex three semantically distinct policy classes (auxiliary commands, foreground sessions, supervisor-pool operations). Name the classes; the next decade of upstream CLI churn becomes vocabulary updates rather than emergency bash patches.

2. **Agent View is the bellwether for background-agent TUIs as the new primary unit.** Both reviewers see PR #150 as the first concrete sign that upstream is moving toward "supervisor with attached background sessions" as the default shape. c11's surface model ("one surface = one foreground process") will feel cramped fast. Decide now whether supervisor sessions are surface attributes, surface-adjacent first-class objects, or sidebar twins of the workspace tree.

3. **Behavioral test coverage of wrapper argv classification is the highest-ratio next move.** `bash -n` is not a test, and both reviewers point to the existing fake-real-Claude harness in `tests/test_claude_wrapper_hooks.py:38` as already-sufficient infrastructure. A 50-line extension catches "forgot to add the next verb" regressions before they ship, at near-zero cost.

4. **A declarative verb manifest is the right destination, but staged.** Both reviewers converge on a YAML/JSON manifest of verb classes per TUI as the architectural endpoint, with named bash predicates as the safe stepping stone. The manifest becomes the contract that c11, tests, skills, and (eventually) the ecosystem consume.

5. **The session-resume rail can extend to supervisor-pool operations almost for free.** One extra background `c11 set-metadata` write on `claude attach`/`respawn` gives c11 awareness of which background session is on the operator's screen — and unlocks sidebar rendering, workspace snapshots, and restore-time re-attachment.

---

## 1. Consensus Direction: Evolution Paths Both Models Identified

1. **Wrapper-as-policy-layer reframing.** Both reviewers reject the "thirteen-line passthrough fix" framing and assert the wrapper is the **agent launch policy layer** (Codex's phrase) / **agent-launch shim layer** (Claude's phrase). Same object, same load-bearing position, same call to make the policy explicit.

2. **Three verb classes are now mixed and need names.** Both reviewers identify the same three categories now coexisting in one case statement:
   - Auxiliary / non-interactive (`mcp`, `config`, `api-key`, `rc`, `remote-control`, `completion`, `--version`)
   - Foreground sessions (default fallthrough: inject `--session-id`, hooks, set-agent)
   - Supervisor-pool (the seven new Agent View verbs: `agents`, `attach`, `logs`, `stop`, `kill`, `respawn`, `rm`)

3. **Bash `case` statement is a structural ceiling.** Both reviewers note the same hard limit: `case "${1:-}"` can never classify flag-shaped invocations like `claude --bg "<prompt>"`. The current shape will always miss flag-form variants of new behavior.

4. **Latency discipline is sacred and should be promoted to a documented contract.** Both reviewers explicitly call out the bounded timeout / backgrounded write / always-exec-real-binary pattern as the right shape — and worth formalizing rather than leaving as "two copies in bash."

5. **Manifest-driven dispatch is the architectural destination.** Both reviewers independently sketch a YAML/JSON manifest with three buckets (auxiliary, supervisor_pool, session_flags, default). Both treat this as the single shared statement of c11's vocabulary across Claude, Codex, and future wrappers.

6. **Launch-time policy and restore-time policy should share names.** Both reviewers point to `AgentRestartRegistry.phase1` (Sources/AgentRestartRegistry.swift:143) as the mirror of wrapper-side verb taxonomy on the restore side — currently coupled implicitly. Both recommend shared vocabulary, while keeping them independently deployable.

7. **`--bg` is unfinished business.** Both reviewers flag the same gap: `claude --bg "<prompt>"` is a flag, not a subcommand, so the current case statement still injects session-id + hooks against what is effectively a detached supervisor process. Out of scope for this PR; structurally important for the next one.

8. **Supervisor metadata should be written even for passthrough verbs.** Both reviewers want `claude attach <short_id>` to leave a fingerprint in surface metadata (e.g., `claude.attached_session`, `agent_mode=supervisor`) without injecting hooks — to keep the sidebar and restore paths informed.

9. **The c11 skill must be updated to teach Agent View semantics.** Both reviewers (per project rules) call out updating skill documentation so future agents don't debug a missing `claude.session_id` as if it were a hook failure.

10. **Ship PR #150 as-is.** Both reviewers concur: the narrow fix is correct for its stated scope. The follow-up work is the interesting territory.

---

## 2. Best Concrete Suggestions (Most Actionable)

1. **Extend `tests/test_claude_wrapper_hooks.py` with Agent View passthrough cases.** The harness already creates a fake real Claude binary, a controllable c11 ping, and live/stale/missing socket cases. Add a live-socket case for each of the seven new verbs that asserts the fake binary receives the original argv exactly — no `--session-id`, no `--settings`. Both reviewers rate this High Value, near-zero risk. Single highest-ratio next move.

2. **Introduce named shell predicates as a behavior-preserving refactor.** `is_auxiliary_subcommand`, `is_supervisor_subcommand`, `is_foreground_session_invocation` (and later `has_detached_session_flag` for `--bg`). Keeps PR #150's conservative shape, gives future reviewers a vocabulary, and unlocks flag-shaped classification that the current `case` cannot reach. Pair with the test corpus above.

3. **Add `--c11-debug-classify` as a wrapper introspection flag.** Five-line addition: the wrapper prints its classification of argv and exits without invoking real Claude. Drives the Python test runner cheaply; doubles as a debugging tool for operators and agents. Foundation for the later `c11 wrapper-explain` CLI.

4. **Write supervisor metadata on `attach`/`respawn` before the passthrough exec.** Single extra background `c11 set-metadata` call with key `claude.attached_session` / `agent_mode=supervisor`. Lives before the passthrough exec so it doesn't add latency to real Claude startup. Verified that metadata APIs exist (`Sources/SurfaceMetadataStore.swift:155–225`). Extends the rail without changing the rail's invariants.

5. **Explicitly decide and document `CLAUDECODE` behavior for passthrough verbs.** Passthrough exec currently happens before `unset CLAUDECODE`. Codex flags this as a deliberate-or-accidental decision that should be named. Either unset before all in-c11 passthrough execs, or comment why supervisor commands must preserve it. Low-risk, prevents future surprise.

6. **Promote the wrapper's four-constraint docstring to a Swift `enum WrapperPolicy`.** Doc-commented Swift type that isn't called by anything yet. Cheap, future-proofs the lift to a Swift `c11-launch` binary, creates a single source of truth that pairs naturally with `AgentRestartRegistry.phase1`.

7. **Stage the manifest extraction.** Both reviewers want a `Resources/wrappers/{claude,codex}.yaml` eventually; Codex recommends starting it as documentation + tests before driving runtime behavior. Stepping stones: (a) named bash predicates, (b) external doc capturing the taxonomy, (c) test corpus reading the doc, (d) wrapper reads the manifest, (e) `c11 wrapper-policy` helper, (f) Swift `c11-launch` binary loads it.

8. **Update the `c11` skill with one short note.** "Claude Agent View subcommands passthrough inside c11 and bypass the session-resume rail; they may later gain supervisor metadata." Prevents the next agent from misdiagnosing a missing `claude.session_id` as a hook failure. Project rules require skill updates when agent-visible behavior changes.

9. **Address `claude --bg <prompt>` as the next PR.** Scan argv for `--bg` before the case statement, route to a third policy ("bg-detached: inject hooks but mark them as supervisor-routed" or "passthrough"). Structural-limit case that motivates the named-predicate refactor; cleanly handled by a manifest with a `session_flags.detached` bucket.

---

## 3. Wildest Mutations: Creative / Ambitious Ideas Worth Exploring

1. **Unified supervisor: c11 sidebar shows Agent View sessions inline.** Claude Code 2.1.139's Agent View is structurally a TUI for a process supervisor; c11's sidebar is structurally a workspace-tree view for a surface supervisor. Make the sidebar render both: c11 surfaces *and* attached/detached Claude background sessions in one tree. Drag a background session onto a c11 surface to attach. Drop a surface in the trash to `claude kill`. Practical first step: a one-day prototype that reads `claude agents --json` (file an upstream request if it doesn't exist) and renders the list in a c11 debug window. Most ambitious; biggest payoff if it lands.

2. **Wrapper telemetry as the operator's "agent week" pedometer.** The wrapper is on every TUI launch by construction. One JSONL line per invocation (tool, verb, policy class, in-c11?, rail-hit?) to `~/Library/Logs/c11/wrappers/`, rotated daily, no PII (argv first-token only). Becomes the foundation for operator dashboards, retro tooling, and regression detection ("Claude 2.1.140 introduced an unknown subcommand that c11 treated as foreground_session"). Free because the wrapper is already there.

3. **Reverse the polarity: wrapper-as-policy-client.** Today c11 commands the wrapper. Invert: the wrapper queries c11 via `c11 wrapper-policy --tool claude --argv "$@"` and gets back a JSON blob telling it what to do. c11 owns the policy and can hot-update it across all running surfaces without re-shipping the bash file. Enables tenant-level rules ("never inject hooks in `~/personal/`," "block `--bg` when this surface is the orchestrator"). Higher latency risk; viable only after the manifest is in place.

4. **Cross-TUI session-resume coherence as a normalized vocabulary.** Today each TUI has its own session-id semantics (claude: uuid-v4, codex: cwd+`--last`, opencode/kimi: best-effort fresh). As more converge on "supervisor with background sessions," c11 hosts an `agent.supervisor_session_id` family keyed by `terminal_type`. `AgentRestartRegistry` collapses into a single resolver instead of four hand-written closures. Experimental because the shape of codex/opencode/kimi supervisors isn't settled.

5. **Supervisor sessions as first-class surface-adjacent objects.** c11's current model: workspace → panes → surfaces. Agent View introduces a fourth object class: a background session that may or may not be attached to a surface. If background-agent TUIs proliferate, c11 grows a first-class "agent process" model alongside surfaces, with surfaces becoming views into those processes. Structural mutation, not additive — worth prototyping before committing.

6. **A publishable `c11-wrappers` skill and convention.** The wrapper pattern is mature enough to be teachable: four constraints, two reference implementations, a clear correctness test. A `c11-wrappers` skill lets any agent verify "is this TUI wrapped?", "what policy applies?", "is the rail capturing me right now?" — and lets agents author wrappers for new TUIs by following the contract. Converts tribal bash into a publishable convention. Pairs with the manifest: skill teaches *how*, manifest is the *data*.

7. **`c11 wrapper-explain <tool> <argv>` as an executable oracle.** Operator/agent introspection: `c11 wrapper-explain claude attach abc123` → `policy=supervisor_pool passthrough=true inject_session=false inject_hooks=false metadata=optional`. Agents stop reading bash to debug their environment; they ask c11 what c11 thinks. Foundation skill for the flywheel.

---

## 4. Leverage Points (Sorted by Impact-to-Cost Ratio)

1. **`Resources/bin/claude:126` — the case statement.** Both reviewers identify this single line as the chokepoint for every future Anthropic CLI verb. Promoting it to named predicates (cheap) or a manifest (medium) gives c11 a one-line policy-update path for the next decade. Same line in spirit at `Resources/bin/codex:80` for OpenAI's CLI.

2. **`tests/test_claude_wrapper_hooks.py:38` — the existing harness.** Fake real Claude, fake socket, live/stale/missing cases. Already sufficient to test PR #150 behaviorally. The cheapest credible test-coverage improvement in the repo right now. Highest leverage for catching the next "forgot to add the verb" regression.

3. **`Resources/bin/claude:151` and the `set-agent` background call.** Already a hot pipe carrying very little. Enriching with `--mode supervisor` / `--mode attached --session <short_id>` (Mutation 5 in Claude's review) is near-zero cost; every c11 UI surface gets richer state to render. Extend the `terminalType` canonicalization in `Sources/WorkspaceMetadataKeys.swift:45` to include a `mode` subfield.

4. **`Sources/AgentRestartRegistry.swift:143` — the restore-side mirror.** Today the launch wrapper and the restore registry know about each other only implicitly. A shared Swift vocabulary (even just shared type names) makes the rail end-to-end inspectable. Operators currently can't ask "what will c11 do when I run `claude attach`?" because the answer is split across a bash file and a Swift struct that have never been introduced.

5. **The four-constraint docstring at `Resources/bin/claude:19–33`.** Currently the only spec of the session-resume wrapper protocol. Promoting it to a Swift type is cheap and creates a single source of truth that future wrapper authors (opencode, kimi, future TUIs) can reference. Foundation for both the test corpus and the eventual Swift `c11-launch` lift.

6. **The bash → Swift lift as the natural endpoint.** When the wrapper hits ~300 lines of case statements and timeout incantations, the shape it wants is a small `c11-launch <tui>` binary: shared socket-ping path, compiled-in manifest, Swift test surface for argv classification, no more 0.75s timeouts reimplemented in three places. The PATH-scoped wrappers become 1-liners that `exec c11-launch claude "$@"`.

---

## The Flywheel (Both Reviewers Converge)

Both reviewers describe the same loop in different vocabulary:

1. Upstream TUI ships a new verb / capability.
2. c11 classifies it (manifest entry / named predicate).
3. Tests lock the classification (corpus driven through the wrapper).
4. Skill / docs teach agents the new behavior.
5. c11 UI exposes the new state (sidebar, set-agent mode).
6. The next upstream change becomes a vocabulary addition, not an emergency wrapper patch.

What's missing today: programmatic argv classification tests, named policy classes, a manifest, an explain CLI, and skill coverage of supervisor semantics. Each is a small standalone increment. Together they make the wrapper a verb-taxonomy artifact instead of a growing pile of bash special cases.

---

## Closing Synthesis

Both reviewers independently land on the same headline: **PR #150 is correct in scope and should ship; the work it reveals is the interesting territory.** The wrapper has quietly become the agent-launch policy layer, and Agent View is the first clear signal that upstream is moving toward background-agent supervisors as the primary unit of work. c11 has a roughly six-month window to name the policy classes, lock them with tests, teach agents through the skill system, and decide whether supervisor sessions are surface attributes or first-class objects — before the bash case statement hits the size where every refactor is expensive.

The narrow fix is thirteen lines. The shape it wants is a manifest, a test corpus, a Swift type, and a sidebar that knows what a background session is. Each step is small. The compound effect is c11 becoming the stable room where every TUI's evolution lands as vocabulary rather than rework.
