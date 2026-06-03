## Evolutionary Code Review

- **Date:** 2026-05-03T17:49:00Z
- **Model:** Claude Opus (claude-opus-4-7[1m])
- **Branch:** c11-24/health-cli
- **Latest Commit:** cdc51c278ddf7bd31ac0c0c540b614d4ee5c1e92
- **Base:** origin/crash-visibility/launch-sentinel (5402d3fcd69c3ecb54ff440664fad51abf59f0e7)
- **Linear Story:** C11-24
- **Review Type:** Evolutionary / Exploratory

---

## What's Really Being Built

The stated feature is a CLI: `c11 health` reads four directories on disk, prints a table or JSON. Useful, narrow, ships clean.

What's actually being built is bigger and worth naming because nobody has yet:

**A passive observer of c11's own visible-from-disk crash surface.** Sentry, Apple, MetricKit, and c11's own sentinel each leave a different kind of breadcrumb. This branch is the first time c11 has a reader that *unifies* those breadcrumbs into a single timeline keyed only on filesystem state. The producers (Sentry SDK, ReportCrash, MXMetricManager, `LaunchSentinel.recordLaunchAndArchivePrevious`) all run independently and have no idea this reader exists. They never will. That's the design.

That separation — producers don't know about readers; readers are read-only of artifacts the producers happened to leave — is the real primitive. Everything in `Sources/HealthCommandCore.swift` is one instance of a pattern I'll call **Disk-Coupled Telemetry Aggregation (DCTA)**: producers write artifacts to well-known paths during their normal lifecycle; one or more readers walk those paths later, decoupled in time, decoupled in process, decoupled in trust. The producer can crash, the reader still works. The reader can never run, the producer is unaffected. The artifact format is the only contract.

This pattern matters beyond crashes. Once the operator gets used to `c11 health` answering "what happened to c11 lately?", they will want the same shape for "what's happening across my fleet of agents", "did this build run cleanly across the last 12 c11 launches", "what's the diff in crash-rate between my last two release tags". Those are the same query against the same disk surface, with different filters. The branch ships the engine for all of them.

**It's also the first deliberately offline-capable c11 CLI subcommand.** Most `c11 *` commands assume the c11 daemon is running and reachable via socket. `c11 health` does not. It works on a machine where c11 has never run, where the socket is dead, where the daemon crashed five minutes ago. That changes c11's deployment story — there's now a c11 surface that survives c11 itself. For an app whose value proposition is "the room for the operator:agent pair", being able to ask the room about itself even when the room can't answer through its own door is a quiet but real capability shift.

**For future-D11**: this branch defines a small portable substrate (rail enum, scan-with-since, filename grammar, JSON shape) that almost-but-not-quite is the right shape for D11 to inherit unchanged. The seams are mostly right. A few are wrong in ways small enough to fix now and large enough to matter later. Those are the leverage points below.

---

## Emerging Patterns

### Forming, should formalize

1. **Scanner-as-pure-function-of-(home, since).** All four `scanXxx(home:since:) -> [HealthEvent]` have the same signature. They're swappable. They produce the same output type. They can be parallelized, mocked, fuzzed, golden-tested against a tmp dir. This shape is good. It just isn't *named* yet — there's no `protocol Rail` or `struct ScannerSpec` — so the uniformity is by convention. Convention rots. Formalize it before the fifth rail makes the cracks visible.
2. **Filename-as-source-of-truth, body-as-best-effort.** `parseUncleanExitFile` and `parseMetricKitFilename` both encode this rule explicitly: timestamp comes from the filename grammar, the body is *additional metadata* that may be missing without invalidating the row. This is exactly right for crash-survival reasoning — a corrupted body must not be able to hide a crash. Make this an explicit doc comment on both producer and reader so nobody "fixes" it later.
3. **Bundle-id family iteration.** `scanSentryQueued` and `scanLaunchSentinel` both walk `Library/Caches/com.stage11.c11*` for "any sibling bundle". This is load-bearing for legacy `com.stage11.c11mux` data and dev/debug variants. The pattern is: enumerate top-level Caches, filter by prefix, descend. It's duplicated. It's also the *correct* boundary. Hoist it into a `forEachC11Bundle(home:)` helper and you've shaved 40 lines and made "what counts as a c11 bundle" a single edit.
4. **Read-only-of-someone-else's-format.** None of the four scanners parses the full payload. IPS reads the first JSON line. Sentry treats envelopes as opaque files. MetricKit reads the filename only. Sentinel reads filename plus a tiny header. This is intentional and correct: c11 is not a crash analyzer, it is a presence detector. The contract is "did the artifact exist", not "what's in it". Make this explicit in the file header — it's the principle that lets the rails shrink instead of grow.

