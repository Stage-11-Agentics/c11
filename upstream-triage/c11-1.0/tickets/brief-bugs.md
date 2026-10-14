# File the c11 1.0 bug tickets

Read `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/ticket-writer-brief.md` and follow its rules, template and duplicate check. This brief replaces its "Your workstream" section.

**Workstream:** `bugs` (tag `ws:bugs`). **Actor:** `agent:grok`. **Map file:** `tickets/bugs.md`. **Your c11 tab:** "Tickets Bugs".

## Inputs
- `upstream-triage/c11-1.0/05-bug-reconciled.md`: the approved tiers. Atin approved them on 2026-10-01.
- `05-bug-sweep-data/LEDGER.md` (and `.tsv`): per-bug evidence.
- `05-bug-sweep-data/audit-fable.md` and `audit-astra.md`: clusters, build order, spot-check corrections. **Where an audit overturned or narrowed a claim, the corrected claim goes in the ticket.** B010 is the key case: per Astra, the output thread unlocks before it blocks, so the real fix is teardown-abortable mailbox pushes, not the autosave mutex cycle.

## What to file
- **Tier 1 (30 bugs) becomes cluster tickets, not 30 single tickets.** Use Fable's clusters and build order (`audit-fable.md` §4 and §5). Expected shape, about 12 to 16 tickets:
  1. **The Ghostty patch set, one ticket:** B065, B010 Ghostty half, B031, B013, B047, B072, B204, B062, B022, plus the 08-25 freeze root (abortable pushes). P0.
  2. **B010 app half, B086 and B003 together:** cold start and read paths. P0 or P1.
  3. **Cold-terminal reads:** B087.
  4. **Restore safety:**
     - B007 and B246, socket readiness;
     - B005, a second app instance killing the fleet;
     - B024;
     - B019.
  5. **Congestion producers:** B012, B030, B056 and B061 (they can split by file).
  6. **Shell hygiene:** B023 and B094.
  7. **Claude hooks:** B028.
  8. **Browser:** B074. Check C11-287 first. It may already cover B074, in which case add the bug to it rather than duplicate.
  9. **Release:** B200, the Sparkle macOS 26 install path.
  10. **Input:** B002 (`send-key` chords).
- **Exceptions:**
  - **B058:** do NOT fix the numbering, because ruling D15 keeps tab numbers resetting. File one small P1 chore instead: the c11 skill states that `tab:N` refs do not survive a restart, and agents hold the tab UUID across restarts.
  - **B059:** a P2 ticket gated on the soak's sidebar measurement (D21). No work unless the soak convicts the sidebar.
  - **B044:** do not file. The journal delivers it. Add a comment to C11-231 or C11-273 naming B044.
- **Tier 2 (51 bugs):** no standalone tickets. In each tier-1 cluster ticket, add a **"Ride-alongs"** section listing the tier-2 IDs that sit in the same files or the same submodule bump, so the owner fixes them in the same PR. Put any tier-2 bugs that fit no cluster into one P2 ticket, "Tier-2 bug sweep", with the IDs grouped by subsystem.
- **Tier 3 (34 bugs):** no tickets. Name the relevant parked IDs in each cluster ticket's "Out" scope, so owners can re-check them when they are already in that code.
- **Tags:** `c11-1.0,ws:bugs,tier:p0|p1|p2`. Within `ws:bugs`, link dependencies: the app-half ticket depends on the Ghostty bump. Name cross-workstream dependencies (C11-216 for builds, C11-270 for soak gates) in each description, and the lead links them.
- **Size and tier** follow the audits. Size relatively (S/M/L), never in days.
- **Public repo:** neutral wording, and nothing that reads as an exploit description.

When finished, set your description to `Done: <n> tickets created, <m> updated (bugs)` and stop.
