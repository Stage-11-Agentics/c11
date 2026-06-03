## Evolutionary Code Review
- **Date:** 2026-05-03T21:57:12Z
- **Model:** Codex (GPT-5)
- **Branch:** c11-24/health-cli
- **Latest Commit:** cdc51c278ddf7bd31ac0c0c540b614d4ee5c1e92
- **Linear Story:** C11-24
- **Review Type:** Evolutionary/Exploratory
---

Setup note: I reviewed HEAD against `origin/crash-visibility/launch-sentinel` as requested. Local `origin/dev` is not present, and I did not run `git fetch` / `git pull` because the wrapper instruction for this pass says the only allowed write is this review file. The local branch is seven commits ahead of the specified base.

## What's Really Being Built

This is not just a `c11 health` command. It is the first version of a **local evidence plane** for c11: a passive, file-system-backed way to turn the operator's machine into its own crash forensics index.

The important move is the shape of `Sources/HealthCommandCore.swift`: four independent rails collapse into one `HealthEvent` stream at `collectHealthEvents` (`Sources/HealthCommandCore.swift:50`). That is the primitive. Once c11 can normalize Apple IPS files, Sentry queue residue, MetricKit payload filenames, and launch-sentinel archives into one sorted stream, the next capability is not "more health output." It is **local incident reconstruction without trusting any one producer**.

That matters for future D11 because D11 should inherit the model, not the UI: local producers leave passive evidence, and a reader composes those crumbs into an operator-facing diagnosis. This branch starts that architecture in a small enough form to keep it honest.

## Emerging Patterns

The strong pattern is **producer contract by filename and path**. MetricKit already encodes its event type in the filename written by `CrashDiagnostics.persist` (`Sources/SentryHelper.swift:55`), launch sentinel encodes unclean exits in `unclean-exit-<stamp>.json` (`Sources/SentryHelper.swift:133`), and Sentry/IPS are discovered by product-scoped directories or names (`Sources/HealthCommandCore.swift:92`, `Sources/HealthCommandCore.swift:180`). That is an emerging convention: producers do not need a database if their disk layout is deliberate and parseable.

The second pattern is **pure core, thin CLI**. `CLI/HealthCommand.swift` only chooses the window, home, rail filter, and output format, then delegates to core functions (`CLI/HealthCommand.swift:7`). Tests exercise the runtime behavior through a temp home and rendered JSON/table output (`c11Tests/CLIHealthRuntimeTests.swift:21`, `c11Tests/CLIHealthRuntimeTests.swift:52`). This is the right direction.

The anti-pattern to catch early is **implicit context leaking into renderers and warnings**. The collector knows which rails were scanned, the CLI knows the requested window, JSON reports rail counts, but the table renderer receives only `[HealthEvent]` and warnings (`Sources/HealthCommandCore.swift:672`). That means the empty table line is fixed to "last 24h across ips, sentry, metrickit, sentinel" (`Sources/HealthCommandCore.swift:667`) even when the user ran `--rail sentinel` or `--since 30m`. That is a small v1 wrinkle, but architecturally it is the sign that a `HealthReport` object wants to exist.

## How This Could Evolve

### 1. Promote the output boundary from events to `HealthReport`

Right now the core returns raw events (`Sources/HealthCommandCore.swift:50`) and the CLI separately computes warnings (`CLI/HealthCommand.swift:35`). A more durable primitive would be:

```swift
struct HealthReport {
    let window: HealthCollectionWindow
    let rails: [HealthRailSnapshot]
    let events: [HealthEvent]
    let warnings: [HealthWarning]
}

struct HealthRailSnapshot {
    let rail: HealthEvent.Rail
    let count: Int
    let status: HealthRailStatus
    let scannedPaths: [String]
}
```

This is not polish. It changes the command from "print events" to "return an evidence snapshot." The table, JSON, and tests then render the same object. It also fixes the empty-result drift because the renderer can include the actual window and rail filter.

✅ Confirmed: `renderHealthJSON` already builds a report-like payload from `events`, `window`, `rails`, and `warnings` (`Sources/HealthCommandCore.swift:705`). The compatibility path is straightforward: create `HealthReport`, teach JSON/table renderers to accept it, then keep thin adapters if needed for existing tests.

### 2. Turn rails into data, not four conditionals

The four scanner functions are intentionally small and uniform, but the registry is still spread across:

- `HealthEvent.Rail.allCases` (`Sources/HealthCommandCore.swift:7`)
- `collectHealthEvents` conditionals (`Sources/HealthCommandCore.swift:56`)
- `parseHealthCLIArgs` rail parsing (`Sources/HealthCommandCore.swift:433`)
- help text (`CLI/c11.swift:7735`)
- warning wiring (`CLI/HealthCommand.swift:39`)

