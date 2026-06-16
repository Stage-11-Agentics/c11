# C11-149: Mailbox: add a reproducible check for stdin push flush-into-PTY at the prompt

Follow-up from v0.53.0 release smoke (shipped C11-144 prompt-gated stdin delivery).

Gap: during v0.53.0 smoke the BUFFER-while-busy path and the durable PULL floor were both verified, but the stdin PUSH flushing the framed <c11-msg> block INTO the recipient's PTY at the prompt could not be reproduced. In a backgrounded, socket-driven Debug build every send recorded outcome=buffered — even to an idle/focused recipient — because the recipient's shell prompt-state read as not-promptIdle, so the dispatcher always took the safe buffer branch. The push is a best-effort doorbell and the pull floor works, so not a release blocker, but the flush path is currently unproven by automated smoke.

Two parts:
1. Confirm interactively (one-time): on a foreground c11, set mailbox.delivery=stdin on a surface, send while idle and watch the block inject at the prompt; then send while it runs a foreground command, confirm buffer then flush at next prompt. Capture trace (buffered -> flushed) + screenshot.
2. Make it repeatable: add a harness/seam so flush-at-prompt is exercisable without a foreground human (drive a recipient surface to a real promptIdle state the dispatcher observes, assert the block lands in the PTY and the dispatch log shows a flushed event). Add to tests_v2 or e2e.

Acceptance: an automated test demonstrates a buffered stdin message flushing into the recipient PTY on its next promptIdle, with a corresponding 'flushed' dispatch-log event.
