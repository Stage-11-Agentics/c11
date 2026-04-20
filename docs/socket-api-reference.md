# cmux Socket API Reference

JSON-RPC API over Unix domain socket for programmatic control of cmux.

**Source:** https://cmux.com/docs/api

## Socket Configuration

| Build Type | Path |
|------------|------|
| Release | `/tmp/cmux.sock` |
| Debug | `/tmp/cmux-debug.sock` |
| Tagged debug | `/tmp/cmux-debug-<tag>.sock` |

Override with `CMUX_SOCKET_PATH` env var.

## Protocol

Newline-terminated JSON. Every request has `id`, `method`, `params`. Every response has `id`, `ok`, `result`.

```json
// Request
{"id":"req-1","method":"workspace.list","params":{}}

// Response
{"id":"req-1","ok":true,"result":{"workspaces":[...]}}
```

## Access Modes

| Mode | Description | How to Enable |
|------|-------------|---------------|
| **Off** | Socket disabled | Settings UI or `CMUX_SOCKET_MODE=off` |
| **cmux processes only** | Only cmux-spawned processes | Default |
| **allowAll** | Any local process | `CMUX_SOCKET_MODE=allowAll` |

Legacy values `"full"` and `"notifications"` still accepted.

## CLI Flags

| Flag | Description |
|------|-------------|
| `--socket PATH` | Custom socket path |
| `--json` | JSON output |
| `--window ID` | Target window |
| `--workspace ID` | Target workspace |
| `--surface ID` | Target surface |
| `--id-format refs\|uuids\|both` | Identifier format in JSON output |

## API Methods

### System

| Method | CLI | Description |
|--------|-----|-------------|
| `system.ping` | `cmux ping` | Health check — returns `{"pong":true}` |
| `system.capabilities` | `cmux capabilities` | Lists available methods and access mode |
| `system.identify` | `cmux identify` | Returns focused window/workspace/pane/surface context |

```json
{"id":"ping","method":"system.ping","params":{}}
// → {"id":"ping","ok":true,"result":{"pong":true}}
```

### Workspaces

| Method | CLI | Description |
|--------|-----|-------------|
| `workspace.list` | `cmux list-workspaces` | List all workspaces |
| `workspace.create` | `cmux new-workspace` | Create new workspace |
| `workspace.select` | `cmux select-workspace --workspace <id>` | Switch to workspace |
| `workspace.current` | `cmux current-workspace` | Get active workspace |
| `workspace.close` | `cmux close-workspace --workspace <id>` | Close workspace |

```json
{"id":"ws-select","method":"workspace.select","params":{"workspace_id":"<id>"}}
```

### Surfaces & Splits

| Method | CLI | Description |
|--------|-----|-------------|
| `surface.split` | `cmux new-split <direction>` | Split pane (left/right/up/down) |
| `surface.list` | `cmux list-surfaces` | List surfaces in workspace |
| `surface.focus` | `cmux focus-surface --surface <id>` | Focus a surface |

```json
{"id":"split","method":"surface.split","params":{"direction":"right"}}
```

Panel IDs (also called surface IDs) are stable across app restarts within the
same machine. External consumers may cache them across sessions. Set
`CMUX_DISABLE_STABLE_PANEL_IDS=1` in the app's environment to revert to
per-restart UUID regeneration (one-release rollback safety net; will be removed
in a followup release).

Workspace IDs are also stable across app restarts within the same machine.
External consumers may cache `(workspace_id, surface_id)` tuples across
sessions. Set `CMUX_DISABLE_STABLE_WORKSPACE_IDS=1` in the app's launch
environment (via `launchctl setenv` or the parent shell before launching the
app — setting it on the `cmux` CLI invocation has no effect) to revert to
per-restart UUID regeneration. One-release rollback safety net; will be removed
in a followup release.

### Input

| Method | CLI | Description |
|--------|-----|-------------|
| `surface.send_text` | `cmux send "text"` | Send text to focused terminal |
| `surface.send_key` | `cmux send-key <key>` | Send keypress (enter/tab/escape/backspace/delete/up/down/left/right) |
| `surface.send_text` | `cmux send-surface --surface <id> "text"` | Send text to specific surface |
| `surface.send_key` | `cmux send-key-surface --surface <id> <key>` | Send key to specific surface |

