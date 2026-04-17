# c11mux Module 8 — `cmux tree` Overhaul for Agent Ergonomics

Canonical specification for Module 8 of the [c11mux charter](./c11mux-charter.md). Implements the charter's Module 8: narrow the default scope, attach spatial coordinates to every pane, expose workspace dimensions, and render an ASCII floor plan so agents *see* the room before they act.

Status: specification, not yet implemented. The `system.tree` socket method exists today (`Sources/TerminalController.swift:2708-2794`) and the `cmux tree` CLI ships (`CLI/cmux.swift:6252-6277`, `7915-7972`). This spec **extends** both — new JSON fields, new text output, one sanctioned default-scope break — without adding a new socket primitive.

---

## Goals

1. **Narrow the default scope** from current-window to current-workspace. A typical agent reads its own workspace, not every workspace on the machine.
2. **Attach spatial coordinates to every pane** in a unified, machine-readable shape: pixels + percent, both on `H` and `V` axes, plus the split path that produced the pane.
3. **Expose workspace-level dimensions** so agents can reason about whether a new split will fit before asking for one.
4. **Render an ASCII floor plan** in text output, proportional to the workspace's actual aspect ratio, so an agent reading `cmux tree` sees the spatial gestalt at a glance.

## Non-goals (v1)

- **Layout intelligence.** Best-guess pane placement, auto-rebalancing, and intent-level layout APIs (`--intent parallel-agents --count 10`) are parking-lot items in the charter; M8 does not ship any of them.
- **Layout write surface.** M8 is read-only. No `cmux set-divider`, no `cmux reshape`. Writers remain out of scope.
- **Persistent layout caching.** No new cache layer. Per the charter: "percentages are derived synchronously on main … no new cache layer."
- **Per-tab spatial info.** Surfaces (tabs) inside a pane share the pane's rect. No per-tab coordinates.
- **GUI-layer rendering changes.** The in-app split view is unaffected; this spec touches only the tree readout.
- **New subscription/push events.** `cmux tree` remains a pull-on-demand query.

---

## Terminology

- **Workspace content area.** The pixel rect managed by bonsplit inside one workspace — everything the agent's splits can occupy. Excludes the Stage 11 sidebar, the window title bar, and the per-surface tab bar. Corresponds to `BonsplitController.layoutSnapshot().containerFrame` (`vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift:655-681`).
- **H-split / horizontal split.** Panes arranged **left / right** (the divider is vertical; content is split along the horizontal axis). Equivalent to bonsplit's `SplitOrientation.horizontal`.
- **V-split / vertical split.** Panes arranged **top / bottom** (divider horizontal). Equivalent to bonsplit's `SplitOrientation.vertical`.
- **Split path.** Ordered chain of `H:left | H:right | V:top | V:bottom` entries describing the route from the workspace root to a pane in the **current** layout. Root-level pane with no splits = `[]`. `split_path` is **not a persistent identifier** — it describes where the pane sits right now. It is recomputed on every `cmux tree` call from `treeSnapshot()`, and a given pane's path will change whenever the enclosing splits change (new sibling split, divider reposition that reshapes ancestry, pane moved via drag, etc.). Agents that need a stable reference to a pane across layout mutations must use `pane:<n>` / pane UUID, not `split_path`.
- **Caller.** The surface that invoked `cmux tree` (identified from `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID`; marked `◀ here` in text output). Already computed by `treeCallerContextFromEnvironment()` in `CLI/cmux.swift` and `v2Identify` in the controller.
- **Floor plan.** The ASCII rendering of the workspace content area with per-pane boxes, proportional to the real pixel rects.
- **CLI split vocabulary** (`new-split left|right|up|down`) is preserved for writes; tree **reads** use `H`/`V` exclusively. The bridge: `left`/`right` ⇒ new H-split; `up`/`down` ⇒ new V-split.

---

## CLI surface

`cmux tree` gains three new flags and one renamed behavior. All other flags and positional arguments keep their current meaning.

