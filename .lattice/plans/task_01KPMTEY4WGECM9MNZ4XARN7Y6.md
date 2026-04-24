# CMUX-37 — Workspace persistence: Blueprints + Snapshots + session resume

**Ticket:** CMUX-37 (`task_01KPMTEY4WGECM9MNZ4XARN7Y6`)
**Companion doc:** `docs/c11-snapshot-restore-plan.md`
**Related platform ticket:** C11-7 (`task_01KPS4FBHSSCCJC3EP43YJ7XMZ`) — socket reliability. CMUX-37 depends on it; does not absorb it.
**Related feature ticket:** C11-13 (`task_01KPYFX4PV4QQQYHCPE0R02GEZ`) — inter-agent messaging primitive. Shares the CMUX-11 per-surface metadata layer; see alignment doc below.
**Alignment doc:** [`docs/c11-13-cmux-37-alignment.md`](../../docs/c11-13-cmux-37-alignment.md) — locked conventions for `mailbox.*` metadata namespace, surface-name addressing, strings-only values for v1, and `WorkspaceApplyPlan` composition path.
**Last refreshed:** 2026-04-24 (added C11-13 alignment)

## What this is

One ticket delivering two persistence concepts on a shared app-side primitive:

- **Blueprints** — declarative markdown that defines the initial shape of a workspace. Checked into git, shareable, per-repo (`.cmux/blueprints/*.md`) or per-user (`~/.config/cmux/blueprints/*.md`).
- **Snapshots** — auto-generated JSON capturing exact live state for crash/restart recovery. Per-user (`~/.cmux-snapshots/`).

Both compile to a `WorkspaceApplyPlan` executed **app-side in one transaction**. Not CLI/socket choreography — the 2026-04-21 dogfood proved that route fails. Both share a known-type restart registry: `claude-code + session_id → cc --resume <id>`.

## The hard constraint

**App-side transaction, not shell choreography.** A `WorkspaceApplyPlan` describes the end state; the app materializes it in one pass. The CLI sends one structured request; the app handles creation, lifecycle waiting, metadata, and ref assignment internally. Blueprints and snapshot-restore MUST route through this — never an internal loop that shells out to existing CLI commands.

## Core primitive

`WorkspaceApplyPlan` — new value type:

```swift
struct WorkspaceApplyPlan: Codable {
    var workspace: WorkspaceSpec
    var layout: LayoutTreeSpec        // nested split tree, not flat
    var surfaces: [SurfaceSpec]       // keyed by stable local ids referenced from LayoutTreeSpec
}

struct SurfaceSpec: Codable {
    var id: String                    // plan-local, not a live ref
    var type: SurfaceType             // terminal | browser | markdown
    var title: String?
    var description: String?
    var cwd: String?
    var command: String?              // terminal: initial command to send
    var url: String?                  // browser
    var file: String?                 // markdown
    var metadata: [String: JSONValue] // surface metadata (including restart registry keys)
    var pane_metadata: [String: JSONValue] // pane metadata (including mailbox.* keys per C11-13 alignment)
}
```

Nested `LayoutTreeSpec` mirrors `SessionWorkspaceLayoutSnapshot` (`Sources/SessionPersistence.swift:360-428`) so Snapshots convert trivially.

**C11-13 coordination:** `pane_metadata` must faithfully round-trip any keys under the reserved `mailbox.*` namespace without modification. For v1 both systems treat metadata values as strings; if CMUX-37 wants structured JSON values earlier, coordinate the `PaneMetadataStore`/`SurfaceMetadataStore` schema migration with C11-13 jointly. See `docs/c11-13-cmux-37-alignment.md`.

## Executor

New file: `Sources/WorkspaceLayoutExecutor.swift`. One async entry point:

```swift
@MainActor
func apply(_ plan: WorkspaceApplyPlan, options: ApplyOptions) async -> ApplyResult
```

