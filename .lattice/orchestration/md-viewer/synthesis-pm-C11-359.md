# C11-359 post-merge synthesis: merge `a95823705c`

Needs you: nothing. The follow-up lands as a PR from `main` on C11-359.

- Seat: `agent:claude-md-synth-359`.
- Merge reviewed: `a95823705c3912d8def621e3b2b7ed3384f47a4c`, a squash on `c37ced9d78` whose tree is identical to verified head `75abca4256`.
- Inputs: `pm-review-C11-359-a.md` (Astra, FAIL) + evidence zip; `pm-review-C11-359-f.md` (Fable, FAIL).

## Verdict: FAIL

Two blocking findings, one from each reviewer; both reproduced. Four small items to fix in the same follow-up PR. The rest go to the hardening ticket.

## My reproduction

Atlas `f568e11c83d44626b8ca465e5d6a97f9`: merged head with tests only added. The probes were Astra's `reload-probes.patch`, my deletion-above variant, and Fable's appearance probe, verbatim from her review. The run executed `MarkdownWebRendererTests`, 13 tests: 3 probes red, the other 10 green, including the retained-reader control.

| Test | Result |
|---|---|
| Retained reader, 12 sections inserted above (control) | PASS: Section 40 before and after |
| Evicted reader, 12 sections inserted above | **RED**: after re-show the heading is **Section 28**, and Section 40's top is at 1665.9 px instead of 18.3 |
| Evicted reader, 12 sections **deleted** above (mine) | **RED**: **Section 52**; Section 40's top is at −1628.8 px |
| Mounted `system`-theme reader, `NSApp.appearance` light → dark | **RED**: `effectiveAppearance` becomes DarkAqua at once, but the reader stays `light` through 4 s, a ThemeManager publish, and a host relayout; a manual `synchronize()` turns it `dark` |

Plus a local compile of the merged description parser (unchanged since verify 2) for task lists, and file checks for the docs items. Evidence: [synthesis-pm-C11-359-evidence.zip](./synthesis-pm-C11-359-evidence.zip) holds the probe patch, the probed test file, and the invocation's logs and `result.json`. The scratch worktree is removed.

## Blocking

### PM-B1 (Astra B1): an evicted reader loses its place when the file changes above it
- **Where:**
  - `Sources/Panels/MarkdownRendererCache.swift:6`: `MarkdownReadingPosition` is a bare line/offset/mode/find, with no content identity.
  - `Sources/Panels/MarkdownPanel.swift:114` stores it.
  - The model-only reload (`MarkdownPanel.swift:276`) replaces `content` and leaves the number unchanged.
  - `MarkdownWebRenderer.swift:233-237` scrolls the new document to the old number.
- **Scenario:** the operator reads Section 40 and visits five other markdown panels (an ordinary many-panel day), and an agent edits the document above that point. On return the operator lands 12 sections away from where they were. A retained reader in exactly the same situation holds Section 40, so whether the place survives depends on how many panels the operator happened to visit.
- **Why it blocks:** the ticket promises live reload with scroll held, and the eviction ruling says "the reader must land on the same line". Eviction is meant to be invisible. Insertion and deletion both fail, so this is general to edits above the anchor, not one shape. Appends pass, which is why the shipped eviction test (append-only) misses it.
- **Fix direction (recommended):** reuse the bridge's proven same-document reload anchoring instead of writing a native line translator.
  1. When capturing at eviction, keep the content the position was captured against (`readingPosition` + `readingContent`). Swift strings are copy-on-write, so this costs nothing until the file changes, then one retained copy per changed evicted panel.
  2. On recreation, `load` the captured content, restore mode/find/`scrollToLine(line, offset)`, then `load` the latest `panel.content` as a same-document reload. The bridge's `capture()`/`restore()` then carries the anchor exactly as it does for a retained reader.
  3. Reveal (`renderedRevision`, which drives opacity) only after the latest revision renders, so the operator never sees the old text. If the captured content equals the latest content, keep today's single load.
  4. Fallback when the anchored block itself is gone: whatever the retained path does today; document it.

  The alternative, a native old→new line mapping by diff, loses intra-block anchoring and would need its own fallback rules. I don't recommend it.
- **Tests:**
  1. Ship Astra's paired retained/evicted insertion probes and my deletion-above variant (heading and ±1 px top of Section 40).
  2. Keep the existing interior-line, source-mode and append cases green.
  3. Show the evicted pair red without the fix.

### PM-B2 (Fable B1): c11's own appearance switch doesn't reach a mounted `system`-theme reader
- **Where:**
  - `Sources/Panels/MarkdownWebRenderer.swift:252-258` reads `osAppearance` from `effectiveAppearance`, and only inside `synchronize()`.
  - `synchronize()` runs from `updateNSView` (`MarkdownPanelView.swift:292-300`) and from the OS-theme and occlusion observers (`MarkdownPanel.swift:310-344`). None of them fires when `c11App.applyAppearance` (`c11App.swift:1121`) sets `NSApplication.shared.appearance`.
