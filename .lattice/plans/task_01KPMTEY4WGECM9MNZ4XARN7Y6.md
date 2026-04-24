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

---

## Phase 0 Implementation Plan (2026-04-24)

*Agent:* `agent:claude-opus-4-7-cmux-37-plan`. Scope is the `WorkspaceApplyPlan` value type and the app-side `WorkspaceLayoutExecutor` only — no Blueprints, Snapshots, restart registry, or CLI sugar beyond the one debug entry point. Later phases build on top.

### 1. Value types

All new types live in a single new file **`Sources/WorkspaceApplyPlan.swift`**, with small extensions added to existing stores where noted. Types are `Codable, Sendable, Equatable` unless noted.

**Reuse `PersistedJSONValue` as the metadata value flavor.** It already exists at `Sources/PersistedMetadata.swift:10` with the exact shape we need (`string | number | bool | array | object | null`), already round-trips through `PaneMetadataStore` and `SurfaceMetadataStore` via the `PersistedMetadataBridge` at `Sources/PersistedMetadata.swift:77-307`, and already composes with `SessionWorkspaceLayoutSnapshot` at `Sources/SessionPersistence.swift:331` / `:379`. Introducing a second JSON flavor would force a conversion layer at exactly the boundaries that are load-bearing for the executor. Per the C11-13 alignment doc (`docs/c11-13-cmux-37-alignment.md`:49-55) **v1 only writes `.string(...)` values**; the executor fails fast with a typed warning on non-string values in reserved pane keys, but the codable shape stays JSON-complete so v1.1+ can ship structured values without a schema migration. No new `JSONValue`/`AnyCodable` — if the codebase later grows a canonical alias, `typealias WorkspaceJSONValue = PersistedJSONValue` is the follow-up.

```swift
// Sources/WorkspaceApplyPlan.swift

struct WorkspaceApplyPlan: Codable, Sendable, Equatable {
    var version: Int                    // Phase 0 ships `1`; bumped on breaking schema changes
    var workspace: WorkspaceSpec
    var layout: LayoutTreeSpec          // nested, mirrors SessionWorkspaceLayoutSnapshot
    var surfaces: [SurfaceSpec]         // keyed by SurfaceSpec.id; referenced from LayoutTreeSpec leaves
}

struct WorkspaceSpec: Codable, Sendable, Equatable {
    var title: String?                  // becomes Workspace.customTitle via setCustomTitle (Sources/Workspace.swift:5383+)
    var customColor: String?            // hex, e.g. "#C0392B" — matches Workspace.customColor at :4976
    var workingDirectory: String?       // passed to TabManager.addWorkspace (Sources/TabManager.swift:1139)
    /// Operator-authored workspace-level metadata. Matches the existing
    /// `SessionWorkspaceSnapshot.metadata: [String: String]?` shape at
    /// `Sources/SessionPersistence.swift:447`. Strings-only per C11-13 alignment.
    var metadata: [String: String]?
}

enum SurfaceSpecKind: String, Codable, Sendable, Equatable {
    case terminal
    case browser
    case markdown
}

struct SurfaceSpec: Codable, Sendable, Equatable {
    var id: String                      // plan-local stable id, referenced from LayoutTreeSpec.pane.surfaceIds
    var kind: SurfaceSpecKind
    var title: String?                  // applied via setPanelCustomTitle (Sources/Workspace.swift:5854)
    var description: String?            // applied via SurfaceMetadataStore key "description" (reserved; Sources/SurfaceMetadataStore.swift:143-152)
    var workingDirectory: String?       // terminal: passed to newTerminalSurface/newTerminalSplit
    var command: String?                // terminal: sent via TerminalPanel.sendText after surface ready
    var url: String?                    // browser: passed to newBrowserSplit(url:)/newBrowserSurface(url:)
    var filePath: String?               // markdown: passed to newMarkdownSplit(filePath:)
    /// Surface metadata — routes through SurfaceMetadataStore.setMetadata at
    /// Sources/SurfaceMetadataStore.swift:245. Writer source is `.explicit`.
    var metadata: [String: PersistedJSONValue]?
    /// Pane metadata — routes through PaneMetadataStore.setMetadata at
    /// Sources/PaneMetadataStore.swift:59. The `mailbox.*` namespace is
    /// reserved per docs/c11-13-cmux-37-alignment.md; executor writes values
    /// verbatim with source `.explicit`. Strings-only in v1; any non-string
    /// value on a `mailbox.*` key surfaces as a warning in ApplyResult.
    var paneMetadata: [String: PersistedJSONValue]?
}

/// Mirrors `SessionWorkspaceLayoutSnapshot` (Sources/SessionPersistence.swift:394-428)
/// so Phase 1 Snapshot capture is a structural copy. `SessionSplitOrientation` at
/// Sources/SessionPersistence.swift:337 and `SplitOrientation` from Bonsplit are
/// the two sides of the translation.
indirect enum LayoutTreeSpec: Codable, Sendable, Equatable {
    case pane(PaneSpec)
    case split(SplitSpec)

    private enum CodingKeys: String, CodingKey { case type, pane, split }

    struct PaneSpec: Codable, Sendable, Equatable {
        /// Plan-local surface ids referenced into `WorkspaceApplyPlan.surfaces`.
        /// Order matches tab order in the pane. At least one entry required.
        var surfaceIds: [String]
        /// Index into `surfaceIds` of the initially selected tab. Defaults to 0.
        var selectedIndex: Int?
    }

    struct SplitSpec: Codable, Sendable, Equatable {
        var orientation: Orientation
        var dividerPosition: Double     // 0...1, mirrors SessionSplitLayoutSnapshot.dividerPosition
        var first: LayoutTreeSpec
        var second: LayoutTreeSpec

        enum Orientation: String, Codable, Sendable, Equatable {
            case horizontal
            case vertical
        }
    }
}

struct ApplyOptions: Codable, Sendable, Equatable {
    /// Select + foreground the created workspace once ready. Defaults true
    /// so the debug CLI behaves like `workspace.create`. Passed through to
    /// `TabManager.addWorkspace(select:)`.
    var select: Bool = true
    /// Per-step deadline guard. If any StepTiming exceeds it, the executor
    /// writes a warning but continues — partial-failure semantics, not
    /// hard-abort. A zero value disables the guard. Default: 2_000 ms, matching
    /// the acceptance target.
    var perStepTimeoutMs: Int = 2_000
    /// Hint for the acceptance fixture: bypass the welcome/default-grid
    /// auto-spawn by calling addWorkspace(autoWelcomeIfNeeded: false).
    /// Executor always sets this to `false`; the field exists for future
    /// callers (Phase 1 restore) that may want it.
    var autoWelcomeIfNeeded: Bool = false
}

struct ApplyResult: Codable, Sendable, Equatable {
    /// Assigned workspace ref in the live ref scheme (`workspace:N`). Populated
    /// from `TabManager.workspaceRef(for:)` post-addWorkspace.
    var workspaceRef: String
    /// Parallel arrays in plan-surface-id order: the ref the executor minted
    /// for each SurfaceSpec.id. `surfaceRefs[i]` corresponds to
    /// `plan.surfaces[i].id`. Empty for any surface whose creation failed;
    /// the failure surfaces in `warnings`.
    var surfaceRefs: [String: String]   // plan-local surface id → "surface:N"
    var paneRefs: [String: String]      // plan-local surface id → "pane:N" of the pane that hosts it
    var timings: [StepTiming]
    var warnings: [String]
    /// Subset of warnings carrying a machine-readable code for later phases
    /// (Snapshot restore in particular). Strings-only in the `message` leg so
    /// the v2 socket response stays JSON-clean.
    var failures: [ApplyFailure]
}

struct StepTiming: Codable, Sendable, Equatable {
    var step: String                    // "workspace.create", "surface[main].create", "metadata.surface.write", "metadata.pane.write", "layout.split[0].create", "total"
    var durationMs: Double
}

struct ApplyFailure: Codable, Sendable, Equatable {
    var code: String                    // "surface_create_failed" | "metadata_write_failed" | "split_failed" | "unknown_surface_ref" | "mailbox_non_string_value"
    var step: String                    // matches a StepTiming.step
    var message: String
}
```

