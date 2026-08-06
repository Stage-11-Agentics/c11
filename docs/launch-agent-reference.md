# `c11 launch-agent` — launching typed agents

The canonical reference for launching a typed coding agent into a c11 surface with
one command: correct invocation for the agent's CLI, model/effort pinned, identity
stamped at birth, machine-readable refs back to the caller.

```
c11 launch-agent --type <kind>
    [--model <id>] [--effort <tier>]
    [--system-prompt-mode inherit|append|replace]
    [--system-prompt <text> | --system-prompt-file <path>]
    [--task <id>]
    [--pane <ref> | --workspace <ref> | --new-workspace] [--cwd <path>]
    [--prompt <text> | --prompt-file <path>]
    [--title <text>] [--flag <reason>] [--suppressed]
    [--env KEY=VALUE ...] [--json]
```

`launch-agent` is the programmatic sibling of the A button. Where
`c11 default-agent launch` launches *whatever the operator configured as the
default*, `launch-agent` launches *a specific agent kind* — the primitive an
external controller (a Stream Deck, a MIDI deck, another agent) needs to say
"give me a Codex on gpt-5.2 in a new workspace, prompted with this brief."

## Why one command

Hand-composing agent launches means re-implementing, per caller: the claude PATH
wrapper + `--dangerously-skip-permissions`, codex `--yolo` (never `exec` for a
visible surface), per-CLI model/effort flag syntax, `C11_AGENT_TYPE/MODEL/TASK`
env declaration, `set-agent` metadata, and tab naming. c11 already knows every one
of these facts (`AgentRegistry`, `DefaultAgentConfigStore`,
`DefaultAgentResolver`); `launch-agent` makes it own them at the launch site.

## Semantics

### Agent kind (`--type`, required)

One of the built-in kinds — `claude-code`, `codex`, `grok`, `kimi`, `opencode`,
`github-copilot`, `pi`, `omp` — or any kebab-case custom kind with a user launch
template on disk (see [Custom kinds](#custom-kinds)). An unknown kind with no
template is an error (`unknown_agent_type`), never a guess.

### Base command resolution

The launch line starts from the same command the A button would use, so
`launch-agent` stays coherent with **Settings → Agents & Automation → Agent
Launcher**:

1. Project config `.c11/agents.json` entry for the kind (walk-up from the launch
   cwd), else
2. the operator's per-agent Settings command, else
3. the registry factory command (`claude --dangerously-skip-permissions`,
   `codex --yolo`, …).

Operator `envOverrides` from the same config are applied to the spawn env.

### Model and effort (`--model`, `--effort`)

Injected as flags using the **launch template** for the kind (below) — the
per-CLI syntax is data, not caller knowledge. Precedence per field:

1. a flag the operator hardcoded into the configured command (never duplicated),
2. the `--model` / `--effort` CLI argument,
3. the model/effort pinned in Settings (project entry beats user entry),
4. nothing — the agent's own ambient default.

If the kind's template declares no model (or effort) syntax and the caller passed
`--model` (or `--effort`), the launch fails with `model_flag_unsupported` /
`effort_flag_unsupported` rather than silently dropping the request. When a
template declares an allowed-values list (claude effort tiers, pi/omp thinking
levels), the value is validated early with a friendly error; otherwise it is
passed through and the agent CLI enforces.

### System prompt (`--system-prompt-mode`, `--system-prompt` / `--system-prompt-file`)

A launch-time override of the agent's system prompt, injected as a flag using
the kind's launch template — data, not caller knowledge. Three modes:

- `inherit` (the absence of the flag): leave the harness default untouched — no
  flag injected. This is the default when `--system-prompt-mode` is omitted.
- `append`: add the text on top of the harness default (claude
  `--append-system-prompt '<text>'`).
- `replace`: supplant the default with the text (claude `--system-prompt
  '<text>'`). An **empty** text is allowed and intentional — the blank-slate
  launch (`--system-prompt ''`).

The text rides `--system-prompt <text>` (inline) or `--system-prompt-file
<path>` (mutually exclusive, for prompts longer than a sentence). Unlike
`--prompt-file`, an **empty** system-prompt file is accepted (it is the blank
slate). System-prompt text is free-form prose and is always single-quoted, the
same treatment as the positional initial prompt.

Precedence, top wins (mirrors `--model`/`--effort`):

1. a system-prompt flag the operator hardcoded into the configured command
   (either `--append-system-prompt` or `--system-prompt` — c11 injects nothing
   on top, with a warning if a mode was also requested),
2. the `--system-prompt-mode` CLI request,
3. the system prompt pinned in Settings (the config base layer),
4. nothing — inherit.

If the kind's template declares no system-prompt syntax and the caller passed a
non-`inherit` `--system-prompt-mode`, the launch fails with
`system_prompt_unsupported` rather than silently dropping the request. **v1 seeds
the axis for `claude-code` only**; every other built-in (and custom kinds) has no
system-prompt axis, so a non-inherit request for them errors. The system-prompt
flag renders after `--model`/`--effort` and before the positional prompt.

### Placement (`--pane` | `--workspace` | `--new-workspace`)

- Default: a new surface in the caller's pane (from `$C11_PANE`/focused pane of
  the current workspace — same target the A button would hit).
- `--pane <ref>`: a new surface in that pane.
- `--workspace <ref>`: a new surface in that workspace's focused pane.
- `--new-workspace`: a fresh workspace whose first terminal is the agent. The
  identity env rides workspace creation (present at PTY birth); the launch
  line is *typed* into the interactive shell (queue-until-ready), not baked as
  the ghostty spawn command — a spawn command execs over the shell, so agent
  exit would kill the surface, and it skips shell rc.

The launch cwd resolves in this order:

1. explicit `--cwd <path>` (resolved CLI-side relative to the caller and
   validated server-side),
2. the target workspace's stable root directory, when set,
3. the launching surface's cwd (the compatibility fallback for rootless
   workspaces).

