# c11mux Modules 3 + 6 — Sidebar TUI Identity Chip & Markdown Surface Polish

Canonical specification for [Module 3](./c11mux-charter.md) (sidebar TUI identity chip) and [Module 6](./c11mux-charter.md) (markdown surface polish). These two small modules are specified together because each is narrow and their surfaces don't overlap with the other MVP modules. Both consume [Module 2's](./c11mux-module-2-metadata-spec.md) metadata primitives and reserved-key table.

Status: specification, not yet implemented. The chip and the new `--pane` flag are new; both depend on M2's `surface.set_metadata` / `surface.get_metadata` socket methods, which themselves are new primitives introduced by M2.

---

## Module 3 — Sidebar TUI identity chip

### Positioning

Each workspace row in the vertical tabs sidebar grows a small **agent chip** — icon plus short model label — that shows at a glance who is running in that workspace's focused surface. With ten workspaces stacked in the sidebar, the chip lets an operator distinguish Claude Opus from Codex from Kimi from OpenCode without reading the tab title.

### Terminology

The charter casually says "each pane's sidebar entry" — this is incorrect for the current cmux sidebar. One **sidebar row** corresponds to one **workspace** (`Sources/ContentView.swift:8167` iterates `tabManager.tabs`; `TabItemView` at `Sources/ContentView.swift:10559+` consumes a `Tab` where `Tab` is a workspace). A workspace can contain many panes, each with many surfaces. M3's chip therefore renders **one agent per workspace row**, sourced from the workspace's focused surface.

The term "chip" is used consistently below; "agent chip" is the same thing.

### Goals

- Surface the **`terminal_type`** and **`model`** canonical keys (owned by M2, seeded/declared by M1) as a compact icon+label rendered on every workspace row.
- Keep the chip cheap at typing latency — the body of `TabItemView` is in a measured hot path.
- Provide a non-visual read-back API so tests and consumers can assert chip state without pixel inspection.
- Stay deferentially narrow: M3 owns rendering and read-back, not the detection or the metadata transport.

### Non-goals

- **Per-surface sidebar rows.** Rebuilding the sidebar as a pane-or-surface hierarchy is a separate, larger effort and is named in Open Questions as parking-lot.
- **New canonical keys.** M3 consumes `terminal_type` and `model` as defined by M2; it does not introduce new keys.
- **Detection.** Process-tree heuristics and declaration commands belong to M1.
- **Title / description rendering.** Those are M7's (title bar) territory. The sidebar tab label (`tab.title`) is unchanged by M3.
- **Configuration of the chip.** No user-facing toggles in v1 beyond inheriting the existing `sidebarShowStatusPills` / "hide all details" settings (the chip sits above those and is not gated by them — see "Interaction with existing sidebar toggles").

### Chip anatomy and layout

**Placement.** The chip sits at the **leading edge of the title row**, immediately before `Text(tab.title)` in the existing HStack at `Sources/ContentView.swift:10854-10916`. It appears between the unread-badge/pin group and the title text. This is the same row that holds the tab title, unread badge, pin icon, and close/shortcut slot; no new row is introduced.

**Dimensions and font.**

| Element | Value |
|---------|-------|
| Icon size | 11pt, `.medium` weight for SF Symbols |
| Label font | `.system(size: 10, weight: .semibold, design: .rounded)` |
| Icon–label spacing | 3pt |
| Chip horizontal padding | 4pt leading, 6pt trailing |
| Chip height | 16pt (matches existing unread badge) |
| Chip background | Capsule, `Color.primary.opacity(0.08)` inactive / `Color.white.opacity(0.18)` active row |
| Chip foreground | `activePrimaryTextColor` when row is active, `.secondary` otherwise (matches existing sidebar palette helpers) |
| Max label length | 10 characters (truncate tail with ellipsis) |
| Collapse threshold | When the row width is below ~120pt, hide the label and show icon-only |

**Active vs inactive.** When the workspace row is selected (`isActive == true`), the chip inverts to match the existing selected-row foreground treatment via `sidebarSelectedWorkspaceForegroundNSColor(opacity:)`, consistent with status pills and the unread badge.

**When the chip is absent.** If `terminal_type` is absent or equals `"unknown"` **and** `model` is also absent, the chip does not render at all — the title row reverts to its pre-M3 layout. When only `model` is set (no `terminal_type`, or `terminal_type == "unknown"`), the chip renders with the `unknown`-family icon + model label (see icon table row for `unknown`). When `terminal_type == "shell"` and no `model` is set, the chip renders an icon-only dimmed shell glyph without a label.

### Icon set and model-label rules

#### Icon source