The next rail should not require touching five places. A minimal, non-bloated registry could live near the enum:

```swift
struct HealthRailDefinition {
    let rail: HealthEvent.Rail
    let scan: (HealthScanContext) -> [HealthEvent]
    let warnings: (HealthReportDraft) -> [HealthWarning]
}
```

The important choice is that this should be a table of functions, not a protocol hierarchy. Keep the ergonomic advantage of plain functions while making the set of rails composable.

✅ Confirmed: every current scanner already has the same effective shape: `home + since -> [HealthEvent]` (`Sources/HealthCommandCore.swift:92`, `Sources/HealthCommandCore.swift:180`, `Sources/HealthCommandCore.swift:322`, `Sources/HealthCommandCore.swift:594`). The only extra input needed is bundle version for MetricKit warning logic, which belongs in a context object rather than a scanner parameter.

### 3. Name the producer contracts

This branch relies on load-bearing disk contracts, but those contracts are currently embedded in comments and parser assumptions. Examples:

- MetricKit filename grammar is documented in `Sources/HealthCommandCore.swift:235` and produced by `Sources/SentryHelper.swift:55`.
- Launch sentinel archive shape is documented in `Sources/HealthCommandCore.swift:590` and produced by `Sources/SentryHelper.swift:126`.
- Sentry deliberately treats regular files as opaque evidence (`Sources/HealthCommandCore.swift:175`).

Future D11 wants these contracts as first-class concepts: "this producer emits passive local evidence at this path, with this retention and this parser." That could be a small internal `HealthEvidenceContract` struct used only for JSON `rail` metadata and developer docs. The payoff is that adding a fifth rail becomes a contract addition, not tribal memory.

✅ Confirmed: the producer and consumer are already close enough to link without changing `Sources/SentryHelper.swift`, which this review intentionally does not propose modifying. A consumer-side contract table can cite the existing producer paths and grammar.

## Mutations and Wild Ideas

**Health as black-box flight recorder.** Keep the CLI passive, but let the evidence model become a local "flight recorder" abstraction: all c11 subsystems that can leave passive forensic residue get one rail definition. The operator asks one question: "What happened recently?" The implementation remains boring files and parsers.

**Evidence confidence.** Add a field like `confidence: confirmed | inferred | ambiguous`. Sentinel `unclean_exit` is confirmed evidence of prior non-clean shutdown; Sentry queued files are inferred queued telemetry; an empty Sentry cache warning is ambiguous. This would make the JSON more useful to agents without changing the human table much.

**Ritual mode.** The operator's daily command could eventually be `c11 health --brief`, returning one stable, scannable paragraph: window, counts, newest event, warnings. Not a notification, not sidebar reporting, just a better terminal rhythm for repeated checks.

**Forensics recipes.** A future `--explain <event-id>` could render a rail-specific explanation from the contract table: where the evidence came from, what it proves, and what it does not prove. This is especially useful for Sentry and MetricKit, where "no rows" can mean several different things.

## Leverage Points

The highest leverage point is the renderer boundary. Once table and JSON consume one `HealthReport`, every future rail gets counts, warnings, and empty-state semantics for free. The current JSON function is already doing half of this work (`Sources/HealthCommandCore.swift:705`), while the table path is still event-only (`Sources/HealthCommandCore.swift:672`).

The second leverage point is scanner uniformity. All four rails already follow the same mental contract: enumerate candidate files, parse minimal metadata, filter by `since`, emit `HealthEvent`. Formalizing that as a tiny registry makes the next rail boring.

The third leverage point is test fixture generation. `CLIHealthRuntimeTests.scaffoldAllRails` (`c11Tests/CLIHealthRuntimeTests.swift:176`) is already an implicit synthetic evidence factory. If it becomes a small helper type, future rail tests can be added without copying temp-home scaffolding across test files.

## The Flywheel

There is a good flywheel here:

1. Producers leave small, passive, local evidence.
2. `c11 health` normalizes it into one report.
3. Tests encode each producer contract with fixtures and temp homes.
4. New incidents teach c11 a new passive rail or warning.
5. The next incident is easier to reconstruct.

The compounding effect depends on not overfitting to today's four rails. The branch is close: it has the right pure functions and tests. The next evolution should make the "rail" abstraction just explicit enough that future evidence sources inherit the same path.

## Concrete Suggestions

1. **High Value: Introduce `HealthReport` and render both table and JSON from it.**
   - Move window, selected rails, per-rail counts, events, and warnings into one value.
   - Change `renderHealthTable` so empty output reflects the actual requested window and rail filter, instead of always using the default line at `Sources/HealthCommandCore.swift:667`.
   - Keep `renderHealthJSON`'s shape stable by serializing the same report fields it already emits at `Sources/HealthCommandCore.swift:729`.
   - ✅ Confirmed: compatible with current architecture. The CLI already constructs `window`, `rails`, `events`, and `warnings` before printing (`CLI/HealthCommand.swift:27`, `CLI/HealthCommand.swift:53`).

