# c11 IPC socket collision — root-cause analysis & production-fix design

> Companion to `docs/socket-collision-fix-brief.md` (the incident write-up). This is the
> engineering design: precise root cause, the fix, the tradeoffs considered, and the test plan.
> Authored 2026-06-29.

## 1. What actually happened (mechanism, not just symptom)

The incident (CLI wedged with `Connection refused, errno 61`; prod GUI alive; socket file present
but no acceptor) is the product of **two independent defects that compound**:

### Defect A — an inherited, cross-bundle `CMUX_SOCKET_PATH` is honored

Prod c11 injects `CMUX_SOCKET_PATH=<prod socket>` into every terminal it spawns (see
`GhosttyTerminalView.swift`). Any build launched *from inside a prod c11 pane* — the normal
dogfooding move (`reload.sh`, `launch-tagged-automation.sh`, `open …Staging.app`) — inherits that
env var pointing at **prod's** socket.

In `SocketControlSettings.socketPath()` the resolution order is:

1. tagged-debug path (`/tmp/c11-debug-<tag>.sock`) — wins for tagged debug builds, ignores ambient `CMUX_SOCKET_PATH`. *Safe.*
2. otherwise, if `CMUX_SOCKET_PATH` is set **and** `shouldHonorSocketPathOverride(...)` is true → return the override.

`shouldHonorSocketPathOverride` returns `true` for **any** debug-like or staging bundle id, with no
opt-in flag. So a staging build (`com.stage11.c11.staging.rel.v0.54.0`) launched from a prod pane
**resolves its own socket path to prod's shared socket** purely because it inherited the env var.
That clause was designed so a *tagged* staging build picks up its *own* tag-matched socket; it does
not distinguish "my own tagged path" from "the prod path I happened to inherit."

### Defect B — bind unconditionally unlinks the path, even if a live peer owns it

`TerminalController.bindListenerSocket()` does `unlink(path)` before `bind()` (to clear a stale
socket from a previous run). It performs **no liveness check**. So once Defect A points the staging
build at prod's socket, staging `unlink()`s prod's *live* socket dentry and binds its own. Prod's fd
stays open in-kernel but is now unreachable; when the interloper exits it unlinks again, leaving the
path with **no acceptor**. Prod never re-binds → permanent wedge until restart.

Forensics matched this exactly: prod (PID 2340, up 18:07) holds the fd; socket + `last-socket-path`
mtime = 18:36 = the staging launch.

### Why C11-105's fix didn't catch it

C11-105 fixed the **shutdown / `stop()`** unlink path (empty default `socketPath` field, gate
`stop()`'s `unlink` on a non-empty path, per-PID XCTest isolation). That closed the teardown stomp.
This incident is a **start-time** stomp via a different door (resolution → bind), untouched by that
fix. They are siblings, not duplicates.

### Aggravating latent gaps found while tracing

- The prod "stable default" socket lives in the **generic** `~/Library/Application Support/c11/`
  dir, not a per-bundle dir — so any build that falls through to the stable-default branch lands on
  the *same* file. (Staging/debug/nightly already use distinct `/tmp/*.sock` paths.)
- Child-PTY env injection uses `SocketControlSettings.socketPath()` (the *resolution-time* path),
  **not** `TerminalController.activeSocketPath()` (the *actually-bound* path). If the binder ever
  falls back to an alternate path, children would be handed the wrong path.
- Only `CMUX_SOCKET_PATH` is injected into child env; the canonical `C11_SOCKET_PATH` is not.

## 2. The fix (three coordinated changes; B is the load-bearing guarantee)

### B. Liveness-aware bind — *never stomp a live peer* (the definitive guarantee)

In `bindListenerSocket`, before `unlink(path)`: if the path exists, is a socket, and a `connect()`
probe **succeeds** (a live acceptor is there) → do **not** unlink; return a new
`.peerAlive(path:)` result. `start()` treats `.peerAlive` like an `EADDRINUSE` collision: it
computes a safe alternate path (user-scoped stable path, or a pid-scoped sibling) and binds there
instead of wedging the incumbent. This holds regardless of *how* resolution produced the path — it
is the general safety net (also covers two prod instances, future resolution bugs, etc.).

### C. Don't honor an inherited cross-bundle override (kills this exact incident at resolution)

`shouldHonorSocketPathOverride` keeps honoring `CMUX_ALLOW_SOCKET_OVERRIDE` and a build's own
tag-matched path, but a debug/staging build must **not** honor an ambient `CMUX_SOCKET_PATH` that
resolves to **another bundle's** stable/default socket (notably prod's shared path) unless the
explicit opt-in flag is set. So staging launched from a prod pane falls through to its own
`/tmp/c11-staging.sock`, never touching prod's socket.

