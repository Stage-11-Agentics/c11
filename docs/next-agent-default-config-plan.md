# PLAN — a "next default agent" model/effort primitive for c11

**Status:** plan only, nothing implemented.
**Author:** planning agent (Opus), 2026-07-18.
**Driver:** Sekhem Prime's RIGHT-Vinyl "new-agent defaults" selector, which today is a
mock because c11 exposes no state for "the next agent you spawn should boot as model X
at effort Y." This plan specifies the c11-side primitive that turns that mock real.

---

## 0. TL;DR

The machinery to launch an agent at a pinned **model + effort already exists and is
wired end to end** — `AgentConfig` carries `model`/`effort`, and `DefaultAgentResolver`
bakes `--model <family>` / `--effort <level>` into the launch command for claude-code.
The **only** missing piece is a way to set those values *without opening Settings*, live,
from the CLI/socket — exactly what a physical fader needs.

Recommendation: add a **session-scoped sticky override tier** (`NextAgentOverride`) that
sits above the persisted config but never rewrites it, driven by
`c11 default-agent set-next --model … --effort …`. Dial the deck once, it holds, every
spawn inherits it, the operator's saved Settings stay untouched.

---

## 1. How default agents launch today (traced, with file:line)

### 1.1 The one resolver everything funnels through

`Sources/DefaultAgentResolver.swift` — a **pure** function, no I/O:

```
DefaultAgentResolver.resolve(explicitAgent:userDefault:projectConfig:)
   → (agent: AgentType, launch: ResolvedAgentLaunch)
```

`ResolvedAgentLaunch` (`DefaultAgentResolver.swift:10`) = `{ command, bareCommand,
initialPrompt, envOverrides }`:

- `command` — full shell line typed into the PTY (for claude-code, the initial prompt is
  appended as a single-quoted positional arg; `buildCommand`, line 63).
- `bareCommand` — same launcher, no baked prompt; exported as `C11_DEFAULT_AGENT_LAUNCH`
  so orchestrators can append their own prompt (`launcherCommand`, line 82).

**Model / effort injection** lives entirely here:

- `launcherCommand` (line 82) appends `modelFlag` then `effortFlag` to `config.command`.
- `modelFlag` (line 106) → `--model <family>` **only when** `supportsModelFlag(agent)`
  (line 97, **claude-code only** today), a family is pinned, and the operator hasn't
  already hardcoded `--model` into their command (that always wins).
- `effortFlag` (line 125) → `--effort <level>` under the same guards
  (`supportsEffortFlag`, line 117, also claude-code only).
- `supportsModelFlag` / `supportsEffortFlag` are deliberate **seams** so codex (also
  `--model`) can opt in later without touching call sites.

### 1.2 The config model

`Sources/DefaultAgentConfig.swift`:

- `AgentType` (line 6): `claude-code, codex, grok, kimi, opencode, github-copilot, pi,
  omp, custom`. Sekhem only cares about claude-code.
- `ClaudeModelFamily` (line 75): `opus, sonnet, haiku, fable` — raw values are exactly
  what `claude --model <alias>` accepts. **1:1 with Sekhem's `modelTokens`.**
- `ClaudeEffort` (line 106): `low, medium, high, xhigh, max` — exactly `claude --effort`.
  **1:1 with Sekhem's `effortTokens`.**
- `AgentConfig` (line 134): `{ command, initialPrompt, envOverridesText, model, effort }`.
  The `model`/`effort` fields **already exist and decode from persisted JSON** (line 164;
  absent → `""` = inherit).
- `DefaultAgentConfig` (line 215): `{ defaultAgent, agents: [AgentType: AgentConfig] }`.
- `DefaultAgentConfigStore` (line 319): UserDefaults singleton, key
  `defaultTerminalAgentConfig.v2`. `current` is recomputed on every access (line 333) so
  socket-driven writes propagate live with no restart. Mutators: `save` (347),
  `update(agent){mutate}` (354), `setDefaultAgent` (363), `reset` (369).
