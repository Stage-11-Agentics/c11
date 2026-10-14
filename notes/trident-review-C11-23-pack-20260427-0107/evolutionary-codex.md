## Evolutionary Code Review
- **Date:** 2026-04-27T05:17:03Z
- **Model:** Codex / GPT-5
- **Branch:** c11-23-ai-usage-monitoring
- **Latest Commit:** 6ed68713d5cd20a1026b6225fb285b2210a43787
- **Linear Story:** C11-23
- **Review Type:** Evolutionary/Exploratory
---

## What's Really Being Built

This is not just sidebar usage monitoring. This branch is creating the first slice of a **local agent ledger**: c11 reads the residue that agent tools already leave on disk, normalizes it into windows, and turns it into operator-facing economic telemetry without asking vendors for permission.

That position matters. Vendor dashboards can tell an operator what one provider thinks they spent. c11 can eventually tell them what the whole working room is burning across Claude, Codex, future CLIs, panes, workspaces, branches, and spawned agents. The stronger name for the capability is **cross-tool agent observability**, with cost as the first metric.

The local-first pivot is the architectural unlock. `ClaudeLocalUsageFetcher` reads `~/.claude/projects` at [ClaudeLocalUsageFetcher.swift:68](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:68), and `CodexLocalUsageFetcher` reads `~/.codex/state_5.sqlite` at [CodexLocalUsageFetcher.swift:84](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:84). The privacy doc now names only status-page hosts while usage is local at [privacy-endpoints.md:16](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/docs/privacy-endpoints.md:16). That changes the product posture from "credentialed API client" to "local observability surface."

## Emerging Patterns

**The provider object is becoming a capability manifest.** `AIUsageProvider` currently holds credentials, status metadata, and fetch closures at [AIUsageProvider.swift:56](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageProvider.swift:56). The branch overloads `credentialFields.isEmpty` to mean local-only/no-Keychain/no-secret UI in `AIUsageAccountStore`, `AIUsagePoller`, and `AIUsageEditorSheet`. That works, but it is an unnamed capability system trying to exist.

**Window aggregation is duplicated provider logic that wants to be a primitive.** Claude computes cutoffs, filters entries, sums tokens, costs entries, derives utilization, and sets reset time at [ClaudeLocalUsageFetcher.swift:16](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:16). Codex repeats the same shape at [CodexLocalUsageFetcher.swift:36](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:36). This is the strongest abstraction signal in the branch: providers should produce normalized usage events; shared code should produce windows.

**Static fetcher enums are the first generation of adapters.** `ClaudeLocalUsageFetcher` and `CodexLocalUsageFetcher` are namespaced static functions. That is fine for two built-in readers, but it makes test fixtures, custom roots, and future data sources harder than they need to be. The next mutation is reader instances configured with paths and clocks.

**The UI already treats cost as first-class, but the model has no provenance.** `AIUsageWindow` has `tokensUsed` and `costUSD` at [AIUsageProvider.swift:3](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageProvider.swift:3), and the footer displays dollars when utilization is zero at [AIUsageFooterView.swift:71](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/UI/AIUsageFooterView.swift:71). The next useful field is not another number; it is confidence/provenance: measured, estimated, blended, or unknown.

**Tests did not evolve with the local-provider model.** The test file still asserts that Claude and Codex UI providers have credential fields at [AIUsageTests.swift:271](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:271), [AIUsageTests.swift:426](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:426), and [AIUsageTests.swift:434](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:434). Evolutionary point: the branch needs a fixture-driven local-source test harness, not more API parser tests.

## How This Could Evolve

The natural architecture is:

1. Local readers produce `AIUsageEvent` values: timestamp, provider, model, token buckets, cost estimate, source path/thread id, project/workspace hint.
2. A shared `AIUsageWindowAggregator` turns events into arbitrary windows.
3. Providers declare capabilities: credentials, local auto-detect, status page, pricing policy, supported windows.
4. `AIUsagePoller` owns snapshots and aggregate views across accounts.
5. c11 exposes the same usage state to agents through the socket/CLI.

That would turn C11-23 from a feature into a primitive. New tools would become data-source plugins instead of bespoke provider implementations.

In six months, the good version is a local ledger that answers: "What did this workspace cost? Which model burned it? Which branch caused the spike? Which panes are active right now? Should I spawn another expensive agent?" The poor version is a growing list of hardcoded fetchers, each re-implementing windows, pricing, path detection, and local error handling.

## Mutations and Wild Ideas

**Agent Ledger.** Persist normalized usage events in a c11-owned local store after reading upstream files. That makes trends, deltas, and branch-level attribution cheap without repeatedly scanning every upstream log.

**Budget Governor.** Add soft and hard thresholds per workspace/session. When aggregate session cost crosses a threshold, c11 can raise a sidebar warning, write metadata, and let agent skills learn to check budget before spawning more work.

