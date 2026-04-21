# Command Reference (c11 Markdown)

## Opening a Markdown Panel

```bash
c11 markdown open <path>
c11 markdown <path>          # shorthand (implicit "open")
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--workspace <id\|ref\|index>` | Target workspace | `$CMUX_WORKSPACE_ID` (`C11_WORKSPACE_ID` is the primary name going forward; `CMUX_WORKSPACE_ID` still works) |
| `--surface <id\|ref\|index>` | Source surface to split from | Focused surface |
| `--window <id\|ref>` | Target window | Current window |

### Output

```
OK surface=surface:8 pane=pane:3 path=/absolute/path/to/file.md
```

With `--json`:

```json
{
  "window_id": "...",
  "workspace_id": "...",
  "pane_id": "...",
  "surface_id": "...",
  "path": "/absolute/path/to/file.md"
}
```

## Path Resolution

- Relative paths are resolved against the caller's current working directory.
- `~` is expanded to the home directory.
- The resolved absolute path is returned in the output.

```bash
# These are equivalent when run from /Users/me/project
c11 markdown open plan.md
c11 markdown open ./plan.md
c11 markdown open /Users/me/project/plan.md
```

## Panel Behavior

- The panel opens as a **horizontal split** to the right of the source surface.
- The tab title shows the filename (e.g., `plan.md`).
- The tab icon is a document icon.
- Content is **read-only** with text selection enabled.
- The file path is displayed as a breadcrumb at the top of the panel.

## Session Persistence

Markdown panels are saved and restored across sessions. On restore, the panel re-reads the file from disk. If the file no longer exists at restore time, the panel is not recreated.

## Help

```bash
c11 markdown --help
c11 markdown -h
```

See also:
- [live-reload.md](live-reload.md)
