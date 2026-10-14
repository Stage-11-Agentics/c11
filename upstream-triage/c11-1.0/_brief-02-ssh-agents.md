# Topic 02: Agents on SSH hosts, and moving sessions between machines

**Report path:** `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/02-ssh-agents.md`

Atin is very interested in this one. It maps onto his real setup: Hyperion (the MacBook, which by rule does no heavy work) and Atlas (the always-on Mac Studio on the tailnet). Read `~/.claude/CLAUDE.md`'s Machines section for that context.

In cmux (unreleased on main):

- #14902: Claude Code and Codex running on a remote host report status to the local sidebar.
- #14959: `cmux session move` moves a stopped session, with its transcript, memory and git tree, between the Mac and an SSH host.
- The surrounding remote machinery: `cmux ssh`, `mosh`, `ssh-tmux`, `mosh-tmux`, `ssh-session-list`, `ssh-session-attach` and `ssh-session-cleanup`, and `cmux-tui`, the headless server that owns sessions so agents outlive the GUI. Cover these only as far as the first two depend on them.

Find out how each actually works: transport, how status crosses the wire (a reverse socket? a relay? ssh forwarding of the cmux socket?), auth, what has to be installed on the remote host, and failure modes when the link drops.

Then propose the c11 1.0 shape. Target experience: from Hyperion, Atin opens a c11 tab whose agent runs on Atlas, and that tab gets full c11 citizenship (sidebar status, `set-agent`, metadata, flags, mailbox, `read-screen`, resume after restart). He can also move a stopped session from Hyperion to Atlas and back. Consider:

- c11's socket and CLI forwarded over ssh, a small c11 agent on the remote host, or a relay.
- How this composes with c11 itself running on Atlas.
- Overwatch: read `~/Projects/Stage11/code/overwatch/CLAUDE.md` and `SEAT-MODEL.md`. Seats today run on Prime boxes that never join the tailnet and are attached view-only. Say whether c11 remote agents could replace or complement `seat-attach`, without breaking the hard rule that boxes never join the tailnet.
