# c11 API Reference

Full command surface for c11. The main `SKILL.md` covers what you reach for most often; this file is the fallback when you need something outside the core path. The binary is `c11`.

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
- [Spatial layout (`c11 tree`)](#spatial-layout-c11-tree)
- [Notifications](#notifications)
- [Installation (`c11 install`)](#installation-c11-install)
- [Troubleshooting](#troubleshooting)

## Addressing & targeting

Commands accept UUIDs, short refs, or indexes:

```
window:1   workspace:1   pane:2   surface:3   tab:1
```

**`--workspace` AND `--surface` must be used together** when targeting a remote surface. Either flag alone fails or targets the wrong thing.

```bash
# WRONG
c11 send --surface surface:5 "npm test"
c11 read-screen --surface surface:3 --lines 50

# RIGHT
c11 send --workspace workspace:2 --surface surface:5 "npm test"
c11 read-screen --workspace workspace:2 --surface surface:3 --lines 50
```

Most commands default to the caller's context via env vars — no flags needed when targeting your own surface.

## Environment variables

`C11_*` variants are the primary names going forward; the legacy `CMUX_*` names continue to work via dual-read. The table below lists the legacy names because they're still what you'll see exported in most environments today.

| Var | Purpose |
|-----|---------|
| `CMUX_WORKSPACE_ID` | Auto-set in c11 terminals; default for `--workspace` |
| `CMUX_SURFACE_ID` | Auto-set; default for `--surface` |
| `CMUX_TAB_ID` | Optional alias for tab commands |
| `CMUX_SOCKET_PATH` | Override socket path (default `/tmp/cmux.sock`; auto-discovers tagged/debug sockets) |
| `CMUX_SOCKET_PASSWORD` | Socket auth password (if set in Settings) |
| `CMUX_SHELL_INTEGRATION` | Set to `1` in c11 terminals — use to detect you're inside c11 (also exported as `C11_SHELL_INTEGRATION=1`) |
| `CMUX_AGENT_TYPE` | Declared agent TUI type (`claude-code`, `codex`, `kimi`, `opencode`, kebab-case custom); read at surface start |
| `CMUX_AGENT_MODEL` | Declared agent model identifier |
| `CMUX_AGENT_TASK` | Declared agent task ID |

## Discovery & state

```bash
c11 identify                         # JSON: caller's workspace/surface/pane refs + focused context
c11 tree                             # Current workspace with ASCII floor plan (default)
c11 tree --window                    # All workspaces in current window (pre-M8 default)
c11 tree --all                       # Every window
c11 tree --json                      # Structured JSON with pixel/percent coordinates
c11 list-workspaces                  # Workspace list (* = selected)
c11 list-panes                       # Panes in current workspace (* = focused)
c11 list-pane-surfaces               # Surfaces in current pane
c11 current-workspace                # Current workspace ref
c11 sidebar-state                    # Sidebar metadata: git branch, ports, status, progress, logs
c11 capabilities                     # JSON: all available socket API methods
c11 version                          # Version string
```

The `caller` block in `c11 identify` always reflects the pane invoking the command; the `focused` block reflects whatever the user (or last `focus-pane`) is looking at. They are frequently different.

## Workspaces, panes, surfaces

```bash
# Create
c11 <path>                           # Open directory in new workspace (launches c11 if needed)
c11 new-workspace [--cwd <path>] [--command <text>]
c11 new-split <left|right|up|down>   # Split any pane; the new pane is always a terminal
c11 new-pane [--type <terminal|browser|markdown>] [--direction <dir>] [--url <url>]
c11 new-surface [--type <terminal|browser|markdown>] [--pane <id|ref>] [--workspace <id|ref>]

# Navigate
c11 select-workspace --workspace <id|ref>
c11 focus-pane --pane <id|ref>
c11 rename-workspace <title>
c11 rename-tab [--workspace <id|ref>] [--surface <id|ref>] <title>

# Close
c11 close-surface [--surface <id|ref>]      # Close a surface (defaults to caller's)
c11 close-workspace --workspace <id|ref>    # Close entire workspace
```

### `new-split` vs `new-pane` vs `new-surface`

- **`new-split`** — creates a new **pane** by splitting an existing one. Always terminal.
- **`new-pane`** — creates a new pane with more options (supports `--type browser|markdown`, `--url`).
- **`new-surface`** — creates a new **tab** (surface) inside an existing pane. Use this to add tabs to a pane that already exists — essential for orchestration (create one pane, then add agent tabs).

### `new-split` targeting

`new-split` defaults to the **caller's** pane, not the focused pane. To split a different pane, pass `--surface`:

```bash
# WRONG — splits the caller's pane regardless of focus
c11 focus-pane --pane pane:5
c11 new-split down

# RIGHT — splits the pane containing surface:10
c11 new-split down --surface surface:10
```

### `new-surface` targeting (gotcha — opposite of `new-split`)

`new-surface` does **not** default to the caller's pane. With no `--pane`, it adds the tab to whichever pane is currently *focused* — often **not** the pane your agent is running in. To add a tab to your own pane, read `caller.pane_ref` from `c11 identify` and pass it:

```bash
CALLER_PANE=$(c11 identify --surface "$CMUX_SURFACE_ID" | grep -o '"pane_ref" : "pane:[0-9]*"' | head -1 | cut -d'"' -f4)
c11 new-surface --type terminal --pane "$CALLER_PANE"
```

## Surface initialization quirk

Ghostty surfaces are lazily initialized — no PTY until they have non-zero screen bounds. Surfaces created in a non-visible workspace are inert until shown.

Workaround: after creating in a hidden workspace, select it briefly so SwiftUI runs the layout pass:

```bash
c11 select-workspace --workspace workspace:N
sleep 2
# now the surface has real bounds and accepts input
```

## Reading & sending

```bash
# Read terminal content
c11 read-screen [--lines <n>] [--scrollback]
c11 read-screen --workspace workspace:2 --surface surface:3 --lines 50

# Send text to a terminal
c11 send "echo hello"                # Types text — does NOT submit
c11 send "npm test\n"                # \n sends Enter, \r also sends Enter, \t sends Tab
c11 send-key enter                   # Send a keypress directly
c11 send --workspace workspace:2 --surface surface:3 "ls\n"
```

**`c11 send` does NOT auto-submit.** Include `\n` or call `c11 send-key enter` separately.

**`\n` gotcha from Claude Code's Bash tool:** the newline is stripped before reaching c11. Always send the text, then `send-key enter` as two separate calls:

```bash
c11 send --workspace $WS --surface $SURF "your command"
c11 send-key --workspace $WS --surface $SURF enter
```

## Per-surface metadata

Each surface carries an open-ended JSON metadata blob. See [metadata.md](metadata.md) for the full socket API, precedence rules, and canonical key table. Common commands:

```bash
c11 set-metadata --json '{"role":"reviewer","task":"lat-412"}'
c11 set-metadata --key status --value "running"
c11 set-metadata --key progress --value 0.6 --type number
c11 get-metadata
c11 get-metadata --key role --sources
c11 clear-metadata --key task
```

## Agent declaration

```bash
c11 set-agent --type claude-code --model claude-opus-4-7
c11 set-agent --type codex --task lat-412
c11 set-agent --type opencode --model <model-id>
```

- `--type` accepts canonical values (`claude-code`, `codex`, `kimi`, `opencode`) and any kebab-case custom value.
- Writes land as `source: declare` in the M2 metadata store, overriding heuristic auto-detection but not user-explicit writes.
- Environment declaration: `CMUX_AGENT_TYPE`, `CMUX_AGENT_MODEL`, `CMUX_AGENT_TASK` in the surface's startup env are read once at surface-child-process start. `C11_*` variants are the primary names going forward; `CMUX_*` still works.
- Clear with `c11 clear-metadata --key terminal_type` (no `c11 unset-agent`).

## Title & description

Sugar over metadata writes to the canonical `title` and `description` keys. Rendered in the surface's title bar (M7).

```bash
c11 set-title "SIG Delegator — reviewing PR #42"
c11 set-title --from-file /tmp/title.txt
c11 set-description "Running smoke suite across 10 shards; reports to Lattice task lat-412."
c11 set-description --from-file /tmp/desc.md
```

`c11 rename-tab` is an alias for `c11 set-title` on the target surface. The sidebar tab label is a truncated projection of the title.

## Sidebar reporting

Sidebar metadata commands are the fast path for reactive pills — separate from the per-surface JSON blob.

```bash
c11 set-status <key> <value> [--icon <name>] [--color <#hex>]
c11 clear-status <key>
c11 list-status
c11 set-progress <0.0-1.0> [--label <text>]
c11 clear-progress
c11 log [--level <level>] [--source <name>] <message>
c11 list-log [--limit <n>]
c11 clear-log
```

**Constraint:** these must be called from a direct c11 child process. Subprocesses spawned by `claude -p` get reparented to `launchd`, breaking the auth chain. Interactive `claude --dangerously-skip-permissions` keeps it intact.

## Spatial layout (`c11 tree`)

```bash
c11 tree                             # Default: current workspace, ASCII floor plan + hierarchy
c11 tree --window                    # All workspaces in current window
c11 tree --all                       # Every window, every workspace
c11 tree --workspace workspace:3     # Single workspace
c11 tree --layout                    # Force floor plan even for multi-workspace scope
c11 tree --no-layout                 # Suppress floor plan
c11 tree --canvas-cols 100           # Override floor plan canvas width
c11 tree --json                      # Structured JSON (pixel + percent coords, split paths, content area)
```

Every pane's JSON output includes: `pixel_rect`, `percent_rect`, `h_range` / `v_range` (both pixel and percent), `split_path` (a non-persistent ordered list of `H:left | H:right | V:top | V:bottom`), and the workspace `content_area` dimensions. Use `split_path` for current-layout reasoning only; use `pane:<n>` / pane UUID for stable references across layout mutations.

## Notifications

```bash
c11 notify --title <text> [--subtitle <text>] [--body <text>]
c11 list-notifications
c11 clear-notifications
c11 trigger-flash [--surface <id|ref>]     # Visual flash on a surface
```

Also responds to standard terminal escape sequences: OSC 9, OSC 99, OSC 777.

## Installation (`c11 install`)

`c11 install <tui>` wires c11's notification shims and agent-declaration calls into a TUI's configuration. Human-run, consent-gated, reversible.

```bash
c11 install claude-code              # Writes hooks into ~/.claude/settings.json
c11 install codex                    # Installs a PATH shim at ~/.local/bin/cmux-shims/codex
c11 install opencode
c11 install kimi
c11 install --list                   # State of all four TUIs
c11 install --status claude-code     # Detailed status for one TUI
c11 install claude-code --dry-run    # Show diff without writing
c11 uninstall claude-code            # Reverses install byte-for-byte
```

Consent is always requested before any write. The installer also installs the c11 skill bundle into `~/.claude/skills/` so agents using that TUI learn the c11 vocabulary.

## Troubleshooting

- **"Connection refused" / socket errors** — c11 app may not be running. Launch it, then retry.
- **"Surface not found"** — target surface was closed or the ref is stale. Run `c11 tree --all` for current refs.
- **"Surface is not a terminal"** — you used `--surface` without `--workspace`. Always pass both when targeting remote surfaces.
- **Browser commands fail with "not a browser"** — you're targeting a terminal surface. Find the browser surface ref with `c11 tree` and pass `--surface <ref>`.
- **Commands do nothing** — check `CMUX_SOCKET_PATH` matches the running instance. Default is `/tmp/cmux.sock`; tagged debug builds use `/tmp/cmux-debug-<tag>.sock`. (`C11_SOCKET_PATH` is the primary name going forward; `CMUX_SOCKET_PATH` still works.)
- **Surface doesn't respond after creation** — it may not be initialized. Run `c11 select-workspace --workspace workspace:N && sleep 2` to trigger the layout pass.
- **Sub-agent can't call `c11`** — happens with `claude -p` (headless). Interactive `claude --dangerously-skip-permissions` launched via `c11 send "claude --dangerously-skip-permissions\n"` + `send-key enter` maintains the auth chain.
- **Metadata write returns `applied: false` with `lower_precedence`** — a higher-precedence source already owns that key. See [metadata.md](metadata.md) precedence table.

## Notes

- c11 is a **local** multiplexer — not a remote session manager. For SSH work, install tmux on the remote.
- Socket access modes: disabled, c11-spawned processes only (`cmuxOnly`), or all local processes. Check with `c11 capabilities`.