**Rationale for shape choices (cited):**

- `WorkspaceSpec.metadata: [String: String]?` matches `SessionWorkspaceSnapshot.metadata` at `Sources/SessionPersistence.swift:447` exactly — Phase 1 Snapshot restore becomes a one-line assignment.
- `SurfaceSpec.metadata` / `SurfaceSpec.paneMetadata` use `[String: PersistedJSONValue]?`, which is the same shape `SessionPanelSnapshot.metadata` (`Sources/SessionPersistence.swift:331`) and `SessionPaneLayoutSnapshot.metadata` (`Sources/SessionPersistence.swift:379`) already carry. The executor decodes via `PersistedMetadataBridge.decodeValues` (`Sources/PersistedMetadata.swift:171`) before handing the `[String: Any]` to the stores.
- `LayoutTreeSpec` mirrors `SessionWorkspaceLayoutSnapshot` keys and orientation enum so `Phase 1 Snapshot.capture` is `SessionWorkspaceLayoutSnapshot → LayoutTreeSpec` via a 20-line translator, not a rewrite.
- `ApplyResult.surfaceRefs`/`paneRefs` map plan-local ids → live refs, making Blueprint/Snapshot re-materialization straightforward in Phase 1 without leaking live UUIDs into the persisted format.

### 2. File layout

**New files:**

- `Sources/WorkspaceApplyPlan.swift` — value types (section 1). Single file, ~250 LOC including Codable boilerplate. No behavior.
- `Sources/WorkspaceLayoutExecutor.swift` — the `@MainActor` executor (section 3). ~400 LOC including diagnostics.
- `c11Tests/WorkspaceApplyPlanCodableTests.swift` — round-trip Codable tests for every value type, including a mixed-kind LayoutTreeSpec and `mailbox.*` keys in `paneMetadata`. Pure struct tests, no AppKit — runs in the existing `c11Tests` target (registered under `F1000004A1B2C3D4E5F60718` in `GhosttyTabs.xcodeproj/project.pbxproj:834`).
- `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift` — the 5-workspace acceptance fixture (section 6). Runs through the executor on a real `TabManager`; uses existing test harness patterns from `DefaultGridSettingsTests.swift` and `MetadataPersistenceRoundTripTests.swift`.
- `c11Tests/Fixtures/workspace-apply-plans/` — one JSON per workspace in the acceptance set, decoded via `JSONDecoder`. Human-readable; doubles as Phase 2 Blueprint reference material.

**Modified files:**

