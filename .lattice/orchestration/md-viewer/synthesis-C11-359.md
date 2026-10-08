# C11-359 synthesis: Fable (PASS) + Astra (FAIL), PR #621

Needs you: nothing. One product question rides along for the Orchestrator (Q1 below); it does not gate the repair.

- Seat: `agent:claude-md-synth-359` (Claude Opus).
- Head attested: `b4f6a62ee5daed640c615e3910a7ee168858f27f` (worktree `c11-worktrees/md-synth-359`, detached, clean before and after).
- Diff: `origin/md-viewer/C11-358-web-renderer...HEAD`, merge-base `2c97338c4c`. R1's branch has since moved to `8ad5469bef`.
- Inputs: `review-C11-359-f.md`, `review-C11-359-a.md` + evidence zip, `briefs/review-C11-359.md`, `briefs/r2-eviction-ruling.md`, ticket.

## Verdict: FAIL

One blocking finding (B1). One required landing step (R1-REBASE): it is not a defect at this head, but this PR cannot land without it. Two coverage items to fix in place, because the owner is already editing those tests. Everything else goes to the hardening ticket.

## My reproductions

All builds and tests ran on Atlas through `scripts/remote-build.sh`, in throwaway worktrees off this head. My own worktree was never edited. Scratch worktrees are removed, and Atlas tag `syn-359-rb` is freed. I keep `syn-359` for the verify round.

| Atlas invocation | Tree | What ran | Result |
|---|---|---|---|
| `2d10761d88644119bd00a6684ca1f2a6` | exact head + Astra's six description probes + my multi-line eviction probe (tests only) | `DescriptionSanitizerTests`, `MarkdownWebRendererTests` | **RED as expected.** 18 description tests, 7 failures: all six B1 probes. The eviction probe restores the reported line (145), but its text row sits at **−52.34 px** where **−7.25 px** was requested, both before eviction and after restore. |
| `0681d96cb8b44f9187b8ac5e10c66b20` | head rebased onto `origin/md-viewer/C11-358-web-renderer` (`8ad5469bef`), scratch `410518fe48`, + the same eviction probe | Owner's 8-class slice | **72/72 PASS**, `** TEST SUCCEEDED **`. Rebase is clean; the duplicated offset commit `b4f6a62ee5` (same patch-id as R1's `16176abc6f`) is dropped automatically. |
| `737763b77b2443108235f756d26a0ab8` | exact head with guards removed: navigation always `.allow`; bridge frame/origin check; zoom-key guard; CSP response header; query pin and epoch; both in-flight checks | Owner's 8-class slice | **71/71 PASS**. Every guard removed, nothing goes red. |

Plus a local standalone `swiftc` probe of the exact production `titleBarDescriptionBlocks`/inline parse (pure functions, no app build). It reproduces all six B1 cases and shows that Foundation's full-syntax parser renders each one correctly (fix direction below).

## Validated findings

### B1: BLOCKING. The native description renderer changes ordinary Markdown that MarkdownUI rendered correctly on base
Source: Astra B1. Fable's invariant (b) passed this path on the four shipped tests, which do not cover these constructs.

- **Where:** `Sources/PanelTitleBarView.swift:289` (`titleBarDescriptionBlocks`, a line classifier), `:294` (paragraph lines joined with a space), `:345` (ordered marker copied verbatim), `:360` (inline parse run per block, so reference definitions never meet their uses).
- **Scenario:** an agent or the operator writes ordinary Markdown in a panel description (any panel type), and the operator expands it. Base rendered it through MarkdownUI (`Markdown(sanitized)` with the compact theme and a discarding `openURL`).

| Input | This head | Base (MarkdownUI / CommonMark) |
|---|---|---|
| `Status\n======` | paragraph `Status ======` | H1 `Status` |
| `Status\n------` | paragraph + rule | H2 `Status` |
| `## Status ##` | H2 `Status ##` | H2 `Status` |
| `- Deploy the change\n  after CI passes` | list item + separate paragraph | one list item |
| `1. First\n1. Second` | `1.` `1.` | `1.` `2.` |
| `See [plan][p].\n\n[p]: https://…` | literal `[plan][p]` and the definition line visible | `See plan.` (inert) |
| `First line  \nSecond line` | one line | two lines |

