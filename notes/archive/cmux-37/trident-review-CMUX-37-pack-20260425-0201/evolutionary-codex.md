## Evolutionary Code Review
- **Date:** 2026-04-25T06:33:36Z
- **Model:** Codex / GPT-5
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8b1531bfc77529bc3663cdafeaa5cb11e
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory
---

## Review Setup Notes

Local branch inspection confirmed `cmux-37/remaining-phases` at `4e4ca5a8`, with 8 commits ahead of local `origin/main`. The review prompt's Phase 0 asks for fetch/pull against `origin/dev`, but the wrapper instruction explicitly says read-only and "take no action beyond writing this single file." I therefore did not fetch or pull. There is also no local `origin/dev` ref, so this review uses the context-stated base, `origin/main`.

## What's Really Being Built

This branch is not just adding blueprints and snapshots. It is turning `WorkspaceApplyPlan` into c11's executable workspace intermediate representation: a small declarative program for materializing a room.

The important move is that three product surfaces now orbit the same plan-space:

- `workspace.apply` decodes and executes a `WorkspaceApplyPlan` through `WorkspaceLayoutExecutor` (`Sources/TerminalController.swift:4360`, `Sources/WorkspaceLayoutExecutor.swift:55`).
- Snapshots embed the same plan (`Sources/WorkspaceSnapshotCapture.swift:60`, `Sources/WorkspaceSnapshotCapture.swift:61`).
- Blueprints wrap the same plan (`Sources/WorkspaceBlueprintFile.swift:7`, `Sources/WorkspaceBlueprintFile.swift:11`) and export live workspaces through the same capture walker (`Sources/WorkspaceBlueprintExporter.swift:24`).

Name this: **Workspace IR**. Once the codebase treats it as an IR, a lot opens up: linting, diffing, composing, parameterizing, transforming, sharing, previewing, and replaying workspaces without needing separate mechanisms for snapshots, templates, and automation.

The second thing being built is a primitive for **operator room memory**. `c11 snapshot --all` captures every open workspace (`Sources/TerminalController.swift:4571`), blueprints can be discovered from repo/user/built-in locations (`Sources/WorkspaceBlueprintStore.swift:60`, `Sources/WorkspaceBlueprintStore.swift:86`, `Sources/WorkspaceBlueprintStore.swift:98`), and restart registry rows can synthesize agent resume commands (`Sources/AgentRestartRegistry.swift:116`). Together, these are the beginnings of "the app remembers how this room works."

## Emerging Patterns

**Plan-space as the center of gravity.** `WorkspaceApplyPlan` already has the shape of a reusable IR: a workspace spec, a layout tree, and surface specs (`Sources/WorkspaceApplyPlan.swift:13`, `Sources/WorkspaceApplyPlan.swift:25`, `Sources/WorkspaceApplyPlan.swift:56`, `Sources/WorkspaceApplyPlan.swift:115`). The branch is converging around that shape, but the support code is still distributed across CLI JSON parsing, socket handlers, snapshot conversion, docs, and tests.

**Capture/apply duality.** `WorkspacePlanCapture.capture(workspace:)` is now the inverse-ish partner to `WorkspaceLayoutExecutor.apply(...)` (`Sources/WorkspacePlanCapture.swift:10`, `Sources/WorkspaceLayoutExecutor.swift:55`). That is a powerful pattern. The next evolution is to make the pair explicit as a round-trip contract: capture should say what fidelity it achieved, and apply should say what it could not faithfully materialize.

**Discovery without diagnostics.** The store currently skips missing directories, unreadable dirs, and undecodable blueprint files quietly (`Sources/WorkspaceBlueprintStore.swift:183`, `Sources/WorkspaceBlueprintStore.swift:194`, `Sources/WorkspaceBlueprintStore.swift:203`, `Sources/WorkspaceBlueprintStore.swift:219`). Silent skipping is fine for a first picker, but as repo/user blueprints become real operator infrastructure, invisible failures will feel like lost work.

**Filesystem hierarchy as product model.** Repo blueprints before user blueprints before built-ins (`Sources/WorkspaceBlueprintStore.swift:118`, `Sources/WorkspaceBlueprintStore.swift:122`) is more than lookup order. It creates a natural inheritance model: project rooms override personal rooms override shipped starter rooms.

