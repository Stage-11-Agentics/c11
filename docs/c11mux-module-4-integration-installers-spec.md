# c11mux Module 4 — Integration Installers Spec

Canonical specification for Module 4 of the [c11mux charter](./c11mux-charter.md). Defines `cmux install <tui>` / `cmux uninstall <tui>` — one-command wiring of cmux's notification shims and agent-declaration calls into each first-class TUI's configuration, plus the menubar item that launches the flow.

Status: specification, not yet implemented. The scaffolding this module extends (the PATH-shim wrapper `Resources/bin/claude`, the `cmux claude-hook` CLI, the menubar controller, the v2 socket `surface.create` method) all exist today; `cmux install` does not.

---

## Purpose

Today, cmux's Claude Code integration only fires when the user runs `claude` through cmux's bundled PATH-shim wrapper at `Resources/bin/claude:89` — the wrapper injects hooks inline via `claude --settings '<json>'` at invocation time. Users who launch Claude Code through their own alias, a task runner, or another terminal bypass the wrapper and lose the integration. The shim works for Claude Code but has never been extended to Codex, OpenCode, or Kimi.

Module 4 makes the integration persistent and TUI-agnostic by **writing the hook wiring into each TUI's own config file**, so the hooks fire regardless of how the TUI is launched. The CLI command exposes this installation; the menubar item is a discovery surface that triggers the CLI in a new terminal.

What "integration" means, per TUI:

1. **Notification shims** — when the TUI reaches an agent milestone (waiting for input / task complete / error), the TUI's configured hook calls `cmux claude-hook <event>` (or the equivalent per-TUI subcommand), which in turn surfaces a cmux notification targeted at the originating surface. For TUIs without native lifecycle hooks, the shim is a PATH wrapper that tails/emits OSC 9/99/777 sequences or runs the hook externally.
2. **Agent declaration** — at TUI startup, the same hook invokes `cmux set-agent --type <tui> --model <model> [--task <id>]` (M1 sugar over `surface.set_metadata`) so the sidebar chip (Module 3), title bar (Module 7), and tree output (Module 8) immediately reflect the correct agent identity.
3. **Skill bundle** — the c11mux skill files (`cmux`, `cmux-browser`, `cmux-markdown`) drop into the TUI's agent-instruction directory so the agent running under that TUI actually knows the CLI surface, the sub-agent orchestration pattern, and the embedded browser. Hooks make the TUI *see* c11mux; the bundle makes it *speak* c11mux. See [§ Skill bundle install](#skill-bundle-install).

---

## Consent

The installer asks before it writes. Every time.

This is not overcaution — it is a stance. The industry norm is that install scripts edit shell configs, editor settings, and agent hooks the moment you run them, on the theory that the user will not notice and would have said yes anyway. We consider that a category error: convenience mistaken for consent. A tool that silently rewrites the user's home directory has confused expedience with permission. It is an unprofessional pattern; at a company that cares where the line between operator and machine sits, it is an unethical one.

c11mux does not work that way. The installer names what it will write, shows the diff, and waits for a `y`. The user is the root authority over their own machine — the installer proves it by asking.

### What consent covers

One act of consent authorizes two bound writes for the chosen TUI:

