# C11-167 — Wire TEL↔EVT derived-liveness event emission

## Verification of the "one-line" claim (prompt asked me to check)

The run report / ticket calls this a one-line seam completion. **That is inaccurate.** Verified against merged #318 (EVT) and #320 (TEL):

- Emit stub (EventEmitter.swift): `func emitDerivedLiveness(workspace: UUID, surface: UUID, state: String)` — needs a workspace UUID and a single `state` string.
- Call site (SurfaceLivenessDeriver.emitLivenessTransition): signature is `(from: String?, to: String?, surfaceId: UUID)` — it has **no `workspaceId`** in scope and carries `from`/`to`, not a single `state`.
- The doc comment's suggested `EventEmitter.emitDerivedLiveness(surfaceId:from:to:)` does not match the merged stub at all.

So the wiring requires threading `workspaceId` into `emitLivenessTransition` from both callers, then mapping `to`→`state`.

## Change

1. Add `workspaceId: UUID` param to `emitLivenessTransition`.
2. Pass `workspaceId` at both call sites (`onShellActivityChanged`, `reconcile` — both already have it in scope).
3. Inside the seam, after the DEBUG dlog, emit only on a real destination state:
   ```swift
   if let to {
       EventEmitter.shared.emitDerivedLiveness(workspace: workspaceId, surface: surfaceId, state: to)
   }
   ```
   `to == nil` (cleared/unknown) is not a working/idle derived state, so no event — matches the stub contract ("working"/"idle" only) and avoids phantom events.

Off-main-safe: `emit` locks internally and is non-blocking (EVT-3); both callers already run off-main.

## Acceptance

SPEC EVT-2 satisfied: a derived working↔idle transition produces a `liveness.derived` event observable via `c11 events tail --filter type=liveness.derived`.

## Validation

Tagged build (`./scripts/reload.sh --tag c11-167`) + recorded demonstration: script a silence→derived-idle transition, capture tail output, attach to ticket.

## Skill

Update c11 events reference if the stub/seam was documented as pending; run scripts/sync-installed-skills.sh if any skill touched.
