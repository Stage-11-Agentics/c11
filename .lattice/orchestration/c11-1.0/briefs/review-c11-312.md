# Review: C11-312 (artifact-only signing: signed, notarized test builds from GitHub Actions), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-312**. PR https://github.com/Stage-11-Agentics/c11/pull/503, head `c5475780903dd0bd4682a824e6db9edd82a283eb`, base = merge-base with origin/main.
- Title `C11-312 Review Astra`. Actor `agent:astra-review-312`. Owner was Codex Sol.
- Plan `.lattice/plans/task_01M3XAPVSTQ5H68S9K7J8N6NMY.md`; validation `ev_01M3XK9WN8T2F809SF3E264WFS` (should include a real signing run URL, artifact names and SHA-256s).
- This is security- and release-critical. Blocking if any of these fail: (1) the workflow can never publish: no release, tag, appcast, Homebrew, `latest` slot, or Sparkle feed change on any trigger path, including `workflow_dispatch` inputs and `push`; (2) secrets are used only in the signing job, never echoed, never written to artifacts or caches, keychain material is ephemeral and cleaned up in an `always()` step; (3) triggers cannot be fired by untrusted forks or PRs from outside (no `pull_request_target` with secrets, no secrets on fork PRs); (4) the recorded hashes identify exactly the uploaded bytes and the source SHA they were built from; (5) `release.yml` behavior is unchanged; (6) the run actually notarized and stapled (or the evidence says plainly what it did not prove). Option A ruling: no credentials on Atlas.
- When done, send VERDICT and wait.
