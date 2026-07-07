# c11 Socket API Reference

The **v2 JSON socket protocol** for programmatically controlling c11 over a Unix domain socket. Every surface, pane, workspace, browser, and theme is addressable from outside the process, so agents can compose their own environment without the operator in the loop.

> This reference is generated against the v2 method dispatch in `Sources/TerminalController.swift`. The **method index** below lists every dotted v2 method the running app accepts. Cross-check a live instance with `c11 capabilities`.

## Socket configuration

| Build | Default socket path |
|-------|---------------------|
| Release (stable) | `~/Library/Application Support/c11/c11.sock` |
| Debug | `/tmp/c11-debug.sock` |
| Tagged debug | `/tmp/c11-debug-<tag>.sock` |

Override the path with the `C11_SOCKET_PATH` environment variable (the CLI also reads `C11_SOCKET`). Inside a c11 terminal, `C11_SOCKET_PATH` is injected automatically so a spawned process talks to its own c11.

## Access modes

The socket is gated. The mode is set in Settings or via `C11_SOCKET_MODE`:

| Mode | Meaning |
|------|---------|
| `off` | Socket disabled |
| `c11Only` | Only processes started inside c11 terminals may connect (**default**) |
| `automation` | Broader automation access |
| `password` | Requires a shared secret |
| `allowAll` | Any local process may connect, no auth — unsafe (`C11_SOCKET_MODE=allowAll`) |

Mode parsing is punctuation- and case-insensitive: `c11-only` / `c11_only` normalize to `c11Only`, `allow-all` / `allow_all` to `allowAll`. Legacy values `full` (→ `allowAll`) and `notifications` (→ `automation`), and the pre-rename `cmux-only` alias, are still accepted for compatibility. For stable/nightly builds an env override additionally requires `C11_ALLOW_SOCKET_OVERRIDE=1`.

## Protocol — newline-delimited JSON

One JSON request per line; one JSON response per line (any newlines inside a response are escaped to `\n` so each response stays on a single line).

**Request**

```json
{"id": "req-1", "method": "workspace.list", "params": {}}
```

- `method` (string, required) — a dotted `domain.method` from the index below.
- `id` (any, optional) — echoed back on the response.
- `params` (object, optional) — method arguments; defaults to `{}`.

**Success response**

```json
{"id": "req-1", "ok": true, "result": {"workspaces": [ ... ]}}
```

**Error response**

```json
{"id": "req-1", "ok": false, "error": {"code": "invalid_request", "message": "Missing method"}}
```

Protocol-level error codes: `invalid_utf8`, `parse_error`, `invalid_request`, `invalid_dispatch`, `encode_error`. Individual methods return their own domain-specific codes in the same `error` envelope.

**Example round-trip**

```bash
SOCK="${C11_SOCKET_PATH:-/tmp/c11-debug.sock}"
printf '%s\n' '{"id":"ping","method":"system.ping","params":{}}' | nc -U "$SOCK"
# → {"id":"ping","ok":true,"result":{"pong":true}}
```

## CLI

The `c11` CLI wraps these methods: e.g. `c11 list-workspaces` → `workspace.list`, `c11 identify` → `system.identify`, `c11 capabilities` → `system.capabilities`. The `cmux` command is a compatibility alias that dispatches to the same binary. Run `c11 --help` for the full command surface, and `c11 capabilities` on a running instance for the authoritative method list of that build.

## Method index

All dotted v2 methods, grouped by domain. Method names are stable identifiers; arguments travel in `params` and results in `result`. The `debug.*` domain is a set of test/automation hooks and is only meaningful on debug/tagged builds.

### System (`system.*`) — 5

- `system.brand`
- `system.capabilities`
- `system.identify`
- `system.ping`
- `system.tree`

### Windows (`window.*`) — 5

- `window.close`
- `window.create`
- `window.current`
- `window.focus`
- `window.list`

### Workspaces (`workspace.*`) — 25

- `workspace.action`
- `workspace.apply`
- `workspace.clear_metadata`
- `workspace.close`
- `workspace.create`
- `workspace.current`
- `workspace.export_blueprint`
- `workspace.get_metadata`
- `workspace.last`
- `workspace.list`
- `workspace.list_blueprints`
- `workspace.move_to_window`
- `workspace.next`
- `workspace.parse_blueprint`
- `workspace.previous`
- `workspace.remote.configure`
- `workspace.remote.disconnect`
- `workspace.remote.reconnect`
- `workspace.remote.status`
- `workspace.remote.terminal_session_end`
- `workspace.rename`
- `workspace.reorder`
- `workspace.select`
- `workspace.set_custom_color`
- `workspace.set_metadata`

### Surfaces (`surface.*`) — 25

- `surface.action`
- `surface.cancel_flash`
- `surface.clear_history`
- `surface.clear_metadata`
- `surface.close`
- `surface.create`
- `surface.current`
- `surface.drag_to_split`
- `surface.focus`
- `surface.get_metadata`
- `surface.get_titlebar_state`
- `surface.health`
- `surface.list`
- `surface.move`
- `surface.read_text`
- `surface.refresh`
- `surface.reorder`
- `surface.send_key`
- `surface.send_text`
- `surface.set_custom_color`
- `surface.set_metadata`
- `surface.set_titlebar_collapsed`
- `surface.set_titlebar_visibility`
- `surface.split`
- `surface.trigger_flash`

### Panes (`pane.*`) — 13