Set a root during creation with `c11 new-workspace --root <path>` (or `--cwd`,
which establishes the same root by default), then edit or clear it with
`c11 set-workspace-root <path>` / `c11 set-workspace-root --clear`.

Any resolved cwd inside a linked git worktree proceeds with one coded warning.
The warning names the absolute worktree path and carries code
`linked_worktree_cwd`. Explicit `--cwd` remains permitted; a configured
workspace root also counts as explicit intent. A launching-surface cwd is
marked inherited, but is warning-only because linked worktrees are the normal
Lattice delegator shape.

Project `.c11/agents.json` discovery uses this same resolved cwd, so the config
selected for a launch cannot silently come from the GUI app process's cwd.

Launches never steal focus or selection —
`agent.launch` is not a focus-intent method under the socket focus policy, so
the new surface is created unfocused regardless of flags (`--no-focus` is
accepted as a no-op for symmetry with `new-surface`).

### Identity at birth

The new PTY spawns with `C11_AGENT_TYPE`, `C11_AGENT_MODEL`, `C11_AGENT_TASK`
(and their `CMUX_*` legacy aliases) in its environment, and the surface metadata
is stamped server-side before the launch line is typed: `terminal_type`, `model`,
`task` (source `declare`), plus the tab title (`--title`, else the standard
launch placeholder). The sidebar chip, title bar, and `c11 tree` are correct with
zero post-hoc calls; wrappers and skill-driven self-reporting only refine from
there.

`--env KEY=VALUE` (repeatable) adds caller extras to the spawn env after the
operator's configured overrides (caller wins on collision).

### Attention at dispatch (`--flag`, `--suppressed`)

Both apply to the new surface before command delivery, so the attention state is
correct from the first frame. `--flag <reason>` raises a sticky flag — reserved
for operator-designated priority missions (pair with the caller relaying explicit
operator intent). `--suppressed` marks the worker parent-owned: routine
completion never reaches the operator, and the launching agent owes it a
completion channel and the flag-escalation contract. Semantics live in the c11
skill card's attention model; parent-side patterns in
`skills/c11/references/orchestration.md`.

### Prompt delivery (`--prompt` | `--prompt-file`)

Delivered per the template's `promptDelivery`:

- `positional` — appended to the launch argv, single-quoted (claude, codex, grok,
  pi, omp). One shot; no ready-state race.