### Anti-patterns forming, catch early

1. **The HealthEvent.Severity enum is a junk drawer.** It mixes orthogonal axes: `crash`/`hang`/`resource`/`mixed` are MetricKit categories; `queued` is a Sentry lifecycle state; `unclean_exit` is a sentinel finding; `diagnostic` is a fallback. `mixed` exists because MetricKit can combine categories in one filename. Adding a fifth rail means adding a sixth severity bucket that probably doesn't fit anyone's mental model. Today this works because the table column is wide and the JSON consumer does whatever. It will not survive contact with the next two rails.
2. **String-typed CLI errors meet stringly-typed JSON output.** `HealthCLIError` is a typed enum with `description` strings; rendering uses raw enum `rawValue`. The shape on the JSON wire (`"rail": "ips"`, `"severity": "crash"`) is implicit — there's no schema, no version field, no negotiated contract. Pin it now (just a `"schema_version": 1` key) and JSON consumers can be written without fear.
3. **`telemetryAmbiguityFooter` and `metricKitBaselineWarning` are sibling helpers with very different shapes.** One takes `(home, bundleVersion, metricKitCount, now)` and decides off disk + version compare. The other takes `(home, sentryCount)` and decides off disk + count. They read different paths, they do different filesystem walks, they use different early-return styles. Both fire from the same place in `runHealth`. Both will multiply. Without a uniform `Warning` type, the third one will look different again.
4. **Two-target source file via dual pbxproj entries.** `HealthCommandCore.swift` is added to both `c11` and `cmux-cli` build files (`DH001BF0...0718` and `DH001BF0...0719`). It works. It's also the second time in the codebase a file is dual-targeted (the first being `c11.swift` itself), and it's a quiet hint that the CLI/main split would be cleaner with a small shared "c11core" target the cmux-cli and the main app both link. Not urgent. But every dual-target file makes the case stronger.

---

## How This Could Evolve

### 1. Promote scanners to a `HealthRail` protocol

Today the four scanners are `func scanXxx(home:since:) -> [HealthEvent]`. The dispatcher `collectHealthEvents` is a four-arm `if rails.contains(.ips) { ... }` ladder. Adding a fifth rail means: edit the enum, edit the helper text, edit the dispatcher, edit the empty-result line, edit `renderHealthJSON`'s `railCounts`, edit help text, edit the warning footer wiring (if applicable), edit the help string `--rail <name>` enumeration, edit the `--rail` parser's diagnostic message. Eight edits in three files for one new rail.

```swift
protocol HealthRail {
    static var id: HealthEvent.Rail { get }
    static var displayName: String { get }
    func scan(home: String, since: Date) -> [HealthEvent]
    func warning(home: String, events: [HealthEvent], context: HealthWarningContext) -> String?
}
```

Register them in a static array. The dispatcher becomes a one-liner over the registry. The help text reads from the registry. The unknown-rail diagnostic enumerates the registry. Adding a fifth rail becomes: write one struct, append to the array. The error messages stay correct automatically.

This is the **single highest-leverage change** for v1.1, and it costs maybe 80 lines of refactor with no behavior change. The existing tests cover the surface; the refactor is mechanical.

### 2. Push `HealthEvent.Severity` to a per-rail enum

Each rail knows its own severity space. Sentry has `queued` (and someday `failed`, `retrying`). IPS has `crash`/`hang`. MetricKit has the category combinations. Sentinel has `unclean_exit` (and someday `clean`/`force_quit`/`sigkill` if it gets smarter).

Two reasonable evolutions:

- **Per-rail severity types**, exposed in JSON as `{"rail": "metrickit", "severity": "crash-hang-mixed"}`. Render layer flattens to one column for the table.
- **Severity-as-tags**, dropping the single-column model entirely: `{"tags": ["crash", "hang"]}` for the multi-category MetricKit case. This naturally handles "mixed" without a special bucket. The table can show the first tag and a `+N` indicator; the JSON gets richer.

