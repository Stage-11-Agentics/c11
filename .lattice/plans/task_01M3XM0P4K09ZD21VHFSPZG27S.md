# C11-313: Agent messaging follow-ups from C11-257: push edge cases, Stop-hook label, messages page design pass

Non-blocking follow-ups from the C11-257 reviews and integrated build (all judged below the final-gate bar: none loses mail, types it into the wrong program, or corrupts an operator draft in normal use). Details and file:line in the C11-257 review comments named in brackets.

Push and input (Lane B code):
1. The per-tab input transaction queue drains recursively with a single in-body flag; a large legacy v1 per-character send landing inside another writer's 200 ms window could overflow the main stack. Drain with a loop; save/restore the flag. [B: review r6]
2. Mail refused because the input slot is busy waits for the next agent edge; the end of a transaction does not retry. Kick the push retry from endInputTransaction when the tab has buffered mail. [B: review r6]
3. A socket send/send-key deferred behind a transaction is dropped if the surface detaches before its turn, though the reply said ok; previously it fell back to the pending-text queue. Restore that fallback. [B: review r6]
4. A deferred performBindingAction (AppleScript perform action) reports true before it runs. [B: review r6]
5. Add the attached-surface regression with a controllable paste delay (push vs submit race: separate turns, one claim). [B: review r6]
6. Integrated build saw one unreproduced case where mail that arrived during a 59 s Stop-hook-forced turn was not pushed when the agent went idle (idle edge with no waiting.entered); it was delivered at the next Stop drain, still exactly once. [INT: validation r2]

Hook drain (Lane C code):
7. Claude labels every Stop-hook mail delivery "Stop hook error occurred"; the agent acts correctly but the operator sees an error. Find a hook output shape that does not read as an error. [C: review r8]
8. Two code comments still say claude-hook prompt-submit can claim mail (CLI/c11.swift ~19157, ~1940); the --event override can mis-wire a hand-built hook; one duplicate Grok test assertion. [C: review r8]
9. A crafted non-ULID inbox filename holding valid envelope JSON gets a fresh ULID for claim/receipt while the framed block keeps the embedded id. [C: review r7]

Messages page (Lane D code; fold into the visual pass once Atin signs off the Overwatch-based design):
10. The bound label says "latest 10000 of N" when the byte budget is the limit; use messages.length and name the limit applied. Every write renders twice (measure, then output). [D: review r3]
11. Port the Overwatch prototype's visual design (held for Atin's design feedback) and fix the Health funnel sublabel overlap noted in the brief.

Other:
12. During integration setup the tagged app ended up frontmost once; check whether a socket path in the new code activates the app (socket focus policy). [INT]