**Best-effort restart is becoming a capability registry.** The registry is currently a terminal type to command-string table (`Sources/AgentRestartRegistry.swift:43`, `Sources/AgentRestartRegistry.swift:116`). Phase 5 adds codex/opencode/kimi rows that resume globally rather than by exact session (`Sources/AgentRestartRegistry.swift:111`, `Sources/AgentRestartRegistry.swift:123`, `Sources/AgentRestartRegistry.swift:128`, `Sources/AgentRestartRegistry.swift:133`). That is useful, but it is really the seed of a broader "agent capability registry."

## How This Could Evolve

The branch wants a **WorkspacePlanKit**: a small pure layer that owns plan decoding, validation, linting, diagnostics, schema version support, and text rendering. Right now those concerns are scattered:

- Socket decode and pre-validation live in `v2WorkspaceApply` (`Sources/TerminalController.swift:4366`, `Sources/TerminalController.swift:4400`).
- Snapshot conversion has a duplicate supported-plan-version literal (`Sources/WorkspaceSnapshotConverter.swift:24`, `Sources/WorkspaceSnapshotConverter.swift:33`).
- CLI blueprint apply reads raw JSON and plucks `plan` directly (`CLI/c11.swift:2754`, `CLI/c11.swift:2760`, `CLI/c11.swift:2841`, `CLI/c11.swift:2847`).
- The docs are hand-written schema text (`docs/workspace-apply-plan-schema.md:1`).

If extracted carefully, that kit becomes the foundation for `c11 workspace lint`, `c11 workspace diff`, `c11 workspace normalize`, preview UI, safer repo blueprints, and CI checks for checked-in `.cmux/blueprints`.

Blueprints also want to become **recipes**, not only static plans. The current envelope is intentionally minimal: version, name, description, plan (`Sources/WorkspaceBlueprintFile.swift:7`). That is the right first move. The next version could add optional parameters and overlays without disturbing v1:

- variables such as `{repoRoot}`, `{defaultBranch}`, `{operatorHome}`, `{socketPath}`
- required capabilities such as `browser`, `markdown`, `agent.codex`
- post-apply hints such as selected workspace, initial command strategy, or telemetry keys
- provenance such as exported-from version, export time, and source workspace title

This would let the starter `agent-room` blueprint (`Resources/Blueprints/agent-room.json:3`) become a reusable agent-room family rather than one fixed split.

Snapshots want to become a **timeline**, not just files. `snapshot --all` already captures the whole room (`CLI/c11.swift:2920`, `Sources/TerminalController.swift:4571`). With a light policy layer, this could become automatic savepoints: before quit, before reload, every N minutes when dirty, or before risky socket operations. That turns CMUX-37 from "restore one workspace" into "rewind the operator's command center."

## Mutations and Wild Ideas

**Blueprint-as-Markdown.** The store accepts `.md` files as blueprint candidates (`Sources/WorkspaceBlueprintStore.swift:197`), but today markdown entries are only indexed by filename stem (`Sources/WorkspaceBlueprintStore.swift:223`) and the picker later reads the selected file as JSON (`CLI/c11.swift:2837`, `CLI/c11.swift:2842`). A strong mutation: make `.md` blueprints first-class documents with YAML front matter or fenced `workspace-plan` JSON. The operator gets prose, screenshots, intent, and the executable plan in one file.

**Workspace genetics.** Since capture mints simple plan-local ids (`Sources/WorkspacePlanCapture.swift:104`), blueprints and snapshots are already "genomes" that can be crossed. A future `workspace compose` could take the left half from one plan, the right half from another, or merge a repo-standard agent sidebar into the current room.

**Room contracts for repos.** A repo could ship `.cmux/blueprints/default.md` plus a CI lint check. Opening a repo in c11 could suggest: "This project defines an agent review room, a release room, and a test triage room." That turns workspace layout into part of the codebase's operational contract.

**Agent restart confidence.** The registry could return `{command, confidence, exactness, warning}` instead of just a string. Claude with a valid session id is exact. Codex `--last` is best-effort. Kimi/opencode flags may be unknown until probed. The restore UI could display that honestly.

**Plan preview thumbnails.** `WorkspaceApplyPlan.layout` is deterministic enough to render a tiny split diagram without touching AppKit. The blueprint picker could show a preview in text today and a graphical picker later.

## Leverage Points

The highest-leverage code is the shared capture/apply spine:

- `WorkspacePlanCapture.capture(workspace:)` (`Sources/WorkspacePlanCapture.swift:10`)
- `WorkspaceLayoutExecutor.apply(...)` (`Sources/WorkspaceLayoutExecutor.swift:55`)
- `WorkspaceApplyPlan` (`Sources/WorkspaceApplyPlan.swift:13`)

Every improvement there compounds across blueprints, snapshots, restore, CLI automation, and future UI.

