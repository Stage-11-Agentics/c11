## Evolutionary Code Review
- **Date:** 2026-04-24T18:55:03Z
- **Model:** Codex (GPT-5)
- **Branch:** cmux-37/phase-1-snapshots-restore
- **Latest Commit:** 2047daff97f99905bccd0bf74a81fe6b703f8c27
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory
---

## Scope Notes

Reviewed the seven Phase 1 commits in `git log --oneline 43807212^..HEAD`, with the local branch at `2047daff`. I did not fetch, pull, commit, push, or run tests: the wrapper prompt's read-only contract allows only inspection plus this single output file, and `CLAUDE.md` says tests run in CI/VM only.

## What's Really Being Built

CMUX-37 Phase 1 is not just "workspace persistence." It is the first version of **workspace memory as executable infrastructure**.

The key move is that snapshots wrap `WorkspaceApplyPlan`, the same declarative plan shape that Blueprints will use (`Sources/WorkspaceApplyPlan.swift:3`, `Sources/WorkspaceSnapshot.swift:3`). That turns a live workspace into an intermediate representation that can be stored, inspected, transformed, and re-executed. The Claude resume work is the first proof that this IR can carry more than geometry: surface metadata becomes a restart hint, and restore-time behavior changes without changing the snapshot file (`Sources/AgentRestartRegistry.swift:8`, `Sources/WorkspaceLayoutExecutor.swift:183`).

The larger capability is a **replayable agent room**: panes, surfaces, titles, metadata, mailbox addressing, and agent session handles become restorable state. Once that state is executable, it can become branchable, portable, migratable, and eventually schedulable.

## Emerging Patterns

**Plan-as-IR is the strongest pattern.** `WorkspaceSnapshotConverter.applyPlan` is currently an identity transform with version checks (`Sources/WorkspaceSnapshotConverter.swift:76`), but the seam is exactly where future migrations, portability rewrites, and branch transforms want to live. This should be named and defended as the "workspace IR" layer, not treated as an incidental snapshot detail.

**Metadata is becoming the capability bus.** `terminal_type`, `claude.session_id`, `mailbox.*`, `model`, `role`, and titles are all converging on metadata as the surface/pane contract (`Sources/WorkspaceMetadataKeys.swift:22`, `Sources/WorkspaceSnapshotCapture.swift:214`, `Sources/WorkspaceLayoutExecutor.swift:716`). This is powerful, but it will need namespacing and capability descriptors before codex/opencode/kimi restart rows arrive.

**The restart registry is a strategy seam disguised as a command lookup.** Today a row maps `(terminal_type, sessionId, metadata)` to one shell string (`Sources/AgentRestartRegistry.swift:23`, `Sources/AgentRestartRegistry.swift:44`). That is perfect for Phase 1, but too small for multi-agent restart. Some agents will need preflight, env, cwd repair, prompt-file injection, readiness checks, or a sequence of commands.

**Pane metadata attached to the first surface is a clever compatibility bridge.** Capture writes pane metadata onto only the first surface in a pane (`Sources/WorkspaceSnapshotCapture.swift:135`), and restore writes it through that surface's resolved pane (`Sources/WorkspaceLayoutExecutor.swift:792`). This is valid for round-trip, but it encodes pane state through a surface ordering convention. If snapshots become editable, diffable, or branchable, pane metadata deserves its own first-class slot in the IR.

**String constants are already testing the future boundary.** The app target has `SurfaceMetadataKeyName.claudeSessionId` (`Sources/WorkspaceMetadataKeys.swift:29`), while the CLI hook uses the literal `"claude.session_id"` because it does not link that file (`CLI/c11.swift:12634`). That is acceptable in Phase 1, but as the metadata bus grows, key drift becomes a strategic risk.

## How This Could Evolve

1. **Snapshot lineage and branching.**
   Add optional envelope fields such as `parent_snapshot_id`, `branch_id`, `restored_from_snapshot_id`, `capture_reason`, and `actor_surface_id` around the existing `WorkspaceSnapshotFile` envelope (`Sources/WorkspaceSnapshot.swift:27`). The store currently lists snapshots as a flat newest-first sequence (`Sources/WorkspaceSnapshotStore.swift:164`); lineage would let c11 show "branch from this room," "return to checkpoint," and "compare workspace branches."

