# Command Reference (c11 Markdown)

## Opening a Markdown Tab

```bash
c11 markdown open <path>
c11 markdown <path>          # shorthand (implicit "open")
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--workspace <id\|ref\|index>` | Target workspace | `$C11_WORKSPACE_ID` |
| `--tab <id\|ref\|index>` | Source tab to split from | Focused tab |
| `--window <id\|ref>` | Target window | Current window |

### Output

```
OK tab=tab:8 area=area:3 path=/absolute/path/to/file.md
```

With `--json`:

```json
{
  "window_id": "...",
  "workspace_id": "...",
  "area_id": "...",
  "tab_id": "...",
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

## Tab Behavior

- The tab opens as a **horizontal split** to the right of the source tab.
- The tab title shows the filename (e.g., `plan.md`).
- The tab icon is a document icon.
- Content is **read-only** with text selection enabled.
- The file path is displayed as a breadcrumb at the top of the tab.

## Session Persistence

Markdown tabs are saved and restored across sessions. On restore, the tab re-reads the file from disk. If the file no longer exists at restore time, the tab is not recreated.

## Help

```bash
c11 markdown --help
c11 markdown -h
```

See also:
- [live-reload.md](live-reload.md)