**Project Heatmap.** Claude JSONL files are discovered by traversing project directories at [ClaudeLocalUsageFetcher.swift:75](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:75). Keeping the file path on each event would unlock per-project cost attribution almost for free.

**Burn Rate, Not Just Total Spend.** The sorted entries at [ClaudeLocalUsageFetcher.swift:122](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:122) and the SQL ordering at [CodexLocalUsageFetcher.swift:93](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:93) already provide enough time structure to compute tokens/minute and dollars/hour for the live session.

**Local Reader Marketplace.** Gemini, Kimi, OpenCode, Aider, and future agent CLIs can be added as local readers. The rule becomes: if a tool writes timestamped usage data locally, c11 can display it.

**Pane-Scoped Economics.** If agents self-report through c11 metadata or a future socket command, usage can be attributed to a surface, not only a provider. That would let the operator see which running pane is expensive right now.

## Leverage Points

The highest-leverage move is to split "read source data" from "aggregate windows." The code already shows this seam twice. Once extracted, every future provider only needs to answer "where are my events?"

The second leverage point is provider capability metadata. Today a local provider is inferred from empty credential fields. Naming that concept lets registration, editor UI, Keychain behavior, auto-detection, and docs all move from scattered conditional code into provider declarations.

The third leverage point is aggregate snapshots. `AIUsagePoller.snapshots` already has every account at [AIUsagePoller.swift:21](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsagePoller.swift:21). A cross-provider total requires no new source readers, only a computed projection.

## The Flywheel

The flywheel is: **more local readers -> better aggregate truth -> stronger operator decisions -> more reason to wire every agent tool into c11.**

Claude and Codex are enough to prove the loop. The next provider makes the aggregate view meaningfully better. The one after that makes vendor dashboards feel incomplete. Once budget and burn-rate signals exist, agents have a reason to consume the same data, which justifies socket/metadata exposure. Then usage monitoring becomes part of orchestration, not just display.

This flywheel only spins if adding a provider gets cheaper. Hardcoded `AIUsageRegistry.all` at [AIUsageRegistry.swift:7](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageRegistry.swift:7) and hardcoded auto-registration at [AIUsageAccountStore.swift:177](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageAccountStore.swift:177) are acceptable now, but they are the first friction points to remove.

## Concrete Suggestions

### High Value

1. **Extract `AIUsageEvent` plus a shared window aggregator.** ✅ Confirmed — verified this would work.

   Create a normalized event type, for example:

   ```swift
   struct AIUsageEvent: Sendable, Equatable {
       var timestamp: Date
       var providerId: String
       var model: String
       var inputTokens: Int
       var outputTokens: Int
       var cacheCreationTokens: Int
       var cacheReadTokens: Int
       var totalTokens: Int
       var estimatedCostUSD: Double
       var sourceHint: String?
   }
   ```

   Then move the duplicated cutoff/filter/sum/reset logic from [ClaudeLocalUsageFetcher.swift:16](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:16) and [CodexLocalUsageFetcher.swift:36](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:36) into a shared `AIUsageWindowAggregator`. Claude and Codex already produce timestamped entries with model and token counts, so the migration is mechanical.

   Dependencies/risks: keep provider-specific cost functions near the provider at first; only aggregate after each event has a cost. This avoids prematurely designing a universal pricing engine.

2. **Move local reader work off the main actor and make that the adapter contract.** ✅ Confirmed — verified this would work.

   `AIUsagePoller` is `@MainActor` at [AIUsagePoller.swift:17](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsagePoller.swift:17), and it calls `provider.fetchUsage` from [AIUsagePoller.swift:197](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsagePoller.swift:197). Claude reads whole files at [ClaudeLocalUsageFetcher.swift:92](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:92); Codex opens and steps SQLite synchronously at [CodexLocalUsageFetcher.swift:88](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:88).

   The evolutionary fix is not just `Task.detached` in two places. Define the rule: provider readers may do blocking local I/O, but they must execute off-main and return normalized events. That keeps the typing-latency contract intact as more local tools join.

   Dependencies/risks: cancellation from `runWithTimeout` at [AIUsagePoller.swift:246](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsagePoller.swift:246) should still cancel waiting tasks. For large JSONL reads, a future streaming reader will respond to cancellation better than whole-file reads.