- Creates the workspace (routes through `TabManager.addWorkspace` at `Sources/TabManager.swift:1138`).
- Walks the layout tree, calling existing split primitives on `Workspace` (`Sources/Workspace.swift` — `newTerminalSplit`, `newBrowserSplit`, `newMarkdownSplit`) to build the bonsplit tree.
- Applies titles, descriptions, surface metadata, pane metadata **during creation**, not as post-hoc socket calls. Writes go to `SurfaceMetadataStore` (`Sources/SurfaceMetadataStore.swift:63`) and `PaneMetadataStore` (`Sources/PaneMetadataStore.swift:22`) directly.
- Returns `{ workspace_ref, pane_refs, surface_refs, timings: [StepTiming], warnings: [String] }`.
- Distinguishes readiness states where practical: `created`, `attached`, `rendered`, `ready`.
- Structured partial failures: which step failed, which refs were created.

Welcome quad (`Sources/c11App.swift:3932-3995` — `WelcomeSettings.performQuadLayout`) and any other existing initial-layout flow should be re-expressed through this primitive where practical, confirming the design is general.

## Socket / CLI surface

**v2 socket method:**
```
workspace.apply(plan, options) -> { workspace_ref, pane_refs, surface_refs, timings, warnings }
```

**CLI:**
```
c11 workspace new --blueprint <path>
c11 workspace export-blueprint --workspace <ref> --out <path>
c11 workspace apply --file <path-or-json>          # lower-level/debug
c11 snapshot [--workspace <ref> | --all]
c11 restore <snapshot-id-or-path>
c11 list-snapshots
```

The `cmux` alias carries all of these (compat).

## Blueprint format

Markdown + YAML frontmatter. Exact schema finalized in Phase 2. Target shape:

```markdown
---
name: debug-auth
description: Auth module debugging layout
---

## Panes
- main  | `cc`              | cwd: ~/repo          | claude.session_id: abc123
- logs  | `tail -f log.txt` | split: right of main
- tests | `vitest --watch`  | split: below logs
```

**Idempotency:** applies at workspace creation only. Live workspace is the user's to mutate. "Re-apply" = close and reopen.

## Restart registry

Shared across Blueprints and Snapshots. Rows added per agent type without schema changes:

| terminal_type | With session_id                  | Without  |
|---------------|----------------------------------|----------|
| `claude-code` | `cc --resume <session_id>`       | `cc`     |
| `codex`       | `codex resume <session_id>` or `--last` | `codex` |
| `opencode`    | `opencode -s <session_id>` or `-c` | `opencode` |
| *unknown*     | —                                | leave empty |

For cc: the grandfathered `Resources/bin/claude` wrapper already mints `--session-id <uuid>` on every launch; `c11 claude-hook session-start` (`CLI/c11.swift:2403`, handler at `:12198`) persists id + cwd to `~/.cmuxterm/claude-hook-sessions.json`. Phase 1 adds one line to that handler: also write `agent.claude.session_id` into `SurfaceMetadataStore` via the existing persistence path. Round-trip through the Tier-1 autosave comes for free.

For codex/opencode: rely on `--last`/`-c` initially; teach agents to self-report via `c11 set-metadata --key agent.session_id …` from the `c11` skill (observe-from-outside principle).

## New-workspace picker

Empty state of `c11 workspace new` (no args) shows a merged, recency-sorted picker:
1. Per-repo Blueprints
2. Per-user Blueprints
3. Built-in starter Blueprints

Subsumes the recovery-banner UX from (superseded) CMUX-5.

## Phases