- **Scenario:** the operator switches c11's appearance mode (Light/Dark) while a markdown panel with the default `system` theme is on screen. Terminals and chrome change; the reader stays in the old mode until it is remounted or the OS theme flips.
- **On base:** the content used `@Environment(\.colorScheme)` (`a95823705c~1:Sources/Panels/MarkdownPanelView.swift:327`) and followed the switch live.
- **Why it blocks:** behavior that worked on base regresses under ordinary operator use. It is cosmetic and heals on remount, but the bar is explicit, and the fix is two lines.
- **Fix:** override `viewDidChangeEffectiveAppearance()` on `MarkdownWKWebView` and call the owning renderer's `synchronize()` (a weak back-reference or closure). `synchronize()` already diffs `loadedSettings`, so a call with no change is free. Keep the explicit `osAppearance` path rather than falling back to `prefers-color-scheme`.
- **Test:** ship Fable's probe, and assert at least stage 1 (the flip alone reaches the reader within the settle window).

## Fix in place in the same follow-up PR (non-blocking)

1. **Docs for the `mailto:` route** (Astra N1 = Fable 1, merged). `docs/security-threat-model.md:254-256` still says other schemes are refused, and `skills/c11-markdown/SKILL.md:186` names only web links. Add one sentence to each: validated `mailto:` (recipients, cc, bcc, subject and body only; no host, port or fragment; control characters refused) opens through `NSWorkspace` on an operator click. Run `scripts/sync-installed-skills.sh c11-markdown` and check the live copy.
2. **Task-list items in descriptions** (Fable 2). Confirmed locally: `- [x] tests green` renders as `• [x] tests green` (the same for ordered items). On base, MarkdownUI's default theme drew task checkboxes. The meaning survives, so it doesn't block, but it is a small visible regression next to the parser that just changed. Map a leading `[ ] ` / `[x] ` / `[X] ` in a list item's text to `☐` / `☑` markers, with a test for each.
3. **Context menu over the reader** (Fable 3). Code-confirmed, not UI-demonstrated. On base, the SwiftUI `.contextMenu` with "Panel Details" (`MarkdownPanelView.swift:33`) wrapped the MarkdownUI body. Now the body is a `MarkdownWKWebView` with no `willOpenMenu`, so WebKit's default menu wins. Its "Open Link", "Open Link in New Window", "Download Linked File" and "Reload" items are cancelled by policy and do nothing; "Copy Link" on a relative link copies `c11md://bundle/<path>`; and "Panel Details" is reachable only over the file-path header or from the command palette. Fix: override `willOpenMenu(_:with:)` on `MarkdownWKWebView` like `CmuxWebView` (`CmuxWebView.swift:1280`): drop the navigation, download, reload and Copy Link items, keep text Copy / Look Up / Services, and append "Panel Details". Test it the way `BrowserConfigTests.swift:859` does, by calling `willOpenMenu` directly on a menu built with WebKit's item identifiers.
4. **Rename** `testMarkdownWebViewPreservesFileDropsWithoutSwallowingInternalDrags` (Fable 5) to what it asserts: types are filtered and drops are refused, and Finder drops arrive through `FileDropOverlayView`.

## Hardening ticket (add to H1–H8 and the verify notes)

- The three `workspaceGroup.error.*` keys with no catalog entry (Fable 4). They predate this PR: present in `Sources/` at `a95823705c~1`, absent from the catalog. They are a separate one-line localization fix, not part of C11-359's follow-up.
- `markdown.mermaid.installHint` remains in the catalog with no caller.

## Dropped / no finding

- None of the reviewers' other probes found a defect. Astra's mutants A–C confirm every shipped guard and witness on the merged head (102/102 with guards restored); Fable's baseline is 81/81. I did not repeat those runs; they match my verify-1 mutants on the same tree.

## Repair brief for the owner (follow-up PR from `main`, on C11-359)

1. **PM-B1:** capture `readingContent` with the position. On re-show, load the captured content, restore, then reload the latest as a same-document reload, revealing only after the latest render. Ship the retained/evicted insertion probes and the deletion probe; show them red without the fix.
2. **PM-B2:** call `synchronize()` from `MarkdownWKWebView.viewDidChangeEffectiveAppearance()`. Ship Fable's appearance probe.
3. **Fix-in-place items 1–4:** mailto docs and skill sync, task-list markers, `willOpenMenu`, test rename.
4. Run the 8-class slice at the PR head on Atlas, plus one packaged check: an evicted reader re-shown after an above-anchor insertion lands on the same heading (a screenshot pair), and a light↔dark appearance flip updates a visible reader. Record the invocation IDs.

## Verify plan

For the follow-up PR, I will:
1. Assert the head descends from `main`.
2. Confirm the diff is confined to the items above.
3. Rerun the four probes and the 8-class slice.
4. Remove the new capture-content step and the appearance hook, and confirm the probes turn red.
5. Check the menu and task-list tests against their code.
6. Check the installed `c11-markdown` skill copy.

A regression introduced by a fix blocks.
