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

**Operator-spoken tab numbers are surface refs.** With the "Show Surface IDs in Tab Titles" setting on (Settings → Surfaces), every tab renders as `N: title` where N is its `surface:N` ordinal. When the operator says "send this to 292", target `surface:292` — never a bare `292`: to the CLI a bare integer is a *positional index* (the Nth surface in list order), which is a different surface. Your own number is `$C11_SURFACE_NUM`.

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
| `C11_SURFACE_NUM` | Integer N of this surface's `surface:N` ref — the number shown in the tab bar when surface-ID display is on. Address yourself as `surface:$C11_SURFACE_NUM` |
| `C11_TAB_ID` | Optional alias for tab commands |
| `C11_SOCKET_PATH` | Override socket path (auto-discovers tagged/debug sockets) |
| `C11_SOCKET_PASSWORD` | Socket auth password (if set in Settings) |
| `C11_SHELL_INTEGRATION` | Set to `1` in c11 terminals — use to detect you're inside c11 |
| `C11_AGENT_TYPE` | Declared agent TUI type (`claude-code`, `codex`, `grok`, `kimi`, `opencode`, `github-copilot`, `pi`, `omp`, kebab-case custom); read at surface start |
| `C11_AGENT_MODEL` | Declared agent model identifier |
| `C11_AGENT_TASK` | Declared agent task ID |

## Discovery & state

```bash
c11 identify                         # JSON: caller/focused refs + each workspace's root_directory
c11 tree                             # Current workspace with ASCII floor plan (default)
c11 tree --window                    # All workspaces in current window
c11 tree --all                       # Every window
c11 tree --json                      # Structured JSON with pixel/percent coordinates
c11 list-workspaces                  # Workspace list (* = selected); --json includes root_directory
c11 list-panes                       # Panes in current workspace (* = focused)
c11 list-pane-surfaces               # Surfaces in current pane
c11 current-workspace                # Current workspace ref
c11 sidebar-state                    # Sidebar metadata: git branch, ports, status, progress, logs
c11 capabilities                     # JSON: all available socket API methods
c11 version                          # Version string
```

The `caller` block in `c11 identify` always reflects the pane invoking the command; the `focused` block reflects whatever the user (or last `focus-pane`) is looking at. They are frequently different.

### There is no `c11 list` (silent-empty footgun)

Enumeration is **scoped** — there is no bare `list`. `c11 list` exits non-zero with `Error: Unknown
command: list` and dumps the usage banner.

```bash
# WRONG — not a command; prints usage to stderr and exits non-zero
c11 list
c11 list --json | grep "ACE-387"        # ← greps the ERROR TEXT, matches nothing, LOOKS like "no results"

# RIGHT — pick the scope you actually want
c11 tree --all                          # every window: workspaces → panes → surfaces, with titles
c11 tree --all --json                   # same, structured (parse this when scripting)
c11 list-workspaces                     # workspaces only
c11 list-panes                          # panes in the current workspace
c11 list-pane-surfaces                  # surfaces in the current pane

# "Is any agent working on X?" — sweep every surface title in the whole app
c11 tree --all | grep -i "ACE-387"
```

The danger isn't the typo, it's the **failure shape**: a failed c11 command still writes to the pipe,
so `c11 list | grep <x>` returns empty and reads exactly like a clean "nothing found." An agent can
confidently report "nobody is working on that" on the strength of a command that never ran. If an
enumeration comes back empty and the answer matters, **run the command bare first** and confirm it
actually produced a tree.

## Workspaces, panes, surfaces

