# c11 workspace persistence — Blueprints + Snapshots + session resume

**Status:** implementation plan
**Ticket:** CMUX-37 (`task_01KPMTEY4WGECM9MNZ4XARN7Y6`)
**Companion:** `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md`
**Related:** C11-7 (`task_01KPS4FBHSSCCJC3EP43YJ7XMZ`) — socket reliability
**Author:** @atin
**Last refreshed:** 2026-04-23

> **Note on supersession.** The older version of this file described snapshot/restore only, driven by shell choreography from `c11 restore`. That approach was invalidated by the 2026-04-21 dogfood (five-workspace fixture attempt). This revision carries the app-side transaction design, introduces Blueprints alongside Snapshots, and lists concrete file-level insertion points grounded in the current codebase.

## Goal

Two outcomes, one system:

1. **Restart recovery.** After `c11` quits or the machine reboots, every workspace returns to the shape it had, with agents (`cc`, `codex`, `opencode`) resumed inside their prior context instead of starting fresh shells.
2. **Declarative workspaces.** Operators or agents can hand-author a workspace layout in markdown (a *Blueprint*), check it into a repo, and spawn it with `c11 workspace new --blueprint <path>`. Layouts become shareable artifacts.

Both routes compile to the same app-side primitive (`WorkspaceApplyPlan`) executed in one transaction.

## Why this shape

### The dogfood finding (2026-04-21)

A dogfood run composed five custom workspaces by chaining CLI calls: `new-workspace`, then per pane `new-surface` / `set-title` / `set-description` / repeated `set-metadata` / `notify`, then follow-up `tree` calls to rediscover refs. The layout work itself was fast. The composition was slow and flaky — many process launches, many socket round-trips, many race windows while AppKit/SwiftUI was still attaching panes. One transient stall in a v1 handler (`notify_target`) stalled the whole batch.

The fix is structural: **the caller describes the end state; the app materializes it in one pass.** Shell choreography is the failure mode.

### Claude session resume exists but isn't used

`claude --resume <id>` rehydrates full history. Nobody uses it because nobody tracks the ids. c11 already captures the id on every `cc` launch (the grandfathered `Resources/bin/claude` wrapper mints `--session-id <uuid>`; `c11 claude-hook session-start` persists it). We just need to route it through restart.

### Tier 1 persistence is already shipped

`Sources/SessionPersistence.swift` auto-saves an `AppSessionSnapshot` every 8s to `~/Library/Application Support/c11mux/session-<bundleId>.json`. Layouts, metadata, status pills, scrollback all round-trip today. What's missing is the agent resume step on restart.

## Principle check (unchanged from prior revision)

- **Unopinionated about the terminal.** Writes only to c11-scoped paths: `~/.cmux-snapshots/` (Snapshots), `.cmux/blueprints/` + `~/.config/cmux/blueprints/` (Blueprints). Does not write to `~/.claude/settings.json`, `~/.codex/*`, or shell rc files.
- **Observe-from-outside session capture.** The Claude SessionStart hook is **operator-installed**, documented in the `c11` skill. c11 does not install it. `Resources/bin/claude` is a grandfathered exception, not a pattern to extend.
- **Automation as first-class consumer.** Bounded, inspectable, structured, fast.

## Verified preconditions

- `cc --resume <id>` works (cc is a shell alias; flags pass through).
- `claude` SessionStart hook receives `session_id` on stdin JSON (`source`, `cwd`, `model` also).
- `terminal_type = claude-code` is already written to surface manifests (`SurfaceMetadataStore`).
- Tier 1 layout persistence already round-trips workspaces, panes, split tree, titles, metadata, status pills, git state, and (truncated) scrollback.

## Architecture

### Core primitive: `WorkspaceApplyPlan`

A declarative value type describing the end state of a workspace.