Each canonical `terminal_type` maps to **a bundled asset** in `Resources/Assets.xcassets/AgentIcons/<terminal-type>.imageset` (light + dark variants, rendered as template images). The asset path is the source of truth; SF Symbol fallbacks are used only until the M5 brand work provides the real glyphs.

| `terminal_type` | Asset name | SF Symbol fallback |
|-----------------|------------|--------------------|
| `claude-code`   | `AgentIcons/claude-code` | `sparkles` |
| `codex`         | `AgentIcons/codex`       | `chevron.left.forwardslash.chevron.right` |
| `kimi`          | `AgentIcons/kimi`        | `moon.stars` |
| `opencode`      | `AgentIcons/opencode`    | `curlybraces` |
| `shell`         | `AgentIcons/shell`       | `terminal.fill` |
| `unknown`       | `AgentIcons/unknown`     | `questionmark.square.dashed` — used when `model` is set but `terminal_type` is absent or equals `"unknown"`; chip is suppressed entirely when `model` is also absent (see "When the chip is absent" above) |
| Any future string | `AgentIcons/<string>` if present, else SF fallback `questionmark.square.dashed` | — |

Brand-aligned glyphs are owned by M5 (Stage 11 brand identity). M3 depends on M5 for the asset set but ships usable fallbacks in the interim — an agent can verify the chip renders without those assets being final.

#### Model label rule

The label is derived from the `model` canonical key via this deterministic shortening, applied in order and stopping at the first match:

1. **Registered alias.** A small built-in table maps known `model` strings to short labels. Initial entries (extendable without a spec amendment since this is display-only):
   - `claude-opus-4-7` → `Opus 4.7`
   - `claude-opus-4-6` → `Opus 4.6`
   - `claude-sonnet-4-6` → `Sonnet 4.6`
   - `claude-haiku-4-5` → `Haiku 4.5`
   - `gpt-5.4-pro` → `GPT-5.4 Pro`
   - `gpt-5.4` → `GPT-5.4`
   - `kimi-k2-0711` → `K2`
   - `opencode-qwen-3-coder` → `Qwen 3`
2. **Versioned family.** For `<family>-<variant>-<major>-<minor>`, output `<Variant> <major>.<minor>` (TitleCase the variant). Handles the long tail of Anthropic-style kebab-case models.
3. **Pass-through.** Any other `model` string renders as-is, truncated to the 10-character max with tail ellipsis.

**Explicit override.** A consumer that wants a specific label writes `model_label` into the metadata blob. When present, `model_label` replaces all of the above. `model_label` is **not** a canonical key — it is an opt-in non-canonical display hint that lives in the open-ended part of M2's metadata object. c11mux never writes it (no heuristic or OSC source emits it); it is consumer-written only, and is readable like any non-canonical key via `surface.get_metadata`. Rendering validation: treated as a string, trimmed, and truncated to 16 characters for display; non-string values are ignored and the shortening rules above run instead. Because it is non-canonical, M2's `reserved_key_invalid_type` error does not apply — a malformed value is silently dropped at render time, not rejected at write time.

### Source resolution — per workspace, per focused surface

The chip for workspace W reflects the metadata of W's **currently focused surface** (`Workspace.focusedPanelId` in `Sources/Workspace.swift:4862`). When focus moves between surfaces within the workspace, the chip updates to reflect the new focused surface.

Pseudocode for the resolver (runs off-main where possible; see "Implementation notes"):

```
let focusedSurfaceId = workspace.focusedPanelId
guard let focusedSurfaceId else { return nil }         // empty / transient
let meta = surface[focusedSurfaceId].metadata
let sources = surface[focusedSurfaceId].metadata_sources

let terminalType = meta["terminal_type"] as? String    // "claude-code" | "codex" | ...
let model = meta["model"] as? String
let modelLabel = meta["model_label"] as? String

if (terminalType == nil || terminalType == "unknown") && model == nil {
    return nil                                         // chip suppressed
}
return AgentChip(
    terminal_type: terminalType ?? "unknown",
    model: model,
    display_label: modelLabel ?? shorten(model),
    source_surface_id: focusedSurfaceId,
    source: sources["terminal_type"]?.source ?? sources["model"]?.source
)
```

If only `model` is set (no `terminal_type`), the chip renders the label with the `unknown`-family fallback icon.

### Update latency — push via existing Combine publishers

No polling. The chip subscribes to two SwiftUI-driven signals, both of which already propagate on main:

1. **Focus change** — `Tab` already exposes focused-pane state via `bonsplitController` changes that drive SwiftUI body re-evaluation in `TabItemView`. `focusedPanelId` becomes reactive for the chip via a new `@Published` property on `Workspace` (`focusedSurfaceMetadataChip: AgentChip?`) that is recomputed whenever `focusedPanelId` or the focused panel's `metadata` sidecar changes.
2. **Metadata change** — M2's `surface.set_metadata` writes mutate the focused surface's blob. `Workspace` installs a Combine observer on the focused panel's metadata publisher (re-subscribing on focus change) and republishes the chip.

