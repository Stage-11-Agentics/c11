# Staged skill section: flags and suppression

**Landing instructions (not part of the skill text):** the section below drops into
`skills/c11/SKILL.md` in the PR that ships the flag/suppress primitives — not before, since
it documents CLI commands that must exist when agents read it. Per the hard rule in
`CLAUDE.md`, the edit is not done until `scripts/sync-installed-skills.sh c11` has run on the
maintainer's machine. The text is written timelessly and needs no modification at landing
time.

---

## Flags and suppression (the attention model)

Your surface's mark shows your lifecycle — working, needs attention (waiting), idle, cold.
Two modifiers sit over it, and they are yours to use.

### Flag: work has stopped and only a human can restart it

```bash
c11 raise-flag --surface "$C11_SURFACE_ID" "Need a call on schema migration vs dual-write"
c11 lower-flag --surface "$C11_SURFACE_ID"
```

The reason is required, one line, and surfaced everywhere the flag appears — write it as the
sentence you would say if the operator walked over.

- A flag is **sticky**: it holds until the operator dismisses it or you lower it. While it is
  up, your marks render violet across the workspace; if you are also stopped, the mark
  strobes — the strongest visual signal c11 has. When the flag lowers, your marks return to
  normal lifecycle colors.
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
c11 suppress --surface "$C11_SURFACE_ID"
c11 unsuppress --surface "$C11_SURFACE_ID"
c11 launch-agent ... --suppressed     # the common case: set at dispatch
```

A suppressed surface never enters the needs-attention state: when it stops, its mark reads
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