```swift
struct WorkspaceApplyPlan: Codable {
    var workspace: WorkspaceSpec
    var layout: LayoutTreeSpec            // nested split tree
    var surfaces: [SurfaceSpec]           // referenced from LayoutTreeSpec via SurfaceSpec.id
}

struct WorkspaceSpec: Codable {
    var title: String?
    var cwd: String?
    var customColor: String?
    var metadata: [String: JSONValue]
}

indirect enum LayoutTreeSpec: Codable {
    case pane(PaneSpec)
    case split(SplitSpec)
}

struct PaneSpec: Codable {
    var id: String                         // plan-local id
    var surface_ids: [String]              // tab order inside the pane
    var selected_surface: String?
    var metadata: [String: JSONValue]      // pane-level metadata
}

struct SplitSpec: Codable {
    var orientation: SplitOrientation      // horizontal | vertical
    var divider_position: Double           // 0.0–1.0
    var first: LayoutTreeSpec
    var second: LayoutTreeSpec
}

struct SurfaceSpec: Codable {
    var id: String                         // plan-local id
    var type: SurfaceType                  // terminal | browser | markdown
    var title: String?
    var description: String?
    var cwd: String?
    var command: String?                   // terminal: initial command sent after shell is ready
    var url: String?                       // browser
    var file: String?                      // markdown
    var metadata: [String: JSONValue]      // surface metadata (incl. restart-registry keys like agent.claude.session_id)
}
```

**Relationship to existing types.** `LayoutTreeSpec` is the same shape as `SessionWorkspaceLayoutSnapshot` in `Sources/SessionPersistence.swift:360-428`. We keep them as separate types (different roles: snapshot state vs. apply plan) but the conversion is a mechanical map. A single helper on `TabManager` builds a `WorkspaceApplyPlan` from the live state of a workspace; Snapshot = persisted `WorkspaceApplyPlan` on disk.

### Executor: `WorkspaceLayoutExecutor`

New file: `Sources/WorkspaceLayoutExecutor.swift`.

```swift
@MainActor
enum WorkspaceLayoutExecutor {
    static func apply(
        _ plan: WorkspaceApplyPlan,
        to tabManager: TabManager,
        options: ApplyOptions
    ) async -> ApplyResult
}

struct ApplyOptions {
    var waitForReadiness: ReadinessLevel   // created | attached | rendered | ready
    var deadline: Duration                 // bounded wait (ties in with C11-7)
    var debugTimings: Bool
}

struct ApplyResult {
    var workspace_ref: WorkspaceRef
    var pane_refs: [String: PaneRef]       // plan-local id -> live ref
    var surface_refs: [String: SurfaceRef] // plan-local id -> live ref
    var timings: [StepTiming]
    var warnings: [String]
    var partial_failure: PartialFailure?   // which step failed + what was created up to that point
}
```

Execution order:

1. **Allocate workspace.** `tabManager.addWorkspace(workingDirectory:initialTerminalCommand:...)` from `Sources/TabManager.swift:1138`. `initialTerminalCommand` stays nil here — commands flow through `SurfaceSpec.command`.
2. **Build layout tree.** Walk `LayoutTreeSpec` depth-first. For a `.pane`, the current root panel is it. For a `.split`, call `workspace.newTerminalSplit`/`newBrowserSplit`/`newMarkdownSplit` (or a generalized internal split operation) to subdivide. The workspace starts with a single pane; we use it as the left/top of the first split, recurse on right/bottom.
3. **Create surfaces per pane.** For each pane, apply the first surface to the existing panel's surface, then add extras as new tabs inside the pane. `Workspace.swift` has the machinery; we thread through it without going out to a socket.
4. **Write metadata at creation time.** `SurfaceMetadataStore.shared.set(workspaceId:surfaceId:...)` and `PaneMetadataStore.shared.set(...)` directly — no round-trip through `c11 set-metadata`. Title/description use their existing typed setters so the store's revision bump + autosave hash update fires correctly (`SessionPersistence.swift:2789+`).
5. **Dispatch restart commands.** For each terminal surface with `metadata["agent.claude.session_id"]`, send `cc --resume <id>\n` via the existing terminal-write path *after* the shell reports ready. Fallback table:

   ```
   claude-code + session_id    -> cc --resume <id>
   claude-code                 -> cc
   codex + session_id          -> codex resume <id>
   codex                       -> codex resume --last
   opencode + session_id       -> opencode -s <id>
   opencode                    -> opencode -c
   (unknown)                   -> SurfaceSpec.command, if any
   ```

   JSONL-missing check: if `~/.claude/projects/<cwd-slug>/<id>.jsonl` doesn't exist, fall back to fresh `cc` and record a warning.
6. **Return `ApplyResult`** with per-step timings and all refs. Partial failure returns which step failed and which refs were created up to that point.

### Socket + CLI surface

New v2 socket method in `Sources/TerminalController.swift` (add near the `v2WorkspaceCreate` handler at ~line 2065):

