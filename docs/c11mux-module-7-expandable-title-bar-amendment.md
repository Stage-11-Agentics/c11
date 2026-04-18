# c11mux M7 Amendment — Expandable Title Bar

**Status:** draft spec + implementation plan, **revised after parallel review** (Claude + Codex, 2026-04-18). See "Revision log" at the end.
**Amends:** [`docs/c11mux-module-7-title-bar-spec.md`](./c11mux-module-7-title-bar-spec.md).
**Does not amend:** Module 2 reserved-key table — no new canonical keys are introduced.

---

## Motivation

With ten to twenty parallel terminal agents in a single workspace, the title bar has to carry real identification weight. Today it shows a single truncated line and a plain-text description. That is not enough when an operator is scanning a dense grid trying to answer "which of these is the reviewer, which one is stalled, which one needs me?" The three changes below turn the title bar from a label into a *per-surface card*: richer content, operator-controlled real estate, no new storage.

---

## What this PR ships

1. **Markdown rendering for `description`.** Replace the plain `Text(description)` at `Sources/SurfaceTitleBarView.swift:83` with a `Markdown(description)` view (MarkdownUI, already used by `MarkdownPanelView`) using a compact title-bar theme. This amendment **consciously updates the M7 subset policy**: the original spec line 57 claimed disallowed markdown renders verbatim, which MarkdownUI's parser does not honor. New policy: accept what MarkdownUI renders by default **minus images** (dropped at render time) and **with link navigation disabled** (rendered as styled text, clicks do nothing). See §Description formatting below.
2. **Multi-line title when expanded.** Lift `.lineLimit(1)` on the title text at `Sources/SurfaceTitleBarView.swift:75` when the title bar is in the expanded state **and** a non-empty description exists. Collapsed state — and any state with an empty description — stays single-line + tail ellipsis. Dense-grid default preserved.
3. **Chevron moves to the right edge.** Relocate the collapse/expand chevron from the left of the title row to the trailing edge. Rationale: the left edge should hold the title (the content operators scan to); the control belongs on the right. **Chevron-only hit target** — no whole-row tap. `.contentShape(Rectangle())` enlarges the button hit area modestly without capturing unrelated click zones. (Whole-row tap was in the draft; removed after review — see Revision log.)

All three are mounted behind the existing `SurfaceTitleBarView` mount point in `Sources/Panels/PanelContentView.swift:23-29`. No new socket methods. No new canonical metadata keys. No persistence changes.

---

## Amendments to the M7 spec

### §Description formatting — rendering subset (revised)

The original M7 spec (line 113 of `c11mux-module-7-title-bar-spec.md`) names an inline-only subset and promises that disallowed syntax renders verbatim. **MarkdownUI does not preserve literal markers for disallowed block elements** — feeding it `# Heading` produces a styled heading, not the text `# Heading`. Pretending otherwise would ship a spec/impl mismatch. This amendment updates the policy:

**Allowed (rendered with styling):**

- Paragraphs and line breaks (including explicit `\n`, `  \n`, and `\n\n` paragraph breaks).
- `**bold**`, `*italic*`, `_italic_`, `__bold__`.
- `` `inline code` `` with subtle background fill.
- Unordered lists (`- item`, `* item`) and ordered lists (`1. item`) — extremely common in status reports.
- Headings `#`/`##`/`###` — styled smaller than they would be in a full document, but **they render**. Operators who type `## Phase 2` in a description should see a heading.
- Blockquotes and horizontal rules — rendered (minimal styling).
- Links — parsed and **rendered as styled text**, but click navigation is **disabled** in v1 (see implementation plan).

**Disallowed (stripped at render time):**

