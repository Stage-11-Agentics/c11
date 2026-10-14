## Evolutionary Code Review
- **Date:** 2026-06-03T18:09:50Z
- **Model:** Codex (GPT-5; exact runtime model ID not exposed)
- **Branch:** drawbridge-install
- **Latest Commit:** 36866f59617d9503798c7729b1f00bc7c610cf21
- **Linear Story:** drawbridge-install
- **Review Type:** Evolutionary/Exploratory
---

Note: the wrapper prompt for this review explicitly prohibited all actions beyond writing this file, so I did not run the requested `git fetch` / `git pull` sync. Scope is the local `HEAD` commit against `origin/main`, read from committed files where the worktree had unrelated dirty changes.

## What's Really Being Built

This is not just an inbound triage workflow. It is a repo-local governance compiler: a human-readable policy file becomes a bounded automation contract, an LLM supplies a soft classification, deterministic code compiles that into allowed actions, and the workflow turns the result into labels, comments, audit artifacts, and maintainer interrupts.

The interesting primitive is "controlled agency at the repository boundary." c11 already treats agents as first-class inside the workspace; Drawbridge extends that idea to the public edge of the project. It answers a different question than CI: not "does this build?" but "what level of trust, attention, and autonomy should this inbound thing receive?"

The name I would give the emerging capability is an **Attention Firewall**. It is not primarily a merge bot. It is an interruption router with an autonomous sublane.

## Emerging Patterns

**Policy-as-dual-contract.** `TRIAGE_POLICY.md:1` through `TRIAGE_POLICY.md:156` carries both maintainer prose and the machine config block. `scripts/drawbridge/gates.py:37` parses that config, while `scripts/drawbridge/notify.sh:16` reparses the same block independently. That pattern is powerful enough to formalize: one policy document, one schema, many consumers.

**LLM judgment as a claim, not an authority.** The judge prompt requires a structured verdict in `scripts/drawbridge/prompts/judge.md:54`, but `scripts/drawbridge/gates.py:109` only treats that verdict as one gate among trust, path, size, draft, and CI gates. This is the right pattern. It should be named and preserved: LLMs can make claims; only deterministic gates grant capabilities.

**Trusted checkout, untrusted text.** `.github/workflows/drawbridge.yml:68`, `.github/workflows/drawbridge.yml:174`, `.github/workflows/drawbridge.yml:333`, and `.github/workflows/drawbridge.yml:392` all checkout `main`, while `scripts/drawbridge/fetch-item.sh:16` fetches PR content through API text and diff. This is becoming a reusable secure review shape, not just a Drawbridge implementation detail.

**Workflow glue is becoming product logic.** The route application, CI polling, act step, and notification composition live mostly in `.github/workflows/drawbridge.yml:185` through `.github/workflows/drawbridge.yml:451`. That is normal for an install pack, but if Drawbridge evolves, this YAML will become the hardest place to test, simulate, and reuse.

**Dry-run as flight recorder.** The live flip in `TRIAGE_POLICY.md:78` and artifacts in `.github/workflows/drawbridge.yml:152` / `.github/workflows/drawbridge.yml:309` create the beginning of a feedback loop. Today the loop is manual audit. In six months, the valuable asset will be the corpus of verdicts, failed gates, comments, and maintainer outcomes.

## How This Could Evolve

The natural next step is a **Drawbridge simulator**: a local command or test harness that accepts policy, item metadata, files, check runs, verdict JSON, and optional comments, then emits the exact route label, gate comment, deep-review eligibility, and notification body. The tests at `tests/drawbridge/test_gates.py:58` already simulate the gate binary. Extend that from "gate unit" to "full routing contract."

That simulator would make policy edits cheap. Before flipping `TRIAGE_POLICY.md:112` from dry-run to live, the maintainer could replay the last 50 Drawbridge artifacts and see which would act, which would interrupt, and why. This turns "audit for 1-2 weeks" from a human memory exercise into a regression suite.

The architecture also wants a **policy compiler module**. Right now the same fenced JSON is parsed by `scripts/drawbridge/gates.py:37` and `scripts/drawbridge/notify.sh:16`, and workflow YAML still owns several route semantics. A small `scripts/drawbridge/policy.py` plus a `validate-policy` command would let every consumer use the same schema, defaults, and error messages.

