# CMUX-37 — Final close-out PR

**Ticket:** CMUX-37 (`task_01KPMTEY4WGECM9MNZ4XARN7Y6`)
**Branch:** `cmux-37/final-push` (off `origin/main`)
**Worktree:** `/Users/atin/Projects/Stage11/code/c11-worktrees/cmux-37-final-push`
**Builds on:** PR #75 (Phase 0 primitive — `WorkspaceApplyPlan` + `WorkspaceLayoutExecutor`), PR #79 (Phases 2–5 in JSON: snapshot/restore, list, workspace new/apply/export-blueprint, browser/markdown round-trip, agent registry rows).
**Last refreshed:** 2026-05-03 by `agent:claude-opus-4-7-cmux-37-plan`.
**Ground truth for what's missing:** `/tmp/cmux-37-smoke-report.md` (2026-05-03 smoke pass on tagged build `cmux-37-smoke`, c11 0.44.1). Anything beyond what that report names is out of scope unless directly required to land the listed fixes.

> **Read me first.** The active plan is this section. Everything below `---` is historical context retained from the pre-final-push iterations of this ticket; do not redo it. Phases 0 through 5 already shipped via PRs #75 and #79.

## Goal

One cohesive PR that closes CMUX-37 by landing the five gaps surfaced in the 2026-05-03 smoke validation. No follow-up tickets for in-scope items. Operator framing: *"This has been an albatross — close it."*

## Scope (in)

Five workstreams, all in one PR.

### 1. Markdown blueprint format

**Why:** the original ticket and operator both call for blueprints to live next to operator notes (Obsidian-friendly), hand-editable. PR #79 shipped JSON only.

**Schema** (operator-approved, from delegator prompt):

````markdown
---
title: Agent Room
description: Three-pane orchestration layout
custom_color: "#9D8048"
---

# Agent Room

Free-form prose body. Renders nicely in Obsidian. Parser ignores it.

## Layout

```yaml
layout:
  - direction: horizontal
    split: 50/50
    children:
      - type: terminal
        title: Main terminal
        cwd: ~/Projects/Stage11/code/c11
      - direction: vertical
        split: 60/40
        children:
          - type: browser
            title: Lattice
            url: http://localhost:8799/
          - type: markdown
            title: Notes
            file: ~/notes/today.md
```
````

**Files to touch:**

- **New:** `Sources/WorkspaceBlueprintMarkdown.swift` — pure parser + writer. Two entry points: `parse(_ data: Data) throws -> WorkspaceBlueprintFile` and `serialize(_ file: WorkspaceBlueprintFile) throws -> Data`. No AppKit. Tests inject a `Foundation`-only world.
- **Edit:** `Sources/WorkspaceBlueprintFile.swift:7` — leave the envelope alone; markdown parsing produces the same `WorkspaceBlueprintFile` value.
- **Edit:** `Sources/WorkspaceBlueprintStore.swift` — `read(url:)` already accepts `.json` and `.md` discovery (`blueprintURLs` at L185 picks both extensions). Make `read(url:)` and `indexEntries` (L207) dispatch on extension. For `.md` files, parse via the new module instead of `JSONDecoder`. Add a `write(_:to:)` overload that writes markdown when the URL has `.md` extension.
- **Edit:** `Sources/TerminalController.swift:4577` (`v2WorkspaceExportBlueprint`) — change `dir = .config/cmux/blueprints` (L4607) to `.config/c11/blueprints`. Rename file extension from `.json` to `.md` by default. Add a `--format json` opt-out (CLI side) for callers who want the legacy shape; default is markdown. **Back-compat read** at L4607: keep listing the old `~/.config/cmux/blueprints/` path so blueprints written by 0.44.x still appear in the picker.
- **Edit:** `CLI/c11.swift:2866` (`runWorkspaceBlueprintNew`) — when reading a blueprint by `--blueprint <path>`, sniff extension. For `.md`, call the new parser; for `.json`, keep the existing `JSONSerialization` path.
- **Edit:** `CLI/c11.swift:3021` (`runWorkspaceExportBlueprint`) — accept `--format json|md` (default `md`); pass through to v2 method as a param. Print the `.md` path on success.
- **Edit:** `Sources/WorkspaceBlueprintStore.swift:62` (`perRepoBlueprintURLs`) — also walk `.c11/blueprints/` in addition to `.cmux/blueprints/` for repo-local discovery; no rename here, just a parallel directory.

**Round-trip story:** `c11 workspace export-blueprint --name foo --workspace workspace:1` writes `~/.config/c11/blueprints/foo.md`. `c11 workspace new --blueprint ~/.config/c11/blueprints/foo.md` materializes a workspace with the same shape. `c11 workspace new` (no args) shows `foo` in the picker alongside built-ins.