- **Images.** Stripped before the string reaches MarkdownUI. Graphics are explicitly parking-lot — see Open Questions. A preprocessing pass (regex substitution of `!\[...\]\(...\)` with empty string) runs inside the renderer wrapper.
- **HTML.** MarkdownUI does not render arbitrary HTML by default; nothing to strip. If it starts to, the wrapper also escapes `<` and `>`.
- **Fenced code blocks** (```` ``` ````). Stripped to avoid large block payloads breaking the 5-line cap. Inline code stays allowed. Inside the preprocessor, fence pairs are replaced with plain inline text between single backticks when feasible, otherwise dropped.
- **Tables.** MarkdownUI renders them; this amendment strips the syntax (leading `|` line detection) before rendering because 5-line-capped tables are nonsense.

The store-side validation in `SurfaceMetadataStore.validateReservedKey` (`Sources/SurfaceMetadataStore.swift:170-171`) does **not** change — description is still `maxLen: 2048`, no syntax enforcement at write time. The preprocessor runs at render time only. The raw string round-trips through the socket unchanged.

### §Visual layout — chevron position

Replaces the layout diagram at `c11mux-module-7-title-bar-spec.md:127-133`:

```
┌────────────────────────────────────────────────────────────────────────┐
│ <title text>                                              [•••]  [▸]   │
│ <description line 1>                                                   │
│ <description line 2…>                                                  │
└────────────────────────────────────────────────────────────────────────┘
```

- Title is flush-left, takes all available leading width.
- `[•••]` overflow menu sits to the right of the title, to the left of the chevron. (The overflow menu is not implemented in v1 of this PR; the spec reserves the slot.)
- `[▸]` / `[▾]` chevron is the trailing-edge control. Rotates on expand.

### §Collapse / expand — chevron-only

Primary gesture: click the trailing-edge chevron button. Secondary gesture: `⌘⇧D`. No whole-row tap (draft had it; removed after review — see Revision log for why). The chevron button uses `.contentShape(Rectangle())` to give it a comfortable tap target (~28×28 pt) without swallowing clicks elsewhere.

The chevron remains **disabled** when `description` is empty (today's behavior at `SurfaceTitleBarView.swift:65`). Today's behavior also handles the edge case correctly: a disabled SwiftUI Button does not fire its action on click, so `toggleSurfaceTitleBarCollapsed` cannot be invoked with an empty description. The `titleBarUserCollapsed` write path stays guarded.

### §Default state & empty-description behavior

Still collapsed by default; still auto-expands on first description set unless user has explicitly collapsed.

**Edge case, newly specified:** when `description` transitions from non-empty → empty, the rendered state collapses regardless of the in-memory `collapsed` flag. The flag itself is unchanged (so if description becomes non-empty again later, the prior user preference still holds). Implementation: in `headerRow`, compute `effectiveCollapsed = state.collapsed || (state.description?.isEmpty ?? true)` and use that for both the chevron icon and the title's `.lineLimit`. Prevents the "multi-line title with no description below and a disabled chevron" visual trap flagged in review.

---

## Swift implementation plan

### File-by-file

#### `Sources/SurfaceTitleBarView.swift` (primary)

- Add `import MarkdownUI`.
- **Add environment property:** `@Environment(\.colorScheme) private var colorScheme` on the `SurfaceTitleBarView` struct. Required by the theme factory below. (Triggers a re-render on system appearance change — acceptable, title bars are cheap.)
- **`headerRow`**: remove the chevron from the leading position; add it to the trailing position after a `Spacer(minLength: 0)`. The title `Text` stays leading. Compute `effectiveCollapsed = state.collapsed || (state.description?.isEmpty ?? true)` once at the top of the body. Apply `.lineLimit(effectiveCollapsed ? 1 : nil)` + `.truncationMode(.tail)` to the title. **No `.onTapGesture` on the row.** Keep the chevron as the sole toggle entry point; add `.contentShape(Rectangle())` to the Button label so the 14×14 chevron glyph gets a ~28×28 hit area via the padded button style.
- **`descriptionRow(_:)`**: 
  1. Preprocess `description` through a new helper `sanitizeDescriptionMarkdown(_:) -> String` that strips images (`!\[...\]\(...\)` regex), fenced code blocks (```` ``` ````), and table-syntax lines.
  2. Render: `Markdown(sanitized).markdownTheme(titleBarMarkdownTheme(for: colorScheme))`.
  3. **Disable link navigation:** `.environment(\.openURL, OpenURLAction { _ in .discarded })` on the Markdown view. Links render as styled text; clicks are dropped.
  4. **5-line cap with scroll:** wrap in `ScrollView(.vertical, showsIndicators: true)` with `.frame(maxHeight: titleBarDescriptionMaxHeight)` where `titleBarDescriptionMaxHeight = 5 * (fontSize=11) * lineSpacingMultiplier ≈ 90`. Inside the ScrollView, the Markdown view uses `.fixedSize(horizontal: false, vertical: true)` so intrinsic height drives content height; the ScrollView clamps at 90pt and scrolls internally. Removes today's `.lineLimit(5)` hard clip.
