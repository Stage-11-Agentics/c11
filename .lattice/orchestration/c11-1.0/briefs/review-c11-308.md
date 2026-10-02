# Review: C11-308 (encode send-key ctrl+letter so agents can interrupt a TUI), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-308**. PR https://github.com/Stage-11-Agentics/c11/pull/523, head `b09a7a697aca74dd5541b7664438e5a558af14c9`, base = merge-base with origin/main.
- Title `C11-308 Review Astra`. Actor `agent:astra-review-308`. Owner was Codex Sol.
- Plan: the ticket's plan file. Validation `ev_01M3XXJJ4VYDTAP05276GCMYPZ`, receipt `art_01M3XXCA5FH49X16MSRA8XKW1R` (26 tests, 35 PTY cases, native Claude/Codex interruption followed by a working send, paired main/candidate latency). CI running.
- Focus: `send-key ctrl+<letter>` delivers the correct C0 byte (and works with Ghostty's key encoding modes, including when a TUI enabled kitty/modifyOtherKeys) so ctrl+c actually interrupts Claude Code and Codex; other keys and existing names unchanged; unknown key names error instead of being typed; the following `send` still works after an interrupt; no new main-thread work per key; C11-257's send/mailbox behavior untouched; its registry feature enabled; tests behavioral.
- When done, send VERDICT and wait.