The second is more honest to what's actually happening. It also subsumes a future "annotate this event with a build/commit" axis without another schema migration.

### 3. The fifth-rail seam: make adding one a 30-minute job

Concrete fifth rails the operator will plausibly want:

- **Console.app `log show --predicate 'subsystem CONTAINS "c11"'`** for the last hour. Reads from the unified log. No disk artifact unless you snapshot it. Different shape, but the filename-as-truth principle still holds — the line timestamp is the truth.
- **Spindump artifacts from `/Library/Logs/DiagnosticReports/Spin*.ips`** — Apple's "your app froze" record, separate from crash IPS. Probably 30 lines if `scanIPS` is generalized to a glob+predicate scanner.
- **Workspace snapshot lifecycle events.** c11's own workspace-snapshot writes/restores have a separate failure mode; reading `~/Library/Application Support/c11/workspace-snapshots/` for missing-or-corrupt files is a c11-specific health signal nobody else can produce.
- **Sentry envelope retention age.** Not "how many" but "how stale" — the oldest queued envelope. A queue that's been stuck for 7 days is a different problem from a queue with one fresh envelope.

Build the rail protocol with these in mind and the abstraction stays honest. Build it abstractly and you'll reinvent it when the second non-disk rail (log show) shows up.

### 4. JSON schema evolution and `schema_version`

The current JSON output has no version key. The first downstream consumer (`c11 health --json | jq`, a CI gate, a fleet-aggregator script) will lock in this shape. Add `"schema_version": 1` now, document the contract, and you have a clean lever to evolve later. Cost: one line. Value: every future change to the JSON shape stays backwards-compatible-by-choice rather than backwards-compatible-by-accident.

### 5. The fleet-mode latent in `home: String`

`collectHealthEvents(window:rails:home:)` already takes `home` as a parameter. The runtime test exercises that. What this means in practice:

```bash
c11 health --home ~atin/sshfs/laptop2 --since 24h
c11 health --home /Volumes/c11-fleet-archive/atin-imac/2026-05-03 --since-boot
```

is one CLI flag away. The Swift function is already pure-of-disk. Surface the flag, document it as "for fleet aggregation and post-mortem replay", and you've extended the use case from "one machine" to "any rsynced snapshot of one or more machines". The same rendering. The same JSON shape. Suddenly `c11 health` is a fleet inspector when you want it to be.

This is in the spirit of v1.1's deferred items but is *not* one of them — it's a smaller flag landing on top of an already-pure function.

---

## Mutations and Wild Ideas

### A. `c11 health --watch` — the live tail

A long-running variant: scan every N seconds, print only deltas, exit on Ctrl-C. Implementation: same scanner pure functions, a run-loop wrapper, a "previously seen paths" set keyed on `path` field. A different surface for the same engine. It would let an operator leave one pane running during a long agent session and *see* a crash the moment its artifact lands.

### B. Sentinel-as-fingerprint, not just timestamp

Right now sentinel events are `{version, build, commit}`. Add a sibling field `fingerprint = sha256(version + build + commit + bundle_id)` — ten bytes — and you can group/dedup unclean-exits across rails: "this sentinel event correlates to this Sentry envelope you queued under that exact build". You don't have to parse the envelope to do the correlation; you just need the fingerprint to be in both places.

The producer side is one line in `LaunchSentinel.recordLaunchAndArchivePrevious`. The reader can correlate without depending on it (best-effort, like the rest of the body parsing).

### C. `c11 health --producer-trace`

Inverts the read direction: instead of reading artifacts, dump where each rail *would* read from on this specific machine right now and whether the directory exists, the count of files, the most-recent mtime. Use case: setup debugging. "Why does my health command say zero metrickit?" → `--producer-trace` shows `~/Library/Logs/c11/metrickit: directory does not exist (MetricKit subscription has not yet fired on this machine)`.

This mutation costs almost nothing and turns the command into a self-diagnosing tool. The exact same scanners can be invoked in "describe-only" mode by passing a flag through to a producer-trace closure.

### D. The events-as-stream variant

