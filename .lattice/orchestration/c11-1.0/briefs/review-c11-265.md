# Review: C11-265 (one attention order for Feed and the jump; menu-bar flags and open-ask count; critical path), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-265**. PR https://github.com/Stage-11-Agentics/c11/pull/548, head `47a7221daf250d76fe02aba514b24042b3b04ff6`, base = merge-base with origin/main.
- Title `C11-265 Review Astra`. Actor `agent:astra-review-265`. Owner is Codex Sol (Feed seat, which also wrote C11-264).
- Plan: the ticket's plan file. Validation: ev_01M3YZ8MTMYVH6HQRAJA7256WE (52 Atlas tests plus a packaged UI pass).
- Focus, per acceptance criteria 1-5: one pure ordered projection (flags first, then asks, oldest first within each, deterministic UUID tie-break) used by BOTH Feed and the jump action, not two lists; a tab with a flag and an ask counts one open ask; suppressed asks excluded but suppressed flags kept at flag priority; closed or unavailable targets skipped identically in both consumers with no fallback to the focused tab; menu-bar counts equal the projection, including zero, and a finished turn is never labeled an ask; menu-bar updates never activate c11; the user's shortcut bindings and the default jump binding unchanged. Main-thread cost: no new work on typing paths and no per-keystroke recomputation. Strings localized.
- Critical path: C11-266 waits on this. Be thorough and fast.
- When done, send VERDICT and wait.