The common description shape (one paragraph plus a `Lineage:` line) renders the same as on base. I checked that explicitly.
- **Reproduced:** Atlas `2d10761d…` (7 assertion failures, production code unmodified) and the local probe.
- **Why it blocks:** behavior that worked on base regresses for ordinary content. The review brief names "panel descriptions that MarkdownUI used to render" in compatibility scope.
- **Fix direction:** stop classifying lines. Parse the sanitized text once with `AttributedString(markdown:options: .init(interpretedSyntax: .full))` (Foundation, backed by swift-cmark, no new dependency). Group runs by the block identity of `presentationIntent.components.first` and map each group to the existing `TitleBarDescriptionBlock` cases:
  - `.header(level)` maps to `.heading`.
  - `.listItem(ordinal)` under `.orderedList` maps to marker `"\(ordinal)."`. Ordinals honor the start number: `3. a\n4. b` gives 3 and 4.
  - `.unorderedList` maps to `•`. Depth is the count of list components.
  - `.blockQuote` maps to `.quote`.
  - `.thematicBreak` maps to `.rule`. It arrives as a run containing U+2E3B; drop the character.
  - `.codeBlock` (indented code) becomes monospace or is dropped; pick one and test it.
  - Hard breaks arrive as a `"\n"` run and soft breaks as `" "`. Reference links resolve. Paragraph-interruption rules match CommonMark (`Step\n2. two` stays a paragraph).

  Keep `sanitizeDescriptionMarkdown`, URL stripping on links, the code tint, and the height cap. Add Astra's six probes (`description-only-probes.patch` in her evidence zip) to `DescriptionSanitizerTests`, plus cases for an ordered start number, a rule between paragraphs, and quote soft breaks. Do not add another per-construct line regex.

### R1-REBASE: REQUIRED TO LAND. Rebase onto R1's repaired bridge and re-prove eviction restore on an interior line
Source: the synthesis brief's own check.

- **At this head, R2's restore is self-consistent but inherits R1's interpolation.** Native code passes the bridge's own `visible()` → `(line, offset)` back to `scrollToLine` (`MarkdownWebRenderer.swift` restore path), so the reader returns to the pixel it left. But the R1 bridge carried here (`viewer.js:229` `lineOrigin`) interpolates across a multi-line block. `scrollToLine(145, 7.25)` therefore puts the requested line's text 45 px away from where the bridge says it is (−52.34 vs −7.25 px; Atlas `2d10761d…`). R4's agent `scroll`/`visible` will expose this directly.
- **After rebasing onto `8ad5469bef`:** the rebase applies cleanly, and the same probe aligns the interior line's text within 1 px before eviction and after restore. The full slice is green (Atlas `0681d96c…`). R2 needs no native change for this; it needs the rebase and a witness.
- **Why the shipped test missed it:** `evictionRestoresReadingState` (`c11Tests/MarkdownWebRendererTests.swift:84`) uses only one-line blocks (`## Section N` / `Paragraph N.`), so block and line mapping coincide.
- **Owner action:**
  1. Rebase onto the current R1 branch tip. Expect `b4f6a62ee5` to drop as already applied.
  2. Add a multi-line read-mode variant of the eviction test. Paragraphs of four source lines that soft-wrap in the 460 px window; scroll to an interior line with a positive offset; assert `visible().lines.first` equals that line and that the line's text row is at `-offset ± 1 px`, both before eviction and after restore. My probe is a working template (synthesis evidence `scratch.patch`).
  3. Re-run the 8-class slice at the rebased head.
  4. Repeat the ruling's packaged eviction screenshot pair at the rebased head, because the bridge under it changed.

### F1: FIX IN PLACE (non-blocking). The "never evict mid-query" barrier has no witness
Source: Astra N2 = Fable #2 (merged).