### Phase 0 — `WorkspaceApplyPlan` + executor
- New value type `WorkspaceApplyPlan` (extends or lives adjacent to `SessionPersistence.swift:462+`'s `AppSessionSnapshot`).
- New file `Sources/WorkspaceLayoutExecutor.swift` with the `apply` entry point.
- Re-express `WelcomeSettings.performQuadLayout` through the executor (or at minimum, demonstrate the executor can produce the same workspace shape).
- v2 socket method `workspace.apply`.
- CLI `c11 workspace apply --file <path>` as the debug/test surface.
- **No Blueprints, no Snapshots, no restart registry yet.** This phase lands the primitive and nothing else.

### Phase 1 — Core subcommands + Snapshots + Claude resume
- `c11 snapshot`, `c11 restore`, `c11 list-snapshots`.
- Snapshot writer: walks live workspace state, emits `WorkspaceApplyPlan` JSON to `~/.cmux-snapshots/`.
- Snapshot reader: loads JSON → `WorkspaceApplyPlan` → `apply()`.
- Restart registry (cc only; `cc --resume <id>` + JSONL-missing fallback).
- Claude-hook handler writes `agent.claude.session_id` into `SurfaceMetadataStore`.
- Opt-in via env flag (`C11_SESSION_RESUME=1`) for one release, on-by-default after.
- Terminal surfaces only; single workspace scope (`--workspace` to pick, default current).

### Phase 2 — Blueprint format + picker + exporter
- Blueprint markdown schema + parser.
- `c11 workspace new --blueprint <path>`.
- New-workspace picker: per-repo → per-user → built-in, recency-sorted.
- `c11 workspace export-blueprint --workspace <ref> --out <path>` captures live layout.

### Phase 3 — Browser/markdown surfaces + `--all`
- Extend Snapshot capture + restore to non-terminal surfaces.
- Extend Blueprint schema to cover browser/markdown.
- `c11 snapshot --all` for multi-workspace.

### Phase 4 — Skill docs + hook snippet
- Add "Session resume" section to `~/.claude/skills/c11/SKILL.md` with operator-install instructions (c11 never installs the hook).
- Document `agent.*.session_id` as a non-canonical-but-recognized metadata convention.

### Phase 5 — codex / kimi / opencode registry rows
- Add per-agent restart commands. Driven by user demand + agent-side `set-metadata` support.

## Dependencies on C11-7 (socket reliability)

Phase 0 consumes, does not absorb:
- Bounded CLI waits by default.
- Named timeout errors (method/command/refs/socket path/elapsed).
- `C11_TRACE=1` per-command start/end/timing.
- `c11 notify` on v2 (off legacy `notify_target`).
- Audit of `DispatchQueue.main.sync` socket handlers (the v1 path has 103 instances in `TerminalController.swift`).
- Deadline-aware main-actor bridge for handlers that must touch AppKit.

The 5-workspace perf fixture (target ~2s or fail fast) is CMUX-37's acceptance test and rides C11-7's stress fixture.

## Performance / reliability acceptance

- One `workspace.apply` creates a 5-workspace mixed fixture (terminal + browser + markdown + metadata + titles + descriptions) in ~2s on a normal dev machine, or fails fast with a named timeout.
- Executor returns per-step timings in debug/JSON output.
- Every readiness wait is bounded and named in the error.
- Regression fixture lives alongside C11-7's stress test.

## Principle check

- **Unopinionated about the terminal.** Writes only to `~/.cmux-snapshots/` (Snapshots) and `.cmux/blueprints/` or `~/.config/cmux/blueprints/` (Blueprints). Does not touch tenant tool settings.
- **Observe-from-outside session capture.** Claude session id via operator-installed SessionStart hook (documented in the `c11` skill). Never c11-installed.
- **Automation is a first-class consumer.** Structured, bounded, inspectable, fast.

## Supersedes

- CMUX-4 (manual Claude session index) — hook-driven capture replaces JSONL discovery.
- CMUX-5 (recovery UI banner) — subsumed by the new-workspace picker + restart registry.

Restore preserves CMUX-11 pane manifests + CMUX-14 lineage chains verbatim.

## Prior art (acknowledged, not adopted)

- `sanghun0724/cmux-claude-skills` — private session JSON + spinner-char detection + fuzzy ID matching. We use the public manifest.
- `drolosoft/cmux-resurrect` (crex) — community save/restore for upstream `manaflow-ai/cmux`, adjacent design. Inspired the Blueprint/Snapshot naming. c11 keeps the primitive narrower; templates/REPL/daemon stay ecosystem territory.