```
workspace.apply(plan: WorkspaceApplyPlan, options: ApplyOptions)
  -> { workspace_ref, pane_refs, surface_refs, timings, warnings, partial_failure? }
```

New CLI commands (`CLI/c11.swift`):

```
c11 workspace apply --file <path>                     # Phase 0 debug surface
c11 workspace new --blueprint <path>                  # Phase 2
c11 workspace export-blueprint --workspace <ref> --out <path>   # Phase 2
c11 snapshot [--workspace <ref> | --all]              # Phase 1
c11 restore <snapshot-id-or-path>                     # Phase 1
c11 list-snapshots                                    # Phase 1
```

CLI sends one structured request. The app handles creation, lifecycle waiting, metadata, and ref assignment internally. **CLI never loops over low-level primitives.**

### Snapshots

Snapshot writer (`c11 snapshot`):

- Walks live workspaces (single or `--all`) via `TabManager` state.
- Calls `WorkspaceApplyPlan.capture(from: workspace)` — a helper that converts live state into a plan, reading `SurfaceMetadataStore` / `PaneMetadataStore` for sidecars and splitting the live bonsplit tree into `LayoutTreeSpec`.
- Embeds `agent.claude.session_id` (and future `agent.codex.session_id` / `agent.opencode.session_id`) into `SurfaceSpec.metadata`.
- Writes JSON to `~/.cmux-snapshots/<name>.json`. Atomic write.

Snapshot reader (`c11 restore <name>`):

- Loads JSON → `WorkspaceApplyPlan` → hands to `WorkspaceLayoutExecutor.apply`.
- Nothing restore-specific beyond the loader. The restart registry lives in the executor, so Blueprints inherit identical resume semantics.

### Blueprints

Phase 2. Markdown + YAML frontmatter → parser → `WorkspaceApplyPlan`. Example:

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

Parser TBD in Phase 2 once Phase 0/1 are shipped and we have a working executor to target.

### Claude session id capture

Today (already shipped): the grandfathered `Resources/bin/claude` wrapper mints `--session-id <uuid>` on every `cc` launch. `c11 claude-hook session-start` (`CLI/c11.swift:2403`, handler at `:12198`) persists `{session_id, cwd, summary}` to `~/.cmuxterm/claude-hook-sessions.json` keyed by `(workspaceId, surfaceId)`.

Phase 1 addition: the same handler also writes `agent.claude.session_id` into `SurfaceMetadataStore.shared`. Then the Tier 1 autosave (which already round-trips that store) carries the id through restart for free. The CLI-backed hook is the observe-from-outside seam — c11 app code does not install hooks in tenant tools.

For codex/opencode, the `c11` skill teaches agents to call `c11 set-metadata --key agent.session_id --value <id>` from their own lifecycle. c11 never installs hooks in their tool directories.

## Restart behavior end-to-end

Boot path on app launch:

1. `AppDelegate` loads `AppSessionSnapshot` from `~/Library/Application Support/c11mux/session-<bundleId>.json` and calls `tabManager.restoreSessionSnapshot` (`Sources/TabManager.swift:5173`). Layout, metadata, status pills, scrollback come back (as today).
2. **New in Phase 1:** after each workspace is reconstructed, the restore path iterates surfaces, reads `agent.*.session_id` from metadata, and dispatches the matching restart command through the restart registry once the shell reports ready.
3. Warnings (missing JSONL, unknown terminal_type with no command) surface in the sidebar log so the operator sees what didn't resume.

Behind an env flag (`C11_SESSION_RESUME=1`) for one release; on-by-default after.

## Algorithm notes

### Tree reconstruction

The prior revision walked `split_path` breadcrumbs from a flat pane list. With nested `LayoutTreeSpec`, reconstruction is a straight recursive descent — no breadcrumb accounting. The shape matches `SessionWorkspaceLayoutSnapshot` which we already round-trip, so this is well-trodden.

### Divider ratios

`SplitSpec.divider_position` carries the target ratio at 0.0–1.0. After the tree is fully built, walk once and `resize-pane` any split whose actual ratio diverges by more than ~2%. Done in the executor, not as post-hoc CLI calls.

### Edge cases

