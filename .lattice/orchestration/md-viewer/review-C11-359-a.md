# C11-359 discovery review: Astra

Needs you: nothing. The synthesis seat owns reproduction and the repair brief.

## Verdict

**FAIL** at `b4f6a62ee5daed640c615e3910a7ee168858f27f`, PR #621, with one blocking compatibility finding (B1) and two non-blocking test-coverage findings (N1–N2).

- Reviewer: `agent:astra-md-review-359`.
- Review checkout: `/Users/atin/Projects/Stage11/code/c11-worktrees/md-review-359-a`, detached, initially and finally clean.
- Stacked diff: `git diff origin/md-viewer/C11-358-web-renderer...HEAD`; base and merge-base both `2c97338c4c995f6513e9f792bfca825935e9a00a`; tree `0ada3e7aa46fcedcfefaecc28bc8b5101b3d40d8`.
- GitHub PR head independently matched this commit; all three cheap CI checks were green. No merge or release action.
- Evidence: [review-C11-359-a-evidence.zip](./review-C11-359-a-evidence.zip). It contains exact patches, reviewer test probes, a run ledger, and all seven Atlas result manifests and build logs. Paths below are relative to the review checkout unless specified otherwise.

## Invariants

1. **Untrusted content stays contained.** Bundled code is the only executable code; document images stay within the pinned directory capability and permitted raster types; one percent-decode; no arbitrary navigation, windows, remote loads, or arbitrary file opening. Clicked links receive independent native validation.
2. **Compatibility and durable state survive.** Open, live reload, drop, raw-content queries, focus/flash, app-wide zoom, and description rendering retain their existing behavior. Scale/theme/typeface/outline restore independently, and invalid fields fall back without losing valid neighbors.
3. **Weight remains bounded without changing the reader's place.** Never-shown panels create no WebKit. All visible readers and four recently hidden readers survive. Eviction retains line/offset/mode/find/latest content and respects queries and focus.
4. **Native policy holds.** No new synchronous telemetry hop, agent-reachable modal, typing hot-path work, unguarded DEBUG logging, or unlocalized strings. Builds/tests remain on Atlas.

## Blocking finding

### B1 — P2: The replacement description parser drops supported Markdown behavior

**Locations:** `Sources/PanelTitleBarView.swift:289`, `:294`, `:307`, `:316`, `:336`, `:352`, `:360`, `:412`.

**Scenario:** An operator or agent supplies ordinary Markdown in an expanded panel description. This PR replaces `Markdown(sanitized)` with a line classifier and invokes the inline parser separately for each block. The resulting native blocks/text no longer preserve several ordinary constructs. This affects descriptions on all panel types, not only markdown panels.

| Construct and input (escaped newlines shown) | Actual result at the reviewed head | Expected existing behavior |
| --- | --- | --- |
| Setext headings: `Status\n======` and `Status\n------` | H1 becomes paragraph `Status ======`; H2 becomes a paragraph followed by a rule | Heading levels 1 and 2 |
| ATX closing hashes: `## Status ##` | Heading text includes the trailing `##` | Heading text `Status` |
| Wrapped list item: `- Deploy the change\n  after CI passes` | Continuation becomes an unrelated paragraph | One list item containing the continuation |
| Repeated ordered markers: `1. First\n1. Second` | Both visible markers are `1.` | Displayed sequence `1.`, `2.` |
| Reference link across blocks: `See [plan][p].\n\n[p]: https://example.invalid/plan` | Literal reference syntax and definition remain visible | Styled, inert label `See plan.`; no visible definition |
| Hard break: `First line  \nSecond line` | One line: `First line Second line` | Two displayed lines |

**Evidence/red:** Atlas invocation `5c5efe99beba4d6ca524e1026f236a1f` changed only `c11Tests/DescriptionSanitizerTests.swift`; all production files were exact-head originals. All six added behavioral tests failed, producing seven assertion failures; the 12 shipped description tests passed. Compilation succeeded and the log ends `** TEST FAILED **`. The same failures appeared in the earlier discovery runs. The functions under test supply the exact block structure, text and markers consumed by the native SwiftUI view; these are executable parser/output probes, not source-text assertions.

