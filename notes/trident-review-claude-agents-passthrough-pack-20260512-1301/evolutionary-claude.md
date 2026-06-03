## Evolutionary Code Review
- **Date:** 2026-05-12T17:03:13Z
- **Model:** Claude (claude-opus-4-7)
- **Branch:** fix/claude-agents-wrapper-passthrough
- **Latest Commit:** 0fdb91e65
- **Linear Story:** claude-agents-passthrough (no Linear ID; c11 PR #150)
- **Review Type:** Evolutionary/Exploratory

---

## What's Really Being Built

The stated feature is "thirteen lines to keep a wrapper out of the way of seven new subcommands." That framing undersells what is actually present here.

What is really being built — and has been quietly accreting for several months across the `Resources/bin/claude` and `Resources/bin/codex` wrappers — is a **shadow protocol between c11 and every TUI agent its operator runs**. The wrapper is not just an injector of `--session-id` and `--settings`. It is the only piece of c11 code that runs *before* the agent process exists, in the agent's own argv space, with enough context to:

- decide whether the launch is a fresh interactive session, a sub-tool invocation (`mcp`, `config`), or now a *supervisor-pool operation* (`agents`, `attach`, `logs`, …),
- conditionally rewrite the launch to thread c11 lifecycle into the resulting process,
- gracefully no-op when c11 isn't there.

That is, in effect, a **per-TUI dispatcher** — a tiny PID-1 for the operator's mental model of "what is this agent process going to do?" The Agent View passthrough makes this very concrete: Claude Code 2.1.139 just *added a new class of verbs* (supervisor-pool verbs, distinct from session verbs) and the wrapper now needs to triage them. That is not a bash hack accumulating special cases — that is **a verb taxonomy reaching mass**.

The other capability quietly being built is the **session-resume rail** itself: a contract where each TUI emits a session ID into surface metadata via lifecycle hooks (`claude.session_id`) or default-resume convention (`codex resume --last`), and `AgentRestartRegistry.phase1` synthesises a typed-resume command at restore time. PR #150 protects this rail by ensuring supervisor-pool verbs don't accidentally write a *fresh* synthetic uuid into the rail's metadata stream.

So this PR is, in narrative terms: **"protect the session-resume rail from a new class of upstream verb."** That's a class of work that will recur as Anthropic/OpenAI/etc. keep shipping new shell subcommands. The interesting question is not "did we add the right seven strings to the case?" but **"what is the right shape for this triage layer in 6 months when there are forty verbs and four TUIs?"**

A name worth claiming: this is the **agent-launch shim layer** — c11's narrowest, most load-bearing seam into the agent ecosystem, and the one place where the principle of "host and primitive, not configurator" gets cashed out as code that *actually has to know things about other people's products*.

---

## Emerging Patterns

Reading the two wrappers (`claude`, `codex`) side by side is the most useful angle. Several patterns are forming. Some want to be formalised; one or two are anti-patterns to catch early.

**Pattern 1 — Verb classification by case statement.**
Both wrappers have a "non-interactive subcommands" passthrough list:

- `claude`: `mcp|config|api-key|rc|remote-control|agents|attach|logs|stop|kill|respawn|rm` (Resources/bin/claude:126)
- `codex`: `exec|review|login|logout|mcp|mcp-server|app-server|app|completion|sandbox|debug|apply|cloud|exec-server|features|plugin|help|--help|-h|--version|-V|-VV` (Resources/bin/codex:80)

That's twenty-five strings in 100 lines of bash, with no shared structure. Each one is a load-bearing assertion about *what an upstream verb means semantically*. When upstream adds another verb, somebody has to know to add it here. When upstream renames or removes one, our wrapper silently keeps applying the wrong policy. This is the **anti-pattern to catch early**: implicit upstream-vocabulary coupling in plain bash.

**Pattern 2 — Two verb classes are already present; PR #150 surfaces a third.**
The case statement is starting to multiplex three semantically distinct policies into one allowlist:

- **non-interactive utilities** (`mcp`, `config`, `completion`, `--version`): no session, no surface telemetry, just pass through.
- **interactive sessions** (default fallthrough): inject `--session-id`, inject `--settings`, declare agent, write surface metadata.
- **supervisor-pool operations** (new in 2.1.139: `agents`, `attach`, `logs`, `stop`, `kill`, `respawn`, `rm`): pass through *but they are still interactive*, the user is still typing into c11, and there is something for c11 to know about that we are currently throwing away.

That third class is the interesting one. It's been collapsed into "passthrough" for expedience, and the PR comment is honest about that: "supervisor-pool operations bypass [the rail] by construction." But the *operator's session* is still happening in a c11 surface. The fact that the operator is now attached to a background session is a fact c11 could carry on the surface, and currently doesn't.

**Pattern 3 — "Best-effort, never block, never break launch."**
Every interaction with the c11 socket has the same shape: bounded timeout (`CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC=0.75`), `>/dev/null 2>&1`, run in `&` background with `disown`, and the fallback if anything fails is "exec the real binary unchanged." This is *the right pattern* for this layer — operator latency is sacred — and it should be promoted from "two copies in bash" to a documented contract.

**Pattern 4 — Tempfile-based settings injection (claude:199–205).**
`claude` 2.1.119 dropped inline `--settings` JSON, so c11 writes per-PID files into `$TMPDIR`. The comment says "leaks until /tmp is reaped on reboot." This is a quiet trash heap that costs nothing today but will produce a useful question in a year: *how many JSON hook files has my Mac silently generated?* It's also a small command-injection-adjacent surface — if the hooks JSON ever takes user input.

**Pattern 5 — `--bg` is the elephant.**
The commit message names this directly: `claude --bg "<prompt>"` is a flag, not a subcommand. It currently still gets `--session-id` and hooks. That's a bug that *would* be caught by Pattern 1's case statement, but the case statement can't see flags. This is a structural limit of the current shape.

---

## How This Could Evolve

The wrapper, viewed as artifact, has at least three available evolution vectors.

**Vector A — Generalise the verb taxonomy into a declarative manifest.**
Today's bash list becomes a YAML/JSON file shipped in `Resources/`:

```yaml
# Resources/wrappers/claude.yaml
non_interactive: [mcp, config, api-key, rc, remote-control]
supervisor_pool: [agents, attach, logs, stop, kill, respawn, rm]
session_flags_block: ["--bg"]  # flag form (no subcommand)
default_policy: inject_session
```

The wrapper becomes thin code that loads the manifest, classifies argv, and dispatches. Three wins:

1. New upstream verb → one-line YAML edit, not "remember to also update the codex wrapper."
2. The manifest becomes the *single shared statement* of what c11 knows about each TUI's CLI surface — a living vocabulary, reviewable, lintable, and visible to operators who want to know "what does c11 do when I run X?"
3. Eventually, that manifest is **the contract that other tools (cmux, third-party wrappers, agent-aware shells) can read**. c11 starts producing a vocabulary that the ecosystem can consume.

**Vector B — Promote supervisor-pool operations to first-class c11 awareness.**
Right now `claude attach abc123` just passes through. But the operator *just attached this c11 surface to a background session.* c11 has no idea. The surface still reports `terminal_type=claude-code` with a stale `claude.session_id` from whatever was running there before.

Small move: extend the wrapper to do exactly one extra background write on `attach`/`respawn`:

```bash
# Pseudo:
if [[ "$1" == "attach" || "$1" == "respawn" ]]; then
    short_id="$2"
    (c11 set-metadata --key claude.attached_session --value "$short_id" \
                      --key terminal_type --value claude-code \
                      --timeout 0.75) &
fi
exec "$REAL_CLAUDE" "$@"
```

Now c11 *knows* which background session is on the operator's screen, which means the sidebar can show it, the workspace snapshot can capture it, and restore can re-attach to the same background session by short id on next launch. The session-resume rail extends from "fresh sessions only" to "the supervisor-pool itself is part of the rail."

This is the move that turns "get out of the way of Agent View" into "**actively support Agent View as the new primary surface for Claude Code work**."

**Vector C — Lift the wrappers into a Swift binary.**
At some point the bash files will be 300 lines of case statements and timeout incantations. The shape they want to be is a small `c11-launch <tui>` binary that:

- knows the manifest (compiled in or loaded from `Resources/wrappers/*.yaml`),
- shares one socket-ping path with the rest of the c11 CLI (no more 0.75s timeouts re-implemented in three places),
- exposes a clean Swift test surface for argv classification (which is currently untested — `bash -n` is not a test),
- can grow features like "rate-limit hook injection" or "version-gated behaviour" without reinventing them in bash.

The wrappers stay PATH-scoped 1-liners that `exec c11-launch claude "$@"`. The 200-line bash files retire. The four constraints in the file's header docstring become a Swift `enum LaunchPolicy` and its test suite. This is the natural endpoint of Pattern 1.

---

## Mutations and Wild Ideas

Going off-script for a moment, because the prompt asks for it.

**Mutation 1: c11's wrapper layer is the right place to host operator-side observability of every TUI on the system.**
Today the wrapper logs nothing. But every Claude/Codex/Opencode/Kimi invocation is going through this shim. The wrapper is in a perfect position to emit one JSONL line per launch (verb, argv shape, in-c11?, session-resume rail hit?) to a per-day rotating log. Suddenly the operator has a complete record of which TUIs they invoked, how often, with what shape, and where the rail captured vs missed. That's the foundation for "show me my agent week" — a kind of pedometer for orchestration. This is **completely free** because the wrapper is already on every launch.

**Mutation 2: Reverse the polarity — let the wrapper drive c11, not the other way around.**
Currently c11 commands the wrapper ("inject these hooks"). What if the wrapper *queries c11* for per-invocation policy? `c11 wrapper-policy --tool claude --argv "$@"` returns a JSON blob describing what to do (pass through, inject session, set metadata). The wrapper is dumb; the c11 binary owns the policy and can update it without re-shipping the bash file. Hot-update policy across all running surfaces. Operator opts a specific surface out of hooks for one launch. A/B testing of new session-resume strategies live.

This also gives c11 a hook to **enforce operator preferences**: "never inject hooks when running in `~/personal/`," "use a different session-id namespace for worktrees," "block `claude --bg` when this surface is the orchestrator." The wrapper enforces a tenant-level policy expressed by c11.

**Mutation 3: Agent View as the c11 sidebar's twin.**
Claude Code 2.1.139's Agent View is, structurally, a TUI for a process supervisor. c11 has a sidebar that is, structurally, a workspace-tree view for a surface supervisor. These are the same shape from two different vantage points. A wild but coherent variant: **make c11's sidebar show Agent View's background sessions inline.** The wrapper writes `claude.supervisor.sessions = [...]` after every `claude agents` or `claude attach`, the sidebar reads it, the operator sees both their c11 surfaces *and* their attached/detached Claude background sessions in one tree. Drop a background session onto a c11 surface to attach it. Drop the surface into the trash to `claude kill`. This is the unified-supervisor mutation.

**Mutation 4: A wrapper-shaped Skill — `c11-wrappers`.**
The wrapper pattern is currently undocumented as an agent-facing affordance. The constraints listed at the top of `Resources/bin/claude` (the four bullet points) are a *protocol spec*. A `c11-wrappers` skill would let any agent verify "is this TUI wrapped?", "what policy applies to this verb?", "is the rail capturing me right now?" — and would let an agent build a wrapper for a new TUI by following the contract. This converts a tribal piece of bash into a publishable convention.

**Mutation 5: Cross-pollinate with the c11 socket's `set-agent` API.**
The claude wrapper already calls `c11 set-agent --type claude-code` in the background (claude:158–172). The Agent View subcommands are a perfect place to enrich that call: `c11 set-agent --type claude-code --mode supervisor` when the operator runs `agents`, `--mode attached --session <short_id>` for `attach`, etc. The sidebar/HUD gets richer state for free, and the metadata becomes useful for layout decisions ("don't auto-arrange this surface; it's actively supervising background work").

---

## Leverage Points

Sorted by ratio of "lines of code that change" to "future capability unlocked."

1. **The case statement at `Resources/bin/claude:126`** is the single point where every future Anthropic CLI verb has to be triaged. Promoting it to a manifest (Vector A) gives c11 a *one-line policy update* path for the next decade of Claude Code releases. Same for codex line 80.

2. **`AgentRestartRegistry.phase1` (Sources/AgentRestartRegistry.swift:143–178)** is the matching mirror of the wrapper's verb taxonomy on the *restore* side. Today the wrapper and the registry know about each other only implicitly. A single Swift type that owns *both* the launch-time policy *and* the restore-time policy would make the rail end-to-end inspectable. Today an operator can't ask "what will c11 do when I run `claude attach`?" — that knowledge is split across a bash file and a Swift struct that have never been introduced.

3. **The `set-agent` background call (claude:158–172)** is a hot pipe carrying very little. Enriching it with `--mode` and per-verb context (Mutation 5) is a near-zero-cost change that gives every c11 UI surface richer state to render. Specifically: extend `c11 set-agent` schema in `WorkspaceMetadataKeys.swift:45` (where `terminalType` is canonicalised) to include a `mode` subfield. The wrapper writes it; the sidebar reads it.

4. **`bash -n` is not a test.** The wrapper currently has zero programmatic coverage of argv classification. A 50-line Python or Swift test that drives the wrapper with a list of argvs and asserts the dispatched verb class is high-leverage: catches "we forgot to add `respawn` to the list" *before* PR #151 has to add it.

---

## The Flywheel

There is a flywheel here, and it's almost spinning. Components in place:

- The session-resume rail exists end-to-end (wrapper → metadata store → registry → executor types into a fresh surface on restore).
- The wrapper is universal-by-construction for any TUI shipped in `Resources/bin/`.
- The skill system trains agents to *use* c11's primitives correctly.

What completes the loop: **every new TUI verb becomes an evolution of c11's vocabulary, not a regression to its wrapper.**

The way to set it spinning:

1. Make the verb manifest a first-class artifact (Vector A).
2. Wire CI to *test the manifest against a synthetic argv corpus* — so a typo in the manifest fails CI before it ships.
3. Add a one-line "what does c11 do with this command?" CLI: `c11 wrapper-explain claude attach abc123` → "supervisor_pool: passthrough, write claude.attached_session=abc123."
4. The `c11-wrappers` skill teaches agents to consult that CLI. Now agents debugging "why didn't my hook fire?" can interrogate the rail without reading bash. The skill becomes the *user-facing documentation* of the manifest.
5. When upstream ships a new verb, the operator (or an agent) edits the YAML, the CI catches mis-classification, the skill teaches the new verb's policy, the explain CLI surfaces it. The vocabulary grows; the bash never grows.

That's the loop. The wrapper-as-bash blocks it; the wrapper-as-manifest-driven-dispatcher unblocks it.

---

## Concrete Suggestions

### High Value

1. **Extract the verb taxonomy into a declarative manifest.** ✅ Confirmed — Vector A above. Create `Resources/wrappers/claude.yaml` and `Resources/wrappers/codex.yaml` with three buckets (`non_interactive`, `supervisor_pool`, `default: inject_session`). Have both wrappers read the file (via a tiny `awk`/`jq` or — better — via `c11 wrapper-policy`). Risk: adds a runtime dependency on a file existing; mitigation is shipping it in the bundle next to the wrapper. Worth doing as a follow-up to this PR.

2. **Add an argv-classification test corpus.** ✅ Confirmed. Sketch: `tests/wrappers/claude_argv_corpus.json` listing argv arrays + expected classification. A tiny Python runner invokes `bash Resources/bin/claude --c11-debug-classify "$@"` (new flag — under 5 lines to add) and diffs against expected. Catches the "forgot to add `respawn`" class of bug before it ships. Today this PR's only validation was `bash -n`; we can do better cheaply.

3. **Write the attached-session ID to metadata on `claude attach`/`respawn`.** ❓ Needs exploration. Vector B above. Mechanically simple (one extra `c11 set-metadata` background call inside the wrapper's passthrough branch). The exploration needed: how the sidebar should *render* `claude.attached_session`, and whether the restore path should care (does `claude attach <short_id>` survive across c11 restarts? Probably yes, since the short id is supervisor-scoped). If yes, the rail extends to background sessions for free. Verified the metadata APIs exist (`Sources/SurfaceMetadataStore.swift:155–225`).

4. **Document the wrapper contract as a Swift type, even before lifting to Swift.** ✅ Confirmed. Today the four constraints in the wrapper's docstring (Resources/bin/claude:19–33) are the *only* spec of the session-resume wrapper protocol. Promote them to a doc-commented `enum WrapperPolicy` in Swift that *isn't called by anything yet*. This is cheap, future-proofs the lift, and creates a single source of truth that agents (and future wrapper authors for opencode/kimi) can reference. Pairs naturally with `AgentRestartRegistry.phase1`.

5. **Address `claude --bg <prompt>` explicitly in this PR's follow-up.** ✅ Confirmed — the commit message already names it as out-of-scope. The current behaviour (the wrapper still injects session-id + hooks for `--bg` because it's a flag, not a subcommand) is at minimum surprising and at worst buggy: c11's surface-scoped hooks fire against a detached supervisor process. A small post-PR change: scan argv for `--bg` *before* the case statement and route to a third policy ("bg-detached: inject hooks but mark them as supervisor-routed"). This is the structural-limit case that motivates Vector A.

### Strategic

6. **Promote `--bg` and Agent View to first-class c11 concepts.** ❓ Needs exploration. Mutation 3 above. If Claude Code is moving toward background-as-default (Agent View is the strongest signal so far), then c11's surface model — which assumes "one surface = one foreground process" — is going to feel increasingly cramped. Strategic move: design a c11 surface-state variant for "this surface is currently attached to background session X, which is in state Y." Not a fork of the surface concept, an *attribute*. Decision-shaping question: should the sidebar render a tree of background sessions independent of surfaces? My instinct is yes — they're the new primary unit of agent work — but this is the kind of thing that benefits from prototyping before committing.

7. **A `c11-wrappers` skill.** ✅ Confirmed (Mutation 4). The wrapper pattern is mature enough to be teachable: four constraints, two reference implementations, a clear test of correctness (does it pass through cleanly outside c11? does the rail fire inside?). Writing this as a skill formalises the convention and gives agents a path to add wrappers for new TUIs without rediscovering the constraints from the docstring. Pairs well with the manifest extraction (Vector A): the skill teaches *how* to author a manifest entry; the manifest is the data.

8. **Operator-side observability via wrapper-emitted JSONL.** ❓ Needs exploration. Mutation 1. Cost: one `printf` per launch into a rotating log. Value: a complete record of which TUIs the operator invoked, when, with what shape — feeds operator dashboards, retro tooling, "agent week" reviews. The exploration: where does the log live (in `~/Library/Logs/c11/wrappers/`?), what's the rotation policy, and is there any PII surface (probably not — argv first-token only).

### Experimental

9. **Wrapper-as-policy-client (Mutation 2).** Have the wrapper ask c11 *what to do* with each launch, rather than carrying its own policy. Inverts the model. Lets c11 evolve session-resume behaviour without re-shipping the bash file. Higher risk: adds a latency-sensitive socket call on every launch (current socket-ping is already ~0.75s timeout-bounded). Worth experimenting with only after Vector A's manifest is in place — at that point, the wrapper is already loading external policy; centralising it in c11 is a small additional step.

10. **Unified supervisor: c11 sidebar shows Agent View sessions.** Mutation 3. The wild variant. Most ambitious; biggest payoff if it lands. Practical first step: a one-day prototype that reads `claude agents --json` (if it exists; if not, file an upstream feature request to manaflow-ai/cmux while we're at it) and renders the list in a c11 debug window. From there, decide whether it deserves first-class sidebar real estate.

11. **Cross-TUI session-resume coherence.** Today each TUI has its own session-id semantics: claude uses uuid-v4, codex uses cwd+`--last`, opencode/kimi are best-effort fresh. As more TUIs converge on "supervisor with background sessions" (Agent View is the bellwether), c11 could host a *normalised* session vocabulary across them. The metadata store already namespaces (`claude.session_id` is reserved). A `agent.supervisor_session_id` family — keyed by `terminal_type` — would let `AgentRestartRegistry` collapse into a single resolver instead of four hand-written closures. Experimental because we don't yet know what shape codex/opencode/kimi supervisors will take.

---

## Closing

PR #150 is the right shape for its stated scope: 13 lines, a clear comment, a load-bearing fix that prevents a real wedge in a freshly-shipped Anthropic feature. Land it. The interesting work is what it reveals: the wrapper is becoming a verb-taxonomy artifact, and the verb taxonomy is starting to want a real home — both for its own clarity and for the bigger move of c11 *actively supporting* Agent View instead of just getting out of its way. The leverage is in extracting the taxonomy, testing it, and giving agents a way to see it. Once that's in place, every future upstream verb is a YAML line and a sidebar render, not a bash patch.

The wrapper is small; the surface it sits on is large. Treat it accordingly.
