# Delta re-review: C11-271 (PR #495), cycle 2 of 3

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-271**. PR https://github.com/Stage-11-Agentics/c11/pull/495. Branch `c11-1.0/C11-271-lifecycle-fixtures`. New head `ece3cf255b598ba49c8f17993d72012f444caadf`. Previous reviewed head `ad7d761e328381972a4319eed80c6dbb96786e42`. Base origin/main `0ff8887e5e`.
- Title `C11-271 Fixture Rereview`. Actor `agent:codex-review-271`.

**Delta-only.** Read the cycle-1 review (`lattice show C11-271 --events`, comment `ev_01M3X81ZNVWP5S58S24W07RXNA`) and verify each of its three blocking findings against `git diff ad7d761e..ece3cf25` plus the files those findings named. Do not restart cold discovery. Check: (1) every case marked observed was actually observed in its capture; unreachable cases (app restart, Codex child completion if not triggered) are marked gap with tagged-build recapture, not synthesized; (2) every normalized event traces to its paired capture or is labeled inferred; (3) the reader exposes identity, attributes, order/timing and the observed oracle, expected marks are concrete, and a test asserts replay behavior. Re-run the disclosure scan over changed fixture files. New blocking findings only if the delta introduced them or a cycle-1 fix is incomplete.