Target latency: **sub-frame on focus change, ≤50 ms after a `surface.set_metadata` write** (covers the hop off-main → main → SwiftUI invalidation). This is the same class of latency as status-pill updates and does not warrant a different mechanism.

**No polling fallback is required.** If the Combine observer is not yet wired for some reason during development, the chip is simply stale until the next focus change — `sidebar_state` read-back still returns the live value because it queries synchronously on main.

### Interaction with existing sidebar toggles

- The chip is **not** gated by `sidebarShowStatusPills`, `sidebarHideAllDetails`, or any of the other workspace-detail toggles. It is a first-class identity marker, not metadata. Rationale: hiding the chip defeats its purpose (instant identity at a glance).
- The chip **is** hidden in the minimal workspace-presentation mode only if `WorkspacePresentationModeSettings.mode == .minimal` and `!isActive`. In minimal mode the inactive rows collapse aggressively; the chip follows that existing rule to avoid visual noise.
- Adding a future `sidebarShowAgentChip` toggle is deferred to Open Questions.

### Interaction with Module 2 — canonical keys read, not written

M3 is strictly a reader of M2's blob for `terminal_type`, `model`, and the ad-hoc `model_label`. It does not write to the blob. All writes originate from:

- **M1** (`heuristic` source for `terminal_type`; `declare` source via `cmux set-agent`).
- **User CLI** (`explicit` source via `cmux set-metadata --key model --value ...`).
- Any other consumer choosing to populate `model_label` directly.

Precedence is handled entirely by M2. M3 does not re-rank sources; it reads whatever is currently winning and displays the result.

### Interaction with Module 7 — title bar owns the "what", chip owns the "who"

| Surface | Renders |
|---------|---------|
| **M3 sidebar chip** | `terminal_type` (icon) + `model` (label) — **who is running** |
| **M7 title bar** | `title` (short) + `description` (long) — **what they're doing** |
| Sidebar `tab.title` (pre-existing) | Truncated projection of M7's `title`, as specified in M7 |

No key is rendered twice in the sidebar. If a consumer wants to communicate both "Claude Opus 4.7" and "Running migration", the chip covers the first and the title bar / tab title cover the second.

### Socket / CLI changes — `sidebar_state` extension

M3 adds one new per-workspace block to the existing `sidebar_state` command (backed by `sidebarState` in `Sources/TerminalController.swift:15040-15111`). No new socket method.

Rationale: `sidebar_state` is already the canonical workspace-level read-back for chips and pills; it already runs on main and assembles a line-oriented dump. Adding a top-level `agent_chip` block keeps discovery in one place for agents writing tests, matches the M2 "everything flows through existing primitives" posture, and costs no new method surface.

#### New lines in `cmux sidebar-state` output

Appended after the existing `status_count` / `meta_block_count` blocks, before `log_count`. When the chip is suppressed, only the `agent_chip=none` line is emitted.

```
agent_chip=present                                  # or "none"
  terminal_type=claude-code
  model=claude-opus-4-7
  model_label=Opus 4.7
  display_label=Opus 4.7                            # final resolved label (post-shortening)
  icon_asset=AgentIcons/claude-code                 # or sf:sparkles when fallback is used
  source_surface_id=<uuid>
  source_surface_ref=surface:12
  source=declare                                    # one of heuristic|osc|declare|explicit
  terminal_type_source=heuristic                    # per-key sidecar sources
  model_source=declare
```

#### JSON output

`cmux sidebar-state --json` already emits a structured object; M3 adds an `agent_chip` field:

```json
{
  "workspace_id": "<uuid>",
  "...": "...existing fields...",
  "agent_chip": {
    "present": true,
    "terminal_type": "claude-code",
    "model": "claude-opus-4-7",
    "model_label": "Opus 4.7",
    "display_label": "Opus 4.7",
    "icon_asset": "AgentIcons/claude-code",
    "source_surface_id": "<uuid>",
    "source_surface_ref": "surface:12",
    "source": "declare",
    "per_key_sources": { "terminal_type": "heuristic", "model": "declare" }
  }
}
```

When the chip is suppressed:

```json
{ "agent_chip": { "present": false } }
```

No new CLI command is introduced. Consumers that want "chip only" output pipe `cmux sidebar-state --json | jq .agent_chip`.

### Storage / persistence

No new storage. The chip is derived from:

- `Workspace.focusedPanelId` (already tracked, `Sources/Workspace.swift:4862`).
- The focused surface's M2 metadata blob (lives on the `MarkdownPanel`/`TerminalPanel`/`BrowserPanel` per M2's spec).