The next leverage point is diagnostics. The current implementation has good typed warning/failure concepts in apply (`Sources/WorkspaceLayoutExecutor.swift:62`, `Sources/WorkspaceLayoutExecutor.swift:281`, `Sources/WorkspaceLayoutExecutor.swift:777`), but blueprint discovery and capture do not yet expose the same quality of feedback. Bringing those into a common diagnostic vocabulary would make the entire persistence stack feel trustworthy.

The third leverage point is repo-local blueprints (`Sources/WorkspaceBlueprintStore.swift:60`). That gives c11 a route into project-specific workflows without writing to other tools' configs, which matches the repo's principle that c11 stops at the edge of its surfaces.

## The Flywheel

The flywheel is:

1. Operators arrange useful workspaces.
2. `workspace export-blueprint` captures them (`CLI/c11.swift:2854`, `Sources/TerminalController.swift:4496`).
3. Blueprints are shared in repo/user/built-in discovery locations (`Sources/WorkspaceBlueprintStore.swift:122`).
4. Agents and humans launch better rooms faster (`CLI/c11.swift:2737`).
5. Those rooms include better metadata, titles, panes, and agent restart hints.
6. Snapshots and restores become more faithful because the same IR improves.
7. More operators trust the system enough to encode more of their work patterns as blueprints.

Set that spinning and c11 becomes not just a multiplexer, but a memory system for compound operator:agent workflows.

## Concrete Suggestions

1. **High Value — Create a pure `WorkspacePlanCodec` / `WorkspacePlanKit` layer.** ✅ Confirmed — this is compatible with the existing architecture because `WorkspaceApplyPlan` and its nested specs are already Foundation value types (`Sources/WorkspaceApplyPlan.swift:1`, `Sources/WorkspaceApplyPlan.swift:13`). Move shared decode, encode, validation, normalization, and version support out of the socket handler and CLI paths. Start by replacing the raw JSON extraction in `runWorkspaceBlueprintNew` (`CLI/c11.swift:2754`, `CLI/c11.swift:2841`) and the decode/pre-validate block in `v2WorkspaceApply` (`Sources/TerminalController.swift:4366`, `Sources/TerminalController.swift:4400`). Also remove the duplicated supported-plan-version literal in `WorkspaceSnapshotConverter` (`Sources/WorkspaceSnapshotConverter.swift:24`, `Sources/WorkspaceSnapshotConverter.swift:33`) by having both sides call one pure source of truth or one tiny version-policy type.

2. **High Value — Add blueprint discovery diagnostics instead of silent skips.** ✅ Confirmed — the store already centralizes discovery in `WorkspaceBlueprintStore.merged(cwd:)` (`Sources/WorkspaceBlueprintStore.swift:122`) and indexing in `indexEntries` (`Sources/WorkspaceBlueprintStore.swift:206`). Extend the return shape internally to include skipped files with `{url, source, code, message}` and surface it optionally from `workspace.list_blueprints` (`Sources/TerminalController.swift:4471`). The CLI can print warnings only in non-JSON mode; JSON clients can inspect diagnostics. Risk: existing tests assert exact counts (`c11Tests/WorkspaceBlueprintStoreTests.swift:136`, `c11Tests/WorkspaceBlueprintStoreTests.swift:157`), so add diagnostics without changing the `blueprints` array semantics.

3. **High Value — Make capture return fidelity diagnostics.** ✅ Confirmed — both Snapshot and Blueprint export now call `WorkspacePlanCapture.capture(workspace:)` (`Sources/WorkspaceSnapshotCapture.swift:60`, `Sources/WorkspaceBlueprintExporter.swift:24`), so one new `WorkspacePlanCaptureResult { plan, warnings }` seam would benefit both. This matters because capture can currently skip unresolved tabs (`Sources/WorkspacePlanCapture.swift:67`, `Sources/WorkspacePlanCapture.swift:69`) and some values are inherently lossy, such as browser URL in the headless test harness (`c11Tests/WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift:16`). Risk: changing the function signature touches both callers, but the migration is small and localized.

