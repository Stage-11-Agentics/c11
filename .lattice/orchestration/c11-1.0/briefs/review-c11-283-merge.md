# Narrow review: C11-283 merge resolution (Grok)

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract. You are Grok: read-only, no builds or tests, no subagents.

- Ticket **C11-283**. PR https://github.com/Stage-11-Agentics/c11/pull/525, merge commit head `6bc28658e554acd9cbf597f9fc032bf4b6b093be` (merging main 85f33041c5, which carries C11-281 send --raw/stdin/no-submit/unknown-flag, into C11-283 --window scoping). Both sides passed review separately.
- Title `C11-283 Merge Review Grok`. Actor `agent:grok-review-283m`.
- Review ONLY the conflict resolution: `git show --remerge-diff 6bc28658e554acd9cbf597f9fc032bf4b6b093be` (CLI/c11.swift, skills/c11/SKILL.md). Owner's description: shared send/send-tab/paste admission checks the effective target after caller-env suppression; send-tab additionally requires an explicit tab; raw/stdin/no-submit behavior and both skill texts retained. Evidence ev_01M3Y19PC8AEJR8TSB5VAAX25R, art_01M3Y17PFRY2QMKVQ6ZPP55HYV (Atlas compile-check, 128 window-scope CLI cases).
- Blocking only if the resolution drops or changes behavior from either side: C11-281's (--raw no escape rewriting, `-` stdin, unknown flags rejected before text assembly, default submit kept) or C11-283's (--window resolves inside that window without focusing it; foreign --workspace rejected). Cite file:line.
- When done, send VERDICT and wait.
