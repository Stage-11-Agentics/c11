# C11-108: c11 send: auto-submit by default (Return after type); add --no-submit for partial-line construction

**Problem**

`c11 send` types characters into the target PTY but never appends a synthetic Return. Agents calling `c11 send` from Claude Code's Bash tool have `\n` stripped, so the documented two-call pattern (`c11 send` + `c11 send-key enter`) is the only way to submit. Agents miss the second call repeatedly in practice — observed multiple times where a sub-agent's outbound message lands in the recipient's input box and sits unsubmitted, blocking the workflow.

**Root cause**: Long-standing design, not a regression. `sendInputToSurface` (Sources/TerminalController.swift:16689 v1, v2SurfaceSendText at 7545) calls `sendSocketText` then returns without firing Return. Skill documents the gotcha at skills/c11/SKILL.md:104 but documentation is the wrong layer to land this on — the API shape is fighting the actual use case.

**Decision (operator, 2026-05-19)**: Flip the default. Option 2 from the diagnosis: `c11 send` auto-submits by default; add `--no-submit` for the rare partial-line construction case. PR #158 (4df99b97e) already proved the same fix shape for the mailbox stdin handler; this is the same change applied to the `c11 send` path.

**Scope**

- Server (Sources/TerminalController.swift v2SurfaceSendText, ~line 7545): accept `submit` param (default `true`). After sendSocketText returns on @MainActor Phase B, if submit, call sendNamedKey(liveSurface, keyName: "enter") on the same turn.
- CLI (cli/c11.swift, `send` and `send-panel` cases): parse `--no-submit`. Default submit=true. Pass submit param through.
- Skill (skills/c11/SKILL.md): replace the \n-stripping gotcha with the new default. Update the orchestration examples that pair send+send-key enter (the sub-agent launch patterns). Document `--no-submit` for partial-line construction.
- Mailbox stdin handler is unaffected (already uses TextBoxSubmit.send per PR #158).
- send-panel is convenience alias for send against a panel ref → same default applies.

**Out of scope**

- Heuristic auto-submit based on terminal_type (option 3 from diagnosis) — rejected as too magic.
- Auto-submit for v1 send/send_surface socket commands — leave alone; they're being phased out anyway.

**Acceptance**

- `c11 send --surface X 'echo hello'` types AND submits in one call.
- `c11 send --no-submit --surface X 'echo hello'` types only (preserves the existing partial-line workflow).
- Skill examples in orchestration patterns no longer require a follow-up `c11 send-key enter`.
- c11-logic tests pass; manual smoke from a tagged build confirms a sub-agent prompt delivered via `c11 send` to a sibling claude pane actually submits.

**Upstream cost**

Behavior shift on a c11-fork CLI command, not a shape change. Upstream cmux scripts that relied on `cmux send` typing-without-submit will break and need `--no-submit` added. Acceptable per fork-level divergence policy when justified.
