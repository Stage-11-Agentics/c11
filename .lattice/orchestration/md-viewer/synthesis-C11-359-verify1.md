# C11-359 verify 1: `c3d4d0867d29fb06ec0600bc6b4239b0595b4736`

Needs you: nothing.

- Seat: `agent:claude-md-synth-359`.
- Head attested: `c3d4d0867d29fb06ec0600bc6b4239b0595b4736` (my worktree checked out detached at that SHA, clean).
- Ancestry: contains C11-358's merge `c37ced9d78` (= `origin/main` tip). 12 rebased commits plus one repair commit.
- Prior synthesis: `synthesis-C11-359.md`. Owner handoff: `ev_01M4DQAYZSXGXVN8TQ06HZSDND`.

## Verdict: FAIL

One regression introduced by the B1 fix (V1 below). Everything else requested holds: R1-REBASE, F1, F2, the Orchestrator's `mailto:` addition, and the rebase itself. The repair is two lines plus tests.

## What changed beyond the four items

- **Rebase:** `git range-diff 2c97338c4c..b4f6a62ee5 c37ced9d78..883a1b3f0e` shows all 12 C11-359 commits patch-identical. `b4f6a62ee5` (the duplicated R1 offset commit) dropped. Bridge files (`Resources/markdown-viewer/`, `scripts/markdown-viewer/`) are byte-identical to R1's fix `8ad5469bef`.
- **Repair commit `c3d4d0867d`** touches exactly six files: `MarkdownAssetPolicy.swift`, `PanelTitleBarView.swift`, `MarkdownWebRenderer.swift` (+2 lines, mailto route), and the three matching test files. Nothing else.

## Atlas runs (tags `syn-359`, `syn-359-m`)

| Invocation | Tree | Result |
|---|---|---|
| `20b9480fcc8a48d084454f60f3229573` | exact head, clean (`dirty=false`) | 8-class slice **88/88 PASS** (63 logic + 25 host), `** TEST SUCCEEDED **` |
| `37114e1ebd8e4b4092d417f61c2afae4` | mutant A: navigation always `.allow`; plus my four nested-list probes | navigation witness **RED** (policy `.allow` ≠ `.cancel`); all 4 nested-list probes **RED** (V1) |
| `46846ad4f51a4b78a7676832ef14ce1a` | mutant B: ⌘= ⌘− ⌘0 guard removed | `testRealWebKitRejectsNavigationPopupAndZoomShortcut` **RED** (`performKeyEquivalent` returned true) |
| `88239eca336b4b54a0a7cb63d134c5a0` | mutant C: query pin and both in-flight checks removed (epoch kept) | `testHeldVisibleQueryPinsRendererUntilTheQueryFinishes` **RED** (held renderer evicted during the query) |
| `fe1173035d9a4313995fa6219ed9b993` | mutant D: post-capture epoch recheck removed (pin kept) | `testCacheDiscardsCaptureCrossedByNativeQueryEpoch` **RED** (stale capture evicted) |

Each new witness goes red against its own guard, isolated one group at a time. The CSP header and bridge frame/origin guards still have no witness; that stays H8 in the hardening ticket, as planned.

## Item by item

- **B1 (description renderer): fixed for every case in the brief.** Locally, compiling the exact production functions, all of these now match CommonMark: setext H1/H2, closing hashes, wrapped list continuation, `1. 1.` → `1. 2.`, reference links (inert label), hard breaks, ordered start numbers, rules, quote soft breaks, indented code, `Step\n2. two`, nested bullet-under-bullet, and the common paragraph + `Lineage:` description. Links stay inert; the sanitizer and the height cap are unchanged. **Except V1.**
- **R1-REBASE: holds.**
  - The new `testReadModeEvictionRestoresInteriorLineInsideSoftWrappedParagraph` asserts `lines.first == 145` and the interior text row at `-offset ± 1 px`, both before eviction and after restore, with each source line soft-wrapping (>1 row). It passes in run `20b9480f…`.
  - The owner's own old-interpolation mutant (`906199a1…`) turned it red.
  - Packaged pair: `art_01M4DQ800M…` / `art_01M4DQ803S…` are pixel-identical. Events show eviction at line 77 / 130.828125 and restore at line 77 / 130.828125, with recreation in 996 ms.
  - The packaged build (`4fdd18e7…`, tag `md359-repair-pack`) ran from `883a1b3f0e` plus an overlay. I checked the overlay's six SHA-256s against `c3d4d0867d`'s blobs and they match exactly, so the build is this head's tree.