2. **High Value: Add a tiny rail definition table.**
   - Keep the scanners as free functions.
   - Add a table mapping each `HealthEvent.Rail` to its scanner and warning contributors.
   - Use the table for collection, CLI rail validation, JSON counts, and possibly help text generation.
   - ✅ Confirmed: scanner signatures are already uniform enough to adapt without broad changes. Risk: do not let this turn into a large protocol framework; a table is enough.

3. **Strategic: Add `HealthScanContext`.**
   - Include `home`, `now`, `bundleVersion`, and maybe `fileManager`.
   - Use it in `runHealth`, scanners, and warning helpers so all time and environment decisions come from one place.
   - This improves deterministic tests and prepares for future D11 runners that may scan alternate homes or mounted bundles.
   - ✅ Confirmed: current call sites already pass `home` and `since` explicitly (`Sources/HealthCommandCore.swift:50`), while `runHealth` owns `now` and bundle version (`CLI/HealthCommand.swift:17`, `CLI/HealthCommand.swift:37`). The migration is mechanical.

4. **Strategic: Track rail status, not just event count.**
   - Add statuses like `missing`, `empty`, `scanned`, `permissionDenied`, and `parseSkipped`.
   - Surface them primarily in JSON; table can stay compact.
   - This preserves passive behavior while making "0 events" more interpretable.
   - ✅ Confirmed: current scanners intentionally swallow missing directories and parse failures (`Sources/HealthCommandCore.swift:97`, `Sources/HealthCommandCore.swift:326`, `Sources/HealthCommandCore.swift:598`). That behavior is correct for v1, but the status can be recorded without turning it into a fatal error. Risk: keep status coarse to avoid recreating the deferred debug-log gap work.

5. **Strategic: Promote test scaffolding into a reusable synthetic evidence builder.**
   - Extract the temp-home file creation currently inside `CLIHealthRuntimeTests.scaffoldAllRails` (`c11Tests/CLIHealthRuntimeTests.swift:176`) into a test helper.
   - Give each rail a helper like `writeIPS`, `writeSentryEnvelope`, `writeMetricKit`, `writeSentinelArchive`.
   - This makes the fifth rail cheaper to test and keeps fixture behavior consistent.
   - ✅ Confirmed: every parser test currently repeats temp-home creation (`c11Tests/HealthIPSParserTests.swift:132`, `c11Tests/HealthSentryParserTests.swift:100`, `c11Tests/HealthMetricKitParserTests.swift:103`, `c11Tests/HealthSentinelParserTests.swift:105`). This can be centralized without touching production code.

6. **Experimental: Add evidence confidence to JSON.**
   - Example: sentinel `unclean_exit` = `confirmed`, Sentry queued file = `inferred`, telemetry empty warning = `ambiguous`.
   - Helps agents reason over output without brittle string parsing.
   - ❓ Needs exploration: the current `HealthEvent` is intentionally small (`Sources/HealthCommandCore.swift:6`). This is worth trying only after `HealthReport` exists.

7. **Experimental: Add `--brief` for the daily operator rhythm.**
   - Output one compact summary line from `HealthReport`: window, counts, newest event, warnings.
   - This is still passive CLI behavior, not active reporting.
   - ❓ Needs exploration: probably best deferred until the table/report boundary is cleaner.

## Validation Pass

- ✅ Confirmed: `HealthReport` fits the existing data flow. `runHealth` already gathers all needed report inputs before rendering (`CLI/HealthCommand.swift:27`, `CLI/HealthCommand.swift:33`, `CLI/HealthCommand.swift:39`).
- ✅ Confirmed: a rail definition table is compatible with the four current scanner functions because they share the same minimal input and output shape.
- ✅ Confirmed: `HealthScanContext` would reduce implicit dependencies without changing passive semantics. It does not require touching `LaunchSentinel` or `CrashDiagnostics`.
- ✅ Confirmed: rail status can be implemented as observability of scanner outcomes, not as new side effects. It remains read-only and socket-free.
- ✅ Confirmed: test helper extraction is compatible with the project's test-quality policy because tests would still exercise runtime behavior through temp-home files, not grep project metadata.
- ❓ Needs exploration: evidence confidence and `--brief` should wait until the report model exists, otherwise they add surface area before the core abstraction is ready.

## Bottom Line

The branch is building a passive local evidence plane. The next best move is not to add more warnings or a flashier command. It is to make the report object explicit, make rails data-driven, and let every future diagnostic source plug into the same small contract.