- **JSONL missing.** Stat `~/.claude/projects/<cwd-slug>/<id>.jsonl` before dispatching `cc --resume`; fall back to fresh `cc` with a sidebar warning.
- **Multi-cc in one workspace.** Each surface dispatches independently; the executor doesn't wait for one before moving on.
- **Unknown terminal_type.** No restart command. Respect `SurfaceSpec.command` if present; else leave the shell.
- **Shell send ordering.** Don't send restart commands until the PTY has reported ready. The executor tracks per-surface readiness, not a global barrier.
- **User disabled the hook.** Snapshots still round-trip layout + cwd + scrollback; only the cc rehydrate is skipped. Record a warning on restore.

## Open questions

1. **`WorkspaceLayoutExecutor` vs extending `TabManager`.** The executor is a separate file for testability and to keep `TabManager` focused. Lean: separate. Revisit if the executor ends up mostly calling `TabManager` private helpers — in that case merge it in.
2. **Readiness model.** `created | attached | rendered | ready` is the proposed four-state model. Phase 0 can ship with just `created | ready` if we don't yet need the middle states; expand later when the executor is wired into welcome quad and the intermediate states start mattering.
3. **Blueprint vs snapshot capture format divergence.** Phase 2 decides: do Blueprints author-facing omit fields that Snapshots carry (e.g. exact window pixel sizes)? Lean yes — Blueprints are abstract, Snapshots are exact. Both serialize to `WorkspaceApplyPlan` but the blueprint parser fills in defaults for omitted fields.
4. **Auto-snapshot cadence.** Tier 1 autosave covers 8s cadence for layout/metadata. A separate `~/.cmux-snapshots/` auto-cadence (e.g. daily) is deferred — operators can cron a manual `c11 snapshot` for now.

## Phased rollout

### Phase 0 — executor + v2 method (no user-facing feature yet)

**Scope.** Land the primitive and prove it works. No Blueprints, no Snapshots, no restart registry.

**Deliverables.**
- New types in a new file `Sources/WorkspaceApplyPlan.swift` (or appended to `SessionPersistence.swift` if the team prefers colocating snapshot-adjacent types).
- New file `Sources/WorkspaceLayoutExecutor.swift` with `apply(plan:to:options:) async -> ApplyResult`.
- v2 socket method `workspace.apply` wired in `Sources/TerminalController.swift` near the existing `v2WorkspaceCreate` handler (~line 2065). Runs off-main per socket threading policy; only the executor's AppKit mutations hop to main.
- CLI: `c11 workspace apply --file <path>` debug command.
- Re-express `WelcomeSettings.performQuadLayout` (`Sources/c11App.swift:3932-3995`) through the executor — proves general applicability. Keep a feature flag to revert if regressions appear.
- Unit test: plan in → expected workspace shape out.
- Regression fixture: build a 5-workspace mixed fixture as a test (terminal + browser + markdown + titles + descriptions + metadata). Target ~2s on a dev machine. Rides on C11-7's stress fixture.

**Exit criteria.** Executor materializes arbitrary mixed workspaces in one app-side pass. Welcome quad flows through the executor with no behavior change.

### Phase 1 — Snapshots + `cc --resume` restart registry

**Scope.** `c11 snapshot`, `c11 restore`, `c11 list-snapshots`. Terminal surfaces. Claude session resume.

**Deliverables.**
- `WorkspaceApplyPlan.capture(from:)` — walks live workspace state to build a plan.
- CLI: `c11 snapshot`, `c11 restore`, `c11 list-snapshots`.
- Restart registry inside the executor (cc-only in this phase).
- Claude hook handler (`CLI/c11.swift:12198+`) writes `agent.claude.session_id` into `SurfaceMetadataStore`.
- Boot-time restore path in `AppDelegate`/`TabManager` dispatches restart commands.
- JSONL-missing fallback + sidebar warning.
- Env-flag opt-in (`C11_SESSION_RESUME=1`).

**Exit criteria.** Restart c11 → all `cc` panels come back with history rehydrated.

### Phase 2 — Blueprints + picker + exporter

- Blueprint markdown schema + parser.
- `c11 workspace new --blueprint <path>`.
- New-workspace picker (per-repo → per-user → built-in, recency-sorted).
- `c11 workspace export-blueprint --workspace <ref> --out <path>`.

### Phase 3 — browser/markdown surfaces + `--all`

- Extend Snapshot capture + restore to non-terminal surfaces.
- Extend Blueprint schema to cover browser/markdown.
- `c11 snapshot --all`.

### Phase 4 — skill docs + hook snippet

