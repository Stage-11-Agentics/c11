# C11-167 — Derived-liveness event emission: recorded demonstration

**Build:** tagged `c11-167` (`./scripts/reload.sh --tag c11-167`), instance `c11-167-57726`, BUILD SUCCEEDED.
**Bar:** SPEC EVT-2 — a derived working↔idle transition produces an event observable via `c11 events tail`.

## What was driven

A real command (`sleep 2`) run in a shell-integrated terminal surface (surface:1,
workspace:1). The shell integration's `preexec`/`precmd` hooks call
`report_shell_state running|prompt` over the socket → `updatePanelShellActivityState`
→ `SurfaceLivenessDeriver.onShellActivityChanged` → `emitLivenessTransition` →
(C11-167 wiring) `EventEmitter.shared.emitDerivedLiveness(...)`.

## Follower (live capture)

Command left running for the whole demo:
```
c11 events tail --instance c11-167-57726 --follow --filter type=liveness.derived
```

Captured output:
```
{"instance":"c11-167-57726","payload":{"state":"idle"},"seq":11,"surface":"45CF6333-B91D-43EF-8985-52EEAFA54286","ts":"2026-07-08T17:00:57.312Z","type":"liveness.derived","v":1,"workspace":"17D9EBD5-A8CC-47DA-A40C-CD65226C4166"}
{"instance":"c11-167-57726","payload":{"state":"working"},"seq":12,"surface":"45CF6333-B91D-43EF-8985-52EEAFA54286","ts":"2026-07-08T17:00:58.468Z","type":"liveness.derived","v":1,"workspace":"17D9EBD5-A8CC-47DA-A40C-CD65226C4166"}
{"instance":"c11-167-57726","payload":{"state":"idle"},"seq":14,"surface":"45CF6333-B91D-43EF-8985-52EEAFA54286","ts":"2026-07-08T17:01:00.581Z","type":"liveness.derived","v":1,"workspace":"17D9EBD5-A8CC-47DA-A40C-CD65226C4166"}
```

## Reading

- `seq 11 state=idle`  — shell settled to prompt (idle).
- `seq 12 state=working` — `sleep 2` started (preexec → running → working).
- `seq 14 state=idle`  — `sleep 2` finished, prompt returned (precmd → prompt → idle).

A full working↔idle round-trip, each transition surfaced as a distinct
`liveness.derived` event with `{state}` payload, `workspace`+`surface` refs, and
schema `v:1`. Before the C11-167 wiring these events never emitted (the seam was a
DEBUG-only no-op).

## Note (out of scope, filed for awareness)

On the QA-fresh tagged launch, the surface's `CMUX_TAB_ID` env was seeded to the
*surface* UUID rather than the *workspace* UUID, so the integration's auto-report
used a `--tab` that `tabManagerFor(tabId:)` couldn't resolve and the report was
silently dropped. Exporting the correct workspace UUID restored the real report
path; the transition then emitted as designed. This is an environment-seeding
quirk independent of the C11-167 seam.
