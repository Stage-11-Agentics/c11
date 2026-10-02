# Review: C11-264 (Feed: typed per-tab asks with list, open, watch and ask events), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-264** (critical path: C11-265 → C11-266 build on it). PR https://github.com/Stage-11-Agentics/c11/pull/541, head `b27f0ca859631218cc758244b651446c699386c3`, base = merge-base with origin/main (C11-263 attention and C11-273 journal on main).
- Title `C11-264 Review Astra`. Actor `agent:astra-review-264`. Owner: Grok WIP, completed by Codex Luna, finished on Sol.
- Plan `.lattice/plans/task_01M3X3WR42JJEV9Y7K30HRD5JK.md`; latest validation comment on the ticket.
- Read `docs/aar-c11-188-attention-loop.md` first (C11-188 signatures: epochs, fences, markers, coordinators; blocking if present). Focus: asks come from the journal fold (no second state machine); list/open/watch output is stable JSON; open jumps to the exact tab without stealing focus unless the command is a focus-intent command; watch streams events bounded and off main; resolved asks (C11-273's PostToolUse/Stop resolution) disappear promptly; audit finding 3: do not drop unread completions from navigation (the Feed filter must not delete navigation candidates); suppression and flags respected; strings localized; registry feature enabled; tests behavioral and replaying the C11-271 corpus (including the answered-ask case).
- When done, send VERDICT and wait.
