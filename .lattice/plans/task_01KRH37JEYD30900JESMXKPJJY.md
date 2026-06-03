# C11-38: Slice 2 — Bootstrap + Hetzner provisioning + manual SSH viewer (parity proof)

Combines architecture-doc slices 2 + 3. Deliverables: (a) `Resources/bin/c11-bootstrap` that installs tmux + claude + drops c11-spawn-agent on a fresh box (macOS + Debian/Ubuntu branches via uname); (b) `scripts/provision-hetzner.sh` using hcloud CLI (Ubuntu 24.04 LTS, CPX21, Tailscale joined); (c) parity validation: the same c11-spawn-agent invocation works identically on Hetzner. Manual viewer = raw `ssh host -t 'tmux -L agents attach ...'` — no local c11 code yet.
