# c11mux Module 7 — Prominent Surface Title Bar Spec

A full-width title bar anchored to the top of every surface, always visible, carrying a short `title` and an optional longer `description`. Implements Module 7 of the [c11mux charter](./c11mux-charter.md). Storage and transport are provided by [Module 2](./c11mux-module-2-metadata-spec.md) — this spec does not introduce a new storage primitive.

Status: specification, not yet implemented. The `title` and `description` canonical keys are **graduated by this document** and ride on top of `surface.set_metadata` / `surface.get_metadata` / `surface.clear_metadata` (all M2-introduced methods; not present in the v2 API today).

---

## Terminology

- **Title bar** — the full-width strip at the top of a surface's content area, inside the surface's geometry (not the macOS window chrome or the sidebar).
- **Short title** — the string stored in the `title` canonical key. Plain text. Renders on the title-bar's first line and is the source of truth for the sidebar tab label.
- **Description** — the string stored in the `description` canonical key. Basic-Markdown-subset text. Renders in the title bar's expanded region only.
- **Collapsed / expanded** — the two display states of the title bar. Collapsed shows only the short title. Expanded shows the short title plus the rendered description.
- **Source of title** — the `metadata_sources.title.source` value. One of `explicit`, `declare`, `osc`, `heuristic` (enum owned by M2).

Where the charter says "sidebar tab title mirrors the title bar," this spec formalizes it as: `title` is the single source, the title bar renders it in full, the sidebar tab label renders a truncated projection of the same value.

---

## Goals

- Give every surface a persistent, glanceable heading that reads clearly across a ten-pane workspace.
- Let agents declare **why** a surface exists (the description) without polluting the short title.
- Route OSC 0/1/2, agent declarations, and user edits into a single precedence-governed metadata key (`title`).
- Remain agentically testable — every rendered state has a socket/CLI read-back.

## Non-goals (v1)

- **Per-tab or per-workspace icons.** Named in the parking lot below.
- **Rich Markdown** (block elements, links, embedded Mermaid, images). The v1 description subset is inline only.
- **Persistence across restart.** M2 keeps metadata in-memory; M7 inherits that.
- **Push/subscribe notifications when title/description changes.** Charter parking-lot item; consumers poll.
- **A second, independently settable "sidebar label" primitive.** There is one source — `title`.
- **Per-user title overrides saved to disk.** Covered by the persistence decision below; acceptable loss to preserve M2's simplicity.

---

## Canonical-key additions (contribution to Module 2)

M7 graduates two keys. These entries extend the reserved-key table in `docs/c11mux-module-2-metadata-spec.md` at lines 46–55, and participate in the "Extension rule" stated there at line 59.

**Amendment procedure (normative).** The M2 reserved-key table must gain rows for `title` and `description` **in the same commit that lands M7 implementation**, not as a follow-up. A stand-alone M7 commit without the M2 row additions leaves M2's spec internally inconsistent (`reserved_key_invalid_type` would be thrown against keys M2's table doesn't list). The M2 edit is mechanical: append two rows to the table at `docs/c11mux-module-2-metadata-spec.md:46–55` using the shape defined in this document's "Canonical-key additions" table below, and update the sidebar-rendering-order sentence at `docs/c11mux-module-2-metadata-spec.md:57` to reference M7 for `title`/`description` placement. No other part of M2 changes; in particular, the precedence chain, error contract, and socket-method signatures are untouched.

The M2 `source` enum's `osc` value — consumed by this spec — is already listed in M2's sidecar-source table at `docs/c11mux-module-2-metadata-spec.md:81–86`, so no enum amendment is required.

| Key | Type | Constraints | Rendering | Graduated by |
|-----|------|-------------|-----------|--------------|
| `title` | string, plain text | ≤ 256 chars; no control chars except whitespace; NFC-normalized on write | Title bar (line 1, full) + sidebar tab label (truncated per "Sidebar truncation rule" below) + pane-box selected-tab line (M8, same truncation) | M7 |
| `description` | string, basic-Markdown subset | ≤ 2048 chars; permitted inline marks: `**bold**`, `*italic*` / `_italic_`, `` `inline code` ``. No block-level elements (no headings, no lists, no blockquotes, no fenced code, no tables). No hyperlinks. No HTML. Unsupported syntax renders as literal text. | Title bar (expanded region only) | M7 |

Validation failures:

- `title` with a value > 256 chars → `reserved_key_invalid_type` (per M2's error convention; includes `{"key": "title", "reason": "too_long"}`).
- `title` containing `\n`, `\r`, or other C0 control chars (tab `\t` excluded — rejected too) → `reserved_key_invalid_type` with `reason: "invalid_char"`. Collapses to a single line unambiguously.
- `description` > 2048 chars → `reserved_key_invalid_type` with `reason: "too_long"`.
- `description` containing disallowed Markdown (e.g., leading `#`, `- ` at line start, ```` ``` ```` fence) → stored verbatim; renderer shows the raw character. No rejection at write time. Authors are expected to keep inline-only.
- Either key written with a non-string type → `reserved_key_invalid_type` with `reason: "wrong_type"`.

Write semantics follow M2's shallow-merge + per-key precedence model. A single `surface.set_metadata` call may land `title` and reject `description` (or vice versa); M2's per-key `applied` map reports which.

---

## Source values and writers

M7 maps writers to M2's source enum as follows. **No new enum values are introduced.**

| Writer | Source | Notes |
|--------|--------|-------|
| User CLI (`cmux set-title`, `cmux set-description`, `cmux set-metadata --key title --value ...`) | `explicit` | Highest precedence. User intent wins. |
| UI inline edit (title-bar field, context-menu edit, `⌘⇧T` then type) | `explicit` | Same precedence as CLI user writes. |
| Agent declaration (`cmux set-title` issued inside the surface's PTY process tree from an agent integration, or direct `surface.set_metadata` with `source: "declare"`) | `declare` | Overwrites `osc`/`heuristic`, not `explicit`. |
| Terminal OSC 0/1/2 sequence | `osc` | Newest OSC within `source: osc` wins; see "OSC binding" below. |
| Working-directory fallback ("first-word-of-cwd basename") | `heuristic` | Optional; only if enabled in the implementation. Never overwrites higher sources. |

M7 does **not** need to distinguish "user CLI" from "UI edit" — both land as `source: "explicit"`. If a future module needs that distinction, it extends M2's enum.

### OSC binding

OSC 0, OSC 1, and OSC 2 all set the terminal title string. In c11mux today, Ghostty's `GHOSTTY_ACTION_SET_TITLE` handler at `Sources/GhosttyTerminalView.swift:2171-2188` posts a `.ghosttyDidSetTitle` notification; `TabManager` listens at `Sources/TabManager.swift:830-842` and routes into `enqueuePanelTitleUpdate` → `flushPendingPanelTitleUpdates` → `updatePanelTitle` → `Workspace.updatePanelTitle(panelId:title:)` at `Sources/Workspace.swift:5857-5892`, which writes `panelTitles[panelId]` and calls `bonsplitController.updateTab(tabId, title:, hasCustomTitle:)`.

**M7 re-routes this call chain through the M2 metadata blob:**

1. `enqueuePanelTitleUpdate` (`Sources/TabManager.swift:2780`) coalesces OSC writes as today (debounce is still desirable — OSC titles can burst during shell-prompt redraw).
2. On flush, instead of calling `Workspace.updatePanelTitle` directly, issue an internal-equivalent `surface.set_metadata` with `{metadata: {"title": <osc-value>}, source: "osc"}` against the surface whose panelId matches. The same precedence gate M2 applies to external callers applies here: if the surface's current `metadata_sources.title.source` is `declare` or `explicit`, the OSC write is dropped with `applied: false, reason: "lower_precedence"`.
3. The sidebar and bonsplit tab label re-read `title` from the metadata blob (see "Render wiring" below) and re-render. `Workspace.panelTitles[panelId]` becomes a cached projection of the `title` canonical key, not an independent store.
4. **Null/empty OSC payload**: an OSC with an empty string clears `title` **only if** the current `metadata_sources.title.source == "osc"`. Otherwise the empty OSC is dropped. This matches the intuition "the shell that set the title via OSC is allowed to clear it by emitting an empty one, but can't blow away a user- or agent-set title." Implemented via `surface.clear_metadata { keys: ["title"], source: "osc" }` which respects M2's precedence-gated clear.
5. **Newest OSC wins within `source: osc`**: M2's precedence rule says `osc` can overwrite `osc`, so every OSC write lands as long as no higher source has taken over. No additional logic needed.

Legacy code paths that write directly to `Workspace.panelTitles` or `Workspace.customTitle` must be audited and funneled through the same `set_metadata` path. See "Implementation notes" for the call-site inventory.

The OSC writer binding above presumes the M2 reserved-key table already contains `title`. Per the amendment procedure stated above, the two-row addition to M2 (`docs/c11mux-module-2-metadata-spec.md:46–55`) lands in the same commit as this module's implementation — not as a follow-up PR.

---

## Anatomy and visual placement

The title bar sits inside the surface content area, above the Ghostty terminal view / browser WKWebView / markdown renderer. It is owned by the same AppKit host view that owns the surface's main content, so it participates in portal-layered rendering (see "Layering constraint" below).

### Heights

- **Collapsed:** **28 pt** total (one title row). Leaves ~2 terminal rows at 14-pt font but padding makes it visually a single "header band." No description is visible.
- **Expanded:** collapsed header (28 pt) + description region with intrinsic height up to **5 lines of the title-bar font** (~90 pt at 14-pt leading). Beyond 5 lines, the description scrolls inside the expanded region (internal NSScrollView) — the title bar itself does not grow unboundedly and does not steal meaningful terminal rows.
- **Hidden:** 0 pt (visibility toggle; see below). When hidden the surface gets 100% of its content area for the primary surface view.

### Default state on surface creation

- **Collapsed.** The description is usually empty; a collapsed bar is the minimum-intrusion default.
- **Auto-expand on first `description` set:** when `description` transitions from absent/empty → non-empty AND the title bar is collapsed AND the user has not explicitly collapsed this surface in the current session, auto-expand. A user-initiated collapse sets a per-surface session flag that suppresses auto-expand until next relaunch.

### Description formatting

Inline-only Markdown. The renderer parses a tight subset and emits styled text:

- `**bold**` and `__bold__` → bold.
- `*italic*` and `_italic_` → italic.
- `` `inline code` `` → monospace + subtle background fill (Module 5 palette role `code-fill`).
- `\n` in the source string wraps to a new line. Consecutive `\n\n` renders a visual paragraph break (extra half-line spacing).
- Backslash escapes (`\*`, `\_`, `` \` ``) render the literal character.

Everything else (lists, headings, blockquotes, fenced code, links, images, HTML) renders as literal text with no styling. Parker-lot item notes the path to richer rendering.

### Visual layout

Single row, left-to-right:

```
┌────────────────────────────────────────────────────────────────────────┐
│ [▸]  <title text>                                            [•••]     │
│      <description line 1>                                              │
│      <description line 2…>                                             │
└────────────────────────────────────────────────────────────────────────┘
```

- **`[▸]`** — disclosure chevron, rotates to `[▾]` when expanded. Click target for the collapse/expand gesture.
- **`<title text>`** — the `title` canonical key, rendered full (no truncation inside the title bar itself — it's the full-width container). Overflow ellipsizes on the trailing end if the surface is genuinely too narrow.
- **`[•••]`** — overflow menu button. Items: "Edit title…", "Edit description…", "Clear title", "Clear description", "Hide title bar". Matches macOS `NSPopUpButton` conventions.

Semantic palette roles (mapped to hex by [Module 5](./c11mux-module-5-brand-identity-spec.md), not here):

| Role | Purpose |
|------|---------|
| `titlebar-bg` | Title bar background fill |
| `titlebar-separator` | 1-pt line between title bar and surface body |
| `titlebar-title-text` | Primary title text color |
| `titlebar-description-text` | Description body color, slightly muted |
| `titlebar-source-chip-text` | Source-of-title chip foreground (see "Source chip" below) |
| `code-fill` | Inline `code` span background |

### Source chip (optional, per-brand)

A small kebab-case chip to the right of the title showing the source value (`OSC`, `AGENT`, `YOU`, `AUTO` — M5 owns labels). Hidden by default; revealed only when `metadata_sources.title.source != "explicit"` AND the surface's current hover/focus state warrants attention. The full source value is always queryable via `cmux get-titlebar-state` — the chip is a visual convenience, not the source of truth.

---

## User edit UX

Two entry points, both resolve to the same inline edit mode.

**Primary: double-click on the title text.**

- Double-click anywhere in the title bar's title region (not the chevron, not the overflow button) enters inline edit of the `title` field.
- The title text becomes an editable `NSTextField` with the same font/size. Enter commits with `source: "explicit"`; Escape cancels.
- Double-click on the description region enters description edit (multi-line `NSTextView`). Enter inserts a newline; `⌘↩` commits; Escape cancels.

**Backup: keyboard shortcut `⌘⇧T`.**

- Pressed while a surface is focused: enters title-edit mode on that surface's title bar (auto-expands if collapsed).
- A second press while in edit mode shifts focus from title → description (auto-expands if needed).
- Escape cancels edits and restores the prior values. Does not collapse.

**Context menu:** the overflow `[•••]` menu's "Edit title…" / "Edit description…" items trigger the same edit modes. Covers mouse-only users and accessibility paths.

**Edit-in-progress semantics:**

- While a user is editing, incoming `osc` or `declare` writes are queued (not dropped). On commit or cancel, the highest-precedence queued write lands. On `explicit` commit, the just-typed value wins outright.
- The `metadata_sources.title.ts` is the server's now-time at edit commit, not keystroke time.

### Layering constraint (MUST follow)

The title-bar edit overlay MUST be hosted from the AppKit portal layer, following the same pattern as `SurfaceSearchOverlay`. Specifically:

- The edit field is mounted as an `NSHostingView<…>` attached to the terminal's `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (see the `searchOverlayHostingView` field at `Sources/GhosttyTerminalView.swift:6139` and the root-view builder `makeSearchOverlayRootView` at `Sources/GhosttyTerminalView.swift:6898-6922`).
- The edit field MUST NOT be attached as a SwiftUI `TextField` inside `Sources/Panels/TerminalPanelView.swift` or any SwiftUI surface panel container. The note at `Sources/Panels/TerminalPanelView.swift:21` and the `CLAUDE.md` "Terminal find layering contract" rule both explain why: portal-hosted terminal views can sit above SwiftUI during split/workspace churn, so any edit field that lives in the SwiftUI tree gets event-routed incorrectly or hidden.
- Browser and markdown surfaces use different host views; for them, the edit overlay mounts inside the same host view that owns the WKWebView / markdown renderer. The rule generalizes to "the edit overlay lives in the same AppKit view the primary surface mounts into," not "always mount in `GhosttyTerminalView`."

This call-out belongs in the implementer's mental model from day one; a naive SwiftUI attempt will work superficially and break during pane reorders.

---

## Collapse / expand

- **Primary gesture:** click the chevron `[▸]` at the left edge of the title bar. Animates to expanded in ~180 ms.
- **Secondary gesture:** `⌘⇧D` (mnemonic: description) while the surface is focused.
- **Discoverability:** chevron is always visible in the collapsed state. In the expanded state it rotates to `[▾]`.
- **Description overflow:** if the description's intrinsic height exceeds the 5-line expanded cap, the description region becomes a vertically scrollable `NSScrollView` inside the title bar. Title-bar total height stays at collapsed-height + 5-lines-cap.
- **State is per-surface, in-memory, not persisted.** Matches M2's overall persistence model (acceptable simplification).

---

## Visibility toggle

- **Menu item:** View → "Show Title Bar" (checkbox). Default: checked.
- **Shortcut:** `⌘⇧H` while the surface is focused (`H` for "header"; check against existing AppDelegate shortcuts before allocating — if taken, fall back to `⌘⌥T`).
- **Scope:** per-workspace. Hiding the title bar hides it on every surface in the current workspace. The decision is stored on the workspace model, not on `Surface.metadata` — it's a render preference, not per-surface intent.
- **Interaction with Module 8:** hidden title bar still renders in `cmux tree` / `cmux get-titlebar-state` as `visible: false`. The `title` canonical key remains readable.

---

## Sidebar truncation rule (normative, new)

The sidebar tab label and Module 8's floor-plan pane-box "selected tab" line MUST use the following truncation when rendering `title`:

1. **Character cap:** 25 grapheme clusters (Swift `String.Character` units, which collate Unicode extended grapheme clusters). Not bytes. Not UTF-16 code units. Not Unicode scalars.
2. **Token-boundary awareness:** if the full string's `Character` count ≤ 25, render verbatim. Otherwise, find the last whitespace (`" "`, `"\t"`) boundary at or before cluster-index 24; truncate there. Append a single `…` (U+2026 horizontal ellipsis) — itself one grapheme cluster, not counted against the 25 cap.
3. **Fallback for pathological tokens:** if a single token's cluster count exceeds 25 (e.g., `ReallyLongContainerizedWorkflowRunnerNameWithoutSpaces`), hard-cut at cluster-index 24 and append `…` regardless of tokenization. Never split a grapheme cluster — the cut always lands on a cluster boundary.
4. **Normalization:** trim leading/trailing whitespace before applying the cap.
5. **Whitespace collapsing:** internal whitespace runs (including `\t`) collapse to a single space before truncation so `"Running   tests"` becomes `"Running tests"` before measurement.

This rule replaces the current SwiftUI tail truncation at `Sources/ContentView.swift:10872-10876` (for the workspace-list label) and the `lineLimit(1)` behavior at `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:121-128` (for per-pane bonsplit tab labels). Both must compute the truncated string through a shared helper (proposed: `TitleFormatting.sidebarLabel(from: String) -> String`) rather than delegating to SwiftUI's default truncation. Module 8's pane-box rendering reuses the same helper.

Legacy direct writes to bonsplit tab titles (e.g., from `Workspace.updatePanelTitle` → `bonsplitController.updateTab(tabId, title:, …)` at `Sources/Workspace.swift:5873-5877` and `Sources/Workspace.swift:5525-5529`, and every `panelCustomTitles` write site at `Sources/Workspace.swift:5511-5530`) must be audited. After M7, these writers must route through `surface.set_metadata` instead of mutating `panelTitles` / `panelCustomTitles` directly; those fields become render-cache projections of the `title` canonical key.

The existing `rename-tab` CLI (`CLI/cmux.swift:3422-3469` → `tab.action` with `--action rename`) becomes a thin alias for `cmux set-title --surface <ref>`. Tests at `tests_v2/test_rename_tab_cli_parity.py` are expected to continue passing after the route change — the external CLI contract is unchanged.

---

## CLI surface

All title/description writes are sugar over M2's `surface.set_metadata`. They exist as distinct commands to reduce typing and remove the ceremony of constructing single-key JSON; the justification is the same as `cmux set-agent` (M1) existing alongside `cmux set-metadata`.

### `cmux set-title`

```
cmux set-title [--surface <ref>] [--workspace <ref>] <title-text>
cmux set-title [--surface <ref>] [--workspace <ref>] --from-file <path>
cmux set-title [--surface <ref>] --json          # read raw socket result
```

Equivalent socket call:

```json
{"id":"t1","method":"surface.set_metadata",
 "params":{"surface_id":"<resolved>", "mode":"merge", "source":"explicit",
           "metadata":{"title":"<title-text>"}}}
```

- `--surface` defaults to `CMUX_SURFACE_ID` env var (same convention as M2's `cmux set-metadata`).
- `--workspace` narrows resolution when the ref is ambiguous; follows existing `--workspace` patterns.
- Empty `<title-text>` is rejected with `missing_title`. To remove: use `cmux clear-metadata --key title`.
- `--from-file -` reads from stdin.
- Exits non-zero with `applied=false, reason=lower_precedence` details when the precedence gate blocks the write. JSON mode emits the full `applied` / `reasons` map.

### `cmux set-description`

```
cmux set-description [--surface <ref>] [--workspace <ref>] <description-text>
cmux set-description [--surface <ref>] [--workspace <ref>] --from-file <path>
cmux set-description [--surface <ref>] --auto-expand=false
```

Equivalent socket call — identical shape to `set-title` with `metadata.description` instead. `--auto-expand=false` suppresses the "auto-expand on first set" behavior for this single write (useful for agents that are writing a description but don't want to claim screen real estate).

### `cmux get-titlebar-state` (new, required by testability)

A minimal read-back that answers the question "what does the title bar currently show for this surface?" without forcing consumers to compose multiple `surface.get_metadata` calls and a visibility query. Justified by the testability constraint — visible state (collapsed vs expanded, visible vs hidden) is not covered by M2's generic reader.

```
cmux get-titlebar-state [--surface <ref>] [--workspace <ref>] [--json]
```

Socket method: `surface.get_titlebar_state` (new, introduced by M7).

```json
{"id":"tb1","method":"surface.get_titlebar_state",
 "params":{"surface_id":"<uuid-or-ref>"}}
```

Response:

```json
{"id":"tb1","ok":true,
 "result":{
   "surface_id":"<uuid>",
   "title":"Running smoke tests",
   "title_source":"declare",
   "title_ts":1713313200.123,
   "description":"Running **10 shards** in parallel; reports to `lat-412`.",
   "description_source":"declare",
   "description_ts":1713313201.456,
   "collapsed":false,
   "visible":true,
   "sidebar_label":"Running smoke tests"
 }}
```

- All fields derive from M2's blob + per-workspace visibility state + per-surface session collapse state.
- `sidebar_label` returns the truncated projection per the "Sidebar truncation rule" — lets tests assert the exact string the sidebar renders without parsing SwiftUI.
- Omitted fields when missing: if `title` is unset, `title`, `title_source`, `title_ts` are absent.

Human-readable output (non-JSON mode):

```
surface=<uuid>
title=Running smoke tests   [declare]
description=Running **10 shards** in parallel; reports to `lat-412`.   [declare]
collapsed=false  visible=true
sidebar_label=Running smoke tests
```

### CLI conventions

- All three new commands honor `--socket`, `--json`, `--window`, `--workspace`, `--surface`, and `--id-format` per `docs/socket-api-reference.md`.
- All three commands follow M2's "default to focused surface if no `--surface` or `CMUX_SURFACE_ID`" rule.
- Exit code 0 on `applied: true`; non-zero on `applied: false` (matching other v2 CLI precedence-gated writes).

---

## Storage and persistence

- **In-memory, per-surface.** `title` and `description` live in the M2 metadata blob; they do not persist across app relaunch.
- **Rationale:** inheriting M2's model avoids introducing a second persistence path. Users who want durability set their title via a shell-init hook or a `cmux set-title` line in their agent's startup. Lattice, which already persists its task titles, can re-push on workspace reopen.
- **Collapse state** is in-memory per surface; **visibility state** is on the workspace model (also in-memory).
- **Future:** if a restart-persistence demand emerges, M2's parking-lot "persistence" item absorbs both title and description along with the rest of the metadata blob — no M7-specific persistence story.

---

## Interactions with other modules

- **Module 1 (TUI detection).** `cmux set-agent` writes `role`, `model`, `terminal_type` but does NOT touch `title`/`description` unless the caller explicitly passes them. An agent that wants to declare both identity and purpose issues two calls (or one `surface.set_metadata` with four keys). No special coupling.
- **Module 2 (metadata).** M7 adds two canonical keys; everything else (transport, precedence, shallow merge, 64 KiB cap, error codes) is M2's. `surface.set_titlebar_state` is not introduced — the getter is a read-only projection.
- **Module 3 (sidebar TUI chip).** The chip renders to the left of the tab label; M7 is orthogonal. The sidebar tab label (M7's truncated projection of `title`) and the chip (M3) coexist in the same sidebar cell. M3 spec owns the chip's exact placement and interaction; M7 commits only to "the tab label, whatever its position, uses M7's truncation rule."
- **Module 5 (brand identity).** M5 owns the hex mapping for M7's semantic palette roles (`titlebar-bg`, `titlebar-separator`, `titlebar-title-text`, `titlebar-description-text`, `titlebar-source-chip-text`, `code-fill`). M7 commits to the role names; M5 binds them.
- **Module 8 (`cmux tree` overhaul).** The pane-box "selected tab" line in M8's ASCII floor plan MUST use M7's sidebar truncation rule for consistency. M8 also exposes pane dimensions in pixel ranges; M7's title bar does not consume pane width — it sits within the pane's content area and has no impact on M8's layout math.
- **Legacy `rename-tab` CLI.** `cmux rename-tab` becomes an alias that routes through `surface.set_metadata { "title": <value>, "source": "explicit" }`. `tests_v2/test_rename_tab_cli_parity.py` continues to pass.
- **Window title.** `Sources/TabManager.swift:2829-2843` (`updateWindowTitle` / `windowTitle(for:)`) already pulls `tab.title` for the macOS window chrome title. After M7, `tab.title` on a single-surface workspace remains a projection of the focused surface's `title` canonical key, so the window title continues to track. For multi-surface workspaces, the window title behavior is unchanged by M7.

---

## Errors

Errors bubble up through M2's existing error contract. M7 adds no new top-level error codes. Soft results reuse M2's `applied: false` contract.

| Code | When |
|------|------|
| `reserved_key_invalid_type` | `title` > 256 chars, `description` > 2048 chars, wrong type, or disallowed control chars in `title` |
| `surface_not_found` | `--surface` or `surface_id` does not resolve (from M2) |
| `lower_precedence` | Soft per-key result; write did not land because a higher-precedence source holds the key |
| `missing_title` | `cmux set-title` called with empty string or missing argument — CLI-only, emitted before any socket call |

No new socket-level error codes. If the `surface.get_titlebar_state` implementation needs one for an unreachable surface (e.g., during close), reuse `surface_not_found`.

---

## Test surface (mandatory)

Every behavior is verifiable from a headless agent via `tests_v2/` Python tests. "Verify by eye" is not a test path.

### Write / read-back

1. `cmux set-title "Running tests"` → `cmux get-titlebar-state --json` → assert `result.title == "Running tests"`, `result.title_source == "explicit"`.
2. `cmux set-description "Shards **1-10** on \`lat-412\`"` → `cmux get-titlebar-state --json` → assert `result.description` preserves the literal string (Markdown is parse-on-render, not parse-on-store).
3. `cmux set-title ""` → reject with `missing_title` (CLI-level), no socket call.
4. `cmux set-title "$(python -c 'print("x"*257)')"` → socket returns `reserved_key_invalid_type`, key unchanged.

### Precedence ladder

For each adjacent pair in `explicit > declare > osc > heuristic`:

1. Write higher source first via `cmux set-metadata --key title --value foo` (using `--source` flag — if M2's CLI does not expose `--source`, use raw `cmux set-metadata --json` with an explicit source).
2. Write lower source via the same path; assert `applied: false, reason: "lower_precedence"` and `get-titlebar-state` shows unchanged value.
3. Write equal or higher source; assert `applied: true` and new value.
4. Repeat the specific scenario in the M7 charter: OSC emits title → agent `cmux set-agent` declaration → user `cmux set-title`. Assert `title_source` transitions `osc` → `declare` → `explicit` across the three steps.

### OSC binding

Via an injected PTY fixture (pattern established in other `tests_v2/` terminal tests):

1. Send the escape sequence `\x1b]2;OSC Title\x07` into the surface's PTY.
2. Poll `cmux get-titlebar-state` until `title == "OSC Title"` and `title_source == "osc"`.
3. Send `\x1b]2;\x07` (empty payload); assert `title` is cleared (current source was `osc`).
4. Set title via `cmux set-title "User Title"` (source `explicit`); send another OSC; assert title unchanged and `title_source == "explicit"`.

### Sidebar truncation

1. Via `cmux set-title "Running the full smoke suite across ten shards"` (long); `cmux get-titlebar-state --json`; assert `sidebar_label == "Running the full smoke…"` (token-boundary at the last space before char 25).
2. Via `cmux set-title "ReallyLongContainerizedWorkflowRunner"` (no spaces); assert `sidebar_label == "ReallyLongContainerizedW…"` (hard-cut fallback, exactly 24 chars + ellipsis).
3. Via `cmux set-title "Short"`; assert `sidebar_label == "Short"` (no truncation).
4. Via `cmux set-title "  Padded   inner   spaces  "`; assert `sidebar_label` collapses inner whitespace and trims.

### Collapse / expand / visibility

1. `cmux get-titlebar-state` on a new surface → `collapsed: true` (default).
2. `cmux set-description "something"` → `collapsed: false` (auto-expand on first description set).
3. User collapses via the UI (simulated by a test helper that sends the equivalent chevron-click or `⌘⇧D`); subsequent `cmux set-description "new"` does NOT auto-expand.
4. View → Show Title Bar toggle; assert `visible: false` after hide; `cmux set-title "still works"` still lands in `title`; on re-show, title appears.

### Legacy rename-tab parity

`tests_v2/test_rename_tab_cli_parity.py` continues to pass unchanged. Add one assertion: after `cmux rename-tab --tab <ref> "X"`, `cmux get-titlebar-state --json` returns `title == "X", title_source == "explicit"`.

### Test location

All tests live under `tests_v2/` following existing conventions:

- `tests_v2/test_m7_title_read_write.py`
- `tests_v2/test_m7_description_read_write.py`
- `tests_v2/test_m7_precedence_ladder.py`
- `tests_v2/test_m7_osc_binding.py`
- `tests_v2/test_m7_sidebar_truncation.py`
- `tests_v2/test_m7_collapse_visibility.py`
- Augment `tests_v2/test_rename_tab_cli_parity.py` with the one extra assertion above.

No screen scraping, no pixel comparison, no PTY buffer diffing. All assertions run through `cmux get-titlebar-state` or `cmux get-metadata`.

### Artifact-level fallback

If future brand rendering (Module 5) adds, e.g., a Stage 11 insignia behind the title-bar background, the pixel-correctness of that insignia is out of M7's test scope. Agents assert that `get-titlebar-state` returns the expected data; brand-rendered pixels are verified by Module 5's bundle-artifact checks (if any) or remain explicitly non-tested.

---

## Implementation notes (non-normative)

Starting points for the implementer.

### Swift files to touch

- **`Sources/GhosttyTerminalView.swift:2171-2188`** — replace the direct `NotificationCenter.default.post(name: .ghosttyDidSetTitle, …)` result-handling chain. The notification itself can remain; the receiver at `Sources/TabManager.swift:830-842` is what changes.
- **`Sources/TabManager.swift:2780-2808`** — `enqueuePanelTitleUpdate` → `flushPendingPanelTitleUpdates` → `updatePanelTitle` chain. After M2 is in, `updatePanelTitle` becomes a small wrapper that issues an internal `surface.set_metadata` with `source: "osc"` against the panel's surface and lets the M2 precedence gate decide whether the write lands. The existing debounce / coalesce logic is preserved — the coalescer is still useful to avoid per-keystroke OSC storms.
- **`Sources/Workspace.swift:5857-5892`** — `updatePanelTitle(panelId:title:)`. After M7, this becomes a read-through that reflects the canonical-key state back into `panelTitles` (render cache) and calls `bonsplitController.updateTab` with the truncated sidebar label. Writes to `panelTitles` from paths other than this function must be audited.
- **`Sources/Workspace.swift:5511-5530`** — `setPanelCustomTitle(panelId:title:)`. Today this stores into `panelCustomTitles[panelId]`. After M7, it becomes sugar over the same `surface.set_metadata { title: <value>, source: "explicit" }` flow; `panelCustomTitles` can stay as a render cache or be removed entirely in favor of reading `metadata.title` with `metadata_sources.title.source == "explicit"`.
- **`Sources/ContentView.swift:10872-10876`** — replace the `Text(tab.title).lineLimit(1).truncationMode(.tail)` with `Text(TitleFormatting.sidebarLabel(from: tab.title)).lineLimit(1)` (no trailing truncation — the helper already emits the ellipsized form).
- **`vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift:121-128`** — same change: run `tab.title` through the shared helper before rendering. Note bonsplit is a submodule; changes there follow the "Submodule safety" rule in `CLAUDE.md` (push to `manaflow-ai/bonsplit` fork first, then bump pointer).
- **`CLI/cmux.swift`** — add `set-title`, `set-description`, `get-titlebar-state` dispatch cases, mirroring `rename-tab`'s shape at `CLI/cmux.swift:3422-3469`. `rename-tab` itself can stay or be reimplemented as a delegator to `set-title`.
- **`Sources/TerminalController.swift`** — add `surface.set_titlebar_state`-wait, no, only `surface.get_titlebar_state`. Route near the `sidebar_state` handler at `Sources/TerminalController.swift:1812-1813` and the `set_status` handler at `1731`. Follow the "off-main parse/merge, main-thread-only-for-UI" threading policy in `CLAUDE.md` — since this is a read, it can run fully off-main once M2's storage lock is respected.
- **`Sources/Panels/TerminalPanelView.swift`** — hosts the terminal panel. The title bar itself mounts above the `GhosttyTerminalView` here, but the **edit overlay** for the title/description MUST be portal-hosted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (mirror `searchOverlayHostingView` at `Sources/GhosttyTerminalView.swift:6139` and `makeSearchOverlayRootView` at `Sources/GhosttyTerminalView.swift:6898-6922`). The title-bar's static (non-editing) render can live in the SwiftUI tree; only the active edit field needs portal hosting.
- **`Sources/Localizable.xcstrings`** — every new user-facing string (menu items, tooltips, shortcut labels, "Edit title…", "Edit description…", "Clear title", etc.) MUST be added with an English default and Japanese translation per `CLAUDE.md`'s localization rule.

### Shared helpers to add

- `Sources/Metadata/TitleFormatting.swift` (new): `static func sidebarLabel(from title: String) -> String`. Used by the workspace sidebar, bonsplit tab labels, and Module 8's floor-plan pane box. Keep the function pure (no state), unit-test it directly in `cmuxTests/`.

### Threading

- Title-bar rendering (read of `title`/`description`) happens on main; the canonical-key read from M2 is a dictionary lookup under M2's per-surface lock, which M2's spec defines as safe from main with a quick read-copy.
- Title-bar writes (user edits, OSC writes, agent declarations) always go through `surface.set_metadata`, whose handler follows M2's off-main parse/merge policy. Re-render is `DispatchQueue.main.async` from the post-merge callback.
- The `panelTitleUpdateCoalescer` debounce at `Sources/TabManager.swift:2785` is preserved. Its flush handler remains the right place to issue the internal `set_metadata` call for OSC.

### Localization

Every user-visible string introduced by M7 — menu items ("Show Title Bar", "Edit title…", "Edit description…", "Clear title", "Clear description"), tooltips (`⌘⇧T`, `⌘⇧D`, `⌘⇧H` chord labels), placeholder text ("Title", "Description"), error CLI messages emitted to the user — must go through `String(localized:defaultValue:)` and land in `Resources/Localizable.xcstrings` with English and Japanese strings. The CLAUDE.md rule is non-negotiable.

### Testing hygiene

- No tests that grep source text or assert on `panelTitles` dictionary contents; all behavior is exercised via CLI / socket per `CLAUDE.md`'s test-quality policy.
- The shared `TitleFormatting.sidebarLabel` helper is the one exception where a direct unit test is appropriate — it's a pure function and the right test path is direct call + assertion on return value.

---

## Open questions

- **Should `title` auto-populate from cwd on surface creation?** A `source: "heuristic"` fallback of `basename(cwd)` when nothing else has set the title would keep new terminals from showing "Tab" / empty. This spec leaves it as optional-at-implementer-discretion (either is consistent with M2). Recommendation: start without it; add iff operators complain about empty titles.
- **Does `description` deserve a parser crate or can we roll our own inline subset?** The listed subset is small enough for a hand-written scanner; pulling in a full Markdown crate is overkill. Defer to the implementer.
- **Swift `String.prefix(_:)` cluster safety.** The sidebar truncation rule counts in `String.Character` units (Swift's extended-grapheme-cluster view), so Zalgo stacks and emoji ZWJ sequences count as one each and never split. Swift's `String.prefix(_:)` operates on `Character` when called on a `String` and is safe; if the implementer reaches for a lower-level view (`unicodeScalars`, `utf16`, `utf8`) for any reason, they must convert back to `Character` counts before applying the cap.
- **Per-tab icon canonical key (`icon`).** Explicit parking-lot item. When it graduates, an `icon` canonical key sits in the M2 reserved-key table alongside `title`/`description`, stores either an SF Symbol name (string) or a small data URI (bounded size). It renders to the left of the title in the title bar AND to the left of the tab label in the bonsplit tab strip — collides with M3's TUI chip position, so the graduator must resolve the precedence between agent-chip and user-icon. Sketched here so a future module has a starting point; out of v1 scope.
- **Rich Markdown in description.** Block-level Markdown (headings, lists, fenced code), hyperlinks, and embedded Mermaid are the obvious next rung. Each has asset and security implications (Mermaid needs JS sandbox; links need click routing; images need fetch rules). Kept out of v1; a future module graduates them with a new `description_format` flag or a per-surface renderer config.
- **`description` Markdown renderer on non-terminal surfaces.** The browser and markdown surface types have their own content renderers; does the title bar use the same markdown renderer across all three, or a title-bar-specific lightweight one? Recommend a specialized lightweight one since the permitted subset is inline-only and reusing the full markdown-surface renderer invites scope creep. Flagged for the implementer's judgment.
- **Auto-expand retention across workspace switches.** If a user collapses a title bar in surface A, switches away, comes back — does the collapse state persist within the session? This spec says yes (in-memory, per-surface, session-scoped). Confirm acceptable ergonomically; if operators want "re-expand on return," wire a "last-expanded time" and re-check auto-expand rules on focus.
- **Per-surface visibility vs per-workspace visibility.** This spec chose per-workspace because the hide-title-bar action reads as "make this workspace quieter." If per-surface feels more natural during implementation, downgrade to per-surface; the testability surface (`cmux get-titlebar-state --surface <ref> → visible`) already supports either scoping.
