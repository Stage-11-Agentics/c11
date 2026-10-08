# Verify 2: C11-360, PR #623, exact-head review for landing

Reviewer: agent:claude-md-review-360. Read-only.
Head verified: `3aabd3b2ac309389a546c0b2fa1cb128027db4c8` (asserted). It is a linear child of `aeb3e8d715`.

**Verdict: PASS.**

## The delta from `aeb3e8d715` covers only B6, V1 and V2

One commit, `3aabd3b2ac`, touching 2 files (+18 −6):

- **B6.** `MarkdownPanelView.swift`: removes `.frame(maxWidth: .infinity, alignment: .trailing)` from `controls`. Nothing else in the toolbar changed.
- **V1.** The source toggle now uses `MarkdownOmnibarButtonStyle(palette:active:)`. The style gains `active`, which gives a 0.08 fill, the same as hover. The pressed fill is 0.16 and the corner radius is 8 continuous, matching the icons beside it.
- **V2.** `test.mjs`: the old racy N10 assertion moves out of the filter scenario into a new settled scenario. That scenario scrolls to Section 12, waits for the heading and the active mark, waits two animation frames, filters for "Section 12", and asserts `['section-12']`.

## Checks

- **Web harness, headless:** 38/38 scenarios passed, including "N10: settled Section 12 scrollspy mark survives outline filtering", with zero console errors and zero network requests.
- **N10 red without the forced update:** I ran a scratch copy of the bundle with `renderOutlineList` calling `updateOutlineActive()` instead of `updateOutlineActive(true)`. The harness went red with "filter repaint dropped the settled active scrollspy mark". V2 now guards the fix.
- **HStack probe (B6):** I measured the head's toolbar structure in an `NSHostingView` (`verify1-C11-360-evidence/toolbar-sweep-probe.swift`).

  | Width (pt) | Cluster trailing inset | Progress-to-cluster gap | Breadcrumb width | Cluster width |
  |---|---|---|---|---|
  | 300 | 4 | progress hidden | 40 | 206 |
  | 360 | 8 | progress hidden | 92 | 206 |
  | 429 | 8 | progress hidden | 161 | 206 |
  | 430 | 8 | 8 | 26 | 206 |
  | 560 | 8 | 8 | 156 | 206 |
  | 700 | 8 | 8 | 234 | 206 |
  | 900 | 8 | 8 | 434 | 206 |
  | 1200 | 8 | 8 | 734 | 206 |

  The cluster stays trailing at every width. The breadcrumb now takes all the free space; at 1120 pt it gets 645 of 645, against 430 at `aeb3e8d`.
- **Exact-head Atlas build plus logic slice** (`rv-360-t`, invocation `8b1fab2dabaf4d5bb92739ad486d6a19`, `head=3aabd3b2ac…`): `C11_REMOTE_OK compile=ok tests=ok`. 11 tests, 0 failures, `** TEST SUCCEEDED **` across `MarkdownReaderInteractionTests` and `MarkdownPanelFontScaleTests`. This covers the Swift change at the exact head. The owner's build was `aeb3e8d` plus file overlays.
- **The owner's packaged-app screenshot** (`art_01M4EBFPY1K9Z3F1QA1SG3ME5C`, a 1200 pt panel) shows "0% · 3 min left" right beside the trailing cluster and the full breadcrumb `welcome.md › welcome to c11`. That matches the prototype's layout.

## Status of earlier findings

- **Fixed and verified in Verify 1, unchanged since:** B1–B4, the find-in-page ruling, N1–N5, N7, and Review 2's B5.
- **Fixed here:** B6, V1, V2.
- **Open, not blocking:**
  - N6 goes to the hardening ticket.
  - V3: the Merge Captain runs `scripts/sync-installed-skills.sh c11-markdown` from merged main. The owner confirms they left the installed copies untouched this round.
- **No regressions found in the delta.**

## Atlas cleanup, per the Orchestrator

I deleted the extra tags `rv-360-t` and `rv-360-m` (about 4.7 GB each); their logs were already retrieved under `build-remote/`. My seat keeps `rv-360` only. Atlas went from 36 GB to 109 GB free.
