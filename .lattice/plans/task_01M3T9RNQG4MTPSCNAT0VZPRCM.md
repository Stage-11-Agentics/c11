# C11-247 — wait for an attached terminal before the CI smoke send

## Cause

`scripts/smoke-test-ci.sh` pings the socket, then immediately sends v1 `send time\n` with a 5s recv timeout. `sendInput` waits at most 2s for `terminalPanel.surface.surface`. On the virtual-display runner that attach can take about 3s (`Welcome quad: initial terminal not ready after 3.0s`), so the recv timeout has no margin.

## Change (script only)

In `scripts/smoke-test-ci.sh`, after a successful ping and before `send time`:

1. Poll v2 `debug.terminals` on the same socket until one terminal has `runtime_surface_ready: true` (`surface != nil`, the predicate `send` waits on) and `surface_focused: true`. `list_surfaces` only shows that a panel exists; `surface.list`'s `tty` is a later shell-integration report and is not what `send` waits for.
2. Bound the poll at 20s. Log each poll (index, elapsed, terminal counts). On timeout or app death, print a clear error and the same log tails the script already dumps, then exit 1.
3. Retry `send time\n` once if the reply is a timeout or an `ERROR:` line, with a log line that says it retried. A second timeout fails the script. A second error reply is logged and the existing stability check still decides, matching today's non-timeout path.

No app code, no new tests. `bash -n` and shellcheck locally. Proof is the `ci-macos-compat` smoke step on the PR (the workflow runs on `pull_request` and has no `workflow_dispatch`).