2. **Restart intents instead of restart commands.**
   Evolve `AgentRestartRegistry.Row.resolve` from `String?` into `RestartIntent?`, while preserving the Phase 1 string path as a convenience. A restart intent could include `command`, `workingDirectory`, `environment`, `requiresMetadata`, `readinessProbe`, `privacyNotes`, and `fallback`. The executor currently sends one command directly (`Sources/WorkspaceLayoutExecutor.swift:225`); wrapping that in an intent would make codex/opencode/kimi rows genuinely one-line additions only when their behavior is simple.

3. **Portable workspace bundles.**
   `SurfaceSpec` currently stores absolute `workingDirectory` and markdown `filePath` values (`Sources/WorkspaceApplyPlan.swift:67`, `Sources/WorkspaceApplyPlan.swift:74`), and fixtures already encode `/tmp/plan.md` (`c11Tests/Fixtures/workspace-snapshots/mixed-surfaces.json:42`). A portability layer could rewrite paths through named anchors: `repoRoot`, `home`, `workspaceRoot`, `artifactRoot`. For cross-machine restore, bundle local markdown files and maybe browser URL state alongside the envelope.

4. **Plan transforms as a formal pipeline.**
   The converter is pure and Linux-friendly (`Sources/WorkspaceSnapshotConverter.swift:1`), which makes it a natural host for transforms: schema migration, path rewrite, title normalization, session resume opt-in, redaction, and "restore as blueprint." Keeping this off the socket and main actor preserves the good Phase 1 isolation.

5. **Group snapshots for multi-workspace restarts.**
   `snapshot.create` captures one workspace (`Sources/TerminalController.swift:4462`), and `origin` already anticipates `auto-restart` (`Sources/WorkspaceSnapshot.swift:46`). The next mutation is a `WorkspaceSnapshotSet` or manifest that captures many workspaces plus their focus/order relationships. That becomes the primitive for "restart my whole agent fleet after app relaunch."

6. **Pane identity independent from surfaces.**
   `LayoutTreeSpec.PaneSpec` currently carries only surface IDs and selection (`Sources/WorkspaceApplyPlan.swift:150`). If pane metadata becomes first-class, a pane could have a stable plan-local ID, title, mailbox subscriptions, restart policy, and perhaps "agent group" semantics. This would make mailbox and swarm operations less dependent on the first surface in a pane.

## Mutations and Wild Ideas

**Time-travel workspaces.** Every significant workspace change could emit an auto snapshot with lineage. The UI could scrub through workspace history: "before review," "after test failure," "after agent split." Because snapshot IDs are time-ordered ULID-shaped strings (`Sources/WorkspaceSnapshot.swift:114`), the storage already wants this.

**Branching rooms.** Restore a snapshot twice with different branch IDs, assign one agent group to each, then compare outcomes. This is not just persistence; it becomes an experiment harness for agentic work.

**Restart choreography.** Use pane metadata and mailbox subscriptions to restart agents in dependency order: orchestrator first, then workers, then observers. `mailbox.*` already identifies communication topology (`c11Tests/Fixtures/workspace-snapshots/mixed-claude-mailbox.json:43`); restart could use it as a graph.

**Snapshot as handoff artifact.** A snapshot bundle plus markdown notes could be sent to another machine. Restore would recreate the room, show missing paths as repair prompts, and resume only agents whose session providers are available.

**Workspace diff and merge.** Since `WorkspaceApplyPlan` is a Codable tree plus surface list, c11 could diff two snapshots: added panes, changed titles, changed mailbox subscriptions, changed agent sessions. Merging could become "take layout from A, session handles from B."

## Leverage Points

**Smallest high-leverage schema addition:** optional lineage fields on `WorkspaceSnapshotFile` and `WorkspaceSnapshotIndex`. Optional fields preserve old files, and the list UI can stay flat until a graph view exists.

**Best near-term abstraction:** `RestartIntent`. It keeps Phase 1 behavior intact while preventing Phase 5 from stuffing multiple TUI-specific behaviors into a single string-returning closure.