- `Sources/Workspace.swift` — no new split primitive. Add one internal helper `func paneIdForPanel(_ panelId: UUID) -> PaneID?` alongside `surfaceIdFromPanelId` at `Sources/Workspace.swift:5599` (the inline loop inside `newTerminalSplit` at `:7215-7223` already does this; extract it so the executor can resolve the pane of a just-created panel without re-walking). Small refactor, keeps existing call sites unchanged.
- `Sources/TabManager.swift` — add `func workspaceRef(for workspaceId: UUID) -> String?` if one doesn't already exist; otherwise reuse the v2 ref minting used by `workspace.create` at `Sources/TerminalController.swift:2066` (`v2WorkspaceCreate` is the anchor). Grep the v2 handler to find the canonical ref helper before adding a duplicate.
- `Sources/c11App.swift` at lines `3983-4040` (`WelcomeSettings.performQuadLayout`) and `4042-4141` (`DefaultGridSettings.performDefaultGrid`) — **keep today's call sites as-is** (partial migration; see section 5). Add one `// TODO(CMUX-37 Phase 0+): migrate to WorkspaceLayoutExecutor once the executor supports post-create-on-existing-workspace mode.` comment on each.
- `Sources/TerminalController.swift` — register one new v2 handler `case "workspace.apply":` in the switch starting at `Sources/TerminalController.swift:2062` (register immediately after the existing workspace commands, e.g. after `workspace.clear_metadata` at `:2101`). Handler decodes `WorkspaceApplyPlan` from params, calls `WorkspaceLayoutExecutor.apply`, returns `ApplyResult` as a JSON dict. This is the **debug/test surface only** for Phase 0; the CLI wiring (`c11 workspace apply --file <path>`) is a one-command add in `CLI/c11.swift` near the existing `workspace.create` call at `:1724` but is **optional** for Phase 0 — the acceptance fixture drives the executor through a direct call, so the socket surface can slip to Phase 1 if Impl is scope-constrained. If shipped in Phase 0, keep the CLI one-liner minimal: read file → `sendV2(method: "workspace.apply", params: [...])` → pretty-print result.

Nothing else changes. No new Swift package, no new target, no Resources changes.

### 3. Executor walk — `WorkspaceLayoutExecutor.apply(_:options:) async -> ApplyResult`

Single `@MainActor` function. Numbered steps; each wraps a timing record.