For live mode, the policy should probably evolve from a single `"mode": "dry-run"` switch at `TRIAGE_POLICY.md:112` into per-category action settings. Example: docs can be live, localization dry-run, bugfix review-only. That matches the graduation protocol in `TRIAGE_POLICY.md:83` more directly than deleting categories from tier lists.

The deep-review prompt should eventually be generated from policy and repo notes instead of hardcoded. `scripts/drawbridge/prompts/deep-review.md:21` duplicates c11-specific review knowledge from `CLAUDE.md`. That is useful for this first install, but it will drift. The evolutionary move is a policy section like `review_knowledge`, compiled into the prompt and tested for presence.

## Mutations and Wild Ideas

**Drawbridge as a maintainer console.** The nightly sweep at `.github/workflows/drawbridge-sweep.yml:30` already constructs a digest. Expand that into a daily "inbound state of the repo" message: new items, aging escalations, would-act decisions, false-positive candidates, and policy tuning suggestions.

**Autonomy budgets.** Instead of only binary live/dry-run, policy could define budgets: "auto-merge at most 3 docs PRs per day," "never auto-merge after a red-to-green CI transition without one extra sweep," or "first live week requires maintainer notification before merge but no comment." This would make live rollout less cliff-shaped.

**Claims and proofs.** Replace the single judge `category` field with a list of claims: `[{type: "bugfix", evidence: "...", confidence: "high"}]`. Gates can then require exactly one supported claim and attach proof-like evidence to the audit artifact. That makes the system more legible when a change spans docs plus source or tests plus bugfix.

**Policy lint from false positives.** If maintainers mark a Drawbridge decision wrong, a tool could propose the smallest policy edit that would have changed the route. This is the compounding move: every mistake becomes a policy regression fixture.

**Forge adapter layer.** The spec is forge-agnostic, but this install is GitHub-native. A future `drawbridge event normalize` layer could translate GitHub, GitLab, or Forgejo events into one item schema. Then `gates.py` and the simulator stop caring about the forge.

## Leverage Points

1. **Extract route composition out of YAML.** `.github/workflows/drawbridge.yml:271` builds the gate comment and `.github/workflows/drawbridge.yml:409` builds the notification body inline. Moving those into scripts gives tests a place to assert contributor-facing copy and maintainer-facing summaries.

2. **Add schema versioning now.** `TRIAGE_POLICY.md:110` starts a raw JSON config with no `schema_version`. Adding one while there is only a single install prevents future migration ambiguity.

3. **Make audit artifacts replayable.** The verdict artifact at `.github/workflows/drawbridge.yml:152` and gate artifact at `.github/workflows/drawbridge.yml:309` are already close to a replay corpus. Add enough normalized metadata to replay decisions without GitHub API calls.

4. **Split "author trust" from GitHub's association names.** `scripts/drawbridge/gates.py:86` resolves tiers from `author_association`. That is good for v0, but the policy will eventually want repo-specific facts: prior false positives, maintainer allowlist, blocked users, trusted translators, upstream maintainers.

5. **Turn prompt safety into a reusable fixture set.** `tests/drawbridge/test_gates.py:132` verifies a fooled judge cannot bypass deterministic gates. Add fixtures for malicious comments, malicious diffs, and malformed judge outputs at the prompt/contract boundary so prompt changes do not silently weaken the shape.

## The Flywheel

Drawbridge can compound if every triage run produces three durable things: a decision, a reason, and whether the maintainer later agreed. The current implementation produces the first two through verdict and gate artifacts. The missing third piece is outcome capture.

Once outcome capture exists, the loop becomes:

1. Inbound items produce verdicts, gates, labels, comments, and notifications.
2. Maintainer corrections become replay fixtures or policy edits.
3. Policy edits are simulated against past traffic before merging.
4. Live scope expands only where replay confidence is high.
5. More accepted automation creates more training/audit data.

That is the real win: the system gets safer as it is used, instead of merely getting busier.

## Concrete Suggestions

1. **High Value — Add a full-route simulator.** ✅ Confirmed — the gate test harness already runs `gates.main()` through file I/O at `tests/drawbridge/test_gates.py:58`, and workflow route semantics are concentrated in `.github/workflows/drawbridge.yml:185`, `.github/workflows/drawbridge.yml:254`, `.github/workflows/drawbridge.yml:271`, `.github/workflows/drawbridge.yml:315`, and `.github/workflows/drawbridge.yml:377`. Extract route/comment/notification composition into scripts and add tests that replay synthetic PRs end-to-end. Dependency/risk: keep GitHub API calls outside the simulator by using normalized fixture JSON.