**Most important documentation move:** name the IR. The skill already documents `c11 snapshot`, `c11 restore`, and the `C11_SESSION_RESUME` gate (`skills/c11/SKILL.md:465`), but it should eventually teach agents that snapshots and blueprints share the same plan primitive. That will make future agents reason in plan transforms instead of shell scripts.

**Most fragile convention to harden early:** pane metadata through first surface. It is fine for capture/restore but awkward for editing, graphing, and branching. Add a first-class pane ID before external tools start generating plans.

## The Flywheel

1. Agents write richer metadata because c11 makes metadata visible and useful.
2. Snapshots preserve that metadata, making restored rooms more faithful.
3. Faithful restore encourages operators to use c11 for more agent fleets.
4. More fleets produce more metadata conventions, mailbox topologies, and restart policies.
5. Those conventions make snapshots smarter, which makes restore more valuable.

The flywheel spins fastest if the schema stays small but the transform layer gets powerful. Do not push every future feature into the snapshot file; make the envelope stable, then let pure transforms and registry strategies evolve around it.

## Concrete Suggestions

1. **High Value - Add optional lineage fields to the snapshot envelope.** ✅ Confirmed.
   Extend `WorkspaceSnapshotFile` (`Sources/WorkspaceSnapshot.swift:27`) with optional `parentSnapshotId`, `branchId`, `restoredFromSnapshotId`, and `captureReason`. Extend `WorkspaceSnapshotIndex` (`Sources/WorkspaceSnapshot.swift:80`) with enough of this metadata for `list-snapshots` to show ancestry later. This is compatible with the current Codable shape if fields are optional and omitted when nil. Risk: be deliberate about privacy; lineage should not accidentally capture transcript paths or host-specific secrets.

2. **High Value - Replace string-only restart results with `RestartIntent`.** ✅ Confirmed.
   Keep `AgentRestartRegistry.phase1` behavior identical, but let `Row.resolve` return a value type with at least `command: String`, `displayName`, `requiredMetadata`, and `fallbackReason`. The executor can initially read only `.command` at `Sources/WorkspaceLayoutExecutor.swift:225`. This is compatible because `AgentRestartRegistry` is not Codable (`Sources/AgentRestartRegistry.swift:8`) and is resolved app-side at restore time (`Sources/TerminalController.swift:4578`). Risk: avoid overfitting the first intent to Claude Code; codex may need file-reference prompt injection rather than a simple resume flag.

3. **High Value - Make pane metadata first-class in the IR before generated plans proliferate.** ✅ Confirmed.
   Add plan-local pane IDs and optional pane metadata to `LayoutTreeSpec.PaneSpec` (`Sources/WorkspaceApplyPlan.swift:150`) instead of attaching pane metadata only to the first surface (`Sources/WorkspaceSnapshotCapture.swift:135`). Keep the current first-surface path as a v1 compatibility reader. This is compatible as a versioned plan migration in `WorkspaceSnapshotConverter` (`Sources/WorkspaceSnapshotConverter.swift:76`). Risk: requires executor changes so pane metadata is written after pane creation even if no surface carries it.

4. **Strategic - Introduce a pure plan-transform pipeline.** ✅ Confirmed.
   Make the converter the home for ordered transforms: validate envelope, migrate plan, rewrite portability anchors, redact secrets, then return `WorkspaceApplyPlan`. It already has the isolation properties needed for this (`Sources/WorkspaceSnapshotConverter.swift:1`). Risk: keep restore-time opt-in behavior like `C11_SESSION_RESUME` out of the converter; the current CLI-only env gate is the right boundary (`CLI/c11.swift:2782`).

5. **Strategic - Add a portability profile for paths and local assets.** ❓ Needs exploration.
   Store absolute paths today for cwd and markdown files (`Sources/WorkspaceApplyPlan.swift:67`, `Sources/WorkspaceApplyPlan.swift:74`). A profile could map `/Users/atin/Projects/...` to `$repoRoot` and bundle markdown files when needed. This fits naturally as a transform before apply, but it needs a design pass for missing files, path prompts, and security. Risk: blindly rewriting paths could launch agents in the wrong repo.

