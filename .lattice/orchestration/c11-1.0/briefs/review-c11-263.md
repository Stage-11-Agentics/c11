# Review: C11-263 (attention: isolate tab clears, surface bypass asks, repair flag notifications), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-263** (P0, risk list, gates C11-273 the journal). PR https://github.com/Stage-11-Agentics/c11/pull/506, head `b0fc4000f2e4061698a73d4c1aa0cf45669bdd4b`, base = merge-base with origin/main.
- Title `C11-263 Review Astra`. Actor `agent:astra-review-263`. Owner was Codex Sol.
- Plan: the ticket's plan file; acceptance criteria 1-5 in the ticket. Validation `ev_01M3XNT0XE2JCVH636GVB14S3S`, native runtime `art_01M3XNMEMT2KZVSGJSMSQH0SD6`, churn `art_01M3XNMES1GMF9AB7836157EJC`. Fixture oracle from C11-271 (merged) must replay.
- Read `docs/aar-c11-188-attention-loop.md` first: this is the C11-188 area. Blocking signatures: epochs, fences, markers, coordinators or other new mechanism beyond the plan; absolute "fail closed everywhere" claims.
- Focus: (AC1) one agent's prompt-submit / pre-tool-use / session-end / stale-PID cleanup clears only its own eligible notice; the sibling's unread/waiting survives; an unknown PID is never guessed onto a sibling; (AC2) bypass-mode AskUserQuestion/ExitPlanMode puts the originating unsuppressed tab in waiting without duplicate items when a normal notification follows; (AC3) flags reach the menu-bar extra with zero routine unread, suppressed flagged tabs included, lowering removes them, suppressed unflagged completions stay quiet; (AC4) C11_/CMUX_ notification env IDs correct for routine and flag, explicit absent-tab for workspace-only; (AC5) no app activation or selected-tab change; telemetry parsing off main per the socket threading policy. Also: it was told to rebase onto C11-257's merged lanes (#493/#494/#497); confirm it did not alter their behavior. Localization of new strings; tests behavioral.
- When done, send VERDICT and wait.