**Test:** round-trip via the new parser at the value level (export plan → serialize to .md → parse → compare equality on `WorkspaceApplyPlan`). Plus one CLI-end-to-end via `tests_v2/` driving a tagged-build socket: build a known mixed layout, export to .md, materialize from that .md into a fresh workspace, assert via `c11 tree --json` that the surface count, types, titles, and split structure match.

### 2. Snapshot manifest layer for `--all`

**Why:** the smoke report's biggest contract miss. `c11 snapshot --all` writes N independent per-workspace files but no combined entity. Operator wants "save the whole c11" without re-architecting the per-workspace primitive.

**Approach:** keep the per-workspace files unchanged (no data duplication). Add a sibling **manifest** file at `~/.c11-snapshots/sets/<ulid>.json` listing the inner snapshot ids with set-level metadata:

```json
{
  "version": 1,
  "set_id": "01KQ...",
  "created_at": "2026-05-03T16:15:38.000Z",
  "c11_version": "0.44.1+95",
  "selected_workspace_index": 1,
  "snapshots": [
    {"workspace_ref": "workspace:1", "snapshot_id": "01KQ...", "order": 0},
    {"workspace_ref": "workspace:2", "snapshot_id": "01KQ...", "order": 1, "selected": true},
    ...
  ]
}
```

**Files to touch:**

- **New:** `Sources/WorkspaceSnapshotSet.swift` — value type `WorkspaceSnapshotSetFile` mirroring `WorkspaceSnapshotFile`'s shape. Pure Codable; no AppKit.
- **Edit:** `Sources/WorkspaceSnapshotStore.swift:46` (`defaultDirectory`) — keep, then add `defaultSetsDirectory()` returning `~/.c11-snapshots/sets/`. Add `writeSet(_:)` and `readSet(byId:)` mirroring the existing single-snapshot path. `list()` adds a `listSets()` sibling. The `enumerate(directory:source:)` private helper (L324) recursively only reads top-level `.json`; the `sets/` subdirectory is naturally excluded since `contentsOfDirectory` is non-recursive — confirm in implementation.
- **Edit:** `Sources/TerminalController.swift:4644` (`v2SnapshotCreate`) — when `params["all"] == true` (L4662), after writing N per-workspace snapshots, also build a `WorkspaceSnapshotSetFile` listing them and write via `store.writeSet(_:)`. Append `set_id` and `set_path` to the response. Track `tabManager.selectedTabIndex` (or equivalent) at capture time so the manifest records which workspace was selected.
- **Edit:** `Sources/TerminalController.swift:2115` (`snapshot.create`) plus a new dispatch case `snapshot.restore_set` at the same site (L4715-ish, next to `v2SnapshotRestore`). Restore-set walks the manifest and applies each inner snapshot in order via the existing `WorkspaceLayoutExecutor`. Re-establishes selection at the end (best-effort; honors `select: true` via the executor option already in use).
- **Edit:** `CLI/c11.swift:1900` (`case "restore"`) — make `c11 restore <id>` polymorphic. Heuristic: try `snapshot.restore` first; if the v2 handler returns `not_found` and the id resolves to a manifest under `sets/`, dispatch `snapshot.restore_set`. Or — preferred — add a stat probe in the CLI before the v2 call: if `~/.c11-snapshots/sets/<id>.json` exists, call `snapshot.restore_set`; else call `snapshot.restore`. Same v2 flag policy (`C11_SESSION_RESUME` / `--in-place`).
- **Edit:** `CLI/c11.swift:8802` (`subcommandUsage("list-snapshots")`) and `CLI/c11.swift:1913` (`case "list-snapshots"`) — add `--sets` flag that switches to listing manifests (sibling table), and `--all` flag that prints both tables back-to-back. Default unchanged.
- **Edit:** `CLI/c11.swift:8742` (`subcommandUsage("snapshot")`) — document the new `--all` behavior: writes per-workspace files **and** a manifest under `sets/`; `c11 restore <manifest-id>` rehydrates the lot.

**No data duplication invariant:** the manifest is a pointer file. Each individual snapshot stays independently restorable through the existing `c11 restore <id>` path.

**Test:** behavioral via `tests_v2/`. Build two distinct workspaces; call `snapshot --all`; assert manifest exists, references both inner ids, and that each inner id is also independently restorable. Then close both workspaces, call `restore <manifest-id>`, assert two workspaces materialize in the right order with selection re-established.

### 3. Restore diagnostic cleanup

**Why:** the smoke validator saw `restore` exit 0 but emit `failure:` lines for behaviors that are deliberate and expected. Seven failures (one `working_directory_not_applied` on the seed terminal, six `metadata_override` for title overrides — one per surface in the smoke fixture). The CLI prints these as `failure:` (`CLI/c11.swift:3297`), which scares automation that grep-greps the output.

**Two root causes — fix both at the source:**

