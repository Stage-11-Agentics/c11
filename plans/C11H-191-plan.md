# C11H-191: c11 inside the Linux host's workspace containers

Owner: the Linux host setup seat (mailbox `client-linuxbox-setup`), from 2026-11-05 16:55. Target: landed and proven before Tue 11-10.
Done: a client project's owner launched with `c11h launch-agent --on linuxbox` renames its panel, raises a flag, sends mail and receives
mail, proven from the operator's c11h; a second workspace's container cannot act for the first one's panels.

## What is missing today

1. **No relay client for Linux.** The relay `c11` is the macOS CLI; the Linux host has no relay kit, so no Linux-host terminal (host or
   container) gets a credential or a working `c11`.
2. **No way out of the container.** The relay client writes request slots in the machine's c11h hc core
   (`doc.get`/`doc.set` on `~/.local/share/c11h/run/c11h.sock`); a container cannot reach that socket, and handing it the
   socket would give it the whole core (spawn host terminals, type into any of them).
3. **(d) Linux-host panels are not agents to c11h.** A Linux-host panel's foreground is `incus`, which `AgentDetector` classifies as
   `unknown`, so the remote doorbell never rings and hc's turn edges are dropped for it (found by C11H-76's planner).

## The shape

- **Linux relay CLI**: the same Swift CLI sources built for x86_64 Linux (static musl, swift.org toolchain and Static
  Linux SDK), on the Linux-host build box. One contract, no second implementation. A fork of this seat is running the spike
  (worktree `c11h-wt-191-cli`); if the full CLI is too far, a relay-only SwiftPM target of the same sources.
- **Relay kit on the Linux host**: `scripts/c11h-atlas-relay.sh install` made Linux-aware (sha256sum, GNU stat), run on the Linux host
  with the Linux CLI and the app's Claude wrapper. Its manifest makes c11h treat the Linux host as a relay machine at the next
  link-up: every Linux-host terminal gets `C11H_RELAY_BIN`, the fail-closed socket path and a credential pickup (the launch line
  is plain sh and runs `c11 relay-pickup` before the login shell). No app change is needed for this.
- **A relay socket per container** (WORKSPACE-CONTAINERS.md decision 4): `linuxbox-relay-proxy`, a small host process per
  container that `linuxbox-seat` starts, serving a socket bind-mounted into that container at the path the relay shim expects
  (`/home/atin/.local/share/c11h/run/c11h.sock`). It forwards only `doc.get`/`doc.set` on `c11h.relay.r00..r31` and
  `doc.get` on `c11h.relay.seen`, and only for this container: a request must name a panel that entered this container;
  slots another container holds read back as occupied (state and age only, never ids, replies or mail) and cannot be
  written. The spool and pickup documents are refused (telemetry then fails instead of queueing while the link is down).
  The credential (C11H-176) still decides who the caller is; the proxy keeps containers apart below it.
- **`linuxbox-seat`**: per entry, passes `HC_TERMINAL_ID`, `C11H_RELAY_BIN`, the protocol variable and the fail-closed socket
  path into the container, and the terminal's credential as a 0600 file in `/run/agent/relay/` (never argv); mounts the
  kit read-only at its host path; adds `/etc/profile.d/zz-c11h-relay.sh` (relay `bin` first on PATH, the credential
  exported for the shell's own panel); starts the container's proxy; and execs the harness with `exec -a <harness>` so
  hc reports the harness as the foreground name (fixes (d) for the Linux host with the installed app). The kit's `claude` wrapper
  then gives a Linux-host Claude c11h's hooks: turn edges and the Stop-hook mail drain.
- **(d) in the app**: an `incus exec ... --` rail in `AgentDetector` that classifies the harness after `--` (skipping a
  `bash -lc 'exec "$@"' bash` wrapper), so any incus-wrapped seat classifies without the argv[0] trick. Logic test.

## Proof (from the operator's c11h, a client workspace)

P1 a Linux-host owner's `c11 identify` answers through the relay. P2 it renames its panel and sets its description. P3 it raises
and lowers a flag. P4 it mails `client-linuxbox-setup`; the mail arrives with `origin_host=linuxbox`. P5 mail sent to it rings its
doorbell and it reads it (`recv --ack`) or the Stop drain hands it over. P6 a second workspace's container cannot name the
first one's panel (proxy refusal) and cannot read its slots. P7 the build host relay is unaffected. Times recorded.

## Risks and asks

- The running c11h reads a machine's manifest only at link-up: the proof needs one Linux-host link-up after the kit is
  installed (a c11h restart or a deliberate Linux-host link reconnect). Linux-host terminals show Reconnecting for a few seconds.
- A Linux CLI port that runs long: fall back to the relay-only target, then the full port later.
- c11h review and landing gate per AGENTS.md (build-host build for any Swift change, `c11h-shareable.yml`).
