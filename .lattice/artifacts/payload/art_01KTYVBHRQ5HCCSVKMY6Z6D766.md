# C11-131 real-Claude smoke — PASSED (operator-witnessed, real LaunchServices path)

Tagged build c11-131. Two REAL `claude --dangerously-skip-permissions` sessions,
each given a codeword and replying ACKNOWLEDGED:
  SmokeA  ecc674ed-f582-49f6-9112-f0fc8b8e84c1   ALPHA-PLATYPUS-7
  SmokeB  7beecad0-f4de-4d75-a6c9-4ef8562ba493   BETA-NARWHAL-9

BEFORE crash:
  c11 state save  -> windows=1 workspaces=3 terminal_panels=6 refs=2
  c11 state verify -> "2/2 ref-bearing panels would resume" (both transcript=present), exit 0

CRASH: kill -9 the tagged PID -> dirty shutdown sentinel confirmed on disk.

RELAUNCH via `open` (real LaunchServices path, exactly how an operator reopens):
  debug log: shutdown.sentinel prior=dirty — crash recovery (deferred to post-seed)
  c11 list-workspaces -> SmokeA + SmokeB + Workspace 1 ALL restored (full layout)
  c11 conversation list -> BOTH refs reclassified alive -> [suspended]
  both Claude panes auto-resumed: prior token counts intact (35K / 33K tok),
    proving --resume (a fresh session would be 0 tok)
  Operator visually witnessed: layout back, Claude auto-resumed in place.

On today's HEAD these refs would have been forced to .unknown and skipped
(panes restored, Claude NOT resumed) — the exact bug. Fixed and witnessed.

NOTE: an earlier "welcome quad only" observation was an artifact of the test
harness's direct-binary launch (env -i); the real `open`/LaunchServices path
restores the full layout, as witnessed here.