### A. Namespace the stable socket per bundle id (defense-in-depth)

Move the prod stable socket + `last-socket-path` from `…/c11/` to `…/<CFBundleIdentifier>/`
(`com.stage11.c11/c11.sock`). Mirror the directory derivation in the CLI resolver. Builds then have
distinct default paths even before B/C engage. `/tmp/*` schemes for tagged-debug/staging/nightly stay
untouched (already namespaced, widely referenced by skill/scripts/tests_v2). Migration is a one-time
restart: after restart prod binds the per-bundle path and writes `last-socket-path` there + the legacy
`/tmp` breadcrumb, which the CLI already discovers.

### Plus the two latent gaps

- Inject the **bound** path (`activeSocketPath`) into child PTY env, not the recomputed path.
- Inject `C11_SOCKET_PATH` alongside `CMUX_SOCKET_PATH`.

## 3. Options considered & rejected

- **B alone (probe only), no namespacing/override change.** Prevents the wedge, but staging still
  *resolves* to prod's path and only avoids it by the probe → noisy fallback every dogfood launch.
  Keeping C makes the common path clean.
- **Remove the debug/staging honor clause entirely.** Breaks the legitimate tagged-staging workflow
  and two existing tests (`testStagingBundleHonorsSocketOverrideWithoutOptInFlag`, debug equivalent).
  The surgical cross-bundle guard (C) preserves them.
- **Move tagged debug/staging sockets into App Support too.** Large blast radius (skill, launch
  scripts, `tests_v2`, `/tmp/c11-debug-<tag>.sock` contract). Not needed — those are already
  collision-free. Out of scope.
- **Self-heal (re-bind on unlink-out-from-under).** The socket-watcher tool shows appetite, but it
  balloons scope and the probe makes the triggering scenario rare. Deferred; noted as follow-up.

## 4. Acceptance criteria mapping

| Criterion | Covered by |
|---|---|
| Coexistence (prod+staging+debug, each CLI works, no wedge) | A (distinct defaults) + B (no-stomp) |
| No stomping a live different-bundle socket | B (probe-before-unlink) |
| Resolution correctness (build X's shell reaches build X) | C + bound-path env injection + last-socket-path breadcrumb |
| Existing socket tests green + new regression | §5 |
| Operator restart minimal & clear | §6 |

## 5. Test plan (logic target — `c11-logic`, host-less, safe local)

- `socketHasLiveListener(path:)` returns false for a non-socket / dead path; true for a live one
  (bind a real listener in-test, probe it).
- `bindListenerSocket` against a path with a live acceptor returns `.peerAlive` and does **not**
  unlink it (incumbent stays connectable).
- Cross-bundle override guard: staging/debug bundle + ambient `CMUX_SOCKET_PATH` == prod stable
  default → resolves to the build's own default, not prod's path; with `CMUX_ALLOW_SOCKET_OVERRIDE=1`
  → honored. Tag-matched path (`/tmp/c11-staging-my-tag.sock`) still honored (existing tests stay green).
- Per-bundle stable path: `stableSocketFileURL()` contains the bundle id segment.

## 6. Operator restart (hand-back)

The fix must be **in the binary before** prod restarts (restarting first loses nothing but also
fixes nothing). Build a fixed prod-equivalent, then the operator quits the wedged prod and launches
the fixed build. After restart, `c11 identify` connects and the staging-from-prod-pane repro no
longer wedges prod.