```json
// Send to focused
{"id":"s1","method":"surface.send_text","params":{"text":"echo hello\n"}}

// Send to specific surface
{"id":"s2","method":"surface.send_text","params":{"surface_id":"<id>","text":"command"}}

// Send key to specific surface
{"id":"s3","method":"surface.send_key","params":{"surface_id":"<id>","key":"enter"}}
```

### Notifications

| Method | CLI | Description |
|--------|-----|-------------|
| `notification.create` | `cmux notify --title "T" --body "B"` | Create notification |
| `notification.list` | `cmux list-notifications` | List notifications |
| `notification.clear` | `cmux clear-notifications` | Clear all notifications |

```json
{"id":"n1","method":"notification.create","params":{"title":"Title","subtitle":"S","body":"Body"}}
```

### Sidebar Metadata

Status pills, progress bars, and log entries in the workspace sidebar.

**Status:**

| CLI | Socket | Description |
|-----|--------|-------------|
| `cmux set-status <key> <value> [--icon <name>] [--color <hex>]` | `set_status <key> <value> --icon=<name> --color=<hex> --tab=<uuid>` | Set status pill |
| `cmux clear-status <key>` | `clear_status <key> --tab=<uuid>` | Remove status entry |
| `cmux list-status` | `list_status --tab=<uuid>` | List status entries |

**Progress:**

| CLI | Socket | Description |
|-----|--------|-------------|
| `cmux set-progress <0.0-1.0> [--label "text"]` | `set_progress <val> --label=<text> --tab=<uuid>` | Set progress bar |
| `cmux clear-progress` | `clear_progress --tab=<uuid>` | Clear progress bar |

**Logs:**

| CLI | Socket | Description |
|-----|--------|-------------|
| `cmux log [--level <level>] [--source <name>] <msg>` | `log --level=<level> --source=<name> --tab=<uuid> -- <msg>` | Append log entry |
| `cmux list-log [--limit <n>]` | `list_log --limit=<n> --tab=<uuid>` | List log entries |
| `cmux clear-log` | `clear_log --tab=<uuid>` | Clear log entries |
| `cmux sidebar-state` | `sidebar_state --tab=<uuid>` | Dump all sidebar metadata |

Log levels: `info`, `progress`, `success`, `warning`, `error`

### Surface Metadata Persistence (Tier 1 Phase 2)

Surface metadata written via `surface.set_metadata` and its heuristic/
OSC/declare counterparts persists across c11 restarts. On restore,
values are reinstalled into `SurfaceMetadataStore` with their original
source and timestamp, preserving the `explicit > declare > osc >
heuristic` precedence chain. A `.heuristic` value from the snapshot
survives at `.heuristic` even if the newly-initialized surface wrote
something at `.declare` first — the snapshot wins.

Coercibility: values that cannot be represented as JSON (custom
classes, `Date`, `URL`, `NaN`/`+Inf`/`-Inf`) are dropped on persist
with a DEBUG-only log line and never crash the snapshot write; the
rest of the blob survives. Numbers round-trip as double-precision
floats — callers needing integer fidelity should convert explicitly
after reading.

**Rollback:** set `CMUX_DISABLE_METADATA_PERSIST=1` in the app's launch
environment (e.g. `launchctl setenv CMUX_DISABLE_METADATA_PERSIST 1`
then relaunch, or export it in the parent shell that launches the
`.app`). When set, snapshot writes emit `null` for both `metadata`
and `metadataSources` and restore ignores any persisted values. The
variable is **app-launch-scope only** — setting it on a `cmux` CLI
invocation has no effect, because the CLI is a separate process from
the running app.

### Themes (CMUX-35)

Chrome-theme lifecycle lives under the `theme.*` method family. Read-only
methods are safe to call unauthenticated; mutating methods are gated by
the normal socket auth chain.

