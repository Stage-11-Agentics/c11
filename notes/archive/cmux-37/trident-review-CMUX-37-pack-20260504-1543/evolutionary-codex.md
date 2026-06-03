## Evolutionary Code Review
- **Date:** 2026-05-04T19:57:44Z
- **Model:** Codex / GPT-5
- **Branch:** cmux-37/final-push
- **Latest Commit:** aea6eaa8cf308fa60f69260bec91ffefe2615850
- **Linear Story:** CMUX-37
- **Review Type:** Evolutionary/Exploratory
---

Scope note: the wrapper prompt says this is read-only except for this review file, so I did not run `git pull`, mutate the branch, run tests, or launch a build. Local status shows `cmux-37/final-push...origin/cmux-37/final-push` with no ahead/behind marker. Project policy also forbids local test runs.

## What's Really Being Built

CMUX-37 is not just workspace persistence. It is the first version of a **workspace intent graph**: a serializable description of what the operator-agent room means, plus enough replay machinery to bring that room back.

The important shift is that c11 now has three layers of persistence, each with a different audience:

- `WorkspaceApplyPlan` is the machine execution IR.
- Markdown blueprints are the human-editable operator notes form.
- Snapshot sets are the "save the whole room" operational artifact.

That combination is powerful because it points c11 toward reproducible agent rooms. The next system this almost enables is not "restore my panes"; it is "ship a working environment as an artifact, inspect it, fork it, compare it, and replay it."

## Emerging Patterns

The strongest emerging pattern is a **pure-value core with socket adapters around it**. `WorkspaceBlueprintMarkdown` is Foundation-only (`Sources/WorkspaceBlueprintMarkdown.swift:57`), `WorkspaceSnapshotSetFile` is pure Codable (`Sources/WorkspaceSnapshotSet.swift:34`), and the socket handlers in `Sources/TerminalController.swift` mostly translate between live AppKit state and those values. That is the right evolutionary direction.

A second pattern is **socket safety through id staging**. Snapshot restore keeps path reads in the CLI and submits ids to the socket (`CLI/c11.swift:3367`), while store reads validate safe ids and root containment (`Sources/WorkspaceSnapshotStore.swift:385`). This pattern should become a named persistence boundary: "CLI may read arbitrary user paths; socket may only resolve managed ids."

A third pattern is **compatibility-as-discovery**, not compatibility-as-default. Blueprints write to `~/.config/c11/blueprints` but still read `~/.config/cmux/blueprints` (`Sources/WorkspaceBlueprintStore.swift:99`). Snapshots write to `~/.c11-snapshots` but still read `~/.cmux-snapshots` (`Sources/WorkspaceSnapshotStore.swift:15`). This is a durable migration convention worth formalizing.

The main anti-pattern forming is **policy hidden in string matching**. Restore diagnostic classification currently lives in the CLI and treats every `metadata_override` as info (`CLI/c11.swift:2882`), even though `WorkspacePlanCapture` explicitly says divergent title metadata is a real conflict (`Sources/WorkspacePlanCapture.swift:148`). That is the right compromise for the smoke gap, but a weak long-term contract.

## How This Could Evolve

The natural architecture is a small artifact subsystem:

- Artifact kinds: `plan`, `blueprint`, `snapshot`, `snapshot_set`
- Formats: JSON, Markdown, maybe future bundle/tar
- Capabilities: lossless, human-editable, restorable, multi-workspace, externally portable
- Operations: inspect, validate, import, export, diff, restore

Right now that subsystem is spread across `WorkspaceBlueprintStore`, `WorkspaceSnapshotStore`, `WorkspaceBlueprintMarkdown`, `WorkspaceSnapshotSetFile`, and CLI helper code. The shape is already there. Naming it would make the next ten persistence features cheaper.

Another strong next step is a **workspace diff primitive**. Because `WorkspacePlanCapture.capture(workspace:)` produces the same IR that blueprint/snapshot restore consumes (`Sources/WorkspacePlanCapture.swift:10`), c11 can compare live state against a blueprint or snapshot without inventing a new model. That opens operator workflows like "what changed since this room was restored?" or "does this smoke workspace still match the acceptance blueprint?"

## Mutations and Wild Ideas

**Blueprints as recipes.** Markdown blueprints could accept variables, small conditionals, and environment selectors:

```yaml
vars:
  repo: ~/Projects/Stage11/code/c11
  lattice: http://localhost:8799/
```

That would turn one blueprint into many operator rooms without becoming a full programming language.

**Snapshot sets as room bundles.** The current set manifest is intentionally a pointer file. A future portable bundle could include the set manifest, inner snapshots, a Markdown README, validation summary, and optional screenshots. That becomes something an operator can attach to a Lattice ticket: "here is the whole failing room."

**Replay diff as review substrate.** A Trident reviewer could receive a blueprint/snapshot plus the branch and say: "this PR's persistence artifact changes the room from A to B." That moves code review from file diffs into workspace diffs.

**Agent-room provenance.** Snapshot set entries already record `workspace_ref`, `snapshot_id`, `order`, and `selected` (`Sources/WorkspaceSnapshotSet.swift:80`). Add `created_by_surface`, agent model, task id, and parent lineage and c11 gets a provenance graph of who created which room state.

## Leverage Points