Both are in-memory and do not persist across app relaunch — matching M2's posture. On relaunch, the chip reappears as soon as M1's heuristic runs or an agent re-declares.

### Error codes

M3 introduces no new error codes. `sidebar_state` already returns `Tab not found` for unresolved workspace references; that carries over.

If an asset for a known `terminal_type` is missing at runtime, the SF Symbol fallback from the table above is used silently. A one-shot `#if DEBUG` `dlog("chip.missingAsset terminal_type=...")` is fired so builders notice during M5 asset integration.

### Implementation notes (non-normative)

- **Equatable footgun — decided: precomputed `let` parameter.** `TabItemView` in `Sources/ContentView.swift` uses `Equatable` conformance + `.equatable()` (lines `10553-10576` and `8209`) specifically to skip body re-evaluation on every parent publish — this path is measured as ~18% of main thread during typing. M3 adds a `let agentChip: AgentChip?` parameter on `TabItemView`, passed in by `VerticalTabsSidebar` where it composes the row (`Sources/ContentView.swift:8175-8208`). `AgentChip` conforms to `Equatable` on its scalar fields (`terminal_type`, `model`, `display_label`, `icon_asset`, `source`). The existing `==` on `TabItemView` gets one new line: `lhs.agentChip == rhs.agentChip`. This matches the existing pattern for `latestNotificationText` and `unreadCount`. **Do not** add a new `@ObservedObject` or `@EnvironmentObject` on `TabItemView` — that silently subscribes to every publish from that object and defeats the `.equatable()` skip.
- **Resolver location.** Add a computed `agentChip: AgentChip?` on `Workspace` that caches the current value and invalidates on focus/metadata change. `VerticalTabsSidebar` reads it synchronously when composing the `TabItemView` list — this runs on main and is only touched when the sidebar body re-evaluates (not on every typing event).
- **Metadata observer lifecycle.** When `focusedPanelId` changes, cancel the Combine subscription on the old panel's metadata publisher and subscribe to the new one. Guard against a focus-churn re-subscribe storm by coalescing via `.removeDuplicates().debounce(for: .milliseconds(16), scheduler: DispatchQueue.main)`.
- **Asset pipeline.** Add `Resources/Assets.xcassets/AgentIcons/` with one `.imageset` per canonical `terminal_type`. Template image rendering mode so the tint follows `activePrimaryTextColor`. M5 supplies the final art; M3 ships with placeholder SF Symbol fallbacks compiled in.
- **`sidebar_state` wiring.** In `Sources/TerminalController.swift:15048+`, after the existing status / meta-block emission, call a new helper `sidebarAgentChipLines(tab:)` that resolves the chip and appends the lines documented above. The JSON variant mirrors the same shape; if no JSON variant exists today for `sidebar_state`, this spec does not add one (the `--json` flag is already a CLI-global concern — follow existing conventions in `cmux sidebar-state`).
- **Threading.** Resolution is main-only because it touches SwiftUI-observable state (`focusedPanelId`, `@Published` metadata). Avoid any `DispatchQueue.main.sync` from the socket thread during chip resolution — `sidebar_state` already uses `DispatchQueue.main.sync` (line 15042); M3 piggybacks on that existing hop.
- **Minimal-mode visibility.** The workspace presentation mode check already lives in `VerticalTabsSidebar` (`Sources/ContentView.swift:8143-8145`). Propagate `isMinimalMode` into `TabItemView` as another precomputed `let` and suppress the chip for inactive rows when true.

### Open questions

- **Sidebar hierarchy rewrite.** A per-pane or per-surface sidebar row (showing every agent in every surface, not just the focused one) is explicitly deferred. If the demand surfaces, it is a sidebar-architecture rewrite, not an M3 extension. Name: "Per-surface sidebar hierarchy". Parking-lot owner: charter (should be added on the next charter pass).
- **User-facing toggle.** `sidebarShowAgentChip` AppStorage default `true`. Deferred until someone asks for it.
- **Model-label alias table growth.** Currently hard-coded in Swift; if the list grows, consider moving to a bundled JSON resource so tests and docs agree. Not needed for v1.
- **Chip interaction.** Click-to-focus-surface (jumps to `source_surface_id`) is tempting but out of scope; the workspace row is already click-to-focus-workspace, which is sufficient.
- **Remote-workspace cases.** When a workspace is in `.connecting` / `.error` state (existing remote-SSH support), suppress the chip? Or render a dimmed variant? Current spec: render the chip if metadata is present regardless of remote state. Revisit if it looks visually busy alongside `remoteWorkspaceSection` at `Sources/ContentView.swift:10766+`.

---

## Module 6 — Markdown surface polish

