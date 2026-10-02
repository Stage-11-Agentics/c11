# Review: C11-253 + C11-256 (c11Tests host CI step gating again; Codex wrapper resume test in CI), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Tickets **C11-253** and **C11-256**, one PR: https://github.com/Stage-11-Agentics/c11/pull/552, head `34a59fead009690c3605140e4222fa4828d1166d`, base = merge-base with origin/main. 22 files (+216/-639), including `notes/c11-253-host-test-triage.md`.
- Title `C11-253 Review Astra`. Actor `agent:astra-review-253`. Owner is Codex Sol.
- Validation: C11-253 ev_01M3Z1J0M5KSXSS935W0WA0CHW; C11-256 ev_01M3Z1J0PHJECAC7G7XS7ZVZWP. Owner's Atlas run 2ae3dcb7dac24210b3e6bc290a38a3eb: 1,573 tests, zero failures.
- Focus:
  1. Every one of the 44 previously failing tests has a written disposition in the triage note: fixed, deleted as obsolete or flaky (Atin's standing rule allows deleting), or quarantined on a named, commented skip list. Count them. None silently disappears.
  2. Deleted tests: confirm each tested something obsolete or was flaky, and that no deleted test was the only guard for a live 1.0 behavior (typing paths, socket focus policy, restore, browser modals). A deletion that drops real coverage is a finding.
  3. Fixed tests: the change fixes the test's own environment or assumption, not the product to suit the test, unless the product was wrong.
  4. The CI host step actually gates now: a failure makes the job red, and no `continue-on-error` or `|| true` remains on it. Workflow edits keep fork PRs safe (no secrets, no self-hosted runner) and never dispatch `release.yml`.
  5. C11-256: `tests/test_codex_wrapper_resume.py` runs in CI on the right trigger and fails the job when it fails.
  6. Prove one gate: show the host step goes red for a deliberately broken test (a scratch branch, never pushed to a PR you don't own, or local reasoning backed by the workflow file).
- When done, send VERDICT and wait.