- **Capture-side cause** (`Sources/WorkspacePlanCapture.swift`): the walker reads `surfaceMetadata()` (L137) — which contains the canonical `"title"` key — and **also** sets `SurfaceSpec.title` from `workspace.panelCustomTitles[panelId]` (L75). On restore, the executor at `Sources/WorkspaceLayoutExecutor.swift:897-914` sees both set and emits `metadata_override`. The data agrees; the duplicate is an artifact of capture, not a real override. Fix: in `WorkspacePlanCapture` line ~76, after reading `metadata`, drop `metadata["title"]` and `metadata["description"]` when their values match the canonical fields the executor will write via `setPanelCustomTitle` / the description path. Net effect: round-trip captures no longer arm the override warning.
- **Apply-side cause** (`Sources/WorkspaceLayoutExecutor.swift:653-660`): the seed-terminal cwd reuse path (`reportWorkingDirectoryNotApplicable` with context "seed terminal reuse") fires on every snapshot whose first terminal had a cwd captured. This too is expected on a restore. Fix: keep the warning text but downgrade the failure-list entry by introducing a notion of severity.

**Severity model (small, surgical):**

- **Add to `Sources/WorkspaceApplyPlan.swift:300` (`ApplyFailure`)** an optional `severity: Severity?` field with cases `.failure` (default for back-compat) and `.info`. Keep absent on the wire when default to preserve existing JSON shape.
- **Edit:** the two emission sites that the smoke report flagged (`reportWorkingDirectoryNotApplicable` for seedTerminal context at L656, and the two `metadata_override` cases at L900 and L909) — emit with `severity: .info`. Leave all other emission sites at default `.failure`.
- **Edit:** `CLI/c11.swift:2914-2918` (`runWorkspaceBlueprintNew` print loop), `CLI/c11.swift:2848-2855` (`runWorkspaceApply`), `CLI/c11.swift:3291-3298` (`runSnapshotRestore`) — when iterating `failures`, partition by severity. Print `info:` lines from `.info` items; `failure:` lines from `.failure` items. The structured payload still carries everything; only the human-readable print classifies.
- **Compromise option** (cheaper, equally valid): instead of adding a severity field, introduce a static set of "expected on round-trip" codes (`{working_directory_not_applied (seedTerminal context), metadata_override}`) in the CLI print, and reclassify them client-side. This keeps the `ApplyFailure` schema untouched. **Recommended over the severity field** because the severity is policy not data — the wire shape stays bit-exact and a future caller with a different opinion can ignore the classification. Impl agent picks; both are acceptable.

**Test:** behavioral. Run the smoke fixture (mixed 6-surface workspace, snapshot, restore) and assert `failures: 0` lines printed. The structured payload may still carry the warning entries — that's fine.

### 4. `c11 workspace <sub> --help` routing fix

**Why:** `c11 workspace new --help` prints `Unknown command 'workspace'`, despite `c11 workspace new` working. This is a help-dispatch bug.

**Root cause:** `CLI/c11.swift:1553` calls `dispatchSubcommandHelp(command, commandArgs)`; that function (L8822) calls `subcommandUsage(command)`. The case list (L7269+) has no entry for `"workspace"` — its subcommands `apply` / `new` / `export-blueprint` aren't reachable through the per-top-level-command dispatcher. Help falls through to the "Unknown command" branch at L1556.

**Fix:** add a `case "workspace":` to `subcommandUsage` that, when called with no further sub-token, prints a workspace top-level help text listing the three subcommands. When `commandArgs.first == "apply" / "new" / "export-blueprint"`, return the per-subcommand help.

**Files to touch:**

- **Edit:** `CLI/c11.swift:7269` (`subcommandUsage`) — add a `case "workspace":` branch. Inspect `commandArgs` (the function takes a single `String` today; either change the signature to `(_ command: String, _ commandArgs: [String]) -> String?` or wrap in a small dispatcher inside `dispatchSubcommandHelp` itself). Recommend changing the signature: it's a single function and both call sites are local.
- **Edit:** `CLI/c11.swift:8822` (`dispatchSubcommandHelp`) — pass `commandArgs` through.
- **Add help text** for: `c11 workspace`, `c11 workspace apply`, `c11 workspace new`, `c11 workspace export-blueprint`. Each documents its real flags (already known from the runners at L2853, L2866, L3021) and one usage example.
- **Edit:** `CLI/c11.swift:14328` (top-level `usage()` Commands list) — the current dump (L14347-L14418) has a sprawling alphabetical listing. Add the four `workspace …` lines; group with the other persistence commands.

**Test:** behavioral via `tests_v2/`. Run `c11 workspace --help`, `c11 workspace new --help`, `c11 workspace export-blueprint --help`, `c11 workspace apply --help`. Assert exit code 0 and stdout contains the per-subcommand `Usage:` line. (No socket needed; help is offline-only, dispatched before connect at L1548-L1558.)

