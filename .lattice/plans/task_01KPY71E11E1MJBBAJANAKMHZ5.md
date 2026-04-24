# C11-14: Default terminal agent: launch a configured agent on new-terminal

Let the operator configure a **default terminal agent** for new terminal surfaces. When set, 'new terminal' boots directly into that agent (claude, codex, kimi, opencode, …) with a configured parameter set instead of dropping into bash. The bash experience is still available via an explicit 'new bash terminal' action.

## Motivation

Surfaced while orchestrating C11-13: the delegator was launched via `claude --dangerously-skip-permissions` and quietly booted on Sonnet 4.6 because no `--model` was passed. The operator had no way to say 'every claude I launch in c11 should be Opus 4.7' without editing every prompt or wrapper. Most operators open dozens of terminals a day and want the same agent in the same shape every time.

## Proposal

- **Settings:** a 'Default terminal agent' section with:
  - **Agent type** — dropdown (claude-code, codex, kimi, opencode, custom, or 'none/bash').
  - **Model** — free text or per-agent picklist (e.g., `claude-opus-4-7`, `claude-sonnet-4-6`).
  - **Flags / arguments** — free text (e.g., `--dangerously-skip-permissions`, `--yolo`).
  - **Initial prompt / file** — optional, for always-on skill loads or orientation.
  - **Working directory** — inherit vs. fixed.
  - **Env overrides** — key=value list.
- **Two new-terminal actions** in the UI + CLI:
  - 'New terminal' → uses default agent config (if set) or bash.
  - 'New bash terminal' → always bash, regardless of default.
- **Per-workspace override** — workspaces can override the default (some workspaces are 'claude' workspaces, some are 'shell' workspaces).
- **CLI surface:** `c11 new-split` / `c11 new-pane` / `c11 new-surface` get a `--agent <name>` flag that resolves the named config, and a `--bash` flag that forces plain shell. Existing behavior becomes 'default agent if configured, else bash' for backward compat.

## Open questions

- Config storage: c11 settings JSON vs. per-project (`.c11/agents.json`)? Probably both — project beats user.
- Should configs be named (`claude-opus`, `claude-haiku`, `codex`) so the operator can pick at new-terminal time?
- Interaction with `c11 install <tui>` is out of scope (principle: c11 is unopinionated about the terminal and does not write to external TUI configs). This feature stays inside c11's boundary — we launch the agent but don't reconfigure its settings.
- How does this compose with sub-agent lineage? If the delegator spawns a sibling surface, should the default-agent config apply there too, or only to operator-initiated new-terminals?