| CLI | Method | Description |
| --- | ------ | ----------- |
| `cmux ui themes list` | `theme.list` | Enumerate built-in + user themes with active-slot flags and load warnings. |
| `cmux ui themes get [--slot light\|dark]` | `theme.get` | Read the active theme for one or both slots. |
| `cmux ui themes set <name> [--slot ...]` | `theme.set_active` | Set active theme. `slot` defaults to `both`; `light`/`dark` narrow it. |
| `cmux ui themes clear` | `theme.clear_active` | Clear `theme.active.light` and `theme.active.dark` back to defaults. |
| `cmux ui themes reload` | `theme.reload` | Manually re-scan the user themes directory. |
| `cmux ui themes path` | `theme.paths` | Print the user and bundled themes directories. |
| `cmux ui themes dump --json` | `theme.dump` | Resolved snapshot for the active theme, JSON schema per plan §10. |
| `cmux ui themes validate <path>` | `theme.validate` | Parse-only validation of a theme file; non-zero exit on failure. |
| `cmux ui themes diff <a> <b>` | `theme.diff` | Role-level diff between two themes (by name or path). |
| `cmux ui themes inherit <parent> --as <name>` | `theme.inherit` | Canonicalize a parent theme into a new user file. |

Per-workspace custom color:

| CLI | Method | Description |
| --- | ------ | ----------- |
| `cmux workspace-color set <hex> [--workspace <ref>]` | `workspace.set_custom_color` | Set workspace color. `<ref>` accepts UUID, `workspace:N`, 1-based index, `@current`/`@focused`. |
| `cmux workspace-color clear [--workspace <ref>]` | `workspace.set_custom_color` (with `clear=true`) | Reset to palette default. |
| `cmux workspace-color get [--workspace <ref>]` | `workspace.list` | Read current custom color via workspace list. |
| `cmux workspace-color list-palette` | — | Print built-in palette entries (client-side list). |

Focus policy: all `theme.*` handlers run off-main (parsing / validation /
diffing) and touch the main actor only for the minimal state update that
publishes a new `ResolvedThemeSnapshot`. None of these methods steal
macOS focus or raise the app.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `CMUX_SOCKET_PATH` | Override socket path |
| `CMUX_SOCKET_ENABLE` | Force enable/disable socket (`1`/`0`, `true`/`false`, `on`/`off`) |
| `CMUX_SOCKET_MODE` | Override access mode (`cmuxOnly`, `allowAll`, `off`) |
| `CMUX_WORKSPACE_ID` | Auto-set: current workspace ID |
| `CMUX_SURFACE_ID` | Auto-set: current surface ID |
| `CMUX_DISABLE_METADATA_PERSIST` | App-launch-scope rollback: `1` skips persist on write and ignores on restore. See Surface Metadata Persistence above. |
| `TERM_PROGRAM` | Set to `ghostty` |
| `TERM` | Set to `xterm-ghostty` |

## Detecting cmux

```bash
# Socket available?
SOCK="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
[ -S "$SOCK" ] && echo "Socket available"

# CLI available?
command -v cmux &>/dev/null && echo "cmux available"

# Inside a cmux surface?
[ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -n "${CMUX_SURFACE_ID:-}" ] && echo "Inside cmux"

# Distinguish from regular Ghostty
[ "$TERM_PROGRAM" = "ghostty" ] && [ -n "${CMUX_WORKSPACE_ID:-}" ] && echo "In cmux (not plain Ghostty)"
```

## Code Examples

### Python Client

```python
import json, os, socket

SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux.sock")

def rpc(method, params=None, req_id=1):
    payload = {"id": req_id, "method": method, "params": params or {}}
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(payload).encode("utf-8") + b"\n")
        return json.loads(sock.recv(65536).decode("utf-8"))

# List workspaces
print(rpc("workspace.list", req_id="ws"))

# Send notification
print(rpc("notification.create", {"title": "Hello", "body": "From Python!"}, req_id="notify"))
```

### Shell Script

```bash
#!/bin/bash
SOCK="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"

cmux_rpc() {
    printf "%s\n" "$1" | nc -U "$SOCK"
}

cmux_rpc '{"id":"ws","method":"workspace.list","params":{}}'
cmux_rpc '{"id":"notify","method":"notification.create","params":{"title":"Done","body":"Task complete"}}'
```

### Build Script with Notification

```bash
#!/bin/bash
npm run build
if [ $? -eq 0 ]; then
    cmux notify --title "Build Success" --body "Ready to deploy"
else
    cmux notify --title "Build Failed" --body "Check the logs"
fi
```
