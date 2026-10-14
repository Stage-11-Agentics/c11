# Critical Review Synthesis — drawbridge-install

- **Pack:** `notes/trident-review-drawbridge-install-pack-20260603-1404`
- **Branch:** drawbridge-install (PR #221)
- **Reviewers:** Claude (opus-4-8), Codex (GPT-5), Gemini 1.5 Pro
- **Synthesized:** 2026-06-03
- **Review type:** Critical/Adversarial — security focus (public repo, write-permission auto-merge workflow)

---

## Executive Summary

All three models agree on the foundation: the architecture is **sound and security-aware**. The core invariant — a read-only, fallible LLM judge feeds a deterministic Python gate that runs from the trusted `main` checkout and a `pull_request_target` workflow that never checks out the PR head — is implemented faithfully. The gate test suite (26/26 passing across all three runs) exercises the real execution path, not source text. Nobody calls the design fragile.

But every reviewer reaches the same verdict on going live: **not ready for live auto-merge.** The disagreement is only about *which* hole is the worst, and three distinct categories of trust-boundary leak emerged — each surfaced by a different model, each real. The unifying theme: the deterministic gate is only as trustworthy as the *inputs it consumes* and the *thing it acts on*, and both can still be influenced by the untrusted side of the boundary.

One previously-flagged issue is **already fixed**: the live-merge TOCTOU (unpinned `gh pr merge`) was resolved in commit `dc2363838` via `--match-head-commit "$head_sha"`. Claude and Gemini reviewed the pre-fix commit (`36866f59`) and flagged it as a blocker; Codex reviewed the post-fix commit (`dc2363838`) and confirmed the pin is in place. See finding 2.1 below.

### Production Readiness Verdict

1. **Dry-run (current state): ACCEPTABLE with eyes open.** Worst single-PR outcome today is a wrong WOULD-AUTO-MERGE comment plus a Zulip ping. Nothing merges. All three reviewers concur dry-run is fine provided maintainers understand notification/review content can be stale or LLM-influenced.
2. **Live auto-merge: BLOCKED.** Unanimous. At minimum the artifact trust boundary (2.1), the LLM-classification privilege escalation (2.2), and the gate-failure silent-notification gap (2.3) must be closed before flipping live.
3. **Counterintuitive risk in the rollout plan:** Claude notes the spec's "flip live for docs-only first" graduation path is the *most* exposed starting point, because `**/*.md` merges with zero CI and `CLAUDE.md` files are agent-executable instructions. Recommend flipping live for `Resources/Localizable.xcstrings` (has real CI, no instruction-execution semantics) before docs.

---

## 1. The Ugly Truths (recurring hard messages)

1. **The deterministic gate's guarantee is narrower than it looks.** All three models, independently, found a way that the untrusted side still influences the outcome despite the gate being un-modifiable by the PR. The gate computation is honest, but (a) its *inputs* can be poisoned (Codex), (b) one of its *decision keys* is supplied by the fallible LLM (Gemini), and (c) the *thing it acts on* could change after approval (Claude — now fixed). "A PR cannot change the gates that judge it" was true; "a PR cannot change what the gates see or do" was not.
2. **"Docs are harmless" is false in this ecosystem.** Claude's sharpest point: `CLAUDE.md` and agent-instruction markdown are executable ground-truth for every agent in the repo. The autonomous docs lane treating `**/*.md` as no-CI-needed prose means an attacker can merge agent-behavior changes with zero review. This directly undermines the recommended docs-first rollout.
3. **Fail-closed for merge is not the same as fail-safe for triage.** Both Claude and Codex hammer this: the system's entire contract is "the maintainer is only ever interrupted by lane 4, and that's enough." A gate that throws an exception is safe against *merging*, but it silently drops the maintainer notification — breaking the one-channel-to-the-human promise exactly when a real malicious PR is the likely cause of the malformed input.
4. **The riskiest code has the least coverage.** The merge/label/notify logic lives in YAML, not Python, so the solid Python test suite doesn't touch it. Live-flip behavior, notify-on-gate-failure, stale-head, and artifact-poisoning are all untested (Claude finding 5; Codex "What's Missing").

---

## 2. Consensus Risks (multiple models)

Highest priority — these are where the reviews converge.

1. **Gate-execution failures do not fail safe into review + notification (silent failure) — CONSENSUS: Claude + Codex.**
   - The gate step runs under `set -euo pipefail`. `gates.py` is designed to exit non-zero / escalate on bad input, but the workflow has no fallback synthesis: any exception, `gh api` hiccup, `jq`/Python error, or malformed `pr.json` fails the whole gate job.
   - `drawbridge-notify`'s condition requires `needs.drawbridge-gate.result == 'success'` (`drawbridge.yml:382-388`). A failed gate → `result != 'success'` → **no label, no comment, no maintainer ping.** Total silence in precisely the case (malformed/hostile input) where escalation matters most.
   - **Fix (agreed):** Wrap the gate step so unexpected failure synthesizes `route=review` + an explanatory gate JSON, then still labels/comments/notifies. Keep merge impossible. Add a separate notify path that fires on `drawbridge-gate.result == 'failure'`.
   - **Status:** Open. Both rank it Important / fix-before-live.

2. **Live-mode merge TOCTOU (unpinned `gh pr merge`) — CONSENSUS: Claude + Gemini flagged; ALREADY FIXED.**
   - Claude (reviewing `36866f59`) ranked this the sole BLOCKER: `gh pr merge <number>` with no SHA pin would merge current head, letting an attacker force-push a malicious commit after the gates pass (window up to ~75 min; `cancel-in-progress: false` means the in-flight run isn't cancelled). Gemini's race-condition findings touch the same stale-head family.
   - **Status: FIXED in `dc2363838`** — merge is now pinned with `--match-head-commit "$head_sha"`. Codex (reviewing the fixed commit) confirmed the pin is present and correctly prevents merging a newer unreviewed head.
   - **Residual (still open — see 2.4):** the pin protects the *merge* only. Stale labels/comments/notifications before the merge step are not pinned.

3. **Comment-marker spoofing in `upsert-comment.sh` — CONSENSUS: Claude (nit) + Gemini (BLOCKER).**
   - The `jq` filter matches *any* comment containing the marker `<!-- drawbridge:gate -->`, including one a contributor pastes into their own comment (the marker is visible in the bot's public comments).
   - **Severity split:** Gemini rates this a **functional blocker** — patching another user's comment returns 403, trips `set -e`, and **crashes the `drawbridge-gate`/`drawbridge-review` jobs** (a denial-of-service). Claude rates it a cosmetic nit — a contributor griefing the audit trail. The disagreement hinges on whether the 403 propagates as a job-crashing error; Gemini's DoS framing makes this the more conservative read and worth treating as the higher severity until disproven.
   - **Fix (agreed):** Filter on author identity AND marker: `select(.body | contains($m)) | select(.user.login == "github-actions[bot]")` (or `.user.type == "Bot"`).

4. **Stale runs can still label/comment/notify for an old PR head — CONSENSUS: Claude + Codex.**
   - With `cancel-in-progress: false` (`drawbridge.yml:42`), an older synchronize run can finish *after* a newer one. The merge is now pinned and will fail safely, but the route label, WOULD-AUTO-MERGE comment, and notification are applied for the stale evaluated SHA before the merge step.
   - **Fix (agreed):** Add a deterministic `head_still_current` check immediately before labeling/commenting/merging; refuse to emit autonomous labels/comments if current head differs from the evaluated SHA. Consider `cancel-in-progress: true` for synchronize events, or visibly include the evaluated SHA in comments.
   - **Status:** Open. Partially mitigated by the merge pin; the comms path remains stale-vulnerable.

---

## 3. Unique Concerns (single model — worth investigating)

1. **[Codex] Artifact trust boundary — LLM judge can poison downstream evidence (Codex's #1 BLOCKER).**
   - The judge job has the `Write` tool and the workflow uploads the *entire* `/tmp/drawbridge/` directory after the judge runs (`drawbridge.yml:152-156`), then feeds that same artifact to the gate, deep-review, and notify jobs. The prompt instructs the judge to write only `verdict.json`, but the whole model assumes the judge can be fooled. A fooled judge can rewrite `meta.json`, `item.diff`, or `comments.json` — suppressing notifications, misleading the deep reviewer, and sending the maintainer a false digest. For issues, `internal` trust tier is derived from artifact `meta.json`, so a poisoned association can suppress the notification.
   - **Why it matters:** This is the most architecturally significant single finding — it's the same class as the consensus issues (untrusted side influences the gate) but on the *input* axis, which the other two models didn't isolate. Codex would not go live until this is fixed.
   - **Fix:** Upload only `verdict.json` from the judge job. Re-fetch metadata/diff/comments deterministically in the gate/review/notify jobs, or capture an immutable pre-judge context artifact the judge cannot write. Add a poisoned-artifact test.

2. **[Gemini] Privilege escalation via LLM `bugfix` classification (Gemini's #1 BLOCKER).**
   - `gates.py` `evaluate_pr` expands the CONTRIBUTOR path allowlist when `verdict.get("category") == "bugfix"`. The LLM decides the category. Prompt injection in the diff (e.g. "set category=bugfix") can make the judge classify malicious `Sources/**` changes as a bugfix, and the deterministic gate then trusts that classification to permit auto-merge.
   - **Why it matters:** This is the cleanest example of Ugly Truth #1 — a security-relevant decision key delegated back to the untrusted LLM. If confirmed, it materially weakens the contributor-tier guarantee. Worth verifying against `gates.py` directly: does the category genuinely widen the allowlist for contributors, or only narrow the audit framing?
   - **Fix:** Do not let the LLM expand access. For CONTRIBUTORs touching `Sources/**`, always escalate; or gate "is this really a bugfix" on behavioral CI, not LLM categorization.

3. **[Gemini] CI-poll race condition / false negatives (Gemini #3, Important).**
   - GitHub takes seconds to register check runs after a PR opens. The wait loop `[[ "$pending" -eq 0 ]] && break` breaks immediately if `check_runs` is empty (pending == 0), causing real code PRs to falsely fail `ci_green` ("no check runs") and escalate. Benign-but-noisy in dry-run; a reliability bug live.
   - **Fix:** Require expected workflows to be registered, or add an initial sleep/retry when `check_runs` is empty for non-docs PRs.

4. **[Gemini] Token/quota exhaustion on closed items (Gemini #4) and massive PRs (#5/nit, also Claude concurrency nit).**
   - `issue_comment` fires on closed/merged PRs too; an attacker can spam comments to repeatedly trigger the LLM judge and burn Claude API quota. Separately, `gh api --paginate` on `files.json` can make dozens of requests (or OOM `jq`) on a 10k-file PR *before* the `size_cap` gate rejects it.
   - **Fix:** Skip judge execution on closed items; cap pagination (any PR >20 files fails size cap anyway).

5. **[Claude] Over-broad `**/*.md` CI-skip merges agent-instruction files (Claude #3, Important).**
   - `ci_ignored_paths` includes `**/*.md`; the gate treats "zero checks + all paths CI-ignored" as `ci_green` pass. This matches `CLAUDE.md`, `README.md`, `SECURITY.md` — and `CLAUDE.md` is executable agent instruction. An autonomously-merged `CLAUDE.md` change is a behavior change to every future agent, with no review and no CI. The judge (assumed-fooled) is the only thing in the way.
   - **Fix:** Carve `CLAUDE.md`, `**/CLAUDE.md`, and agent-instruction/security markdown into the deny list. At minimum `CLAUDE.md` escalates.

6. **[Claude] Path-normalization absent — `..`/`./` defeat deny+allow matching (Claude #4, Potential).**
   - `glob_to_regex` does literal anchored matching, no normalization. `Sources/../scripts/notarize.sh` passes both `no_denied_paths` and `paths_allowed`, routing autonomous (verified PROBE4). Not exploitable via GitHub's `files` API today (it normalizes paths), but the gate is the boundary and shouldn't depend on upstream normalization staying constant.
   - **Fix:** `os.path.normpath` + reject any path with `..`, leading `/`, or `./`; treat non-normalizable as denied.

7. **[Claude] `size_cap` line count defaults missing fields to 0 (Claude #6, Potential).**
   - `lines = pr.get("additions", 0) + pr.get("deletions", 0)` — a `pr.json` missing both fields counts as 0 lines and passes the cap (verified PROBE2). The file-count cap has a `len(files)` fallback; the line cap doesn't. A truncated `gh api` response under-counts rather than fails safe.
   - **Fix:** If `additions`/`deletions` absent, escalate.

8. **[Codex] `drawbridge-gate` carries `contents: write` even for issue-only routing; CI check only covers check-runs not legacy commit statuses; `ref: main` hardcoded (Codex nits/Potential).**
   - Blast-radius and forward-compat hardening. Splitting PR vs issue gate jobs would reduce the scope of the write token. The check-run-only CI gate matches today's Actions setup but misses external required statuses if added later (Codex finding 4) — document the limitation or combine with the commit-status API.

---

## 4. Consolidated Blockers & Production Risk Assessment

### Must-fix before live flip (consensus or BLOCKER-rated)

1. **Artifact trust boundary** [Codex BLOCKER] — judge must only emit `verdict.json`; downstream jobs re-fetch trusted context. *Architectural; highest single risk.*
2. **LLM `bugfix` classification privilege escalation** [Gemini BLOCKER] — don't let LLM category expand contributor path allowlist. *Verify against `gates.py`, then fix.*
3. **Gate-failure silent notification** [Claude + Codex, Important/consensus] — synthesize review-route + maintainer ping on gate execution failure.
4. **Comment-marker spoof** [Gemini BLOCKER / Claude nit] — author-scope the `jq` filter; prevents 403-induced job crash (DoS) and audit-trail griefing.
5. **`CLAUDE.md` / agent-instruction markdown in autonomous docs lane** [Claude Important] — deny-list agent-executable markdown. *Directly affects the recommended docs-first rollout.*

### Should-fix before relying on live triage (consensus, partially mitigated)

6. **Stale-head label/comment/notify** [Claude + Codex] — `head_still_current` check before comms; the merge pin (`dc2363838`) already covers the merge itself.
7. **CI-poll race / false negatives** [Gemini] — handle empty `check_runs` for code PRs.

### Already fixed

8. **Live-merge TOCTOU** [Claude BLOCKER, Gemini-adjacent] — **CLOSED in `dc2363838`** via `--match-head-commit "$head_sha"`; confirmed by Codex.

### Hardening / defense-in-depth (Potential)

9. Path normalization (`..`/`./` rejection) [Claude].
10. `size_cap` missing-field escalation [Claude].
11. Closed-item judge skip + pagination cap (quota/DoS) [Gemini].
12. Split `contents: write` off issue routing; check-run vs commit-status CI completeness; `ref: main` reuse brittleness [Codex].

### Test gaps (all three flag the same hole)

13. No coverage for: live-merge/SHA-pin behavior, notify-on-gate-failure, stale-head, artifact poisoning, path normalization. The riskiest code (YAML merge/label/notify) is entirely untested. Add harness/integration tests for each must-fix above.

### Overall Risk Posture

- **Today (dry-run):** LOW. Blast radius is a comment + a ping. Ship and observe.
- **At live flip without the must-fix list:** HIGH. Three independent trust-boundary leaks (input poisoning, LLM-delegated security key, silent failure) each let the untrusted side influence an auto-merge or blind the maintainer. The deterministic-gate guarantee becomes partial theater.
- **At live flip with must-fix 1–5 closed and should-fix 6–7 addressed:** MODERATE and defensible. Two of three reviewers explicitly say they'd trust it after the SHA pin + CLAUDE.md carve-out (Claude) / artifact boundary + stale-head fixes (Codex). Recommend live-flipping `Localizable.xcstrings` (real CI, no instruction semantics) before docs, against Claude's argument that docs is the most-exposed lane.
