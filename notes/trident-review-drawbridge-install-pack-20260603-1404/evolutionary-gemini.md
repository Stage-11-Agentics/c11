## Evolutionary Code Review
- **Date:** 2026-06-03T14:04:00Z
- **Model:** Gemini 1.5 Pro
- **Branch:** drawbridge-install
- **Latest Commit:** 36866f596
- **Linear Story:** drawbridge-install
- **Review Type:** Evolutionary/Exploratory
---

**What's Really Being Built**:
You aren't just building an autonomous triage pipeline. You are building a **Programmable AI Maintainer**. By explicitly separating the "Heuristic Judge" (LLM) from the "Deterministic Gates" (Python scripts) and unifying them under a shared constitution (`TRIAGE_POLICY.md`), you are creating a blueprint for high-trust autonomous operations. This is a framework for scaling open-source maintenance where the LLM does the semantic filtering and traditional code provides the hard security boundaries. You're building an organizational scaling vector that turns policy into executable enforcement.

**Emerging Patterns**:
- **The Tripartite Constitution**: `TRIAGE_POLICY.md` is functioning as human documentation, LLM context, and machine-readable JSON config simultaneously. This is a powerful "Policy-as-Code-as-Prompt" pattern that guarantees all three actors (Contributor, LLM, Gate Script) are aligned on the exact same ground truth.
- **Fail-Safe Asymmetry**: The system is designed to gracefully degrade to human review upon any uncertainty (malformed outputs, medium confidence). This asymmetric trust model is crucial for autonomous systems operating in public spaces.

**How This Could Evolve**:
- **From Reviewer to Collaborator**: Currently, Drawbridge passes judgment and suggests closures or auto-merges. It could evolve to actively engage with the contributor: if the deterministic gates fail due to a linting error or a missed test, Drawbridge could automatically push a fix commit to the contributor's PR (or suggest a `patch` file) instead of just rejecting it.
- **Dynamic Trust Scoring**: Instead of a binary "trusted" (MEMBER/COLLABORATOR) vs "untrusted" (FIRST_TIMER) tier, trust could be continuous. Contributors gain trust points per merged PR, slowly unlocking larger size caps and riskier file paths for autonomous merging.

**Mutations and Wild Ideas**:
- **Auto-Regression Testing of Policy**: Drawbridge could use its historical JSON artifacts (the inputs and verdicts) as a test suite. Whenever `TRIAGE_POLICY.md` is updated, it reruns historical PRs through the new policy to see if any past "escalate" would now be "autonomous", acting as a regression suite for community guidelines.
- **Ephemeral "Prove It" Environments**: For bugfix PRs, the pipeline could automatically construct and deploy a tiny reproducible environment (e.g., via WASM or a quick remote sandbox) demonstrating the "before" and "after" of the bug, linking it directly in the Zulip notification.

**Leverage Points**:
- The `fetch-item.sh` context generation. Currently, it pulls the diff and comments. If you expand this to include a static analysis "blast radius" (what functions call the changed functions), the Deep Reviewer's accuracy will skyrocket without needing to use Grep/Glob iteratively, saving tokens, latency, and increasing confidence.
- The `item.json` artifact allows integrating secondary checks easily in the future without hitting GitHub's API again. 

**The Flywheel**:
- **The Fast-Feedback Loop**: Immediate, polite, autonomous merges for small docs/bugfixes provide an incredible dopamine hit to contributors. This encourages more small, well-scoped PRs, which are exactly the kind of PRs the AI is best at reviewing. The more it auto-merges, the more contributors submit cleanly scoped work, reinforcing the pipeline's effectiveness and lowering maintainer burden.

**Concrete Suggestions**:

1. **High Value**: Output a structured Patch file from the Deep Reviewer.
   Instead of just commenting nits in `review.md` in lane 3, prompt the Opus model to output a `suggestions.patch` artifact. The maintainer can then apply the patch with a single command if they agree, turning a "needs work" PR into a "ready to merge" PR instantly.
   ✅ Confirmed — Compatible with the current artifact upload pipeline; Claude Opus is highly capable of generating unified diffs.

2. **Strategic**: Augment `fetch-item.sh` with Semantic Context.
   Inject a lightweight symbol map or a list of callers/callees for the modified files into `/tmp/drawbridge/`. The LLMs currently have to use tools (`Grep`, `Glob`) to discover this. Providing a static dependency map upfront gives the Judge and Reviewer instant architectural context.
   ✅ Confirmed — Can be done via existing AST tools without breaking the sandboxed read-only nature of the workflow.

3. **Experimental**: Policy Regression Suite.
   Create a new workflow that periodically pulls the last 100 closed PRs and their `item.json` data, running them through `gates.py` and the `Judge` to ensure policy tweaks don't inadvertently open security holes or dramatically shift the merge rate.
   ❓ Needs exploration — Requires building a storage mechanism for historical PR contexts (or fetching them dynamically), which might hit GitHub API limits or require an external datastore.

4. **Strategic**: Add a "Self-Correction" Lane before Escalate.
   If `gates.py` fails (e.g., CI is red or a required label is missing), allow the Deep Reviewer one attempt to comment on the PR explaining *how* the contributor can fix it (e.g., "It looks like the build failed because of X. Try doing Y."), before finally escalating to a maintainer.
   ⬇️ Lower priority than initially thought — The current pipeline values zero-noise maintainer escalation over automated back-and-forth, which could frustrate contributors if the AI hallucinates the fix. Keep it read-only and decisive for now.