```bash
# Create
c11 <path>                           # Open directory in new workspace (launches c11 if needed)
c11 new-workspace [--cwd <path>] [--root <path>] [--command <text>] [--title <text>] [--layout <path|name>]
c11 set-workspace-root [--workspace <id|ref>] (<path> | --clear)
c11 new-split <left|right|up|down> [--cwd <path|inherit>]   # Split any pane; the new pane is always a terminal
c11 new-pane [--type <terminal|browser|markdown>] [--direction <dir>] [--url <url>] [--cwd <path|inherit>]
c11 new-surface [--type <terminal|browser|markdown>] [--pane <id|ref>] [--workspace <id|ref>]
c11 launch-agent --type <kind> [--model <id>] [--effort <tier>] \
    [--system-prompt-mode inherit|append|replace] [--system-prompt <text> | --system-prompt-file <path>] \
    [--task <id>] [--pane <id|ref> | --workspace <id|ref> | --new-workspace] [--cwd <path>] \
    [--prompt <text> | --prompt-file <path>] [--title <text>] \
    [--flag <reason>] [--suppressed] [--env K=V ...] [--json]
    # Launch a typed agent (claude-code|codex|grok|kimi|opencode|github-copilot|pi|omp,
    # or a custom kind with ~/.config/c11/agents/<kind>.json) into a new surface or a
    # fresh workspace. One command owns the per-agent invocation quirks, model/effort
    # flag syntax, identity-at-birth (env + metadata + title), and prompt delivery;
    # --json returns the new refs. Canonical reference: docs/launch-agent-reference.md.
    # --system-prompt-mode append|replace injects the kind's system-prompt flag
    # (claude-code only in v1; replace + empty text = blank slate). errors
    # system_prompt_unsupported for a kind with no system-prompt axis.
    # --flag <reason> raises a sticky flag before command delivery (operator-designated
    # priority missions only); --suppressed marks the worker parent-owned. Semantics:
    # the attention model in SKILL.md.
    # cwd precedence: explicit --cwd > workspace root > launching surface cwd.
    # Linked-worktree cwd values proceed with a coded warning naming the worktree path.
    # Explicit --cwd and workspace-root provenance count as explicit intent; a
    # launching-surface cwd is inherited. warning_details carries code/path/source
    # in --json, and the coded warning is also printed once to stderr.
    # Project .c11/agents.json lookup uses that resolved cwd (never the GUI process
    # cwd); config_source reports the matched file path or null in --json.

# Saved agent configs (the model picker's CLI, design §6)
c11 config list [--json]                          # saved configs + pinned default + most-recent
c11 config recent [--json]                        # observed most-recent, with per-field source
c11 config stats [--window today|all|<N>d] [--by model|harness|provider] [--json]
c11 config save <name> --harness <k> [--model <id>] [--effort <tier>] \
    [--system-prompt-mode inherit|append|replace] [--system-prompt <text> | --system-prompt-file <path>] \
    [--command <c>] [--initial-prompt <p>] [--env K=V ...] [--json]
c11 config edit <name|id> [ …same field flags… ]  # supply only what changes; empty string clears to inherit
c11 config rm <name|id>
c11 config reorder <name|id> --to <index>
c11 config default <name|id> | --pin-current [<name>]   # the default is always a pinned config
c11 config launch <name|id> [--pane <id|ref> | --workspace <id|ref> | --new-workspace] \
    [--cwd <path>] [--prompt <text> | --prompt-file <path>] [--json]
    # A saved config is a full launch recipe (harness + model/effort/system-prompt +
    # advanced command/initial-prompt/env). `list/recent/stats/save/edit/rm/reorder/
    # default` read & write the state-root files DIRECTLY — they work with the app down.
    # `config launch` is the one command that needs the running app (it spawns a
    # surface); it's a thin client over agent.launch, honoring the config's full recipe
    # and reusing its error codes (unknown_agent_type, invalid_effort, …).
    # `default --pin-current` snapshots the most-recent launch into a new saved config
    # and pins it (optional name overrides the auto label). `--window <N>d` = last N days.