```
Usage: cmux tree [flags]

Print the hierarchy of windows, workspaces, panes, and surfaces.

Flags:
  --all                         Include all windows and all workspaces
  --window                      Include all workspaces in the current window (NEW)
  --workspace <id|ref|index>    Show only one workspace
  --layout                      Render the ASCII floor plan even when scope > 1 workspace (NEW)
  --no-layout                   Suppress the ASCII floor plan unconditionally (NEW)
  --canvas-cols <N>             Override the floor-plan canvas width (default: auto, min 40) (NEW)
  --json                        Structured JSON output (layout in `layout` and `content_area` keys)

Default scope: current workspace. Use --window for the pre-M8 behavior (current window, all
workspaces); --all for every window.
```

### Scope resolution

1. `--workspace X` always wins; a single workspace is returned.
2. `--all` returns every workspace in every window.
3. `--window` returns every workspace in the current window (the pre-M8 default).
4. Otherwise (M8 default) the response contains **only the caller's current workspace**, resolved in priority order: (a) `CMUX_WORKSPACE_ID` env var, (b) the focused workspace from `system.identify`, (c) the selected workspace of the current window.

Flag conflicts (`--all --window`, `--all --workspace`, `--window --workspace`) return error `conflicting_flags` with the offending pair named in `data.flags`.

### Floor plan rendering rules (text mode)

| Scope | Default | Override |
|-------|---------|----------|
| single workspace (default, or `--workspace`) | plan **on** | `--no-layout` to suppress |
| `--window` | plan **off** | `--layout` renders one plan per workspace |
| `--all` | plan **off** | `--layout` renders one plan per workspace |
| `--json` (any scope) | plan **never rendered** | plan is presentation-layer; `--layout` is ignored with JSON |

Canvas width: default `auto` — use `min(80, terminal_cols, 160)` when stdout is a TTY, else 80. `--canvas-cols N` pins the width (clamped to `[40, 200]`). At canvas widths below 40 cols, the floor plan is suppressed with a single-line notice (`[layout suppressed: canvas <40 cols]`) — the hierarchical tree still renders.

### JSON-mode behavior

- Every pane node gains a `layout` sub-object (schema below).
- Every workspace node gains a `content_area` sub-object (schema below).
- No floor-plan text appears in JSON output.
- All **existing fields remain byte-identical** — no renames, no removals. New fields are strictly additive under the two named keys.

### Workspace-relative behavior

`cmux tree` honors the same env-vars every other v2 CLI does (`CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`). No changes beyond the default-scope shift.

---

## Socket response shape (extends `system.tree`)

### Workspace node (new field)

```json
{
  "id": "<uuid>",
  "ref": "workspace:11",
  "index": 1,
  "title": "⠐ Find and work on CMUX fork",
  "selected": true,
  "pinned": false,
  "content_area": {
    "pixels": { "width": 1920, "height": 1080 }
  },
  "panes": [ ... ]
}
```

`content_area.pixels.{width,height}` are integers (rounded from the native `Double` in `PixelRect`). They equal `containerFrame.size` from the workspace's `BonsplitController.layoutSnapshot()`. This is the denominator for every `percent` value in the pane nodes beneath this workspace.

When the workspace has never been laid out (e.g., never visible since app launch), `content_area` is `null` and every pane's `layout.pixels` / `layout.percent` in that workspace is also `null` (not absent). `split_path` is always present.

### Pane node (new field)

```json
{
  "id": "<uuid>",
  "ref": "pane:25",
  "index": 0,
  "focused": true,
  "surface_count": 4,
  "surface_refs": ["surface:45", "surface:51", "surface:54", "surface:55"],
  "selected_surface_ref": "surface:55",
  "surfaces": [ ... ],
  "layout": {
    "percent": { "H": [0.0, 0.4],  "V": [0.0, 1.0] },
    "pixels":  { "H": [0, 768],    "V": [0, 1080] },
    "split_path": ["H:left"]
  }
}
```

**`layout.percent`** — normalized to the **workspace content area**, regardless of nesting depth. `[start, end]` with `0.0 <= start < end <= 1.0`. Never relative to a parent split.