1. The highest leverage point is the shared IR boundary around `WorkspaceApplyPlan`. Every tool that can parse to this shape gets restore, diff, validate, and inspect for free.
2. The next leverage point is command metadata. Help text, parsing, examples, tests, and skill docs are manually kept in sync today (`CLI/c11.swift:9187`, `CLI/c11.swift:14791`). A command registry would reduce drift.
3. The third leverage point is diagnostic typing. Once diagnostics are structured, smoke validation and automation can reason about expected degradation without grepping human text.
4. The fourth leverage point is artifact inspection. Pure parser/store code means many checks can run offline, before connecting to a socket or launching the app.

## The Flywheel

The flywheel is:

1. Capture live operator rooms into stable artifacts.
2. Make artifacts human-readable enough that operators edit and share them.
3. Use artifacts in smoke tests and Trident reviews.
4. Feed failed rooms back as new artifacts.
5. Improve restore/diff/inspect until every tricky workflow has a reproducible room attached.

The compounding effect is that every future c11 feature can ship with a blueprint or snapshot fixture. The product becomes easier to validate because the workspace itself becomes test data.

## Concrete Suggestions

1. **High Value — Promote restore diagnostics to a structured contract.** ✅ Confirmed — the current CLI classifier marks all `metadata_override` entries as info (`CLI/c11.swift:2882`), but capture only strips redundant title metadata when values exactly match (`Sources/WorkspacePlanCapture.swift:158`) and intentionally preserves divergent conflicts. Keep the smoke behavior, but add an executor-side diagnostic field such as `classification: "expected_roundtrip" | "conflict" | "failure"` or a narrower code for seed-terminal cwd reuse. Risk: wire shape changes need compatibility; use optional fields so old clients keep working.

2. **High Value — Make snapshot sets transaction-ledger-like.** ✅ Confirmed — `snapshot --all` only appends entries for captures that return an envelope (`Sources/TerminalController.swift:4748`) and writes a manifest listing successful inner snapshots even after partial write failures (`Sources/TerminalController.swift:4790`). That is pragmatic, but the set should also record expected workspace count, omitted/capture-failed workspaces, per-inner checksums, and manifest completeness. This would let `restore <set-id>` distinguish "restored a partial set correctly" from "silently missed part of the room."

3. **High Value — Add offline artifact inspection commands.** ✅ Confirmed — markdown parsing is pure (`Sources/WorkspaceBlueprintMarkdown.swift:125`), snapshot set decoding is pure Codable (`Sources/WorkspaceSnapshotSet.swift:34`), and store listing already does shallow summary reads (`Sources/WorkspaceSnapshotStore.swift:556`). Add `c11 blueprint inspect <path>`, `c11 snapshot inspect <id|path>`, and `c11 snapshot verify-set <id>` that do not require a live socket. This gives CI and operators a cheap validation path without launching c11.

4. **Strategic — Create a persistence artifact registry.** ✅ Confirmed — blueprint and snapshot stores independently implement extension dispatch, date formatting, path discovery, atomic writes, id safety, and index summaries (`Sources/WorkspaceBlueprintStore.swift:158`, `Sources/WorkspaceSnapshotStore.swift:205`). A small registry could centralize artifact kind, format, reader, writer, capabilities, default paths, and legacy paths. Risk: do not abstract too early; start by extracting only metadata and inspection, not the full I/O surface.

5. **Strategic — Formalize Markdown blueprint as a projection profile.** ✅ Confirmed — serialization intentionally drops workspace metadata, surface descriptions, surface metadata, and pane metadata (`Sources/WorkspaceBlueprintMarkdown.swift:52`). That is acceptable for hand-authored blueprints, but default export now creates a non-lossless artifact. Add a capability marker or export note like `fidelity: layout` vs `fidelity: full`, and have `export-blueprint` report dropped fields when present. This turns surprise data loss into an explicit design choice.

6. **Strategic — Generate help, parser hints, and skill docs from one command table.** ✅ Confirmed — `workspace <sub> --help` is fixed through handcrafted dispatch (`CLI/c11.swift:9187`), top-level usage is another handcrafted block (`CLI/c11.swift:14791`), and the socket auto-discovery plan mentions `--quiet` but this diff only implements `C11_QUIET_DISCOVERY` (`CLI/c11.swift:1474`). A command table with flags, examples, socket need, focus intent, and environment variables could generate help text, tests, and c11 skill snippets. Risk: keep it lightweight; a static Swift table is enough.

7. **Experimental — Parameterized blueprints.** ❓ Needs exploration — the YAML subset already has a focused grammar (`Sources/WorkspaceBlueprintMarkdown.swift:593`). Variables could be added above `layout:` without changing the apply IR. This needs a careful "no arbitrary execution" rule.

8. **Experimental — Workspace diff.** ✅ Confirmed — live capture and restored artifacts converge on `WorkspaceApplyPlan`, so a structural diff can compare layout tree, surface kinds, titles, URLs, cwd, file paths, and metadata. This would be valuable for smoke reports and PR validation.

9. **Experimental — Portable room bundle.** ❓ Needs exploration — current snapshot sets are pointer manifests by design. A future bundle format could package the set plus inner snapshots, README, and screenshots. This is probably a separate artifact kind, not a replacement for the current lightweight set manifest.

## Final Read

This PR is closing smoke gaps, but the evolutionary signal is bigger: c11 is gaining an artifact layer. The best next moves are to name that layer, make diagnostics machine-trustworthy, and add offline inspect/diff/verify tools so every future room can become a reproducible object.