`collectHealthEvents` returns `[HealthEvent]` — an array, eagerly built. For a v1 with hundreds of events that's fine. For "show me everything across the last 90 days on this machine and also the rsynced laptop2 snapshot" it's not. Yield events as they're scanned (`AsyncStream<HealthEvent>` or a callback-based scanner). The render layer can then emit incrementally. Useful for `--watch` (D above) and for the fleet-mode (#5 in evolution). Not needed for v1, worth keeping in mind so the v1 internals don't make it harder.

### E. The dual `c11 health` and `c11 reportz`

A whimsical one. `c11 health` is the sober timeline. `c11 reportz` (or `c11 ¬health`) takes the same data and generates a report in narrative form: "On May 1st, c11 unclean-exited twice during version 0.43.0. The next version, 0.44.0, ran clean for 36 hours before its first MetricKit hang at 14:30 on May 3." Same engine, different render. Operator-facing storytelling on top of disk artifacts. Probably not v1.1, but the engine you're building easily supports it.

### F. Replace the ad-hoc `parseFilenameSafeISO` with an `ISO8601FilenameStamp` helper

This 24-character grammar (`YYYY-MM-DDTHH-MM-SS.fffZ`) is used by *both* MetricKit producer/reader *and* sentinel producer/reader. Right now it's ad-hoc string surgery in `parseFilenameSafeISO`. Promote it to a struct with `init(_:Date)` and `init?(stamp: String)` and a `static let length = 24`. Producer and reader share the same source of truth. Add a fuzz test on it. This is the kind of small primitive that pays compound interest.

---

## Leverage Points

Where small changes create disproportionate value:

