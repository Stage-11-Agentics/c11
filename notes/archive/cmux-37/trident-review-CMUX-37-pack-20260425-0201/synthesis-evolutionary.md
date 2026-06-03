## Evolutionary Synthesis — CMUX-37
- **Date:** 2026-04-25
- **Models synthesized:** Claude Sonnet 4.6, Codex/GPT-5, Gemini
- **Branch:** cmux-37/remaining-phases
- **Latest Commit:** 4e4ca5a8b1531bfc77529bc3663cdafeaa5cb11e

---

## Executive Summary: Biggest Opportunities

All three models converged on the same fundamental insight: CMUX-37 is not shipping a persistence feature — it is shipping a **workspace intermediate representation** with a complete I/O surface. The `WorkspaceApplyPlan` is now the executable, versioned, round-trippable grammar for describing a multi-agent environment. The capture/apply pair completes the loop. What happens next determines whether c11 becomes a multiplexer with snapshots, or a **workspace programming language with a runtime**.

The four biggest opportunities, in order of leverage:

1. **WorkspacePlanKit** — extract a pure codec/validator/diagnostics layer from the three scattered decode paths. Every other evolution depends on this foundation being clean.
2. **Parametric blueprints** — the single highest-ROI feature addition. Turns static named templates into reusable programs. All three models named this independently.
3. **Rename `.config/cmux/` to `.config/c11/`** — low-effort, time-sensitive. Blueprints are about to accumulate in user home directories. Fix the path before operators build muscle memory around the wrong name.
4. **Blueprint sharing infrastructure** — git-backed or URL-based remote source tier. This is the flywheel fuel: sharing is what makes the ecosystem compound.

---

## 1. Consensus Direction

Evolution paths that two or more models identified independently:

1. **WorkspaceApplyPlan as a first-class IR.** All three models named this the true output of CMUX-37. Claude called it "a workspace programming language." Codex called it "Workspace IR." Gemini called it "Workspace-as-Code." The unanimity is signal: this framing should govern every decision about what to build next. The plan schema is the public API; treat it as such.

2. **Parametric blueprints.** All three models identified this as the highest-value near-term addition. Current blueprints are static; the natural evolution is template substitution at apply time: variables in `command`, `working_directory`, `url`, and `title` resolved via `--param KEY=VALUE` flags or interactive prompts. The executor never sees variables — a pre-apply expansion step resolves them before `WorkspaceLayoutExecutor` is invoked. The CLI picker already has the interactive infrastructure.

3. **Capture/apply round-trip as an explicit invariant.** Both Claude and Codex called out that `WorkspacePlanCapture` and `WorkspaceLayoutExecutor` are inverses, and that this invariant is not yet formally tested. The missing test: `capture(apply(plan)) ≅ plan`. Both also noted that capture currently silently skips unresolved tabs and that lossy edges are not surfaced to callers.

4. **Diagnostics for discovery and capture.** Both Codex and Claude flagged the same gap: `WorkspaceBlueprintStore` silently skips unreadable/undecodable files, and `WorkspacePlanCapture` silently drops unresolved surfaces. As blueprints become real operator infrastructure, invisible failures feel like lost work. The fix is a common diagnostic vocabulary across the persistence stack: `{url, source, code, message}` from discovery; `WorkspacePlanCaptureResult { plan, warnings }` from capture; surfaced optionally from `workspace.list_blueprints` and `workspace.export_blueprint`.

