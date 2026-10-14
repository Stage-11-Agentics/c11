## Critical Code Review
- **Date:** 2026-06-03T18:06:57Z
- **Model:** Claude — claude-opus-4-8[1m]
- **Branch:** drawbridge-install
- **Latest Commit:** 36866f59617d9503798c7729b1f00bc7c610cf21
- **Story:** drawbridge-install (PR #221)
- **Review Type:** Critical/Adversarial — security focus (public repo, write-permission workflow)
---

## The Ugly Truth

This is genuinely good security engineering. The author clearly internalized the spec's threat model: untrusted content feeds an LLM that can be fooled, so the LLM is read-only and powerless, and a deterministic Python gate that a PR cannot modify (it runs from the trusted `main` checkout) makes the actual decision. Every checkout in the workflow is `ref: main` — I checked all five. No `pull_request_target` ever touches the PR head. The gate logic fails safe to escalation on every error path I could find. The test suite exercises the real `main()` execution path against fixtures rather than asserting on source text, which is exactly right per repo policy. 26/26 pass locally.

So I'm not going to pretend the foundation is fragile. It isn't. The autonomous lane is also still in **dry-run**, which means the worst single-PR outcome today is a wrong WOULD-AUTO-MERGE comment plus a Zulip ping — not an actual merge. That dramatically lowers the stakes of everything below.

But this PR is the *plumbing for a system that will be flipped live*, and the review bar has to be "would I trust this with `contents: write` and `gh pr merge` against a public repo when someone changes one word in the policy file." Against that bar, there are real holes. The most serious is a time-of-check/time-of-use gap in live mode that lets a contributor merge code CI never validated. There's also a notify-job that will silently never fire in the most important failure case, and an over-broad CI-skip rule that lets arbitrary markdown (including agent-instruction files) merge with zero verification.

## What Will Break

### 1. TOCTOU: live-mode `gh pr merge` merges a different commit than the gates approved (BLOCKER for live mode)

This is the one that would page me. In `drawbridge.yml` the gate job:
1. Fetches `pr.json`, reads `head_sha`, waits for CI to go green **on that SHA**.
2. Re-runs `gates.py` against the same `pr.json`/`files.json`/`checks.json`.
3. In live mode, runs `gh pr merge "$ITEM_NUMBER" --squash` — **by PR number, with no `--sha` / `--match-head-commit` pin** (`drawbridge.yml:302`).

Between the green-CI confirmation and the merge call there is a window of up to ~75 minutes (job timeout) plus the 45-minute CI poll. An attacker opens a clean docs/bugfix PR, lets it go green, and force-pushes a malicious commit to the same branch the instant the gates pass. `gh pr merge <number>` merges *current* head, not the SHA the gates blessed. The `synchronize` event would also fire a *new* drawbridge run, but `concurrency.cancel-in-progress: false` (`drawbridge.yml:42`) means the in-flight run is **not** cancelled — it proceeds to merge the attacker's new head. The `--files-json` and CI the gates validated describe a commit that is no longer what gets merged.

**Fix:** pin the merge to the exact approved SHA. `gh pr merge "$ITEM_NUMBER" --squash --match-head-commit "$head_sha"` (and surface `head_sha` from the gate step as an output / re-read it and compare immediately before merging). Also reconsider `cancel-in-progress: false` for the merge path, or have the act step re-verify head SHA equality as its first action. Without this, the deterministic-gate guarantee ("a PR cannot change the gates that judge it") is real for the gate computation but not for the *act* — the thing being acted on can change after approval. ✅ Confirmed by reading `drawbridge.yml:210-303`; the merge command carries no SHA pin.

### 2. `drawbridge-notify` never fires when the gate job fails — i.e. exactly when you most need to know (IMPORTANT)

`drawbridge-notify`'s `if:` is `always() && needs.drawbridge-gate.result == 'success' && (...)` (`drawbridge.yml:380-384`). `gates.py` is designed to *exit non-zero / fail safe to escalation* on bad input, and the doc comment says "any error … fails safe to the review lane (non-zero exit)." But the notify job is gated on `drawbridge-gate.result == 'success'`. So if the gate step throws (malformed `pr.json`, a `gh api` failure, the policy parse raising `ValueError`, an `ap.error` exit-2), the gate job fails — and the maintainer gets **no notification at all**. The "fail safe to escalation" promise is only kept for the *route value*, not for the *human in the loop*. A flaky `gh api` during a real malicious PR means total silence. For a system whose entire contract is "the maintainer is only ever interrupted by lane 4, and that's enough to decide," a silent failure mode on the gate is a serious gap. ✅ Confirmed: `set -euo pipefail` + `gh api` without `|| true` on `drawbridge.yml:196-197` will fail the step, and `gates.py` `ap.error`/exceptions exit non-zero, all of which make `drawbridge-gate.result != 'success'`.

**Fix:** add a separate notify path (or relax the condition) that fires specifically when `drawbridge-gate.result == 'failure'`, with a "Drawbridge gate errored — manual triage needed" message. Don't let an exception eat the only signal.

### 3. Over-broad CI-skip: any markdown at any path merges with zero CI, including agent-instruction files (IMPORTANT)

`ci_ignored_paths` includes `**/*.md` (`TRIAGE_POLICY.md:855`), and `gates.py` treats "zero check runs + all paths CI-ignored" as a passing `ci_green` gate (`gates.py:184-196`). I verified empirically: a `MEMBER`/`CONTRIBUTOR` PR touching a single root-level `EVIL.md`, judged `bugfix` or `docs`, with **zero check runs**, routes `autonomous`. That's intended for docs — but `**/*.md` also matches `CLAUDE.md`, `*/CLAUDE.md`, `README.md`, `SECURITY.md`, and `scripts/drawbridge/prompts/*.md` is only saved from this by being under `scripts/**` (deny list). Two concrete problems:

- **`CLAUDE.md` files are executable instructions in this ecosystem** — every agent in this repo loads them as ground-truth behavior. An autonomously-merged change to a `CLAUDE.md` is effectively a code change to every future agent's behavior, merged with no review and no CI. It is *not* the harmless prose the docs category assumes.
- The judge is the only thing standing between "innocuous docs" and "weaponized agent instructions / social-engineering README," and the judge is explicitly assumed-fooled by design. The deterministic gate adds nothing here because markdown legitimately has no CI to check.

**Fix:** carve `CLAUDE.md`, `**/CLAUDE.md`, and other agent-instruction/security-relevant markdown into the deny list (or out of the autonomous docs category). At minimum `CLAUDE.md` should escalate. The contributor tier merging arbitrary markdown is the highest-residual-risk autonomous path in the whole design once live.

## What's Missing

### 4. Path-normalization gate is absent; `..` segments defeat the deny list (POTENTIAL — currently theoretical on GitHub)

`glob_to_regex` does literal anchored matching with no path normalization. I verified that `Sources/../scripts/notarize.sh` passes `no_denied_paths` (it doesn't textually match `scripts/**`) **and** passes `paths_allowed` (it textually matches `Sources/**`), routing `autonomous`. Same class: a leading `./` prefix (`./.github/...`) dodges the `.github/**` deny pattern's anchor. GitHub's `files` API normalizes paths and never returns `..` or `./` segments, so this is not exploitable through the real event path *today* — but the gate is the security boundary and should not depend on an upstream API's normalization behavior staying constant. Defense in depth: normalize every path (`os.path.normpath`, reject any path containing `..` or starting with `/` or `./`) before matching, and treat a non-normalizable path as denied. Cheap, and it closes the whole class. ✅ Confirmed empirically (PROBE4).

### 5. Tests don't cover the live-mode merge path, the notify-on-gate-failure path, or path-normalization

The suite is solid on routing but every test is dry-run-implicit (mode comes from the policy file) and PR-data-shaped. There is no test that the act step pins a SHA, no test of the notify condition matrix (especially gate-failure → notify), and no adversarial path-normalization test. The conformance checklist in the spec is partially covered by tests (forbidden path, first-timer, injection-shaped verdict, size cap — all present and good) but the live-flip behavior is entirely untested because it lives in YAML, not Python. That's understandable but means the riskiest code (the merge) has the least coverage.

### 6. `size_cap` line count silently trusts `additions`/`deletions` and defaults them to 0 (POTENTIAL)

`lines = pr.get("additions", 0) + pr.get("deletions", 0)` (`gates.py:157`). I verified that a `pr.json` missing both fields yields `0 lines` and passes the line cap (PROBE2). The file-count cap has a sane fallback to `len(files)`, but the line cap has no such cross-check. GitHub always populates `additions`/`deletions`, so again not exploitable through the real path — but a malformed/partial `pr.json` (e.g. a `gh api` hiccup returning a truncated object) would under-count rather than fail safe. Prefer: if `additions`/`deletions` are absent, fail the gate (escalate) rather than treat as zero.

## The Nits

- **`fetch-item.sh` diff truncation off-by-context:** `head -c 300000` can cut a multibyte UTF-8 char mid-sequence; the judge prompt handles arbitrary text so it's cosmetic, but `iconv -c` or a char-boundary trim would be cleaner. (`fetch-item.sh:20`)
- **`notify.sh` truncates to 9000 chars with `head -c`** (`notify.sh:1245`) — same multibyte-cut nit, and it can sever a markdown link or code fence mid-token, producing slightly broken Zulip rendering. Low stakes.
- **`upsert-comment.sh` uses `head -1` on a marker match** (`upsert-comment.sh:1429`) — if a contributor pastes the literal marker `<!-- drawbridge:gate -->` into their own comment (it's visible in the bot's posted comments), they could get the bot to PATCH *their* comment instead of its own, or shift which comment is updated. Cosmetic, not a privilege issue (the bot only edits comments, and only on that issue), but a contributor could grief the audit trail. Consider matching on `user.type == "Bot"` AND marker.
- **`concurrency` group keys on item number but `cancel-in-progress: false`** means rapid comment spam on one issue serially queues full pipeline runs (each up to 75 min) rather than coalescing. A hostile actor commenting in a loop could pile up runners. The judge `if:` skips maintainer/bot comments but not arbitrary external commenters. Consider rate-limiting or `cancel-in-progress: true` for the non-merge events.
- **`issue_comment` retriggers the full judge→gate→(merge) pipeline.** A contributor whose clean PR previously escalated can post a comment to force a *fresh* autonomous evaluation at any time. Combined with finding #1 (force-push) and #3 (markdown), the comment vector is a convenient attacker-controlled "re-roll the dice" trigger once live. Worth a deliberate decision about whether comments should ever be able to *advance* a PR to autonomous merge, vs. only re-triage routing.
- **`gates.py` `evaluate_pr` reads `pr.get("author_association")` but the workflow separately derives `internal` from the same field via shell `case`** — two sources of truth for trust tier (Python gate + YAML `case` on `drawbridge.yml:248-251`). They agree today, but a future edit to one and not the other is a latent inconsistency. Centralize.

## Numbered Findings

**Blockers (will cause an incident once live):**
1. ✅ Live-mode `gh pr merge` has no SHA pin → TOCTOU force-push merges unvalidated code (`drawbridge.yml:302`; `cancel-in-progress: false` at `:42`). Must pin `--match-head-commit "$head_sha"` and/or re-verify head equality before merge.

**Important (security/UX correctness, fix before live):**
2. ✅ `drawbridge-notify` skipped when the gate job fails (`drawbridge.yml:382`) → silent failure exactly when escalation matters. Add a gate-failure notify path.
3. ✅ `**/*.md` CI-skip + autonomous docs lets arbitrary markdown — including `CLAUDE.md` agent instructions — merge with zero CI/review (`TRIAGE_POLICY.md:855`, `gates.py:184-196`). Deny `CLAUDE.md`/agent-instruction markdown from the autonomous lane.

**Potential (hardening / latent / lower priority):**
4. ⬇️ No path normalization; `..`/`./` defeat deny+allow matching (`gates.py:46-73`). Theoretical on GitHub today; close the class with `normpath` + reject `..`.
5. Live-merge / notify-failure / normalization paths untested.
6. ⬇️ `size_cap` line count defaults missing fields to 0 instead of failing safe (`gates.py:157`).
7. Nits above (truncation multibyte cuts, marker-spoof in upsert, concurrency pile-up, comment re-roll vector, dual trust-tier source of truth).

## Closing

Would I mass-deploy this to 100k users? In its **current dry-run state — yes, with the Important items tracked.** The blast radius today is a comment and a ping; nothing merges. The architecture is sound and the read-only-judge / deterministic-gate split is implemented faithfully to the spec's MUSTs (I verified invariants 1–7: read-only judge ✅, deterministic action ✅, gates cover CI/size/allowlist/deny/tier ✅, no PR-head checkout ✅, first-timers blocked ✅ and tested, dry-run default ✅, secrets in forge storage ✅).

**Before the live flip, items 1, 2, and 3 are mandatory.** #1 because an unpinned `gh pr merge` turns the entire deterministic-gate guarantee into theater the moment an attacker force-pushes; #2 because a silent gate failure breaks the one-channel-to-the-maintainer contract; #3 because "docs are harmless" is false in a repo where markdown is agent-executable instruction. The graduation protocol's "flip live for docs-only first" is, ironically, the *most* exposed starting point given #3 — I'd flip live for `Resources/Localizable.xcstrings` (localization) before docs, since that path has real CI and no instruction-execution semantics.

Solid work. Fix the merge SHA pin and the CLAUDE.md carve-out and this is a system I'd actually trust to lower the drawbridge.