1. **Rail registry** (#1 above). 80 lines, no behavior change, fifth-rail cost drops by ~80%.
2. **`schema_version` in JSON**. One line, locks the contract, makes downstream consumers safe to write.
3. **`forEachC11Bundle(home:)` helper**. ~25 lines saved across `scanSentryQueued`, `scanLaunchSentinel`, `mostRecentSentinelMarker`, and `telemetryAmbiguityFooter`. Single source of truth for "what counts as a c11 bundle dir". Fixes the "what about com.stage11.c11.beta?" question once.
4. **Promote `parseFilenameSafeISO` and `filenameSafeISO` to a paired primitive shared with `LaunchSentinel`/`CrashDiagnostics`**. Producer and reader stop having two copies of the same 24-char rule. Today both halves are correct; tomorrow somebody changes one and not the other. Bind them now.
5. **`HealthEvent` gets a `bundleID` and `build` field (both optional)**. Three of the four rails already know this information. IPS knows `bundleID` from the first-line parse. Sentry encodes it in the path. Sentinel encodes it in the JSON body. MetricKit doesn't (yet) but the producer easily could. Once `HealthEvent` carries it, the JSON can group by build, the table can show a column, and the warning helpers stop having to re-walk the disk to find the version.
6. **A `HealthArtifact` (the file you scanned) vs `HealthEvent` (the row you emit) split**. Some artifacts produce multiple events (think: future MetricKit JSON parser). Some events come from multiple artifacts (think: dedup via fingerprint). Splitting the type now is cheap; splitting it later is migration.

---

## The Flywheel

The flywheel that wants to spin:

1. **More producers leave artifacts** → more rails to read → richer health surface. Each c11 subsystem (workspace snapshots, agent restarts, daemon lifecycle) can become a rail by writing well-known files. The skill teaches subsystem authors that "if it can fail, write a tiny artifact when it does, and `c11 health` will surface it." Subsystem authors don't need to know about `c11 health` to participate — they just need to write the artifact.

2. **More health visibility** → more confidence → more aggressive iteration. The operator can ship a release-candidate, watch `c11 health` over 24 hours, and decide whether to promote based on disk artifacts rather than vibes. This compounds with the version-bump baseline warning that's already in v1: that warning *itself* is a small engine for "did you just ship something risky and is it behaving."

3. **Fleet aggregation falls out** (#5 in evolution). `c11 health --home /path/to/snapshot` is one flag, and now the same skill works for "what happened on the CI runner last night" and "what's my dev laptop done since I left it." The engine doesn't care.

4. **Cross-rail correlation gets easier with each rail added** (mutation B, the fingerprint). Once two rails agree on a fingerprint shape, the third rail joins for free, and `c11 health --correlated` becomes a useful filter.

The thing that *would* break the flywheel: letting `HealthEvent.Severity` keep growing as a single junk-drawer enum. Every new rail will fight to add a case, the enum will accumulate special meanings, and at some point the table column gets wider than the user's terminal. That's why per-rail severity (or tags, my preference) before the fifth rail is the right call.

---

## Concrete Suggestions

### High Value (significant improvement, worth doing now or in v1.1)

1. **Add `schema_version: 1` to `renderHealthJSON` payload** (`Sources/HealthCommandCore.swift:1158-1167`). One line, locks the contract for downstream tools. ✅ Confirmed — the JSON is built as a `[String: Any]` dict; adding a key is trivial and the existing `testJSONShapeContainsTopLevelKeys` covers the structural check.

2. **Hoist the `Library/Caches/com.stage11.c11*` walk** into a private helper. Three call sites today: `scanSentryQueued` (line 609), `scanLaunchSentinel` (line 1023), `mostRecentSentinelMarker` (line 910), plus a fourth implicit call inside `telemetryAmbiguityFooter` (line 994) which hardcodes `com.stage11.c11` instead of iterating the family. This hardcoding is a latent bug: if someone runs the debug build only and the production cache never appears, the footer never fires. Fix the bug *and* deduplicate by extracting one helper. ✅ Confirmed — file structure supports it; existing tests cover all four call sites and would catch a regression.

3. **Promote scanners to a registry pattern** (the `HealthRail` protocol idea). Today: ~30 lines of dispatcher in `collectHealthEvents` + `runHealth` + `renderHealthJSON` + help text + error message that all enumerate the four rails. Tomorrow: a single registry array. Adding a fifth rail goes from eight edits to one. ❓ Needs exploration — a clean Swift implementation needs to handle the per-rail warning helper as a peer concept (some rails have warnings, some don't), so the protocol is `HealthRail + (optionally) HealthRailWarning`. Worth prototyping in a v1.1 follow-up branch.

4. **Pin the filename-safe ISO grammar as a shared primitive** (`Sources/HealthCommandCore.swift:705` and the matching producer in `Sources/SentryHelper.swift`). The current setup has two copies of the same 24-character rule, one in the reader and one in the producer. Make a `FilenameSafeISO8601` type that exposes both `format(_: Date) -> String` and `parse(_: String) -> Date?`. Use it from `LaunchSentinel.recordLaunchAndArchivePrevious`, `CrashDiagnostics.persist`, and the four reader sites. Add a round-trip property test. ✅ Confirmed — the producers and reader are clearly mirroring each other today; binding them at the type level removes an entire class of "we changed the producer and forgot the reader" bug.

5. **Fix `telemetryAmbiguityFooter`'s hardcoded bundle path** (`Sources/HealthCommandCore.swift:996`). The probe path is `\(home)/Library/Caches/com.stage11.c11/io.sentry`. On a machine where only the debug build (`com.stage11.c11.debug`) ever ran, this footer never fires, even though the operator is in the exact ambiguous state the footer is designed for. Fix: walk the bundle family the same way `scanSentryQueued` does, and fire the footer if *any* bundle has an empty `io.sentry/` and overall sentry count is zero. ✅ Confirmed — the bug is real in v1; there's a test (`testTelemetryAmbiguityFooterFiresWhenCacheExistsAndIsEmpty`) that uses `com.stage11.c11` exactly, which masks the issue. Add a test using `com.stage11.c11.debug` to lock the fix.

### Strategic (sets up future advantages)

6. **Add `bundleID` and `build` (optional) fields to `HealthEvent`**. Three rails know these already. JSON consumers want them. The "group by build, show me what 0.44.1 broke" story is one schema field away. ✅ Confirmed — additive change, the JSON test only asserts presence of a fixed key set so it won't break.

7. **Surface `home` as a CLI flag (`--home <path>`)**, with a short doc-comment describing fleet/snapshot use cases. The plumbing is already done — the function takes the parameter; the runtime test proves it works. ❓ Needs exploration — there's a privacy/safety dimension (running against an arbitrary path is fine, but document that nothing is *sent* anywhere, the read is purely local). Worth a mini design pass before shipping.

8. **Replace `HealthEvent.Severity` with per-rail severity tags**. Mutation #2 above. Most natural to do *with* the rail-registry refactor (#3) since each rail can declare its own severity space. ❓ Needs exploration — table rendering becomes more interesting, and downstream JSON consumers may have already locked the current shape; bundle this with `schema_version` bump (1 → 2).

9. **Add a `HealthArtifact` type distinct from `HealthEvent`**. Today they're 1:1, but only by coincidence; future MetricKit JSON parsing or correlation features want N:M. Cheap to split now, painful to split later. ⬇️ Lower priority than initially thought — without a concrete consumer of the split (e.g., correlation feature, MetricKit body parsing), this risks being a YAGNI abstraction. Reconsider when the second non-1:1 rail appears.

### Experimental (worth exploring, uncertain payoff)

10. **`c11 health --producer-trace`** (mutation C). Self-diagnosing setup tool. Cheap to build, very high "operator walks away knowing why" value the first time something is misconfigured.

11. **`c11 health --watch`** (mutation A). Tail-mode for live observation. Likely most valuable during release candidate testing or during a multi-hour agent run.

12. **Fingerprint correlation across rails** (mutation B). Useful only after two rails agree on the format, but trivial once they do. Producer-side cost is one line per rail.

13. **AsyncStream-based scanners** (mutation D). Only worth it once `--watch` or fleet-mode lands; until then, the array shape is fine. Note it as a known seam for v1.2.

14. **`c11 reportz`** (mutation E, the narrative renderer). Pure speculation, but the engine you have can produce it. Might be a fun day's work for an LLM-rendered report once there's enough data to narrate over.

---

## Validation Pass — Verified Suggestions

| # | Status | Note |
|---|--------|------|
| 1 | ✅ Confirmed | `renderHealthJSON` builds a `[String: Any]` payload at lines 1158-1167; one extra key added before serialization. Existing `testJSONShapeContainsTopLevelKeys` will not regress. |
| 2 | ✅ Confirmed | Three explicit call sites + one implicit one (in `telemetryAmbiguityFooter`); helper signature would be `func forEachC11Bundle(home:body:(URL, String) -> Void)` returning early on the standard "non-c11 prefix → continue" filter. |
| 3 | ❓ Needs exploration | The protocol abstraction is sound, but `metricKitBaselineWarning` and `telemetryAmbiguityFooter` have heterogeneous shapes; the protocol may need a `HealthRailWithWarning` extension or a parallel `HealthWarning` registry. Prototype before committing to a final shape. |
| 4 | ✅ Confirmed | The grammar is mirrored 1:1 between `LaunchSentinel.recordLaunchAndArchivePrevious` (producer) and `parseFilenameSafeISO` (reader). A shared type binding both is risk-reducing. |
| 5 | ✅ Confirmed | The hardcoded path at `Sources/HealthCommandCore.swift:996` does not match the bundle-family walk used elsewhere; this is a v1 footgun, not just an evolutionary nit. The test at `c11Tests/HealthFlagsTests.swift:1676-1689` happens to use `com.stage11.c11` and so doesn't expose it. |
| 6 | ✅ Confirmed | `HealthEvent` is a struct with named fields; adding optional fields is fully additive. `renderHealthJSON` and `renderHealthTable` would simply ignore them until updated. |
| 7 | ❓ Needs exploration | Trivial wiring; the work is in choosing the flag name, deciding interaction with `--since-boot` (which needs the *target machine's* boot time, which can't be read from a snapshot), and documenting the safety story. |
| 8 | ❓ Needs exploration | Bundle with `schema_version` bump; needs care for the table-rendering width. |
| 9 | ⬇️ Lower priority | Worth keeping in the back pocket but not pulling in until a concrete consumer demands it. |

---

## Most Exciting Opportunities

If I had to pick the three that would most change what `c11 health` becomes:

1. **The rail registry** turns a four-rail CLI into an extensible health platform. Every c11 subsystem becomes a potential rail with no central coordination. This is the pattern that lets future-D11 inherit the substrate cleanly.

2. **The shared filename-safe ISO primitive** is the small engineering move that prevents a production bug. Producer and reader stop drifting. It's the kind of work that doesn't show up in any release note but saves someone a 90-minute debug session in 2027.

3. **The fleet seam (`--home <path>`)** is already 90% there. Surfacing it makes `c11 health` work for a use case the branch wasn't designed for, with no architectural change. That's the cleanest possible signal that the abstraction is right.

The branch ships solidly as v1. These suggestions are how it grows — and the registry refactor is the one I'd reach for first in a v1.1.