**Normal-use bar:** Blocking because ordinary, previously supported description content changes meaning or presentation. No hostile process or narrow timing is needed. The brief explicitly includes descriptions previously rendered by MarkdownUI in compatibility scope.

**Fix direction:** Parse the full sanitized document with a Markdown parser that retains block structure, reference definitions, ordered-list numbering, and hard breaks, then render its supported subset natively. Alternatively retain the existing description renderer until a compatible replacement exists. Preserve sanitization, inactive links and the height cap. Add the six regression probes to the shipped suite; do not patch each example with another isolated line regex.

## Non-blocking findings

### N1 — Native navigation cancellation has no effective regression test

**Locations:** `Sources/Panels/MarkdownWebRenderer.swift:323`; `c11Tests/MarkdownWebRendererTests.swift:45`.

**Scenario/evidence:** Replace `decisionHandler(initial ? .allow : .cancel)` with unconditional `.allow`. Atlas invocation `93b8168d935245f3a31ad7358a010bce` still passed all 71 of the owner's selected tests, including all five actual-WebKit tests. This invocation's sole overlay is `MarkdownWebRenderer.swift`; the exact mutation is in `navigation-mutant.patch`.

The hostile-content test examines the resulting DOM but does not attempt a prohibited navigation through the native delegate. Add real requests for a second entry load, arbitrary custom-scheme/HTTP/file destinations, subframes and new windows, with policy/canary observations. The original navigation guard remains present at the reviewed head; this surviving mutant is a coverage finding, not a demonstrated current escape.

### N2 — The eviction test does not establish that an unresolved query prevents teardown

**Locations:** `Sources/Panels/MarkdownRendererCache.swift:62`, `:89`, `:96`; `c11Tests/MarkdownWebRendererTests.swift:115`, `:126`, `:138`.

**Scenario/evidence:** Disable query-start pinning and epoch invalidation, and remove both `hasQueriesInFlight` checks around candidate capture/teardown. All five shipped WebKit tests, including `testEvictionWaitsForQueryAndRestoresPositionModeFindAndLatestContent`, still passed in Atlas invocation `a75b3fb2f5764ae4a538556a9158ffff`. That invocation is globally red only because it also carries the separate description probes. The patch preserves the existing query-finished repin logic; it specifically demonstrates the untested admission/epoch/recheck barriers.

A quick `visible()` call and an immediate non-nil assertion do not force a query to remain unresolved while asynchronous eviction gets a chance to finish. Hold a bridge Promise with an explicit started/release handshake, drive the cache to settled eviction pressure, prove the target remains resident, then release the Promise and prove teardown occurs. Also exercise a new query after position capture starts. The unmodified implementation contains these guards, so this is non-blocking under the normal-use bar rather than an observed production eviction failure.

## What I demonstrated

All compilation and tests below ran through `scripts/remote-build.sh --tag rv-359-a --mode test`. No local build or app launch occurred. No source changes, fixes, commits, pushes or tickets remain from this review.