**`layout.pixels`** — integer `[start_px, end_px]` on each axis in the workspace content-area frame (origin at the content area's top-left, **not** the window's top-left — subtract `containerFrame.origin` from bonsplit's raw frame). `end_px - start_px` is the pane's width/height in that axis.

**`layout.split_path`** — ordered list of step tokens, root-to-leaf, for the **current** layout:
- `H:left` = took the first child of a horizontal split.
- `H:right` = took the second child of a horizontal split.
- `V:top` = took the first child of a vertical split.
- `V:bottom` = took the second child of a vertical split.

A single-pane workspace has `split_path = []`. Three panes produced by "left half, right half V-split into top+bottom" have paths `["H:left"]`, `["H:right","V:top"]`, `["H:right","V:bottom"]`.

`split_path` is recomputed from `treeSnapshot()` on every `cmux tree` / `system.tree` call. It is **not a persistent identifier** — it changes whenever the enclosing splits change. Do not use it as a key for tracking a pane across layout mutations; use the pane's `ref`/UUID.

### Side-by-side example (non-trivial layout)

Layout: a workspace whose left half is one pane, and whose right half is V-split into a top pane and a bottom pane. Content area 1920×1080.

**Current (pre-M8) JSON — pane fragment:**

```json
{
  "ref": "pane:25",
  "index": 0,
  "focused": true,
  "surface_count": 4,
  "surface_refs": ["surface:45","surface:51","surface:54","surface:55"],
  "selected_surface_ref": "surface:55",
  "surfaces": [ /* … */ ]
}
```

**Proposed (post-M8) JSON — same pane:**

```json
{
  "ref": "pane:25",
  "index": 0,
  "focused": true,
  "surface_count": 4,
  "surface_refs": ["surface:45","surface:51","surface:54","surface:55"],
  "selected_surface_ref": "surface:55",
  "surfaces": [ /* … */ ],
  "layout": {
    "percent": { "H": [0.0, 0.4], "V": [0.0, 1.0] },
    "pixels":  { "H": [0, 768],   "V": [0, 1080] },
    "split_path": ["H:left"]
  }
}
```

**All three panes' `layout` in the same workspace:**

```json
// pane:25 — left half, full height
{"percent":{"H":[0.0,0.4], "V":[0.0,1.0]},
 "pixels":{"H":[0,768],    "V":[0,1080]},
 "split_path":["H:left"]}

// pane:27 — right half, top half
{"percent":{"H":[0.4,1.0], "V":[0.0,0.5]},
 "pixels":{"H":[768,1920], "V":[0,540]},
 "split_path":["H:right","V:top"]}

// pane:28 — right half, bottom half
{"percent":{"H":[0.4,1.0], "V":[0.5,1.0]},
 "pixels":{"H":[768,1920], "V":[540,1080]},
 "split_path":["H:right","V:bottom"]}
```

Workspace node carries `"content_area": {"pixels": {"width": 1920, "height": 1080}}`.

The existing `panes[*].surfaces[*]` list, `selected_surface_ref`, `focused`, `active` markers, and every other pre-M8 field are returned unchanged.

---

## ASCII floor plan — specification

### Canvas math

- **Canvas width** (cols): resolved per the CLI table above. Default `auto` = `clamp(terminal_cols, 40, 160)` or 80 when stdout is not a TTY.
- **Canvas height** (rows): `round(canvas_width * (content_area.height / content_area.width) * 0.5)`. The `0.5` is the char-cell aspect correction (character cells are roughly twice as tall as they are wide). Floor at 6 rows; ceiling at 60 rows.
- **Per-pane box extent**: `box_cols = round(canvas_width * (pane.pixels.H.width / content.width))`, `box_rows = round(canvas_height * (pane.pixels.V.height / content.height))`. Adjust the rightmost/bottommost box by ±1 when rounding leaves a gap so the outer border closes cleanly.

### Per-pane box content (fixed 5-line body)

```
┌─────────────────┐
│ pane:25         │   line 1: pane ref
│ 40%W × 100%H    │   line 2: size as percent of workspace
│ 768×1080 px     │   line 3: size in pixels
│ 4 tabs          │   line 4: tab count (pluralize "1 tab" / "N tabs")
│ * selected-tab  │   line 5: `* <selected-tab-title>` (M7 title), truncated with `…`
└─────────────────┘
```

- Singular form: `1 tab`; plural: `N tabs`.
- Line 5 uses the selected tab's `title`, resolved by Module 7's precedence (`explicit > declare > osc > heuristic`). When no M7 title is set on the selected surface — i.e., before M7 lands, or when the agent has not declared one — the plan falls back to the panel's `displayTitle`, mirroring `v2TreeWorkspaceNode`'s existing title resolution at `Sources/TerminalController.swift:2846` (`workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle`). This ensures the floor plan renders the same title string the hierarchical tree does below it, with or without M7 in play.
- No tab-bullet decorations (`[●○○]` etc.). The tab count on line 4 carries that information and degrades cleanly; full tab titles live in the hierarchical tree section.

### Truncation + degradation

| Condition | Behavior |
|-----------|----------|
| Line 5 title wider than `box_cols - 4` | Truncate with `…` (e.g., `* long-title-goes…`) |
| `box_cols - 4 < 2` (can't even fit `*…`) | Drop line 5; keep lines 1–4 |
| `box_rows < 5` but `>= 2` | Drop lines from the bottom: line 5 first, then 4, then 3. Never drop the pane ref. |
| `box_cols < 15` | Collapse the pane to a **single-line summary**: `pane:N 8%W×20%H 154×216px 5 tabs` (see tight-layout example below). The pane box still borders; only its body collapses. |
| `canvas_width < 40` | Suppress the entire floor plan (see CLI rules). |

### Example render — three panes, 80-col canvas

Workspace 1920×1080, panes as in the JSON example above. At 80-col canvas, canvas_height ≈ 23 rows.

```
workspace:11 "⠐ Find and work on CMUX fork"  content: 1920×1080 px
┌───────────────────────────────┬──────────────────────────────────────────────┐
│ pane:25                       │ pane:27                                      │
│ 40%W × 100%H                  │ 60%W × 50%H                                  │
│ 768×1080 px                   │ 1152×540 px                                  │
│ 4 tabs                        │ 1 tab                                        │
│ * Review and execute spawn.…  │ * orchestrator                               │
│                               │                                              │
│                               ├──────────────────────────────────────────────┤
│                               │ pane:28                                      │
│                               │ 60%W × 50%H                                  │
│                               │ 1152×540 px                                  │
│                               │ 1 tab                                        │
│                               │ * preview                                    │
└───────────────────────────────┴──────────────────────────────────────────────┘
```

### Tight-layout example — five narrow panes, 80-col canvas

Workspace 1920×1080, five equal left-to-right H-split panes (each ≈ 16 cols). Each falls under the 15-col minimum, so each pane collapses to a single-line summary:

```
workspace:11 "five shards"  content: 1920×1080 px
┌──────────────┬──────────────┬──────────────┬──────────────┬──────────────┐
│ p:40 20%W×1… │ p:41 20%W×1… │ p:42 20%W×1… │ p:43 20%W×1… │ p:44 20%W×1… │
└──────────────┴──────────────┴──────────────┴──────────────┴──────────────┘
```

In collapsed form the line reads `p:N <W>%W×<H>%H <px>×<px>px <N> tabs`, truncated with `…`. The pane ref is always first and never dropped.

### Output ordering in text mode

1. Floor plan (when enabled) — **above** the hierarchical tree. Spatial first, detail second. An agent scanning for "which pane is my target" sees the map before the legend.
2. Hierarchical tree — unchanged except that each pane line now includes its `size=<W>%×<H>%` and `px=<W>×<H>` badges after the pane ref. Existing markers (`◀ active`, `◀ here`, `[focused]`, `[selected]`) are preserved in the same positions.

### Hierarchical tree — augmented pane line

```
├── pane pane:25 size=40%×100% px=768×1080 split=H:left [focused] ◀ active
```

The `size=`, `px=`, and `split=` badges are appended after the pane ref and before the existing bracketed markers. Missing values (pre-layout workspace) render as `size=? px=? split=?`. The surface/tab lines below the pane are **unchanged** — tab titles, `[selected]`, `[terminal|browser|markdown]`, URL for browsers all stay as they are today (`CLI/cmux.swift` tree renderer).

Module 1's `terminal_type` chip and Module 2's `model` (when they graduate) render on the **surface** lines, not on the pane line. This spec does not add them — it just reserves the right-hand column of the surface line for a future M1/M3 pass (noted in Open Questions).

---

## Storage / persistence

M8 adds **no persistent state**. Every value in the response is derived live from the workspace's `BonsplitController.layoutSnapshot()` at the moment of the call. `content_area` and each pane's `layout.pixels` are read from `containerFrame` and pane frames; `layout.percent` and `layout.split_path` are computed by tree-walking `treeSnapshot()` (`vendor/bonsplit/.../BonsplitController.swift:684-734`).

No caching. If bonsplit's snapshot is `<1ms` today (plain struct copy of already-computed frames), it stays `<1ms`. An agent calling `cmux tree` ten times per second is the expected regime.

---

## Interaction with other modules

| Module | Interaction |
|--------|------------|
| **M2** (metadata) | `layout` and `content_area` are top-level response fields — they are **not** per-surface metadata. They do not appear in `surface.get_metadata` output and do not count against the 64 KiB per-surface metadata cap. Agents that want metadata call `surface.get_metadata`; agents that want geometry call `system.tree`. Clean boundary. |
| **M1** (TUI detection) | The hierarchical tree's surface lines may show `terminal_type` when M1 ships; floor-plan line 5 does not. The pane-level floor-plan box never shows multi-tab roll-ups. |
| **M3** (sidebar chip) | No interaction. M3 is GUI. |
| **M7** (title bar) | Floor-plan line 5 renders the selected tab's `title` resolved per M7's precedence. If `title` is unset, fall through to the panel's `displayTitle` (matches today's tree renderer). `description` is never shown in the floor plan (too long). |
| **Charter parking-lot items** (layout intelligence, auto-placement) | M8 is the read half of their eventual read/write pair. M8's `layout.percent` + `content_area.pixels` is the schema a future `cmux new-pane --intent …` will consume. This spec does not encode that API — just confirms the shape is future-compatible. |

---

## Error codes

Inherits all errors from `system.tree` today. New additions:

| Code | When | Data |
|------|------|------|
| `conflicting_flags` | Two or more of `--all`, `--window`, `--workspace` supplied together. | `data.flags: ["--all","--window"]` |
| `invalid_canvas_cols` | `--canvas-cols` present but not an integer, or outside `[40, 200]`. | `data.value: <raw>` |
| `workspace_not_laid_out` | Soft status, not a hard error. Never returned as `ok:false`. When a workspace has no layout yet, `content_area` is `null` in the JSON response and every pane's `layout.pixels`/`layout.percent` is `null`; `layout.split_path` is still populated. | — |

Existing `invalid_params` / `not_found` remain as defined by `v2SystemTree`.

---

## Test surface (mandatory)

All tests live in `tests_v2/` following the existing socket-client pattern (`tests_v2/cmux.py`). Per project test policy, no local `open DEV.app`; tests connect via `CMUX_SOCKET` to a tagged debug socket or run under CI.

### Scope / flag handling

- **`test_tree_default_scope_workspace.py`** — Create two workspaces in the current window. From surface in workspace A, invoke `cmux --json tree`. Assert `result.windows[0].workspaces` has exactly **one** entry (workspace A). Assert the other workspace is absent.
- **`test_tree_window_flag.py`** — Same setup. Invoke `cmux --json tree --window`. Assert both workspaces in the current window appear; other windows do not.
- **`test_tree_all_flag.py`** — `cmux --json tree --all`. Assert every workspace across all windows appears.
- **`test_tree_workspace_flag.py`** — `cmux --json tree --workspace <ref>`. Assert exactly that workspace is returned.
- **`test_tree_conflicting_flags.py`** — Invoke with `--all --window`. Assert `ok: false`, `error.code == "conflicting_flags"`, `data.flags` lists both.

### Coordinate correctness

- **`test_tree_layout_horizontal_split.py`** — Create a workspace, H-split 50/50 (`cmux new-split right`). In `cmux --json tree`:
  - Assert pane A `layout.percent.H == [0.0, 0.5]`, `V == [0.0, 1.0]`.
  - Assert pane B `percent.H == [0.5, 1.0]`, `V == [0.0, 1.0]`.
  - Assert `A.pixels.H[1] == B.pixels.H[0]` (touching edge).
  - Assert `A.pixels.H[0] == 0` and `B.pixels.H[1] == workspace.content_area.pixels.width`.
  - Assert `A.split_path == ["H:left"]`, `B.split_path == ["H:right"]`.

- **`test_tree_layout_vertical_split.py`** — Mirror of above, `cmux new-split down`. Assert `percent.V` splits, `split_path` uses `V:top`/`V:bottom`.

- **`test_tree_layout_nested_split.py`** — Build the three-pane layout ("left pane + right V-split"). Assert:
  - `left.split_path == ["H:left"]`.
  - `top_right.split_path == ["H:right", "V:top"]`.
  - `bottom_right.split_path == ["H:right", "V:bottom"]`.
  - `top_right.pixels.H[0] == bottom_right.pixels.H[0] == left.pixels.H[1]` (aligned inner edge).
  - `top_right.pixels.V[1] == bottom_right.pixels.V[0]` (aligned horizontal divider).
  - `top_right.pixels.V[0] == 0` and `bottom_right.pixels.V[1] == content_area.pixels.height` (inner coords relative to workspace, not to the right-half parent).
  - `top_right.percent.H[0] != 0.0` (proves percent is workspace-relative, not parent-relative).

- **`test_tree_content_area_sum.py`** — For any multi-pane workspace, assert the outermost panes' pixel ranges sum to exactly `content_area.pixels.width` (on H axis) and `height` (on V axis).

### Floor-plan rendering

- **`test_tree_floor_plan_default_on.py`** — Single-workspace scope (default). Assert stdout from `cmux tree` (no `--json`) starts with the workspace header line followed by a box-drawing plan (regex match on `┌` within first 3 lines).
- **`test_tree_floor_plan_off_with_window_flag.py`** — `cmux tree --window`. Assert no `┌` box-drawing chars appear in output (plan suppressed by default under `--window`).
- **`test_tree_floor_plan_opt_in_with_layout.py`** — `cmux tree --window --layout`. Assert one plan per workspace renders.
- **`test_tree_floor_plan_never_in_json.py`** — `cmux --json tree --layout`. Assert `--layout` is ignored; output is valid JSON with no box-drawing chars.

### Box content and truncation

- **`test_tree_floor_plan_box_content.py`** — Known 2-pane H-split layout. Parse floor-plan text. For each pane box, assert the 5 mandatory lines appear in order: pane ref line, `NN%W × NN%H`, `NNN×NNN px`, `N tab[s]`, `* <title>`.
- **`test_tree_floor_plan_title_truncation.py`** — Rename the selected surface to a 200-char title (`cmux set-title` per M7). Render the plan. Assert line 5 ends with `…` and that the pane ref on line 1 is intact.
- **`test_tree_floor_plan_narrow_pane_degradation.py`** — Create 6 equal H-split panes (each ≈ 13 cols at 80-col canvas, below the 15-col floor). Assert each pane renders as a single-line summary matching `p:\d+ \d+%W×\d+%H \d+×\d+px \d+ tabs?` (possibly truncated with `…`).
- **`test_tree_floor_plan_tiny_canvas_suppressed.py`** — Invoke `cmux tree --canvas-cols 30`. Assert the plan is suppressed and the text contains `[layout suppressed: canvas <40 cols]`. Hierarchical tree still renders.
- **`test_tree_floor_plan_aspect_ratio.py`** — For a workspace of known dimensions (e.g., 1920×1080), count rendered plan rows and cols. Assert `rows / cols` approximates `(height / width) * 0.5` within ±1 row (documented tolerance = 1 row to account for rounding).

### Back-compat

- **`test_tree_json_backcompat.py`** — Capture pre-M8 `cmux --json tree --all` output on a baseline layout (committed fixture). After M8 lands, assert every key present in the baseline is still present with the same type. New `layout` and `content_area` keys are the only additions. Use `jsondiff`-style subset assertion.

### Hierarchical tree augmentation

- **`test_tree_text_pane_line_badges.py`** — Render `cmux tree`. For every `pane pane:N` line, assert it matches `pane pane:\d+ size=\d+%×\d+% px=\d+×\d+ split=\S+` (with `split=none` for root single pane or `split=H:left|H:right|V:top|V:bottom` chains comma-separated — e.g., `split=H:right,V:top`).

---

## Implementation notes (non-normative)

Starting points for the builder. All file paths are repo-relative.

- **Socket method to extend:** `v2SystemTree` at `Sources/TerminalController.swift:2708-2794`. It already walks workspaces; add a branch that, per workspace, pulls `bonsplitController.layoutSnapshot()` and `treeSnapshot()` and decorates the returned `workspaceNodes` / `panes` with `content_area` and per-pane `layout`.
- **Per-workspace layout derivation:** in `v2TreeWorkspaceNode` (`Sources/TerminalController.swift:2814-2903`), after `paneIds` are collected:
  1. `let snapshot = workspace.bonsplitController.layoutSnapshot()` — pixel frames in **window** coordinates (origin = content-area top-left in window space, non-zero x/y).
  2. Compute `contentOrigin = snapshot.containerFrame.origin` and `contentSize = snapshot.containerFrame.size`.
  3. For each pane geometry: subtract `contentOrigin` to get workspace-relative pixel rect; divide by `contentSize` for percent; round to the nearest integer for pixel ranges (use `Int(round(...))` consistently).
  4. Populate the `content_area.pixels.width/height` on the workspace node from `contentSize`.
- **`split_path` derivation:** walk `workspace.bonsplitController.treeSnapshot()` (`ExternalTreeNode`, defined at `vendor/bonsplit/.../LayoutSnapshot.swift:107-146`). At each `.split(splitNode)`, push `"H:left"` / `"H:right"` (for `orientation == "horizontal"`) or `"V:top"` / `"V:bottom"` (for `"vertical"`). Accumulate by pane UUID in a dictionary; look up in the existing pane iteration.
- **Percent semantics:** always **workspace-relative**, not split-relative. The `buildExternalTree` helper at `vendor/bonsplit/.../BonsplitController.swift:689-734` already computes nested bounds; your derivation re-uses that math but normalizes at the outer frame. Do not traverse splits a second time to re-derive — use the pane's absolute frame from `layoutSnapshot().panes` and divide by `containerFrame`.
- **CLI flag parsing:** `parseTreeCommandOptions` at `CLI/cmux.swift:7944-7972`. Add `--window`, `--layout`, `--no-layout`, `--canvas-cols`. Detect flag conflicts before the server call. Pass a new `scope` enum (`workspace | window | all`) in params; the server already interprets `all_windows` — extend `system.tree` to also accept `scope: "workspace"` (default) and `scope: "window"` (equivalent to today's `all_windows: false, workspace_id: nil`). Keep `all_windows` as an accepted legacy key for back-compat.
- **Text renderer:** `renderTreeText` (currently called at `CLI/cmux.swift:7940`). Extend with a `renderFloorPlan(workspace:)` helper invoked before the existing hierarchical render. Reuse Unicode box-drawing chars (`┌ ┐ └ ┘ ─ │ ├ ┤ ┬ ┴ ┼`). Suggested layout-engine approach: convert each pane's percent rect to canvas row/col ranges, emit borders along inferred grid lines (unique x-coords from box edges → column dividers; unique y-coords → row dividers). Use the Bonsplit split-tree walk to emit `T`-junctions at divider ends when sibling panes don't share an axis.
- **Canvas size detection:** `isatty(stdout)` + `ioctl(TIOCGWINSZ)` in `CLI/cmux.swift`. `cmux` already detects TTY for colorized output — reuse the same helper if present; otherwise add one.
- **Threading:** `v2SystemTree` already runs its geometry reads inside `v2MainSync` (`Sources/TerminalController.swift:2727`) because `listMainWindowSummaries` and `Workspace.bonsplitController` are main-thread-bound. Keep the new `layoutSnapshot()` / `treeSnapshot()` calls inside the same block. Socket-threading policy per `CLAUDE.md` permits this for "commands that directly manipulate AppKit/Ghostty UI state … requiring exact synchronous snapshot."
- **Rounding:** use banker's rounding (`.toNearestOrEven`) or consistent `round()`. Tests assert exact edge-touching (`A.H[1] == B.H[0]`), so both panes of a split must round the same boundary identically — compute the shared divider pixel once and use it for both panes.
- **Percent formatting:** `String(format: "%.0f", percent * 100)` for box lines (whole percents). JSON always carries full-precision `Double`. Tests compare JSON with `abs(delta) < 1e-6`.
- **Help text:** update the `"tree"` case in the help dispatch at `CLI/cmux.swift:6252-6277`. Include a short example showing the new floor-plan output inline.
- **README update:** patch `README.md` (or the docs page at `web/app/docs/...`) with a one-paragraph mention of the new default scope and the `--window` migration note.
- **No sidebar / GUI render changes.** Nothing in `Sources/ContentView.swift` or `Sources/Panels/*` needs to move.

---

## Migration notes (sanctioned break)

The default-scope change from window to workspace is the one sanctioned behavioral break in M8. Existing JSON callers that relied on `cmux --json tree` returning all workspaces in the current window must add `--window`. This is documented in:

1. `CHANGELOG.md` — one bullet under the M8 release: **"`cmux tree` now defaults to the current workspace. Use `--window` for the pre-M8 behavior."**
2. `cmux tree --help` — scope section (shown above) makes the new default and the `--window` opt-out explicit.
3. README snippet (per Open Question 7 below).

Every other contract stays back-compatible: JSON keys are additive, socket errors keep their codes, flags keep their semantics, and the `system.tree` socket method accepts both legacy `all_windows` and new `scope` in params.

---

## Open questions

1. **Orchestration skill update (follow-up, NOT part of this spec's code change).** `~/.claude/skills/cmux/references/orchestration.md` documents the current `cmux tree` / `cmux tree --all` idiom for agents. Post-M8 it should recommend `cmux tree` (default) and call out `--window` / `--all` as explicit opt-ins. This file lives outside the repo; flag it in the M8 release-notes PR so Atin can update it alongside the landing commit.
2. **Surface-line chips.** This spec does not add `terminal_type` (M1) or `model` (M2) to the hierarchical tree's surface lines. The right-hand column is reserved for them. A future pass (probably a small M3-adjacent spec amendment) should formalize the format — e.g., `surface surface:55 [terminal] "title" [selected] {claude-code · opus-4-7}`. Unresolved: exact delimiter and whether chips stay off under `--json` or mirror into a new `surface.chips` array.
3. **Floor plan for `workspace not laid out`.** When `content_area` is `null` (the workspace has never been visible since launch), what should the floor plan render? Current spec says "no plan" — but that's awkward if the default scope is a not-yet-laid-out workspace. Proposal: render a placeholder box `[workspace not laid out — focus it once to populate]`. Flag for decision before implementation.
4. **Unicode fallback.** Some terminals render box-drawing chars poorly under non-UTF-8 locales. An `--ascii` fallback (replace `┌┐└┘─│├┤┬┴┼` with `+-|`) is plausible but not in v1. Add if a user complains.
5. **Per-pane `split_path` for the GUI-layer degenerate case.** Bonsplit's tree may briefly report a degenerate split (dividerPosition ~0 or ~1) during churn. The spec clamps percent to `[0.0, 1.0]` but does not define behavior when a pane's rect is 0-sized. Suggested: skip such panes from the floor plan but still list them in the hierarchical tree. Confirm behavior with the geometry-fuzz test suite (`tests_v2/test_split_cmd_d_ctrl_d_geometry_fuzz.py`).
6. **Stability under rename.** A sibling agent is performing the mechanical `cmux → c11mux` rename concurrently. The `cmux` binary name may flip to `c11mux`. All CLI examples in this spec say `cmux` — the eventual renamed binary will carry the same flags and JSON shape. No spec change required; update examples after the rename settles.
7. **Help-text example rendering.** The proposed help block inlines a ~10-line floor-plan example. On narrow terminals the help output will wrap and look ragged. Decision: either (a) make the example adapt to terminal width, (b) keep a compact 40-col example, or (c) point at `docs/c11mux-module-8-tree-overhaul-spec.md` for the big example and keep the help terse. Recommend (c).
8. **Canvas-height floor of 6 rows.** At very flat aspect ratios (ultrawide 3440×1440 → ~20 rows at 80 cols; ultra-tall 1080×1920 vertical monitor → ~28 rows at 80 cols), the 6-row floor only hits for cartoonishly thin workspaces. Keep as stated; revisit if a user file an issue.