c11 model-costs list [--json]                     # model token-cost catalog (picker $ column)
c11 model-costs set <model> --in <usd> --out <usd> [--source <url>] [--notes <text>]
c11 model-costs get <model> [--json] | rm <model>
c11 model-costs import <path|-> [--replace]       # bulk JSON: {"<model>": {"in_usd": n, "out_usd": n, ...}}
    # Agent-maintained API list prices ($/Mtok) at the state root (model-costs.json),
    # file-first like `config` — works with the app down. Feeds the launch picker's
    # cost column; keys are model ids (short `opus`, full `claude-opus-5`, router
    # `provider/model`). `set` stamps observed_at; keep `--source` honest so the next
    # updater has provenance. Prices are relative-magnitude signal, not billing truth.

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
c11 send-key down                    # Send a keypress directly (no text) — drives TUI menus
c11 send --workspace workspace:2 --surface surface:3 "ls"
c11 send --surface surface:3 -- "$(cat brief.md)"   # Multi-line brief: one paste, one turn
```

**`c11 send` delivers the payload as a paste, then submits it with a separate Return.** The Return is a real key event dispatched after the target has ingested the paste, so paste-detecting TUIs (Claude Code, codex) register a submit rather than swallowing it. This holds whether or not the target's workspace is the one on screen — a send into a background agent lands exactly like one into the focused pane.

**Interior newlines are content; a trailing newline means "and press Enter".** A multi-line brief arrives whole and becomes *one* turn — you don't need to stage it in a file and send a pointer. `send --no-submit "cmd\n"` still runs `cmd`, because the trailing newline is the Enter.

**Targeting is strict.** An empty or unresolvable ref (`--surface ""`, a stale `surface:99`) is an error — `send` never falls back to whatever pane happens to be focused. For `send` / `send-key`, a surface ref is a global handle: `--surface` alone reaches a pane in any workspace of the window. (Other commands, `read-screen` included, still resolve a surface within the caller's workspace, so pass `--workspace` alongside it there.)

Naming only a workspace (`send --workspace workspace:3 "ls"`, no `--surface`) still targets that workspace's focused pane — you named a target, just a coarser one.

**`c11 send-key <key>` dispatches a single keypress** to the surface's PTY, encoded for the terminal's current mode (so arrow keys drive arrow-select menus like codex's hooks-trust prompt). Vocabulary:

- Submission / editing: `enter`/`return`, `tab`, `escape`, `space`, `backspace`, `delete`
- Arrows: `up`, `down`, `left`, `right`
- Navigation: `home`, `end`, `pageup`, `pagedown`
- Function keys: `f1`–`f12`
- Control: `ctrl-c`, `ctrl-d`, `ctrl-z`, and generic `ctrl-<letter>`

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

- `--type` accepts canonical values (`claude-code`, `codex`, `grok`, `kimi`, `opencode`, `github-copilot`, `pi`, `omp`) and any kebab-case custom value.
- Writes land as `source: declare` in the metadata store, overriding heuristic auto-detection but not user-explicit writes.
- Environment declaration: `C11_AGENT_TYPE`, `C11_AGENT_MODEL`, `C11_AGENT_TASK` in the surface's startup env are read once at surface-child-process start.
- Clear with `c11 clear-metadata --key terminal_type` (no `c11 unset-agent`).
- Bundled provider wrappers and runtime plugins may report exact loop state with
  `c11 agent-hook working|idle`. This is a bundle-private lifecycle bridge,
  not a command agents need to call in ordinary skill-driven operation.

## Title & description

Sugar over metadata writes to the canonical `title` and `description` keys. Rendered in the surface's title bar.

```bash
c11 set-title "SIG Delegator — reviewing PR #42"
c11 set-title --from-file /tmp/title.txt
c11 set-description "Running smoke suite across 10 shards; reports to Lattice task lat-412."
c11 set-description --from-file /tmp/desc.md
```

`c11 rename-tab` is an alias for `c11 set-title` on the target surface. The sidebar tab label is a truncated projection of the title.

`c11 get-titlebar-state` prints the surface's `ref=surface:N` alongside title/description — the same N the tab bar displays when surface-ID display is on. The "N: " prefix is rendered by the app, not stored: titles never contain it, and `set-title` must not add one.

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

## Resize panes

Binary splits aren't balanced automatically. Two `new-split right` calls give you `[A 50% | B 25% | C 25%]`, not equal thirds. Use `resize-pane` to rebalance.

```bash
c11 resize-pane --pane <ref> --workspace <ref> (-L|-R|-U|-D) --amount <px>
```

- `-R <px>` grows the pane by pushing its **right** border rightward (shrinks the right neighbor).
- `-L <px>` grows the pane by pushing its **left** border leftward (shrinks the left neighbor).
- `-U` / `-D` are the vertical equivalents.
- A direction toward the workspace edge fails with `Pane has no adjacent border in direction <dir>`: the leftmost pane cannot `-L`, the topmost cannot `-U`, etc. Resize from the neighbor instead.

**Compound-split cascade.** When you resize a pane whose nearest matching border belongs to an *outer* split (not the split that directly separates it from its closest sibling), the resize moves the outer boundary; both children of the inner split grow **proportionally**, preserving their existing ratio. Example: given `[A 50%] | [B 25% | C 25%]` (outer horizontal split, right half split again), `resize-pane --pane B -L 500` pulls 500px across the outer boundary — B and C each gain 250px because their inner ratio is 1:1. Resize again across the inner boundary (`-R` on B) to equalize B and C without touching A.

**Recipe: equal thirds from two right-splits.** After `new-split right` twice on a workspace of width `W`, you have `[A W/2 | B W/4 | C W/4]`. One resize lands thirds, because the cascade does the inner redistribution for free:

```bash
# W = workspace content width (read from `c11 tree --json` or the ASCII floor plan header)
c11 resize-pane --workspace $WS --pane $B -L $((W / 6))
# → A shrinks by W/6 to W/3; B and C each grow by W/12 (inner ratio preserved) to W/3 each.
```

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

## Skill + Plugin Installation (`c11 skill install`)

`c11 skill install --tool <tui>` copies the c11 skill bundle (and for OpenCode, a notification plugin) into the TUI's config directories. Human-run, consent-gated, reversible.

```bash
c11 skill install --tool claude        # Skills → ~/.claude/skills/
c11 skill install --tool opencode      # Skills → ~/.opencode/skills/ + plugin → ~/.config/opencode/plugins/
c11 skill install --tool codex         # Skills → ~/.codex/skills/
c11 skill install --tool kimi          # Skills → ~/.kimi/skills/
c11 skill status [--json]              # Detection + install state for all tools
c11 skill install --tool opencode --dry-run   # Show what would be written
c11 skill remove --tool opencode       # Reverses install (skills + plugins)
```

For OpenCode, the installer also copies a bundled plugin (`c11-notify.js`) into `~/.config/opencode/plugins/`. The plugin bridges `session.idle`, `permission.asked`, `session.error`, and `session.status` events into c11 notifications and sidebar status updates — giving OpenCode the same "blue ring + tab highlight + Cmd+Shift+U" workflow as Claude Code. OpenCode auto-loads plugins from that directory at startup; no `opencode.json` edit is required.

> **Historical note:** `c11 install <tui>` (without the `skill` subcommand) is not a real command — it was aspirational in earlier docs. The actual install path is `c11 skill install --tool <tui>`.

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