### 5. CLI socket safety (`C11_SOCKET` + auto-discovery breadcrumb)

**Why:** during the smoke setup, the orchestrator set `C11_SOCKET=/tmp/c11-debug-cmux-37-smoke.sock` thinking it was the override env var. The CLI read `CMUX_SOCKET_PATH` instead, fell through to auto-discovery, picked up the operator's live socket via `last-socket-path`, and silently mutated the operator's live workspace. This is the wrong-socket disaster the operator wants permanently closed.

**Files to touch:**

- **Edit:** `CLI/c11.swift:1437` (`run()` env-var resolution at L1439-L1448). Today the loop is `for key in ["CMUX_SOCKET_PATH", "CMUX_SOCKET"]`. Change to: **read `C11_SOCKET` first**, then `CMUX_SOCKET_PATH`, then `CMUX_SOCKET` (which is already an alias). Both `CMUX_*` keys remain accepted for back-compat. **Do not** add a deprecation warning yet — that's a separate ticket per the delegator prompt.
- **Edit:** `CLI/c11.swift:1424` (`defaultSocketPath`) — same precedence change; replace `environment["CMUX_SOCKET_PATH"]` with the same fallback chain.
- **Edit:** `CLI/c11.swift:1620-1629` — the breadcrumb already fires for `socket.path.autodiscovered`, but only into telemetry. Add a stderr line, gated on `!isatty(stderr)` being false (i.e., always emit) and suppressible via `--quiet` or `C11_QUIET_DISCOVERY=1`. Format: `c11: using socket /tmp/cmux-debug.sock (auto-discovered from /tmp/cmux-last-socket-path)` — name both the picked socket and the pointer file.
- **Edit:** `CLI/c11.swift:14324` (top-level `usage()` "Socket Auth" block) — add a "Socket Path" subsection above it documenting precedence: `--socket` flag → `C11_SOCKET` → `CMUX_SOCKET_PATH` → auto-discovery. List `C11_QUIET_DISCOVERY=1` and `--quiet`.
- **Edit:** `CLI/c11.swift:163` (`init` of `CLISocketSentryTelemetry`) — the breadcrumb already records `envSocketPath` from the two CMUX-prefixed keys. Add `processEnv["C11_SOCKET"]` to the precedence in the `??` chain.

**Test:** behavioral via `tests_v2/` driving a tagged smoke build:

- `C11_SOCKET=<path> c11 ping` hits the smoke build (assert via `c11 list-workspaces` count diff, or via a sentinel `set-metadata` write).
- `CMUX_SOCKET_PATH=<path> c11 ping` also works.
- With no env var set and a stale `/tmp/cmux-last-socket-path` pointing at a smoke socket, `c11 ping` emits exactly one stderr line naming the auto-discovered path.
- `C11_QUIET_DISCOVERY=1 c11 ping` suppresses that line; stdout is unchanged.

## Out of scope / Do-NOT-ship

- **Deprecation warning for `CMUX_SOCKET_PATH`**: explicitly deferred per the delegator prompt. Both env vars accepted in this PR; no warning yet.
- **Renaming public `cmux` CLI compat alias**, historical commit identifiers, or shipped public APIs (per CLAUDE.md "Pitfalls" / "lineage").
- **Mailbox topic fan-out** (Stage 3 of C11-13). The `mailbox.*` namespace is preserved bit-exact in this PR; no schema work.
- **codex / opencode / kimi restart-registry rows.** Phase 5 of the original ticket; outside the smoke-report-driven scope.
- **Anything touching typing-latency hot paths.** Per CLAUDE.md "Pitfalls": `WindowTerminalHostView.hitTest`, `TabItemView`, `TerminalSurface.forceRefresh`. None of the five workstreams need to.
- **Persistent writes to tenant config** (`~/.claude/`, `~/.codex/`, etc). Per CLAUDE.md "Unopinionated about the terminal".
- **JSON blueprint deletion.** Read path stays (`~/.config/cmux/blueprints/`, `.cmux/blueprints/`). New writes go to `~/.config/c11/blueprints/<name>.md`. Don't restructure the JSON reader; don't remove `~/.cmux-snapshots/` legacy fallback.
- **Submodule edits.** None of the five workstreams touch `ghostty/` or `vendor/bonsplit/`. If review surfaces a Ghostty issue, surface it separately.
- **iOS Simulator / Chrome MCP usage.** This PR is text-only and CLI-driven; UI validation happens in the Validate phase via Codex computer-use against a tagged build.

## Commit grouping (8 commits, ordered)

The order matters: each commit is intended to compile and pass `xcodebuild -scheme c11-unit` on its own. Review-phase rework may consolidate, but keep this as the default.