4. **Strategic — Promote AgentRestartRegistry from command table to capability registry.** ✅ Confirmed — the existing registry is deliberately pure and row-based (`Sources/AgentRestartRegistry.swift:43`, `Sources/AgentRestartRegistry.swift:52`), so it can evolve without socket schema churn. Add a richer result type such as `RestartResolution(command: String, exactness: .exact | .bestEffort | .fresh, warnings: [String])`. This would let `claude-code` with a UUID remain exact (`Sources/AgentRestartRegistry.swift:117`), while codex/opencode/kimi expose their global-last caveat honestly (`Sources/AgentRestartRegistry.swift:123`, `Sources/AgentRestartRegistry.swift:128`, `Sources/AgentRestartRegistry.swift:133`). Risk: `TerminalPanel.sendText` currently expects only command text at executor time (`Sources/WorkspaceLayoutExecutor.swift:206`, `Sources/WorkspaceLayoutExecutor.swift:241`); thread warnings into `ApplyResult` before changing UI.

5. **Strategic — Make `.md` blueprints real blueprint documents.** ✅ Confirmed — `.md` files are already accepted by discovery (`Sources/WorkspaceBlueprintStore.swift:197`) and tests intentionally cover `.md` extension acceptance (`c11Tests/WorkspaceBlueprintStoreTests.swift:203`). Today, however, markdown index entries use only the filename stem (`Sources/WorkspaceBlueprintStore.swift:223`) and the picker reads the file as JSON (`CLI/c11.swift:2837`, `CLI/c11.swift:2842`). Add a parser for front matter plus a fenced JSON plan block. This turns blueprint files into explainable operational docs. Risk: keep JSON `.md` compatibility initially because the current test writes JSON content to `.md` (`c11Tests/WorkspaceBlueprintStoreTests.swift:207`, `c11Tests/WorkspaceBlueprintStoreTests.swift:211`).

6. **Strategic — Add plan overlays and parameters in a v2 blueprint envelope.** ❓ Needs exploration — the v1 envelope is intentionally small (`Sources/WorkspaceBlueprintFile.swift:7`) and should stay stable. A v2 `WorkspaceBlueprintFile` could add optional `parameters`, `requires`, and `overlays` while still emitting a concrete v1 `WorkspaceApplyPlan` before apply. This is compatible if implemented as a pre-apply expansion step in the CLI/socket layer rather than inside `WorkspaceLayoutExecutor`, which should continue consuming concrete plans. Dependency: first extract the codec/validator layer so expansion has one canonical output path.

7. **Strategic — Turn `snapshot --all` into a room timeline.** ✅ Confirmed — the socket handler already enumerates `tabManager.tabs`, captures each workspace, writes each snapshot, and returns a batch result (`Sources/TerminalController.swift:4574`, `Sources/TerminalController.swift:4586`, `Sources/TerminalController.swift:4605`). Add a policy layer later for automatic savepoints and retention. Risk: automatic capture needs throttling and storage policy; manual `--all` should remain simple and explicit.

8. **Experimental — Add `workspace diff` and `workspace preview`.** ✅ Confirmed — the layout tree and surface list are pure Codable structures (`Sources/WorkspaceApplyPlan.swift:115`, `Sources/WorkspaceApplyPlan.swift:150`, `Sources/WorkspaceApplyPlan.swift:163`), so a text preview/diff does not need AppKit. This would make blueprint review practical in PRs: "this changes a two-pane terminal room into an agent-room with browser." Start as CLI-only and generated from the same pure PlanKit.

9. **Experimental — Repo room contracts.** ❓ Needs exploration — repo blueprint discovery already walks upward from cwd and stops at the first `.cmux/blueprints` hit (`Sources/WorkspaceBlueprintStore.swift:60`, `Sources/WorkspaceBlueprintStore.swift:69`). Build on that with a conventional `.cmux/blueprints/default.md` and a lint command. This could make workspace structure part of a project's onboarding contract. Risk: avoid auto-launching anything; suggest or list only, preserving c11's unopinionated boundary.

10. **Experimental — Workspace composition operators.** ❓ Needs exploration — because `LayoutTreeSpec` is recursive and surfaces are id-keyed (`Sources/WorkspaceApplyPlan.swift:20`, `Sources/WorkspaceApplyPlan.swift:115`), composition is plausible: append a sidecar pane, replace a leaf, merge metadata, or graft one blueprint into another. The hard part is stable conflict behavior for ids, pane metadata, selected indexes, and divider positions. Prototype as pure transforms before exposing it in the app.

## Closing Take

CMUX-37 is quietly creating c11's workspace language. The immediate feature is persistence, but the durable asset is the reusable IR and the capture/apply loop around it. The strongest next move is to treat that IR as a product primitive: give it a pure toolkit, diagnostics, markdown affordances, and eventually composition.

The architectural direction looks good because the important pieces are converging instead of multiplying. Keep the executor concrete, keep plan manipulation pure, make lossy edges visible, and let repo/user/built-in blueprints become the way c11 learns an operator's rooms.