2. **High Value — Centralize policy parsing and validation.** ✅ Confirmed — `scripts/drawbridge/gates.py:37` and `scripts/drawbridge/notify.sh:16` duplicate fenced-config parsing. Add `scripts/drawbridge/policy.py` with `load_config()`, schema validation, glob semantics, and Zulip config access; make `notify.sh` call a tiny Python helper or switch notification composition to Python. Dependency/risk: preserve shell simplicity for workflow use, but avoid a second parser.

3. **High Value — Add policy schema version and CI policy-lint.** ✅ Confirmed — the config starts at `TRIAGE_POLICY.md:110` with no version, and CI already runs Drawbridge gate tests at `.github/workflows/ci.yml:48`. Add `"schema_version": 1`, validate required keys/types, and wire `python3 scripts/drawbridge/gates.py --validate-policy TRIAGE_POLICY.md` or a dedicated validator into the existing workflow-guard job. Dependency/risk: this is purely additive if defaults are explicit.

4. **Strategic — Replace global mode with per-category action profile.** ✅ Confirmed — `TRIAGE_POLICY.md:83` describes narrowing live rollout by dropping categories, while `scripts/drawbridge/gates.py:269` emits a single `mode` and `.github/workflows/drawbridge.yml:280` treats it globally. A policy like `actions.docs=live`, `actions.localization=dry-run`, `actions.bugfix=review` would better match staged graduation. Dependency/risk: gates must output the matched category/action so workflow behavior stays deterministic.

5. **Strategic — Make the audit trail replayable and outcome-aware.** ✅ Confirmed — verdict and gate artifacts are uploaded at `.github/workflows/drawbridge.yml:152` and `.github/workflows/drawbridge.yml:309`, but they are not yet a stable replay record. Add `drawbridge-record.json` containing item metadata, head SHA, changed paths, check summary, verdict, gates, route, mode, and emitted comment/notification hashes. Dependency/risk: avoid storing secrets or full untrusted bodies unless capped and clearly marked.

6. **Strategic — Generate deep-review knowledge from policy/repo notes.** ❓ Needs exploration — the deep-review prompt has c11-specific rules at `scripts/drawbridge/prompts/deep-review.md:21`, while `TRIAGE_POLICY.md:10` carries mission/scope but not review hot spots. A generated prompt would reduce drift, but the source-of-truth boundary needs design: some rules belong in `CLAUDE.md`, some in policy, and some in prompt-only workflow context.

7. **Experimental — Add autonomy budgets and cooldowns.** ❓ Needs exploration — nothing in the current gates prevents a burst of eligible docs PRs from all would-acting or auto-merging once live. This may be fine for c11's current traffic, but a policy section for daily limits and escalation-on-burst would turn Drawbridge from a static gate into an attention manager. Dependency/risk: budgets require state, so they should probably live in labels/artifacts or GitHub queries rather than mutable repo files.

8. **Experimental — Move from single `category` to judge claims.** ❓ Needs exploration — `scripts/drawbridge/prompts/judge.md:40` asks for one category, and `scripts/drawbridge/gates.py:131` treats `bugfix` specially. A claims array would handle mixed PRs and provide better audit detail, but it increases judge/output complexity. Prototype in dry-run artifacts before making gates depend on it.

## Validation Pass

The high-value suggestions are compatible with the current architecture because Drawbridge already has executable seams: `gates.py` is a CLI, test fixtures already serialize inputs, and workflow outputs are JSON-shaped. The main implementation risk is not technical; it is keeping the security invariant intact when moving logic out of YAML. Any extracted script must consume trusted checkout files plus API-fetched JSON only, never execute PR head content.

The strategic suggestions are also compatible, but should be staged. Per-category action profiles and replayable artifacts change the policy contract, so they should land behind schema versioning. Generated deep-review knowledge is valuable, but it needs a clear source-of-truth decision to avoid creating a third place where c11 review rules drift.

I would prioritize the simulator, policy parser, and schema lint before any live-mode expansion. Those three moves convert Drawbridge from a carefully built workflow into a maintainable system.
