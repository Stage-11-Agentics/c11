# Turn c11 1.0 backlog items into Lattice tickets

You write full Lattice tickets for one workstream of c11 1.0, on c11's local board. Load the `c11` and `lattice` skills first. Keep your c11 tab description current. Its last line is `Lineage: cmux Harvest Lead → ticket writer`.

## Read first
1. `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/BACKLOG.md`: the item list, Atin's rulings, and the tiers. **Your items are named at the bottom of this brief.** Do not ticket anything else.
2. The sources each item cites:
   - reports `01`–`06`;
   - `feature-audit-fable.md` and `feature-audit-astra.md`;
   - `c11-1.0.html` (decisions as revised).

   All are in the same folder.
3. c11 source at `~/Projects/Stage11/code/c11`. Read `origin/main` with `git show origin/main:<path>`. The local checkout is behind, and it holds another agent's uncommitted Swift work: do not touch it. cmux code is at `upstream/main`.
4. `~/Projects/Stage11/code/c11/CLAUDE.md` (typing-latency hot paths, socket threading, localization, build lock, tagged builds) and `PHILOSOPHY.md`.

## Rules
- **Read only on code.** The only writes are Lattice commands and your one map file. No builds, tests, branches or commits.
- **Check for duplicates.** Before creating a ticket, search the board for an existing one (`lattice list`, `grep -ril <keyword> .lattice/tasks`). If one exists, update it rather than duplicate it: `lattice update`, `lattice edit-description` or `lattice comment`, plus the tags. Known ones: C11-216 (Atlas builds), C11-231 (waiting carries a reason), C11-257 (mailbox delivery), C11-130, C11-169 and C11-235 (PTYs that never attach), C11-197, C11-202 and C11-205 (main-thread hangs), C11-131 and C11-139 (crash-resume), C11-243 (seen tracking).
- **Create from the c11 repo root**, `cd ~/Projects/Stage11/code/c11`, with your actor:
  ```
  lattice create "<title>" --type <task|bug|spike|chore> --priority <critical|high|medium|low> --complexity <low|medium|high> --tags c11-1.0,ws:<workstream>,tier:<p0|p1|p2> --description "$(cat <file>)" --actor agent:<codex|grok> --json
  ```
  Write each description to a temp file in your scratch space first. Priority: P0 is critical, P1 is high, P2 is medium.
- **Link dependencies** with `lattice link <A> depends_on <B>`. Check `lattice link --help` for the exact relationship names. Link inside your workstream. For dependencies on other workstreams, write the backlog item id (for example "depends on J2") in the description, and the lead links those.
- **One ticket per backlog item,** unless the item is clearly two PRs. Then make two tickets, and say why in both.

## Ticket description template (markdown)
```
## Why
The operator moment this fixes, in one or two sentences. Backlog item: <id>.

## Evidence
- c11: `path:line` on origin/main (0ff8887e5e), with what is there today.
- Upstream: cmux PR numbers and files, if any.
- Research: report and section.

## Scope
In: ...
Out: ... (name the parked neighbours explicitly)

## Approach
A light sketch, not a plan. The delegator will plan. Name the seams to use and the traps to avoid.

## Acceptance criteria
Numbered, observable, and tied to an incident, a fixture or an operator workflow. No absolute "fail closed everywhere" language (C11-188 lesson, `docs/aar-c11-188-attention-loop.md`).

## Validation
How a reviewer sees it work: a unit or fixture test, `tests_v2` against a tagged build's socket, a computer-use pass for UI, and a soak if the item touches hot paths. Builds and soaks run on Atlas once C11-216 lands.

## Dependencies
Backlog ids, and ticket ids where known.

## Risks
Typing latency, main thread, doctrine (no tenant config writes), localization (six locales for new UI strings), and public-repo disclosure.

Size: S/M/L. Tier: P0/P1/P2. Doctrine check: one line.
```

## Output
- **The map file:** `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/tickets/<workstream>.md`. One table: backlog id, ticket id, title, tier, size, deps (backlog ids), created or updated.
- **When finished,** set your tab description to `Done: <n> tickets created, <m> updated (<workstream>)` and stop. Do not message other tabs.

Quality bar: a delegator who has never seen this conversation can pick up any one of your tickets and plan from it alone.

## Your workstream: `journal`
Items: **F1, F2, F3, J1, J2, J3, J4, J5, J6, J7, J8** (see BACKLOG.md). Your actor is `agent:codex`. Your c11 tab title is "Tickets Journal".
