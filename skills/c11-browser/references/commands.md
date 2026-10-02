# Command Reference (c11 Browser)

This maps common `agent-browser` usage to `c11 browser` usage.

## Direct Equivalents

- `agent-browser open <url>` -> `c11 browser open <url>`
- `agent-browser goto|navigate <url>` -> `c11 browser <tab> goto|navigate <url>`
- `agent-browser snapshot -i` -> `c11 browser <tab> snapshot --interactive`
- `agent-browser click <ref>` -> `c11 browser <tab> click <ref>`
- `agent-browser fill <ref> <text>` -> `c11 browser <tab> fill <ref> <text>`
- `agent-browser type <ref> <text>` -> `c11 browser <tab> type <ref> <text>`
- `agent-browser select <ref> <value>` -> `c11 browser <tab> select <ref> <value>`
- `agent-browser get text <ref>` -> `c11 browser <tab> get text <ref-or-selector>`
- `agent-browser get url` -> `c11 browser <tab> get url`
- `agent-browser get title` -> `c11 browser <tab> get title`

## Core Command Groups

### Navigation

```bash
c11 browser open <url>                        # opens in caller's workspace (uses C11_WORKSPACE_ID)
c11 browser open <url> --workspace <id|ref>   # opens in a specific workspace
c11 browser <tab> goto <url>
c11 browser <tab> back|forward|reload
c11 browser <tab> get url|title

c11 browser open <url> --allow-insecure-http   # consent to one plain-http navigation
c11 browser <tab> goto <url> --allow-insecure-http
```

> **Plain `http://`:** loopback hosts are allowed by default; any other plain-HTTP host either sheets a prompt for a human (`insecure_http: {"status": "prompted"}` in the payload) or, with no window to prompt on, fails with `insecure_http_blocked`. `--allow-insecure-http` consents for that one navigation to that one host.

> **Workspace context:** `browser open` targets the workspace of the terminal where the command is run (via `C11_WORKSPACE_ID`), even if a different workspace is currently focused. Use `--workspace` to override.

### Snapshot and Inspection

```bash
c11 browser <tab> snapshot --interactive
c11 browser <tab> snapshot --interactive --compact --max-depth 3
c11 browser <tab> get text body
c11 browser <tab> get html body
c11 browser <tab> get value "#email"
c11 browser <tab> get attr "#email" --attr placeholder
c11 browser <tab> get count ".row"
c11 browser <tab> get box "#submit"
c11 browser <tab> get styles "#submit" --property color
c11 browser <tab> eval '<js>'
```

### Interaction

```bash
c11 browser <tab> click|dblclick|hover|focus <selector-or-ref>
c11 browser <tab> fill <selector-or-ref> [text]   # empty text clears
c11 browser <tab> type <selector-or-ref> <text>
c11 browser <tab> press|keydown|keyup <key>
c11 browser <tab> select <selector-or-ref> <value>
c11 browser <tab> check|uncheck <selector-or-ref>
c11 browser <tab> scroll [--selector <css>] [--dx <n>] [--dy <n>]
```

### Wait

```bash
c11 browser <tab> wait --selector "#ready" --timeout-ms 10000
c11 browser <tab> wait --text "Done" --timeout-ms 10000
c11 browser <tab> wait --url-contains "/dashboard" --timeout-ms 10000
c11 browser <tab> wait --load-state complete --timeout-ms 15000
c11 browser <tab> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

### Session/State

```bash
c11 browser <tab> cookies get|set|clear ...
c11 browser <tab> storage local|session get|set|clear ...
c11 browser <tab> tab list|new|switch|close ...
c11 browser <tab> state save|load <path>
```

`cookies clear` requires a scope unless `--all` is explicit. Use `--name`,
`--domain`, `--url`, or `--path`; URL scopes respect cookie domain, path, and
secure-cookie rules, so a host substring does not clear an unrelated origin.
`state load` waits for the saved URL's navigation to commit on the expected
origin before applying localStorage/sessionStorage. A failed or wrong-origin
navigation returns an error without writing storage.

### Diagnostics

```bash
c11 browser <tab> console list|clear
c11 browser <tab> errors list|clear
c11 browser <tab> highlight <selector>
c11 browser <tab> screenshot
c11 browser <tab> download wait --timeout-ms 10000
```

## Maintainer Crash Recovery Probe (DEBUG only)

On a tagged QA build, call the socket method
`debug.browser.simulate_web_content_termination` with the browser's `workspace_id`
and `tab_id`. `scheduled: true` means recovery was queued; wait for the next
main turn and page load before inspecting the URL or taking a snapshot. Duplicate
calls while pending return `scheduled: false`. For the same URL within ten seconds,
the first termination restores the URL, the second shows the existing error page,
and further terminations do not create another view. Use synthetic pages only.

## Agent Reliability Tips

- Use `--snapshot-after` on mutating actions to return a fresh post-action snapshot.
- Re-snapshot after navigation, modal open/close, or major DOM changes.
- Prefer short handles in outputs by default (`tab:N`, `area:N`, `workspace:N`, `window:N`) within the current c11 process; they start over after a restart, so store the tab UUID from `c11 --id-format both tree --json` for later targeting.
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
