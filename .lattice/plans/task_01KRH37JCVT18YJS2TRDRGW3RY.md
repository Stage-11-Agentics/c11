# C11-37: Slice 1 — c11-spawn-agent server-side primitive

Build `code/c11/Resources/bin/c11-spawn-agent` (bash). Launches a Claude Code agent in a named tmux window on dedicated `-L agents` socket. Idempotent on session; errors on existing window. Auth comes from `claude login` already on the box. Validate on Atlas: spawn a haiku-writing agent, verify it survives SSH detach, verify the output file appears.

## Approach

The canonical implementation plan, script contract, tmux specifics, portability constraints, and 8-step Atlas validation procedure live in `notes/task_01KRH37JCVT18YJS2TRDRGW3RY.md`. That note is treated as the load-bearing plan for this slice; this file points at it to keep the lattice state machine moving.

Headline deliverables:

1. `code/c11/Resources/bin/c11-spawn-agent` — ~50 lines of bash, portable across macOS bash 3.2 and Linux bash 5+.
2. `--workspace`, `--window`, exactly-one-of `--prompt-file` / `--prompt`; optional `--cwd`, `--model`, `--socket`.
3. Defaults: socket `agents`, cwd `$HOME`, model `claude-opus-4-7`.
4. Window-already-exists guard is load-bearing — re-running same invocation errors, does not clobber.
5. No credentials handled in script; relies entirely on whatever `claude login` already wrote on the target box.
6. CHANGELOG entry under Unreleased.

Validation: 8 mechanical steps on Atlas (preflight → scp → spawn → verify → SSH-detach test → output → negative test → cleanup). The load-bearing assertion is step 5: window survives SSH disconnect.

Out of scope for slice 1: crash/restart logic, reboot persistence, transcript capture, Lattice status reporting, the local-side `c11 remote spawn` wrapper (slice 3 / C11-39), Hetzner (slice 2 / C11-38), bootstrap automation.

## Reset 2026-05-13 by agent:claude-opus-4
