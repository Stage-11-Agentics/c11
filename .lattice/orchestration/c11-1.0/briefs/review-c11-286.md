# Review: C11-286 (resize-window keeps the top-left and does not focus; P2), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-286** (P2). PR https://github.com/Stage-11-Agentics/c11/pull/545, head `ba414b7967626ce09b776bbed4c8cc26e218e7ae`, base = merge-base with origin/main.
- Title `C11-286 Review Astra`. Actor `agent:astra-review-286`. Owner was Codex Luna.
- Plan: the ticket's plan file; validation is the latest validation comment on the ticket.
- Focus: the command never activates c11 or steals focus (socket focus policy in CLAUDE.md); the top-left stays fixed in screen coordinates across displays, including a secondary display with a different origin and a window near a screen edge; sizes are clamped to the window's minimum and the visible frame with a clear error or result; targeting is explicit (no fallback to the focused window); off-main parsing with only minimal main-thread mutation; CLI help and the c11 skill updated and synced; tests behavioral. As a P2 it must add no risk to the release.
- When done, send VERDICT and wait.
