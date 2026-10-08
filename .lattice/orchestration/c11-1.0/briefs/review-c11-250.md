# Review: C11-250 (close safety follow-ups 2, 5 and 6 from the #469 review), cycle 1

Follow `reviewer-common.md` in this directory (mailbox tab:210). Title `C11-250 Review Astra`. Actor `agent:astra-review-250`. Owner: Claude Sonnet (rolled over from Codex Luna).

- PR https://github.com/Stage-11-Agentics/c11/pull/561, head `a9ffddc43fc23897745ea37ec8d4eeb362575c68`, base = merge-base with origin/main. The owner says the last commit is a clean main merge touching none of the PR's files; confirm with remerge-diff.
- Validation: the validation comment on C11-250 (3 Atlas tests pass at 39612dc8ae; runtime proof of attached-sheet window.close in an Atlas guest).
- Read the ticket for fixes 2, 5 and 6 and the #469 shutdown-snapshot review they come from. Check each fix is real, minimal, and has a behavioral test that goes red without it (break each and confirm).
- Shutdown and snapshot paths: no data loss on quit, no new runModal on an agent-reachable path (CLAUDE.md pitfall), no main-thread blocking in socket handlers, sheets attached to windows close cleanly.
- Reply `VERDICT C11-250 PASS|FAIL <head> <artifact>` to tab:210.