- "Session resume" section in `~/.claude/skills/c11/SKILL.md` (or the checked-in version).
- Document `agent.*.session_id` metadata convention.
- Document the operator-install SessionStart hook snippet.

### Phase 5 — codex / kimi / opencode registry rows

- Restart commands per agent type.
- Agents self-report via `c11 set-metadata` from the skill.

## Insertion-point map (for implementation)

| Concern | File | Notes |
|---|---|---|
| Welcome quad | `Sources/c11App.swift:3932-3995` | `WelcomeSettings.performQuadLayout` — Phase 0 re-expresses through executor |
| Workspace allocator | `Sources/TabManager.swift:1138` | `addWorkspace(workingDirectory:initialTerminalCommand:...)` |
| Split creation | `Sources/Workspace.swift` | `newTerminalSplit`, `newBrowserSplit`, `newMarkdownSplit` |
| Surface metadata | `Sources/SurfaceMetadataStore.swift:63` | Direct writes from executor; revision bump drives autosave |
| Pane metadata | `Sources/PaneMetadataStore.swift:22` | Symmetric with surface |
| v2 socket routing | `Sources/TerminalController.swift:~2065` | Add `workspace.apply` near `v2WorkspaceCreate` |
| v1 legacy | `Sources/TerminalController.swift:1683-1685, 13516-13526` | `DispatchQueue.main.sync` path — C11-7 audits these |
| Session persistence (today) | `Sources/SessionPersistence.swift:360-428, 462+` | `SessionWorkspaceLayoutSnapshot`, `AppSessionSnapshot` — related shape |
| Autosave trigger | `Sources/AppDelegate.swift:3414-3462` | 8s tick; `saveSessionSnapshot` |
| Restore on launch | `Sources/TabManager.swift:5173` | `restoreSessionSnapshot(_:)` — Phase 1 dispatches restart commands after |
| Scrollback replay | `Sources/SessionPersistence.swift:534` | `SessionScrollbackReplayStore`, `CMUX_RESTORE_SCROLLBACK_FILE` |
| Claude hook CLI | `CLI/c11.swift:2403-2410` | `c11 claude-hook session-start` entry |
| Claude hook handler | `CLI/c11.swift:12198-12237` | Phase 1 adds `SurfaceMetadataStore` write here |
| Grandfathered wrapper | `Resources/bin/claude` | Already mints `--session-id <uuid>`. Don't generalize. |

## Acceptance criteria

- One `workspace.apply` call materializes a 5-workspace mixed fixture (terminal + browser + markdown + metadata + titles + descriptions) in ~2s on a dev machine, or fails fast with a named timeout.
- Executor returns per-step timings in debug output.
- Every readiness wait is bounded and named in the error.
- Welcome quad uses the executor with no visible behavior change.
- Phase 1: restart → all `cc` panels rehydrate their session; missing JSONL triggers fallback + warning, not a broken terminal.
- No `workspace.apply` or restart-registry code shells out through the socket to an existing CLI command.

## Dependencies (C11-7)

CMUX-37 depends on but does not absorb:

- Bounded CLI waits by default.
- Named timeout errors (method + refs + socket path + elapsed).
- `C11_TRACE=1` per-command start/end/timing.
- `c11 notify` migrated to v2.
- Audit of risky `DispatchQueue.main.sync` socket handlers.
- Deadline-aware main-actor bridge.

Start Phase 0 of CMUX-37 after C11-7 has landed bounded waits and v2 `notify`; the rest of C11-7 can run parallel.

## Supersedes / preserves

- Supersedes **CMUX-4** (manual Claude session index) — hook-driven metadata write replaces discovery/disambiguation logic.
- Supersedes **CMUX-5** (recovery UI banner) — new-workspace picker + restart registry.
- Preserves **CMUX-11** pane manifests and **CMUX-14** lineage chains verbatim via the metadata pass-through.

## Prior art

- `sanghun0724/cmux-claude-skills` — private session JSON + spinner-char detection + fuzzy ID matching. Right idea, heuristic-heavy implementation. We use the public manifest.
- `drolosoft/cmux-resurrect` (crex) — community save/restore for upstream `manaflow-ai/cmux`, adjacent design (Markdown blueprints + watch daemon + template gallery). Inspired the Blueprint/Snapshot split. c11 keeps the primitive narrower; templates/REPL/daemon stay ecosystem territory.
