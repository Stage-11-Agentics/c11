# Incident brief: one pkill ended every local c11h terminal (2026-11-06, 11:17 PM PST)

From the Workspace Forensics panel (a client workspace), 2026-11-07. Atin asked for this fix in the C11H workspace.

## What happened

- At 23:17:11 PST an agent in a client workspace ran
  `pkill -f "tsx mock-backend/server.ts" -n` to stop a mock server it had started.
- BSD pkill stops parsing options at the first pattern, so `-n` became a second pattern. With `-f` it
  matched every process whose command line contains `-n`.
- Every c11h terminal root is
  `/usr/bin/login -flp atin /bin/bash --noprofile --norc -c exec -l /bin/zsh`, and `--noprofile`
  contains `-n`. Every local terminal on all 9 hc shards got SIGTERM within about 2 s: 44 panels in
  10 workspaces. BSD pkill skips its own ancestors, so only the caller's terminal survived.
  Terminals on the build host and the Linux host survived (remote).
- Evidence: `c11h hc get <terminal>` shows `reason=exited signal=15` for each; hc cores and holders
  stayed up (started Nov 4, `holder_lost_count=0`). `pgrep -lf "tsx mock-backend/server.ts" -n`
  still lists every live terminal root except the caller's.
- c11h then **closed all 44 panels outright**: no ended banner, no Resume conversation, and
  `c11h restore status` reported `0 of 0`. Titles, mailbox addresses, delegation and lineage went
  with them. Recovery took manual forensics (lifecycle journal, transcripts, the events log) to find
  each session and relaunch it with `claude --resume`.
- Side finding: an agent ran `vmmap <c11h pid>` at the same moment, which suspended the app for
  11.4 s (`watchdog.late` in `~/Library/Logs/c11h/hang.log`). Note it; it is not the cause.

## The work (one ticket on stage11/c11h, or two if you judge they split cleanly)

1. **Recovery (the larger win).** A terminal whose root ended by a signal it did not raise itself,
   while an agent was running in it, should end like a host end: the panel stays, with the ended
   banner and **Resume conversation**, and it gets a restore record that `c11h restore status` and
   `restore run` act on. A clean user exit (`/exit`, Ctrl-D, the shell exiting 0) still closes the
   panel as today. Decide the exact rule and write it into the c11h skill.
2. **Hardening.** Make the terminal root a poor target for broad patterns: no common option strings
   (`-n`, `--no...`) or generic program names in its argv where avoidable, for example one
   c11h-named launcher with plain arguments. Weigh what else is feasible, such as a root that
   survives an outside SIGTERM to the login process while the shell stays signalable. Pick with
   evidence; don't over-build.

## Safety rule for reproducing

**Never run a broad pkill, killall or `kill -1` on the laptop to reproduce this.** It ends every
agent Atin is running. Reproduce on the build host, or in an isolated tagged build, by sending
`kill -TERM <pid>` to one test terminal's root pid only.

## Done

- The fix is merged; its proof is an e2e run on a packaged build: SIGTERM one test terminal's root
  while an agent runs in it, and the panel stays with a working Resume conversation.
- The c11h skill describes the new behavior.
- Report to Atin in your panel with "Needs you" first.