### Positioning

The markdown surface type (file-watched, Mermaid-rendering, read-only) is already merged on main (`Sources/Panels/MarkdownPanel.swift`, `Sources/Panels/MarkdownPanelView.swift`). M6 is the small last-mile polish: give `cmux markdown` a `--pane` flag so the viewer opens as a tab inside an existing pane instead of always splitting, plus a minimal content read-back so tests can assert rendered content without pixel inspection.

### Terminology

- **`cmux markdown [open] <path>`** — the public CLI. Socket method: `markdown.open` (`Sources/TerminalController.swift:7127+`).
- **Split placement** — current behavior, implemented by `Workspace.newMarkdownSplit` (`Sources/Workspace.swift:6872+`). Creates a new pane via `bonsplitController.splitPane`.
- **Tab-in-pane placement** — new with M6, but the underlying primitive already exists as `Workspace.newMarkdownSurface(inPane:)` (`Sources/Workspace.swift:6935+`). It is already reachable via `cmux new-surface --type markdown --pane <ref> --file <path>` (see `Sources/TerminalController.swift:4600-4607`). M6 plumbs the same primitive through the `markdown.open` entrypoint.

### Goals

- `cmux markdown --pane <pane-ref> <path>` opens the markdown viewer as a new tab in the named pane, not as a split.
- `cmux markdown <path>` (no `--pane`) preserves existing behavior (new horizontal split from the focused surface) for backward compat.
- Add a minimal socket read-back so agents can assert "surface S is a markdown surface rendering file F, content bytes match" without pixel diffs.
- Add `file_path` to `surface.list` and `cmux tree` output for markdown surfaces.

### Non-goals (parking lot, explicit)

All of these are named here so they are recoverable; none are accepted into v1.

- **`--stdin`** (charter parking-lot). Requires a new in-memory content source distinct from a file-backed panel. `MarkdownPanel` today is strictly file-backed (`Sources/Panels/MarkdownPanel.swift:71-85`) — adding stdin would mean either writing to a temp file (cheap, ugly) or introducing an in-memory variant of the panel (meaningful new code path). Not trivially free; defer.
- **`--url`**. Not in charter. Would need HTTP fetch + TLS + refresh semantics — clearly beyond last-mile polish.
- **Live-reload UX beyond the existing passive FS watcher.** `MarkdownPanel` already installs a `DispatchSourceFileSystemObject` watcher (`Sources/Panels/MarkdownPanel.swift:60-67`) and reloads on file change. Exposing live-reload as a CLI-visible feature (e.g., a status pill) is charter parking-lot; defer.
- **Copy-link-on-heading, scroll-position preservation, keyboard-driven heading jump.** Valuable polish items; should be picked up by the M6 implementer opportunistically if cheap, but not guaranteed. Any that are not landed remain in Open Questions.
- **Writable markdown surface.** `MarkdownPanel` is read-only by design (`Sources/Panels/MarkdownPanel.swift:89-95`). Out of scope.

### `markdown.open` — new `pane_id` param

Extend the existing socket method. No new method is introduced.

```json
{
  "id": "m1",
  "method": "markdown.open",
  "params": {
    "path": "/abs/path/to/file.md",
    "pane_id": "<pane-uuid>",
    "workspace_id": "<workspace-uuid>"
  }
}
```

**Params (additions to existing):**

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `pane_id` | no | string (uuid/ref) | When set, opens the markdown viewer as a new tab in this pane. Must resolve to a pane in the resolved workspace. |
| `path` | yes | string | Unchanged. Absolute; tilde-expanded server-side. |
| `workspace_id` / `window_id` / `surface_id` | no | string | Unchanged. `surface_id` continues to select the split origin when `pane_id` is not provided. |

**Semantics:**

- `pane_id` set and valid → dispatch `Workspace.newMarkdownSurface(inPane: paneId, filePath: filePath, focus: v2FocusAllowed())`. The result is a markdown panel added as a tab to that pane; no split is created.
- `pane_id` absent → preserve current behavior: call `Workspace.newMarkdownSplit(...)` from the focused (or `surface_id`-specified) source surface.
- `pane_id` present alongside `surface_id` → `pane_id` wins; `surface_id` is ignored. Precedence rationale: the operator explicitly asked for a pane; the split-origin semantic of `surface_id` is irrelevant.

**Result shape:** unchanged — returns `surface_id`, `pane_id`, `workspace_id`, `window_id`, `path`, and when applicable the `source_surface_id` (omitted for tab-in-pane placement since no split occurred).

### CLI — `cmux markdown --pane`

```
cmux markdown open <path> [--pane <id|ref|index>] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
cmux markdown <path>                                          # shorthand for 'open'
```

**New flag:**

