## Critical Code Review
- **Date:** 2026-06-03T18:11:40Z
- **Model:** Codex (GPT-5)
- **Branch:** drawbridge-install
- **Latest Commit:** dc2363838c81e31717838e7c90eac19ec4243c72
- **Linear Story:** drawbridge-install
- **Review Type:** Critical/Adversarial
---

## The Ugly Truth

The core shape is serious and mostly security-aware: `pull_request_target` never checks out the PR head, the merge is now pinned with `--match-head-commit`, and the gate tests exercise the important deterministic cases. But there is still a trust-boundary bug in the workflow: the untrusted-content LLM job is allowed to write into the same `/tmp/drawbridge` directory that later jobs treat as the source of truth for metadata, diff, comments, and review context. The design says the judge can be fooled and must be boxed in; this implementation still lets a fooled judge poison downstream evidence.

I would not turn this on in live mode until that artifact boundary is fixed. Dry-run is acceptable only if maintainers understand that some notification/review content can be stale or LLM-mutated.

Validation run:
- `python3 tests/drawbridge/test_gates.py`: PASS, 26/26.
- `bash -n scripts/drawbridge/*.sh`: PASS.
- Ruby YAML parse for `.github/workflows/drawbridge.yml` and `.github/workflows/drawbridge-sweep.yml`: PASS.
- `npm run type-check`, `npm run lint`, `npm test`: not meaningful for this branch; the root `package.json` has no scripts, and this PR touches no web TypeScript.
- Fetch/pull was intentionally not run because the wrapper prompt forbids actions beyond writing this review file.

## What Will Break

1. When a malicious PR body/diff convinces the judge to write more than `verdict.json`, the judge can alter `/tmp/drawbridge/meta.json`, `item.diff`, or `comments.json`. The gate/review/notify jobs then download that whole directory and trust it. That can suppress notifications for issues, mislead the deep reviewer, and send the maintainer a false digest.
2. When a contributor pushes a new PR head while an older Drawbridge run is waiting on CI, the older run can still apply `drawbridge:autonomous` and post/update a WOULD AUTO-MERGE comment for the stale SHA. The live merge itself is pinned and will fail, but the label/comment/notification path is still stale.
3. When gate code or GitHub API input fails unexpectedly, the workflow usually fails closed for merge, but not fail-safe for triage. There is no synthesized review route/notification for gate execution failures, so the maintainer can lose the lane-4 interrupt that the spec relies on.

## What's Missing

- A hard artifact boundary test: prove the judge can only influence `verdict.json`, and that review/notify fetch trusted context fresh or consume an immutable pre-judge artifact.
- A stale-head workflow test or harness: prove a run cannot label/comment/notify as autonomous unless the PR head still equals the evaluated SHA.
- A failure-mode test for gate execution errors: prove malformed policy/API/check data still produces a review route plus maintainer notification, not a silent red workflow.

## The Nits

- `drawbridge-gate` carries `contents: write` even for issue-only routing. Splitting PR and issue gate jobs would reduce blast radius.
- CI validation checks only GitHub check runs, not legacy commit statuses. That matches this repo's current Actions CI, but it is not a complete "CI fully green" implementation if external required statuses appear later.
- The workflow hardcodes `ref: main`; acceptable for this repo today, but it makes default-branch or release-branch reuse brittle.

## Findings

1. **Blocker - LLM judge can poison downstream trusted artifacts**  
   ✅ Confirmed - `.github/workflows/drawbridge.yml:117-126` gives the judge the `Write` tool, `.github/workflows/drawbridge.yml:152-156` uploads the entire `/tmp/drawbridge/` directory after the judge runs, and `.github/workflows/drawbridge.yml:338-342` feeds that same artifact to the deep-review job. The prompt tells the judge to write only `/tmp/drawbridge/verdict.json`, but the whole security model assumes untrusted content can fool the judge. If it writes a sanitized `item.diff` or fake `comments.json`, the downstream deep review is reviewing judge-mutated evidence. For issues, `.github/workflows/drawbridge.yml:236-241` also derives `internal` from artifact `meta.json`; a poisoned association can suppress notification through `.github/workflows/drawbridge.yml:384-388`.  
   Fix: upload only `verdict.json` from the judge job. Re-fetch item metadata/diff/comments deterministically in gate/review/notify jobs, or capture immutable pre-judge context in a separate artifact the judge cannot write to. Add a test/harness that simulates a poisoned artifact and proves it cannot affect route, review context, or notification suppression.

2. **Important - Stale runs can still label/comment/notify for an old PR head**  
   ✅ Confirmed - the PR JSON and `head_sha` are fetched once at `.github/workflows/drawbridge.yml:195-210`, checks are polled for that SHA at `.github/workflows/drawbridge.yml:211-224`, then the route label is applied at `.github/workflows/drawbridge.yml:254-269` and the WOULD AUTO-MERGE comment is posted at `.github/workflows/drawbridge.yml:271-299`. The live merge is pinned at `.github/workflows/drawbridge.yml:301-306`, which prevents merging a newer unreviewed head, but it does not prevent stale labels/comments before that point. With `.github/workflows/drawbridge.yml:40-42` setting `cancel-in-progress: false`, older synchronize runs can finish after newer ones.  
   Fix: add a final deterministic `head_still_current` check immediately before labeling/commenting/merging, and do not emit autonomous labels/comments if the current PR head differs from the evaluated SHA. Consider cancelling in-progress runs for PR synchronize events, or include the evaluated SHA visibly in comments and refuse to upsert if stale.

3. **Important - Gate execution failures do not fail safe into review + notification**  
   ✅ Confirmed - `scripts/drawbridge/gates.py:18-19` says bad input should be treated as escalation, but the workflow step at `.github/workflows/drawbridge.yml:185-252` runs under `set -euo pipefail` with no fallback synthesis if Python, `gh`, or `jq` exits nonzero. Downstream notification then requires `needs.drawbridge-gate.result == 'success'` at `.github/workflows/drawbridge.yml:384-388`, so a gate infrastructure failure becomes a red workflow with no Drawbridge label/comment/maintainer ping. This is fail-closed for merge, but not fail-safe for the product's triage contract.  
   Fix: wrap the gate step so unexpected failures write a `route=review`, `mode=<policy>`, and a gate JSON explaining the infrastructure failure, then still label/comment/notify the maintainer. Keep merge impossible, but preserve lane 4.

4. **Potential - CI green ignores commit statuses outside check-runs**  
   ❓ Likely but environment-dependent - `.github/workflows/drawbridge.yml:213-223` fetches only `commits/{sha}/check-runs`, and `scripts/drawbridge/gates.py:172-201` evaluates only those check runs. That covers GitHub Actions for this repo today, but it will not catch legacy commit statuses from external CI providers or required status contexts if they are added later.  
   Fix: either document that Drawbridge only gates on Actions check-runs, or combine check-runs with the commit status/combined-status API and fail unless both surfaces are green or intentionally ignored.

## Closing

Not ready for live production automation. The merge SHA pin is the right move, and the deterministic gate tests are a solid base, but the artifact trust boundary is wrong for a public-repo workflow designed around prompt-injection resistance. I would dry-run this with eyes open; I would not mass deploy live auto-merge until findings 1 and 2 are fixed, and I would fix finding 3 before relying on Drawbridge as the maintainer's primary interrupt path.
