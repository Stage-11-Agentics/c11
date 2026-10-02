# Review: C11-281 (document send delivery; add --raw, stdin and unknown-flag errors), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-281**. PR https://github.com/Stage-11-Agentics/c11/pull/519, head `c8c04ea982293d0e723d8975b9d021b38df554ee`, base = merge-base with origin/main.
- Title `C11-281 Review Astra`. Actor `agent:astra-review-281`. Owner was Codex Sol.
- Plan `.lattice/plans/task_01M3X4FN4MAW3RB7T9VGFJGS70.md`; validation `ev_01M3XSHTG7F1X2J6QRJQATG5F7` (17 Atlas tests; tagged attached/queued/composer proof; the live Claude response leg was not verified because that login expired: say whether that matters for acceptance). CI pending.
- Focus: `send` builds on C11-257's merged recording and mailbox delivery without changing their behavior; `--raw` sends exactly the given bytes (no implicit Return, no escape processing) and is documented as such; stdin input works for multi-line and large text without truncation; unknown flags error instead of being typed into the terminal (the `--text` footgun); existing `c11 send --tab <t> "text"` behavior unchanged; docs/skill text accurate and timeless (do not sync installed skills); its capabilities feature enabled in the C11-284 registry; tests behavioral.
- When done, send VERDICT and wait.