| Flag | Arg | Notes |
|------|-----|-------|
| `--pane <ref>` | required value | Accepts uuid, `pane:<n>` ref, or positional index. When present, `cmux markdown` passes `pane_id` to the socket method and the viewer opens as a tab in that pane (not a split). |

Existing `--workspace`, `--surface`, `--window` flags retain their current semantics. `--surface` without `--pane` continues to control which surface the new split is created from.

**Workspace-relative behavior.** When `--pane` is provided and `--workspace` is omitted, `cmux markdown` reads `CMUX_WORKSPACE_ID` and resolves the pane reference against that workspace (matches existing convention at `CLI/cmux.swift:2417-2422`).

**JSON mode.** `--json` continues to emit the raw socket response. The response shape is described above.

**Examples:**

```bash
# Existing: open as a new horizontal split from focused surface
cmux markdown plan.md

# New: open as a new tab inside pane:2
cmux markdown plan.md --pane pane:2

# New: with explicit workspace routing
cmux markdown ./docs/design.md --workspace workspace:3 --pane pane:1
```

### Read-back — content assertion without pixel inspection

Markdown surfaces are visual by nature. To keep the testability principle honest, two read-back surfaces are added.

#### 1. `surface.list` / `cmux tree` — `file_path` on markdown surfaces

Extend the surface node emitted by `v2SurfaceList` (`Sources/TerminalController.swift:4379-4440`) and `v2TreeWorkspaceNode` (`Sources/TerminalController.swift:2814-2903`) so that markdown panels include a `file_path` field. Non-markdown surfaces omit the key (not `null` — absent, so shape stays tight).

```json
{
  "id": "<uuid>",
  "ref": "surface:12",
  "type": "markdown",
  "title": "plan.md",
  "file_path": "/abs/path/to/plan.md",
  "...": "..."
}
```

This is analogous to `url` on browser surfaces, which both methods already emit (`Sources/TerminalController.swift:2855-2859`, `4419-4421`).

#### 2. `markdown.get_content` — new socket method

Reads the current in-memory content of a markdown surface. Needed because:
- "Does my file render?" is assertable without this method (just read the file on disk). But:
- "Did the panel observe my file's latest write?" requires reading the panel's in-memory content after its FS watcher has fired. Without this, an agent test racing the watcher has no way to verify the panel refreshed.

```json
{
  "id": "g1",
  "method": "markdown.get_content",
  "params": { "surface_id": "<uuid-or-ref>" }
}
```

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `surface_id` | yes | string | Must resolve to a markdown panel. |

**Result:**

```json
{
  "ok": true,
  "result": {
    "surface_id": "<uuid>",
    "surface_ref": "surface:12",
    "type": "markdown",
    "file_path": "/abs/path/to/plan.md",
    "content": "# Hello\n\n```mermaid\ngraph TD; A-->B\n```\n",
    "content_length": 52,
    "content_sha256": "<hex>",
    "is_file_unavailable": false
  }
}
```

The `content` field is the raw text as read from disk by `MarkdownPanel` (exposed via its `@Published var content: String`, `Sources/Panels/MarkdownPanel.swift:32`). No rendering, no Mermaid expansion — the pre-render text is sufficient for assertion.

**Content size cap — soft result.** 256 KiB. Files larger than that return `ok: true` with the `content` field omitted and only `content_length` + `content_sha256` populated, plus `result.truncated: true` and `result.reason: "content_too_large"`. This mirrors M2's soft-result convention for `lower_precedence` (`ok: true` response with an explicit `reason:` string — see `docs/c11mux-module-2-metadata-spec.md` "Precedence"). The call is not an error; `content_too_large` is therefore not in the error-codes table below. Tests asserting large files compare against `content_sha256`.

```json
{
  "ok": true,
  "result": {
    "surface_id": "<uuid>",
    "surface_ref": "surface:12",
    "type": "markdown",
    "file_path": "/abs/path/to/big.md",
    "content_length": 524288,
    "content_sha256": "<hex>",
    "is_file_unavailable": false,
    "truncated": true,
    "reason": "content_too_large"
  }
}
```

**Threading.** Runs off-main for parse/validate; touches `MarkdownPanel.content` on main because it's `@MainActor`-bound.

### Error codes

| Code | When |
|------|------|
| `not_found` | `pane_id`, `surface_id`, or `workspace_id` does not resolve. |
| `invalid_params` | `path` missing / not absolute after expansion, `pane_id` malformed, `surface_id` for `markdown.get_content` points at a non-markdown surface. |
| `permission_denied` | File not readable at open time (`Sources/TerminalController.swift:7152-7153`). Unchanged. |
| `internal_error` | Panel construction failed (existing code path). Unchanged. |