- `flag <name>` — appended as `<name> '<prompt>'`, for CLIs whose TUI takes an
  initial prompt only via a named flag (opencode `--prompt`). Same one-shot
  argv delivery as `positional`, no ready-state race.
- `post-boot` — typed into the TUI after a fixed delay (kimi, github-copilot),
  the same best-effort rail `default-agent launch` uses today. Racy by nature;
  prefer kinds with argv delivery for orchestration.

`--prompt-file` reads the prompt from a file (use it for anything longer than a
sentence — shell escaping of inline prompts is the caller's problem).

### Output

Human-readable by default; `--json` prints one object:

```json
{
  "ok": true,
  "agent": { "type": "codex", "model": "gpt-5.2", "effort": "high", "task": "sekhem-42" },
  "command": "codex --yolo --model gpt-5.2 -c model_reasoning_effort=high",
  "window_ref": "window:1",
  "workspace_ref": "workspace:4",
  "pane_ref": "pane:9",
  "surface_ref": "surface:341",
  "cwd": "/path/to/project",
  "cwd_source": "workspace_root",
  "warnings": ["workspace root (explicit intent) '/path/to/project' selects linked git worktree '/path/to/project' on 'fix/example'; launch is proceeding."],
  "warning_details": [{
    "code": "linked_worktree_cwd",
    "message": "workspace root (explicit intent) '/path/to/project' selects linked git worktree '/path/to/project' on 'fix/example'; launch is proceeding.",
    "data": {
      "cwd": "/path/to/project",
      "worktree_path": "/path/to/project",
      "worktree_basename": "project",
      "branch": "fix/example",
      "cwd_source": "workspace_root",
      "explicit_intent": true
    }
  }],
  "workspace_id": "…", "pane_id": "…", "surface_id": "…"
}
```

Refs are immediately valid targets for `send`, `read-screen`, `set-*`.

### Errors and warnings

Errors are structured (`--json` gives `{"ok":false,"error":{"code":…,"message":…}}`):

| code | when |
|---|---|
| `unknown_agent_type` | `--type` is not a built-in kind and no user template exists |
| `empty_command` | the kind resolved to an empty launch command (unconfigured `custom`/template) |
| `model_flag_unsupported` / `effort_flag_unsupported` | `--model`/`--effort` passed for a kind whose template declares no syntax for it |
| `system_prompt_unsupported` | a non-inherit `--system-prompt-mode` passed for a kind whose template declares no system-prompt syntax |
| `invalid_effort` | value outside the template's declared allowed list |
| `invalid_params` | bad `cwd`, or `new_workspace` combined with `pane_id`/`workspace_id` |
| `not_found` | target workspace or pane doesn't resolve |

A conflicting `--prompt`/`--prompt-file` pair is rejected CLI-side before the
socket call. A launch binary that can't be found is a **warning**, not an
error — the app-process PATH is poorer than the login-shell PATH a pane
actually gets, so the result carries `"warnings": ["binary '<x>' not found …"]`
and the launch proceeds (a truly missing binary shows the shell error in the
pane). A linked-worktree cwd is also reported once in this legacy warnings
array and as a structured `warning_details` entry with code
`linked_worktree_cwd`. The CLI prints the coded warning once to stderr in both
human and `--json` modes while the launch proceeds.

## Launch templates

The per-kind launch facts are **data on the agent manifest**
(`Sources/AgentManifest.swift` → `LaunchTemplate`), not code at call sites:

```swift
struct AgentLaunchTemplate {
    let modelArg: AgentLaunchArgStyle?   // how "--model <id>" renders for this CLI
    let effortArg: AgentLaunchArgStyle?  // how "--effort <tier>" renders
    let effortValues: [String]           // non-empty → validated early
    let promptDelivery: AgentPromptDelivery  // .positional | .flag(String) | .postBoot
    let systemPromptArg: AgentSystemPromptArg?  // append/replace flags, or nil (no axis)
}
enum AgentLaunchArgStyle {
    case flag(String)       // "--model" → `--model <v>`
    case configKV(String)   // "model_reasoning_effort" → `-c k=<v>`
}
struct AgentSystemPromptArg {
    let appendFlag: String?   // append mode → `<appendFlag> '<text>'`
    let replaceFlag: String?  // replace mode → `<replaceFlag> '<text>'` (empty allowed)
}
```

### Built-in seeds

| kind | model | effort | effort values | system prompt | prompt |
|---|---|---|---|---|---|
| `claude-code` | `--model` | `--effort` | low, medium, high, xhigh, max | `--append-system-prompt` / `--system-prompt` | positional |
| `codex` | `--model` | `-c model_reasoning_effort=` | (pass-through) | — | positional |
| `grok` | `--model` | — | | — | positional |
| `kimi` | `--model` | — | | — | post-boot |
| `opencode` | `--model` (provider/model) | — | | — | `--prompt` (bare TUI) |
| `github-copilot` | `--model` | — | | — | post-boot |
| `pi` | `--model` | `--thinking` | off, minimal, low, medium, high, xhigh | — | positional |
| `omp` | `--model` | `--thinking` | off, minimal, low, medium, high, xhigh | — | positional |

The system-prompt axis is claude-code-only in v1 (other harnesses map to their
equivalent flag in a later phase, the same way effort was staged); a non-inherit
system-prompt request for a kind with `—` errors `system_prompt_unsupported`.

Notes: opencode's prompt goes through `--prompt` **because** its factory
command is the bare interactive TUI, whose only positional is `[project]` — a
path, not a message. An operator who reconfigures the base command to the
one-shot `opencode run` form owns the delivery consequences. kimi's
`--thinking` is boolean, not tiered, so it is not mapped to `--effort`.

### Custom kinds

A kebab-case kind that is not built-in resolves its template from
`~/.config/c11/agents/<kind>.json`:

```json
{
  "command": "aider --yes-always",
  "modelFlag": "--model",
  "effortFlag": null,
  "effortValues": [],
  "promptDelivery": "post-boot",
  "env": { "AIDER_ANALYTICS": "false" }
}
```

Only `command` is required. This file is the launch-template subset of the
planned runtime agent manifest (`docs/agent-registry-design.md` §7); when full
TOML manifests land, they subsume it. Custom kinds get env identity + metadata
stamping like built-ins (`terminal_type` = the kind), but no branded chip, no
detection, no resume.

## Socket method

CLI `launch-agent` is a thin client over one v2 method, `agent.launch`:

```json
{ "method": "agent.launch",
  "params": { "type": "codex", "model": "gpt-5.2", "effort": "high",
              "system_prompt_mode": "append", "system_prompt": "…",
              "task": "sekhem-42", "prompt": "…", "title": "…",
              "pane_id": "<uuid>" | "workspace_id": "<uuid>" | "new_workspace": true,
              "cwd": "/path", "env": {"K": "V"} } }
```

`system_prompt_mode` ∈ `inherit | append | replace` gates the axis;
`system_prompt` carries the text (empty allowed on `replace` = blank slate). An
unparseable mode is treated as no override; the planner is the single validation
authority (it emits `system_prompt_unsupported` for a non-inherit mode on a kind
with no axis).

`pane_id`/`workspace_id` take UUIDs — the CLI resolves `pane:N`/`workspace:N`
short refs client-side before sending, and direct socket callers must do the
same (resolve via `system.tree` or `c11 identify`).

The handler performs resolution, surface creation, env injection, metadata
stamping, and command typing **atomically server-side** — a caller never has to
sequence create → stamp → send itself. Response is the JSON object above.
Follows the socket threading policy (parse/validate off-main; UI mutation
scheduled on main) and the no-focus-steal policy.

## Relationship to existing commands

- `c11 default-agent launch` — unchanged; still "launch the operator's default."
  Internally both share `DefaultAgentResolver` + `DefaultAgentLaunchComposition`.
- The A button — unchanged; same resolver, same stamping.
- `$C11_DEFAULT_AGENT_LAUNCH` — unchanged; the per-shell export still reflects
  the operator's default agent only.

## Consumers

First consumer: Sekhem Prime's provider/harness selector — deck knobs choose
`{type, model, effort}`, Sweep A shells out to
`c11 launch-agent --type … --model … --effort … --new-workspace --json` and
tracks the returned refs.