- **New private helpers (same file):**
  - `func titleBarMarkdownTheme(for colorScheme: ColorScheme) -> Theme` — tight variant: base font 11, heading sizes 13/12/11 (not 28/22/18 like `cmuxMarkdownTheme`), tight margins (top/bottom 2–4), inline code with the subtle fill color already in the main theme.
  - `func sanitizeDescriptionMarkdown(_ input: String) -> String` — pure function; strips images, fenced code, table rows. Testable directly.
- Keep the `accessibilityText` logic — the combined VoiceOver label works.
- Keep `state.visible` gating and the background/overlay chrome.

#### `Sources/Workspace.swift` (one small addition)

- `surfaceTitleBarState(panelId:)` at line 5964 — no change; the view computes `effectiveCollapsed` locally.
- `toggleSurfaceTitleBarCollapsed(panelId:)` at line 5985 — no change; today's logic is correct.
- `titleBarStatePayload(panelId:)` at line 5992 — **add one field:** `payload["effective_collapsed"] = collapsed || (descriptionString?.isEmpty ?? true)`. Gives tests a way to assert the rendered behavior without mounting the view. Three lines of Swift; matches the Testability plan.

#### `Sources/Panels/PanelContentView.swift` (no changes expected)

- The mount at lines 22-29 already passes `onToggleCollapsed`. Nothing to touch.

#### `Sources/SurfaceMetadataStore.swift` (no changes)

- No new keys, no validation changes. Existing `title` ≤ 256, `description` ≤ 2048 caps hold.

#### `Resources/Localizable.xcstrings` (strings to add)

**Correction (reviewer caught):** the existing `titlebar.chevron` and `titlebar.empty_title` usages exist only as `String(localized:defaultValue:)` call sites in `SurfaceTitleBarView.swift` — they have **not** been added to the `.xcstrings` catalog yet. The existing `titlebar.*` entries in the catalog are all for window-titlebar controls (`titlebar.newWorkspace.*`, `titlebar.sidebar.*`, `titlebar.notifications.*`), unrelated to the surface title bar.

Action in this PR:

