# Implementation Plan: C11-7 — Automation socket reliability

**Ticket:** task_01KPS4FBHSSCCJC3EP43YJ7XMZ
**Branch:** c11-7/bounded-waits
**Plan author:** agent:opus-c11-7-plan
**Date:** 2026-04-24

---

## Status of prior work

### Items 1-3 (commit 3d0b8257)

Audited via `git show 3d0b8257 --stat`, `git diff main HEAD -- CLI/c11.swift`, and `git diff main HEAD -- tests/test_cli_socket_deadline.py`.

**Item 1: Bounded CLI waits — CONFIRMED.**
- `SocketDeadline` enum added to CLI: `.default` (10s, env-tunable), `.none` (unbounded), `.custom(TimeInterval)`.
- Default reads `C11_DEFAULT_SOCKET_DEADLINE_MS` (primary) then `CMUX_DEFAULT_SOCKET_DEADLINE_MS` (compat) then legacy `CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC`, falls back to 10s.
- `send(command:responseTimeout:)` overload plumbed through `configureReceiveTimeout` which correctly clears `SO_RCVTIMEO` when `timeout == nil`.
- Opt-outs with `deadline: .none`: `pane.confirm` (line 1989), `browser.wait` (line 5338), `browser.download.wait` (line 5873). Correct; these are governed by server-side timeouts.

**Item 2: Named timeout errors — CONFIRMED.**
- Stable `c11: timeout:` prefix present.
- Fields: `method=`, `workspace=`, `surface=`, `pane=`, `panel=` (when present in params), `socket=`, `elapsed_ms=`.
- Exits non-zero on timeout.
- `traceStatus = "timeout"` set before the re-throw so trace output also reflects the timeout.

**Item 3: Trace mode — CONFIRMED.**
- `C11_TRACE=1` and `CMUX_TRACE=1` both set `SocketClient.traceEnabled = true`.
- `[c11-trace] -> <method> (<refs>) socket=<path>` emitted to stderr before send.
- `[c11-trace] <- <method> elapsed=<N>ms status=<ok|timeout|error>` emitted after, via `defer`.
- `traceRefs(from:)` helper extracts workspace/surface/pane/panel refs from params.

**Tests in tests/test_cli_socket_deadline.py — SOLID.**
Three tests, all using a real deaf-socket harness (accepts but never writes). Verifies observable behavior (exit code, stderr content, timing). Correctly skips if CLI binary not found. Does not inspect source code or file structure. Appropriately designed for CI.

**One minor removal in the diff not called out in the commit message:**
The diff removes `isAdvisoryHookConnectivityError` and the `claude-hook` connect-failure suppression path. This appears intentional (simplification — the advisory no-op was fragile), but is undocumented. Not a blocker; note for review.

### Item 4 (notify v2, PR #66)

DONE. Landed on main via commit `8ffcae8f`.

---

## Remaining work

### Item 5: Main-thread audit doc

- **Status:** DONE (this plan session).
- **Output file:** `notes/c11-7-mainthread-audit-2026-04-24.md`
- **Summary:** 105 total `DispatchQueue.main.sync` occurrences across Sources/. 48 SAFE, 38 RISKY, 19 NEEDS_ASYNC. The 19 NEEDS_ASYNC occurrences are in workspace/surface/pane/window creation handlers — the paths agents call most under rapid automation. Full table and migration priority in the audit file.

### Item 6: Deadline-aware main actor bridge

**Problem:** Items 1-3 fix the CLI side — the CLI now exits with a named error after 10s. But the server-side socket handler is still blocked: `DispatchQueue.main.sync` inside the background accept-thread blocks indefinitely waiting for main. Under rapid multi-agent automation (many `workspace.create` / `surface.create` calls), the main thread queues up many sync dispatches. Each one blocks the socket thread until the previous finishes, which can be seconds. The 10s CLI deadline fires before the server has responded, but the server handler is still blocking.

**Approach:** Two implementation options; recommend Option A.

**Option A (minimal change — recommended for this ticket):** Replace `DispatchQueue.main.sync` in Tier 1 handlers with a semaphore+deadline pattern. Keeps the existing background-thread accept loop architecture; no Swift Concurrency rearchitecture needed.

```swift
// In TerminalController.swift, alongside v2MainSync:
private func v2MainSyncWithDeadline<T>(
    seconds: TimeInterval = 10.0,
    _ body: @escaping () -> T
) -> T? {
    if Thread.isMainThread { return body() }
    var result: T?
    let sema = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        result = body()
        sema.signal()
    }
    let waited = sema.wait(timeout: .now() + seconds)
    return waited == .success ? result : nil
}
```

Callers that currently use `v2MainSync { ... }` for creation paths switch to `v2MainSyncWithDeadline { ... }`. If nil is returned, the handler returns a `v2Error` with `code: "main_thread_timeout"`. The CLI caller receives the error JSON within the deadline window instead of waiting for the full 10s `SO_RCVTIMEO`.

**Option B (full async refactor — defer to C11-4):** Rearchitect the accept loop to use Swift Concurrency (`async`/`await`, `Task { @MainActor }`). Cleaner long-term but requires restructuring `handleClient`, `processCommand`, and `processV2Command` to be async. Scope: ~500 lines. Better for C11-4 which owns the full bounded-dispatch work.

**Decision for C11-7:** Apply Option A to Tier 1 handlers only (workspace.create, surface.create, pane.create, window.create, new_workspace, new_split, drag_surface_to_split). This closes the "server side can still hang" gap. C11-4 then owns the full async refactor.

**Files to change:**
- `Sources/TerminalController.swift`: add `v2MainSyncWithDeadline`, update 7 Tier 1 handler call sites
- `CLI/c11.swift`: no changes needed (already done by items 1-3)

