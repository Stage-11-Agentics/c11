# Agents stopped naming their panels (regression from PR #267)

Found by the Inbox Coordinator (Inbound workspace), 2026-11-13 12:50 PM.

## Symptom
Operator-opened Claude panels sit under "Awaiting first task" for whole sessions. Examples on 11-13:
panels 1787, 1769, 1821 (Inbound), 1783 (Gregorovich). Their transcripts show zero `rename-panel` calls,
no c11 skill load, and (two of three) no `c11h guide` call. The tasks they got (an email, a calendar question)
never touched c11, so nothing pulled them into the card.

## Cause
PR #267 (30ce02da, 11-11 01:44 AM) made the per-launch note the only orientation text and dropped the
SessionStart `additionalContext`, which said:

> Before other work, load the c11 skill... As your first action, name this panel so the operator can see
> your role: c11 rename-panel --panel "$C11_PANEL_ID" "<2-4 word role>". A working agent must not sit under
> "Awaiting first task".

The note that replaced it (`Resources/bin/c11h-agent-note.txt`) says only "Run `c11h guide` first" and
mentions naming in a parenthetical. Agents treat that as optional reading when the task is not about c11.
Rough rename rate across Claude transcripts that touched c11: 48-84% per day through 11-10, 27-44% on 11-11
to 11-13.

## Fix (proposed)
Put the imperative back into the note itself, one sentence, with the command, so it does not depend on
the agent choosing to read the card. For example, append to c11h-agent-note.txt:

> On your first real task, before other work, name your panel and say what you are doing:
> `c11h rename-panel --panel "$C11_PANEL_ID" "<2-4 word role>"` and
> `c11h set-description --panel "$C11_PANEL_ID" "<what you are doing now>"`.
> A working agent never sits under "Awaiting first task".

Tests that pin the note: tests/test_c11h_agent_note.py:168, c11Tests/CLIUnknownCommandTests.swift:52.
Optional stronger guard: the Stop hook could notice a panel still titled "Awaiting first task" after a
completed turn with tool use and add a one-line reminder.
