# c11 — Workspace Metadata Persistence + Rich Sidebar Rows

**Status:**
- **Phase 1 (persistence layer + socket + CLI) — SHIPPED 2026-04-18** via parallel tier-1 persistence work. Convergent implementation: `Workspace.metadata`, `SessionWorkspaceSnapshot.metadata`, `workspace.{set,get,clear}_metadata` socket methods, CLI (`set-workspace-metadata` + `set-workspace-description` / `set-workspace-icon` aliases), and autosave fingerprint update all landed. `Sources/WorkspaceMetadataKeys.swift` is byte-identical to this plan's spec.
- **Phases 3 (sidebar description render) and 4 (workspace icon) — still open.** This doc is the reference for those.
- **Phase 2 (shared markdown helpers) — likely no-op;** verify at Phase 3 start.
- **Phase 5 (docs) — follows.**

**Related:** [M7 title bar amendment](./c11mux-module-7-expandable-title-bar-amendment.md). Phase 3 reuses M7's module-scope `sanitizeDescriptionMarkdown` and `titleBarMarkdownTheme` helpers from `Sources/SurfaceTitleBarView.swift`.

---

## Motivation

Two problems, one plan:

1. **Workspace metadata does not persist what it should.** The session snapshot (`Sources/SessionPersistence.swift:330`) already carries `customTitle`, `customColor`, `isPinned`, `log`, `progress`, and `gitBranch` across restart. Status entries and agent PIDs are **intentionally ephemeral** — cleared on restore (`Sources/Workspace.swift:243-247`). But there is no durable slot for operator-authored workspace *description*, *icon*, or future free-form metadata. `SurfaceMetadataStore` is in-memory only (documented at `Sources/SurfaceMetadataStore.swift:60-63`), so surface titles also vanish on restart — the M7 amendment explicitly parks that ("Persistence across restart (M2 parking-lot)"). The hole is wider than just title bars: anything an operator types to customize a workspace for recognition is lossy.
2. **Sidebar rows are scannable but not distinctive.** With 10–20 workspaces, operators can't tell them apart at a glance. Title + color is not enough. `SidebarMetadataMarkdownBlocks` (`Sources/ContentView.swift:12180`) already renders agent-emitted markdown in the sidebar, so the row is not "plain text only" — the Rubicon is crossed. But there's no *operator-authored* rich-text slot. And there's no icon slot at all.

Mirror the M7 instinct ("make the title bar a card, not a label") where it fits, and *don't* mirror it where it doesn't. The sidebar row's job is recognition; it should get an icon and a short rich subtitle, not an expand/collapse state.

---

## Scope