1. **Validate plan locally (no AppKit).** Walk `plan.surfaces` for duplicate `id`s, walk `plan.layout` for unknown surface id references, reject empty panes. Validation failures short-circuit to `ApplyResult` with the workspace never created; `failures` names the bad id. No partial workspace is ever created on a validation error. Timing step: `"validate"`.
2. **Create workspace.** Call `TabManager.shared.addWorkspace(workingDirectory: plan.workspace.workingDirectory, initialTerminalCommand: nil, select: options.select, eagerLoadTerminal: false, autoWelcomeIfNeeded: options.autoWelcomeIfNeeded)` (`Sources/TabManager.swift:1138`). Critical: **pass `autoWelcomeIfNeeded: false`** so the executor never collides with welcome/default-grid auto-spawns — those are Phase 0+5 migration targets, not executor dependencies. Capture the returned `Workspace`. Apply `plan.workspace.title` via `workspace.setCustomTitle` and `plan.workspace.customColor` via `workspace.setCustomColor` (existing setters at `Sources/Workspace.swift:6019+`). Timing step: `"workspace.create"`.
3. **Apply workspace-level metadata.** For each `(key, value)` in `plan.workspace.metadata`, mirror whatever persistence path `SessionWorkspaceSnapshot.metadata` uses today (confirmed via `Sources/SessionPersistence.swift:447` round-trip; if it's a dedicated setter, call it — if it's direct dictionary assignment on `Workspace`, proxy through a new `Workspace.setOperatorMetadata(key:value:)` helper that mirrors `setPanelCustomTitle`'s shape). Timing step: `"metadata.workspace.write"`.
4. **Seed root pane with the first leaf's initial surface.** `TabManager.addWorkspace` always creates a seed `TerminalPanel` in a single root pane. Walk `plan.layout` and find the first leaf (`LayoutTreeSpec.pane`); its first `surfaceId` maps onto that seed panel:
   - If the first surface is `.terminal`, **reuse** the seed. Rename via `setPanelCustomTitle` and apply metadata (step 6).
   - If the first surface is `.browser` or `.markdown`, **replace** the seed: open the target kind in the same pane via `newBrowserSurface` / `newMarkdownSurface` equivalent in-pane creation (no `newXSplit` — those create a new pane), then close the seed terminal panel. Open question in section 9.
   This keeps the invariant "one pane per LayoutTreeSpec.pane node" without an extra seed pane.
5. **Walk the layout tree and materialize splits.** Depth-first traversal. For each `LayoutTreeSpec.split` encountered:
   - Pick the "parent" panel = the tail of whatever the `first` subtree resolves to (for `split.first` we descend into `first` and remember the last panel id we created there; for `split.second` we split off that panel).
   - Call `workspace.newTerminalSplit(from: parentPanelId, orientation: split.orientation, insertFirst: false, focus: false)` (`Sources/Workspace.swift:7208`) — or `newBrowserSplit` (`:7408`) / `newMarkdownSplit` (`:7568`) depending on the first surface kind of the leaf we're creating inside the new pane. `focus: false` is mandatory — the executor does not steal focus per `CLAUDE.md` socket focus policy.
   - Apply the `split.dividerPosition` via whatever bonsplit setter already exists (grep `dividerPosition` / `divider_position` in `Sources/Workspace.swift` — likely `bonsplitController.setDividerPosition(paneId:position:)` or similar; if it doesn't exist, file a small follow-up and accept default in Phase 0).
   - For each additional `surfaceId` in the pane (`surfaceIds.count > 1`): call `workspace.newTerminalSurface(inPane:)` (`:7327`) / `newBrowserSurface` (`:7495`) / equivalent markdown in-pane create. Apply title/metadata.
   - Apply `PaneSpec.selectedIndex` via the existing tab-select path (`bonsplitController.selectTab` is the final call in both split primitives today — expose the tab id and call it).
   - Timing steps: `"layout.split[<index>].create"` per split, `"surface[<planId>].create"` per surface.
6. **Apply surface + pane metadata during creation.** Immediately after each surface's panel exists (still inside step 4/5, not as a post-hoc second pass):
   - **Surface title** (if set): `workspace.setPanelCustomTitle(panelId:title:)` at `Sources/Workspace.swift:5854`. This already writes the canonical `title` key into `SurfaceMetadataStore` (`:5872-5878`) — no double-write.
   - **Surface description** (if set): `SurfaceMetadataStore.shared.setMetadata(workspaceId: workspace.id, surfaceId: panelId, partial: ["description": trimmed], mode: .merge, source: .explicit)` — `description` is already in the reserved key set at `Sources/SurfaceMetadataStore.swift:143-152` and validates as a string.
   - **Rest of surface metadata**: for every `(key, value)` in `surfaceSpec.metadata` besides `title`/`description` (which the above two already wrote), decode via `PersistedMetadataBridge.decodeValues([key: value])` (`Sources/PersistedMetadata.swift:171`) and call `SurfaceMetadataStore.shared.setMetadata(..., mode: .merge, source: .explicit)`. Keys that collide with `title`/`description` take the explicit `metadata` value and emit an `ApplyFailure("metadata_override")` warning — the spec is ambiguous if a caller sets both.
   - **Pane metadata**: resolve the panel's hosting pane via the new `paneIdForPanel` helper (section 2 modifications). For every `(key, value)` in `surfaceSpec.paneMetadata`, decode and call `PaneMetadataStore.shared.setMetadata(workspaceId: workspace.id, paneId: paneId, partial: [key: decoded], mode: .merge, source: .explicit)` (`Sources/PaneMetadataStore.swift:59`). **v1 strings-only contract:** before decoding, if `key` matches `^mailbox\.` and `value` is not `.string`, append an `ApplyFailure("mailbox_non_string_value", ...)` warning and skip the write. The surface is still created; only the offending key is dropped. Per alignment doc `docs/c11-13-cmux-37-alignment.md:49-55`.
   - Timing steps: `"metadata.surface[<planId>].write"` and `"metadata.pane[<planId>].write"` rolled up per surface.
7. **Apply terminal initial command.** For each terminal surface where `command` is set, schedule a `sendText` via the existing `TerminalPanel.sendText` path — it already auto-queues pre-surface-ready and flushes on ready (`Sources/c11App.swift:3997-3999` documents this behavior for `performQuadLayout`). The executor does not `await` surface readiness; that's Phase 1's `readiness: ready` pass. Timing step: `"surface[<planId>].command.enqueue"`.
8. **Assemble refs.** For each `SurfaceSpec`, mint `surface:N` and `pane:N` via the same v2 ref helper `workspace.create` uses (`Sources/TerminalController.swift:2066`). Build `ApplyResult.surfaceRefs` / `paneRefs` keyed by plan-local `SurfaceSpec.id`. Mint `workspaceRef`. Timing step: `"refs.assemble"`.
9. **Return.** Emit `StepTiming("total", ...)` covering the full `apply()` duration and return `ApplyResult`.

**Partial-failure handling lives in step 5 and step 6.** A failed split (e.g., bonsplit rejects the geometry) appends an `ApplyFailure("split_failed", step: "layout.split[<i>].create", ...)`, skips the subtree rooted at that split, and continues with the next peer split. A failed metadata write appends `ApplyFailure("metadata_write_failed", ...)` but the surface stays alive. The workspace itself is **never rolled back** — leaving a partial workspace on-screen is better UX than a silent disappear, and matches today's `performDefaultGrid` truncate-on-failure behavior (`Sources/c11App.swift:4100-4116`).

### 4. Metadata write path — summary table

| Plan field | Store | API | Source | When |
|---|---|---|---|---|
| `WorkspaceSpec.metadata` | `Workspace.metadata` (matches `SessionWorkspaceSnapshot.metadata` at `SessionPersistence.swift:447`) | direct or new `Workspace.setOperatorMetadata` helper | `.explicit` | step 3, right after workspace create |
| `SurfaceSpec.title` | `SurfaceMetadataStore` key `title` | `workspace.setPanelCustomTitle` at `Workspace.swift:5854` (already writes the canonical key) | `.explicit` | step 6, during surface creation |
| `SurfaceSpec.description` | `SurfaceMetadataStore` key `description` | `SurfaceMetadataStore.shared.setMetadata(..., .merge, .explicit)` at `SurfaceMetadataStore.swift:245` | `.explicit` | step 6, during surface creation |
| `SurfaceSpec.metadata[*]` | `SurfaceMetadataStore` | `setMetadata(..., .merge, .explicit)` | `.explicit` | step 6, during surface creation |
| `SurfaceSpec.paneMetadata[*]` | `PaneMetadataStore` | `setMetadata(..., .merge, .explicit)` at `PaneMetadataStore.swift:59` | `.explicit` | step 6, during surface creation |
| `SurfaceSpec.paneMetadata["mailbox.*"]` | `PaneMetadataStore` | same as above; strings only; executor-level type guard drops non-string values with a warning | `.explicit` | step 6 |

**All writes happen during creation, not after.** No post-hoc `c11 set-metadata` round trip, no socket call loop. This matches the locked composition convention in `docs/c11-13-cmux-37-alignment.md:58-65`.

**`mailbox.*` round-trip invariant.** The executor never rewrites, normalizes, or validates `mailbox.*` keys beyond the string-value type guard. Blueprints and Snapshots can carry `mailbox.delivery = "stdin,watch"`, `mailbox.subscribe = "build.*,deploy.green"`, `mailbox.retention_days = "7"` verbatim. The executor decodes `.string(s)` → `s` and hands it to `PaneMetadataStore.setMetadata`. v1.1+ values stay strings (comma-separated lists, stringified ints) until the joint schema migration described in the alignment doc (`:49-55`).

**Strings-only contract today.** If `PaneMetadataStore` later grows native structured values, the executor's decode step (`PersistedMetadataBridge.decodeValues`) already round-trips arrays/objects — no executor change needed at that migration.

### 5. Welcome-quad / default-grid migration

**Scope call for Phase 0: design the executor so both can converge; migrate neither today.** Both call sites are load-bearing on app startup and ship with behavioral tests (`DefaultGridSettingsTests.swift`). A migration that reshapes startup sequencing risks regressions that Phase 0 isn't set up to catch (no local-run path per `CLAUDE.md`; E2E must go through `gh workflow run test-e2e.yml`). Phase 0 ships the primitive; migration lands in a follow-up.

**Welcome-quad (`Sources/c11App.swift:3983-4040`):**
- (a) Lives at `WelcomeSettings.performQuadLayout(on:initialPanel:)`, called by `TabManager.addWorkspace` indirectly via `sendWelcomeCommandWhenReady` (`TabManager.swift:1213`) once the initial Ghostty surface is ready.
- (b) **Not migrated in Phase 0.** Both call sites unchanged.
- (c) TODO comment at line 4000, above `performQuadLayout`:
  ```
  // TODO(CMUX-37 Phase 0+): express the quad as a WorkspaceApplyPlan and
  // apply via WorkspaceLayoutExecutor. The current implementation runs on an
  // already-created workspace with a live terminal panel; the executor
  // assumes workspace-creation responsibility. Migration path: extend
  // WorkspaceLayoutExecutor with an `applyTo(existing:Workspace)` overload
  // that skips step 2 and reuses the seed panel.
  ```
- (d) **Risk to startup behavior: none.** No edit to this function in Phase 0.

**Default-grid (`Sources/c11App.swift:4042-4141`):**
- (a) Lives at `DefaultGridSettings.performDefaultGrid(on:initialPanel:)`, called by `TabManager.spawnDefaultGridWhenReady` (`TabManager.swift:1290-1292`) and `AppDelegate.spawnDefaultGridWhenReady` (`AppDelegate.swift:6349-6351`).
- (b) **Not migrated in Phase 0.** Same rationale.
- (c) TODO comment at line 4082, above `performDefaultGrid`:
  ```
  // TODO(CMUX-37 Phase 0+): express the 2x2 grid as a WorkspaceApplyPlan
  // driven by DefaultGridSettings.gridSplitOperations(). Gated on the
  // apply-to-existing-workspace overload. Remote-workspace guard at
  // line 4089 must move into the executor or stay at the call site.
  ```
- (d) **Risk to startup behavior: none.** No edit to this function in Phase 0.

**Executor design bar that enables migration.** The `apply(_:options:)` signature stays creation-centric, but the internal layout walk (steps 4-5) is written against `Workspace` as an injected reference — not a freshly-minted one. Adding an `applyToExistingWorkspace(_ plan: WorkspaceApplyPlan, workspace: Workspace, seedPanel: TerminalPanel?) async -> ApplyResult` in the follow-up is purely a public-API extension, not a refactor. Phase 0's acceptance fixture validates that the creation-centric path reproduces the welcome-quad and default-grid shapes exactly (see section 6).

### 6. Acceptance fixture

**Location:** `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift`. Runs in the existing `c11Tests` target (`GhosttyTabs.xcodeproj/project.pbxproj:834`). JSON fixtures at `c11Tests/Fixtures/workspace-apply-plans/*.json`.

**Structure:** One `XCTestCase` with five `async` test methods, each materializing one `WorkspaceApplyPlan` through `WorkspaceLayoutExecutor.apply` on a real `TabManager` instance (no mocks — per `CLAUDE.md` test policy, real runtime behavior only). The five workspaces cover the matrix:

1. `welcome-quad.json` — TL terminal + TR browser + BL markdown + BR terminal; mirrors `performQuadLayout` exactly. Asserts the resulting pane tree matches a structural fingerprint.
2. `default-grid.json` — 2x2 all-terminal. Mirrors `performDefaultGrid`.
3. `single-large-with-metadata.json` — one terminal surface; surface metadata carries `{role: "driver", status: "ready", task: "cmux-37"}`; pane metadata carries `{"mailbox.delivery": "stdin,watch", "mailbox.subscribe": "build.*"}`; asserts post-apply store reads round-trip the values.
4. `mixed-browser-markdown.json` — browser + markdown side-by-side + two terminal panes below; exercises mid-tree browser/markdown creation.
5. `deep-nested-splits.json` — 4-level nested splits with mixed orientations; exercises the depth-first layout walker, dividerPosition application, and parent-panel bookkeeping.

**One consolidated acceptance test** drives the full 5-workspace set through **one loop** and asserts `sum(StepTiming.durationMs) < 2_000` for each workspace individually. This is the fixture referenced in the plan's "Performance / reliability acceptance" section (`:181-185`). Per-step timings from `ApplyResult.timings` emit as XCTest `XCTPerformanceMetric` measurements so CI can track regressions.

**Invocation under CI:** runs as part of the unit test target in `ci.yml` (the existing `c11-unit` scheme; path verified via `project.pbxproj:834-849`). **Per `CLAUDE.md` the impl agent never runs tests locally** — `xcodebuild -scheme c11-unit` is only safe for CI. UI/E2E layer runs via `gh workflow run test-e2e.yml` (workflow at `.github/workflows/test-e2e.yml:1`) with `test_filter=WorkspaceLayoutExecutorAcceptanceTests`. Validation is CI-only; the plan's impl agent commits the fixture and triggers the workflow, never runs it locally.

**Acceptance gate for CI:** the workflow's pass criterion is `total < 2_000 ms` across all five fixtures run sequentially on a clean macos-15 runner. Fail-fast: if any single fixture exceeds `ApplyOptions.perStepTimeoutMs`, the warning lands in `ApplyResult.warnings` and the XCTAssert on that fixture fails with the named step in the message.

### 7. Order of implementation (commit boundaries)

Eight commits, each leaving the tree green:

1. **Add `Sources/WorkspaceApplyPlan.swift`** with value types only. Add `WorkspaceApplyPlanCodableTests.swift` with round-trip Codable tests (including `mailbox.*` keys). No executor yet. Tree builds; tests pass in CI.
2. **Extract `Workspace.paneIdForPanel(_:)` helper** (refactor of the inline loop in `newTerminalSplit`/`newBrowserSplit`/`newMarkdownSplit` at `Sources/Workspace.swift:7215-7223` and siblings). No behavior change. One-line callers update.
3. **Add `WorkspaceLayoutExecutor.swift` skeleton** — signature + step 1 validation + step 2 workspace creation + step 3 workspace metadata. Returns a stub `ApplyResult` with only workspace-level fields populated. `paneRefs`/`surfaceRefs` empty.
4. **Implement layout walker (steps 4-5)** — seed-panel handoff, DFS traversal, split primitives, in-pane surface creation. Still no metadata writes at surface level.
5. **Implement metadata writes (step 6)** — surface + pane, including the `mailbox.*` string-value guard.
6. **Implement terminal initial command + refs assembly (steps 7-8)** — `sendText` for terminals + `surfaceRefs`/`paneRefs` minting. `ApplyResult` fully populated.
7. **Add TODO comments to welcome-quad and default-grid** (section 5). Two-file change, documentation only.
8. **Add acceptance fixture + 5 JSON plans** (`c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift` + `c11Tests/Fixtures/workspace-apply-plans/*.json`). Optional commit 8b: add `case "workspace.apply":` v2 handler in `TerminalController.swift` + minimal `c11 workspace apply --file` CLI wiring in `CLI/c11.swift`. This is the observable socket surface; can slip to Phase 1 without breaking the executor.

Each commit carries the `CMUX-37 Phase 0:` prefix and references the specific deliverable from the plan file. Per the global policy in `~/.claude/CLAUDE.md`, push on clean forward motion; open PR once commit 8 (or 8b) lands.

### 8. Alignment with C11-13

**Locked contract reaffirmed.** The executor addresses surfaces by **surface name** (via `SurfaceSpec.title` → `panelCustomTitles` → `SurfaceMetadataStore["title"]`), never by the process-local `surface:N` ref. Plan-local `SurfaceSpec.id` is a temporary handle used only during `apply()` and never persisted beyond `ApplyResult`. The `mailbox.*` namespace round-trips through `SurfaceSpec.paneMetadata` unmodified; the executor's only contribution is the strings-only type guard (alignment doc `:49-55`). `c11 mailbox configure` (C11-13's CLI) remains a separate runtime mutation path through the existing `set_metadata` socket method — **not** routed through `workspace.apply`. The executor is a creation primitive; C11-13's CLI is a post-creation mutation primitive. They share the store and the namespace, not the code path. This stays true through all of Phase 0 and does not change in later phases.

### 9. Risks / open questions

1. **Seed-panel replacement for non-terminal root leaves (step 4).** `TabManager.addWorkspace` always mints a `TerminalPanel` for the root pane (`TabManager.swift:1158-1166`). If `plan.layout` roots with a `LayoutTreeSpec.pane` whose first surface is `browser` or `markdown`, the executor must either (a) close the seed terminal and open the target kind in the same pane, or (b) add a `TabManager.addWorkspaceWithoutSeed` path. **Recommendation:** (a) in Phase 0 — simpler, no TabManager change, one extra panel mint+close per workspace. **Needs_human trigger:** only if operator wants to avoid the visible flash of the seed terminal; if so, (b) is a small TabManager change. Default to (a); reconsider if the acceptance fixture shows a visible flash.
2. **`dividerPosition` API surface.** Phase 0 plan mentions applying `split.dividerPosition` but bonsplit's divider-position setter is not yet cited in this plan. If `bonsplitController` exposes `setDividerPosition(paneId:position:)` (or equivalent), wire it; if not, Phase 0 accepts the default 50/50 and files a follow-up. **Not a blocker** — Phase 1 Snapshot restore will need it, at which point the gap is obvious.
3. **Focus behavior.** `ApplyOptions.select` defaults true so the debug CLI matches `workspace.create`. The **socket focus policy** in `CLAUDE.md` forbids non-focus-intent commands from stealing focus. `workspace.apply` is *intent-bearing* (it created the workspace), so selecting is consistent with `workspace.create`. All internal split calls pass `focus: false` and `autoWelcomeIfNeeded: false` to avoid compounding focus moves. **No human decision needed unless the Impl agent observes focus thrash during the acceptance run.**
4. **Typing-latency hot paths untouched.** `TerminalWindowPortal.hitTest()`, `TabItemView`, and `GhosttyTerminalView.forceRefresh()` are not on the executor's write path. The executor invokes existing split primitives that already respect these invariants; no new allocation or observation is added inside their bodies. This is a confirmation, not a risk — flagged explicitly because the Impl agent might be tempted to add timing breadcrumbs inside one of those paths. **Don't.** Breadcrumbs live in the executor, not inside split primitives or terminal-refresh hot loops.
5. **`c11 install <tui>` and wrapper generalization — NOT proposed.** Per `CLAUDE.md` c11-is-unopinionated-about-the-terminal principle, Phase 0 does not touch `Resources/bin/claude`, does not add per-agent wrappers, and does not write to any tenant config. `WorkspaceApplyPlan` is app-internal; the debug CLI `c11 workspace apply --file` reads from a path the operator supplies.
6. **Socket method + CLI in Phase 0 or Phase 1?** The broader plan (`:137`) lists `workspace.apply` as Phase 0. The prompt's concrete deliverable list focuses on the executor and fixture. **Recommendation:** ship the socket handler + minimal CLI (`commit 8b` above); they total ~50 LOC and give the executor an observable surface for CI or operator debugging without enlarging Phase 0 scope. If Impl time is tight, defer to Phase 1 — the acceptance fixture runs the executor directly and doesn't need the socket. **No human decision needed unless Impl pushes back.**
7. **`Workspace.setOperatorMetadata` helper — exists or new?** The plan assumes workspace-level metadata has a setter; if it's currently only written through the `SessionWorkspaceSnapshot` restore path, Impl adds a one-line helper that mirrors `setPanelCustomTitle`'s shape. **Not a blocker** — small localized change.
8. **`TabManager.workspaceRef(for:)` helper — exists or new?** Ref minting for `workspace:N` is owned by the v2 handler layer today (`TerminalController.swift:2066`). Impl should reuse that helper rather than duplicating the logic in the executor. If the helper lives inside `TerminalController`, lift it to `TabManager` or a small `V2Refs` namespace so the executor doesn't depend on the socket layer. **Not a blocker** — trivial refactor.

None of the open questions rise to a `needs_human` architectural fork. They are execution-detail calls Impl can make in-session with reasonable defaults captured above.

## Review Cycle 1 Findings (2026-04-24)

*Verdict:* **FAIL-IMPL-REWORK** from `/trident-code-review` (9-agent pack; 3-model consensus on both blockers). Same branch, no plan reshape. Scope: ~1 day walker + harness rework, ~½ day for the accompanying minor-fixes. Cycle 1 of max 3.

*Review pack:* `notes/trident-review-CMUX-37-pack-20260424-0303/` (12 files: 9 per-agent + 3 synthesis).

*What's clean (consensus — do not change):* value types + Codable round-trips; `PersistedJSONValue` reuse; `source: .explicit` throughout; `mailbox.*` strings-only guard; reserved-key routing through `setPanelCustomTitle` / canonical `setMetadata`; no typing-latency hot-path edits; no terminal-opinion creep (no `Resources/bin/claude` touch, no `c11 install <tui>`); `async` drop is clean (no trailing awaits, no spurious `Task { }` in the socket handler); 8-commit boundary hygiene; TODO comments at welcome-quad / default-grid migration sites.

### BLOCKERS (must fix to pass cycle 2)

**B1. Layout walker composes nested splits bottom-up against a leaf-only API.** `WorkspaceLayoutExecutor.materializeSplit` (`Sources/WorkspaceLayoutExecutor.swift:448-501`) splits a leaf of `split.first` to produce what should be a sibling of the whole `split.first` subtree, but bonsplit's `splitPane(_:orientation:insertFirst:)` only splits leaf panes. 4 of 5 acceptance fixtures materialize malformed trees (welcome-quad, default-grid, mixed-browser-markdown, deep-nested-splits); only `single-large-with-metadata` (no splits) escapes. This is a design-level defect — not a line edit. **Fix path:** top-down injection matching `Workspace.restoreSessionLayoutNode` (the existing idiom the `SessionWorkspaceLayoutSnapshot` restore path already uses), or outer-first two-pass preallocation. Trace-validate the new walker against welcome-quad and default-grid shapes before landing.

**B2. Acceptance harness cannot detect B1.** `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:106-147` asserts only ref-set membership + the 2_000 ms timing. No bonsplit tree-shape comparison, no divider-position check, no `selectedIndex` check, no per-fixture metadata round-trip beyond `single-large-with-metadata`. Section 6 of the plan called for structural-fingerprint assertions — they were not shipped, which is why B1 passed CI silently. **Fix path:** add structural assertions to `runFixture` that normalize `workspace.bonsplitController.treeSnapshot()` (orientation + recursive pane grouping + leaf surface-id order + divider positions + `selectedIndex`) and compare against the plan's `LayoutTreeSpec`. Extend the metadata round-trip pattern from `single-large-with-metadata` to every fixture. **Land the test first, watch all 5 fail, then ship the walker fix** — this is the TDD anchor for B1.

### IMPORTANT (fix in the same rework pass)

**I1. `SurfaceSpec.workingDirectory` silently dropped for split-created terminals and the reused seed.** At `Sources/WorkspaceLayoutExecutor.swift:361` (seed-reuse path) and `:506-537` (split path), `newTerminalSplit` has no `cwd` parameter and no `ApplyFailure` is emitted when `workingDirectory` is non-nil. Silent data loss. **Fix path:** either plumb `cwd` through `Workspace.newTerminalSplit` / `newTerminalSurface(inPane:)` / seed-reuse, or emit `ApplyFailure("working_directory_not_applied", step: ..., message: "…")` when `workingDirectory` is set and the creation path doesn't support it. First option preferred since the single-pane path already honors `workspace.workingDirectory` via `TabManager.addWorkspace`.

**I2. CLI subcommand name drift.** Impl shipped `c11 workspace-apply` at `CLI/c11.swift:1713`, but the CMUX-37 plan body (`:83`) and `docs/c11-snapshot-restore-plan.md:164` both specify `c11 workspace apply` (subcommand under `workspace`). **Fix path:** add a `c11 workspace apply` subcommand route at `CLI/c11.swift:1713` (or equivalent subcommand dispatch point) to match plan and docs. Keeping `c11 workspace-apply` as a back-compat alias is acceptable but not required — nothing else consumes it yet.

**I3. `validate(plan:)` runs on MainActor inside `v2MainSync`, contradicting the handler header's off-main promise.** `Sources/TerminalController.swift:4347-4399` + `Sources/WorkspaceLayoutExecutor.swift:63-64`. The socket-command threading policy in `CLAUDE.md` requires parse/validate off-main, with only AppKit/model mutation on main. **Fix path:** hoist the `validate(plan:)` call (and any pure decode/arg-parsing) above the `v2MainSync { … }` block in `v2WorkspaceApply` so the handler comment becomes true. Only the `apply(_:options:)` body needs the MainActor.

**I4. Silent-failure gaps (close in the same pass).**
  - **I4a.** `ApplyOptions.perStepTimeoutMs` is not enforced (Codex finding). The option exists on the struct but nothing inside the executor reads it. **Fix path:** wrap each step's timing measurement with the deadline check; on breach, append a warning with the step name and keep going (soft limit, per the plan's partial-failure semantics).
  - **I4b.** `WorkspaceApplyPlan.version` is not validated (Codex finding). Version-1 plans should be accepted; anything else should short-circuit with a typed error before any workspace is created.
  - **I4c.** `applyDividerPositions` does not emit `ApplyFailure` on tree-shape mismatch (Gemini finding). When the plan's `SplitSpec.dividerPosition` references a split slot that doesn't exist in the live bonsplit tree (because of B1 or a future divergence), it currently no-ops silently. **Fix path:** emit `ApplyFailure("divider_apply_failed", step: "layout.split[<i>].divider", message: ...)` and continue.
  - **I4d.** `validateLayout` does not detect duplicate `surfaceIds` references in `PaneSpec.surfaceIds` or across multiple `PaneSpec`s (Gemini finding). Two leaves referencing the same plan-local surface id produce undefined behavior. **Fix path:** add a duplicate-reference check to step 1 validation; emit a typed error and short-circuit before any workspace is created.

