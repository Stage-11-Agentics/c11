# Skill reference: flags and suppression

This note tracks the corresponding section in `skills/c11/SKILL.md`. C11-513 adds named flag
kinds to the existing attention model. Keep both copies aligned when the commands or rendering
contract changes. After editing the skill, run `scripts/sync-installed-skills.sh c11` and inspect
the installed copy.

---

## Flags and suppression (the attention model)

Your panel's mark shows your lifecycle — working, needs attention (waiting), idle, cold.
Two modifiers sit over it, and they are yours to use.

### Flag: work has stopped and only a human can restart it

```bash
c11 raise-flag --panel "$C11_PANEL_ID" "Need a call on schema migration vs dual-write"
c11 raise-flag --panel "$C11_PANEL_ID" --kind chief-of-staff "Need a decision before I can continue"
c11 lower-flag --panel "$C11_PANEL_ID"
```

The reason is required, one line, and surfaced everywhere the flag appears — write it as the
sentence you would say if the operator walked over. A flag can optionally carry a registered
kind. `nil` remains the generic violet flag; kinds label a flag but do not add severity.

Manage c11-owned kinds in Settings or with the CLI:

```bash
c11 flag-kind list
c11 flag-kind set --id <slug> --name <name> --color <token> [--emoji <emoji>]
c11 flag-kind rm --id <slug>
```

`chief-of-staff` (green) and `merge-issue` (red) are editable built-ins. `raise-flag --kind`
accepts only a registered slug. Colors come from a fixed adaptive palette; arbitrary hex and
per-raise color or emoji overrides are not supported. The active flag and `flag.raised` event
snapshot the resolved name, color token, and emoji. Registry edits do not repaint an existing
flag; editing its reason or kind keeps its original raise time and oldest-first queue position.
The Feed, individual sidebar row, tooltip/accessibility text, menu-bar flag item, in-surface
banner, system notification, and panel-list row show the optional kind label and reason. The
aggregate count and menu-bar icon keep the existing generic flag glyph.

- A flag is **sticky**: it holds until the operator dismisses it or you lower it. Generic
  marks remain violet; named marks use their adaptive token. If you are also stopped, the mark
  strobes in that color — the strongest visual signal c11 has. When the flag lowers, your marks
  return to normal lifecycle colors. Reduce Motion suppresses the animation.
- **Flag only when work has stopped and only a human can restart it**, or when you have hit
  an urgent issue whose blast radius crosses other agents. "I finished, please review" is
  waiting, not a flag. If the operator is already in conversation with you, just ask them —
  the flag is your channel back when you were dispatched and left alone.
- Flags arrive from either side: the operator may launch you flagged (a mission they intend
  to watch), or you may raise one mid-run. Both are rare by design — **expect at least nine
  in ten agents to never carry a flag**. The tier's power is its scarcity; an agent that
  flags routinely is spending everyone's signal.
- A dismissed flag is not an unseen flag. `flag.lowered` carries `by: "operator" | "agent"`;
  operator dismissal without an answer means *seen and deferred*. Re-raise only if the
  blocker still stands and you can say why the deferral does not.

### Suppression: keep working, do not signal

```bash
c11 suppress --panel "$C11_PANEL_ID"
c11 unsuppress --panel "$C11_PANEL_ID"
c11 launch-agent ... --suppressed     # the common case: set at dispatch
```

A suppressed panel never enters the needs-attention state: when it stops, its mark reads
idle, and it is excluded from waiting counts, ⌥V, and routine waiting-derived system
notifications. The notification record still lands in the store — suppression silences the
routine signal, not the history. A direct notification from `flag.raise` is the deliberate
exception because the flag tier overrides suppression completely.

- The natural fit is **subagents under an orchestrator**: the orchestrator watches you, so
  the operator's sidebar stays quiet while coordination happens one level down. If you are
  orchestrating, launch your workers `--suppressed` and sweep them yourself.
- **Suppression is not a gag.** If you hit a genuine blocker, raise the flag — a flag
  overrides suppression entirely, at full visual strength. "Do not tell me when you finish,
  do tell me if you get stuck" is the contract, and the flag is the second half.