**Key decision:** The deadline passed to `v2MainSyncWithDeadline` should be slightly shorter than the CLI deadline (e.g., 8s) so the server-side error propagates before `SO_RCVTIMEO` fires. This gives the CLI a clean JSON error response rather than a bare timeout.

**What this does NOT fix:**
- The 38 RISKY handlers that are fast under normal load but block under heavy concurrency. Those are C11-4 scope.
- The `appendLog` RISKY path (telemetry hotpath). Fix is trivial (switch to `.async`) but out of scope for this item.

### Item 7: Regression stress test

**Goal:** Assert that no CLI process can hang indefinitely during rapid mixed-surface creation. Tests run in CI only (per CLAUDE.md testing policy).

**File:** `tests_v2/test_socket_reliability_stress.py`

**Approach:**
- Use the `cmux` Python client from `tests_v2/cmux.py` to connect to a running c11 debug instance.
- Rapidly issue `workspace.create`, `surface.create` (terminal, browser, markdown), `pane.create`, and `surface.set_metadata` commands concurrently via `threading.Thread`.
- Each CLI call via `subprocess.run` is given a hard timeout of 12s (above the 10s CLI deadline).
- Assert all calls complete within that timeout (no hung processes).
- Assert CLI processes that do timeout exit with the `c11: timeout:` prefix, not hang indefinitely.
- Clean up created workspaces/surfaces after the test.

**Key design constraints:**
- Must connect to a real running c11 instance (uses `CMUX_SOCKET` / `C11_SOCKET` env var). Skips gracefully if socket not found.
- Does NOT inspect source code or count `DispatchQueue.main.sync` occurrences.
- Tests observable timing behavior: "all 20 CLI calls completed within 12s" is the assertion.
- Uses the `C11_DEFAULT_SOCKET_DEADLINE_MS=9000` env var to set a known CLI deadline for the stress test.

**Test sketch:**

```python
def test_no_cli_hangs_under_rapid_surface_creation(c11: cmux, cli_path: str) -> None:
    """Rapid mixed surface creation must not cause any CLI call to hang indefinitely."""
    CONCURRENT_CALLS = 20
    PER_CALL_TIMEOUT_S = 12.0  # well above 10s CLI deadline
    CLI_DEADLINE_MS = "9000"   # leaves 3s for the server to propagate the error

    results = []
    threads = []

    def create_workspace():
        proc = subprocess.run(
            [cli_path, "workspace.create"],
            env={**os.environ, "C11_DEFAULT_SOCKET_DEADLINE_MS": CLI_DEADLINE_MS},
            capture_output=True, text=True, timeout=PER_CALL_TIMEOUT_S, check=False,
        )
        results.append((proc.returncode, proc.stderr))

    for _ in range(CONCURRENT_CALLS):
        t = threading.Thread(target=create_workspace, daemon=True)
        threads.append(t)

    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=PER_CALL_TIMEOUT_S + 2.0)

    hung = [t for t in threads if t.is_alive()]
    assert not hung, f"{len(hung)} CLI calls hung past the deadline+grace period"

    # Any failed calls should carry the named timeout prefix, not be silent failures
    for returncode, stderr in results:
        if returncode != 0:
            assert "c11: timeout:" in stderr or "error" in stderr.lower(), \
                f"Non-zero exit without named error: {stderr!r}"
```

---

## Implementation order

1. **Item 5 (audit doc):** Done in this plan session. File is at `notes/c11-7-mainthread-audit-2026-04-24.md`. No further work needed; C11-4 can cite it directly.

2. **Item 6 (deadline-aware main actor bridge):** Implement `v2MainSyncWithDeadline` and wire it into the 7 Tier 1 creation handlers. Commit separately from item 7.

3. **Item 7 (stress test):** Write `tests_v2/test_socket_reliability_stress.py` after item 6 is in, so the test exercises the fixed code paths. Commit to the same branch.

4. **PR:** Squash items 6-7 into logical commits, push to `c11-7/bounded-waits`, open PR targeting main.

---

## Do NOT ship

- A full Swift Concurrency refactor of the accept loop (C11-4 scope).
- Changes to the 38 RISKY-but-not-creation handlers (appendLog, notifyCurrent, etc.) — C11-4 scope.
- Any changes to `CLI/c11.swift` beyond what landed in commit 3d0b8257.
- Reverting or modifying the `claude-hook` connect-failure suppression removal (it's gone, leave it gone).
- Any `install`-style hooks or writes to external tool config files (per CLAUDE.md principle: c11 is unopinionated about the terminal).

---

## Acceptance criteria verification

| Criterion | How met |
|-----------|---------|
| CLI socket commands have a default 10s deadline | `SocketDeadline.default` → `configuredDefaultDeadlineSeconds` = 10s. Confirmed in audit of commit 3d0b8257. |
| Timeout exits non-zero with parseable named error | `c11: timeout: method=... socket=... elapsed_ms=...`. Confirmed. |
| Long-runners opt out | `pane.confirm`, `browser.wait`, `browser.download.wait` use `deadline: .none`. Confirmed. |
| `C11_TRACE=1` emits bracketing lines | `[c11-trace] ->` / `<-` with status and elapsed. Confirmed. |
| Tests cover the above | Three tests in `tests/test_cli_socket_deadline.py`, behavioral not structural. Confirmed. |
| Main-thread audit doc exists | `notes/c11-7-mainthread-audit-2026-04-24.md`. Written this session. |
| Server side has bounded dispatch for creation handlers | Item 6 (pending): `v2MainSyncWithDeadline` wired into Tier 1 handlers. |
| Stress test covers concurrent surface creation | Item 7 (pending): `tests_v2/test_socket_reliability_stress.py`. |
