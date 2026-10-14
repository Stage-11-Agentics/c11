# Topic 01: Event journal as the source of agent status

**Report path:** `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/01-event-journal.md`

Atin found this interesting and wants to talk it through.

cmux #10490 made sidebar agent status (Running, Needs input, Idle, Error) come from a durable event journal instead of text heuristics. Find out:

- How the journal works: what writes events (hooks? wrappers? the terminal?), the storage format, durability and replay, how status is derived from it, and how it handles agents that emit no events.
- How it relates to `cmux events` (the resumable NDJSON stream with cursor file and reconnect). Atin skipped `cmux events` as a standalone item, so cover it only as part of the journal substrate.
- How c11 derives its lifecycle marks today (working, waiting, idle, cold), what c11's `events tail` and file-first events stream already provide (see the c11 skill's `references/events.md`), and where c11's derivation is heuristic and fragile.
- Whether c11 1.0 should put lifecycle on a durable journal, and how to feed it without hooks into tenant config: wrappers, transcript watching, the PTY, agent self-report through `c11` commands, or a mix. Be concrete about each agent kind c11 supports.
- What a journal unlocks downstream: Overwatch-style fleet views, accurate Active and turn clocks, restore, notifications.