1. Add `titlebar.chevron` and `titlebar.empty_title` to the catalog with English + Japanese translations (they're currently compile-extracted but un-translated).
2. Add new keys for the directional labels:
   - `titlebar.chevron.collapse` → English "Collapse title bar" + Japanese translation.
   - `titlebar.chevron.expand` → English "Expand title bar" + Japanese translation.
3. Update the Button's `.accessibilityLabel` in `SurfaceTitleBarView.swift:66-69` to pick between the two new directional keys based on `effectiveCollapsed`.
4. Retire `titlebar.chevron` (the generic "Toggle description" key) — no longer referenced, remove from catalog too.

All additions follow `CLAUDE.md`'s localization rule (English + Japanese, non-negotiable).

#### `CLI/cmux.swift` (no changes)

- `set-title`, `set-description`, `get-titlebar-state` already exist and route through the same `surface.set_metadata` path. Behavior under this amendment is unchanged — the CLI writes raw strings, the renderer does the new parsing.

### Package / build

- `MarkdownUI` is already a transitive dependency (`GhosttyTabs.xcodeproj/project.pbxproj:41`, `:315`, `:592`). Confirm it's linked into the main app target (it is — `MarkdownPanelView` imports it and runs). No `Package.swift` or project.pbxproj edits expected.

### Threading

- Rendering happens on main; the markdown parse is synchronous inside MarkdownUI's view body, which is acceptable for strings capped at 2048 characters. No off-main parsing needed.
- No socket path changes.

### Portal-layering contract

- The M7 spec's layering rule (line 179: "edit overlay MUST be hosted from the AppKit portal layer") applies to the *edit overlay*, not to the static render. This PR does not touch edit UX. No portal changes.

---

## Testability

Two `tests_v2/` files + two Swift unit test files. The `tests_v2/test_m7_titlebar_toggle_gesture.py` from the draft was dropped (redundant with existing `test_m7_collapse_visibility.py`).

### New: `tests_v2/test_m7_titlebar_description_roundtrip.py` (renamed from `_expand_markdown`)

Socket-level store pass-through — confirms the preprocessor runs at render time only, not at write time.

1. Set description to `"Running **10 shards** on \`lat-412\`"`; assert `get-titlebar-state --json → result.description` returns the literal string including asterisks and backticks.
2. Set description to `"Line one\n\nLine two\n\n- item"` (mixed paragraph + list); assert literal preservation.
3. Set description to `"![alt](image.png)"` (an image — disallowed at render, preserved at store); assert store preservation.
4. Set description to a string with a fenced code block (` ```swift ... ``` `); assert store preservation.

### New: `cmuxTests/SurfaceTitleBarRenderTests.swift` (Swift, behavioral)

Adopts reviewer's suggestion: mount `SurfaceTitleBarView` in an `NSHostingView` at fixed width and assert layout invariants. Behavioral, not source-text.

1. **Multi-line title wrap in expanded state.** Render with a 100-char title, non-empty description, `collapsed = false`, fixed width 400pt. Capture `fittingSize.height`. Repeat with `collapsed = true`. Assert expanded height > collapsed height by at least `1 × titleLineHeight`.
2. **Empty-description collapse.** Render with a 100-char title, `description = nil`, `collapsed = false`. Capture height. Repeat with `collapsed = true`. Assert heights are equal (empty-description case ignores the collapsed flag per `effectiveCollapsed` rule).
3. **Description scroll cap.** Render with a 50-line markdown description (lists), `collapsed = false`. Assert the title bar's total height does not exceed `titleBarCollapsedHeight + titleBarDescriptionMaxHeight (=90pt) + padding`.
4. **Chevron-disabled with empty description.** Assert the chevron's `.disabled(true)` modifier is honored: programmatically invoke the button action path; assert `onToggleCollapsed` closure was NOT invoked when description is empty. (This closes the regression path flagged in review where tapping would write `titleBarUserCollapsed`.)

### New: `cmuxTests/DescriptionSanitizerTests.swift`

Direct unit test of `sanitizeDescriptionMarkdown(_:)`. Pure function, fair game per CLAUDE.md test-quality policy.

1. `"![alt](x.png) hello"` → `" hello"` (image stripped).
2. `"line\n```swift\ncode\n```\nafter"` → `"line\n\nafter"` (fenced block stripped).
3. `"| a | b |\n|---|---|\n| 1 | 2 |"` → `""` (table stripped).
4. `"**bold** and *italic*"` → unchanged.
5. `"- list item\n- another"` → unchanged.
6. `"[link text](https://example.com)"` → unchanged (link syntax passes; navigation is disabled elsewhere).

### Augment: `tests_v2/test_m7_collapse_visibility.py`

One extra assertion: after `cmux clear-metadata --key description`, `get-titlebar-state → collapsed` reads as today (flag unchanged), but the socket payload should include a new `effective_collapsed` field computed as `collapsed || description.isEmpty`. This requires extending `titleBarStatePayload` in `Workspace.swift:5992-6015` to emit `effective_collapsed`. **Small Workspace.swift change — adds to the "no changes expected" list above; now expected.**

### Intentionally *not* tested

- **Pixel-exact rendering of markdown.** MarkdownUI has its own test suite.
- **Window-drag conflict.** Now moot after removing whole-row tap. No coverage needed.
- **Japanese translation accuracy.** Out of scope; CLAUDE.md requires the translations exist, not that they're validated.

---

## Rollout

Single PR. No staged rollout. The three features are cheap to revert (one view file, one strings file, possibly one theme helper). No data migration; no canonical-key additions; collapsed-by-default default unchanged.

**Regression risk areas:**

- **Markdown parsing throwing on pathological input.** MarkdownUI is permissive but a malformed string with deeply nested syntax could in theory cause a reparse spike. Mitigation: the 2048-char cap holds; stress-test with a fuzz input during manual QA.
- **Header-row tap conflicting with existing focus routing.** The workspace's focus routing on click lives elsewhere; the title-bar's `.onTapGesture` is scoped to the `HStack` inside the title bar and does not propagate. But: in the SwiftUI tree, nested tap gestures can eat clicks. Verify that clicking the title bar does not steal focus from the underlying terminal. (The M7 spec specifically says "Source chip" etc. are secondary; the title bar itself should not steal terminal focus on click.)
- **Chevron position and RTL.** Moving the chevron to the trailing edge means RTL locales get it on the visual leading edge. This is the macOS-native behavior (trailing ≠ "right" in RTL). No change needed.

---

## Open questions

### Resolved in this revision

1. ~~**Chevron-only vs. whole-row tap.**~~ **Chevron-only.** Whole-row tap introduced two real risks (window-drag conflict; `.disabled()` not propagating to `.onTapGesture`, silently writing `titleBarUserCollapsed`). Cost > benefit for v1.
2. **Markdown subset breadth** — widened substantially. Now: accept MarkdownUI defaults minus images, fenced code, and tables; link navigation disabled. Operators can write headings, lists, bold/italic, inline code, blockquotes, rules.
3. ~~**Compact theme variance.**~~ 11pt base. Matches existing title-bar description font density.
4. **Graphics / images.** Still deferred. Path remains either (a) a separate `icon` canonical key per the M7 parking lot (line 465), or (b) bounded data-URI allowance inside description. Both non-trivial. Not in this PR.
5. ~~**Sidebar label rendering.**~~ Confirmed: `TitleFormatting.sidebarLabel` strips newlines and collapses whitespace. Multi-line title renders as single-line with ellipsis in the sidebar. Correct.
6. ~~**5-line description cap inside ScrollView.**~~ Wired in this PR. `.frame(maxHeight: ~90)` + internal `ScrollView`.

### Still open (reviewers please weigh in)

7. **Link navigation disabled vs. enabled.** The revised plan disables link navigation (`OpenURLAction { _ in .discarded }`). Alternatives: (a) open in embedded browser surface via `cmux browser` route; (b) open in system default browser; (c) confirmation dialog first. All three need plumbing this PR doesn't have. Disabled is the safe v1 choice but operators typing `[PR #42](https://github.com/...)` will click and get nothing. Is that acceptable friction, or should the PR grow to wire one of the open-paths?
8. **Headings in a 5-line-capped region.** We allow headings, but a `# Big Heading` on line 1 will chew into the 5-line cap quickly. Should heading sizes be compressed further (e.g., all heading levels become just "bold text, slightly larger") rather than a true heading hierarchy? Pragmatic answer: yes — the compact theme already does this via smaller font sizes, but the hierarchy is still visible. Acceptable for now.

---

## Non-goals (this PR)

- Push notifications when title/description changes (charter parking-lot; consumers poll).
- Icons or graphics (parking-lot).
- Persistence across restart (M2 parking-lot).
- Links, images, fenced code blocks (this amendment's explicit deferral).
- Source-chip rendering ("OSC", "AGENT", "YOU" chip) — covered by the original M7 spec at line 150, still not implemented; out of scope here.
- Edit UX / inline editing (§User edit UX in M7 spec, not yet built; out of scope here).

---

## Appendix: why not ship the missing M7 features in this PR too?

The M7 spec is considerably larger than what's implemented today. It includes: double-click-to-edit, source chip rendering, the `[•••]` overflow menu, portal-layered edit overlay, OSC precedence-gate re-routing. This PR intentionally does not touch those: they are independent scope, each carries its own risk, and the user request — "expand the title bar to show the full text, with line breaks and bolding" — maps cleanly to the three changes above. Landing them in one PR keeps the blast radius small and the review bounded.

---

## Revision log

**2026-04-18 — revised after parallel Claude + Codex review.**

### Accepted and applied

| Finding | Reviewer | Fix |
|---------|----------|-----|
| Missing `@Environment(\.colorScheme)` on `SurfaceTitleBarView` — compile error | Both | Added to file-by-file implementation plan |
| Whole-row `.onTapGesture` bypasses `.disabled()` → silent write to `titleBarUserCollapsed` | Claude | Removed whole-row tap; chevron-only |
| Whole-row tap conflicts with NSWindow drag | Claude | Removed whole-row tap |
| `Button` + parent tap can double-fire / ambiguous | Codex | Removed whole-row tap |
| Spec drift: MarkdownUI does not render disallowed syntax verbatim | Codex | Added explicit `sanitizeDescriptionMarkdown` preprocessor; widened rendered subset to MarkdownUI defaults minus images/fenced/tables; disabled link navigation |
| 5-line ScrollView cap must be decided in-PR | Both | Specified `.frame(maxHeight: ~90)` + internal `ScrollView`; replaces today's `.lineLimit(5)` hard cut |
| `titlebar.chevron` / `titlebar.empty_title` NOT in `.xcstrings` catalog yet | Codex | Corrected plan; added explicit steps to register and translate both |
| Edge case: `collapsed == false` + empty description = multi-line title with disabled chevron | Codex | Added `effectiveCollapsed = collapsed \|\| description.isEmpty` rule |
| Tests are storage smoke, not behavioral | Both | Added `cmuxTests/SurfaceTitleBarRenderTests.swift` using `NSHostingView` for height-delta assertions; added `DescriptionSanitizerTests.swift` for the pure preprocessor; renamed the storage test to make its scope honest |
| Redundant `test_m7_titlebar_toggle_gesture.py` | Claude | Dropped; auto-expand regression already covered by `test_m7_collapse_visibility.py` |
| Need to expose `effective_collapsed` for testability | This revision | Added one-line change to `titleBarStatePayload` in Workspace.swift |
| OQ #3 (font size) should be closed | Both | Closed — 11pt |
| OQ #5 (sidebar label) should be closed | Claude | Closed — unchanged |
| OQ #1 (whole-row tap) should be decided | Both | Decided — chevron-only |
| OQ #6 (ScrollView) should be decided | Both | Decided — in-PR |

### Rejected (with reasoning)

| Finding | Reviewer | Why rejected |
|---------|----------|--------------|
| Consider removing the chevron-move and shipping only markdown + multiline | Implicit Codex ("scope slightly too broad") | User explicitly asked for a shrink/expand control on the right. Dropping the chevron move would fail the primary ask. Mitigated instead by removing whole-row tap, which was the actual scope hazard |
| Consider an NSHostingView-based test for exact line count of title wrap | Codex | Accepted in principle, but exact line-count is SwiftUI-library behavior; the behavioral test now asserts height *delta* between collapsed and expanded, which catches the regression path without over-specifying SwiftUI internals |

### New questions surfaced by review

- Q7: Link navigation (disabled vs. embedded-browser vs. system-default) — deferred to reviewers.
- Q8: Heading hierarchy inside a 5-line-capped region — compact theme already flattens; documented.

---

## Reviews archived

Raw review outputs for audit:

- `/tmp/titlebar-review-claude.md` — Claude (Sonnet 4.6), merge readiness: ready-with-minor-fixes.
- `/tmp/titlebar-review-codex.md` — Codex, merge readiness: needs-revision.

Both reviewers agreed on the `.onTapGesture` regression path and the missing `@Environment(\.colorScheme)`; Codex uniquely caught the MarkdownUI spec-drift and the `.xcstrings` catalog error; Claude uniquely caught the specific `titleBarUserCollapsed` write path and the `test_m7_collapse_visibility.py` redundancy. Both independently confirmed the chevron move does not break existing tests.