Note: `content_too_large` is **not** an error code — see `markdown.get_content` "Content size cap — soft result" above. Oversized reads return `ok: true` with `result.truncated: true` and `result.reason: "content_too_large"`, following M2's `lower_precedence` soft-result convention.

### Storage / persistence

No new storage. The `MarkdownPanel` instance already lives in `Workspace.panels` and is cleaned up on close. Session persistence (`Sources/SessionPersistence.swift`) already rehydrates markdown panels with their file path; the `--pane` placement does not change what is persisted (the pane-parent relationship is already recorded via the bonsplit layout snapshot).

### Implementation notes (non-normative)

- **Entrypoint to patch.** `v2MarkdownOpen` in `Sources/TerminalController.swift:7127-7210`. Read `v2UUID(params, "pane_id")` alongside the existing `surface_id`. If non-nil and resolves to a pane in the resolved workspace, call `ws.newMarkdownSurface(inPane:filePath:focus:)` instead of `ws.newMarkdownSplit(...)`.
- **CLI patch.** `runMarkdownCommand` in `CLI/cmux.swift:2353-2439`. Add `--pane` to the routing-flag parse stack (mirror the existing `--workspace` / `--surface` / `--window` plumbing via `parseOption`). Normalize with an analogue to `normalizeSurfaceHandle` — `normalizePaneHandle` already exists for other commands and should be reused.
- **`file_path` on `surface.list` / `tree`.** One-line addition at the markdown branch of each surface-node builder:
  ```swift
  if let mdPanel = panel as? MarkdownPanel {
      item["file_path"] = mdPanel.filePath
  }
  ```
  Mirrors the existing `BrowserPanel` URL block.
- **`markdown.get_content`.** New case in the v2 dispatch switch (`Sources/TerminalController.swift:2345-2347` neighborhood) and a new private helper `v2MarkdownGetContent(params:)` that resolves the surface, type-checks it as `MarkdownPanel`, and returns the current `content`/`filePath`/`isFileUnavailable`/SHA-256. Compute the SHA-256 off-main before dispatching to main for the `@Published` read.
- **CLI surface for `markdown.get_content`.** Add `cmux markdown-content --surface <ref>` as thin sugar. Emits either human-readable header lines plus the content body, or the raw JSON response under `--json`.
- **Session restore.** `Workspace.newMarkdownSurface(inPane:)` already integrates with the existing surface-id mapping (`surfaceIdToPanelId`) and `installMarkdownPanelSubscription` (`Sources/Workspace.swift:6962-6975`). No extra wiring.
- **Focus policy.** `markdown.open` passes `focus: v2FocusAllowed()` for both the split and tab-in-pane paths, preserving the socket focus policy (`CLAUDE.md` — "Socket focus policy").

### Open questions

- **Scroll-position preservation across reload.** The existing panel reloads content on FS change. Whether the rendered view restores scroll position is view-layer behavior in `MarkdownPanelView`; verify during implementation, file a follow-up if not.
- **Copy-link-on-heading.** Surface-level gesture; nice to have. Not a v1 blocker.
- **Keyboard shortcuts for heading navigation.** Same — not v1.
- **Reuse-existing-markdown-tab-for-same-path.** When `cmux markdown --pane P file.md` is called and `P` already has a tab for `file.md`, should we refocus the existing tab instead of creating a duplicate? Current spec: always create new. Consider a `--reuse` flag in a follow-up if the behavior is requested.
- **`--stdin` / `--url`** (charter parking-lot) — defer until an agent genuinely needs them.
- **`markdown.reload`** — explicit reload socket method (useful for tests that want to assert panel observed an atomic-rename rewrite). Deferred; `markdown.get_content` plus a small sleep is sufficient for v1 tests.

---

## Test surface (mandatory)

All tests live in `tests_v2/` following existing conventions (`tests_v2/test_cli_sidebar_metadata_commands.py` is the reference for CLI-driven socket tests). Every assertion below is exercisable headless, with no screen scraping or pixel inspection.

### Module 3 — chip tests

**Test 1 — declaration drives chip (`tests_v2/test_sidebar_agent_chip_declaration.py`).**

1. Create a workspace; focus its initial terminal surface.
2. Call M1 sugar `cmux set-agent --type codex --model gpt-5.4-pro` (this is the M1 CLI; if not yet implemented, fall back to the raw `surface.set_metadata` call with `source: declare`).
3. `cmux sidebar-state --json` on that workspace.
4. Assert: `agent_chip.present == true`; `terminal_type == "codex"`; `model == "gpt-5.4-pro"`; `display_label == "GPT-5.4 Pro"`; `source == "declare"`; `source_surface_id` equals the initial surface's UUID.

**Test 2 — `model` change updates chip (`tests_v2/test_sidebar_agent_chip_model_change.py`).**

