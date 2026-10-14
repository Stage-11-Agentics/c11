# Action-Ready Synthesis: drawbridge-install

## Verdict
fix-then-merge

The architecture is sound and the security MUSTs are honored: every checkout pins `ref: main`, the judge is read-only, gates are deterministic Python run from trusted `main`, the merge is now SHA-pinned, and the whole pipeline ships in dry-run (worst single-PR outcome today is a wrong comment + a Zulip ping). Five of nine reviewers (both standard-claude and critical-codex) would merge as-is for dry-run; standard-codex says "do not merge as-is if the goal is a conforming install" on the CI-race; critical-claude/critical-gemini gate the **live flip** on a small set of items.

The reviewers disagree on whether anything blocks the *dry-run merge*. Biasing toward the more cautious read: there are two findings worth landing in this PR (the CI-poll race, which degrades the core autonomous lane even in dry-run, and the fetch-item.sh interpolation, a cheap script-injection close-out) plus several important items that are explicit prerequisites before flipping `mode: live`. None of the live-flip prerequisites need to block the dry-run merge, but they should land in the same PR because they are small and the diff is fresh.

Note on already-landed fix: commit dc2363838 SHA-pins live auto-merge via `gh pr merge --squash --match-head-commit "$(jq -r '.head.sha' /tmp/gate/pr.json)"` (confirmed at `drawbridge.yml:305-306` in the working tree) and adds the GITHUB_TOKEN no-cascade note to TRIAGE_POLICY.md. The TOCTOU/SHA-pin finding (critical-claude #1) and the no-cascade behavior are therefore **already fixed and excluded** from the apply list below.

## Apply by default

### Blockers (merge-blocking)

None that block the dry-run merge. (The live-flip prerequisites are tracked under Important; see I1–I3.)

### Important (land in same PR)

- **I1: CI-poll race exits the wait loop before check runs exist, losing the autonomous bugfix lane**
  - Location: `.github/workflows/drawbridge.yml:213-220` (the `for i in $(seq 1 45)` poll loop; the break is at `:217`)
  - Problem: The loop computes only `pending` (non-drawbridge checks with `status != "completed"`) and breaks the instant `pending == 0`. GitHub commonly has not yet *created* any check runs when Drawbridge fires, so `pending` is `0` on the first poll, the loop exits immediately, and the final `gates.py` pass sees zero runs and fails `ci_green` for non-CI-ignored paths ("no check runs and paths are not CI-ignored" — `gates.py:978-990`). The intended autonomous bugfix lane is lost to scheduler timing. Fail-safe (escalates, never merges) but it makes the lane unreliable even in dry-run.
  - Fix: In the wait loop, also count the *total* non-drawbridge check runs. For non-CI-ignored (code) paths, keep polling while that count is `0` (i.e. checks not yet registered), then continue waiting until all registered checks are `completed`. A small initial sleep before the first poll is a weaker mitigation; prefer the explicit "wait until at least one non-drawbridge check exists" guard. Add a unit/harness case: "eligible code PR, first poll has zero check runs, later poll has green checks → autonomous."
  - Sources: standard-codex (blocker #1, confirmed, cites `drawbridge.yml:211/216/217`, `gates.py:184`); standard-gemini (important #2, confirmed); critical-gemini (important #3, confirmed). Three-reviewer consensus across two lenses.

- **I2: `fetch-item.sh` invocation interpolates `steps.resolve.outputs.*` directly into the run script instead of via `env:`**
  - Location: `.github/workflows/drawbridge.yml:111-115` (the "Fetch item context" step)
  - Problem: `item_type` and `item_number` are spliced into the shell `run:` block as `${{ steps.resolve.outputs.item_type }}` / `${{ ... item_number }}`. This is the known GitHub Actions expression-injection shape. Practically low-risk here (the values are derived from `resolve`, which reads `.number`/jq-derived integers, and direct exploitation needs `workflow_dispatch` write access), but every other step in the file already passes such values through `env:` (e.g. the gate step at `:187-190`, "Apply route label" at `:255-258`), so this is an inconsistency that should be closed.
  - Fix: Add `ITEM_TYPE` / `ITEM_NUMBER` to the step's `env:` block (mirroring the gate step) and reference `"$ITEM_TYPE"` / `"$ITEM_NUMBER"` in the `run:` script. Pure mechanical change.
  - Sources: standard-gemini (important #1, confirmed, with the exact env-based fix shown). Single-reviewer but cited file:line obviously exhibits the pattern and the fix is unambiguous and matches the file's own established convention.

- **I3: `drawbridge-notify` is skipped when the gate job fails — silent failure exactly when escalation matters (live-flip prerequisite)**
  - Location: `.github/workflows/drawbridge.yml:384-388` (the notify `if:` requires `needs.drawbridge-gate.result == 'success'`)
  - Problem: `gates.py` and the gate shell step run under `set -euo pipefail` and are documented to fail-closed (non-zero exit) on malformed input / `gh api` hiccup / policy parse error. But `drawbridge-notify` is gated on `drawbridge-gate.result == 'success'`, so any gate-step exception produces a red workflow with no label, no comment, and **no maintainer ping**. The "fail safe to escalation" promise is kept for the *route value* but not for the *human-in-the-loop*, which is the system's core contract once live. Fail-closed for merge, but not fail-safe for triage.
  - Fix: Add a notify path (or relax the condition) that fires when `drawbridge-gate.result == 'failure'`, sending a "Drawbridge gate errored — manual triage needed" message with the run URL. Optionally have the gate step trap unexpected failures and synthesize a `route=review` gate JSON so the normal notify path still runs. Keep merge impossible on the failure path.
  - Sources: critical-claude (important #2, confirmed, cites `:382`); critical-codex (important #3, confirmed, cites `:384-388`); standard-gemini (potential #3, confirmed). Three-reviewer consensus across two lenses.

- **I4: `upsert-comment.sh` matches any comment carrying the marker, regardless of author — DoS + audit-trail griefing (live-flip prerequisite)**
  - Location: `scripts/drawbridge/upsert-comment.sh:14-15` (the `jq` filter `select(.body | contains($m))`)
  - Problem: The marker (`<!-- drawbridge:gate -->` / `<!-- drawbridge:review -->`) is visible in the bot's own posted comments. If a contributor pastes the literal marker into their own comment, the filter selects *that* comment and the script issues `gh api -X PATCH repos/$REPO/issues/comments/$existing`. `GITHUB_TOKEN` cannot edit another user's comment → 403 → `set -e` crashes the gate/review job (which, combined with I3, also suppresses the maintainer ping). At minimum a contributor can grief the audit trail or shift which comment is updated.
  - Fix: Constrain the filter to bot-authored comments, e.g. `select((.body | contains($m)) and (.user.type == "Bot"))` (preferred over matching a hardcoded login, which varies by app/installation). Verify the GitHub API returns `user.type == "Bot"` for the posting identity; if matching on login, use the actual bot login.
  - Sources: critical-gemini (blocker #2, "verified this will happen", cites `upsert-comment.sh`); critical-claude (nit, cites the same `head -1`/marker-match and recommends `user.type == "Bot"` AND marker). Two-reviewer consensus across two lenses (one rates blocker, one rates nit — landing it is cheap and removes a crash vector that interacts with I3).

- **I5: `issue_comment`-triggered pipeline re-fires on closed/merged items and on any external commenter — token/quota exhaustion (live-flip prerequisite)**
  - Location: `.github/workflows/drawbridge.yml:27-28` (`issue_comment: [created]`) plus the judge `if:` at `:53-59` (which excludes bots and maintainer associations but not arbitrary external commenters, and does not check item state)
  - Problem: A comment on a closed or merged PR/issue still triggers the full judge → gate pipeline, including the paid LLM judge call. An external party can spam comments to repeatedly burn Claude/GitHub API quota. The judge `if:` filters bot/maintainer comments but does nothing about item open-state.
  - Fix: In the `resolve` step (or as a judge `if:` precondition), read the item state and exit early / skip the job when the item is `closed`/`merged`. The `meta.json`/`item.json` already carry enough to check state; a cheap `gh api .../issues/$NUM --jq .state` guard before the judge call also works.
  - Sources: critical-gemini (important #4, "verified this will happen"); standard-claude (important #2, confirmed — flags the unconditional re-trigger on `issue_comment` re-fires and recommends a guard before live); critical-claude (nit — "`issue_comment` retriggers the full judge→gate→(merge) pipeline … a convenient attacker-controlled re-roll trigger once live"). Three-reviewer consensus across two lenses. (The label-churn/re-merge facet of standard-claude #2 is largely neutralized by the now-landed SHA pin; the open-state guard is the durable fix.)

### Straightforward mediums

- **M1: `**/*.md` CI-skip lets agent-instruction markdown (`CLAUDE.md`) reach the autonomous lane with zero CI (live-flip prerequisite)**
  - Location: `TRIAGE_POLICY.md` machine config — `ci_ignored_paths: ["**/*.md", ...]` (diff line ~728) and `categories.docs: ["docs/**", "notes/**", "*.md"]` / `categories.bugfix: [... "*.md"]` (diff lines ~714-716); gate logic `gates.py:978-990`
  - Problem: A root-level `CLAUDE.md` matches `*.md` (docs category) and `**/*.md` (CI-ignored), so an org/contributor markdown-only PR judged `docs`/`bugfix` can route autonomous with zero check runs. In this ecosystem `CLAUDE.md` files are executable agent instructions, not harmless prose: an autonomously-merged `CLAUDE.md` change reprograms every future agent's behavior with no review and no CI, and the judge (assumed-foolable by design) is the only thing in the way.
  - Fix: Add `CLAUDE.md`, `**/CLAUDE.md`, and any other agent-instruction markdown (consider `*.mdc`, `AGENTS.md`, skill `SKILL.md` if applicable) to the `deny_paths` list in `TRIAGE_POLICY.md` so they always escalate. Pure policy-file edit (the deny list already self-protects via `TRIAGE_POLICY.md` being denied), well-scoped, no code change. Add a gate test asserting a root `CLAUDE.md` routes `review`.
  - Sources: critical-claude (important #3, confirmed empirically, cites `TRIAGE_POLICY.md:855`/`gates.py:184-196`). Single-reviewer but cited, checkable, and the fix is a contained additive policy edit. (Listed as a medium rather than important because it is a live-flip-only exposure and a one-line policy add; sequence it with I3/I4/I5 before the live flip.)

### Evolutionary clear wins

- **EW1: Centralize the `drawbridge-config` parser and escalation-synthesis into one Python module (kill the duplicate parsers)**
  - Location: `scripts/drawbridge/gates.py:26-32` (`CONFIG_FENCE_RE` / `load_policy_config`) vs `scripts/drawbridge/notify.sh:16-25` (an inline Python heredoc re-implementing the same regex to pull the `zulip` block); plus the escalation JSON duplicated between `drawbridge.yml:139-148` ("Validate verdict") and `gates.py:1036-1044` (malformed-verdict synthesis)
  - Problem: The policy schema is parsed by two copies of the same regex and the fail-safe escalation verdict exists in two hand-maintained copies. As the policy grows these drift silently.
  - Fix: Have `gates.py` expose the config accessor (e.g. `--emit-config-key zulip`) and a single `synthesize_escalation()` reused by `main()` and called from the YAML "Validate verdict" step; switch `notify.sh` to call it instead of its heredoc. One schema, one regex, one escalation contract; all become testable. Low risk (notify runs in `main`-checkout jobs with Python already available).
  - Sources: evolutionary-claude (concrete suggestion #1, confirmed); evolutionary-codex (concrete suggestion #2, confirmed); evolutionary-gemini (tripartite-constitution pattern). Two-reviewer consensus on the exact refactor, both verified against module shape. Clear win: durability with no behavior change. (If the team prefers to keep this PR tight, it is equally valid to surface this rather than apply — see note; included here because both evo reviewers independently verified it as compatible and low-risk.)

## Surface to user (do not apply silently)

- **S1: Path-normalization gate absent — `..` / `./` segments can defeat deny+allow matching**
  - Why deferred: ambiguous (theoretical-on-GitHub; design choice about how strict to be)
  - Summary: `glob_to_regex` does literal anchored matching with no normalization. critical-claude verified empirically (PROBE4) that `Sources/../scripts/notarize.sh` passes both `no_denied_paths` and `paths_allowed` and routes autonomous, and a leading `./` dodges anchored deny patterns. GitHub's `files` API normalizes paths and never returns `..`/`./`, so this is not reachable through the real event path today, but the gate is the security boundary and arguably should not depend on an upstream API's normalization. Cheap defense-in-depth (`os.path.normpath`, reject any path containing `..` or starting with `/`/`./`, treat non-normalizable as denied). Single-reviewer, not exploitable today; surface so the user can decide whether to harden now or note the dependency.
  - Sources: critical-claude (potential #4, confirmed empirically)

- **S2: `size_cap` line count defaults missing `additions`/`deletions` to `0` instead of failing safe**
  - Why deferred: ambiguous (not exploitable through real path; GitHub always populates these)
  - Summary: `lines = pr.get("additions", 0) + pr.get("deletions", 0)` (`gates.py:951`) under-counts to `0` and passes the line cap if a truncated/partial `pr.json` (e.g. a `gh api` hiccup) lacks both fields. The file-count cap has a `len(files)` fallback; the line cap has none. critical-claude recommends failing the gate (escalate) when both fields are absent. Single-reviewer, fail-soft-not-safe edge that GitHub does not trigger today; surface for a decision.
  - Sources: critical-claude (potential #6, confirmed via PROBE2)

- **S3: `category` field is load-bearing but unvalidated in both the YAML jq check and `gates.py:valid_verdict()`**
  - Why deferred: disagreement on whether it matters (it fails safe today)
  - Summary: The autonomous source-path lane depends on `verdict.category == "bugfix"`, but neither validator constrains `category` to the five-value enum. Behavior is fail-safe (a typo like `"bug_fix"` drops bugfix from allowed categories → source PR escalates), so it is not exploitable; standard-claude flags it as a latent footgun that silently downgrades legitimate fixes with no audit signal and recommends adding `category` to both schema checks. Single-reviewer, fails safe; surface so the user can decide whether the audit-visibility gain is worth the change.
  - Sources: standard-claude (finding #3, confirmed)

- **S4: `notify.sh` / `fetch-item.sh` byte-boundary UTF-8 truncation (`head -c`) can emit malformed bytes**
  - Why deferred: subjective/low-stakes; reviewers rate it differently (important vs nit)
  - Summary: `notify.sh:37` truncates with `head -c 9000` and `fetch-item.sh:20` with `head -c 300000`; both can sever a multibyte UTF-8 rune (this repo ships six locales, so CJK/emoji in titles is plausible) and produce mojibake or a Zulip-rejected payload — and notify is the only maintainer-facing lane, so a dropped ping is a silent miss. Fix is a char-boundary trim (`python3 -c '...read()[:9000]'`, `cut -c`, or `iconv -c`). standard-claude rates it important; critical-claude rates the same thing a nit. Low likelihood (titles rarely approach the cap). Surface for a quick judgment call.
  - Sources: standard-claude (finding #1, confirmed); critical-claude (nit)

- **S5: Localization (`Resources/Localizable.xcstrings`) auto-routes with zero CI validation**
  - Why deferred: design-needed (requires deciding on a validation gate or a CI change)
  - Summary: `.xcstrings` is in both CI `paths-ignore` and Drawbridge `ci_ignored_paths`, and the test suite explicitly expects org-member localization PRs to route autonomous with zero check runs. A malformed `.xcstrings` could break localization/build tooling while passing the "CI green" gate (there is no CI signal to read). standard-codex suggests either removing it from CI `paths-ignore` or adding a deterministic localization gate (parse as JSON/plist, assert expected locale keys). Single-reviewer, design choice that touches CI config; surface for direction. (critical-claude separately argues localization is actually the *safest* first live path because, unlike docs, it has no instruction-execution semantics — the two views should be reconciled by the user.)
  - Sources: standard-codex (important #3, confirmed); critical-claude (closing, opposing framing)

- **S6: `issues`/`issue_comment` event coverage omits `edited`/`reopened`; nightly sweep never revisits labeled-but-stale items**
  - Why deferred: design-needed (intentional-scoping question)
  - Summary: The workflow handles `issues: [opened]` and `issue_comment: [created]` only, and the sweep filters out anything already carrying a `drawbridge:*` label. A contributor who edits a comment (adding info, or removing injection text) or a stale labeled item with meaningful new activity will not be re-triaged until — and unless — the sweep catches it, which it won't for labeled items. standard-codex recommends adding `edited`/`reopened` and/or a second low-volume sweep query for labeled items updated since last run, or documenting the "new-only + unlabeled-sweep" behavior as a deliberate spec deviation. Single-reviewer; this is a scope decision, not a clear bug.
  - Sources: standard-codex (important #2 + potential #5, confirmed)

- **S7: CI gate considers only check-runs, not legacy commit statuses**
  - Why deferred: ambiguous (correct for this repo today; matters only if external status providers are added)
  - Summary: The poll and `gates.py` read only `commits/{sha}/check-runs`. This matches c11's Actions-only CI today, but if branch protection or an external CI provider later adds classic commit statuses, Drawbridge could declare CI green without them. Both reviewers suggest either documenting the Actions-only assumption in `TRIAGE_POLICY.md` or combining check-runs with the combined-status API before live mode depends on branch-protection semantics. Two reviewers raised it but both as a forward-looking caveat, not a current defect; documenting the assumption is the lightweight resolution.
  - Sources: standard-codex (potential #4, confirmed); critical-codex (nit)

- **S8: Privilege escalation via prompt injection forcing `category: bugfix` (CONTRIBUTOR → `Sources/**`)**
  - Why deferred: disagreement / reviewer misread of the threat model
  - Summary: critical-gemini rates as a blocker that the gate "trusts the LLM's `bugfix` classification to expand allowed paths," so prompt injection could auto-merge malicious `Sources/**` code. This overstates the exposure: the gate also requires `ci_green` (real CI must pass on the actual code), `size_cap`, the deny list, and a non-first-timer tier — a fooled `bugfix` classification alone cannot merge code that fails CI, and `Sources/**` always has CI. standard-claude and critical-claude both independently conclude the verdict is "never sufficient alone" and the injection-shaped-verdict test (`test_injection_shaped_verdict_cannot_bypass_gates`) confirms gates hold. Surface because one reviewer rated it a blocker, but the consensus reading is that the deterministic gates contain it; the user may still want to consider critical-gemini's stricter stance (CONTRIBUTOR `Sources/**` always escalates) as a policy tightening before live.
  - Sources: critical-gemini (blocker #1); contra: standard-claude (finding #9 / scorecard), critical-claude (scorecard MUST 2)

- **S9: `cancel-in-progress: false` allows pipeline pile-up / runs to stack on rapid comment or force-push spam**
  - Why deferred: disagreement on the correct fix (the SHA pin already neutralizes the dangerous merge facet)
  - Summary: `concurrency.cancel-in-progress: false` (`drawbridge.yml:42`) means rapid `synchronize`/comment events queue full pipeline runs (each up to 75 min) rather than coalescing, wasting runner minutes and Claude tokens. standard-gemini and critical-claude suggest `cancel-in-progress: true` for non-merge events; critical-codex/critical-claude note the now-landed SHA pin already prevents the stale-head *merge* hazard, leaving only stale label/comment churn and cost. Reviewers disagree on whether to flip the flag (risks cancelling an in-flight merge) vs. add a head-currency recheck before label/comment. Surface for a design call.
  - Sources: standard-gemini (potential #4); critical-claude (nit); critical-codex (finding #2, partially mitigated by SHA pin)

- **S10: LLM judge can write files other than `verdict.json` into `/tmp/drawbridge`, poisoning downstream artifact consumers**
  - Why deferred: design-needed (real but contested severity; fix is non-trivial)
  - Summary: critical-codex rates as a blocker: the judge has the `Write` tool, the whole `/tmp/drawbridge/` dir is uploaded after the judge runs (`:152-156`), and gate/review/notify download and trust it (`meta.json`, `item.diff`, `comments.json`). A fooled judge could rewrite `item.diff`/`comments.json` to mislead the deep reviewer or `meta.json` to suppress notification. Fix: upload only `verdict.json` from the judge job and re-fetch context deterministically in downstream jobs (or capture an immutable pre-judge artifact the judge cannot write). No other reviewer raised this; it is a legitimate trust-boundary observation but the fix changes the artifact flow and warrants design discussion (and the route/merge decision itself is unaffected because `gates.py` re-fetches `pr.json`/`files.json`/`checks.json` fresh in the gate job — the exposure is to review-context and notify-metadata, not to the merge gate). Surface for the user.
  - Sources: critical-codex (blocker #1, confirmed, cites `:117-126`, `:152-156`, `:338-342`, `:236-241`)

## Evolutionary worth considering (do not apply silently)

- **E1: `gates.py --replay` mode + persisting raw gate inputs in the audit artifact**
  - Summary: `evaluate_pr()` is already a pure function of `(config, verdict, pr, files, checks, skip_ci)` — exactly the inputs the run produces. Adding a replay entry point and uploading the raw `pr.json`/`files.json`/`checks.json` (today only `gates.json` is uploaded) turns the dry-run audit trail into a regression corpus: before flipping to live you replay every recent PR against the candidate policy and see what *would* have auto-merged.
  - Why worth a look: It converts the spec's "audit 1-2 weeks of would-act decisions" graduation step from manual Zulip-scrolling into a deterministic, reviewable check — the single highest-leverage move toward a *safe* live flip, and nearly free given the existing artifacts.
  - Sources: evolutionary-claude (suggestion #2 / leverage #2); evolutionary-codex (suggestion #5); evolutionary-gemini (mutation: auto-regression of policy). Three-reviewer consensus.

- **E2: Add `schema_version` to the `drawbridge-config` block now**
  - Summary: The config JSON has no version field. Adding `"schema_version": 1` while there is exactly one install is purely additive and prevents migration ambiguity once per-category action profiles, replayable records, or new keys land.
  - Why worth a look: One-line, zero-risk insurance against a future where multiple instantiations and policy-shape changes make unversioned configs painful to migrate.
  - Sources: evolutionary-codex (suggestion #3 / leverage #2)

- **E3: Name and document the "LLM proposes, deterministic gate disposes" pattern as a durable c11/Stage 11 primitive**
  - Summary: The propose/dispose split (read-only judge with `--disallowedTools`, `gates.py` as sole authorizer, deterministic act step) is the load-bearing pattern here and is reusable for any future agent-authorizing surface (lattice-orchestrator gating, a `/drawbridge-install` skill). Today it lives only as YAML comments and spec prose. Writing it into `platform/` or a c11 skill lets the next surface reuse it instead of re-deriving it.
  - Why worth a look: Pure documentation, zero runtime risk, and it propagates the one genuinely novel architectural idea in the diff across the fleet.
  - Sources: evolutionary-claude (suggestion #4 / pattern #1, confirmed); evolutionary-codex (pattern: "LLM judgment as a claim, not an authority"); evolutionary-gemini (tripartite constitution). Three-reviewer consensus.