3. **Introduce explicit provider capabilities: `isLocal`, `autoDetect`, and `usageSourceDescription`.** ✅ Confirmed — verified this would work.

   Add capability fields or computed properties to `AIUsageProvider` at [AIUsageProvider.swift:56](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageProvider.swift:56). Then replace scattered `credentialFields.isEmpty` checks in [AIUsageAccountStore.swift:52](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageAccountStore.swift:52), [AIUsagePoller.swift:186](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsagePoller.swift:186), and [AIUsageEditorSheet.swift:29](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/UI/AIUsageEditorSheet.swift:29).

   Move Claude/Codex path probes out of `AIUsageAccountStore.load()` at [AIUsageAccountStore.swift:177](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsageAccountStore.swift:177) and into provider declarations. This makes the third provider a provider-file change instead of a store change.

   Dependencies/risks: `AIUsageProvider` is `Sendable`, so closures should be `@Sendable`. Auto-detect closures must stay cheap because `load()` is synchronous today.

### Strategic

4. **Add cross-provider aggregate windows to `AIUsagePoller`.** ✅ Confirmed — verified this would work.

   `snapshots` already holds the account windows at [AIUsagePoller.swift:21](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsagePoller.swift:21), and the poller filters it to live accounts at [AIUsagePoller.swift:219](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/AIUsagePoller.swift:219). Add computed projections such as `aggregateSessionTokens`, `aggregateSessionCostUSD`, and `aggregateWeekCostUSD`.

   This enables a single footer total row when multiple accounts are active. More importantly, it creates the internal API future budget and burn-rate features will consume.

   Dependencies/risks: aggregating `utilization` percentages is meaningless unless limits share a denominator. Aggregate tokens and cost first; only compute aggregate utilization if there is an explicit total budget.

5. **Make local fetchers fixture-driven and add real local-reader tests.** ✅ Confirmed — verified this is needed.

   The fetchers hardcode `NSHomeDirectory()` at [ClaudeLocalUsageFetcher.swift:68](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:68) and [CodexLocalUsageFetcher.swift:84](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:84), which blocks clean tests. Meanwhile existing tests still encode the old credential-provider world at [AIUsageTests.swift:271](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/c11Tests/AIUsageTests.swift:271).

   Introduce instance readers with injected roots/db URLs and clocks. Then add tests that create temporary JSONL and SQLite fixtures, exercise malformed rows, timestamp units, cost propagation, and window cutoffs through executable paths.

   Dependencies/risks: project policy says do not run local tests here; this suggestion is about improving CI coverage, not running it in the review.

6. **Separate pricing into a small catalog with provenance.** ❓ Needs exploration — promising but needs prototyping.

   Claude pricing lives in branches at [ClaudeLocalUsageFetcher.swift:125](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:125), and Codex uses blended family rates at [CodexLocalUsageFetcher.swift:116](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/CodexLocalUsageFetcher.swift:116). Move these into a small `AIUsagePricingCatalog` that returns both cost and accuracy metadata: exact per-token-bucket, blended estimate, fallback estimate, unknown.

   The UI can then say "estimated" only when it should, and docs can explain why Codex costs are approximate. This also prevents future fetchers from scattering pricing tables across source files.

   Dependencies/risks: pricing changes over time. Keep the catalog static for now; do not add network price fetching until there is a clear update workflow.

### Experimental

7. **Expose usage to agents through c11 CLI/socket.** ❓ Needs exploration — compatible with the architecture, but the socket command surface needs a separate design pass.

   Once `AIUsagePoller` has aggregate projections, add a read-only command such as `c11 usage snapshot --json`. Agents could check current burn before launching expensive work. Later, a write command could let tools without local logs self-report usage events.

   Dependencies/risks: socket commands have a threading policy in this repo. Any telemetry command should parse off-main and schedule only minimal UI/model work on main.

8. **Capture project/workspace attribution.** ❓ Needs exploration — source data exists for Claude, Codex needs schema inspection.

   Claude's enumerator sees the JSONL file URL at [ClaudeLocalUsageFetcher.swift:89](/Users/atin/Projects/Stage11/code/c11-worktrees/c11-23-ai-usage-monitoring/Sources/AIUsage/ClaudeLocalUsageFetcher.swift:89). Store a sanitized project/path hint on the normalized event. Codex threads may also have title/path/session columns; inspect `state_5.sqlite` before designing the field.

   This would unlock "cost by repo/branch/workspace" and make c11's own workspaces the natural unit of spend.

9. **Persist a c11-owned historical usage index.** ⬇️ Lower priority than initially thought.

   A local `usage_history.sqlite` would enable trends and anomaly detection, but it should wait until normalized events and reader tests exist. Without those, persistence risks fossilizing the first draft of the schema.

## Validation Notes

- Branch setup: `git fetch origin` succeeded, `git pull --ff-only origin c11-23-ai-usage-monitoring` reported already up to date. `origin/dev` does not exist on this remote, so I used `origin/main` for the three-dot diff, matching the context document's stated base.
- Scope checked with `git log --oneline origin/main..HEAD` and `git diff origin/main...HEAD --stat`.
- No local tests were run, per the project testing policy.
- Existing untracked review directories under `notes/` were left untouched except for this required output file.