5. **Rename `.config/cmux/` to `.config/c11/`** (confirmed by Claude, implicit in Codex and Gemini's consistent use of "c11" framing). The three known hardcode locations: `WorkspaceBlueprintStore.swift:92`, `TerminalController.swift:4524`, `CLI/c11.swift` around `runWorkspaceExportBlueprint`. Requires a one-time migration shim.

6. **Blueprint sharing and remote discovery.** All three models identified the three-tier (repo/user/built-in) discovery as the right foundation and the natural extension as a fourth `remote` tier — fetched from a URL or pulled from a git repo. Gemini called out "git-backed blueprint palettes." Codex named it "repo room contracts." Claude described it as a team/org sharing registry. The implementation is additive: `WorkspaceBlueprintStore.merged(cwd:)` accepts a new source with a cache layer.

7. **AgentRestartRegistry evolves from command table to capability registry.** All three models noted that the registry rows for opencode/kimi have unconfirmed flags and silently fail at best-effort. Both Codex and Claude proposed a richer result type: `RestartResolution(command, exactness: .exact | .bestEffort | .fresh, warnings)`. Claude proposed a `confidence` field on `Row`. Gemini described a "Session Revival Agent" that queries runtime context rather than a static table.

---

## 2. Best Concrete Suggestions

The most actionable ideas across all three, ordered by value:

1. **Extract `WorkspacePlanKit` (pure codec/validator layer).** Codex's suggestion, confirmed by architecture. Move shared decode, encode, validation, normalization, and version support out of the three scattered paths: socket handler `v2WorkspaceApply` (`TerminalController.swift:4366`), CLI `runWorkspaceBlueprintNew` (`CLI/c11.swift:2754`), and `WorkspaceSnapshotConverter`'s duplicated version literal. A single source of truth for plan versions eliminates the `WorkspaceSnapshotConverter` duplication and makes `c11 workspace lint`, `c11 workspace diff`, and `c11 workspace preview` buildable as thin CLI wrappers.

2. **Add blueprint discovery diagnostics.** Extend `WorkspaceBlueprintStore.indexEntries` to track skipped files with `{url, source, reason}`. Surface optionally from `workspace.list_blueprints`. CLI prints warnings in non-JSON mode; JSON clients inspect diagnostics field. Existing tests assert exact counts — add diagnostics without changing `blueprints` array semantics.

3. **`WorkspacePlanCaptureResult { plan, warnings }`.** Change `WorkspacePlanCapture.capture(workspace:)` to return a result type instead of a bare plan. Both Snapshot and Blueprint export are the only two callers; the migration is small and localized. Immediately surfaces lossy edges that are currently invisible.

4. **Parametric blueprint variables.** Add optional `parameters: [{name, prompt, default}]` to `WorkspaceBlueprintFile`. Add a pre-apply expansion step in the CLI/socket layer that resolves `{{VAR}}` substitutions in `command`, `url`, `working_directory`, and `title`. The executor never sees variables — it always receives a concrete plan. The picker already has interactive stdin infrastructure; parameter prompting follows the same pattern. This is a `WorkspaceBlueprintParameters.swift` new file, not a change to executor internals.

5. **Rename `.config/cmux/blueprints/` to `.config/c11/blueprints/`** with a migration shim in `perUserBlueprintURLs()`. Do it before blueprints accumulate in user home directories. Check for old directory on first access; move contents if present; log a one-time deprecation notice. Three hardcode locations confirmed.

6. **`workspace.get_plan` socket command.** One `v2MainSync` block calling `WorkspacePlanCapture.capture(workspace:)`, encode to JSON, return in response body. No file write. Agents read current workspace topology as structured JSON without side effects. Pattern matches `v2WorkspaceExportBlueprint` exactly.

7. **Ship "phase2" registry as soon as flags are confirmed.** The `AgentRestartRegistry.named(_:)` binding decouples wire protocol from registry versions. Once `opencode --continue` and `kimi --continue` are confirmed (or confirmed to not exist), add a `phase2` registry with verified rows and emit a `restart_registry_best_effort` warning (not failure) in `WorkspaceLayoutExecutor` when a best-effort row fires. The "phase1" name becomes a permanent compat alias.

8. **Blueprint round-trip invariant test.** Add to `WorkspaceBlueprintFileCodableTests.swift` or a new file. Uses the existing fake `TabManager` pattern from `WorkspaceLayoutExecutorDependencies` Phase 0 tests. The invariant: `capture(apply(plan)) ≅ plan`. This is the test that guarantees the persistence promise.

9. **Make `.md` blueprints first-class documents.** Codex and Gemini both named this. Discovery already accepts `.md` files; today picker reads them as raw JSON. Add a parser: YAML front matter or fenced `workspace-plan` JSON block carries the plan, body is prose/instructions. Backward compatibility: current tests write JSON content to `.md` — keep JSON-only `.md` working as a fallback.

10. **Add `--description` to `c11 workspace export-blueprint`.** Gemini flagged: `WorkspaceBlueprintFile.description` can only be set at export time, and only programmatically. Allow `c11 workspace export-blueprint --description "..."` as a CLI flag. Small addition in `CLI/c11.swift`, improves every downstream picker display.

11. **Versioning contract section in `docs/workspace-apply-plan-schema.md`.** The schema is the public API for agents and blueprint authors. Add explicit stability promise: optional fields are additive and free; new required fields bump the version; breaking semantics bump the version. `WorkspaceLayoutExecutor.supportedPlanVersions` is already the enforcement point.

---

## 3. Wildest Mutations

Creative and ambitious ideas worth exploring, ranked by ambition:

1. **Blueprints as Lattice task `launch_spec`.** Claude's mutation. A Lattice task carries a blueprint inline or by reference. When the task is started, Lattice calls `workspace.apply` with the embedded plan and configures the agent's pane from the spec. "Create task" and "configure workspace" collapse into one action. Requires cross-repo coordination (`lattice-stage-11-plugin`), but the socket interface is already in place. This is the move that makes workspace layout part of Lattice's operational contract.

2. **Blueprint-as-CI-environment.** Claude's mutation. The schema already describes a running environment (terminals with commands, browsers at URLs). With minor additions, a blueprint describes a CI check environment: "this test requires a terminal running `npm start` and a browser at localhost:3000." A "headless apply" mode (no UI, capture stdout) makes blueprints the unit of reproducible environment specification — closer to Devcontainer than to tmux layouts.

3. **Workspace genetics / composition operators.** Codex's mutation. Because `LayoutTreeSpec` is recursive and surfaces are id-keyed, composition is plausible: `workspace compose --left blueprint-a --right blueprint-b`, append a sidecar pane, replace a leaf, merge metadata, graft one blueprint into another. The hard part is stable conflict behavior for ids and divider positions. Prototype as pure transforms before exposing in the app.

4. **`workspace.watch` for live topology events.** Claude's experimental suggestion. Agents subscribe to workspace topology changes (surface added/removed/metadata changed) and react without polling. Start with a simple "workspace changed" event with no payload; agents re-query `workspace.get_plan` on receipt. Non-trivial with bonsplit's AppKit-bound state model but follows the existing notification infrastructure pattern.

5. **The workspace as an AI reasoning artifact.** Claude's mutation. Because `WorkspacePlanCapture` produces stable JSON, an LLM can reason over workspace topology directly: "Here is my current workspace state (JSON). What surfaces suggest I'm doing X? What should I add?" Most agent tools observe the environment through process-level affordances (terminal I/O, screenshots). Structured JSON topology is cheaper, lossless, and manipulable. The `workspace.get_plan` socket command (suggestion #6 above) is the enabling primitive.

6. **Snapshot timeline / automatic savepoints.** Codex's suggestion. `snapshot --all` already captures the whole room. Add a policy layer: before quit, before reload, every N minutes when dirty, before risky socket operations. Turns CMUX-37 from "restore one workspace" into "rewind the operator's command center." Requires throttling and storage policy; `--all` manual mode stays simple and explicit.

7. **Live Blueprint hot-reload.** Claude's mutation. `WorkspaceBlueprintStore` watches sources for changes via `DispatchSource`/FSEvents; picker refreshes live without re-running `c11 workspace new`. More ambitiously: if an operator edits a blueprint while it's applied, `workspace.apply` computes a diff and hot-patches the live workspace. "Live reload for workspace layout."

8. **Plan preview thumbnails.** Codex's mutation. `WorkspaceApplyPlan.layout` is deterministic enough to render a tiny split diagram without touching AppKit. Blueprint picker shows ASCII art preview today; graphical picker later. Pure text rendering is implementable today in the CLI as part of `WorkspacePlanKit`.

9. **Room contracts for repos.** Codex's experimental suggestion. Repo blueprint discovery already walks upward from cwd. Formalize: `.cmux/blueprints/default.md` plus a `c11 workspace lint` CI check. Opening a repo in c11 suggests: "This project defines an agent-review room, a release room, a test-triage room." Workspace layout becomes part of the codebase's operational contract. Important constraint: suggest or list only — never auto-launch, per c11's unopinionated-about-terminals principle.

---

## 4. Leverage Points and Flywheel Opportunities

### Primary leverage points

1. **The `WorkspaceApplyPlan` capture/apply spine.** All three models agreed this is the highest-leverage code. Every improvement to `WorkspacePlanCapture.capture()`, `WorkspaceLayoutExecutor.apply()`, and the `WorkspaceApplyPlan` schema compounds across blueprints, snapshots, restore, CLI automation, and any future UI. The spine is already clean; the leverage move is to give it a pure toolkit (`WorkspacePlanKit`) so callers never touch it raw again.

2. **`WorkspaceBlueprintStore.merged(cwd:)`.** Single discovery entry point. Adding a fourth source (remote/URL/git) requires one `result.append(contentsOf:)` call plus a source implementation. The `directoryOverride:` injection already makes new sources testable in isolation. The leverage move: add a `sources` parameter so `c11 snapshot --all` and `workspace new` can filter source types without global state.

3. **The `AgentRestartRegistry.named(_:)` name binding.** Wire protocol decoupled from registry versions. Adding `phase2` with verified flags is zero schema change. `phase1` becomes a permanent compat alias. The leverage move: the moment `opencode`/`kimi` flags are confirmed, ship `phase2` with honest `RestartResolution.exactness` field and the flywheel's weakest link (unreliable agent resume) closes.

4. **The CLI picker.** Currently a numbered list. The leverage move: add parameter prompting (enabling parametric blueprints), source filtering (`--source built-in`), and plan preview. The picker is the user-facing surface for the entire blueprint system; improvements here are visible on every `c11 workspace new` invocation.

### The flywheel

All three models described the same self-reinforcing loop, with slightly different emphasis:

1. Operators arrange useful workspaces in c11.
2. `workspace export-blueprint` captures them — zero friction.
3. Blueprints are committed to repos (`.cmux/blueprints/`) or shared via URL/git remote.
4. Team members and agents launch better rooms instantly from the picker.
5. Rooms include correct metadata, panes, and restart hints — agent resume works.
6. Agents running in well-configured workspaces produce more reliable work.
7. Operators refine blueprints based on agent performance and export again.
8. The library grows richer; c11 becomes not just a multiplexer but a memory system for compound operator:agent workflows.

**Flywheel's weakest link (all three models agreed):** step 3 — sharing. Without a frictionless sharing mechanism (git-backed palettes, URL blueprints, or at minimum committed repo blueprints with documented conventions), blueprints stay per-operator and the network effect never fires. The second weakest link: step 5 — the skill file. Agents can already call `workspace.apply` and `workspace.list_blueprints` via socket, but if the c11 skill doesn't teach them blueprints exist, they never use them. The flywheel stalls on agent ignorance.

### The highest-leverage single action

If forced to one: **extract `WorkspacePlanKit` first.** It is the foundation that makes `c11 workspace lint`, `c11 workspace diff`, parametric blueprints, `.md` blueprint documents, and the round-trip invariant test all buildable without re-solving the codec problem every time. Everything else listed in this synthesis is easier after the pure layer exists.
