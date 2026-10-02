# Review: C11-283 (scope --window without focusing that window), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract. Batch validation is in force (Atin): low-risk runtime proof runs in the Validator's batch on merged main; judge whether the numbered scenario would prove the acceptance, and do not fail the ticket only because that runtime proof is deferred.

- Ticket **C11-283**. PR https://github.com/Stage-11-Agentics/c11/pull/525, head `50fa043ece804bfd820eb94ddf91ad9b45fe7e4a`, base = merge-base with origin/main.
- Title `C11-283 Review Astra`. Actor `agent:astra-review-283`. Owner was Codex Sol.
- Plan: the ticket's plan file. Validation `ev_01M3XYDAGFZH2D14W8DAAC6H7B`, artifact `art_01M3XYA44QJ6XHH9GDPZ9410BH` (94 CLI cases, tagged build, 25 native checks). CI pending.
- Focus: `--window` resolves workspaces/tabs within that window for every command that accepts it, without raising, activating or focusing it (socket focus policy); an unknown or closed window is an error, never a fallback to the focused window; commands without --window behave as before; its registry feature enabled; tests behavioral.
- When done, send VERDICT and wait.
