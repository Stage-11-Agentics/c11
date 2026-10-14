# Evolutionary Review Synthesis — drawbridge-install

- **Branch:** drawbridge-install (PR #221)
- **Commit:** 36866f596
- **Reviewers synthesized:** Claude Opus 4.8 (1M), Codex (GPT-5), Gemini 1.5 Pro
- **Lens:** Evolutionary / exploratory (not line-level correctness; that's the Standard/Critical passes)

---

## Executive Summary — The Biggest Opportunities

All three models independently arrived at the same core read: **this PR is not a triage bot, it is the first instantiation of a programmable governance kernel for an open-source repo.** The names differ but describe one thing — Claude's "policy-as-runtime-config seam / governance kernel," Codex's "Attention Firewall / controlled agency at the repository boundary," Gemini's "Programmable AI Maintainer." The deeper capability: c11 can now accept work from agents and strangers with the trust boundary expressed declaratively rather than in code, which is the c11 thesis ("operator running thirty agents") turned back on c11's own contribution flow.

The three highest-leverage moves, in unanimous or near-unanimous agreement:

1. **Build a replay/simulator harness.** Turn the existing audit artifacts (verdicts + gate results) into a regression corpus so policy edits become provably safe and the "go live" decision becomes a deterministic test instead of a human reading Zulip. *(All 3 models. Claude's #1 leverage point and "the bearing the whole flywheel spins on." Codex's top priority. Gemini's experimental #3.)*

2. **Collapse the config schema into one parser/validator.** The `drawbridge-config` JSON block is parsed independently in `gates.py` and `notify.sh` (copy-pasted regex), and escalation JSON is duplicated between the YAML "Validate verdict" step and `gates.py`. One schema, one validator, one escalation contract. *(All 3 models. Smallest diff, disproportionate durability.)*

3. **Get logic out of untested YAML.** The most intricate control flow in the system (the CI pre-pass → poll → re-evaluate loop, the route/comment/notification composition) lives in untestable bash inside `drawbridge.yml`. Pull it into the already-tested Python module. *(Claude + Codex, strongly.)*

The flywheel all three converge on: **decision → reason → outcome capture → replay → confident policy widening → wider autonomy → more inbound → repeat.** The system should get *safer* as it's used, not just busier. The single missing piece today is **outcome capture** (did the maintainer later agree?).

---

## 1. Consensus Direction — Evolution Paths Multiple Models Identified

1. **The replay corpus / simulator is the keystone (3/3).** Every reviewer independently identified that the dry-run artifacts are 90% of a regression suite. Claude proposes `gates.py --replay <historical-pr.json>`; Codex proposes a full-route simulator extending the existing `test_gates.py` harness from "gate unit" to "full routing contract"; Gemini proposes a periodic policy-regression workflow over the last 100 closed PRs. Same idea at three altitudes. The prerequisite (flagged by Claude and Codex): the gate job currently only uploads `gates.json`, not the raw `pr.json`/`files.json`/`checks.json` inputs — add a normalized `drawbridge-record.json` so replay needs no GitHub API calls.

2. **Centralize policy parsing into one module (3/3).** All three flag the duplicated config-parsing regex between `gates.py:37` and `notify.sh:16`. Consensus solution: a `scripts/drawbridge/policy.py` (or extend `gates.py`) exposing `load_config()`, schema validation, glob semantics, and Zulip-config access, with `notify.sh` calling it instead of re-parsing.

3. **Move workflow glue into testable code (2/3 explicit, 3rd implied).** Claude and Codex both name the YAML as "where the next bug will hide" / "the hardest place to test, simulate, and reuse." The CI-polling loop, act step, gate-comment builder, and notification body builder should become scripts so tests can assert both the security behavior and the contributor/maintainer-facing copy.

4. **Name and preserve the "LLM proposes, deterministic code disposes" pattern (3/3).** Claude: "the single most important pattern in the diff... name it and write it into the c11 skill set." Codex: "LLMs can make claims; only deterministic gates grant capabilities." Gemini: "Heuristic Judge vs Deterministic Gates unified under a shared constitution." Consensus: this is a reusable Stage 11 primitive (it's the same shape as a capability system — the LLM holds no capabilities, the gate mints them) and currently lives only as code comments and spec prose. It belongs in a durable doc/skill so the next agent-authorizing surface (lattice-orchestrator gating, the drawbridge-install skill itself) reuses it.

5. **The tripartite/dual-contract policy file is the most reusable artifact (3/3).** `TRIAGE_POLICY.md` as simultaneously human prose, LLM context, and machine config — Claude's "policy-as-runtime-config seam," Codex's "policy-as-dual-contract," Gemini's "Tripartite Constitution / Policy-as-Code-as-Prompt." Plus the self-protecting property (the policy is on its own deny list) that Claude singles out as a generalizable rule: any file governing autonomous behavior should deny-list itself.

6. **Fail-safe-to-human is the correct, stated invariant (2/3).** Claude's "fail-safe-to-escalation" and Gemini's "Fail-Safe Asymmetry" both call out that every error/malformed input routes to a human, never toward the action. Worth stating explicitly as a rule (while deduplicating its two implementations).

7. **Graduation should be per-category, not a global switch (2/3).** Claude (Mutation E direction) and Codex both note the single `mode: dry-run` switch should become per-category action profiles (e.g., docs=live, localization=dry-run, bugfix=review-only). Gemini's continuous-trust idea is the contributor-side analog. This matches the spec's graduation protocol more directly than deleting categories from tier lists. Codex adds: land this behind schema versioning.

---

## 2. Best Concrete Suggestions — Most Actionable Across All Three

1. **Unify config + escalation into one module; make `notify.sh` and the YAML call it.** *(Claude #1, Codex #2 — both ✅ Confirmed.)* `gates.py` already exposes `load_policy_config()` and a clean `main(argv)`. Add `--emit-config-key zulip` and a shared `synthesize_escalation()` reused by both the YAML step and `main()`. Kills two of three emerging anti-patterns. Low risk, small diff. **Highest actionability-to-effort ratio in the whole set.**

2. **Add a `schema_version` to the config now, plus a CI policy-lint.** *(Codex #3, Claude #3 — ✅ Confirmed.)* The config JSON starts with no version; add `"schema_version": 1` while there's a single install to prevent future migration ambiguity. Wire `python3 scripts/drawbridge/gates.py --validate-policy TRIAGE_POLICY.md` into the existing workflow-guard CI job: validates the JSON schema, checks every `tiers[].categories` references a real `categories` key, that `deny_paths`/`categories` globs compile, and that `TRIAGE_POLICY.md` is in its own deny list. Catches typos at PR time instead of at runtime on a real inbound PR. Purely additive.

3. **Add `--replay` and seed a corpus from the dry-run period.** *(Claude #2, Codex #5, Gemini #3.)* `evaluate_pr()` is already a pure function of `(config, verdict, pr, files, checks, skip_ci)` — exactly the artifact inputs. Prerequisite: upload the raw inputs (or a normalized `drawbridge-record.json`) from the gate job, not just `gates.json`. Then replaying the last N PRs against a candidate policy becomes the graduation test.

4. **Extract/test the CI-polling bash.** *(Claude #3, Codex #1 — ✅ Confirmed as a gap.)* The 45-iteration pre-pass → poll → re-evaluate loop is the least-tested code in a security-critical path. Pull the decision logic into `gates.py` with a `--with-ci-wait` mode (or a checks-fetch callback seam), leaving only `gh api`/`sleep` in shell. Medium effort, needs a fetch seam.

5. **Add a prompt/gate contract test.** *(Claude #4, Codex #5.)* The judge prompt hard-codes the verdict schema that must stay in sync with `valid_verdict()`. Per repo test policy, assert *behavior*: feed `judge.md`'s documented example verdict through `valid_verdict()` and assert it passes (not grep the prompt text). Codex extends this to a reusable adversarial fixture set: malicious comments, malicious diffs, malformed judge outputs — so prompt changes can't silently weaken the boundary. (`test_gates.py:132` already proves a fooled judge can't bypass the gates; generalize it.)

6. **Per-category action profiles behind schema versioning.** *(Claude direction, Codex #4 — ✅ Confirmed.)* Replace the global `mode` with `actions.docs=live`, `actions.localization=dry-run`, `actions.bugfix=review`. Gates must output the matched category/action so workflow behavior stays deterministic.

7. **Enrich `fetch-item.sh` with semantic/blast-radius context.** *(Gemini #2 — ✅ Confirmed.)* Inject a lightweight symbol map / callers-callees list for modified files into `/tmp/drawbridge/`. The Judge and Deep Reviewer currently burn tokens and latency rediscovering this via Grep/Glob. Static dependency map up front raises accuracy without breaking the read-only sandbox. The `item.json` artifact is the natural carrier (Gemini's second leverage point).

8. **Deep Reviewer emits a `suggestions.patch` artifact.** *(Gemini #1 — ✅ Confirmed.)* Instead of only nits in `review.md`, have Opus output a unified diff the maintainer can apply with one command — turning a "needs work" PR into "ready to merge." Compatible with the existing artifact upload pipeline.

---

## 3. Wildest Mutations — Creative / Ambitious Ideas Worth Exploring

1. **Policy that evolves from its own audit trail (Claude B + Codex "policy lint from false positives" + Gemini "auto-regression of policy").** A periodic agent reads the last month of would-act decisions paired with maintainer corrections ("Atin escalated this even though the gate said autonomous") and proposes the *smallest `TRIAGE_POLICY.md` diff* that would have fixed each miss. The maintainer reviews one policy PR instead of N individual corrections — and the move is always a human-reviewed policy edit, never silent. This is the flywheel made mechanical. Every mistake becomes a policy regression fixture. **The most ambitious and most-converged-on mutation; depends entirely on the replay corpus existing first.**

2. **The drawbridge as a first-class c11 surface (Claude A).** The pipeline already emits structured JSON; pipe it to a c11 sidebar/markdown surface showing the live inbox — pending verdicts, would-act decisions, the dry-run ledger — rendered in the operator's command center next to their agent panes. The repo's inbox becomes another addressable surface. The most on-brand mutation: c11 dogfooding its own "every surface has a handle" pitch on its own contribution flow. Codex's "maintainer console" (expand the nightly sweep into a daily "inbound state of the repo" digest) is the lower-effort cousin.

3. **The two-lane kernel applied to the agent fleet itself (Claude D).** judge→gate→act isn't specific to inbound PRs. The same kernel could gate *outbound* agent actions in the lattice-orchestrator workflow: a delegator "proposes" a PR-open/merge, deterministic gates check it, only then does it act. The drawbridge is the first place c11 expresses "an LLM may propose but only deterministic code may authorize" — and that principle wants to be the spine of how every autonomous Stage 11 agent is bounded.

4. **`/drawbridge-install` as an invocable c11 skill (Claude C).** Since the whole thing is markdown spec + Python + shell, "deploy to a new repo" is: copy `DRAWBRIDGE.md`, run an agent, answer the interview. Make that a c11 skill that *is* the interview — spawns an agent, runs the maintainer interview via `AskUserQuestion`, generates the adapted artifacts in the target repo. Stage 11 ships a governance kernel as a skill, not a SaaS.

5. **Autonomy budgets and cooldowns (Codex).** Move beyond binary live/dry-run: "auto-merge at most 3 docs PRs/day," "never auto-merge after a red-to-green CI transition without one extra sweep," "first live week notifies before merge but doesn't comment." Makes live rollout less cliff-shaped and turns the gate into an attention *manager*. (Needs state — labels/artifacts/queries, not mutable repo files.)

6. **Claims-and-proofs instead of a single category (Codex).** Replace the judge's single `category` field with a list of claims `[{type, evidence, confidence}]`. Gates require exactly one supported claim and attach proof-like evidence to the audit artifact. Handles mixed PRs (docs + source, tests + bugfix) far more legibly. Prototype in dry-run artifacts first.

7. **Multi-judge model-diversity quorum (Claude #6).** The highest-stakes lane currently rides one Sonnet verdict (correctly bounded by gates, but still). Require *two* judges (e.g., Sonnet + a second model) to both say `autonomous`; disagreement → escalate. Matches the c11 house style ("get perspectives from different models"). Worth prototyping before the live flip, not before merge — cost matters and it only bites once live.

8. **Forge adapter layer (Codex).** A `drawbridge event normalize` layer translating GitHub/GitLab/Forgejo events into one item schema, so `gates.py` and the simulator stop caring about the forge. Realizes the spec's forge-agnostic promise (this install is GitHub-native).

9. **Ephemeral "prove it" environments + self-correction lane (Gemini, lower priority).** For bugfix PRs, auto-construct a tiny reproducible before/after (WASM or remote sandbox) linked in the Zulip notification. Gemini's self-correction lane (let the reviewer coach the contributor before escalating) is explicitly *downgraded by Gemini itself* — the pipeline values zero-noise decisive escalation over automated back-and-forth that could frustrate contributors if the AI hallucinates the fix. Noted for completeness; keep it read-only and decisive for now.

---

## 4. Leverage Points and Flywheel Opportunities

### Leverage Points (ranked by consensus + impact-to-effort)

1. **One config parser, one schema, one validator.** *(All 3 — highest leverage, smallest change.)* Collapse the duplicated regex + duplicated escalation JSON into the one tested Python module. Kills two of three emerging anti-patterns in a small diff. Do this first.

2. **`--replay` mode / replayable audit artifacts.** *(All 3.)* The artifacts already carry nearly every gate input. Adding the raw-input bundle + a replay entry point converts "go live safely" from a vibes exercise into a deterministic, reviewable check. This is the lever that makes flipping to live mode *safe enough to actually do* — the whole point of the pipeline.

3. **Test or relocate the CI-polling bash.** *(Claude + Codex.)* The "wait for CI" behavior — the thing between a green-looking PR and an auto-merge — is the least-tested code in the critical path.

4. **Schema versioning + policy-lint in CI.** *(Codex + Claude.)* Cheap insurance against config drift and runtime-discovered typos. Land before any policy-contract change (per-category profiles, replay records).

5. **Richer `item.json` / `fetch-item.sh` context.** *(Gemini.)* The artifact is the integration seam for secondary checks (blast radius, symbol maps, future analyzers) without re-hitting the GitHub API. Investing in the context payload compounds across every downstream consumer.

6. **Split author-trust from GitHub's association names.** *(Codex #4.)* `gates.py:86` keys tiers off `author_association`; the policy will eventually want repo-specific facts (prior false positives, maintainer allowlist, blocked users, trusted translators). Gemini's continuous trust-scoring is the same lever pushed further.

### The Flywheel (unanimous shape)

```
more inbound items
  → decision + reason logged (verdict + gate artifacts — EXISTS TODAY)
  → outcome captured: did the maintainer later agree? (THE MISSING PIECE — all 3 flag it)
  → larger replay corpus
  → policy tuned with confidence (replay proves the edit is safe)
  → wider autonomous scope / live mode on more paths
  → fewer maintainer interruptions per item
  → repo absorbs more contributors + agent-authored PRs
  → more inbound items
```

The accelerant all three name is the **audit trail → replay corpus → policy-tuning loop.** The trail exists; the loop is open because (a) outcome capture is missing and (b) a human reads Zulip and hand-edits the policy. Two seams close it:

- **Replay** (Leverage #2) makes policy edits provably safe → the maintainer widens scope faster and more confidently.
- **Policy-proposal agent** (Mutation #1) makes the corpus *generate* the policy edits → the human reviews proposals instead of authoring them.

Close both and the human moves from author to approver, and the system tightens its own trust boundary every week from its own history. As Codex put it: **the system gets safer as it is used, instead of merely getting busier.**

A second, softer flywheel (Claude + Gemini): every re-instantiation of the spec on a new repo hardens the *generic* kernel, making the next instantiation easier — open-source-template compounding applied to a governance kernel rather than a project skeleton. Gemini's contributor-side flywheel: fast autonomous merges of small well-scoped PRs create a dopamine loop that trains contributors to submit exactly the cleanly-scoped work the AI reviews best.

---

## Recommended Sequencing (synthesized from all three)

**Before merge / immediately (additive, low risk):** config unification (#2.1), schema version + policy-lint (#2.2). Codex: "convert Drawbridge from a carefully built workflow into a maintainable system" — these three plus the simulator are the maintainability floor.

**Before the live flip:** replay corpus + replayable records (#2.3), CI-polling extraction/test (#2.4), prompt/gate contract + adversarial fixtures (#2.5), multi-judge quorum prototype (#3.7). All three reviewers agree: prioritize simulator + parser + lint *before any live-mode expansion.*

**Staged behind schema versioning:** per-category action profiles (#2.6), richer audit records, generated deep-review knowledge (the one suggestion needing a source-of-truth design decision — some rules belong in `CLAUDE.md`, some in policy, some prompt-only).

**Demand-driven / spikes:** drawbridge c11 surface (#3.2), policy-proposal agent (#3.1, after replay exists), generalized non-merge verbs, forge adapter, autonomy budgets, claims-and-proofs.