1. Create a workspace; set `terminal_type=claude-code` + `model=claude-opus-4-7` via `cmux set-metadata --key model --value claude-opus-4-7 --key terminal_type --value claude-code` (source `explicit`).
2. Assert `sidebar-state --json` shows `display_label == "Opus 4.7"`, `source == "explicit"`.
3. Overwrite `model` with `claude-sonnet-4-6` via the same command.
4. Assert `display_label` now reads `Sonnet 4.6` and the `model_source` field is `explicit`.

**Test 3 — `model_label` override (`tests_v2/test_sidebar_agent_chip_model_label_override.py`).**

1. Set `model=claude-opus-4-7` and `model_label=Opus`.
2. Assert `display_label == "Opus"` (pass-through, not shortened).

**Test 4 — unknown state suppression (`tests_v2/test_sidebar_agent_chip_unknown.py`).**

1. Create a workspace, write nothing.
2. Assert `agent_chip.present == false`.
3. Set `terminal_type=unknown` explicitly.
4. Assert `agent_chip.present == false` still holds.

**Test 5 — focus change updates chip (`tests_v2/test_sidebar_agent_chip_focus_change.py`).**

1. Create a workspace with two terminal surfaces A and B (split right).
2. Declare `terminal_type=codex` on A, `terminal_type=kimi` on B.
3. Focus A; assert `agent_chip.terminal_type == "codex"` and `source_surface_id == A`.
4. Focus B; assert chip flips to `kimi` with `source_surface_id == B`.

**Test 6 — precedence: heuristic does not overwrite declare.**

This is strictly a M2 test, already covered by M2's test surface. M3 does not re-test precedence; it only asserts "whichever source wins per M2, the chip reflects that source in the `source` field". Verified implicitly by Test 1 (`source == declare`) and Test 2 (`source == explicit`).

### Module 6 — markdown placement and content tests

**Test 7 — `--pane` creates a tab, not a split (`tests_v2/test_markdown_open_pane_flag.py`).**

1. Create a workspace with one pane. Call `cmux tree --json`; note the initial pane UUID `P` and surface count.
2. Write a temp markdown file `/tmp/m6-test.md` with known content.
3. Call `cmux markdown /tmp/m6-test.md --pane <P>`.
4. Call `cmux tree --json`. Assert:
   - The workspace still has exactly one pane (no split was created).
   - That pane's `surface_count` incremented by 1.
   - The newly added surface has `type == "markdown"` and `file_path == "/tmp/m6-test.md"`.

**Test 8 — default `cmux markdown` still splits (`tests_v2/test_markdown_open_default_split.py`).**

1. Same setup as Test 7.
2. Call `cmux markdown /tmp/m6-test.md` (no `--pane`).
3. Assert `cmux tree --json` now reports two panes (a split was created).

**Test 9 — `markdown.get_content` round-trip (`tests_v2/test_markdown_get_content.py`).**

1. Write `/tmp/m6-content.md` with `# Hello\n\nworld\n`.
2. `cmux markdown /tmp/m6-content.md --pane <P>`; capture the returned `surface_id`.
3. Call `markdown.get_content` on that surface (via the raw socket).
4. Assert `result.file_path == "/tmp/m6-content.md"`, `result.content == "# Hello\n\nworld\n"`, `result.content_length == 17`, `result.is_file_unavailable == false`.
5. Overwrite the file. Poll `markdown.get_content` for up to 1 second; assert the new content surfaces (watcher fired).
6. `rm /tmp/m6-content.md`; poll; assert `is_file_unavailable == true`.

**Test 10 — error paths (`tests_v2/test_markdown_open_errors.py`).**

1. `cmux markdown --pane pane:99999 /tmp/m6-test.md` → assert `not_found` error.
2. `markdown.get_content` on a terminal surface → assert `invalid_params` error.
3. `cmux markdown /nonexistent.md` → assert `not_found` error (existing behavior; regression coverage).

**Test 11 — content size cap (`tests_v2/test_markdown_get_content_size_cap.py`).**

1. Write a 300 KiB markdown file.
2. Open it, then `markdown.get_content` on that surface.
3. Assert `ok == true`, `result.truncated == true`, `result.reason == "content_too_large"`, `result.content` is omitted, `result.content_length == <actual>`, `result.content_sha256` matches the file's SHA-256.

---

## Non-goals (cross-module, recap)

- No push/subscribe for chip or content — pull-on-demand is sufficient; matches M2's delivery model.
- No persistence of chip state or markdown content across app relaunch — reloaded from the live focused surface / the file on disk.
- No user-facing configuration beyond the existing sidebar-detail toggles.
- No new surface types; no writable markdown; no HTTP-fetched markdown.
