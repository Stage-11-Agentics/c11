# Command Reference (c11 Markdown)

## Opening a Markdown Panel

```bash
c11 markdown open <path>
c11 markdown <path>          # shorthand (implicit "open")
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--workspace <id\|ref\|index>` | Target workspace | `$C11_WORKSPACE_ID` |
| `--panel <id\|ref\|index>` | Source panel to split from | Focused panel |
| `--window <id\|ref>` | Target window | Current window |

### Output

```
OK panel=panel:8 area=area:3 path=/absolute/path/to/file.md
```

With `--json`:

```json
{
  "window_id": "...",
  "workspace_id": "...",
  "area_id": "...",
  "panel_id": "...",
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

- The panel opens as a **horizontal split** to the right of the source panel.
- The panel title shows the filename (e.g., `plan.md`).
- The panel icon is a document icon.
- Content is **read-only** with text selection enabled.
- The file path is displayed as a breadcrumb at the top of the panel.

## Session Persistence

Markdown panels are saved and restored across sessions. On restore, the panel re-reads the file from disk. If the file no longer exists at restore time, the panel is not recreated.

## Agent Reading Commands

All reading commands require an explicit panel. They never fall back to the
focused panel, select a workspace, or change c11's in-app focus.

```bash
c11 markdown scroll --panel <id|ref> --heading "Installation"
c11 markdown visible --panel <id|ref> --json
c11 markdown visible --panel <id|ref> --json --watch
c11 markdown theme --panel <id|ref> --list
c11 markdown theme --panel <id|ref> --set <system|light|dark>
c11 markdown typeface --panel <id|ref> --list
c11 markdown typeface --panel <id|ref> --set <theme|serif|sans|mono>
c11 markdown font --panel <id|ref> --scale <0.5..3.0>
c11 markdown open-external --panel <id|ref>
```

`visible` returns JSON containing the heading path, visible 1-based source-line
range, reading progress, theme and typeface, font scale, pane size, find state,
and bounded selected text. `visible --watch` prints the initial state and each
coalesced change as newline-delimited JSON. It uses renderer state events, not
polling, and ends when the panel closes or the client disconnects.

Theme and typeface `--list` return the names registered by the markdown viewer;
`--set` rejects any other name. Font scale accepts finite values from 0.5 to
3.0 and is saved with the panel's 0.1-step precision. `open-external` asks
macOS to open the panel's bound file in its default application.

## Help

```bash
c11 markdown --help
c11 markdown -h
```

See also:
- [live-reload.md](live-reload.md)