- **Where:** `Sources/Panels/MarkdownRendererCache.swift:62` (pin + epoch), `:89` and `:96` (in-flight and epoch rechecks); `c11Tests/MarkdownWebRendererTests.swift:138`.
- **Scenario:** a refactor drops the pin or the post-capture recheck, an agent's `markdown` query races eviction, and the reader is torn down mid-query. The suite stays green. The assertion at `:138` runs synchronously before any asynchronous capture can finish, so it passes with or without the guard. The owner's validation comment calls this a "genuine in-flight query witness"; it is not one.
- **Reproduced:** Atlas `737763b7…` (pin, epoch and both in-flight checks removed: 71/71 green); independently Astra `a75b3fb2…` and Fable `1dac4183…`/`02861ae2…`.
- **Why fix in place:** this is the ruling's invariant 3, and the owner is editing this test for R1-REBASE anyway.
- **Fix direction:** hold the query open deterministically. `window.c11md` is a writable property holding a frozen object, so the test can replace it. Evaluate a stub that wraps the original and makes `visible` return a promise resolved by `window.__release()`. Then:
  1. `renderer.call("visible")` and assert it is pending.
  2. Register five more renderers and let the run loop settle. Await one of the *other* evictions as the "the cache acted" signal; don't sleep.
  3. Assert the held panel is still resident.
  4. Release, and assert the held panel's eviction arrives.

  For the epoch, the same stub also holds the cache's own capture (`captureReadingPosition` calls `window.c11md.visible()`). Start a `call` while the capture is held, release it, and assert that capture round does not evict.

### F2: FIX IN PLACE (non-blocking). Navigation, new-window and zoom-key refusals have no witness
Source: Astra N1 = Fable #1 (merged; the CSP and frame parts go to hardening, H8).

- **Where:** `Sources/Panels/MarkdownWebRenderer.swift:330` (cancel all but the entry load), `:333` (no new web views), `:107` (⌘= ⌘− ⌘0 never reach WebKit).
- **Scenario:** a refactor admits a navigation, and hostile document content (realistic per the bar) navigates the reader. The suite stays green. The guards are present at this head; there is no live escape.
- **Reproduced:** Atlas `737763b7…`; independently Astra `93b8168d…`, Fable `b9ea6e51…`.
- **Fix direction:** in the real-WebKit test, set a page marker. Then:
  1. From the page, try `location.assign('c11md://bundle/index.html?x')`, `location.href='https://example.invalid/'` and `window.open('c11md://bundle/index.html')`.
  2. Assert the marker survives, `revision` is unchanged, and no `rendered` arrives for a new entry. Record `decidePolicyFor` outcomes through a test-observable counter if that is simpler.
  3. Send a synthesized ⌘= `NSEvent` through `performKeyEquivalent`; assert it returns false and `pageZoom == 1`.

## Hardening ticket (non-blocking; not part of this repair)

- **H1, Fable #5: a failed renderer never recovers while visible.** `failure` is set by `render_failed` (`MarkdownWebRenderer.swift:288`) and cleared only on `ready` (`:283`). Scenario: a document trips `render_failed`; the operator fixes the file; live reload renders it successfully behind the error view, yet the panel still says "Renderer unavailable" until the panel is evicted and re-shown, and a visible panel is never evicted. Reproduced by code path (no ordinary content found that triggers `render_failed`). Fix: clear `failure` on a successful `rendered` for the current revision; recreate on the next content change after two terminations.
- **H2, Fable #3: link narrowing.** On base, SwiftUI's default `openURL` opened every scheme, including `file:` executables; now `mailto:`, `file:` and other schemes do nothing (`MarkdownAssetPolicy.swift:133`, `MarkdownWebRenderer.swift:313`). The ticket enumerates the routed set and the threat model records the refusal, so this is a contracted change, not a regression. See Q1.
- **H3, Fable #4:** relative `.md` links resolve to any readable `.md` path and open an offline panel on click. That is the same reach as `c11 markdown open`, and nothing is executed or sent off the machine. C11-357 owns linked-doc navigation; consider confining links to the document tree there.
- **H4, Fable #8:** a pre-`fontScale` legacy snapshot restores at 1.0 instead of the last-used scale (`SessionPersistence.swift:381`, `Workspace.swift:1187`). It affects only the first restore from very old snapshots.
- **H5, Fable #7:** `Package.resolved` whitespace churn and a stale `originHash`. Let Xcode re-resolve once.
- **H6, Fable #9:** `synchronize()` runs on every `updateNSView`. Cheap today; recheck when R3's toolbar multiplies updates.
- **H7, Fable #10:** hard links inside the document tree serve outside bytes. Not reachable from document text; add a line to the threat model.
- **H8, rest of Fable #1:** witnesses for the CSP response header (unit-test `MarkdownSchemeHandler` with a fake `WKURLSchemeTask` and assert the headers; the page-level CSP masks header removal in WebKit tests) and for the bridge frame/origin check (`:275`).