### In scope
1. Durable workspace-level metadata store (extends `SessionWorkspaceSnapshot`).
2. Socket surface for reading/writing workspace metadata.
3. `workspace.description` canonical key (≤2048 chars, markdown subset identical to M7's sanitizer).
4. `workspace.icon` canonical key (single-character emoji or bundled glyph name, ≤32 chars).
5. Sidebar row consumes both: icon renders in leading slot, description replaces the plain `effectiveSubtitle` when set, markdown-rendered with a 2-line cap.
6. CLI commands to set/clear both keys.

### Explicitly not in scope
- **Expand/collapse state for sidebar rows.** Rows stay compact by contract. Detail lives in the surface, not the sidebar.
- **Graphics / bitmaps / SVG in description.** Same reasoning as M7 parks it — security + visual-budget + data-URI concerns. Icons are character-only in v1.
- **Markdown in the workspace *title*.** Title remains plain text with newlines stripped (`TitleFormatting.sidebarLabel` already strips them).
- **Per-workspace theme overrides** beyond `customColor` (already exists).
- **Restoring `SurfaceMetadataStore` across restart.** That's M7's parking-lot item; this plan does not claim it. Surface-level metadata persistence is a separate PR.
- **Notifications on metadata change.** Consumers poll via socket.

---

## Architecture

Three layers, top-to-bottom:

```
┌────────────────────────────────────────────────────────┐
│ Sidebar row (TabItemView) / CLI                        │  ← consumer
├────────────────────────────────────────────────────────┤
│ Socket methods (workspace.set_metadata, .get_metadata) │  ← transport
├────────────────────────────────────────────────────────┤
│ Workspace metadata storage                             │  ← durability
│   - In-memory: Workspace.metadata: [String: String]    │
│   - On-disk:  SessionWorkspaceSnapshot.metadata        │
└────────────────────────────────────────────────────────┘
```

No new `WorkspaceMetadataStore` class. The existing session-snapshot save/load cycle is the persistence mechanism; extending `SessionWorkspaceSnapshot` with a `metadata: [String: String]?` dictionary gets us durability for free. A parallel in-memory dictionary on `Workspace` (the mutable class aliased from `Tab`) holds the runtime state and writes through.

---

## Phase 1 — Persistence layer

**Deliverable:** workspace-scoped key/value metadata that survives restart, wired end-to-end but not yet consumed by UI.

### Data model

Extend `SessionWorkspaceSnapshot` (`Sources/SessionPersistence.swift:330`):

```swift
struct SessionWorkspaceSnapshot: Codable, Sendable {
    var processTitle: String
    var customTitle: String?
    var customColor: String?
    var isPinned: Bool
    // ... existing fields ...
    var metadata: [String: String]?   // NEW — optional for backward compat
}
```

**Schema compat:** new field is optional; existing snapshots decode fine without it. No `SessionSnapshotSchema.currentVersion` bump required — only bump if the old app would *misinterpret* a new field, which it won't (it'll ignore unknown keys on decode with `JSONDecoder`'s default behavior).

Add a parallel mutable dictionary on the `Workspace` class (`Sources/Workspace.swift`). `Workspace` is `@MainActor` (`Workspace.swift:4818`), so all mutations must happen on the main actor — matching the existing pattern for every other `@Published` property on this class:

```swift
@Published var metadata: [String: String] = [:]
```

Restore path in `Workspace.restoreFromSnapshot(...)` alongside `customTitle` / `customColor` / `isPinned` assignments (`Workspace.swift:239-241`):

```swift
if let meta = snapshot.metadata { workspace.metadata = meta }
```

Save path mirrors `customTitle` / `customColor` in `TabManager.buildSessionWorkspaceSnapshot(...)`.

**Autosave dedupe must be updated.** `TabManager.sessionAutosaveFingerprint()` (`TabManager.swift:4879-4918`) hashes selected workspace fields to decide whether the snapshot has changed since the last save. If `metadata` is omitted, value-only metadata edits (same key count, different values) look identical to the previous snapshot and the write is deferred up to the 60-second forced-save window (`AppDelegate.shouldSkipSessionAutosaveForUnchangedFingerprint` at `AppDelegate.swift:3593`). Fix: hash metadata by iterating keys in sorted order and feeding `key`+`value` into the same combiner used for the other fields. Deterministic, O(n·log n) once per autosave tick.

### Key validation

New file `Sources/WorkspaceMetadataKeys.swift` (small, focused — ~70 lines):

```swift
/// Canonical operator-authored workspace metadata keys.
///
/// This is workspace-scoped and distinct from `MetadataKey` in
/// `SurfaceMetadataStore.swift` (surface-scoped). Same string literals
/// ("description", etc.) in different namespaces; do not cross them.
enum WorkspaceMetadataKey {
    static let description = "description"
    static let icon = "icon"
    // future canonical keys here
}

enum WorkspaceMetadataValidator {
    static let maxDescriptionLen = 2048
    static let maxIconLen = 32
    static let maxCustomKeys = 32
    static let maxCustomValueLen = 1024
    static let maxCustomKeyLen = 64

    /// Key grammar: non-empty ASCII letters/digits/underscore/dot/hyphen.
    /// Matches `^[A-Za-z0-9_.-]+$`. No whitespace, no arbitrary UTF-8.
    /// Rationale: stable socket wire shape, no escape surprises in logs/CLI.
    static let keyPattern = #"^[A-Za-z0-9_.\-]+$"#

    static func validate(key: String, value: String) throws { ... }
}
```

Write-path calls `validate(key:value:)`. Canonical keys have specific caps; custom keys allowed up to the generic caps with the key grammar enforced. Mirrors `SurfaceMetadataStore.validateReservedKey` pattern (`Sources/SurfaceMetadataStore.swift:147-175`; the `description` cap branch is at `:170-171`).

### Socket surface

Add two methods to the `workspace.*` namespace in `Sources/TerminalController.swift` (current methods at `:2058-2091`):

- `workspace.set_metadata` — args: `workspace_id` (UUID), `key` (String), `value` (String or null for delete).
- `workspace.get_metadata` — args: `workspace_id`, optional `key`. Returns the full dictionary if key omitted, single value otherwise.

**Threading.** Existing workspace socket handlers marshal through `v2MainSync` for `Workspace` reads/writes (e.g., `workspace.rename` at `TerminalController.swift:3816`, `workspace.remote.configure` at `:4218`). Follow that pattern:

1. Parse and validate arguments **off-main** (per `CLAUDE.md` "Socket command threading policy").
2. Perform the `Workspace.metadata` read or write **on main actor** via `v2MainSync`. Writes are model mutations of a `@MainActor @Published` property, so main-actor execution is required; the `v2MainSync` call site should carry an inline comment pointing at the threading policy.
3. Keep the on-main critical section minimal — the write is a dictionary update and nothing more.

**Persistence trigger.** Do **not** claim a "debounced save" API. The existing autosave machinery is already the right mechanism: `AppDelegate` owns a private `saveSessionSnapshot` method and an autosave timer (`AppDelegate.swift:3403`, `:3501`), with dedupe via `TabManager.sessionAutosaveFingerprint()`. Metadata edits flow through the autosave timer once the fingerprint is updated (see Data model section above). If a synchronous flush is required (e.g., before app termination), the existing quit hook handles it.

If the implementer finds autosave latency unacceptable for metadata writes, the correct move is to add a new public `AppDelegate.requestSessionAutosave(reason:)` entry point (small, scoped) that the socket handler can call — **not** to reach into private save methods. Flag as a follow-up; do not bundle with Phase 1.

`workspace.rename` (existing) writes `customTitle` and continues to be the title path — does not write through `metadata`. Keep title separate so it doesn't get tangled with arbitrary-key validation.

### CLI

The existing CLI uses flat-verb grammar (`list-workspaces`, `new-workspace`, `workspace-action`, per `CLI/cmux.swift:1641-1693`, usage at `:12290+`). Match that style — do **not** introduce a nested `cmux workspace ...` subcommand tree in this PR.

New commands:
- `cmux set-workspace-metadata <key> <value>`
- `cmux get-workspace-metadata [<key>]`
- `cmux clear-workspace-metadata <key>`
- Convenience aliases: `cmux set-workspace-description <text>`, `cmux set-workspace-icon <glyph>` (sugar over `set-workspace-metadata description|icon ...`).

Target defaults to the currently-focused workspace. `--workspace-id` flag for scripted access.

All command help strings, error messages, and validation messages go through `String(localized:defaultValue:)` and are registered in `Resources/Localizable.xcstrings` with English + Japanese translations per `CLAUDE.md` localization rule.

### Phase 1 tests

- `tests_v2/test_workspace_metadata_roundtrip.py` — set, get, clear, restart-and-reload (via session snapshot fixture), confirm persistence.
- `cmuxTests/WorkspaceMetadataValidatorTests.swift` — pure unit test for the validator (canonical caps, custom-key caps, rejects empty keys, accepts emoji in values).
- `tests_v2/test_workspace_metadata_limits.py` — reject oversize, reject too many custom keys, reject disallowed chars in keys.

**Phase 1 exits with durable KV workspace metadata, socket and CLI exposure, but no UI consumer yet.** It's landable as its own PR.

---

## Phase 2 — Shared markdown helpers

**Deliverable:** the M7 sanitizer and compact theme factory are reachable from outside `SurfaceTitleBarView.swift` without duplicating code.

### Current state (verified)

M7's helpers are already landed at module scope (not `private`) in `Sources/SurfaceTitleBarView.swift`:

- `func sanitizeDescriptionMarkdown(_ input: String) -> String` at line 147.
- `func titleBarMarkdownTheme(for colorScheme: ColorScheme) -> Theme` at line 194.

Module scope = reachable from any file in the same target. No extraction required for Phase 3 to consume them; just call them.

### Minor cleanup (optional, only if Phase 3 forces it)

If the sidebar needs a *different* max-height than the title bar (it does — 2-line cap vs. 5-line cap), that parameter lives on the consumer side (`.frame(maxHeight:)`), not in the theme. Theme itself is reusable as-is.

**If the in-flight M7 agent moves these helpers to `private`, coordinate to revert that one line.** Keep them at module scope. No new file, no churn.

### Phase 2 tests

No new tests. M7's tests already cover sanitizer behavior (`cmuxTests/DescriptionSanitizerTests.swift` per the amendment plan).

**Phase 2 is a 0-line or 1-line change depending on what the M7 agent ships.** Might fold into Phase 3.

---

## Phase 3 — Workspace description in the sidebar

**Deliverable:** when `workspace.metadata["description"]` is set, the sidebar row renders it as markdown below the title, capped at 2 lines, replacing today's plain `effectiveSubtitle`.

### Render changes

Target: `TabItemView.effectiveSubtitle` logic in `Sources/ContentView.swift` (around the subtitle branch at line 10933).

**Critical constraint: TabItemView performance invariant.** `TabItemView` is `Equatable` with `==` defined at `ContentView.swift:10562`, and is called via `.equatable()` at `:8209`. The `==` check uses `lhs.tab === rhs.tab` (identity), which means any direct read of `tab.metadata[...]` in the body will be suppressed by SwiftUI's equatable short-circuit — **the description would never update after initial render.** `CLAUDE.md` lines 139-142 explicitly warn against this. The pattern the file already uses (for `agentChip`, `latestNotificationText`, `unreadCount`) is to precompute in the parent `ForEach` call site and pass as `let` parameters.

Step 1 — extend `TabItemView` parameters:

```swift
// In TabItemView struct definition
let workspaceDescription: String?   // non-empty trimmed description, else nil
let workspaceIcon: String?          // validated icon string, else nil
```

Step 2 — extend `==` at `ContentView.swift:10562`:

```swift
lhs.workspaceDescription == rhs.workspaceDescription &&
lhs.workspaceIcon == rhs.workspaceIcon &&
// ...existing comparisons
```

Step 3 — parent `ForEach` (the site that constructs `TabItemView` in `VerticalTabsSidebar`) precomputes:

```swift
let description = tab.metadata[WorkspaceMetadataKey.description]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .nonEmptyOrNil
let icon = tab.metadata[WorkspaceMetadataKey.icon]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .nonEmptyOrNil
TabItemView(
    tab: tab,
    // ...existing params
    workspaceDescription: description,
    workspaceIcon: icon,
)
```

Step 4 — render in the body:

```swift
if let description = workspaceDescription {
    SidebarDescriptionView(
        markdown: description,
        colorScheme: colorScheme,
        foreground: activeSecondaryColor(0.85)
    )
} else if let subtitle = effectiveSubtitle {
    Text(subtitle)
        .font(.system(size: 10))
        .foregroundColor(activeSecondaryColor(0.8))
        .lineLimit(2)
        .truncationMode(.tail)
}
```

`SidebarDescriptionView` is a new small `View` struct (same file or new `Sources/SidebarDescriptionView.swift`, ~50 lines). It encapsulates:
- `sanitizeDescriptionMarkdown(markdown)` preprocessing.
- `Markdown(...)` render with `sidebarDescriptionMarkdownTheme(for: colorScheme)`.
- `.environment(\.openURL, OpenURLAction { _ in .discarded })` to disable link navigation.
- **Hard height cap** via `.frame(maxHeight: sidebarDescriptionMaxHeight)` (where `sidebarDescriptionMaxHeight = ~26pt`, i.e. `2 × lineHeight(10pt)`). `.lineLimit(2)` alone does not reliably clamp MarkdownUI output when block elements are present; the hard frame cap is the contract. Content that overflows is clipped (not scrollable — sidebar rows don't scroll).
- `.accessibilityLabel(...)` using `String(localized:)` to describe the row as "Workspace description: …".

Add `sidebarDescriptionMarkdownTheme(for:)` as a sibling of `titleBarMarkdownTheme` (either in `SurfaceTitleBarView.swift` or a new tiny `Sources/MarkdownThemes.swift`). **Differences from title bar theme:**
- Base font 10pt (sidebar density) vs. 11pt.
- Heading sizes compressed further — `H1/H2/H3 = 11/10.5/10` (nearly-flat hierarchy; sidebar shouldn't shout).
- Zero vertical margins on block elements (2-line cap).
- Inline code fill: same subtle chip as title bar.

### Markdown subset

Identical to M7's sanitizer output. No new sanitizer. Images, fenced code, tables stripped. Links rendered as styled text, navigation disabled. One extension **not needed here:** the 2-line cap naturally suppresses anything that would have wrapped past 2 lines, so we don't need further per-element gating.

### Color tokens

Consumes the gold-on-void active treatment we just landed — description text color is `activeSecondaryColor(0.85)`, which resolves to `BrandColors.white` on active rows and `.secondary` on inactive rows. No additional brand-color work.

### Phase 3 tests

**Testability seam required.** `TabItemView` is `private` (`ContentView.swift:10559`) and cannot be instantiated from `cmuxTests`. Do not change its visibility — it's intentionally scoped. Instead, test `SidebarDescriptionView` directly (it's the new component introduced above, and can be declared `internal`). This keeps the behavioral assertions at the right layer: markdown rendering and height-clamp behavior belong to `SidebarDescriptionView`, not to the row composition that contains it.

Tests:

- `tests_v2/test_workspace_description_roundtrip.py` — socket-level roundtrip:
  1. `set-workspace-metadata description "hello"` → `get-workspace-metadata description` returns `"hello"`.
  2. Set description with markdown syntax → get returns literal string unchanged (preprocessor runs only at render time).
  3. Clear description → get returns nil / no key.
- `cmuxTests/SidebarDescriptionViewTests.swift` (behavioral, `NSHostingView`-based — targets the public-to-tests `SidebarDescriptionView`):
  1. Plain description `"hello world"` → mounted view renders at a height equal to a single 10pt line (± rendering tolerance).
  2. Description with a single `\n` → two-line height.
  3. 50-line description → mounted view height **does not exceed** `sidebarDescriptionMaxHeight` (the 2-line cap is enforced).
  4. Description `"![alt](x.png) hello"` → rendered view contains no image; text-only height matches `"hello"` baseline.
  5. Description `"[link](https://example.com)"` → `OpenURLAction` is invoked with `.discarded` result (link tap does nothing). Assert via a test-scoped `OpenURLAction` stub that records calls.
- `cmuxTests/SidebarDescriptionPrecedenceTests.swift` — precedence logic only (does not need NSHostingView; can assert the precomputed `workspaceDescription` value against `effectiveSubtitle` selection via a small internal helper extracted from `TabItemView`). If the helper cannot be extracted cleanly, add a new `tests_v2/test_sidebar_description_precedence.py` that sets a notification + a description and reads back via `workspace.get_metadata` + `notifications.list` to verify both observables are correct, even though the rendered precedence is asserted only indirectly.

**Note on sidebar-state observability.** `sidebar.state` / `v2SidebarState` (`TerminalController.swift:7801-7833`) reports counts and agent-chip metadata, not workspace `metadata`. Do not extend it for this feature; use `workspace.get_metadata` as the test observable. If a later feature needs sidebar-render observability for e2e tests, extend `sidebar.state` in that PR.

---

## Phase 4 — Workspace icon

**Deliverable:** when `workspace.metadata["icon"]` is set to a single emoji or glyph name, it renders as a leading element in the sidebar row title line.

### Render changes

Uses the `workspaceIcon: String?` precomputed parameter added in Phase 3 (same `Equatable` constraint applies — no direct `tab.metadata` reads in body).

Insert a new leading element in the title `HStack` (`Sources/ContentView.swift:10862`), between the unread-badge slot and the pin-icon slot:

```swift
if let icon = workspaceIcon {
    WorkspaceIconView(icon: icon, foreground: activePrimaryTextColor)
        .frame(width: 16, height: 16)
        .accessibilityLabel(
            String(localized: "sidebar.workspaceIcon.label",
                   defaultValue: "Workspace icon")
        )
}
```

`WorkspaceIconView` (new, small — ~50 lines, probably `Sources/WorkspaceIconView.swift`):
- If `icon` starts with `sf:` → treat rest as SF Symbol name, render via `Image(systemName:)` tinted with `foreground`.
- Else → render first grapheme cluster as `Text(...)` with `.font(.system(size: 13))`. (First grapheme cluster handles emoji-with-modifiers like skin-tone correctly; `String.prefix(1)` splits combined characters.)
- If the SF Symbol name is invalid, fall back to the text path on the original string.

Accessibility label uses `String(localized:)` per `CLAUDE.md` rules; `titlebar.*` catalog keys are the wrong namespace, use `sidebar.workspaceIcon.*`.

### Precedence with agent chip

Today `AgentChipBadge` (`ContentView.swift:10880`) sits in the title line. If both the agent chip and a user-set icon exist, render:
- User-set icon first (leading — it's the scan anchor).
- Agent chip after, if present.

Rationale: operator-authored identity outranks agent-inferred role for scannability.

### Phase 4 tests

Same test-seam discipline as Phase 3 — `WorkspaceIconView` is the testable surface (declare `internal`), not `TabItemView`.

- `tests_v2/test_workspace_icon_roundtrip.py` — set/get/clear via socket; reload via synthetic session snapshot fixture and assert persistence.
- `cmuxTests/WorkspaceIconViewTests.swift`:
  - `"🦊"` renders as `Text` with the emoji as its string content.
  - `"sf:star.fill"` renders as `Image(systemName: "star.fill")` (assert via `NSHostingView` image extraction or a view-model helper function the test can call directly).
  - Invalid SF Symbol name `"sf:nonexistent.symbol.xyzzy"` falls back to the text path.
  - Emoji-with-modifier (e.g., `"👍🏽"`) renders the full grapheme cluster, not just the base character.
- `cmuxTests/WorkspaceMetadataValidatorTests.swift` (shared with Phase 1):
  - 32-char cap for icon enforced (reject 33-char icon write).
  - Key grammar reject (e.g., `"my key"` with space → reject; `"my.key"` → accept).

---

## Phase 5 — Documentation and polish

- Add `workspace.metadata` canonical keys to whichever reference doc lists M-module canonical keys (check `docs/c11mux-module-2-*` or equivalent; if none exists, note that in the plan).
- Update the top-level c11 skill (`skills/cmux/SKILL.md`) with the new CLI commands.
- Add a short "workspace metadata" section to the c11 reference docs.

---

## Rollout order

Must land in order. Each phase is a separate PR.

1. **Phase 1** — persistence layer. Lands independently. No user-visible change. Safe to revert.
2. **Phase 3** — description render. Requires Phase 1. Visible user change, but opt-in (empty description = today's behavior).
3. **Phase 4** — icon render. Requires Phase 1. Visible user change, opt-in.
4. **Phase 5** — docs. Follows.

Phase 2 is a no-op unless the M7 agent does something unexpected with the helpers. Fold into Phase 3 if it remains trivial.

---

## Dependencies and coordination

- **M7 in-flight agent.** Do not block. This plan does not touch `Sources/SurfaceTitleBarView.swift` unless the M7 agent privatizes `sanitizeDescriptionMarkdown` or `titleBarMarkdownTheme`, in which case a one-line visibility change is needed. Coordinate by reading the M7 PR before starting Phase 3.
- **Session persistence schema.** Optional fields avoid a schema version bump. If someone else adds a required field to `SessionWorkspaceSnapshot` concurrently, rebase.
- **Gold-on-void sidebar styling PR.** Should land before Phase 3 so the description renders against the new color system. (This plan assumes it has landed.)

---

## Open questions

1. **Per-workspace markdown max length.** 2048 matches surface description. Workspaces are long-lived; is that still enough, or should it be 4096? Leaning 2048 (consistency > capacity).
2. **Emoji vs. SF Symbol vs. custom asset for icon.** This plan allows emoji + SF Symbol. Custom asset (shipped `.xcassets` image) is deferred — would require an allowlist and localization-neutrality check. Operator-uploaded bitmaps stay parked indefinitely.
3. **Link navigation.** Disabled in Phase 3 matching M7. If M7 later enables links (e.g., via embedded browser route), this plan should follow immediately. Same policy, one place.
4. **Markdown in the sidebar subtitle vs. operator-authored tags.** Alternative design: instead of a `description` key, expose a richer tag/status model (`workspace.metadata["status"] = "blocked"`, `["waiting_on"] = "@val"`). The markdown-description approach is more flexible but gives up the chance to drive semantic UI (filtered views, colored-by-status, etc.). Propose shipping markdown first; consider structured fields as an additive layer if recognition needs outgrow plain text.
5. **Does `workspace.get_metadata` expose agent-written metadata too?** Today workspaces carry agent-emitted `statusEntries`, `logEntries`, etc. — those aren't in the new `metadata` dict. Proposal: keep them separate. `metadata` is operator-authored; agent-emitted state keeps its current typed fields. Clean separation > one bag.

---

## Appendix — why this isn't a larger refactor

A tempting move: create a general `WorkspaceMetadataStore` class mirroring `SurfaceMetadataStore`, with full canonical/custom/source tracking, and use it everywhere. Rejected for v1: the session-snapshot path already handles durability, the scope here is two canonical keys plus a small custom-key escape hatch, and the per-source/per-agent tracking that `SurfaceMetadataStore` needs (panels are shared across agents; workspaces are one-per-operator) doesn't apply. If workspace metadata grows to require source attribution later, *then* extract the store.

Keep it small. Ship Phase 1 first. See if operators want more.

---

## Revision log

**2026-04-18 — revised after parallel Claude + Codex review.**

### Accepted and applied

| Finding | Reviewer | Fix |
|---------|----------|-----|
| TabItemView `Equatable` identity check would suppress `tab.metadata` reads in body → description never updates | Claude | Added `workspaceDescription` / `workspaceIcon` as precomputed `let` params, extended `==`, specified parent `ForEach` precomputation |
| `Workspace` is `@MainActor`; off-main direct write would violate threading model | Codex | Specified parse/validate off-main, marshal to main via `v2MainSync` for the mutation; called out the existing precedent (`workspace.rename` handler) |
| "Debounced save" was asserted without a real API reference | Both | Removed claim; use autosave timer + fingerprint-update path; flagged a new public `requestSessionAutosave` entry point as follow-up if needed |
| Autosave fingerprint dedupe would skip metadata-only edits up to 60s | Codex | Added explicit requirement to hash metadata into `sessionAutosaveFingerprint()` |
| `TabItemView` is `private`; NSHostingView tests can't mount it | Codex | Reworked tests to target the new `SidebarDescriptionView` / `WorkspaceIconView` components at `internal` visibility; `TabItemView` visibility unchanged |
| `sidebar.state` doesn't expose workspace `metadata` | Codex | Dropped the `sidebar.state` assertion path; tests read via `workspace.get_metadata` (which this PR adds) |
| "status entries persist across restart" — wrong | Codex | Corrected motivation; status and agent PIDs are intentionally ephemeral per `Workspace.swift:243-247` |
| CLI proposed nested-subcommand grammar; existing CLI is flat-verb | Codex | Switched to `set-workspace-metadata` / `get-workspace-metadata` / `clear-workspace-metadata` and flat aliases |
| Key grammar unspecified | Codex | Added `^[A-Za-z0-9_.\-]+$` key pattern and `maxCustomKeyLen = 64` |
| `.lineLimit(2)` may not clamp MarkdownUI with block elements | Codex | Specified hard `.frame(maxHeight: sidebarDescriptionMaxHeight ≈ 26pt)` as the real cap; `.lineLimit(2)` stays as a hint only |
| Localization missing for accessibility labels and CLI help | Claude | Explicit localization requirements added to Phase 4 icon view and Phase 1 CLI sections |
| `MetadataKey` / `WorkspaceMetadataKey` collision in future reader's head | Claude | Added docstring on `WorkspaceMetadataKey` noting workspace vs. surface scope |
| Line reference drift: `SidebarMetadataMarkdownBlocks` at :12180, not :12178 | Claude | Corrected |
| Line reference drift: `validateReservedKey` starts :147, description branch at :170-171 | Claude | Corrected to `:147-175` with explicit branch note |

### Rejected (with reasoning)

| Finding | Reviewer | Why |
|---------|----------|-----|
| Claude claim that `Workspace` is not `@MainActor` | Claude | Contradicted by Codex's verification at `Workspace.swift:4818`; `@MainActor` is correct, so the fix direction (marshal to main) is right but the stated rationale was inverted |

### New questions surfaced by review

- **Public `AppDelegate.requestSessionAutosave(reason:)` API.** Deferred to implementation time. If autosave latency for metadata writes is acceptable in practice, skip it. If not, the implementer is authorized to add it as a minimal scoped addition — not a broader autosave-API refactor.
- **Precedence of user-icon vs. agent-chip.** Plan says user-icon first (leading), agent-chip after. Confirm with the implementer via the row's existing layout review once the feature is wired end-to-end — may want to revisit after seeing both in the sidebar.

