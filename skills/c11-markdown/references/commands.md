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
| `--panel <id\|ref\|index>` | Existing Markdown panel to navigate in place | None; opens a new panel |
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

- Without `--panel`, the command opens a new Markdown panel in the target workspace.
- With `--panel`, the command navigates that existing Markdown panel in place and records bounded back/forward history.
- The panel title shows the filename (e.g., `plan.md`).
- The panel icon is a document icon.
- Content is **read-only** with text selection enabled.
- The file path is displayed as a breadcrumb at the top of the panel.

An optional `#fragment` selects a heading. With a stable panel target,
`c11 markdown open <path>#<fragment> --panel panel:8` navigates that
reader in place and leaves workspace selection and c11 focus unchanged. The
panel validates the target and records the source position in its bounded
back/forward history.

## Session Persistence

Markdown panels are saved and restored across sessions. On restore, the panel re-reads the file from disk. If the file no longer exists at restore time, the panel is not recreated.

## Agent Reading Commands

All reading commands require an explicit panel. They never fall back to the
focused panel, select a workspace, or change c11's in-app focus. Discover the
`markdown.agent_cli` feature, version 1, through `c11 capabilities` before
depending on the socket methods. Use a stable `panel:<n>` reference or UUID;
these commands reject bare panel indices because they are workspace-scoped.

```bash
c11 markdown scroll --panel <id|ref> --heading "Installation"
c11 markdown backlinks --panel <id|ref> --json
c11 markdown visible --panel <id|ref> --json
c11 markdown visible --panel <id|ref> --json --watch
c11 markdown theme --panel <id|ref> --list
c11 markdown theme --panel <id|ref> --set <system|light|dark>
c11 markdown typeface --panel <id|ref> --list
c11 markdown typeface --panel <id|ref> --set <theme|serif|sans|mono>
c11 markdown font --panel <id|ref> --scale <0.5..3.0>
c11 markdown open-external --panel <id|ref>
c11 markdown open /path/to/guide.md#installation --panel <id|ref>
c11 markdown history --panel <id|ref> --json
c11 markdown links --panel <id|ref> --broken --json
```

`visible` returns JSON containing the heading path, visible 1-based source-line
range, reading progress, theme and typeface, font scale, pane size, find state,
and bounded selected text. `scroll`, `visible`, and `visible --watch` create a
hidden reader when needed and wait up to eight seconds for its first rendered
state. `not_ready` or `timeout` means the reader did not become ready in that
window; agents cannot select a workspace to initialize it, so report the error.
A hidden-panel scroll takes effect in its reader, and the gold flash appears
when the panel is next shown.

`backlinks` returns bounded references to the selected panel's current file.
Each row includes the source file, source section and line, link text, and
target fragment. The query is local and read-only; it does not change panel or
workspace selection. An unready index returns `not_ready`.

`visible --watch` prints the initial state and each coalesced change as
newline-delimited JSON. It uses renderer state events, not polling, stays
attached to the panel model while WebKit is evicted, streams presentation
changes, and resumes rendered state when the reader is recreated or shown. It
ends when the panel closes (for example, `c11 close-panel --panel panel:8`),
the client disconnects, c11 stops the CLI listener, or the peer sends more
bytes or half-closes its request side.
`scroll --heading` prefers an exact slug or exact case-insensitive heading text.
If only broader matches exist, it chooses a unique prefix before considering a
unique substring; multiple matches at that tier return `ambiguous` with heading
examples instead of silently scrolling to the first one.

`markdown open <path>#<fragment> --panel` navigates an existing reader in place.
Successful JSON responses carry `result.outcome` as `navigated` or `unchanged`;
the plain CLI prints `navigation=navigated|unchanged`. Failures use the v2
error envelope (`invalid_params`, `not_found`, `permission_denied`,
`superseded`, or `timeout`); when navigation produced an outcome, it is in
`error.data.outcome` using the native case name (`invalidTarget`, `notFound`,
`notReadable`, `outsideScope`, `superseded`, or `panelClosed`). Automatic
document, palette, and backlink navigation stays inside the source repository,
or the document's directory when no repository is present. The direct agent CLI
origin can open an explicit path; back/forward restores the recorded scope and
reading position.
The native method is
`@MainActor @discardableResult func MarkdownPanel.navigate(to fileURL: URL, fragment: String?, origin: MarkdownNavigationOrigin) async -> MarkdownNavigationOutcome`.

`history --json` reports the panel's bounded history and captured reading
positions. `links --broken --json` returns one `result.links` array, plus
`total` and `truncated`; broken entries carry `broken: true` and a snake-case
`reason`: `not_found`, `not_readable`, `outside_scope`, `invalid_target`,
`invalid_fragment`, `blocked_target`, or `missing_fragment`. Relative-link navigation defaults to the current panel; the
toolbar toggle changes the default destination, and Cmd-click uses the opposite
destination. Same-document anchors always stay in the current panel, including
Cmd-click, and enter its history. ⌘[ / ⌘] and the toolbar arrows move back and
forward. Hover previews are native-validated inert excerpts with bounded
content. `links --broken` caps inspection to 128 links and 16 target documents
of at most 256 KiB each; a `truncated` result means more content was present
than the bounded inspection could examine.

Theme and typeface `--list` return the names registered by the markdown viewer;
`--set` rejects any other name. Font scale accepts finite values from 0.5 to
3.0 and is saved with the panel's 0.1-step precision. `open-external` asks
macOS to open the panel's bound file in its default application behind c11.

## Help

```bash
c11 markdown --help
c11 markdown -h
```

See also:
- [live-reload.md](live-reload.md)
