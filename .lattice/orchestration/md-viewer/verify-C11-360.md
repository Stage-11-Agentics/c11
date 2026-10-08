# Verification: C11-360 repair, PR #623

Reviewer: agent:grok-md-review-360-g. Read-only.
Head: `aeb3e8d7157d1e2c2016ed12f44045d339d19894` (checked out, asserted). Parent `a020849f9f`. `fd263426f9` is an ancestor. Repair commit `aeb3e8d715` ("C11-360: repair reader chrome review findings"). Owner validation `ev_01M4E12KCZ2YCBHJSM88K381DJ`, refreshed at 2026-10-08T17:28:35Z.

Scope was B5 and N10–N13, including the in-page find bar that replaces the native one. No new discovery pass.

**Verdict: PASS.**

## What I ran

- Headless harness on the repaired bundle: `node scripts/markdown-viewer/test.mjs`, **37/37**, zero console errors, zero network requests. No ports bound. Chromium was the installed 1223 headless shell (`PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`); Playwright 1.56.1's pinned 1194 shell is still missing here.
- Each page fix was broken in a scratch copy of the bundle, the harness or a settled probe was rerun, and the copy was deleted. The worktree was not edited.
- Outline-choice cast checked with `JSONSerialization` against the value types the page publishes. No c11 build and no launch.

## B5. Source-mode gutter

Fix: `layoutAll` builds one `dockGutter` from `S.docked` (not from whether the outline is open) and assigns it to both `#layout` and `#srcScroller` (`viewer.js:590-592`).

Red, scratch copy, official harness:

- Dropping `srcScroller.style.paddingLeft=dockGutter` failed at `test.mjs:211`: `docked outline covered source line number`.
- Gating the gutter on `S.docked && S.outlineOpen` failed at `test.mjs:216`: `closing a docked outline shifted source lines`.

The repaired tree passes `docked outline reserves its gutter over source line numbers and text`. Touched: `viewer.js` and the new harness scenario. The read-column anchor scenarios still pass.

## N10. Scrollspy mark after a filter

Fix: `renderOutlineList` ends with `updateOutlineActive(true)` (`viewer.js:439`).

The official assertion did not go red. Removing that `true` left the full harness green (exit 0). `waitForFunction` on `c11md.visible().heading` can resolve before the scrollspy `requestAnimationFrame` stores the slug, so the unforced refresh still paints `.on`.

A settled probe, after two animation frames, then filtering "task": the repaired page keeps `a.on` on `tasks`. The same probe on the unforced scratch copy returns no `.on`. That copy was deleted. The fix holds. The harness guard is racy; that is not a behavior regression.

## N11. 300% filter metrics

Fix: `.ohead` height is `calc(38px * var(--scale))` and the input height is `calc(30px * var(--scale))` (`viewer.css:47-48`).

Red: putting the fixed `38px` and `30px` heights back failed at `test.mjs:190`: `300% outline header clipped its controls: 38px`. The repaired scenario passes.

## N12. Outline choice snapshot

Fix: `MarkdownReaderOutlineSnapshot.choice` is `Bool?`, set with `outline["choice"] as? Bool` (`MarkdownWebRenderer.swift:203`, `:485`). Nil is the auto value.

The page publishes a boolean for an explicit open or close, and the string `"auto"` otherwise. The harness asserts the invalid-setting fallback is `outline.choice === 'auto'` (`test.mjs:432`).

`JSONSerialization` of those JSON types, which is what the script bridge delivers:

| Published value | New `as? Bool` | Old `as? String ?? "auto"` |
|---|---|---|
| `true` | `true` | `"auto"` |
| `false` | `false` | `"auto"` |
| `"auto"` | `nil` | `"auto"` |

The old cast collapsed an explicit choice to `"auto"`. The new cast keeps it. No in-repo test calls this line, so there was no project test to turn red. Nothing in the app reads `readerOutline.value.choice` yet. The toggle-persistence tests in `MarkdownReaderInteractionTests` cover `presentation.outlineOpen`, which is a different field.

## N13 and the in-page find bar

The native find field is gone from `MarkdownPanelView`. `requestFind` calls `openFind(focusAllowed:)` (`MarkdownPanel.swift:113-116`). The renderer passes that flag through (`MarkdownWebRenderer.swift:607-608`). The page popover is `#findbar` (`index.html:31-37`).

`renderFindChrome` writes `S.find.draft`, and the input handler updates `draft` immediately (`viewer.js:395`, `:900-903`). A render during the debounce cannot put the previous committed query back.

Red: pointing that render at `S.find.query` failed at `test.mjs:129`: `a find render restored the previous query while the new input was debouncing`.

The repaired scenario passes: open, focus, count `1 / 3`, previous/next wrap, clear stays empty, Escape closes the popover and drops the marks, and the reading anchor does not move. `openFind(false)` leaves focus on `body`; `openFind(true)` focuses `#findInput`.

Touched for this path: `index.html`, `viewer.css` (`.findbar`), `viewer.js` (draft, chrome, Escape closes find before the outline filter), `MarkdownPanel.swift`, `MarkdownPanelView.swift`, `MarkdownWebRenderer.swift`, and the harness scenario. Escape on the page still posts `outlineDismiss` only after find and the filter are clear. The anchor, source-toggle, and find scenarios in the 37 all pass.

## Not re-opened

Review 1's B1–B4 and N1–N9, except where N13 required checking that the native field is gone and the page popover replaced it.
