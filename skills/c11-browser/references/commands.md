# Command Reference (c11 Browser)

This maps common `agent-browser` usage to `c11 browser` usage.

## Direct Equivalents

- `agent-browser open <url>` -> `c11 browser open <url>`
- `agent-browser goto|navigate <url>` -> `c11 browser <surface> goto|navigate <url>`
- `agent-browser snapshot -i` -> `c11 browser <surface> snapshot --interactive`
- `agent-browser click <ref>` -> `c11 browser <surface> click <ref>`
- `agent-browser fill <ref> <text>` -> `c11 browser <surface> fill <ref> <text>`
- `agent-browser type <ref> <text>` -> `c11 browser <surface> type <ref> <text>`
- `agent-browser select <ref> <value>` -> `c11 browser <surface> select <ref> <value>`
- `agent-browser get text <ref>` -> `c11 browser <surface> get text <ref-or-selector>`
- `agent-browser get url` -> `c11 browser <surface> get url`
- `agent-browser get title` -> `c11 browser <surface> get title`

## Core Command Groups

### Navigation

```bash
c11 browser open <url>                        # opens in caller's workspace (uses CMUX_WORKSPACE_ID)
c11 browser open <url> --workspace <id|ref>   # opens in a specific workspace
c11 browser <surface> goto <url>
c11 browser <surface> back|forward|reload
c11 browser <surface> get url|title
```

> **Workspace context:** `browser open` targets the workspace of the terminal where the command is run (via `CMUX_WORKSPACE_ID`; `C11_WORKSPACE_ID` is the primary name going forward, `CMUX_WORKSPACE_ID` still works), even if a different workspace is currently focused. Use `--workspace` to override.

### Snapshot and Inspection

```bash
c11 browser <surface> snapshot --interactive
c11 browser <surface> snapshot --interactive --compact --max-depth 3
c11 browser <surface> get text body
c11 browser <surface> get html body
c11 browser <surface> get value "#email"
c11 browser <surface> get attr "#email" --attr placeholder
c11 browser <surface> get count ".row"
c11 browser <surface> get box "#submit"
c11 browser <surface> get styles "#submit" --property color
c11 browser <surface> eval '<js>'
```

### Interaction

```bash
c11 browser <surface> click|dblclick|hover|focus <selector-or-ref>
c11 browser <surface> fill <selector-or-ref> [text]   # empty text clears
c11 browser <surface> type <selector-or-ref> <text>
c11 browser <surface> press|keydown|keyup <key>
c11 browser <surface> select <selector-or-ref> <value>
c11 browser <surface> check|uncheck <selector-or-ref>
c11 browser <surface> scroll [--selector <css>] [--dx <n>] [--dy <n>]
```

### Wait

```bash
c11 browser <surface> wait --selector "#ready" --timeout-ms 10000
c11 browser <surface> wait --text "Done" --timeout-ms 10000
c11 browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
c11 browser <surface> wait --load-state complete --timeout-ms 15000
c11 browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

### Session/State

```bash
c11 browser <surface> cookies get|set|clear ...
c11 browser <surface> storage local|session get|set|clear ...
c11 browser <surface> tab list|new|switch|close ...
c11 browser <surface> state save|load <path>
```

### Diagnostics

```bash
c11 browser <surface> console list|clear
c11 browser <surface> errors list|clear
c11 browser <surface> highlight <selector>
c11 browser <surface> screenshot
c11 browser <surface> download wait --timeout-ms 10000
```

## Agent Reliability Tips

- Use `--snapshot-after` on mutating actions to return a fresh post-action snapshot.
- Re-snapshot after navigation, modal open/close, or major DOM changes.
- Prefer short handles in outputs by default (`surface:N`, `pane:N`, `workspace:N`, `window:N`).
- Use `--id-format both` only when a UUID must be logged/exported.

## Known WKWebView Gaps (`not_supported`)

- `browser.viewport.set`
- `browser.geolocation.set`
- `browser.offline.set`
- `browser.trace.start|stop`
- `browser.network.route|unroute|requests`
- `browser.screencast.start|stop`
- `browser.input_mouse|input_keyboard|input_touch`

See also:
- [snapshot-refs.md](snapshot-refs.md)
- [authentication.md](authentication.md)
- [session-management.md](session-management.md)