1. **`workspace: route --help for subcommands`** — workstream 4. `subcommandUsage` signature change; new help cases for `workspace`, `workspace apply`, `workspace new`, `workspace export-blueprint`; top-level `usage()` updates. Pure CLI, no socket changes. Smallest blast radius — first.
2. **`cli: honor C11_SOCKET; log auto-discovery to stderr`** — workstream 5. `run()` env precedence, `defaultSocketPath`, breadcrumb-to-stderr gated on `C11_QUIET_DISCOVERY`/`--quiet`, top-level `usage()` Socket Path block. Pure CLI. Lands the wrong-socket fix early so subsequent validate runs cannot footgun.
3. **`executor: classify expected restore diagnostics as info`** — workstream 3 (apply-side). Whichever option the impl agent picks (severity field or CLI-side reclass). No new wire breakage.
4. **`capture: drop redundant title/description metadata to silence override warnings`** — workstream 3 (capture-side). Pure `WorkspacePlanCapture` change. Round-trip becomes clean.
5. **`blueprint: parse and write markdown format`** — workstream 1 (parser/writer). New `Sources/WorkspaceBlueprintMarkdown.swift`. `WorkspaceBlueprintStore` extension dispatching by extension. Round-trip unit test on the value level.
6. **`blueprint: c11 directory + markdown by default; legacy paths still read`** — workstream 1 (filesystem rename + CLI integration). `TerminalController` exporter writes to `~/.config/c11/blueprints/<name>.md`. CLI sniffs `.md` vs `.json` on `--blueprint` input. Picker discovers both. Add `.c11/blueprints/` to per-repo discovery.
7. **`snapshot: write manifest on --all; restore polymorphic on manifest id`** — workstream 2. New `WorkspaceSnapshotSetFile`, `writeSet`/`readSet`, manifest-aware `snapshot.create --all`, new `snapshot.restore_set` v2 method. CLI `restore <id>` polymorphism. `list-snapshots --sets`/`--all` flags.
8. **`docs/lattice: rename ticket title to c11; strip stale plan-freshness warning`** — housekeeping. Single `lattice update CMUX-37 --title "c11 workspace persistence: …"` + description trim. No code.

If localization adds strings (likely — a couple of error messages and the `--help` text), insert a translator commit after step 7. The translator phase is a sub-agent operation per c11 CLAUDE.md "Localization", not impl agent work.

## Parallelization recommendation

**Two impl siblings, not one, not three.** File overlap analysis:

| Workstream | Primary files | `CLI/c11.swift`? |
|---|---|---|
| 1. Markdown blueprints | new `Sources/WorkspaceBlueprintMarkdown.swift`, `Sources/WorkspaceBlueprintStore.swift`, `Sources/TerminalController.swift` (export handler), `CLI/c11.swift` (~L2866, ~L3021) | yes, two sites |
| 2. Manifest layer | new `Sources/WorkspaceSnapshotSet.swift`, `Sources/WorkspaceSnapshotStore.swift`, `Sources/TerminalController.swift` (snapshot.create + new snapshot.restore_set), `CLI/c11.swift` (~L1900, ~L1913, ~L8742, ~L8802) | yes, four sites |
| 3. Diagnostic cleanup | `Sources/WorkspaceLayoutExecutor.swift`, `Sources/WorkspacePlanCapture.swift`, `CLI/c11.swift` (~L2848, ~L2914, ~L3291) | yes, three sites |
| 4. `workspace --help` routing | `CLI/c11.swift` (~L7269, ~L8822, ~L14328) | yes, three sites |
| 5. `C11_SOCKET` + log | `CLI/c11.swift` (~L1424, ~L1437, ~L1620, ~L14324) | yes, four sites |

`CLI/c11.swift` is touched by all five workstreams but the regions are non-adjacent: socket resolution at L1400-L1500, command dispatch at L1500-L2000, snapshot/blueprint runners at L2860-L3300, help dispatch at L7269-L8830, top-level usage at L14310-L14430. Two siblings with disjoint regions:

- **Sibling A — Markdown blueprints + manifest layer (workstreams 1 + 2).** The big new files. `Sources/WorkspaceBlueprintMarkdown.swift`, `Sources/WorkspaceSnapshotSet.swift`. `CLI/c11.swift` regions: blueprint runner (~L2860), snapshot runner (~L1900, L8742), restore polymorphism. Roughly the larger half by LOC.
- **Sibling B — Diagnostics + help routing + socket safety (workstreams 3 + 4 + 5).** `Sources/WorkspaceLayoutExecutor.swift`, `Sources/WorkspacePlanCapture.swift`. `CLI/c11.swift` regions: help dispatch (~L7269, L8822, L14328), socket resolution (~L1424, L1437, L1620, L14324), CLI print loops (~L2848, L2914, L3291). Mostly small surgical edits, lots of files.

A and B can run in parallel and merge cleanly because their `CLI/c11.swift` line ranges don't overlap. Sibling B should land first chronologically (commits 1-4 in the grouping above) since several of its changes — especially commit 2 (`C11_SOCKET`) — make it safer to run any subsequent validation against the smoke build. Sibling A then layers commits 5-7 on top.