- Project override: `.c11/agents.json`, loaded by `DefaultAgentProjectConfig.find(from:)`;
  a file that omits `defaultAgent` must not displace the user's pick
  (`overrideDefaultAgent`, line 236).

### 1.3 The four resolve call sites (all identical resolver, different consumers)

1. **Per-shell env seed** — `Sources/GhosttyTerminalView.swift:3387`. On **every** PTY
   spawn (terminals included). Exports `C11_DEFAULT_AGENT_LAUNCH` (= `bareCommand`, line
   3393) and `C11_DEFAULT_AGENT_SEED_PROMPT` (line 3396). `explicitAgent: nil`. Resolved
   per shell — preference changes only affect newly spawned shells.
2. **The "A" button** — `Sources/Workspace.swift:11924`,
   `launchAgentSurface(inPane:explicitAgent:)`. Creates a terminal, types
   `resolved.launch.command + "\n"`, then `stampLaunchIdentity` (line ~11960) stamps the
   pinned model + placeholder title into the sidebar (`source=.declare`) so the sidebar
   doesn't wait on an agent round-trip. `explicitAgent` carries the right-click
   "launch this one now" override.
3. **Workspace-creation-with-agent (blueprint)** — `Sources/AppDelegate.swift:6493`.
   Bakes `command + "\n"` into the first empty terminal `SurfaceSpec`.
4. **Socket launch** — `Sources/TerminalController.swift:8750`, behind
   `default_agent launch [--agent <type>] [--pane <id> | --in-surface <uuid>] [--cwd]
   [--prompt | --prompt-file]` (`defaultAgentLaunch`, line 8693).

### 1.4 Socket + CLI surface today

- Socket (`TerminalController.swift`): `default_agent {get | set <type> | launch}`
  (`defaultAgentCommand`, line 8666); `agent_config {get <type> | set <type>
  [--command | --initial-prompt | --env-overrides | --reset]}` (`agentConfigCommand`,
  line 8884). Dispatched in `Sources/SocketHandlers/SocketDispatch.swift:793`.
- CLI (`CLI/c11.swift`): `default-agent {get | set | launch}`
  (`runDefaultAgentCommand`, line 11116). There is **no** `agent-config` CLI subcommand.
- **Gap:** `agent_config set` exposes command / initial-prompt / env-overrides but
  **not `--model` / `--effort`** (line 8927–8949). So the persisted model/effort fields
  are writable *only* through the Settings UI (`DefaultAgentSettingsView`). No live,
  scriptable write path exists — this is the hole Sekhem falls into.

### 1.5 About `CMUX_AGENT_MODEL` / `_TYPE` / `_TASK` (correcting the brief's assumption)

These are **consumed** by `Resources/bin/claude:159-175`, but only to call
`c11 set-agent --type/--model/--task` in the background — that is **sidebar telemetry**
(what the sidebar *displays*), **not** an injection of `--model` into the real claude
launch. And they are **not seeded anywhere in the c11 source** — the consumption hook
exists, the producer does not. So they are *not* a usable rail for "boot the next agent
as model X"; the real model injection is the `--model` flag baked by the resolver
(§1.1). Do not build the primitive on these vars.

**Net:** the launch pipeline already honors a pinned model/effort. We need a
**write/override path** into it that a fader can drive.

---

## 2. The primitive — options weighed

### Option A — Persist into the existing per-agent config

Extend `agent_config set <type>` with `--model` / `--effort` (and add an `agent-config`
CLI wrapper, or fold `set-model`/`set-effort` into `default-agent`). Writes straight to
`DefaultAgentConfigStore` via `update(agent){ $0.model = … }`.

- **Pros:** smallest change; reuses store + resolver + Settings UI verbatim; deck and
  Settings stay in sync (the operator can *see* the value); genuinely persistent across
  restart, which mirrors a physical selector that holds its position; per-agent-type
  correct; also closes the pre-existing `agent_config` gap (§1.4).
