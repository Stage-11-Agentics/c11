# C11-36: Autonomous Connections — remote agents over c11

Umbrella ticket. Run autonomous Claude Code agents on remote servers (Atlas, Hetzner), controlled from local c11. Server-side: bash scripts shipped in c11's Resources/bin/. Local-side: new `c11 remote` subcommand namespace. Mapping: tmux session <-> c11 workspace, tmux window <-> c11 surface, one agent per window. Architecture doc attached. Built in 3 slices below; explicit non-goals in the doc.
