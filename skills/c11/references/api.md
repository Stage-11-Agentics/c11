# c11 API Reference

Full command surface for c11. The main `SKILL.md` covers what you reach for most often; this file is the fallback when you need something outside the core path. The binary is `cmux`.

## Contents

- [Addressing & targeting](#addressing--targeting)
- [Environment variables](#environment-variables)
- [Discovery & state](#discovery--state)
- [Workspaces, panes, surfaces](#workspaces-panes-surfaces)
- [Surface initialization quirk](#surface-initialization-quirk)
- [Reading & sending](#reading--sending)
- [Per-surface metadata](#per-surface-metadata)
- [Agent declaration](#agent-declaration)
- [Title & description](#title--description)
- [Sidebar reporting](#sidebar-reporting)
- [Spatial layout (`cmux tree`)](#spatial-layout-cmux-tree)
- [Notifications](#notifications)
- [Installation (`cmux install`)](#installation-cmux-install)
- [Troubleshooting](#troubleshooting)

## Addressing & targeting

Commands accept UUIDs, short refs, or indexes:

```
window:1   workspace:1   pane:2   surface:3   tab:1
```

**`--workspace` AND `--surface` must be used together** when targeting a remote surface. Either flag alone fails or targets the wrong thing.

```bash
# WRONG
cmux send --surface surface:5 "npm test"
cmux read-screen --surface surface:3 --lines 50

# RIGHT
cmux send --workspace workspace:2 --surface surface:5 "npm test"
cmux read-screen --workspace workspace:2 --surface surface:3 --lines 50
```

Most commands default to the caller's context via env vars — no flags needed when targeting your own surface.

## Environment variables

| Var | Purpose |
|-----|---------|
| `CMUX_WORKSPACE_ID` | Auto-set in c11 terminals; default for `--workspace` |
| `CMUX_SURFACE_ID` | Auto-set; default for `--surface` |
| `CMUX_TAB_ID` | Optional alias for tab commands |
| `CMUX_SOCKET_PATH` | Override socket path (default `/tmp/cmux.sock`; auto-discovers tagged/debug sockets) |
| `CMUX_SOCKET_PASSWORD` | Socket auth password (if set in Settings) |
| `CMUX_SHELL_INTEGRATION` | Set to `1` in c11 terminals — use to detect you're inside c11 |
| `CMUX_AGENT_TYPE` | Declared agent TUI type (`claude-code`, `codex`, `kimi`, `opencode`, kebab-case custom); read at surface start |
| `CMUX_AGENT_MODEL` | Declared agent model identifier |
| `CMUX_AGENT_TASK` | Declared agent task ID |

## Discovery & state

```bash
cmux identify                        # JSON: caller's workspace/surface/pane refs + focused context
cmux tree                            # Current workspace with ASCII floor plan (default)
cmux tree --window                   # All workspaces in current window (pre-M8 default)
cmux tree --all                      # Every window
cmux tree --json                     # Structured JSON with pixel/percent coordinates
cmux list-workspaces                 # Workspace list (* = selected)
cmux list-panes                      # Panes in current workspace (* = focused)
cmux list-pane-surfaces              # Surfaces in current pane
cmux current-workspace               # Current workspace ref
cmux sidebar-state                   # Sidebar metadata: git branch, ports, status, progress, logs
cmux capabilities                    # JSON: all available socket API methods
cmux version                         # Version string
```

The `caller` block in `cmux identify` always reflects the pane invoking the command; the `focused` block reflects whatever the user (or last `focus-pane`) is looking at. They are frequently different.

## Workspaces, panes, surfaces

```bash
# Create
cmux <path>                          # Open directory in new workspace (launches c11 if needed)
cmux new-workspace [--cwd <path>] [--command <text>]
cmux new-split <left|right|up|down>  # Split any pane; the new pane is always a terminal
cmux new-pane [--type <terminal|browser|markdown>] [--direction <dir>] [--url <url>]
cmux new-surface [--type <terminal|browser|markdown>] [--pane <id|ref>] [--workspace <id|ref>]

# Navigate
cmux select-workspace --workspace <id|ref>
cmux focus-pane --pane <id|ref>
cmux rename-workspace <title>
cmux rename-tab [--workspace <id|ref>] [--surface <id|ref>] <title>

# Close
cmux close-surface [--surface <id|ref>]     # Close a surface (defaults to caller's)
cmux close-workspace --workspace <id|ref>   # Close entire workspace
```

### `new-split` vs `new-pane` vs `new-surface`

- **`new-split`** — creates a new **pane** by splitting an existing one. Always terminal.
- **`new-pane`** — creates a new pane with more options (supports `--type browser|markdown`, `--url`).
- **`new-surface`** — creates a new **tab** (surface) inside an existing pane. Use this to add tabs to a pane that already exists — essential for orchestration (create one pane, then add agent tabs).

### `new-split` targeting

`new-split` defaults to the **caller's** pane, not the focused pane. To split a different pane, pass `--surface`:

```bash
# WRONG — splits the caller's pane regardless of focus
cmux focus-pane --pane pane:5
cmux new-split down

# RIGHT — splits the pane containing surface:10
cmux new-split down --surface surface:10
```

### `new-surface` targeting (gotcha — opposite of `new-split`)

`new-surface` does **not** default to the caller's pane. With no `--pane`, it adds the tab to whichever pane is currently *focused* — often **not** the pane your agent is running in. To add a tab to your own pane, read `caller.pane_ref` from `cmux identify` and pass it:

```bash
CALLER_PANE=$(cmux identify --surface "$CMUX_SURFACE_ID" | grep -o '"pane_ref" : "pane:[0-9]*"' | head -1 | cut -d'"' -f4)
cmux new-surface --type terminal --pane "$CALLER_PANE"
```

## Surface initialization quirk

Ghostty surfaces are lazily initialized — no PTY until they have non-zero screen bounds. Surfaces created in a non-visible workspace are inert until shown.

Workaround: after creating in a hidden workspace, select it briefly so SwiftUI runs the layout pass:

```bash
cmux select-workspace --workspace workspace:N
sleep 2
# now the surface has real bounds and accepts input
```

## Reading & sending

```bash
# Read terminal content
cmux read-screen [--lines <n>] [--scrollback]
cmux read-screen --workspace workspace:2 --surface surface:3 --lines 50

# Send text to a terminal
cmux send "echo hello"               # Types text — does NOT submit
cmux send "npm test\n"               # \n sends Enter, \r also sends Enter, \t sends Tab
cmux send-key enter                  # Send a keypress directly
cmux send --workspace workspace:2 --surface surface:3 "ls\n"
```

**`cmux send` does NOT auto-submit.** Include `\n` or call `cmux send-key enter` separately.

**`\n` gotcha from Claude Code's Bash tool:** the newline is stripped before reaching c11. Always send the text, then `send-key enter` as two separate calls:

```bash
cmux send --workspace $WS --surface $SURF "your command"
cmux send-key --workspace $WS --surface $SURF enter
```

## Per-surface metadata

Each surface carries an open-ended JSON metadata blob. See [metadata.md](metadata.md) for the full socket API, precedence rules, and canonical key table. Common commands:

```bash
cmux set-metadata --json '{"role":"reviewer","task":"lat-412"}'
cmux set-metadata --key status --value "running"
cmux set-metadata --key progress --value 0.6 --type number
cmux get-metadata
cmux get-metadata --key role --sources
cmux clear-metadata --key task
```

## Agent declaration

```bash
cmux set-agent --type claude-code --model claude-opus-4-7
cmux set-agent --type codex --task lat-412
cmux set-agent --type opencode --model <model-id>
```

- `--type` accepts canonical values (`claude-code`, `codex`, `kimi`, `opencode`) and any kebab-case custom value.
- Writes land as `source: declare` in the M2 metadata store, overriding heuristic auto-detection but not user-explicit writes.
- Environment declaration: `CMUX_AGENT_TYPE`, `CMUX_AGENT_MODEL`, `CMUX_AGENT_TASK` in the surface's startup env are read once at surface-child-process start.
- Clear with `cmux clear-metadata --key terminal_type` (no `cmux unset-agent`).

## Title & description

Sugar over metadata writes to the canonical `title` and `description` keys. Rendered in the surface's title bar (M7).

```bash
cmux set-title "SIG Delegator — reviewing PR #42"
cmux set-title --from-file /tmp/title.txt
cmux set-description "Running smoke suite across 10 shards; reports to Lattice task lat-412."
cmux set-description --from-file /tmp/desc.md
```

`cmux rename-tab` is an alias for `cmux set-title` on the target surface. The sidebar tab label is a truncated projection of the title.

## Sidebar reporting

Sidebar metadata commands are the fast path for reactive pills — separate from the per-surface JSON blob.

```bash
cmux set-status <key> <value> [--icon <name>] [--color <#hex>]
cmux clear-status <key>
cmux list-status
cmux set-progress <0.0-1.0> [--label <text>]
cmux clear-progress
cmux log [--level <level>] [--source <name>] <message>
cmux list-log [--limit <n>]
cmux clear-log
```

**Constraint:** these must be called from a direct c11 child process. Subprocesses spawned by `claude -p` get reparented to `launchd`, breaking the auth chain. Interactive `cc` keeps it intact.

## Spatial layout (`cmux tree`)

```bash
cmux tree                            # Default: current workspace, ASCII floor plan + hierarchy
cmux tree --window                   # All workspaces in current window
cmux tree --all                      # Every window, every workspace
cmux tree --workspace workspace:3    # Single workspace
cmux tree --layout                   # Force floor plan even for multi-workspace scope
cmux tree --no-layout                # Suppress floor plan
cmux tree --canvas-cols 100          # Override floor plan canvas width
cmux tree --json                     # Structured JSON (pixel + percent coords, split paths, content area)
```

Every pane's JSON output includes: `pixel_rect`, `percent_rect`, `h_range` / `v_range` (both pixel and percent), `split_path` (a non-persistent ordered list of `H:left | H:right | V:top | V:bottom`), and the workspace `content_area` dimensions. Use `split_path` for current-layout reasoning only; use `pane:<n>` / pane UUID for stable references across layout mutations.

## Notifications

```bash
cmux notify --title <text> [--subtitle <text>] [--body <text>]
cmux list-notifications
cmux clear-notifications
cmux trigger-flash [--surface <id|ref>]    # Visual flash on a surface
```

Also responds to standard terminal escape sequences: OSC 9, OSC 99, OSC 777.

## Installation (`cmux install`)

`cmux install <tui>` wires c11's notification shims and agent-declaration calls into a TUI's configuration. Human-run, consent-gated, reversible.

```bash
cmux install claude-code             # Writes hooks into ~/.claude/settings.json
cmux install codex                   # Installs a PATH shim at ~/.local/bin/cmux-shims/codex
cmux install opencode
cmux install kimi
cmux install --list                  # State of all four TUIs
cmux install --status claude-code    # Detailed status for one TUI
cmux install claude-code --dry-run   # Show diff without writing
cmux uninstall claude-code           # Reverses install byte-for-byte
```

Consent is always requested before any write. The installer also installs the c11 skill bundle into `~/.claude/skills/` so agents using that TUI learn the c11 vocabulary.

## Troubleshooting

- **"Connection refused" / socket errors** — c11 app may not be running. Launch it, then retry.
- **"Surface not found"** — target surface was closed or the ref is stale. Run `cmux tree --all` for current refs.
- **"Surface is not a terminal"** — you used `--surface` without `--workspace`. Always pass both when targeting remote surfaces.
- **Browser commands fail with "not a browser"** — you're targeting a terminal surface. Find the browser surface ref with `cmux tree` and pass `--surface <ref>`.
- **Commands do nothing** — check `CMUX_SOCKET_PATH` matches the running instance. Default is `/tmp/cmux.sock`; tagged debug builds use `/tmp/cmux-debug-<tag>.sock`.
- **Surface doesn't respond after creation** — it may not be initialized. Run `cmux select-workspace --workspace workspace:N && sleep 2` to trigger the layout pass.
- **Sub-agent can't call `cmux`** — happens with `claude -p` (headless). Interactive `cc` launched via `cmux send "cc\n"` + `send-key enter` maintains the auth chain.
- **Metadata write returns `applied: false` with `lower_precedence`** — a higher-precedence source already owns that key. See [metadata.md](metadata.md) precedence table.

## Notes

- c11 is a **local** multiplexer — not a remote session manager. For SSH work, install tmux on the remote.
- Socket access modes: disabled, c11-spawned processes only (`cmuxOnly`), or all local processes. Check with `cmux capabilities`.
