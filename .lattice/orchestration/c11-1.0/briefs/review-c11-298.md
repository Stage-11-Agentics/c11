# Review: C11-298 (a second copy of c11 must not kill the running fleet), cycle 1 — Grok

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract. You are Grok: read-only, no builds or tests, no subagents. Read every changed hunk; cite file:line.

- Ticket **C11-298** (risk list). PR https://github.com/Stage-11-Agentics/c11/pull/531, head `876fbadf08aacb56af4f62202259716f9de111e5` (admitted by the Orchestrator for signed proof builds 29801/29802), base = merge-base with origin/main.
- Title `C11-298 Review Grok`. Actor `agent:grok-review-298`. Owner was Codex Astra.
- Plan: the ticket's plan file. Evidence: signed update/relaunch `art_01M3Y551F6ZKGVT96FNW1DK7KB`; coexist/restart/Quit `art_01M3Y5FZ2AP3NKVC7KJVBY6XE5`; 18 tests; a same-path repeat at the current head is disclosed as inconclusive.
- Focus: launching a second copy (same or different bundle path, tagged vs production, after Sparkle relaunch) never terminates the running instance or its agents' PTYs; instance arbitration is deterministic and leaves exactly one owner of the production socket; the Sparkle relaunch path (C11-307's version) still works; the known rollout limit (an older running binary keeps its killer observer) is documented, not hidden; no runModal on agent-reachable paths; tests behavioral. Judge whether the inconclusive repeat is a blocking gap or an honest residual.
- When done, send VERDICT and wait.
