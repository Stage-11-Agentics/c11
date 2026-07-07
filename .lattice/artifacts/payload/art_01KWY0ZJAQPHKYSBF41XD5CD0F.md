# C11-165 Validation Report (tagged build `cor-post`)

Branch `ts/cor-p0-correctness` @ 2 commits (092855747 COR-1/COR-2, cf0c11736 COR-3/COR-4).
Tagged build: `./scripts/reload.sh --tag cor-post` → **BUILD SUCCEEDED**, app launched (pid 143), socket `/tmp/c11-debug-cor-post.sock` bound. Validation driven live against that socket.

## COR-1 — empty/absent surface-ref rejection (EVALUATION: autonomous)
`tests_v2/test_cor1_empty_ref_rejection.py` → **PASS**. Matrix over the write family (`surface.set_metadata`, `surface.clear_metadata`, `surface.trigger_flash`, `pane.set_metadata`, `pane.clear_metadata`, `surface.action` rename):
- present-but-empty ref (`""`, whitespace) → `empty_ref` for every method.
- absent ref → `missing_ref` for every method.
- coarser `workspace_id`-only ref on a surface-pinned write → `missing_ref` (does not misroute to focus).
- **No rejected call mutated the control surface** (read-back unchanged) — no write lands.
- Positive control: a valid explicit write still succeeds.

Fast suite: `c11-logic` → **11/11** `SocketSurfaceRefValidatorTests` pass (pure seam). Wiring: `SocketSurfaceRefRejectionWiringTests` links, but the `c11-unit` HOST target cannot compile on the base (pre-existing `c11Tests/SurfaceActivityTests.swift` break, RES domain — flagged to orchestrator); the live socket matrix above is the authoritative wiring proof.

## COR-3 — main-thread-reachable socket paths (EVALUATION: autonomous)
`tests_v2/test_cor3_socket_flood_mainthread.py` → **PASS**: 31 liveness probes under an 8-thread telemetry flood + a concurrent `feedback.submit` blocker; worst probe latency **37ms** (« 2000ms bound). Pre-fix, `feedback.submit` on the main policy froze main ~35s.

Direct `pane.confirm` off-main proof: fired a `pane.confirm` with a 3s wait; a concurrent `workspace.list` probe stayed responsive (worst **752ms**, the dialog-present cost) vs. the ~3000ms freeze it would show if the semaphore wait were still on main. Confirms the wait blocks a worker, not main.

Hang monitor: `~/Library/Logs/c11/hang.log` shows **no entries for pid 143** (the cor-post app) during validation (unrelated entries belong to another instance's pid).

Sweep artifact: `notes/c11-165-mainthread-sweep.md` — 0 bare `CFRunLoopRun`/`CFRunLoopStop` remain; all `semaphore.wait` sites off-main; `main.sync` only at the dispatch seam; browser deliberately kept on main (WebKit affinity) with the nested-loop wedge fixed via sliced `CFRunLoopRunInMode`.

## COR-2 — skill footgun (EVALUATION: autonomous)
`skills/c11/SKILL.md` + `references/metadata.md` rewritten to the new contract (missing/empty ref now errors, no silent misroute); `scripts/sync-installed-skills.sh c11` run (installed copy refreshed).

## COR-4 — regression tests (EVALUATION: autonomous + external-oracle)
- Logic suite: `SocketSurfaceRefValidatorTests` (11 cases) — green in `c11-logic` (CI-gated).
- Socket suite: `test_cor1_empty_ref_rejection.py` + `test_cor3_socket_flood_mainthread.py` — pass live; both fail-not-skip when the socket is unreachable. Home is the c11-vm socket lane (tests_v2 is not in GitHub CI — see plan §8.12).