- **F1: holds.** The held `visible()` promise keeps the renderer resident while a peer is evicted. The renderer leaves only after release (mutant C red). A capture crossed by a native query cannot evict (mutant D red). The earlier "genuine in-flight witness" claim is corrected in the owner's validation comment.
- **F2: holds.** Real WebKit: `location.assign` to `c11md://…?x` and to `https://…` is cancelled; `window.open` reaches the native refusal and returns null with no second web view; ⌘= returns false with `pageZoom == 1`; no new entry renders. Mutants A and B both red.
- **mailto (Orchestrator addition): holds.**
  - `MarkdownLinkTarget.resolve` returns `.mailto` only for a scheme-matched href with no host, userinfo, port or fragment. Recipients (and cc/bcc) must be validated addresses; query names are limited to subject, body, cc and bcc; no control characters after decoding.
  - `routeLink` opens it with `NSWorkspace.shared.open`, reached only through the existing bridge `link` message (operator click; the bundle classifies `mailto:` as external).
  - The test covers acceptance, case-folding, and eight rejections, including CRLF header smuggling, `attachment=`, a fragment, and `mailto://`.
  - Note for hardening, non-blocking: a `body` containing an encoded newline is refused (conservative).

## V1: BLOCKING (a regression the B1 fix introduced). Nested list items take the outermost item's marker

- **Where:** `Sources/PanelTitleBarView.swift`, `titleBarDescriptionBlockKey`, list-item branch. `components.last(where: listItem)` and `components.lastIndex(where: listItem)` pick the **outermost** item, because `presentationIntent.components` is ordered innermost-first. The parent-list lookup then reads the outer item's list.
- **Scenario and evidence** (local compile of the exact production code, confirmed in-target by Atlas `37114e1e…`):

| Description | This head | Base (MarkdownUI) and the previous head |
|---|---|---|
| `1. Plan` / `   1. read` / `   2. write` / `2. Ship` | `1. Plan`, `1. read`, **`1. write`**, `2. Ship` | `1.` `1.` `2.` `2.` |
| `- a` / `  1. x` / `  2. y` | `• a`, **`• x`, `• y`** | `•`, `1.`, `2.` |
| `1. a` / `   - x` / `   - y` / `2. b` | `1. a`, **`1. x`, `1. y`**, `2. b` | `1.`, `•`, `•`, `2.` |
| `- item one` / *(blank)* / `  second para` / `- item two` | three bullets: the second paragraph becomes a phantom item | two items (base: one item with two paragraphs; previous head: item plus plain paragraph) |

- **Why it blocks:** numbering and list structure change meaning on ordinary nested lists. Both base and the previous head rendered the first three rows correctly, so this is a regression introduced by a fix.
- **Repair:**
  1. In the list-item branch, use the innermost item: `firstIndex(where: listItem)`, take `ordinal` from that component, and find the parent list as the first list kind after that index.
  2. Key list content by that item's identity (not the enclosing paragraph's), so a loose item's paragraphs stay in one row. Join paragraph changes within an item with `"\n"`.
  3. Optional in the same pass: multi-paragraph quotes (`> a\n>\n> b`) currently render as two adjacent quote blocks; keying quotes by quote identity the same way makes them one.
  4. Add my four probes. They are in `verify1/evidence-vA.patch` in the evidence zip, as `testSynth…` in `DescriptionSanitizerTests`; rename freely. Show them red at this head and green after.
- **Re-verify scope:** only `PanelTitleBarView.swift` and `DescriptionSanitizerTests.swift` should change. I will rerun the 8-class slice at the new head and the description probes. A one-function change does not need a new packaged pair.

## Unchanged from the synthesis

H1–H8 stay in the hardening ticket. Add: "mailto with an encoded newline in `body` is refused."

Evidence: [synthesis-C11-359-verify1-evidence.zip](./synthesis-C11-359-verify1-evidence.zip) holds the five invocations' logs and `result.json`, the mutant and probe patches, and the standalone parser probe.
