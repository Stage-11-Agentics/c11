# Review: C11-231 round 2 (delta)

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `C11-231 Review Astra`. Actor `agent:astra-review-231`. Owner: Claude Sonnet (rolled over from Codex Luna). C11-278 waits on this ticket.

- PR https://github.com/Stage-11-Agentics/c11/pull/544, new head `dfcdfe164d5466b40deca01e2e9ea80222da56ba`. Round-1 FAIL head `aeba92403b`, verdict `ev_01M3YSHSAX9SE1YZQC75RBP6F9` (seven blocking findings: crash recovery, restored clocks, submit handling, picker wiring, localization, required runtime proof, and the rest as listed). Read it first.
- Delta: `git diff aeba92403b dfcdfe164d`. Many commits are main merges; check them with remerge-diff and confirm they add nothing beyond main. Repair commits: fcc5dd0f6c, 48b35a790c, 3d79e13682 (WIP parked), dfcdfe164d.
- Validation: the validation comment on C11-231 (70 native tests, 4 tests_v2 files, tagged UI proof). The owner lists open items: the pinned Claude picker fixture was not run; `pickerCommitKeyCode` stays nil and fails closed; the tab-sheet restart clock was not driven in the UI; the C11-270 soak is unverified.
- Judge each of the seven findings: resolved, or still blocking. For the owner's open items, decide which are acceptable deferrals (numbered Validator or sign-off steps; the soak belongs to C11-270) and which are real gaps against the acceptance criteria. Fail-closed picker behavior must be explicit to the user, not silent.
- Break at least one repaired guard and confirm its test goes red.
- Reply `VERDICT C11-231 PASS|FAIL <head> <artifact>` to tab:210.