## Dropped

- **Fable #6 ("a rejected `load` leaves the page invisible"): unreachable.** The bridge's `enqueue` (`viewer.js:478`) catches every task error into `render_failed`, which shows the failure view instead of a blank one. Native always passes string `markdown`/`documentPath`, so `invalid_argument` cannot fire. A load superseded mid-flight is always superseded by a newer load, which posts `rendered`.
- **My own lead, "a settings change swallows a load's `rendered`": dropped.** `setSettings` enqueues with `supersedes=false`, so only a newer load can supersede a load.

## Also checked, no finding

- The terminal link path refactored into `openC11WebLink` (`BrowserPanel.swift`, `GhosttyTerminalView.swift`) keeps base behavior. Every `.embeddedBrowser` target is http(s) with a normalizable host, so the new scheme/host guard always passes. Option, settings, whitelist and placement order are unchanged.
- Drag-type consolidation into `DragOverlayRoutingPolicy.webViewDragTypes` blocks the same strings (`com.stage11.c11.sidebar-tab-reorder` = `SidebarWorkspaceDragPayload.typeIdentifier`).
- A renderer is created only after a file is bound (the empty state never mounts web content), so the scheme handler's document root is never nil for a real reader.

## Repair brief for the owner (`agent:codex-md-r2`)

Do these in order, and push one head for verification:

1. **B1:** replace `titleBarDescriptionBlocks` with a single Foundation full-syntax parse mapped to the existing native blocks, as described under B1. Add the six Astra probes plus start-number, rule and quote-softbreak cases. Keep the sanitizer, inert links and the height cap. Add no new package dependency and no web view.
2. **R1-REBASE:** rebase onto the current `md-viewer/C11-358-web-renderer` tip. Add the multi-line interior-line eviction variant (assert the line and a ±1 px text row before eviction and after restore). Re-run the 8-class slice at the rebased head, and repeat the packaged eviction screenshot pair there.
3. **F1:** make the in-flight-query and capture-epoch barriers observable with a held bridge promise, as described under F1.
4. **F2:** add navigation, new-window and ⌘= witnesses to the real-WebKit test.
5. Show each new test red against a guard you remove temporarily, then green, and record the Atlas invocation IDs in the validation comment. Also correct the earlier "genuine in-flight query witness" claim.

Out of scope for this repair: H1–H8 (hardening ticket) and anything in R1's renderer beyond the rebase.

## Questions for the Orchestrator

1. **Q1, `mailto:` links in markdown documents.** Base opened them (along with every other scheme); this PR refuses them by contract. Should a `mailto:`-only allowlist through `NSWorkspace.open` go into the hardening ticket? If yes, operators keep mail links; nothing else changes. If no, the contracted narrowing stands. My recommendation: yes, low risk.

## Verification plan (for VERIFY)

At the new head I will:

1. Assert the exact SHA and its ancestry on the R1 tip.
2. Diff it against this head for anything beyond the four items.
3. Rerun the B1 probes and my multi-line probe against the owner's versions.
4. Rerun the 8-class slice.
5. Re-apply the run-3 mutations to confirm the new witnesses go red.
6. Spot-check that the description renderer change touches nothing else on the title bar.

A regression introduced by a fix blocks.

Evidence: [synthesis-C11-359-evidence.zip](./synthesis-C11-359-evidence.zip) holds the three Atlas invocations' build logs and `result.json`; `head.patch`, `scratch.patch` and `mut.patch` (the exact probe and mutation diffs); `mutate.py` and `add_multiline_test.py`; and the standalone B1 parser probes.