**I5. Plan file — sync the `async` signature with what shipped.** `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:58` still reads `async @MainActor func apply(…)`. Impl shipped sync because Phase 0 has no await points (verified clean by review). Update the plan sketch to match so Phase 1 agents implementing the readiness pass see the correct current shape. This is a documentation-only plan edit; it does NOT change the rework scope.

### Rework directive — order of work

Ship as a continuation of the same feature branch (`cmux-37/phase-0-workspace-apply-plan`). Commits carry the `CMUX-37 Phase 0 (rework):` prefix.

1. **Commit R1 — structural-assertion harness (lands first).** Rewrite `c11Tests/WorkspaceLayoutExecutorAcceptanceTests.swift:runFixture` to normalize `bonsplitController.treeSnapshot()` and compare against the plan `LayoutTreeSpec`. Extend metadata round-trip to every fixture. Push. CI should fail all 5 fixtures (expected — this is the TDD anchor).
2. **Commit R2 — walker top-down rewrite.** Replace `materializeSplit` with a top-down injection / outer-first two-pass strategy modeled on `Workspace.restoreSessionLayoutNode`. Trace-validate welcome-quad + default-grid shapes in-source before pushing. CI now passes all 5 fixtures.
3. **Commit R3 — plumb `SurfaceSpec.workingDirectory`.** Either through split primitives or via `ApplyFailure` emission when unsupported. Add a fixture that exercises `workingDirectory` on a split-created terminal.
4. **Commit R4 — CLI subcommand rename.** Add `c11 workspace apply` route. Alias retained or removed per Impl judgment.
5. **Commit R5 — off-main validate.** Hoist `validate(plan:)` above `v2MainSync` in `v2WorkspaceApply`.
6. **Commit R6 — silent-failure gaps.** I4a (`perStepTimeoutMs` enforcement), I4b (`version` validation), I4c (`divider_apply_failed` warning), I4d (duplicate-ref check). Extend existing Codable/validation tests with cases for each.
7. **Commit R7 — plan file sync.** Edit `.lattice/plans/task_01KPMTEY4WGECM9MNZ4XARN7Y6.md:58` to match the shipped sync signature. One-line documentation edit.

After R7 lands and is pushed, the rework Impl agent posts the completion comment on CMUX-37 and the delegator spawns Trident cycle 2 on the new branch head.
