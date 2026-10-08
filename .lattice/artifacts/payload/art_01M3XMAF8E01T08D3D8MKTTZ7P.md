C11-257 complete. All five lanes merged to origin/main and verified (squash merges):
- A #492 3a38d8a23b: every send/send-key recorded as tab.input_sent with full text; mailbox events carry bodies and via; event schema updated.
- B #491 72cd3882df: mail pushed to a waiting agent (opt-in mailbox.delivery=stdin) only when the agent owns its terminal in raw mode; one input transaction per tab; never into a shell; inboxes keyed on tab UUID (fixes the 52 lost long/slash-title copies).
- C #493 2b3c67ede3: busy Claude and Codex drain at Stop (decision:block, own turn); no socket I/O after the claim; deliveries recorded through a receipts spool; Grok covered by B's push.
- D #494 9b1380e08f: c11 writes a self-contained, bounded messages.html; c11 messages view opens it in the caller's workspace without focus. Visual port held for Atin's design feedback (C11-313).
- E #497 0bc4b61779: mailbox --help and sibling help fixes; skill/guide teach the two channels and the push opt-in.

Review: every lane passed a non-author, cross-family review at its final head (A r3, B r6, C r8 + attested test-only commit, D r4, E r1 + attested text-only commit). Integrated build c11-257-int passed smoke for Claude, Codex and Grok (waiting, busy, operator draft, awkward title, help, page). Atin approved the merge ("Yep, get it done, please"). Post-merge smoke on a tagged build of main 0bc4b61779 (steps 1/3/4/8) passed. Installed c11 skill synced from main.

Follow-ups (non-blocking, below the final-gate bar): C11-313. Main CI and Mailbox parity on 0bc4b61779 were still queued behind the c11-1.0 fleet at completion; the integrator is watching and fixes forward if red.