- `pane.break`
- `pane.clear_metadata`
- `pane.confirm`
- `pane.create`
- `pane.focus`
- `pane.get_metadata`
- `pane.join`
- `pane.last`
- `pane.list`
- `pane.resize`
- `pane.set_metadata`
- `pane.surfaces`
- `pane.swap`

### Browser (`browser.*`) — 84

- `browser.addinitscript`
- `browser.addscript`
- `browser.addstyle`
- `browser.back`
- `browser.check`
- `browser.click`
- `browser.console.clear`
- `browser.console.list`
- `browser.cookies.clear`
- `browser.cookies.get`
- `browser.cookies.set`
- `browser.dblclick`
- `browser.dialog.accept`
- `browser.dialog.dismiss`
- `browser.download.wait`
- `browser.errors.list`
- `browser.eval`
- `browser.fill`
- `browser.find.alt`
- `browser.find.first`
- `browser.find.label`
- `browser.find.last`
- `browser.find.nth`
- `browser.find.placeholder`
- `browser.find.role`
- `browser.find.testid`
- `browser.find.text`
- `browser.find.title`
- `browser.focus`
- `browser.focus_webview`
- `browser.forward`
- `browser.frame.main`
- `browser.frame.select`
- `browser.geolocation.set`
- `browser.get.attr`
- `browser.get.box`
- `browser.get.count`
- `browser.get.html`
- `browser.get.styles`
- `browser.get.text`
- `browser.get.title`
- `browser.get.value`
- `browser.highlight`
- `browser.hover`
- `browser.input_keyboard`
- `browser.input_mouse`
- `browser.input_touch`
- `browser.is.checked`
- `browser.is.enabled`
- `browser.is.visible`
- `browser.is_webview_focused`
- `browser.keydown`
- `browser.keyup`
- `browser.navigate`
- `browser.network.requests`
- `browser.network.route`
- `browser.network.unroute`
- `browser.offline.set`
- `browser.open_split`
- `browser.press`
- `browser.reload`
- `browser.screencast.start`
- `browser.screencast.stop`
- `browser.screenshot`
- `browser.scroll`
- `browser.scroll_into_view`
- `browser.select`
- `browser.snapshot`
- `browser.state.load`
- `browser.state.save`
- `browser.storage.clear`
- `browser.storage.get`
- `browser.storage.set`
- `browser.tab.close`
- `browser.tab.list`
- `browser.tab.new`
- `browser.tab.switch`
- `browser.trace.start`
- `browser.trace.stop`
- `browser.type`
- `browser.uncheck`
- `browser.url.get`
- `browser.viewport.set`
- `browser.wait`

### Theme (`theme.*`) — 10

- `theme.clear_active`
- `theme.diff`
- `theme.dump`
- `theme.get`
- `theme.inherit`
- `theme.list`
- `theme.paths`
- `theme.reload`
- `theme.set_active`
- `theme.validate`

### Conversations (`conversation.*`) — 6

- `conversation.claim`
- `conversation.clear`
- `conversation.get`
- `conversation.list`
- `conversation.push`
- `conversation.tombstone`

### Mailbox (`mailbox.*`) — 1

- `mailbox.resolve`

### Notifications (`notification.*`) — 5

- `notification.clear`
- `notification.create`
- `notification.create_for_surface`
- `notification.create_for_target`
- `notification.list`

### Markdown surfaces (`markdown.*`) — 2

- `markdown.get_content`
- `markdown.open`

### Snapshots (`snapshot.*`) — 5

- `snapshot.create`
- `snapshot.list`
- `snapshot.list_sets`
- `snapshot.restore`
- `snapshot.restore_set`

### Feedback (`feedback.*`) — 2

- `feedback.open`
- `feedback.submit`

### Tabs (`tab.*`) — 1

- `tab.action`

### Sidebar (`sidebar.*`) — 1

- `sidebar.state`

### Settings (`settings.*`) — 1

- `settings.open`

### Session (`session.*`) — 1

- `session.save`

### App (`app.*`) — 3

- `app.focus_override.set`
- `app.restart`
- `app.simulate_active`

### Auth (`auth.*`) — 1

- `auth.login`

### Debug (`debug.*`) — 35

- `debug.app.activate`
- `debug.bonsplit_underflow.count`
- `debug.bonsplit_underflow.reset`
- `debug.browser.address_bar_focused`
- `debug.browser.favicon`
- `debug.command_palette.rename_input.delete_backward`
- `debug.command_palette.rename_input.interact`
- `debug.command_palette.rename_input.select_all`
- `debug.command_palette.rename_input.selection`
- `debug.command_palette.rename_tab.open`
- `debug.command_palette.results`
- `debug.command_palette.selection`
- `debug.command_palette.toggle`
- `debug.command_palette.visible`
- `debug.empty_panel.count`
- `debug.empty_panel.reset`
- `debug.flash.count`
- `debug.flash.reset`
- `debug.layout`
- `debug.notification.focus`
- `debug.panel_snapshot`
- `debug.panel_snapshot.reset`
- `debug.portal.stats`
- `debug.session.round_trip`
- `debug.session.round_trip_workspaces`
- `debug.session.save_and_load`
- `debug.shortcut.set`
- `debug.shortcut.simulate`
- `debug.sidebar.visible`
- `debug.terminal.is_focused`
- `debug.terminal.read_text`
- `debug.terminal.render_stats`
- `debug.terminals`
- `debug.type`
- `debug.window.screenshot`

