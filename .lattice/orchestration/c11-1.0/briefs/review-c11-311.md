# Review: C11-311 (tier-2 bug sweep, P2), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-311** (P2: ships only if individually releasable and off the critical path). PR https://github.com/Stage-11-Agentics/c11/pull/538, head `36cb0a8cdccac3bd4936d917bb785c90a5d7757b`, base = merge-base with origin/main.
- Title `C11-311 Review Astra`. Actor `agent:astra-review-311`. Owner was Codex Luna.
- Plan: the ticket's plan file (optional slices; B075 deferred unless assigned). Validation `ev_01M3YPS1SWTKM7Q1NV9E211K13`, status `ev_01M3YPS5T7Z03A9CR7N7YWKJ9S`, branch `ev_01M3YHJWPH492E9V6W90Z9P8EF`.
- Focus: each fixed bug row names its ledger ID and an incident/fixture and has a behavioral test; no slice touches typing hot paths, socket threading or the journal/attention seams without saying so; no unrelated refactors; every fix is independently correct (a P2 must never add risk to the release); deferred rows are listed honestly, never counted fixed; strings localized.
- When done, send VERDICT and wait.