**Why not three siblings.** Workstream 3 alone is small enough that splitting it from 4+5 doesn't buy throughput; it just adds a third merge surface. Workstreams 1 and 2 each touch enough places that asking one impl agent to hold both contexts is fine; splitting them adds coordination overhead with little wall-clock win.

**Why not single-agent.** The combined diff is sizeable (estimated ~1.5k–2k lines including tests) and the two halves are genuinely independent (different files in `Sources/`, different regions in `CLI/c11.swift`). One agent serializes work that doesn't need to be serialized.

## File-level survey (existing, the impl agents do not need to rediscover)

- `Sources/WorkspaceApplyPlan.swift` (353 LoC) — `WorkspaceApplyPlan`, `WorkspaceSpec`, `SurfaceSpec`, `LayoutTreeSpec`, `ApplyOptions`, `StepTiming`, `ApplyFailure`, `ApplyResult`. Only workstream 3 touches this (severity field option).
- `Sources/WorkspaceLayoutExecutor.swift` (1171 LoC) — apply primitive. Failure emission sites for workstream 3: `reportWorkingDirectoryNotApplicable` at L846, the two `metadata_override` cases at L900 and L909.
- `Sources/WorkspacePlanCapture.swift` (168 LoC) — capture walker. Workstream 3 capture-side fix lands at L75-L91 (the `SurfaceSpec` initializer call).
- `Sources/WorkspaceBlueprintFile.swift` (41 LoC) — `WorkspaceBlueprintFile` + `WorkspaceBlueprintIndex`. Untouched.
- `Sources/WorkspaceBlueprintStore.swift` (239 LoC) — discovery + read/write. Workstream 1 extends `read(url:)` (L143) and `write(_:to:)` (L159) to dispatch by extension; `indexEntries` (L207) already handles `.md` for the picker (L224).
- `Sources/WorkspaceBlueprintExporter.swift` (32 LoC) — main-actor capture wrapper. Untouched.
- `Sources/WorkspaceSnapshot.swift` (276 LoC) — `WorkspaceSnapshotFile`, `WorkspaceSnapshotIndex`, ULID generator. Untouched.
- `Sources/WorkspaceSnapshotStore.swift` (459 LoC) — disk I/O. Workstream 2 adds `defaultSetsDirectory()`, `writeSet`, `readSet`, `listSets`. The existing `enumerate(directory:source:)` at L324 is non-recursive; the new `sets/` subdirectory is naturally excluded.
- `Sources/WorkspaceSnapshotCapture.swift` (101 LoC) and `Sources/WorkspaceSnapshotConverter.swift` (87 LoC) — capture + envelope conversion. Untouched.
- `Sources/TerminalController.swift` — v2 socket dispatch. Workstream 1 edits `v2WorkspaceExportBlueprint` (L4577); workstream 2 edits `v2SnapshotCreate` (L4644) and adds `v2SnapshotRestoreSet`. Method registration table at L2109/L2115/L2111.
- `CLI/c11.swift` (17,641 LoC) — multi-purpose. Specific sites named under each workstream.

## Testing strategy

Per CLAUDE.md "Test quality policy": no source-text/grep tests. All tests must verify observable runtime behavior.