| Atlas invocation | Source/test condition | Observed result |
| --- | --- | --- |
| `29bf4f1391664bb2a1c0a8a9acfda47b` | Clean pinned head; initial selected classes | 58 tests PASS. The initial BrowserLinkOpenSettings selection used the wrong target and ran no tests from that class; the later 71/78-test runs use the correct host target. |
| `568bf5f5d67246d996403f68ee7d6e3f` | Remove autosave fingerprint fields, hidden viewport retention, decoded-NUL link rejection; add first four description probes | All three intended guards went RED; description probes also RED. |
| `93b8168d935245f3a31ad7358a010bce` | Only navigation cancellation removed | All 71 shipped tests PASS: N1. The prior three guard mutations were restored. |
| `a75b3fb2f5764ae4a538556a9158ffff` | Query admission/epoch/recheck guards removed; six description probes | Five native WebKit tests PASS: N2. Description probes RED. |
| `c41de09e51fb444fb88fee9296873bad` | Add second path decode; remove raster sniffing; accept unknown theme/typeface; remove retention eligibility filter | RED for literal double-encoded filenames, disguised SVG-as-PNG, per-field name fallback, and model pin protection. 31 tests executed, 19 assertion failures. Combined retention mutation proves pin tests fire; it does not independently prove the visible-ID filter. |
| `281c592ef56d4feba89967793a95748a` | Every mutation/probe restored; clean exact head; owner's 71 plus seven title-bar render tests | **78 tests PASS**, `dirty=false`, `compile=ok`, `tests=ok`, `** TEST SUCCEEDED **`. |
| `5c5efe99beba4d6ca524e1026f236a1f` | Production exact head, only six added description probes | B1 independently RED: 18 tests, seven assertion failures. Probes removed afterward; final tracked/index diff empty. |

**Owner's key reds independently reproduced:**

- Removing the markdown preference fingerprint loop makes all four field-change assertions fail.
- Removing hidden viewport retention makes the narrow reader capture line **50** instead of **160**, return at line **52**, and restore offset **−70.890625** instead of **6.5625**. Restoring the guard returns the original test to green.
- Removing decoded control-character validation admits `hidden%00.md`; the link-policy test catches it.

The clean test run also exercises actual bundled Mermaid rendering, native image byte serving and WebKit decoding, live file-watcher reload with a one-pixel position assertion, pageZoom=1, source/read eviction restoration, find state, evicted model reload, script-handler release, durable preferences, malformed per-field values, and the model LRU. Static review covered the scheme's pinned root/openat/no-follow policy and cancellation tokens, delegate/message routing, existing zoom/drop/focus/raw-content wiring, the changed project membership and package cleanup, threat notes, and skill changes. All 14 added localization keys contain all six non-English locales; no interpolation tokens were introduced.

### Packaged and footprint evidence: inspected owner evidence, not a fresh reviewer run

I read the ticket, plan, eviction ruling, final test manifest/log, final packaged acceptance bundle, and the two physical-footprint JSON reports. I inspected the before/after eviction images. The reported physical totals recompute from their process rows:

| Phase | Origin/main baseline | Corrected reader |
| --- | --- | --- |
| Before | 231.40 MiB / 4 processes | 232.68 MiB / 5 processes |
| 20 never shown | 1464.89 MiB / 4 processes | 246.01 MiB / 5 processes |
| 20 visited | 1515.79 MiB / 4 processes | 933.15 MiB / 10 processes |
| 10 recreations | — | 939.28 MiB / 10 processes |

The owner reports 1160.8535 ms median recreation and matching line 77 / offset 130.828125 before/after eviction. These are sequential Debug guest samples with significant startup-load differences, not controlled production latency. Evidence IDs: `art_01M4DG9NY2DXAT21MVHAXH1J0E`, `art_01M4DGMBYCHJ1VY4NS4XVHDBMK`, `art_01M4DFDYJ4Q1FW52EZD0DQ58RR`, `art_01M4DGGFN5JB1PTZHAYZC6XB82`. The packaged app was built from a different commit with the same claimed source tree, rather than stamped with this PR head; the exact-head native tests are separately attributable.

Limits: I did not independently repeat packaged computer use, keyboard/drop input, restart persistence, physical memory measurement, attempted network egress, scheme-stop callback races, or hostile root-replacement runtime beyond the existing behavioral tests. No new current-head security escape or native lifecycle product failure was demonstrated. R1's renderer implementation remains separately reviewed, except for native integration and the included offset bridge.

## Cleanup and handoff

All temporary tracked edits were restored byte-for-byte. Detached HEAD and submodule pins are unchanged; no staged changes. Atlas tag `rv-359-a` and its per-tag test cache are removed after verifying no owned processes remain. No new panels, servers or sandbox guests were created. The initial review worktree is retained for the synthesis seat. This report and its evidence archive are the durable handoff; no owner message or ticket status change was made.
