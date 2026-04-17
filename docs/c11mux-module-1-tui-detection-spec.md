# c11mux Module 1 — TUI Auto-Detection Spec

Canonical specification for Module 1 of the [c11mux charter](./c11mux-charter.md). This module identifies which agent TUI is running in each surface and exposes that identity through two canonical keys in the Module 2 metadata blob: `terminal_type` and `model`. All writes land via `surface.set_metadata` (defined in [`c11mux-module-2-metadata-spec.md`](./c11mux-module-2-metadata-spec.md)); M1 introduces **no new socket method**.

Status: specification, not yet implemented. Depends on M2's `surface.set_metadata` / `surface.get_metadata`, which are also not-yet-implemented primitives — M1 and M2 ship together.

---

## Purpose

Every c11mux surface that hosts a terminal is usually running either a plain shell, a first-class agent TUI (Claude Code, Codex, Kimi, OpenCode), or some other program. Downstream modules need a cheap, always-fresh answer to "what is in this surface?":

- **Module 3** renders a sidebar chip per surface (icon + model label).
- **Module 8** (`cmux tree`) shows the running program next to each pane box.
- **Lattice and external consumers** filter panes by running agent, correlate task IDs, and route messages.

M1 provides this answer in two layers:

1. **Heuristic layer** (default, always-on): a process-tree/TTY scan classifies the foreground process on each surface against a known-binary table and writes `terminal_type` (plus `model` when derivable) with `source: heuristic`.
2. **Declaration layer** (opt-in, authoritative): a `cmux set-agent` CLI and `CMUX_AGENT_*` env-var convention let an agent or launcher self-identify with richer fields the heuristic can't see (`model`, `task`, `role`). All writes go through `surface.set_metadata` with `source: declare`, so M2's precedence chain handles the override.

---

## Terminology

- **Surface** — in c11mux today, a `Panel` / `TerminalPanel` keyed by `UUID` on the owning `Workspace`. The charter casually uses "pane" and "surface" interchangeably; this spec uses **surface** (matching the v2 socket API and M2).
- **TTY** — the slave pseudo-terminal device path (e.g. `ttys014`) reported by the shell via the existing `report_tty` socket command. Stored on `Workspace.surfaceTTYNames[panelId]`.
- **Foreground process** — on a given TTY, the process group that currently owns the controlling terminal (`tpgid` / `ps STAT` column with `+`). This is what the user sees typing; by definition at most one exists per TTY at a time.
- **Canonical TUI** — one of `claude-code`, `codex`, `kimi`, `opencode`. The value space of `terminal_type` is open-ended; these four are the first-class set that M1 ships binary-match rules for and that M3 renders with branded icons.

---

## Goals / Non-goals

### Goals
- Classify the foreground process of every terminal surface into `terminal_type` within ~2 seconds of a TUI starting, without user cooperation.
- Let an agent authoritatively declare its identity in one CLI call or one env-var assignment, carrying `model`, `task`, and `role` in the same operation.
- Respect M2's precedence chain: never trample a user's `explicit` override, never trample an agent's `declare`.
- Be agentically testable: a `tests_v2/` test must be able to simulate any `terminal_type` in a headless CI environment.

