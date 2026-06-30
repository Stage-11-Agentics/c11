# c11 — IPC socket collision across builds (incident + production-fix brief)

> **Purpose.** This is both the **bug write-up** and the **expert prompt** for an agent tasked with the production fix. It was authored from live forensics on 2026-06-29 by a sibling session that hit the bug. **Research and plan carefully before implementing** — this is the IPC seam every agent and the whole sidebar depend on. Do **not** restart/relaunch c11 yourself (it may kill live sessions, possibly your own); prepare the fixed build and hand the restart back to the operator (that's the whole point of fixing *before* the restart).

---

## TL;DR
All c11 builds (prod / staging / debug) share **one IPC socket path** — `~/Library/Application Support/**c11/**c11.sock` — instead of namespacing it per bundle id. Running a staging + debug build alongside the already-running prod app today caused a later instance to **re-bind/unlink that shared socket**, orphaning prod's listener. When the extra instances exited, the path was left with **no live acceptor**, so every `c11 …` CLI call now returns **"Connection refused (errno 61)"** while the prod GUI keeps running, permanently wedged (it never re-binds). Fix: **namespace the socket per build and stop instances from stomping a live peer's socket.**

## Evidence (filesystem forensics)
- **One socket, shared:** `~/Library/Application Support/c11/c11.sock` + `last-socket-path` both live in the **generic `c11/`** dir. The per-build support dirs that *do* exist — `com.stage11.c11`, `com.stage11.c11.debug`, `com.stage11.c11.staging`, `com.stage11.c11.staging.rel.v0.54.0` — **hold no socket of their own.** Every build resolves to the same socket path.
- **Three builds live together today** (session files written into the shared `c11/` dir): `session-com.stage11.c11.json` (prod, live), `session-com.stage11.c11.debug.v054input.json` (debug, 18:57), `session-com.stage11.c11.staging.rel.v0.54.0.json` (staging, 18:57).
- **Timeline:** prod app (PID 2340) up since Fri 18:07 holds `c11.sock` fd 5u (lsof). The socket + `last-socket-path` **mtime = 18:36**, matching the **staging** support-dir mtime → a later instance re-created/re-bound the shared socket at 18:36, orphaning prod's listener. Extra instances exited → dead path → all CLI connects refused; prod never recovers.
- `tools/socket-watcher/Sources/SocketWatcherKit/SocketWatcher.swift:11` already notes "`…/c11/c11.sock` is being unlinked while …" — this failure mode is partly known; read it.

## Where the code lives (start here)
- **`Sources/SocketControlSettings.swift`** (~L301-304): `stableSocketFileName = "c11.sock"`, `lastSocketPathFileName = "last-socket-path"`, `legacyStableDefaultSocketPath = "/tmp/c11.sock"`, `legacyLastSocketPathFile`. **This is where the socket path + breadcrumb are constructed** — the heart of the fix.
- **`CLI/c11.swift`** (~L697-701, 784, 1416, 1469): CLI-side resolution — reads `last-socket-path`, legacy `/tmp/cmux-last-socket-path`, `CMUX_TAG`, and env (`CMUX_SOCKET_PATH`). The CLI must still find the *right* socket after the fix.
- **`Sources/c11App.swift`, `Sources/TerminalController.swift`** (socket-fast-path queue), `Sources/Workspace.swift` — bind/serve lifecycle.
- **Tests already covering this area** (keep green, extend): `c11Tests/SocketControlSafetyTests.swift`, `TerminalControllerSocketSecurityTests.swift`, `SocketControlPasswordStoreTests.swift`, `c11UITests/AutomationSocketUITests.swift`, and the `tools/socket-watcher` package.

## Your mission
1. **c11 hygiene first** (note: the live socket is wedged, so `c11 …` self-reporting will fail until after the operator restarts — don't block on it). If you *can* talk to c11, orient + name your tab `Socket Collision Fix`; otherwise proceed and self-report after the restart.
2. **Open a Lattice ticket** in the c11 repo (load the `lattice` skill; this repo tracks work in Lattice). Capture the incident + plan there.
3. **Research deeply, then plan** — read the files above and trace the *full* socket lifecycle: how the path + `last-socket-path` breadcrumb are derived; bind/unlink/serve; how the CLI and the shell env (`CMUX_SOCKET_PATH`/`CMUX_TAG`) resolve which socket to hit; what happens when a second build launches; the socket-watcher's role. Write a short **design doc / plan** (in `docs/` or the Lattice plan) with options + tradeoffs **before** coding.
4. **Implement the production fix** (see directions below), with tests, then **build** per the repo's process (e.g. `reload.sh` / the build script) so a fixed binary is ready.
5. **Stop and hand back to the operator for the restart.** Report: what changed, that the build is ready, and the exact restart steps. Do **not** quit/relaunch c11 yourself.

## Fix directions to evaluate (design for these; don't just patch the symptom)
- **Namespace the socket per build (primary).** Bind `~/Library/Application Support/<CFBundleIdentifier>/c11.sock` and write `last-socket-path` into that **per-bundle** dir (those dirs already exist). Goal: prod, staging, and debug **coexist**, each on its own socket — no contention.
- **Never stomp a live peer (hardening).** On bind/`EADDRINUSE`, only unlink+replace a socket if its owning process is **dead** (probe liveness); never unlink a socket a *different live bundle* is serving. Make the bind defensive regardless of path scheme.
- **CLI/env resolution must follow the build.** A shell spawned by build X must resolve to build X's socket (via env `CMUX_SOCKET_PATH`/`CMUX_TAG` and/or a per-bundle `last-socket-path`). Make sure an agent in a staging surface can't accidentally talk to (or clobber) prod.
- **Migration / back-compat.** Handle existing breadcrumbs and the legacy `/tmp` paths; don't strand already-running sessions more than the one-time restart requires. Consider a deprecation path for the shared `c11/` location.
- **Self-heal (nice-to-have).** Should a running app detect its socket was unlinked out from under it and **re-bind**, rather than wedging until restart? (The socket-watcher tool suggests appetite for this.) Evaluate, but don't let it balloon the change.

## Acceptance criteria for the fix
- **Coexistence:** prod + staging + debug can run simultaneously; each has a working CLI; launching/quitting one never wedges another. (Reproduce the original failure first, then prove it's gone.)
- **No stomping:** a second instance never unlinks/replaces a socket served by a live different-bundle process.
- **Resolution correctness:** `c11 identify` from a shell spawned by build X reaches build X.
- **Tests:** existing socket tests stay green; add a regression test for the multi-build collision (and ideally an automated repro).
- **Operator restart:** clear, minimal steps; after restart on the fixed build, `c11 identify` connects and the original repro no longer wedges.

## Notes
- This is dogfooding — Stage11 builds and runs c11 daily; multiple builds running at once is a *normal* developer workflow, so coexistence is the real requirement, not just "don't run two."
- Keep the change tight and well-tested; this is the IPC seam everything depends on. Commit as you go; open a PR per repo convention.