6. **Strategic - Define snapshot sets for whole-room restart.** ❓ Needs exploration.
   The `origin.autoRestart` enum case already points at app restart recovery (`Sources/WorkspaceSnapshot.swift:48`), but Phase 1 captures one workspace (`Sources/TerminalController.swift:4462`). A snapshot-set manifest could capture multiple workspace snapshot IDs, selected workspace, ordering, and maybe window layout. Risk: this crosses from workspace persistence into application session persistence; keep the single-workspace primitive clean.

7. **Experimental - Build a restart coordinator from mailbox topology.** ❓ Needs exploration.
   A restore could inspect `mailbox.subscribe` / `mailbox.delivery` pane metadata, restart orchestrators first, then workers, then watchers. The fixture already shows mailbox metadata and agent session metadata living in the same snapshot (`c11Tests/Fixtures/workspace-snapshots/mixed-claude-mailbox.json:38`). Risk: topology inference can be wrong; expose it as preview/diagnostic before automating.

8. **Experimental - Add workspace diff.** ✅ Confirmed.
   Because snapshots are Codable envelopes around `WorkspaceApplyPlan`, a diff tool can compare layout trees, surface lists, metadata, and session IDs without touching AppKit. Start with a CLI/debug command that compares two JSON files through the pure decoder. Risk: redact or abbreviate sensitive metadata values by default.

9. **Experimental - Promote the DEBUG send-text seam into an executor test dependency.** ⬇️ Lower priority than initially thought.
   `pendingInitialInputForTests` is properly `#if DEBUG` (`Sources/GhosttyTerminalView.swift:2595`) and keeps tests behavioral enough. Long-term, a `TerminalCommandSink` dependency would make command synthesis testable without reaching into `TerminalSurface`, but the current seam is acceptable for Phase 1.

## Validation Pass

✅ Converter purity and transform readiness: `WorkspaceSnapshotConverter.swift` imports only Foundation and performs no env, store, or AppKit work (`Sources/WorkspaceSnapshotConverter.swift:1`, `Sources/WorkspaceSnapshotConverter.swift:76`). This supports the plan-transform recommendation.

✅ Restart seam compatibility: the registry is not persisted, is resolved by name at restore time, and Phase 1 has only a `phase1` literal row (`Sources/AgentRestartRegistry.swift:59`, `Sources/AgentRestartRegistry.swift:68`, `Sources/TerminalController.swift:4578`). This supports evolving the in-process return type without snapshot schema churn.

✅ Explicit command precedence: executor trims and honors non-empty `SurfaceSpec.command` before consulting the registry (`Sources/WorkspaceLayoutExecutor.swift:197`). A richer `RestartIntent` can preserve this exact guard.

✅ Env gate remains at CLI restore boundary: `C11_SESSION_RESUME` / `CMUX_SESSION_RESUME` are read in `runSnapshotRestore` and only then thread `"phase1"` to `snapshot.restore` (`CLI/c11.swift:2782`). This is the right boundary; do not move it into the converter.

✅ Storage can grow lineage without disrupting writes: store writes by `snapshotId` and lists indexes from decoded envelopes (`Sources/WorkspaceSnapshotStore.swift:89`, `Sources/WorkspaceSnapshotStore.swift:203`). Optional lineage fields would be available to list without changing the basic storage model.

✅ Cross-machine portability gap is real: `workingDirectory` and `filePath` are plain strings in the plan (`Sources/WorkspaceApplyPlan.swift:67`, `Sources/WorkspaceApplyPlan.swift:74`), and fixtures demonstrate absolute-like paths. This makes portability a concrete future transform, not speculative polish.

✅ Skill contract was updated for Phase 1 usage: the c11 skill documents snapshot/list/restore and the session resume gate (`skills/c11/SKILL.md:465`). Future CLI or schema changes should continue to update the skill as the operator-agent contract.

## Bottom Line

The most interesting mutation is to treat CMUX-37 as the birth of a **workspace memory IR**. Keep `WorkspaceApplyPlan` as the executable substrate, add lineage around snapshots, make restart synthesis strategy-shaped instead of string-shaped, and let pure transforms handle migration and portability. That turns Phase 1 from restore functionality into the foundation for branching agent rooms, whole-fleet restart, and cross-machine handoff.