1. **Hooks and shims** — the per-TUI config entries defined in [§ Per-TUI install plan](#per-tui-install-plan) (and, for shim TUIs, the script at `$HOME/.local/bin/cmux-shims/<tui>`). These make the TUI *see* c11mux: notifications, sidebar chip, title bar, tree.
2. **Skill bundle** — the c11mux skills dropped into the TUI's skills directory. These make the TUI *speak* c11mux: splits, surfaces, sub-agent orchestration, the embedded browser. An agent with hooks but no skill bundle can signal but not drive; an agent with skills but no hooks can drive but not signal. The pair is load-bearing.

Both live behind the same prompt. Advanced flags `--only-hooks` and `--only-skills` exist for operators wiring one half in isolation, but the default path installs the pair.

### The prompt

Interactive runs print this frame before the diff. Copy is loaded from `Resources/Consent/prompt.md` so brand edits don't require a code change; tests assert the rendered prompt matches a versioned golden.

> **c11mux integration — consent required**
>
> Most installers write to your config the moment you run them. We consider that a category error: convenience mistaken for consent. Your machine is yours; this installer proves the distinction by asking.
>
> With your permission, we will do two things for `<tui>`:
>
> 1. **Wire the hooks.** `<tui>` notifies c11mux at session start, prompt submit, completion. The sidebar, title bar, and tree will reflect what this agent is doing — not what the process tree guesses. The diff below names every line.
>
> 2. **Install the skill bundle.** The c11mux skills — `cmux`, `cmux-browser`, `cmux-markdown` — drop into `<skills-path>`. Hooks make `<tui>` *see* c11mux. The bundle makes it *speak* c11mux: surfaces, splits, sub-agent orchestration, the embedded browser.
>
> These arrive together. A wired TUI without the bundle has eyes but no language; a bundled TUI without wiring can talk but nobody is listening. Consent gates the pair.
>
> Apply? [y/N]

Non-interactive runs (`--no-confirm`) skip the prompt but do **not** skip the policy — the caller is asserting that consent was granted by an earlier interactive act (e.g. the operator approving the CI pipeline that calls the installer). Scripts that invoke `--no-confirm` on user-initiated flows without prior consent are violating the posture this spec documents, and we will not ship affordances that hide that fact.

---

## Terminology

- **TUI** — one of the four first-class supported agent CLIs: `claude-code`, `codex`, `opencode`, `kimi`. This module only ships installers for these four. Additional TUIs may be added in a later spec amendment.
- **Hook** — a user-configured callback the TUI invokes at a lifecycle event (e.g. session start, user prompt submit, completion). Claude Code calls these `hooks`; other TUIs use different vocabulary. For this spec, "hook" is the generic term.
- **Shim** — a PATH-resident wrapper script that intercepts TUI invocations when the TUI has no native hook surface (see `Resources/bin/claude`). Shims are cmux's fallback when config-based hooks aren't available.
- **Marker** — the idempotency sentinel embedded in the config. See [§ Idempotency](#idempotency).
- **Config path** — the absolute filesystem path where the TUI reads its config. Defaults to the TUI's documented location; can be overridden with `--config-path`.

---

## Goals / Non-goals

### Goals (v1)

- `cmux install <tui>` for `claude-code`, `codex`, `opencode`, `kimi`.
- Idempotent: re-running is a no-op when hooks and skill bundle are already present and current.
- Uninstallable: `cmux uninstall <tui>` cleanly removes only cmux-installed content (both hooks and skill bundle).
- Merge-safe: preserve the user's hand-written hooks and surrounding config.
- **Consent-gated by default.** No write happens without an explicit `y` in interactive mode. See [§ Consent](#consent).
- Skill bundle install — drop `cmux`, `cmux-browser`, `cmux-markdown` into the TUI's skills directory as part of the same consent act.
- Confirmation diff before write, with a non-interactive mode for CI (assumed pre-authorized).
- Menubar entry that spawns a terminal and runs the installer for a picked TUI.
- Status/list queries to inspect installation state (hooks + bundle) across all four TUIs.
- HOME-redirectable so tests can run against a tempdir config.

### Non-goals (v1)

- **Installing the TUIs themselves.** If `claude-code` or `codex` is not on the system, `cmux install claude-code` exits with a guidance error, not a bootstrap.
- **Detecting installations outside the canonical config path.** We write to the documented location per TUI. Users who have relocated their config supply `--config-path`.
- **Auto-upgrading existing hooks written by previous c11mux versions.** The marker carries a schema version; a version mismatch is reported and the user is prompted to re-run with `--force`. Silent upgrade is parked.
- **Subscribe/push delivery of installation status.** Status queries are pull-only (matches Module 2's charter-level posture).
- **Per-workspace installation.** Hooks are global to the user's TUI config. Workspace-scoped installation is parked.
- **Uninstalling the cmux-bundled `Resources/bin/claude` wrapper.** That wrapper is a cmux *distribution* artifact, not installer-managed state. Its presence is orthogonal to this module.

### Charter parking-lot items we explicitly do not address

- "Canonical JSON-broadcast writers shipped per TUI" (charter parking lot, *Metadata delivery* bucket) — the charter notes these "may not be needed if the integration installers from Module 4 handle this." Module 4 handles the notification/declaration piece; it does not ship a generic broadcast writer.

---

## CLI surface

All installer CLIs take the same workspace-relative treatment as other Module 4 non-focus commands: they don't consult `CMUX_WORKSPACE_ID`, because installation is global. They do consult `CMUX_SOCKET_PATH` for the running-cmux check (see [§ Failure modes](#failure-modes)).

```
cmux install <tui> [--dry-run] [--no-confirm] [--force] [--config-path <path>] [--skills-path <path>] [--home <path>] [--only-hooks] [--only-skills] [--json]
cmux uninstall <tui> [--dry-run] [--no-confirm] [--config-path <path>] [--skills-path <path>] [--home <path>] [--only-hooks] [--only-skills] [--json]
cmux install --list [--json]
cmux install --status <tui> [--json]
```

### Positional argument

`<tui>` is one of: `claude-code`, `codex`, `opencode`, `kimi`. Aliases: `claude` → `claude-code`. Unknown values return `unknown_tui` (exit 2).

### Flags

| Flag | Applies to | Default | Behavior |
|------|------------|---------|----------|
| `--dry-run` | install, uninstall | false | Compute the diff, print it, exit 0 without writing. **Never focus-stealing** — safe from menubar/hook contexts. |
| `--no-confirm` | install, uninstall | false | Skip the `y/N` prompt. Required for non-TTY contexts (CI, menubar-launched surface that the user did not type in). Exits 0 after write. |
| `--force` | install | false | Write even if the existing cmux-installed block is at a newer schema version. Overwrites. Without `--force`, a version-mismatch exits `schema_version_mismatch`. |
| `--config-path <path>` | install, uninstall, `--status` | per-TUI default | Override the config file location. Used by tests (fake HOME) and by users with non-default paths. |
| `--skills-path <path>` | install, uninstall, `--status` | per-TUI default | Override the skills directory. Defaults: `$HOME/.claude/skills` for claude-code; see [§ Skill bundle install](#skill-bundle-install) for the other TUIs. Tests use this. |
| `--home <path>` | install, uninstall, `--status` | `$HOME` | Override the root for all per-TUI default paths. Equivalent to setting `HOME=<path>` for the duration of the invocation, but without mutating the process env. Tests use this. |
| `--only-hooks` | install, uninstall | false | Install or remove only the hook/shim side; skip the skill bundle. Advanced; see [§ Consent](#consent). |
| `--only-skills` | install, uninstall | false | Install or remove only the skill bundle; skip hooks. Advanced; mutually exclusive with `--only-hooks`. |
| `--json` | all | false | Emit JSON instead of human-readable text. Matches existing CLI convention (`docs/socket-api-reference.md`). |

### Sub-commands (implemented as flags on `install`)

- `cmux install --list` — table of all four TUIs with one row each: `tui | installed? | schema_version | config_path | tui_binary_found?`. No writes, non-focus-stealing.
- `cmux install --status <tui>` — single-TUI detailed view: installed state, schema version, expected hash, actual hash, last-write timestamp (from the marker), the exact injected block that would be written. No writes, non-focus-stealing.

### Interactive flow (default)

1. CLI resolves the config path per TUI (or `--config-path`).
2. CLI reads the existing config; if absent, prompts "Config not found at <path>. Create? [y/N]".
3. CLI computes the post-write config, diffs against pre-write config, prints the diff (unified format, colorized when stdout is a TTY).
4. CLI prompts "Apply these changes? [y/N]". Any input other than `y`/`Y` aborts with exit code 1 and no write.
5. On `y`: writes atomically (tempfile + rename in the same directory), chmod preserves existing mode, prints a one-line success summary.
6. On failure mid-write: the tempfile is removed; the original config is untouched.

Non-interactive mode (`--no-confirm`) skips steps 2 (errors with `config_missing` if absent unless `--create-if-missing` is passed — see open questions) and 4 (auto-confirms).

---

## Per-TUI install plan

The four TUIs fall into two buckets:

- **Native-hook TUIs** — the TUI's config file includes a first-class hook/lifecycle callback surface. We inject into that surface. **Current set: `claude-code`.**
- **Shim TUIs** — the TUI has no native hook surface c11mux can rely on in v1. We install a PATH shim at `$HOME/.local/bin/cmux-shims/<tui>` that wraps the real binary, emits `cmux claude-hook` calls around it, and ask the user to prepend `$HOME/.local/bin/cmux-shims` to PATH. **Current set: `codex`, `opencode`, `kimi`** (verified against the upstream CLIs' `--help` output as of this spec's date; see [§ Open questions](#open-questions) for the revisit criteria).

### `claude-code` (native-hook)

**Config path (default):** `$HOME/.claude/settings.json` (JSON, pretty-printed, 2-space indent preserved when present).

**What we write:** a hooks object matching the inline JSON already baked into the `Resources/bin/claude` wrapper at `Resources/bin/claude:89`. The canonical block, versioned:

```jsonc
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "cmux claude-hook session-start", "timeout": 10 },
          { "type": "command", "command": "cmux set-agent --type claude-code --source declare", "timeout": 5 }
        ]
      }
    ],
    "Stop": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "cmux claude-hook stop", "timeout": 10 } ] }
    ],
    "SessionEnd": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "cmux claude-hook session-end", "timeout": 1 } ] }
    ],
    "Notification": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "cmux claude-hook notification", "timeout": 10 } ] }
    ],
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "cmux claude-hook prompt-submit", "timeout": 10 } ] }
    ],
    "PreToolUse": [
      { "matcher": "", "hooks": [ { "type": "command", "command": "cmux claude-hook pre-tool-use", "timeout": 5, "async": true } ] }
    ]
  },
  "x-cmux": {
    "schema": 1,
    "id": "c11mux-v1",
    "installed_at": "<iso-ts>",
    "entries": [
      { "event": "SessionStart",     "sha256": "<computed>" },
      { "event": "Stop",             "sha256": "<computed>" },
      { "event": "SessionEnd",       "sha256": "<computed>" },
      { "event": "Notification",     "sha256": "<computed>" },
      { "event": "UserPromptSubmit", "sha256": "<computed>" },
      { "event": "PreToolUse",       "sha256": "<computed>" }
    ]
  }
}
```

**Merge strategy:** cmux-installed hook entries carry no inline marker. Identity is established by **content-hash match** against the `x-cmux.entries[]` table at the root of `settings.json`. For each event in the block above:

1. If `settings.hooks[event]` does not exist → create with `[cmux_entry]`; append a new `{event, sha256}` to `x-cmux.entries`.
2. If it exists and contains an entry whose canonical-hash matches any prior `x-cmux.entries[]` sha256 for this event → replace that entry in place (preserve entry index to minimize diff churn) and update the stored sha256.
3. If it exists without any matching cmux-owned entry → append `cmux_entry` to the end of the array; record its sha256 in `x-cmux.entries`. The user's hand-written entries run first, cmux's run after.
4. If `x-cmux.schema` differs from the current schema → bail with `schema_version_mismatch` unless `--force`.

**`x-cmux` placement:** the marker lives as a parallel top-level key in `settings.json`, not as a sibling on individual hook entries. This is the same pattern used for OpenCode's config and avoids relying on Claude Code tolerating unknown keys inside the hooks schema (JSON Schema convention treats `x-`-prefixed root keys as extension points; unknown root keys are broadly ignored by consumers). The hook-entry objects Claude Code parses match the exact shape documented upstream.

**Agent-declaration wiring:** the `cmux set-agent --type claude-code --source declare` call at `SessionStart` establishes `terminal_type=claude-code` in the surface's metadata blob (M2 canonical key) via the `declare` source. Model id is declared separately by the user or by a future `--model` resolution in M1; v1 does not attempt to auto-detect the model client-side.

**`sha256` computation:** per-event, SHA-256 over the canonical JSON serialization (sorted keys, no whitespace) of the hook-entry object cmux writes (`{matcher, hooks}`). Stored in `x-cmux.entries[i].sha256`. Idempotency and uninstall both rely on hash-matching entries in `hooks.<event>` against this table — see [§ Idempotency](#idempotency).

### `codex` (shim TUI for v1)

**Config path (default):** `$HOME/.codex/config.toml` (TOML, per `codex --help`). Codex does not expose a lifecycle-hook surface in its config today; config is strictly for model selection, sandbox flags, and MCP servers. A PATH shim is the v1 approach.

**What we write (shim approach):**

1. **Shim script** at `$HOME/.local/bin/cmux-shims/codex` (executable, 0755, owner-only writable), shape:
   ```bash
   #!/usr/bin/env bash
   # c11mux integration shim (do not edit)
   set -u
   CMUX_MARKER_ID="c11mux-v1"
   [[ -n "${CMUX_SURFACE_ID:-}" ]] && cmux set-agent --type codex --source declare || true
   [[ -n "${CMUX_SURFACE_ID:-}" ]] && cmux claude-hook session-start </dev/null >/dev/null 2>&1 || true
   # Resolve real codex, skipping this shim directory.
   SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
   REAL=""
   IFS=:
   for d in $PATH; do
     [[ "$d" == "$SELF_DIR" ]] && continue
     [[ -x "$d/codex" ]] && { REAL="$d/codex"; break; }
   done
   [[ -n "$REAL" ]] || { echo "cmux-shim: codex not found in PATH" >&2; exit 127; }
   "$REAL" "$@"
   STATUS=$?
   [[ -n "${CMUX_SURFACE_ID:-}" ]] && cmux claude-hook session-end </dev/null >/dev/null 2>&1 || true
   exit $STATUS
   ```
2. **Marker table** appended to the *end* of `$HOME/.codex/config.toml` as a top-level `[x-cmux]` table (parallel to the JSON `x-cmux` root key used by claude-code and opencode):
   ```toml
   [x-cmux]
   schema = 1
   id = "c11mux-v1"
   installed_at = "<iso-ts>"
   shim_path = "~/.local/bin/cmux-shims/codex"
   shim_sha256 = "<computed>"
   # Managed by `cmux install codex`. The shim wires cmux notifications around
   # codex. For it to run, prepend $HOME/.local/bin/cmux-shims to PATH.
   ```
   Codex reads `~/.codex/config.toml` for its own keys; unknown top-level tables are ignored by the Codex parser (same tolerance assumption as OpenCode's `x-cmux`). `shim_sha256` is hashed over the generated shim script so re-install can detect shim drift.
3. **PATH-activation guidance** printed at the end of the install: a single line telling the user to add `$HOME/.local/bin/cmux-shims` to their shell PATH. The installer does **not** modify `.zshrc`/`.bashrc` — shell init files are user territory. See Open question #1 for shell-init-management as a potential v2 addition.

**Merge strategy:** the TOML mutation is a single top-level `[x-cmux]` table append. If an `[x-cmux]` table already exists with a different `schema`, `schema_version_mismatch` applies. With matching schema and a `shim_sha256` that matches the current shim, re-install is a no-op; otherwise the shim script is overwritten and `shim_sha256` updated. The shim script is treated as cmux-owned.

**Declaration wiring:** the shim calls `cmux set-agent --type codex --source declare` when `CMUX_SURFACE_ID` is present (i.e. when run inside a cmux terminal). Outside cmux the shim still runs codex but skips the declaration and hook calls.

### `opencode` (shim TUI for v1)

**Config path (default):** `$HOME/.config/opencode/opencode.json` (JSON, `$schema` = `https://opencode.ai/config.json`). The config's schema centers on model providers, instructions, and MCP servers; no lifecycle-hook surface we can rely on in v1. Same shim approach as codex.

**What we write:**

1. **Shim script** at `$HOME/.local/bin/cmux-shims/opencode` (same shape as the codex shim, with `--type opencode` in the set-agent call).
2. **Marker block** appended to `opencode.json`'s root object as a top-level `x-cmux` key (JSON Schema convention: `x-`-prefixed keys are extension points):
   ```json
   {
     "x-cmux": {
       "schema": 1,
       "id": "c11mux-v1",
       "installed_at": "<iso-ts>",
       "shim_path": "~/.local/bin/cmux-shims/opencode",
       "shim_sha256": "<computed>"
     }
   }
   ```
   This key is reserved for uninstall to find; cmux does not otherwise read it at runtime. Shape is the same envelope claude-code and kimi use.

**Merge strategy:** JSON-level shallow merge, same precedence rules as the Claude Code block: add `x-cmux`, leave all other keys untouched, error on schema mismatch.

### `kimi` (shim TUI for v1)

**Config path (default):** `$HOME/.kimi/config.toml` (TOML). Structure centers on model selection, providers, and loop control; no lifecycle-hook surface we can rely on in v1. Shim approach.

**What we write:**

1. **Shim script** at `$HOME/.local/bin/cmux-shims/kimi` (same shape as codex, with `--type kimi`).
2. **Marker table** appended to `$HOME/.kimi/config.toml` as a top-level `[x-cmux]` table (same envelope as codex):
   ```toml
   [x-cmux]
   schema = 1
   id = "c11mux-v1"
   installed_at = "<iso-ts>"
   shim_path = "~/.local/bin/cmux-shims/kimi"
   shim_sha256 = "<computed>"
   # Managed by `cmux install kimi`.
   ```
   Kimi's TOML parser tolerates unknown top-level tables (verified against `~/.kimi/config.toml` existing keys: `default_model`, `providers.*`, `services.*`, `loop_control` — all dotted tables; extras are ignored).

Merge strategy identical to codex.

---

## Skill bundle install

The skill bundle is the second half of the consent-gated pair ([§ Consent](#consent)). Hooks make a TUI *see* c11mux; the bundle makes it *speak* c11mux. Without the bundle, an agent under a wired TUI can emit notifications but has no working vocabulary for `cmux new-split`, `surface:N` refs, sub-agent launch patterns, the metadata blob, or the embedded browser — it has eyes but not language.

### What's in the bundle

Three sibling skills, shipped in lockstep because they are parts of one surface:

| Skill | Purpose |
|-------|---------|
| `cmux` | Core: orient, declare, send/read, splits/panes/surfaces, `cmux tree`, sub-agent orchestration via `cc`. |
| `cmux-browser` | WKWebView browser automation — open, click, fill, snapshot. Preferred over Chrome MCP when in c11mux. |
| `cmux-markdown` | Markdown surfaces with live file watching and Mermaid rendering. |

Each skill is a directory: `<skill>/SKILL.md` plus `references/` and `templates/` as needed. Canonical source lives at `code/c11mux/skills/<skill>/` in the c11mux repo; the app bundles a release snapshot under `Resources/Skills/<skill>/`. The installer copies from the bundled snapshot, not the repo path, so installed versions are pinned to the shipped cmux version.

`cmux-debug-windows` is a developer-focused skill for c11mux contributors and is **not** part of the user-facing bundle. It installs only via the developer flow (`cmux install claude-code --dev-skills` — see [§ Open questions](#open-questions)).

### Per-TUI destination

Only `claude-code` has a first-class skills surface in v1. For shim TUIs, the bundle is scoped to their documented instruction surface:

| TUI | Destination | Status |
|-----|-------------|--------|
| `claude-code` | `$HOME/.claude/skills/<skill>/` per skill | Full bundle install. |
| `codex` | `$HOME/.codex/skills/<skill>/` per skill | Full bundle install. Codex reads `skills/` equivalently to Claude Code as of this spec's date; verify against `codex --help` and fall back to no-op with a warning if the directory convention changes upstream. |
| `opencode` | `$HOME/.config/opencode/skills/<skill>/` | Bundle install if the directory is writable; otherwise skip with a warning. OpenCode's skill surface is still consolidating upstream; see [§ Open questions](#open-questions). |
| `kimi` | *Skipped in v1.* | Kimi has no documented skills/instructions surface cmux can target in v1. The installer writes hooks and prints a guidance line that the skill bundle will activate for Kimi once upstream ships a skills directory. |

Users with non-default skill paths supply `--skills-path <path>`. Inside that directory the installer always creates one subdirectory per skill (`<path>/cmux`, `<path>/cmux-browser`, `<path>/cmux-markdown`).

### What we write

For each target skill, the installer:

1. **Writes the skill directory** at `<skills-path>/<skill>/`, recursively copying from the bundled snapshot at `Resources/Skills/<skill>/`. File mode 0644 for regular files, 0755 for directories. No symlinks at install time — the bundle is materialized as real files so user's skill directory does not depend on the app bundle remaining on disk at its current path.
2. **Writes a per-skill marker** at `<skills-path>/<skill>/.cmux-managed.json`:
   ```json
   {
     "schema": 1,
     "id": "c11mux-v1",
     "skill": "cmux",
     "installed_at": "<iso-ts>",
     "version": "<cmux-version>",
     "manifest_sha256": "<computed>"
   }
   ```
   `manifest_sha256` is a SHA-256 over the sorted list of `(relative-path, content-sha256)` pairs for every file in the installed skill. Re-install recomputes, compares, and no-ops if the hash matches.
3. **Writes/merges a top-level bundle marker** at `<skills-path>/.cmux-bundle.json` tracking which skills the c11mux installer placed, so uninstall knows what to remove without needing to re-read each skill's marker:
   ```json
   {
     "schema": 1,
     "id": "c11mux-v1",
     "installed_at": "<iso-ts>",
     "skills": ["cmux", "cmux-browser", "cmux-markdown"]
   }
   ```

### Merge strategy

- **Fresh install.** `<skills-path>/<skill>/` does not exist → write all files, drop both markers.
- **Existing c11mux-installed skill (`.cmux-managed.json` present, `schema` matches, `manifest_sha256` matches current bundle)** → no-op.
- **Outdated c11mux-installed skill (`schema` matches, `manifest_sha256` differs)** → remove every file the old manifest lists, write the new snapshot, update the marker. Files the old manifest does not list are preserved (user additions).
- **Schema mismatch on `.cmux-managed.json`** → bail with `schema_version_mismatch` unless `--force`.
- **Existing user-owned skill at the same directory name (no `.cmux-managed.json`)** → refuse to write. Exit `skill_collision` with the path and instructions to rename or pass `--force` (which backs up the existing directory to `<skills-path>/<skill>.pre-cmux-<iso-ts>/` and then installs).

Hand-edited files inside a c11mux-managed skill directory are detected by per-file content hash against the manifest; modified files are preserved and the installer surfaces them in the diff ("3 files user-modified, preserved"). New files the user has added survive install/uninstall untouched — the manifest is the only delete-authority.

### Uninstall

`cmux uninstall <tui>` removes:

1. Every file listed in the installed-skill manifest for each skill in `.cmux-bundle.json`.
2. The skill directory itself, if it becomes empty after step 1.
3. `.cmux-managed.json` per skill.
4. `.cmux-bundle.json`, if its `skills` array becomes empty.

User-added files and user-modified files are preserved by design. If the skill directory is not empty after file removal, the directory is kept with only the user-owned residue inside.

### Dry-run and status

- `cmux install <tui> --dry-run` prints the diff for hooks **and** the bundle — the skill side shows which skills will be created/updated/no-op'd, with a per-skill summary line and a file-count change.
- `cmux install --status <tui>` reports bundle state alongside hook state, using a matching three-value taxonomy (`bundle_not_installed` / `bundle_installed_current` / `bundle_installed_outdated`).

### Interaction with personal-dev symlinks

cmux developers working on the skills themselves typically symlink `~/.claude/skills/cmux` to `code/c11mux/skills/cmux` so edits are live. The installer detects a symlinked skill directory (not a regular directory) and refuses to overwrite it, exiting `skill_is_symlink` unless `--force` is passed — at which point the symlink is removed and a materialized copy replaces it. This protects an in-flight dev setup from being stomped by an accidental `cmux install`.

---

## Idempotency

The **marker** is the single source of truth for "is cmux installed here, and is the install current?"

- **Marker id:** `c11mux-v1` — global constant, bumped only on breaking schema changes.
- **Schema version:** integer, currently `1`.
- **SHA-256:** hash over the canonical serialization of the commands we'd write. Changing the command list (e.g. the `PreToolUse` call's `timeout`) changes the hash.

### Detection algorithm (`cmux install --status <tui>` / re-install no-op check)

All four TUIs use the same envelope: a top-level `x-cmux` key (JSON root for claude-code/opencode, `[x-cmux]` table for codex/kimi) carrying `schema`, `id`, `installed_at`, and per-TUI content hashes (`entries[].sha256` for claude-code; `shim_sha256` for the shim TUIs).

1. Read the config file; if absent → `not_installed`.
2. Look up `x-cmux` (JSON root key) or `[x-cmux]` (TOML top-level table). If absent → `not_installed`.
3. If `x-cmux.schema` ≠ current schema → `schema_mismatch`.
4. Compute the expected content hashes for the current cmux templates.
   - **claude-code:** for each event in the canonical block, re-serialize the expected `{matcher, hooks}` entry, SHA-256 it, and compare to `x-cmux.entries[event].sha256`. Also verify that the matching entry actually exists in `hooks.<event>` (hash-match against the entries' live content).
   - **shim TUIs:** recompute SHA-256 of the shim script that would be written now, compare to `x-cmux.shim_sha256`; also stat the shim at `x-cmux.shim_path` and verify its on-disk hash matches.
5. If all hashes match → `installed_current`.
6. If any hash differs → `installed_outdated`.

### Re-run behavior

| Prior state | `cmux install <tui>` behavior |
|-------------|-------------------------------|
| `not_installed` | Interactive: show diff, prompt. Non-interactive: write. |
| `installed_current` | No-op. Print "already installed, current" and exit 0. `--dry-run` prints "would no-op." |
| `installed_outdated` | Interactive: show diff (old cmux block → new cmux block), prompt. Non-interactive with `--force`: overwrite. Non-interactive without `--force`: exit `outdated_install_requires_force`. |
| `schema_mismatch` | Exit `schema_version_mismatch` unless `--force`. With `--force`: overwrite. |

### User-edit handling

If the user has hand-edited the `[x-cmux]` table (TOML) or the `x-cmux` key (JSON), or has modified a cmux-owned hook entry such that its content-hash no longer matches any `x-cmux.entries[].sha256`, the installer treats the entry as user-owned and will not replace it — re-install appends a fresh cmux entry alongside, and uninstall leaves the orphaned entry in place. Hand edits to the shim script itself are detected via `shim_sha256` drift and overwritten on re-install (the shim is cmux-owned; users who want to customize behavior should wrap the shim, not edit it). CLI output surfaces both cases explicitly ("will overwrite shim at <path>; N hand-edited entries preserved").

---

## Menubar wiring

### Where it hooks in

In `Sources/AppDelegate.swift:11419` (`MenuBarExtraController.buildMenu()`), insert a new submenu *before* the `checkForUpdatesItem` separator at line 11451:

```swift
// After markAllReadItem / clearAllItem and before the checkForUpdates separator
let integrationsItem = NSMenuItem(title: String(localized: "menu.integrations", defaultValue: "Integrations"), action: nil, keyEquivalent: "")
let integrationsSubmenu = NSMenu(title: "Integrations")
for tui in IntegrationInstallerTUI.allCases {
    let item = NSMenuItem(
        title: String(format: "%@ %@", tui.displayName, installedStateGlyph(tui)),
        action: #selector(installIntegrationAction(_:)),
        keyEquivalent: ""
    )
    item.target = self
    item.representedObject = tui.rawValue
    integrationsSubmenu.addItem(item)
}
integrationsItem.submenu = integrationsSubmenu
menu.addItem(integrationsItem)
```

### Click handler

`installIntegrationAction(_:)` does:

1. Read `representedObject` (the TUI's raw value).
2. Resolve a target workspace: the currently-selected workspace if there is one; else the first in `window.list`. (Menu-bar-launched surfaces do need a workspace to live in.)
3. Send `surface.create` via the socket (`CLI/cmux.swift:1796` shows the equivalent CLI path using `client.sendV2(method: "surface.create", params: ...)`). Params: `{ "workspace_id": "<ws>", "type": "terminal" }`. The newly-created surface is returned.
4. Immediately send `surface.send_text` to the new surface: `"cmux install <tui>\n"` — this types and executes the command.
5. Because `surface.create` is an existing focus-carrying method (v2 convention), the new surface becomes the focused surface in that workspace and the app activates. **This is the intended focus-stealing path** (see [§ Focus policy](#focus-policy)).

### Installed-state glyph

`installedStateGlyph(tui)` returns a short suffix rendered after the display name:

- `installed_current` → `✓` (or SF Symbol `checkmark.circle.fill`)
- `installed_outdated` → `↻` (update-available)
- `not_installed` → `○`
- `schema_mismatch` → `!`

The glyph is computed by reading the config paths directly from AppKit. This read is non-focus-stealing (it's a filesystem read), and the lookup runs on menu-open (`menuWillOpen` at `Sources/AppDelegate.swift:11468`), so it's at most O(4 config file reads) per menu open — acceptable.

### Error handling

If `surface.create` fails (no workspace exists), the handler posts an NSAlert "Open a workspace first, then re-open the Integrations menu." Explicit focus is acceptable here because the user just clicked a menu item — this is inside an explicit user action, matching the socket focus policy's allowance for user-initiated UI surfaces.

---

## Storage / persistence

Installer state lives entirely in **the user's TUI config files** (and, for shim TUIs, in `$HOME/.local/bin/cmux-shims/`). cmux itself does **not** persist installer state in UserDefaults or app-support storage. This is intentional:

- The source of truth is the TUI's config — what's actually loaded when the TUI runs. An app-side cache can drift.
- Tests can work against a fake `$HOME` without AppKit state leaking in.
- The existing `ClaudeCodeIntegrationSettings.hooksEnabled` at `Sources/cmuxApp.swift:3745` is a separate, orthogonal flag: it controls whether the `Resources/bin/claude` PATH-shim wrapper injects its inline `--settings` JSON. M4's installer writes hooks into the user's persistent config; the two paths are independent and can both be enabled simultaneously (hooks fire either way, Claude Code deduplicates by command-string equality per its own merge semantics).

### Interaction with existing wrapper

The `Resources/bin/claude` wrapper at `Resources/bin/claude:89` remains unchanged. Users running claude through cmux's PATH get hooks via `--settings` (inline). Users running claude outside cmux (after `cmux install claude-code`) get hooks from `~/.claude/settings.json`. Users running claude inside cmux *after* installing get both — the bundled-wrapper hooks and the installer-written hooks coexist safely: Claude Code merges `--settings` into loaded settings additively and deduplicates hook commands by **command-string equality**. Since the wrapper's inline JSON and the installed entries emit byte-identical `command` strings (same `cmux claude-hook <event>` invocations, same timeouts), each event fires exactly once regardless of which path loaded the hook. The wrapper is the belt, the installer is the suspenders.

---

## Interaction with other modules

- **Module 1 (TUI detection).** The installer wires `cmux set-agent` into the startup hook for every TUI. That CLI is M1 sugar over `surface.set_metadata` (per the M1 spec and Module 2's CLI table at `docs/c11mux-module-2-metadata-spec.md`). The `source` the shim uses is always `declare`, which overwrites heuristic-level auto-detection (M1) and `osc` writes (M7) but not `explicit` user overrides. See Module 2's precedence table.
  - **Ordering dependency.** `cmux set-agent` does not exist yet — it is introduced by M1. If M4 lands before M1, the installed hooks/shims MUST emit raw `surface.set_metadata` calls instead (e.g. `cmux __v2 surface.set_metadata --json '{"metadata":{"terminal_type":"claude-code"},"source":"declare"}'`), then be migrated to `cmux set-agent` once M1 ships. Either form writes identical metadata via the same precedence rules; only the CLI surface differs.
- **Module 2 (per-surface metadata).** All agent-declaration writes land as metadata. The canonical keys touched are `terminal_type` (always) and optionally `model` (if the TUI exposes it to the hook — only Claude Code does today, via the `session-start` payload). Other keys (`role`, `status`, `task`) are not written by the installer; agents and users own them.
- **Module 3 (sidebar chip).** The installer is what *enables* Module 3 to show the right chip outside cmux's wrapper. No direct coupling — M3 just reads the metadata M4's hooks populate.
- **Module 5 (brand identity).** The consent prompt is a brand surface ([§ Consent](#consent)). Copy lives at `Resources/Consent/prompt.md` and coordinates with whatever canonical voice artifacts M5 establishes.
- **Module 6 (markdown polish).** No interaction beyond shipping `cmux-markdown` as part of the skill bundle.
- **Module 7 (title bar).** No interaction beyond the metadata store shared via M2.
- **Module 8 (cmux tree).** Tree output cites `terminal_type` per pane, which the installer's hook writes. No direct coupling.
- **Skill bundle dependency.** The bundle install side ([§ Skill bundle install](#skill-bundle-install)) depends on the skills existing under `code/c11mux/skills/` at build time and being snapshotted into `Resources/Skills/` at app-bundle creation. No runtime coupling — installed skills are regular files, readable by the target TUI without cmux running.

---

## Socket methods

This module does **not introduce new socket methods.** Everything that touches the running cmux process goes through existing APIs:

- `surface.create` — used by the menubar click path (`CLI/cmux.swift:1796` shows the CLI-side call).
- `surface.send_text` — used by the menubar path to send `cmux install <tui>\n` to the newly-created surface.
- `surface.set_metadata` / `cmux set-agent` — used at TUI startup by the installed hook (these are M1/M2 primitives).
- `notification.create` / `notify_target` — used mid-session by the installed `cmux claude-hook` calls (already wired at `CLI/cmux.swift:10197`).

The CLI is entirely filesystem-local for the install operation itself. It hits the socket only for the optional "is cmux running?" advisory check (see failure modes) and for the menubar-triggered flow.

---

## Error codes

| Code | Exit | When |
|------|------|------|
| `unknown_tui` | 2 | `<tui>` is not one of the four supported values. |
| `config_missing` | 3 | Config file does not exist and `--no-confirm` was used (no way to prompt). With `--no-confirm --create-if-missing` (see Open questions), writes a fresh config. |
| `config_permission_denied` | 4 | Cannot read or write the config path (EACCES). Suggest `chmod` or `--config-path` override. |
| `config_malformed` | 5 | Existing config fails to parse as JSON/TOML. Prints the parser error. Install refuses to write over malformed config. |
| `schema_version_mismatch` | 6 | Existing cmux-installed block's `schema` differs from current. Resolvable with `--force`. |
| `outdated_install_requires_force` | 7 | Non-interactive install over an outdated-but-same-schema block without `--force`. |
| `tui_binary_not_found` | 8 | Warning on install (non-fatal; exit 0 with a warning line). Fatal only for `--strict` (see Open questions). |
| `shim_dir_not_writable` | 9 | Cannot create or write `$HOME/.local/bin/cmux-shims/`. |
| `marker_hand_edit_detected` | 10 | Uninstall: the `x-cmux` table was hand-edited (e.g. `schema` or `id` changed) or a tracked entry's hash no longer matches any `x-cmux.entries[].sha256`, and `--preserve-edits` was not passed. Prints the diff, asks user to confirm with `--force` (non-interactive) or `y` (interactive). |
| `skill_collision` | 11 | A skill directory of the same name exists at the target path but is not c11mux-managed (no `.cmux-managed.json`). Exit without writing. `--force` backs up the existing directory to `<skill>.pre-cmux-<iso-ts>/` and proceeds. |
| `skill_is_symlink` | 12 | The target skill directory is a symlink (typical of cmux developer setups). Exit without writing. `--force` replaces the symlink with a materialized copy. |
| `skills_dir_not_writable` | 13 | Cannot create or write under `--skills-path`. Suggest `chmod` or an alternate path. |
| `exclusive_only_flags` | 14 | Both `--only-hooks` and `--only-skills` passed; they are mutually exclusive. |
| `user_aborted` | 1 | Interactive confirm returned non-`y`. |

All error paths print a one-line human message followed, in `--json`, by a structured body:

```json
{ "ok": false, "error": { "code": "config_malformed", "message": "...", "path": "/Users/x/.claude/settings.json", "parser_error": "..." } }
```

---

## Focus policy

Per `Sources/../CLAUDE.md`'s "Socket focus policy" section and the charter-level stance that non-focus commands preserve user focus:

| Operation | Focus behavior |
|-----------|----------------|
| `cmux install <tui>` (interactive) from a terminal the user is already in | No focus change. The user is typing in the surface; the prompt appears in that surface. |
| `cmux install <tui>` invoked via the menubar trigger | **Focus-stealing, and intentional.** The menubar click calls `surface.create` (existing focus-carrying v2 method) — the new terminal surface becomes focused and the app activates, so the user can read the diff and type `y`. `surface.create` is the sole focus-intent socket call in this module. |
| `cmux install --list`, `cmux install --status <tui>` | Non-focus-stealing. Filesystem-only reads; no socket calls touch the running app at all. |
| `cmux install <tui> --dry-run` | Non-focus-stealing. No writes; no socket side-effects. Safe to invoke from background watchers. |
| `cmux uninstall <tui>` (any mode) | Same rules as install. The menubar does not expose uninstall in v1 (see Open questions) — uninstall is CLI-only. |
| Background idempotency checks (called by the menubar's `menuWillOpen` to compute the installed-state glyph) | Non-focus-stealing. Filesystem reads only. |

The dry-run flag is the carrier of "I know nothing I do should cause activation" — if the caller is unsure, `--dry-run` first is always safe.

---

## Test surface (mandatory)

Per the charter's testability principle. Every behavior below is verifiable headlessly via the CLI, with no AppKit or render-loop dependency.

**Test location:** `tests_v2/test_install_<tui>.py` per TUI, plus `tests_v2/test_install_common.py` for cross-TUI behavior (dry-run, list, status). Follow the shape of `tests_v2/test_cli_sidebar_metadata_commands.py:1-56` (CLI-binary resolution via `CMUXTERM_CLI`, subprocess invocation, stdout assertions).

### Fake HOME fixture

All tests construct a `tempfile.TemporaryDirectory()` and pass `--home <tempdir>` to the CLI. The CLI resolves all default config paths relative to that directory. No environment-variable mutation (the test does not export `HOME` — it would race with other tests on CI). Per-test fixture shape:

```python
def _fresh_home(starting_configs: dict[str, str] | None = None) -> str:
    home = tempfile.mkdtemp(prefix="cmux-install-test-")
    for rel_path, contents in (starting_configs or {}).items():
        full = os.path.join(home, rel_path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(contents)
    return home
```

### Required test cases

1. **Install from empty** (per TUI). `_fresh_home()` with no config; run `cmux install <tui> --no-confirm --home <home>`; assert exit 0, config created, marker present, hash matches expected-golden. Snapshot the resulting config against `tests_v2/fixtures/install_<tui>_fresh.golden`.

2. **Install over user config** (per TUI). `_fresh_home({".claude/settings.json": <hand-written-hooks>})`; install; assert user hooks preserved verbatim AND cmux entries present. Compare against `tests_v2/fixtures/install_<tui>_merge.golden`.

3. **Idempotency no-op.** Install twice; assert second run exits 0 with output containing `already installed, current`, and the config file's mtime does not change between runs.

4. **Round-trip.** Install → uninstall → config byte-identical to pre-install. For starting-from-empty, uninstall leaves the file not-created (if we created it) or untouched (if we didn't).

5. **Dry-run.** `cmux install <tui> --dry-run --home <home>`: assert exit 0, assert config file *not* modified, assert stdout contains a unified diff with `+` lines for every cmux-injected line.

6. **List.** `cmux install --list --json --home <home>`: assert JSON array of length 4, each element has `tui`, `installed`, `schema_version`, `config_path`, `tui_binary_found`. Install one TUI, re-run list, assert that TUI shows `installed: true`.

7. **Status.** `cmux install --status claude-code --json --home <home>`: installed-current / not-installed / installed-outdated states each produce the expected `status` field.

8. **Schema-mismatch gate.** Seed a config with a `c11mux-v99` marker; run install without `--force`, assert exit 6 (`schema_version_mismatch`). Re-run with `--force`, assert exit 0 and marker rewritten to schema 1.

9. **Malformed config refusal.** Seed `settings.json` with `{` (incomplete JSON); run install; assert exit 5 (`config_malformed`), assert file unchanged.

10. **Shim-dir creation.** For codex / opencode / kimi: install; assert `$home/.local/bin/cmux-shims/<tui>` exists, is executable (mode & 0o111), and runs `<tui> --version` passthrough correctly when the real binary is in PATH.

11. **Confirmation flow non-interactive.** `cmux install <tui>` without `--no-confirm` and without a TTY (subprocess with `stdin=DEVNULL`): assert exit 1 (`user_aborted`) with a message indicating TTY required or `--no-confirm` missing.

12. **Marker hand-edit detection.** Install; manually mutate the `x-cmux` table (e.g. change `schema` or clear an entry's `sha256`); run uninstall; assert exit 10 (`marker_hand_edit_detected`) without `--force`.

### What's *not* in the test surface

- Actually running Claude Code / Codex / OpenCode / Kimi. We don't need to — the TUIs' own acceptance of the config is the TUIs' problem, and cmux's responsibility ends at writing a valid file. Claude Code–level "does the hook actually fire?" coverage lives in Claude Code's own test suite, not cmux's.
- The menubar click path. The menubar → `surface.create` → `send_text` chain is covered by existing v2 socket tests (e.g. the browser-surface open-flow tests demonstrate the `surface.create` + `send_text` pattern). Menubar-specific coverage would require AppKit fixtures and is out of scope.
- Network reachability of TUI binaries. `tui_binary_found` is a PATH-based check, not an execution check.

---

## Implementation notes (non-normative)

Starting points for the implementer. None of the changes below have landed yet; cite line numbers against current files.

### CLI plumbing

- Add a `case "install":` and `case "uninstall":` branch in `CLI/cmux.swift`'s main dispatch switch around `CLI/cmux.swift:2064-2302`. Adjacent handlers — `notify` at line 2064, `claude-hook` at line 2195 — are the shape to follow. Delegate to a new `runInstallCommand(commandArgs:client:jsonOutput:)` / `runUninstallCommand(...)` helper.
- The helper lives in a new file `CLI/Install/InstallCommand.swift` (mirroring how `runClaudeHook` at `CLI/cmux.swift:10023` is a long private method). Split it out because it's going to grow.
- Per-TUI logic in `CLI/Install/Installers/<Tui>Installer.swift` — one struct per TUI, all conforming to an `IntegrationInstaller` protocol:
  ```swift
  protocol IntegrationInstaller {
      var tui: IntegrationInstallerTUI { get }
      func defaultConfigPath(home: String) -> String
      func detect(configPath: String, home: String) -> InstallState  // .notInstalled, .installedCurrent, ...
      func plan(configPath: String, home: String, forced: Bool) throws -> InstallPlan  // the diff + new content
      func apply(plan: InstallPlan) throws
      func uninstall(configPath: String, home: String, force: Bool) throws
  }
  ```
- Config-file readers/writers should use `FileManager` + `Data` for atomic-rename writes. JSON work through `JSONSerialization` (preserving key order isn't critical; Claude Code's schema doesn't depend on key order). TOML work through a vendored minimal TOML library — or, to avoid a new dependency, use line-based BEGIN/END marker handling for the TOML TUIs, since we only ever append a marker block.

### Menubar plumbing

- Extend `MenuBarExtraController.buildMenu()` at `Sources/AppDelegate.swift:11419`. Add the new submenu between the `clearAllItem` (line 11449) and the separator at line 11451. Wire the click handler via `@objc` `installIntegrationAction(_:)` on the controller.
- The handler calls into a Swift wrapper that invokes `surface.create` via the same socket-client code the CLI uses. The existing CLI path at `CLI/cmux.swift:1796` shows the v2 params shape; reuse it.
- `IntegrationInstallerTUI` enum + `allCases` exhaustiveness gives the menu its list without drift.

### ClaudeCodeIntegrationSettings interaction

`Sources/cmuxApp.swift:3745` — leave the existing `hooksEnabledKey` UserDefault alone. It controls the bundled PATH-shim wrapper's inline-hook injection, which is independent of M4's persistent-config install. Document in the Settings UI that the wrapper and the persistent install are independent and both can be on.

### Tests

Follow the shape of `tests_v2/test_cli_sidebar_metadata_commands.py:1-56` for CLI-binary resolution (the `_find_cli_binary` helper at `tests_v2/test_cli_sidebar_metadata_commands.py:24-39` is copy-pastable). For fake-HOME handling, see test #1 above — do not mutate `os.environ["HOME"]`; pass `--home <tempdir>` to the CLI.

### Threading

All install logic is off-main, filesystem-bound, and synchronous from the CLI caller's perspective. No `DispatchQueue.main.sync`. The menubar click handler does the `surface.create` call on the main actor (AppKit default) and returns immediately; the `surface.create` socket method already handles its own threading per `Sources/../CLAUDE.md`'s socket threading policy.

---

## Open questions

Deliberately not decided in this spec so future agents can pick them up:

1. **Should `cmux install` offer to modify shell init files (`.zshrc`, `.bashrc`, `.config/fish/config.fish`) to prepend `$HOME/.local/bin/cmux-shims` to PATH?** v1 only prints guidance. If user feedback says "I always forget the PATH step," a v2 addition could offer an *optional* `--wire-shell-init` flag with the same marker/diff/confirm ceremony as config installs. Scoped for a separate spec amendment.

2. **Per-TUI native hook discovery.** Codex, OpenCode, and Kimi may grow native hook surfaces upstream. When they do, the shim approach should be replaced per-TUI. Revisit criteria: when any of the three ships a documented session-lifecycle hook, open an issue to migrate that TUI to native-hook install and bump `schema` to 2.

3. **`--create-if-missing` flag for non-interactive bootstraps.** Currently install-from-empty requires an interactive prompt to confirm creation. CI scenarios need `--no-confirm --create-if-missing` to do both skips in one. Add when a user surfaces this.

4. **Uninstall from the menubar.** v1 exposes install only. Adding an uninstall action to the submenu is trivial but doubles the menu real-estate; deferred until operators ask for it.

5. **Menubar state caching.** Reading four config files on every `menuWillOpen` is fine today (cheap, local) but could become visible if we grow to many integrations. Add a file-mtime-keyed cache if latency becomes measurable.

6. **`cmux install all` convenience.** One-shot install of every available TUI. Not in v1 — each TUI has its own failure modes and deserves its own confirm prompt.

7. **`--strict` mode where `tui_binary_not_found` is fatal.** Useful for CI that provisions a Codex install first, then runs `cmux install codex` as a setup step. Deferred to first user ask.

8. **`--dev-skills` to include `cmux-debug-windows` in the bundle.** Today's user-facing bundle is `cmux` + `cmux-browser` + `cmux-markdown`. cmux contributors want the debug-windows skill too. A `--dev-skills` flag would widen the manifest without forking the installer. Ship when a contributor asks.

9. **Skill-bundle destination for shim TUIs.** `codex`, `opencode`, and `kimi` are evolving their own skill/instructions surfaces upstream. The v1 destinations named in [§ Skill bundle install](#skill-bundle-install) reflect the current state (April 2026). Revisit per TUI when its skills surface stabilizes; the installer's per-TUI config already isolates this so changing a destination is a one-table edit.

10. **Signing the skill bundle manifest.** `manifest_sha256` verifies integrity of the files at install time, but a later adversary with write access to `~/.claude/skills/` could modify both files and manifest. If agent skills become a security-relevant surface, the bundle marker could carry a detached signature over a release keypair. Out of scope until threat model pushes back.
