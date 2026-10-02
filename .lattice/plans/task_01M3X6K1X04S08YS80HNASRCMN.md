# C11-296 — demand-start a cold screen read

Owner agent:astra-hangs; build-mode base `7bb785741750ddeb8ab12b4cf6472593fb8c3550` (original planning base `0ff8887e5e965400b01645ef40b85fd0b2605cf2`). Separate branch/PR `c11-1.0/C11-296-cold-read`, created from origin/main. Land before C11-295, which rebases onto this handler. No dependency on the Ghostty bump for this small change.

## Verified architecture

B087 is confirmed by `Sources/SocketHandlers/SurfaceHandlers.swift:1111-1176`: read resolves and formats immediately on main. `TerminalController.swift:3388-3445::waitForTerminalSurfaceOffMain` already requests background start, installs ready/host observers, closes its registration race and waits up to the supplied deadline. `v2SurfaceSendText` uses it with 2 seconds (`SurfaceHandlers.swift:884`). Reuse it exactly once, outside main; the returned pointer is only a readiness indication, never dereferenced off main. CLI `read-screen` uses `tab.read_text` (`CLI/c11.swift:2940`), whose canonical handler is `v2SurfaceReadText`; legacy surface method aliases reach it too. Legacy v1 `read_screen` has a separate path and is not silently claimed fixed by this v2/CLI ticket.

Read ticket, seeded plan, `05-bug-sweep.md`, ledger B087, Fable cold-start cluster, Astra cold-start correction and reconciled tiers. C11-130/169/235 provide the incident shape; specific incident attribution remains inferred.

## Change

In `SurfaceHandlers.swift::v2SurfaceReadText`, split the existing main task into resolution, the existing off-main readiness wait, and a final main read. Preserve resolution/fallback semantics and response keys. In the final hop verify that the captured tab is still a live member of the resolved workspace, then re-read its current runtime; a tab closed during the wait must error rather than format a stale pointer. If the cold wait ends without a surface, preserve the existing read error shape. Keep current formatting and encoding on main for C11-295. Update the obsolete no-wait comment. No second observer/waiter, main-loop pumping or send behavior change.

Update `skills/c11/references/api.md` to say reads request startup without focus and allow the existing 2-second startup budget; the Merge Captain alone syncs the installed skill after landing, per go-owner.md; this seat does not edit installed skills.

## Acceptance → fixture → proof

1. **Cold-read AC1 / B087:** Extend `tests_v2/test_new_surface_no_focus.py` or add a small `test_read_screen_cold_start.py`. Create a never-focused terminal with no eager command, read its exact UUID before selecting it, verify successful text response and unchanged selection/focus. Use a host test fixture in `c11Tests/TerminalAndGhosttyTests.swift` that begins with an absent runtime so this cannot pass merely because creation raced ahead. On Atlas tagged build poll only within the existing 2-second startup budget plus measured socket scheduling allowance for a shell prompt; readiness does not promise the shell has already printed on the first read.
2. **Closed-tab AC2 / closed-while-waiting fixture:** Read a closed UUID; the deterministic host fixture removes the owning workspace on the cold runtime ready notification, between resolution and completion, while retaining the runtime to detect a stale-object read. Both fail; the readiness wait stops within 2 seconds plus scheduling allowance and observers are removed. Use UUIDs: unresolved short-handle fallback is B066/C11-295 and intentionally unchanged here. A busy/wedged main's whole-request deadline is also C11-295, not supplied by this helper.
3. **Focused-read AC3 / capture parity:** Include synthetic numbered lines and Unicode in `tests_v2/test_read_screen_cold_start.py`; viewport, scrollback and last-N behavior remain the same. Exercise canonical `tab.read_text`, compatibility method alias, and shipped CLI `read-screen`.

Build-mode validation follows go-owner.md: GitHub CI until ATLAS BUILDS LIVE is sent. C11-296 is outside the pre-merge runtime risk list and changes no typing/input/focus path, so tagged runtime acceptance belongs to the batch Validator. Use the isolated Atlas tagged socket/sandbox route, never the operator session. No CUA required for text semantics; any screenshot must show readable areas. Record exact SHA, target socket and actual assertions. No source-grep tests.

## Impact and cut line

The 2-second wait stays off main. No changes to `forceRefresh`, `hitTest`, `TabItemView`, sidebar equality, telemetry or long-lived thread pools. No new localization keys, persistence migration, tenant config or renderer loop. No B003 bootstrap re-adoption, B086 formatting/deadline, B066 ref hardening, B189 transport, selection command (C11-282), or legacy v1 expansion.

The soak is deferred by go-owner.md. The batch Validator records first cold-read elapsed time, then compares candidate and origin/main on the same tagged host with load average. No claim of measured typing latency or completed soak from this seat; no typing path changes. Cold-start scheduling allowance in the socket scenario is 2 seconds beyond the shared 2-second readiness budget, not a whole-request deadline guarantee. Open decisions: none. Review routed only by Orchestrator, maximum three cycles; one PR, no merge/release.