- **Cons:** the deck becomes a **hidden editor of the operator's saved Settings** — a
  stray fader nudge permanently overwrites a deliberate Settings choice; it's
  global-per-type, not scoped to "this working session"; no one-shot semantics.

### Option B — One-shot "next launch" override

`c11 set-next-agent-config --model X --effort Y` writes transient state consumed by the
*next* agent-launch resolve, then cleared.

- **Pros:** never touches Settings; literal "dial → spawn → branded."
- **Cons:** "next" is **racy** — the env-seed resolve (§1.3 site 1) fires on *every*
  terminal spawn, so a consume-once token can be eaten by an unrelated plain-terminal
  spawn unless carefully scoped to agent launches; and a fader that *holds* a band maps
  badly to consume-once (you'd have to re-dial before every single spawn).

### Option C — Session-scoped **sticky** override tier  ⭐ recommended

Introduce a new, explicitly transient precedence layer above the persisted config and
below an operator-hardcoded flag:

```
NextAgentOverride { model: String?, effort: String?, agent: AgentType?, once: Bool }
```

held by `DefaultAgentConfigStore` (in-memory, lock-guarded; **not** persisted across app
relaunch by default). New model/effort precedence inside `resolve`:

```
hardcoded --model/--effort in command   (existing guard, unchanged)
  ▷ session override (NextAgentOverride)   ← NEW
    ▷ project .c11/agents.json
      ▷ user Settings default
```

The override is a **partial patch**: only the fields it sets are applied onto the chosen
`AgentConfig` before `buildCommand`. It does not change the agent *selection* unless
`agent` is set (Sekhem leaves it nil — it only dials model/effort).

- **Pros:** matches the deck's mental model exactly — dial the fader and it **holds**
  until re-dialed / cleared / app relaunch, and every A-button / new-surface / socket
  launch in between inherits it, **without ever mutating the operator's saved Settings**;
  supports both sticky (default) and `--once`; one obvious clear path; agent-scoped so
  plain terminals are unaffected; Settings remains the durable, operator-owned baseline.
- **Cons:** a new state field + precedence tier (more code than A); an active sticky
  override that isn't shown in Settings can surprise ("why is this agent Opus?") — needs
  a `show-next` readback and (later) a Settings banner.

### Recommendation

**Adopt Option C** as the primitive Sekhem drives. It is the only option whose lifecycle
(sticky, non-destructive, session-scoped) matches a live physical selector.

Fold in the cheap half of **Option A as a secondary, optional affordance**: add
`--model`/`--effort` to `agent_config set` so there's a *deliberate* "make this my
permanent default" path (and to close the existing CLI gap). Not required for Sekhem v1;
keep it distinct from `set-next` so the operator's baseline is never edited by accident.

---

## 3. The Sekhem-facing contract

Replace the RIGHT-Vinyl mock (`Sekhem_Prime/mac/sekhem_prime.swift:249-257`,
"DEFAULTS (mock — NOT applied; c11 new-agent-default TODO)") with a real call.

### Commands

```
# Set the next-agent brand (sticky; holds until re-dialed / cleared / app relaunch).
# Partial is allowed — pass one or both. Idempotent; safe on every Vinyl commit.
c11 default-agent set-next --model <haiku|sonnet|opus|fable> \
                           --effort <low|medium|high|xhigh|max>

# Read it back (deck LED / label confirmation).  → JSON {model, effort, agent, once}
c11 default-agent show-next

# Clear it (a "reset to Settings baseline" gesture).
c11 default-agent clear-next
```

- **Token mapping is identity.** `modelTokens` (`haiku/sonnet/opus/fable`) →
  `ClaudeModelFamily`; `effortTokens` (`low/medium/high/xhigh/max`) → `ClaudeEffort`.
  No translation on the Sekhem side.
- **Optional `--once`** flag for a "brand only the very next spawn" gesture (cleared by
  the agent-launch sites after consumption; the env-seed site reads but never clears).
  Sekhem v1 should **not** pass it — the fader holds a band, so sticky is correct.
- **`--agent <type>`** optional; omit for claude-code (the default). Present so a future
  deck mode could also switch which agent the A-button launches.

### Lifecycle

- **Sticky by default.** Commit once, every subsequent default-agent spawn is branded.
- **Non-destructive.** Never writes `defaultTerminalAgentConfig.v2`; the operator's saved
  Settings are the baseline the override sits on top of.
- **Session-scoped.** Cleared on app relaunch → Settings baseline resumes. Sekhem already
  refreshes deck state on (re)connect, so it re-asserts the brand naturally.
- **LEFT Vinyl is unchanged** — it still types `/model` + `/effort` into the *focused*
  agent (`sendFocused`, line 243-244). This plan fills only the RIGHT-Vinyl gap.

---

## 4. Scope, risks, phased build plan

### v1 (claude-code only — matches the resolver's current flag support)

1. `NextAgentOverride` struct + storage on `DefaultAgentConfigStore` (in-memory,
   lock-guarded getter/setter/clear; not persisted).
2. Add a `sessionOverride:` parameter to `DefaultAgentResolver.resolve` and the
   partial-patch merge (§2 Option C). Keep the resolver pure — callers pass the override.
3. Thread the override read through all four call sites (§1.3). Env-seed site is
   **read-only** (must not clear, fires constantly, must stay cheap — it's on the
   typing-adjacent spawn path).
4. Socket: `default_agent set-next | clear-next | show-next` in `defaultAgentCommand`
   (`TerminalController.swift:8666`). Off-main parse per the socket-threading policy;
   mutate store under its lock.
5. CLI: `default-agent set-next | clear-next | show-next` in `runDefaultAgentCommand`
   (`CLI/c11.swift:11116`), validating `--model` against `ClaudeModelFamily` and
   `--effort` against `ClaudeEffort` with friendly errors; `show-next` prints JSON.
6. Tests (logic-only → **`c11-logic`** scheme, safe to run locally): resolver merge
   precedence (override > project > user; partial patch; hardcoded-command guard still
   wins; non-claude agent → no flag injected); store set/clear/threadsafety; CLI token
   validation. No source-text/AST tests (repo test policy).
7. Skill sync (**HARD RULE**): document `set-next/clear-next/show-next` in
   `skills/c11/SKILL.md` + `skills/c11/references/api.md` (both already touched on this
   branch — coordinate the edit), then run `scripts/sync-installed-skills.sh c11`.

### Later

- Extend `supportsModelFlag` / `supportsEffortFlag` + per-agent flag mapping for codex
  (`--model` + reasoning-effort via `-c model_reasoning_effort=`), grok, opencode. The
  override interface is already agent-agnostic; only the flag emitters change.
- Optional Option A: `agent_config set --model/--effort` (persist to Settings) and a
  `--sticky` flag on `set-next` to persist the override across restart.
- Settings UI: a small "deck override active: opus / high — clear" banner sourced from
  the override, so the operator can see and dismiss why launches diverge from saved
  Settings (mitigates the invisibility risk).

### Risks

- **Invisible override / surprise.** A sticky brand not shown in Settings confuses.
  Mitigate: `show-next` in v1, Settings banner later, and a `c11 log`-style line on set.
- **Non-claude agents.** `set-next` accepts model/effort but they no-op for agents whose
  flags aren't wired yet. Do **not** error — forward-compatible; have `show-next` /
  response note "applies to claude-code today."
- **Concurrency.** Store touched from socket thread + main. Guard with a lock; keep the
  env-seed read allocation-free.
- **Baseline integrity.** `set-next` must never write `defaultTerminalAgentConfig.v2` —
  keeping the override a separate tier is what protects the operator's saved Settings.
- **Env-seed cost.** Site 1 is on the shell-spawn path; the override read there must be a
  cheap struct copy, nothing more.

### Needs the operator

- Confirm **sticky vs one-shot default** (plan recommends sticky).
- Confirm **persist-across-restart** (plan recommends no — a session brand, deck
  re-asserts on connect).
