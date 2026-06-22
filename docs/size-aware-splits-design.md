# Size-aware pane creation

## Problem

`new-split` / `new-pane` split the target 50/50 with no notion of a minimum usable
size. Stacking splits (vertical especially) drives panes to sizes like 584×173 pt
(≈70 cols × 10 rows) — too small to read or drive a coding-agent TUI. An orchestrator
fanning out sub-agent panes ends up with several panes at 25%×13% and the operator has
to manually recombine. c11 also treats every surface kind identically: a Claude Code
TUI and a `tail -f` log pane get the same blind 50/50.

## Goal

Pane creation refuses to produce an unusable pane: it either lays the split out usably
(picking the roomier axis), turns the request into a tab (tabs do not shrink), or
returns a clear actionable refusal. Behavior is configurable with a safe default and a
per-call escape hatch.

## Architecture (where things live)

c11's live split engine is **Bonsplit** (`vendor/bonsplit/`), driven via
`Workspace.bonsplitController`. The ghostty submodule's `SplitTree.swift` is unused by
c11.

- `bonsplitController.layoutSnapshot()` → `containerFrame` (content area, pt) and
  `panes[]` each with a pixel `frame` (pt). This is the source of the current pane size.
- A terminal surface's font cell size lives on `TerminalPanel.hostedView.cellSize`
  (`GhosttySurfaceScrollView`), reported by Ghostty in **backing pixels**, while pane
  frames are in **AppKit points**. `Workspace.sourceCellSize` divides the cell size by
  the surface's `backingScaleFactor` to bring both into points before deriving
  `cols = frame.width / cellSize.width`, `rows = frame.height / cellSize.height`.
- Surface kind comes from `terminal_type` in the surface manifest
  (`SurfaceMetadataStore`): `claude-code`, `codex`, `grok`, `kimi`, `opencode`,
  `opencode-run`, `github-copilot` are coding agents; `shell` / `unknown` / unset are
  generic terminals.

### Creation paths

| CLI | V2 method | App handler | Effect |
|-----|-----------|-------------|--------|
| `new-split` | `surface.split` | `v2SurfaceSplit` → `tabManager.newSplit` → `Workspace.newTerminalSplit` | split (shrinks) |
| `new-pane` | `pane.create` | `v2PaneCreate` → `Workspace.new{Terminal,Browser,Markdown}Split` | split (shrinks) |
| `new-surface` | `surface.create` | `v2SurfaceCreate` | tab (no shrink) — the fallback target |

`Workspace.newTerminalSplit` sets `isProgrammaticSplit = true` around the Bonsplit
mutation, so CLI/programmatic splits are distinguishable from UI (Bonsplit tab-bar
button / drag) splits.

## The size model

Minimums are per surface kind, expressed in cols × rows and converted to points with the
source surface's cell size:

| Kind | Minimum (cols × rows) | Optimum |
|------|----------------------|---------|
| Coding agent | 80 × 20 | 120 × 30 |
| Generic terminal | 40 × 10 | 80 × 24 |
| Browser / markdown | 320 × 240 pt (fixed) | — |

A split inherits kind: splitting a `claude-code` pane holds **both** children to the
agent minimum (this is exactly the orchestrator fan-out case — every spawned agent pane
stays usable). The existing child is held to the source's own kind; the new child is
held to the new pane's type (terminal new panes inherit the source kind; browser/markdown
use the point floor). The controlling minimum on the shrinking axis is the max of the
two children's requirements.

A surface may override its own minimum via `min_cols` / `min_rows` metadata keys (lets a
status strip or log tail declare itself tiny-ok). Optional; defaults apply when unset.

### Geometry

For a source pane of `W × H` points, a 50/50 split yields two children:

- **Horizontal** (side-by-side): each child is `W/2 × H`. Admissible iff `W/2 ≥ minW`
  **and** `H ≥ minH`.
- **Vertical** (stacked): each child is `W × H/2`. Admissible iff `W ≥ minW` **and**
  `H/2 ≥ minH`.

A split is *near threshold* when admissible but the controlling dimension is within 15%
of the minimum — a non-blocking warning.

## Policy modes (setting `paneSizeMode`, default `balance`)

| Mode | Behavior |
|------|----------|
| `off` | Never block; today's blind 50/50. |
| `warn` | Never block; attach a warning when the result is undersized / near threshold. |
| `balance` (default) | Use the requested axis if admissible; else auto-flip to the other axis if that is admissible; else **refuse** with an actionable message. |
| `tab` | Like `balance`, but when neither axis is admissible, fall back to adding a **tab** to the target pane instead of refusing. |

- Setting persists via `@AppStorage` (`SocketControlSettings`-style enum). Env override
  `C11_SPLIT_SIZE_POLICY` (and `CMUX_*` compat) for headless/tests.
- Per-call escape hatch: `--allow-undersized` (alias `--force`) on `new-split` /
  `new-pane` → `allow_undersized: true` param → behave as `off` for that one call.

## Outcome reporting

V2 success envelope gains:

- `requested_direction`, `applied_direction` (differ when flipped)
- `size_outcome`: `split` | `flipped` | `tab`
- `size_warning`: string | null

Refusal returns `.err(code: "pane_too_small", message: <actionable>, data: { resulting,
minimum, pane_ref })`. Message names the offending size, the minimum, the kind, and the
remedies (add a tab with `new-surface --pane …`, close a sibling, or `--allow-undersized`).

The CLI prints `size_warning` when present and surfaces the refusal message on error.

## UI path (follow-up, deferred)

A global Bonsplit `splitTabBar(_:shouldSplitPane:orientation:)` veto would catch the
tab-bar split buttons and drag-to-split, but it also fires for direct
`bonsplitController.splitPane` callers that are *not* interactive (cross-workspace
tab-drag in `AppDelegate`, other socket split commands), and the only in-app notice
channel is a modal `NSAlert`. A veto can only deny, not flip the axis, so it would
reject an explicit "split down" even when "split right" would fit. Given the blast
radius and that the *accidental* tiny-pane pain is the CLI/orchestrator fan-out (fully
covered by the handlers), the manual UI path is left as-is in this change and tracked as
a follow-up — ideally routing the tab-bar split buttons through the same size-aware
evaluation so they can flip the axis rather than just refuse.

CLI splits go through `Workspace.newTerminalSplit` (which sets `isProgrammaticSplit`),
so they would bypass any future veto; the handler owns their richer policy regardless.

## Testing

Pure decision logic (`PaneSizePolicy.decide`) is unit-tested in `c11LogicTests` (fast,
host-free): given pane rect + cell size + kind + requested axis + mode → expected outcome
(proceed / flip / tab / refuse) and flags (flipped, nearThreshold). Covers the 584×173
repro, the orchestrator fan-out cascade, axis-flip selection, force bypass, and per-kind
minimums.

## Out of scope / follow-ups

- Auto-rebalance "tidy" so N panes on an axis distribute evenly — `equalizeSplits`
  already exists in `TabManager`/`Workspace`; exposing a `balance-panes` CLI verb is a
  natural follow-up.
- Axis-flip for the UI path (the veto can only deny, not redirect).
