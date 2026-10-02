# Review: C11-280 (type --command into a new terminal via Ghostty initial_input), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-280**. PR https://github.com/Stage-11-Agentics/c11/pull/522, head `812b26bd16d7a19dff13539bcb595512de2e2e18`, base = merge-base with origin/main.
- Title `C11-280 Review Astra`. Actor `agent:astra-review-280`. Owner was Codex Sol.
- Plan: the ticket's plan file. Evidence `art_01M3XVTESJVCH2GNWE0N47QZ9M`, image `art_01M3XVTEVZW7SY82KH6V0713XS` (13 Atlas tests; packaged four-create / capability / atomic-rejection / shell proof). CI pending.
- Focus: `--command` reaches the shell via Ghostty `initial_input` exactly once on every create path the ticket names (new-workspace, new-split, new-tab, launch), so there is no race with a follow-up send and no discarded send result (the ticket moved that here from C3); text is delivered as typed input (no implicit shell-escaping surprises) and documented as such; invalid combinations are rejected atomically (nothing created); its feature is enabled in the C11-284 registry; C11-258's launch path is unaffected; tests behavioral.
- When done, send VERDICT and wait.