### Non-goals
- **Not a process-tree observer.** M1 does not walk the full descendant tree; it classifies the foreground process on the surface's TTY. Nested cases (tmux-in-surface running Claude in a tmux pane) are out of scope for v1 and land as `terminal_type: unknown` or `shell`. A future version may walk the subtree; the wire format leaves room.
- **Not a notification router.** Notification-source labeling is a parking-lot item in the charter (Module 4's territory).
- **Not a model-picker UI.** The `model` key carries whatever string the agent or user declares. c11mux does not validate model names against any registry.
- **No new socket method.** This is a deliberate constraint the charter reviewers set. All M1 writes funnel through `surface.set_metadata`; if a genuine need for a distinct method surfaces during implementation, it lives in "Open questions" first, not silently in the spec.

---

## Canonical keys (defined here, stored in M2)

M2's canonical-key table lists `terminal_type` and `model` and cites M1 as the graduator. M1 is the definitive source for their **behavior**; M2 owns the **storage mechanics**.

### `terminal_type`

- **Type:** string, kebab-case, lowercase, `^[a-z][a-z0-9-]{0,31}$` (max 32 chars). Violations return `reserved_key_invalid_type` per M2.
- **Canonical values (shipped in v1):**

  | Value | Meaning | Source |
  |-------|---------|--------|
  | `claude-code` | Anthropic Claude Code CLI running in the foreground | heuristic, declare |
  | `codex` | OpenAI Codex CLI running in the foreground | heuristic, declare |
  | `kimi` | Moonshot Kimi CLI running in the foreground | heuristic, declare |
  | `opencode` | OpenCode CLI running in the foreground | heuristic, declare |
  | `shell` | Only a login shell is foregrounded; no recognized TUI | heuristic |
  | `unknown` | A non-shell, non-canonical program is foregrounded; the heuristic ran but could not classify | heuristic |

- **Open value space.** New first-class TUIs are added by amending the table in this spec. Third parties may declare arbitrary kebab-case values via `cmux set-agent --type <custom>`; M3 renders a generic chip for unrecognized values.
- **Lifecycle.** Cleared automatically when the surface closes (M2's existing surface-scoped cleanup handles this). Never cleared on shell exec — the heuristic re-evaluates and writes a new value.

### `model`

- **Type:** string, kebab-case, ≤ 64 chars (per M2's existing constraint).
- **Relationship to `terminal_type`:** optional, independent, paired. The heuristic may know `terminal_type` but not `model` (e.g., it sees the `claude` binary but not which model is selected). Declaration may supply `model` without `terminal_type` (agent knows its own model but defers type to the heuristic).
- **Heuristic-derivable cases.** The heuristic MAY seed `model` only when the model is unambiguously encoded in the binary name or a well-known env var. In v1 the heuristic does NOT set `model` for any first-class TUI (model selection is a TUI-internal decision); it leaves the field for declaration to fill. This keeps the heuristic honest and cheap.
- **Declaration cases.** `cmux set-agent --model <id>` and `CMUX_AGENT_MODEL=<id>` both write `model` with `source: declare`.

### Optional declaration-only keys

These are already reserved by M2 but are written by M1's declaration layer (CLI + env). M1 does not seed them from the heuristic.

- `task` — free-form task correlation ID (e.g. `lat-412`). String, ≤ 128 chars per M2.
- `role` — free-form agent role (e.g. `reviewer`, `spike-coordinator`). String, ≤ 64 chars, kebab-case per M2.

---

## Detection mechanism

### TTY-based foreground-process scan

The heuristic does not walk arbitrary subtrees. It uses the same path PortScanner already uses (`Sources/PortScanner.swift`):

1. For each surface with a registered TTY in `Workspace.surfaceTTYNames[panelId]`, collect the TTY name.
2. Dedupe across all surfaces, run a single `ps -t <tty1>,<tty2>,... -o pid=,ppid=,stat=,tpgid=,comm=,args=`.
3. For each TTY, pick the **foreground process** = the process whose `pid` equals the TTY's `tpgid` (all processes on the TTY share the same `tpgid`, so any row will do). If `stat` contains `+`, that is a secondary confirmation.
4. Apply the matching table (below) to the foreground process's `comm` and `args`.
5. Derive `terminal_type` and write it via `surface.set_metadata` with `source: heuristic` if the value has changed.

### Binary-match table

| `terminal_type` | Match rule |
|------|------|
| `claude-code` | `comm == "claude"` OR `comm == "claude-code"`. If `comm == "node"`, fall back to `args` substring `claude-code` or `anthropic-ai/claude-code` (Claude Code ships as a Node bin). |
| `codex` | `comm == "codex"` OR `comm == "codex-cli"`. If `comm == "node"`, `args` substring `openai/codex` or `codex-cli`. |
| `kimi` | `comm == "kimi"` OR `comm == "kimi-cli"`. If `comm == "node"`, `args` substring `moonshot/kimi` or `kimi-cli`. |
| `opencode` | `comm == "opencode"` OR `comm == "opencode-cli"`. If `comm == "node"`, `args` substring `sst/opencode` or `opencode-cli`. |
| `shell` | `comm` is in the static set `{"zsh", "bash", "fish", "sh", "dash"}` AND matches none of the above. |
| `unknown` | TTY has a foreground process but it matches nothing above. |
| (no write) | TTY exists but no foreground process (exiting surface, race); heuristic is a no-op. |

**Matching rules in detail.**
- `comm` is truncated to 15 chars by Darwin's `ps`; rely on `args` when the short name is ambiguous (`node`, `python`, etc.).
- Matching is **exact** on `comm` for the canonical shells and TUIs; **substring on `args`** only for the `node`/`python`-wrapped cases above. No path-prefix matching — an alias at `~/.local/bin/claude` still has `comm == "claude"`.
- **Wrapper scripts.** The c11mux bundle ships `Resources/bin/claude` as a shim that `exec`s the real binary — after `exec`, `comm` is `claude` (or `node`), so the wrapper does not confuse the matcher. OpenCode and similar wrappers follow the same pattern; if a third-party wrapper doesn't `exec` but instead forks, the heuristic sees the wrapper (typically `bash`) and classifies as `shell`. Declaration covers this case.

### When to scan

Scans are cheap (one `ps` across all TTYs) but not free. M1 triggers a scan at:

1. **Surface creation** — immediately after a terminal surface attaches its TTY (hooked off the existing `report_tty` path in `Sources/TerminalController.swift:14934` — when a TTY is first registered for a surface, schedule a scan for that surface's workspace after a 250 ms debounce so the shell's startup has settled).
2. **Shell prompt refresh** — the zsh shell integration already fires `ports_kick` at prompt refresh (`Sources/PortScanner.swift:65`). Add a sibling `agent_kick` (socket command, see below) that shell integration fires from the same hook. Coalesces on the same 200 ms timer.
3. **Periodic sweep** — a 10 s utility-QoS timer rescans every surface with a registered TTY. Catches TUIs started via non-cooperating shells and detects exits. This is the safety net; (1) and (2) carry the common case.
4. **Surface focus change** — on focus, kick a targeted scan for the newly-focused surface only. Keeps the sidebar chip (M3) fresh at interaction time.

No scan on every keystroke or on every OSC sequence — that is the parking-lot push/subscribe territory and not worth the cost.

### `agent_kick` (internal, not user-facing)

M1 adds one **v1-style** socket command `agent_kick [--tab=<id>] [--surface=<id>]` that shell integration fires from its existing precmd/preexec hook. It enqueues the requested surface into the same coalescing queue used by the scanner. It is not a v2 JSON-RPC method; it is an internal hook, symmetric with `ports_kick`, and documented in the shell-integration section.

This is the **only new socket surface** M1 adds. It is not a metadata-writing method — writes still go through `surface.set_metadata`.

---

## Declaration layer (sugar over `surface.set_metadata`)

### CLI: `cmux set-agent`

```
cmux set-agent --type <terminal_type>
              [--model <id>]
              [--task <id>]
              [--role <id>]
              [--surface <ref>]   # defaults to $CMUX_SURFACE_ID / focused surface
              [--workspace <ref>] # per the workspace-relative convention
              [--json]
```

**Semantics.** Builds a partial metadata object from the supplied flags, then issues a single `surface.set_metadata` call with `source: "declare"`, `mode: "merge"`. Only flags that are present are written — omitting `--model` does not clear an existing declared model.

**Return.** Mirrors M2's `set_metadata` result (`applied` per-key, `reasons` per rejected key). `--json` emits the raw JSON-RPC `result`.

**Validation before send.** The CLI pre-validates `--type` against the canonical-key rules for `terminal_type` (kebab-case, ≤ 32 chars) and returns a local `invalid_value` error without hitting the socket when malformed. This is purely ergonomic; the socket would reject it too.

**Workspace-relative behavior.** Standard v2-CLI resolution per `CLI/cmux.swift:136-137` — absent `--surface`/`--workspace`, the CLI uses `CMUX_SURFACE_ID` / `CMUX_WORKSPACE_ID`, so an agent inside a surface always annotates its own surface rather than the user's focused one.

### Env-var convention (launcher path)

Launchers that start a TUI can declare identity **in the process environment** rather than in a CLI call. On surface startup (in the `Resources/bin/claude`-style wrapper or in the integration scripts shipped by Module 4), the wrapper reads these vars and makes a single `cmux set-agent` call before `exec`ing the real TUI.

| Env var | Writes | Notes |
|---------|--------|-------|
| `CMUX_AGENT_TYPE` | `terminal_type` | Required for the wrapper to make a declaration call at all. |
| `CMUX_AGENT_MODEL` | `model` | Optional. |
| `CMUX_AGENT_TASK` | `task` | Optional. |
| `CMUX_AGENT_ROLE` | `role` | Optional. |

**Reading semantics.** Env vars are read **once at surface-child-process start** by the wrapper, not continuously. If the env changes mid-session, the declaration does not update. Agents that need live updates call `cmux set-agent` explicitly.

**Wrapper responsibility, not c11mux core.** c11mux Swift does not spawn subprocesses and read these env vars; the TUI wrappers (`Resources/bin/claude`, OpenCode's integration from M4, etc.) are responsible for forwarding. This keeps the Swift side ignorant of env-var grammar and keeps the wrappers portable to non-c11mux terminals.

### Why no new socket method

M2 owns the metadata store, the sidecar, the precedence chain, and the size cap. Introducing `surface.set_agent` would duplicate precedence logic in a second code path. Specifying M1 as sugar means one store, one precedence ladder, and one place to reason about "who wrote what." If, during implementation, a need emerges for a distinct method (e.g. atomic multi-key writes that `set_metadata`'s shallow-merge can't express), it is flagged in "Open questions" below and escalated — not introduced silently.

---

## Storage model

M1 **does not add a new storage dictionary**. Detection results live in M2's per-surface `metadata` / `metadata_sources` blob. Specifically:

- `workspace.metadata[surfaceId]["terminal_type"]` — a string
- `workspace.metadata[surfaceId]["model"]` — a string (when declared)
- `workspace.metadata_sources[surfaceId]["terminal_type"]` — `{source, ts}` from M2

The existing `Workspace.agentPIDs: [String: pid_t]` (`Sources/Workspace.swift:4936`) is **unchanged** and **unrelated** to M1. It continues to power stale-session detection for the Claude Code wrapper's visible status entries. PID-tracking and agent-identity are orthogonal concerns kept separate:

- `agentPIDs` answers "is the process I started still alive?"
- `metadata[terminal_type]` answers "what is running in this surface right now?"

M1's heuristic does not write to `agentPIDs`; M1's declaration does not write to `agentPIDs`. Existing writers of `agentPIDs` (`Sources/TerminalController.swift:14254`) are untouched.

**Rationale for not adding a new map.** Three candidates were considered: (a) extend `agentPIDs`, (b) add `agentInfo: [UUID: AgentInfo]`, (c) store in M2 metadata. (a) conflates liveness with identity. (b) creates a second, parallel store that M2 consumers would have to know about. (c) gives one store, one wire format, one precedence model — at the cost of accepting M2's 64 KiB cap and string-typed keys, which is trivial for these fields.

---

## Interaction with other modules

### Module 2 (metadata)
- M1 is a **client** of M2's socket methods. All reads use `surface.get_metadata` with `include_sources: true`; all writes use `surface.set_metadata` with an explicit `source`.
- **Internal in-process accessor.** The detection code inside the c11mux process reads and writes via an internal function (`TerminalController.swift` extension, to be added) that short-circuits the socket — it directly mutates the per-surface blob under the same per-surface lock `set_metadata` uses. This avoids self-RPC and keeps the scan cycle cheap.
- M1 does not redefine the `source` enum, the precedence chain, or the size cap. Any amendment to those lives in M2.

### Module 3 (sidebar chip)
- M3 renders `metadata[terminal_type]` and `metadata[model]` as one combined chip. M3's spec defines the icon mapping per canonical TUI. M1 does not prescribe rendering.

### Module 4 (integration installers)
- The wrappers `cmux install` writes (for Claude Code, Codex, Kimi, OpenCode) are responsible for exporting `CMUX_AGENT_TYPE`/`MODEL`/etc. in their shims. M1 defines the env-var contract; M4 is the primary consumer.

### Module 8 (`cmux tree`)
- `cmux tree` reads `metadata[terminal_type]` per surface via `surface.get_metadata` and renders it in the per-pane listing (and in the ASCII floor plan's tab-line label when space permits).

---

## Precedence resolution

M2 owns the precedence chain (`explicit > declare > osc > heuristic`). M1's contribution is:

1. **Heuristic writer always uses `source: "heuristic"`.** Before writing, it calls the internal metadata accessor with `include_sources: true` and compares the current source to `heuristic`. If the current source is `declare`, `osc`, or `explicit`, the heuristic **no-ops** — it does not hit `set_metadata` at all. This keeps the scan cycle free of futile precedence-check round-trips.
2. **Declaration writer (CLI + env wrapper) always uses `source: "declare"`.** It issues `set_metadata`; M2 returns `applied: false` with `reasons[key] = "lower_precedence"` if a higher-precedence value is present. The CLI surfaces this to the caller in both human and `--json` output.
3. **Clearing.** `cmux set-agent --type <other>` is a merge write, not a clear. Clearing a declared agent identity uses `cmux clear-metadata --key terminal_type` (M2 sugar). There is no `cmux unset-agent`.
4. **No special-case for heuristic → heuristic writes.** When the heuristic re-runs and the new value differs, it writes (same-source overwrites same-source per M2). The timestamp advances.

**Never-overwritten rules:**
- `source: heuristic` never overwrites `declare`, `osc`, or `explicit`.
- `source: declare` never overwrites `explicit`.
- An `explicit` clear (`cmux clear-metadata --key terminal_type`) returns the key to "unset"; the next heuristic tick will re-seed it.

---

## Heuristic seeding rules

The heuristic writes `terminal_type` if and only if all of:

1. The surface has a registered TTY (`surfaceTTYNames[panelId]` is non-empty).
2. The TTY's foreground process classified to a value (including `shell` / `unknown`).
3. Either (a) `metadata[terminal_type]` is unset, or (b) its current `metadata_sources[terminal_type].source == "heuristic"`.
4. The new value differs from the current value (avoid no-op writes and sidecar-timestamp churn).

For `model`: in v1 the heuristic **never writes** this key. Reserved for future heuristics that can unambiguously detect model from environment (see "Open questions").

---

## First-class TUI matrix

Shipped in v1. Expansion happens by amending this table and the binary-match table above in the same PR.

| TUI | Binary(ies) | Wrapper in `Resources/bin/` today | Typical `comm` at runtime | `model` heuristic? |
|-----|-------------|----------------------------------|---------------------------|---------------------|
| Claude Code | `claude` (Anthropic CLI, often a Node shim) | Yes — `Resources/bin/claude` injects hooks and `exec`s real binary | `claude` or `node` (with `claude-code` in `args`) | No — must declare |
| Codex | `codex` (OpenAI CLI) | To be added by M4 | `codex` or `node` (with `codex-cli` in `args`) | No — must declare |
| Kimi | `kimi` | To be added by M4 | `kimi` or `node` (with `kimi-cli` in `args`) | No — must declare |
| OpenCode | `opencode` | To be added by M4 | `opencode` or `node` (with `opencode` in `args`) | No — must declare |

**Why no `model` heuristic in v1.** Every first-class TUI selects its model through flags, config files, or interactive pickers — not through stable filesystem or env markers c11mux can read. A brittle heuristic would write stale values. Declaration covers this case precisely and cheaply. Revisit this constraint if a first-class TUI ships a stable, standard env marker (e.g. `ANTHROPIC_MODEL`, `OPENAI_MODEL`) that is authoritative for the running session — at that point a narrow per-TUI rule can safely seed `model` with `source: heuristic`.

---

## Errors

M1 adds no new error codes beyond what M2 already defines. Declaration-CLI errors route through M2's error table:

| Code | When |
|------|------|
| `surface_not_found` | `--surface <ref>` doesn't resolve (from M2). |
| `reserved_key_invalid_type` | `--type` or `--model` violates kebab-case / length (from M2; CLI pre-validates and may emit locally as `invalid_value`). |
| `lower_precedence` | Soft, per-key, when a declaration write can't overcome an existing `explicit` value (from M2). |
| `invalid_source` | Should never surface — the CLI hard-codes `declare`, the heuristic hard-codes `heuristic`. If observed, it's a c11mux bug. |

The heuristic's writes are fire-and-forget: `applied: false` is logged at debug level, never raised to the user.

---

## Test surface (mandatory)

All tests live in `tests_v2/` and follow the conventions in `tests_v2/test_cli_sidebar_metadata_commands.py` (locate debug CLI binary, connect to a tagged debug socket, operate via `cmux` CLI + sockets).

### Fixture: synthetic foreground process on a surface's TTY

`tests_v2/tui_detection_helpers.py` (new) exposes:

- `make_tty_foreground(cli, surface_ref, comm, args=None, hold_seconds=5)` — launches a small helper binary inside the surface that:
  - `exec`s `python3 -c "import sys,time,os; os.execvp(sys.argv[1], sys.argv[1:])"` with a rename trick so `comm` becomes the requested string, OR
  - Preferably: a prebuilt Swift helper `cmuxTests/helpers/tui-mock` whose binary name can be symlinked/copied to any target name at test setup time (`/tmp/claude`, `/tmp/codex`, etc.) and `exec`d into the surface via `cmux send-text`. `comm` is set by the binary filename, which is exactly what the heuristic matches.
- `wait_for_terminal_type(cli, surface_ref, expected, timeout=5.0)` — polls `surface.get_metadata` until the expected value is present or the timeout fires.

The second approach is preferred because it exercises the real `comm` match path. No mocking of `ps` or `sysctl` — the real tools run against a real TTY.

### Required tests

1. **`test_tui_detection_claude_heuristic.py`** — start a `tui-mock` renamed to `claude` in a fresh surface; assert `terminal_type == "claude-code"` with `source: heuristic` within 5 s. Kill it; assert `terminal_type == "shell"`.
2. **`test_tui_detection_all_first_class.py`** — parametrized across `claude`/`codex`/`kimi`/`opencode`; each asserts the expected canonical value.
3. **`test_tui_detection_declaration_overrides_heuristic.py`** — start `claude` mock, wait for heuristic, then `cmux set-agent --type codex --model moonshot-v2`. Assert `terminal_type == "codex"`, `source: declare`. Kill `claude` mock, wait 15 s; assert value unchanged (heuristic does not clobber declaration).
4. **`test_tui_detection_explicit_beats_declare.py`** — `cmux set-agent --type codex`, then `cmux set-metadata --key terminal_type --value claude-code` (which uses `source: explicit`). Assert final value `claude-code`, `source: explicit`. Follow with `cmux set-agent --type kimi`; assert `applied: false` and value unchanged.
5. **`test_tui_detection_env_declaration.py`** — launch a new surface with `CMUX_AGENT_TYPE=claude-code CMUX_AGENT_MODEL=claude-opus-4-7` in its startup env; assert both keys are written with `source: declare` within 2 s of surface creation. (Requires the M4 wrapper; in the interim the test uses `cmux send-text 'cmux set-agent --type claude-code --model claude-opus-4-7\n'` as a stand-in and the test gets renamed when the wrapper lands.)
6. **`test_tui_detection_unknown_fallback.py`** — start a mock named `nonsense-xyz`; assert `terminal_type == "unknown"`.
7. **`test_tui_detection_shell_fallback.py`** — fresh surface with no TUI; assert `terminal_type == "shell"` within 5 s.
8. **`test_tui_detection_survives_surface_close.py`** — set a `declare` value, close the surface, reopen a new surface; assert the new surface's `terminal_type` is independent (M2 owns lifecycle, so this is a sanity check that M1 doesn't leak state across UUIDs).

### Readback surface

"Reading back what's detected" is covered entirely by M2's `surface.get_metadata` — no M1-specific readback is needed. Tests use `cmux get-metadata --surface <ref> --key terminal_type --sources --json` to inspect both value and source in one call.

### Explicit non-test

**No test verifies the sidebar chip renders.** That is M3's responsibility and M3's test surface (icon-presence assertion via a socket `sidebar-state` dump, already live per `docs/socket-api-reference.md`). M1's contract ends at the metadata blob.

---

## Implementation notes (non-normative)

Starting points for the builder. All file:line references are against the branch state at spec-write time; expect drift from the in-flight rename.

### Hooking the scan

- Shared queue — reuse `PortScanner`'s dispatch pattern (`Sources/PortScanner.swift:23`). The agent scan can live in a sibling `AgentDetector` class or be merged into PortScanner as a second pass on the same `ps` run (the `comm`/`args`/`tpgid` columns are already nearly there — PortScanner currently asks for `pid=,tty=`; widen to `pid=,ppid=,tty=,tpgid=,comm=,args=` and branch the output into both port scanning and agent detection). Prefer merging — one `ps` is cheaper than two.
- Trigger points:
  - On `report_tty` (`Sources/TerminalController.swift:14934`) — after `PortScanner.shared.registerTTY(...)`, also schedule an agent scan.
  - Add `agent_kick` command dispatch (`Sources/TerminalController.swift:1743` area, next to `set_agent_pid`). Shell integration scripts (search `Resources/shell-integration/`) fire it from the same precmd that already fires `ports_kick`.
  - 10 s periodic timer — mirrors the agent-PID sweep (`Sources/TabManager.swift:876`).

### Internal metadata accessor

- M2's implementation will add a `Workspace.setSurfaceMetadata(_:source:)` and `Workspace.getSurfaceMetadata(_:)` pair, guarded by a per-surface lock (M2 spec's Threading section). M1's detector calls those directly; do NOT round-trip through the socket.
- Writes must be scheduled via `DispatchQueue.main.async` only for the sidebar re-render (per M2 Threading), consistent with the existing `setStatus` pattern at `Sources/TerminalController.swift:14184`.

### Declaration CLI

- Add `set-agent` subcommand to `CLI/cmux.swift`, parallel to the existing `set-status` handler (grep `"set-status"` for the template). The handler builds a JSON object and invokes the v2 `surface.set_metadata` client the CLI already has.
- Respect `--json`, `--workspace`, `--surface` per `docs/socket-api-reference.md`.

### Env-var wrapper forwarding

- In v1, extend `Resources/bin/claude` (`Resources/bin/claude:81` and around) to:
  ```bash
  if [[ -n "$CMUX_AGENT_TYPE" ]]; then
      cmux set-agent \
          --type "$CMUX_AGENT_TYPE" \
          ${CMUX_AGENT_MODEL:+--model "$CMUX_AGENT_MODEL"} \
          ${CMUX_AGENT_TASK:+--task "$CMUX_AGENT_TASK"} \
          ${CMUX_AGENT_ROLE:+--role "$CMUX_AGENT_ROLE"} >/dev/null 2>&1 || true
  fi
  ```
  before the `exec` of the real binary. Other TUI wrappers (added by M4) follow the same template.

### Threading

- The scan job runs off-main on `PortScanner`'s queue (or an analogous utility queue).
- Parsing, classification, and precedence-gate checks are off-main.
- The per-surface blob mutation takes the M2 per-surface lock; this is off-main.
- Only sidebar re-renders (M3) are dispatched to main.

---

## Open questions

1. **Tmux nesting.** If the user runs `tmux` in a surface and `claude` inside a tmux pane, the tmux server detaches from the surface's TTY — `claude` lives on a pty tmux owns, not on the surface's TTY. v1 will classify the surface as `shell` (tmux appears as the foreground process). Is that acceptable, or do we want a v1.1 that walks tmux's process tree? Suspected answer: accept for v1; declaration covers the case for agents that care.
2. **Does M1 need its own socket method after all?** The constraint is that declaration is sugar over `surface.set_metadata`. If, during implementation, atomic multi-key declaration semantics become load-bearing (e.g., the caller needs `terminal_type` and `model` to land together-or-not-at-all), M2's current shallow-merge with per-key precedence may not suffice. Flagging for the implementer to confirm before locking the CLI shape.
3. **`comm` matching on remote-workspace surfaces.** The remote daemon path (`WorkspaceRemoteSessionController`, `Sources/Workspace.swift:2874`) forwards TTYs over SSH. Does `ps -t` on the local host see the remote foreground process? Almost certainly not — detection on remote surfaces is a follow-up. v1 simply leaves `terminal_type` unset on remote surfaces; the remote daemon can declare via its own `cmux set-agent` call (declaration is transport-agnostic).
4. **Heuristic model derivation for future TUIs.** If a TUI ships with model-specific binary names (e.g. `claude-opus-4-7-cli`), the heuristic could seed `model` safely. Worth revisiting once the first-class set expands.
5. **Deprecation path for the existing `claude_code` status entry.** Today `set_agent_pid claude_code <pid>` is the user-visible marker of "Claude is registered here" (`CLI/cmux.swift:10081`). After M1 lands, `terminal_type == "claude-code"` is the canonical signal. The PID tracking stays for stale-session detection; whether the visible `claude_code` status entry gets retired in favor of the M3 chip is a follow-up for M3's spec.