- **Unit tests** (`Tests/c11Tests/`): markdown parser/writer round-trip on `WorkspaceApplyPlan` values (workstream 1). `WorkspaceSnapshotSetFile` Codable round-trip (workstream 2). New severity classification or CLI-print partition (workstream 3). No tests of source text, AST shape, or method signatures.
- **CLI behavioral tests** (`tests_v2/`): require a running c11 socket (per CLAUDE.md "Testing policy" — never launch an untagged build for these; the Validate phase uses a tagged smoke build). Round-trip blueprint export/materialize. Round-trip manifest snapshot/restore-set. Workspace-help dispatch (offline). Socket-precedence env-var probes. Restore exit-0-clean on the smoke fixture.
- **No tests** of `Resources/Info.plist` text, project file contents, or grep over the source. If a behavior cannot be exercised end-to-end (which doesn't apply to anything in this PR), state the gap explicitly in the commit message rather than writing a fake check.
- **Validate phase** (after impl + review): drives a `cmux-37-final` tagged build with explicit `--socket /tmp/c11-debug-cmux-37-final.sock` on every CLI call (per the wrong-socket protocol; once workstream 5 is in the smoke build, the validator can also confirm `C11_SOCKET=…` works without explicit `--socket`). Runs the same scenarios the smoke validator ran on 2026-05-03; outputs `/tmp/cmux-37-final-smoke-report.md`.

## Localization touch points

Workstreams 1, 4, and 5 will introduce new user-facing strings. Likely additions:

- Markdown parse error messages (workstream 1): "blueprint markdown: missing `## Layout` section", "blueprint markdown: layout codeblock is not valid YAML", "blueprint markdown: unknown layout node type '%@'", "blueprint markdown: file references missing path '%@'".
- Workspace help text (workstream 4): four new `Usage:` blocks. The existing precedent (`subcommandUsage` cases) does not localize the help bodies — they're plain English. **Recommend keeping the new help bodies in plain English** to match the surrounding cases. Translation only kicks in for `String(localized:)` call sites; help strings aren't currently in `Localizable.xcstrings`.
- CLI socket discovery line (workstream 5): "c11: using socket %@ (auto-discovered from %@)". Wrap in `String(localized:)` so the translator phase can fan out.

**Translator handoff (post-impl):** if new `String(localized:)` calls land, spawn six per-locale translator siblings (ja, uk, ko, zh-Hans, zh-Hant, ru) per c11 CLAUDE.md "Localization". If no `String(localized:)` calls land, skip translator entirely. Impl agents must list the new keys in their completion comment so the delegator can decide.

## Risks and gotchas

- **Wrong-socket disaster.** Until workstream 5 is in the smoke build, every Validate-phase CLI call MUST pass `--socket /tmp/c11-debug-cmux-37-final.sock` explicitly. Auto-discovery hits the operator's live workspace; not theoretical, this happened on 2026-05-03.
- **Typing-latency hot paths.** `WindowTerminalHostView.hitTest`, `TabItemView`, `TerminalSurface.forceRefresh`. None of the five workstreams need to touch them. If review thinks a workstream wants to: stop and re-scope.
- **Submodule hygiene.** None of the workstreams should require `ghostty/` or `vendor/bonsplit/` edits. If one starts to: a separate submodule-bump commit and push to the fork's `main` *first*, per CLAUDE.md "Submodule safety".
- **xcstrings hand-editing.** Never. Translator sub-agents drive the `.xcstrings` write; impl agents only add English `defaultValue:` strings.
- **Capture-side title strip (workstream 3).** Be careful: only strip `metadata["title"]` when its value equals what `setPanelCustomTitle` will write. If they differ (operator manually wrote `set-metadata --key title --value "Foo"` separate from `set-title`), the divergent value still warrants the override warning — that's a real conflict.
- **Manifest schema versioning (workstream 2).** Ship `version: 1`. A future change must bump.
- **Polymorphic restore (workstream 2).** Probe order matters. CLI checks `~/.c11-snapshots/sets/<id>.json` before falling through to `snapshot.restore`. Identical ULIDs in both places are vanishingly unlikely (different generators / different occasions), but if the user passes a path, treat the file extension and content as authoritative — a manifest file has `snapshots: [...]` while a single snapshot has `plan: ...`.
- **Per-repo blueprint discovery dual paths.** Adding `.c11/blueprints/` alongside `.cmux/blueprints/` means a repo with both directories shows merged results. Order: `.c11` first, `.cmux` second, modified-time desc within each. Don't ship a deduplication that's hard to reason about.
- **`c11 workspace --help` and offline mode.** Help dispatch runs **before** the socket connect (`CLI/c11.swift:1548`). Don't introduce a help branch that accidentally requires a socket.
- **`--quiet` flag scope.** Adding a global `--quiet` flag in workstream 5 is tempting but it touches every command's print loop. Recommend `C11_QUIET_DISCOVERY=1` env var only for v1; `--quiet` is a follow-up if the operator asks.
- **CLAUDE.md "Validate what you ship".** The Validate phase exercises the user flow on a tagged build, not just unit tests. Acceptance criteria below are smoke-testable on `cmux-37-final`.

## Acceptance criteria (Validate phase checks)

Each maps 1:1 to a scope item. The validator drives `c11 --socket /tmp/c11-debug-cmux-37-final.sock <cmd>` explicitly until workstream 5 lands in-build.

- **Markdown blueprint round-trip.** `c11 workspace export-blueprint --name foo --workspace workspace:1` writes `~/.config/c11/blueprints/foo.md`. `cat foo.md` shows YAML frontmatter (`title:`, `description:`, `custom_color:`) and a `## Layout` section with a fenced YAML codeblock. `c11 workspace new --blueprint ~/.config/c11/blueprints/foo.md` materializes a workspace whose `c11 tree --json` structurally matches the original (surface count, types, titles, split orientation, divider positions within tolerance).
- **Picker discovery.** `c11 workspace new` (no args) lists `foo` alongside the three built-ins. Picking `foo` materializes correctly.
- **JSON back-compat read.** A pre-existing JSON blueprint at `~/.config/cmux/blueprints/legacy.json` is still discoverable via the picker and applies via `--blueprint`.
- **Snapshot manifest.** `c11 snapshot --all` (run on a c11 with two distinct workspaces) writes per-workspace files at `~/.c11-snapshots/<ulid>.json` AND a manifest at `~/.c11-snapshots/sets/<set-ulid>.json`. The manifest references both inner ids and records selection.
- **Manifest restore.** Closing both workspaces and running `c11 restore <set-ulid>` rehydrates both in correct order with selection re-established. Each inner snapshot is also independently restorable via `c11 restore <inner-ulid>`.
- **`list-snapshots --sets`.** Lists manifests with their inner-snapshot counts. `list-snapshots --all` shows both sections.
- **Restore diagnostics clean.** On the smoke fixture (mixed 6-surface workspace with title overrides), `c11 restore <id>` prints `failures: 0` (or `failures:` line absent). Info-level lines are acceptable; the structured payload still carries them.
- **`c11 workspace new --help`** prints the per-subcommand help, exit 0. Same for `c11 workspace --help`, `c11 workspace export-blueprint --help`, `c11 workspace apply --help`. None print `Unknown command`.
- **`C11_SOCKET` honored.** `C11_SOCKET=/tmp/c11-debug-cmux-37-final.sock c11 ping` returns `PONG` from the smoke build (verified by counting workspaces — smoke build has 1, live has many). `CMUX_SOCKET_PATH=…` still works as alias. With both set, `C11_SOCKET` wins.
- **Auto-discovery breadcrumb.** With no env var set and a stale `/tmp/cmux-last-socket-path` symlink pointing at the smoke socket, `c11 ping` emits exactly one stderr line naming both the socket and the pointer file. Stdout is unchanged. `C11_QUIET_DISCOVERY=1 c11 ping` suppresses the line.

## Operator-visible result

When this PR lands and the operator runs `c11 workspace export-blueprint --name agent-room --workspace workspace:1`, they see a markdown file at `~/.config/c11/blueprints/agent-room.md` they can open in Obsidian, edit by hand, and check into git next to their notes. They can run `c11 workspace new` and pick it from a list. They can run `c11 snapshot --all` end-of-day and `c11 restore <set-id>` first-thing-tomorrow and walk back into the same room. They can run `c11 workspace new --help` and get help instead of a confusing `Unknown command` echo. They can `C11_SOCKET=… c11 …` and trust it landed where they asked. And they can read `c11 restore <id>`'s output without parsing through six bogus `failure:` lines for behaviors that worked exactly as designed.

That's CMUX-37 closed. The next operator picking up this codebase finds blueprints next to notes, snapshots that round-trip cleanly across reboots, and a CLI that doesn't booby-trap them with the wrong socket.

---

# Historical context (pre-final-push)

The sections below describe earlier iterations of this ticket — the original Phase 0–5 plan, the C11-13 alignment, and the dogfood findings that drove the workspace-apply transaction. Retained as context. **Not active work.**

## What this is

One ticket delivering two persistence concepts on a shared app-side primitive:

- **Blueprints** — declarative markdown that defines the initial shape of a workspace. Checked into git, shareable, per-repo (`.cmux/blueprints/*.md`) or per-user (`~/.config/cmux/blueprints/*.md`).
- **Snapshots** — auto-generated JSON capturing exact live state for crash/restart recovery. Per-user (`~/.cmux-snapshots/`).

Both compile to a `WorkspaceApplyPlan` executed **app-side in one transaction**. Not CLI/socket choreography — the 2026-04-21 dogfood proved that route fails. Both share a known-type restart registry: `claude-code + session_id → cc --resume <id>`.

## The hard constraint

**App-side transaction, not shell choreography.** A `WorkspaceApplyPlan` describes the end state; the app materializes it in one pass. The CLI sends one structured request; the app handles creation, lifecycle waiting, metadata, and ref assignment internally. Blueprints and snapshot-restore MUST route through this — never an internal loop that shells out to existing CLI commands.

## Phases (historical — Phase 0, 1, 2, 3, 4 shipped via PRs #75 and #79)

Phase 0 — `WorkspaceApplyPlan` + executor → PR #75.
Phase 1 — Snapshots + Claude resume + restart registry → PR #79.
Phase 2 — Blueprint format + picker + exporter (JSON shape) → PR #79.
Phase 3 — Browser/markdown surfaces + `--all` (per-workspace files only, no manifest) → PR #79.
Phase 4 — Skill docs + hook snippet → in skill.
Phase 5 — codex / kimi / opencode registry rows → deferred.

The Final-Push Plan above replaces the unfinished work from Phases 2/3 with the markdown blueprint format + manifest layer + diagnostic cleanup + help fix + socket safety set the smoke validator surfaced.

## Supersedes

- CMUX-4 (manual Claude session index) — hook-driven capture replaces JSONL discovery.
- CMUX-5 (recovery UI banner) — subsumed by the new-workspace picker + restart registry.

Restore preserves CMUX-11 pane manifests + CMUX-14 lineage chains verbatim.
