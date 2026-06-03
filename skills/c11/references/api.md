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

Auto-exported into every c11 surface child process.

| Var | Purpose |
|-----|---------|
| `C11_WORKSPACE_ID` | Auto-set in c11 terminals; default for `--workspace` |
| `C11_SURFACE_ID` | Auto-set; default for `--surface` |
| `C11_TAB_ID` | Optional alias for tab commands |
| `C11_SOCKET_PATH` | Override socket path (auto-discovers tagged/debug sockets) |
| `C11_SOCKET_PASSWORD` | Socket auth password (if set in Settings) |
| `C11_SHELL_INTEGRATION` | Set to `1` in c11 terminals — use to detect you're inside c11 |
| `C11_AGENT_TYPE` | Declared agent TUI type (`claude-code`, `codex`, `kimi`, `opencode`, kebab-case custom); read at surface start |
| `C11_AGENT_MODEL` | Declared agent model identifier |
| `C11_AGENT_TASK` | Declared agent task ID |

## Discovery & state

```bash
c11 identify                         # JSON: caller's workspace/surface/pane refs + focused context
c11 tree                             # Current workspace with ASCII floor plan (default)
c11 tree --window                    # All workspaces in current window
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
c11 new-workspace [--cwd <path>] [--command <text>] [--title <text>] [--layout <path|name>]
c11 new-split <left|right|up|down> [--cwd <path|inherit>]   # Split any pane; the new pane is always a terminal
c11 new-pane [--type <terminal|browser|markdown>] [--direction <dir>] [--url <url>] [--cwd <path|inherit>]
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

### `--cwd` — set the new shell's working directory

`new-split` and `new-pane` spawn a terminal whose default working directory is inherited from the parent surface. Pass `--cwd <path>` to start the shell in a specific directory instead — set at creation, before the PTY is wired up, so the agent lands there with no `cd`:

```bash
c11 new-split right --cwd /Users/me/project   # new shell starts in /Users/me/project
c11 new-split down --cwd .                     # relative path, resolved against your cwd
c11 new-pane --cwd ~/code/api                  # tilde-expanded
```

- The path is resolved relative to where the CLI runs (so `--cwd .` is your current dir) and validated server-side: a nonexistent path or a file (not a directory) returns a clear error rather than silently falling back to `$HOME`.
- Omitting `--cwd` — or passing `--cwd inherit` — keeps the default: inherit the parent surface's cwd.
- Browser/markdown panes have no shell, so `--cwd` has no effect there (it's still validated if supplied).

This removes the orchestrator habit of prefixing every spawned command with `cd /path && …` just to keep a sub-agent out of `~`.

### `new-surface` targeting (gotcha — opposite of `new-split`)

`new-surface` does **not** default to the caller's pane. With no `--pane`, it adds the tab to whichever pane is currently *focused* — often **not** the pane your agent is running in. To add a tab to your own pane, read `caller.pane_ref` from `c11 identify` and pass it:

```bash
CALLER_PANE=$(c11 identify --surface "$C11_SURFACE_ID" | grep -o '"pane_ref" : "pane:[0-9]*"' | head -1 | cut -d'"' -f4)
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
c11 send "echo hello"                # Types text AND submits (default behavior)
c11 send --no-submit "cd /tmp/"      # Types text only, no Return — for partial-line construction
c11 send-key enter                   # Send a keypress directly (no text)
c11 send --workspace workspace:2 --surface surface:3 "ls"
```

**`c11 send` types the text and submits.** A synthetic Return is dispatched on the same turn as the text, so the receiving TUI sees one user turn. Pass `--no-submit` to type into the prompt without executing — typically to build a partial line across multiple sends, or to stage text before the operator hits Enter manually.

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
- Writes land as `source: declare` in the metadata store, overriding heuristic auto-detection but not user-explicit writes.
- Environment declaration: `C11_AGENT_TYPE`, `C11_AGENT_MODEL`, `C11_AGENT_TASK` in the surface's startup env are read once at surface-child-process start.
- Clear with `c11 clear-metadata --key terminal_type` (no `c11 unset-agent`).

## Title & description

Sugar over metadata writes to the canonical `title` and `description` keys. Rendered in the surface's title bar.

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
c11 install codex                    # Installs a PATH shim under ~/.local/bin/
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
- **Commands do nothing** — check `C11_SOCKET_PATH` matches the running instance. Tagged debug builds use a per-tag socket path; the CLI auto-discovers it when launched from a tagged surface.
- **Surface doesn't respond after creation** — it may not be initialized. Run `c11 select-workspace --workspace workspace:N && sleep 2` to trigger the layout pass.
- **Sub-agent can't call `c11`** — happens with `claude -p` (headless). Interactive `claude --dangerously-skip-permissions` launched via `c11 send "claude --dangerously-skip-permissions"` maintains the auth chain.
- **Metadata write returns `applied: false` with `lower_precedence`** — a higher-precedence source already owns that key. See [metadata.md](metadata.md) precedence table.

## Notes

- c11 is a **local** multiplexer — not a remote session manager. For SSH work, install tmux on the remote.
- Socket access modes: disabled, c11-spawned processes only (`c11Only`), or all local processes. Check with `c11 capabilities`.
