# WorkspaceApplyPlan schema (v1)

Reference for the JSON shape accepted by `workspace.apply`, emitted by
`workspace.export_blueprint`, and embedded inside `WorkspaceSnapshotFile`.
Fields use camelCase wire names (Swift synthesized Codable) except where
explicit `CodingKeys` or custom encode/decode are defined (see LayoutTreeSpec).

## Top-level envelope

```json
{
  "version": 1,
  "workspace": { ... },
  "layout": { ... },
  "panels": [ ... ]
}
```

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `version` | int | yes | Must be `1` |
| `workspace` | WorkspaceSpec | yes | Workspace-level settings |
| `layout` | LayoutTreeSpec | yes | Area/split tree |
| `panels` | object[] | yes | Keyed by plan-local id; each entry is described under [`panels` entries](#panels-entries) |

## WorkspaceSpec

```json
{
  "title": "My workspace",
  "customColor": "#C0392B",
  "workingDirectory": "/Users/me/project",
  "metadata": { "key": "value" }
}
```

All fields optional. `customColor` accepts a hex string (`#RRGGBB`) or a named palette color
(e.g., `"Red"`, `"Blue"`). Unknown names return an `ApplyFailure` with code
`unknown_color_name` without aborting the plan. `metadata` values must be strings.

## LayoutTreeSpec

A recursive union: either an area leaf (`"type": "pane"`) or a `split` node.

### Area leaf

```json
{ "type": "pane", "pane": { "panelIds": ["s1", "s2"], "selectedIndex": 0 } }
```

`selectedIndex` is optional; omit to preserve focus as-is.

### Split node

```json
{
  "type": "split",
  "split": {
    "orientation": "horizontal",
    "dividerPosition": 0.6,
    "first": { ... },
    "second": { ... }
  }
}
```

`orientation`: `"horizontal"` (side by side) or `"vertical"` (top/bottom).
`dividerPosition`: float in `(0, 1)`.

## `panels` entries

```json
{
  "id": "s1",
  "kind": "terminal",
  "title": "main",
  "description": "Primary shell",
  "workingDirectory": "/Users/me/project",
  "command": "echo hello",
  "url": "https://example.com",
  "filePath": "/Users/me/notes.md",
  "metadata": { "terminal_type": "claude-code" },
  "paneMetadata": { "mailbox.task": "CMUX-37" }
}
```

| Field | Kind | Notes |
|-------|------|-------|
| `id` | all | Plan-local stable id. Appears in `ApplyResult.panelRefs` |
| `kind` | all | `"terminal"`, `"browser"`, or `"markdown"` |
| `title` | all | Written via `setPanelCustomTitle` |
| `description` | all | Written to panel metadata under `description` key |
| `workingDirectory` | terminal | Shell launch directory; ignored (warning) on browser/markdown |
| `command` | terminal | Sent as text once the panel is ready |
| `url` | browser | Initial navigation URL |
| `filePath` | markdown | Absolute path to the markdown file |
| `metadata` | all | Panel-scoped key/value pairs (`SurfaceMetadataStore`) |
| `paneMetadata` | all | Area-scoped key/value pairs; only the first panel per area writes |

`metadata` and `pane_metadata` values must be JSON-serialisable. Non-string
values on the reserved `mailbox.*` area namespace are dropped with a warning.

## ApplyResult

```json
{
  "workspaceRef": "workspace:<uuid>",
  "panelRefs": { "s1": "panel:<uuid>", "s2": "panel:<uuid>" },
  "areaRefs": { "s1": "area:<uuid>" },
  "warnings": [],
  "failures": []
}
```

`failures` entries: `{ "code": "...", "step": "...", "message": "..." }`.
