# c11 — Pane Metadata & Naming Plan

**Status:** plan (not scheduled). **Author:** conversation 2026-04-18.
**Scope:** pane-level metadata layer with first consumer being a user/agent-assigned pane title that carries lineage as an operator moves through a task graph.
**Companion plans:**
- [Pane title bar chrome & theming](./c11-pane-title-bar-plan.md) — the visual consumer of this metadata (separate ticket, depends on this plan landing first).
- [Title Bar Fidelity improvements](../skills/cmux/SKILL.md) — the in-flight skill-side work that establishes the `::` lineage convention for surface titles. This plan reuses that convention rather than duplicating it.
- [Tier 1 persistence](./c11-tier1-persistence-plan.md) — Phase 2 persisted `SurfaceMetadataStore` losslessly. Pane metadata rides the same rails.
**Non-goals:** pane title bar rendering (Ticket 2, separate plan), window/workspace metadata parity (deferred — windows don't split; the case is simpler and can follow after panes prove the pattern).

---

## Motivation

Panes are first-class topology nodes in c11 — they hold surfaces, split, merge, move across workspaces — but they carry no identity of their own. A multi-surface pane's "name" today is implicitly whichever surface is active, which means the pane loses identity every time the operator switches tabs inside it. Newly spawned panes have no identity until a surface boots and a title is set.

Operators moving through a task graph (e.g., "login button" work spawns a "code review" sub-task in a new pane) want the pane itself to carry the lineage: `Login Button :: Code Review`. That string is a narrative, not a data structure — the operator glances at the pane and remembers why it exists. This plan gives panes a place to store that string (and anything else we might want later) and makes it durable across restart.

This plan is also the first consumer of the open `TODO.md:38` parity goal: *"Extend optional JSON attributes (currently surface-only) to panes and windows — full parity so any topology node can carry structured metadata."*

---

## Decisions (locked from scoping conversation)

1. **It's text. Trust the LLM.** Pane title is a free-form string managed by agents at the prose layer. No structured breadcrumb type, no merge rules, no close-time snapshotting — a single string field that agents compose, mutate, and occasionally reset. The `::` separator is a *convention*, not a system delimiter.
2. **Create-time seeding passes lineage for free.** `pane.create` and split commands take an optional `title` argument. The spawning agent (the one that calls create) is responsible for composing a good title, typically by reading its own current title and appending `:: <child role>`. c11 does not auto-copy — the intelligence lives at the LLM layer, per the "unopinionated host" principle.
3. **Rename is read-then-write by convention.** The `pane.set_metadata` RPC response includes the previous value so agents have it in-hand after a write; the skill documents the read-before-write norm so agents default to mutation over replacement. Agents can always replace wholesale when the new task is unrelated — trust the model.
4. **Breadcrumb survives ancestor closure.** Because the value is stored as plain text, closing an ancestor pane has no effect on descendants' titles. The string is frozen narrative.
5. **Full `PaneMetadataStore` parity with `SurfaceMetadataStore`.** Even though the first consumer (title) is just text, the plumbing matches surfaces so future pane-level metadata (status, role, progress) can land without a second migration.
6. **Windows out of scope.** Windows don't split and their naming is a separate mechanism (workspace titles). Defer until panes prove the pattern.
7. **`/clear` cue lives in the skill.** When an agent runs `/clear` (or equivalent context-reset), the skill instructs it to ask the operator whether to rename the pane. c11 installs no hooks into the agent — guidance only, per the principle file.
8. **Skill `::` convention is single-source-of-truth.** The Title Bar Fidelity work is landing the `::` lineage convention in `skills/cmux/SKILL.md` for surface titles. This plan does not re-document the convention; it adds a short "also applies to panes" cross-reference so there is one place to read the rules.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ Pane title bar chrome (Ticket 2, separate plan)          │  ← consumer
├──────────────────────────────────────────────────────────┤
│ PaneMetadataStore (new) — mirrors SurfaceMetadataStore   │  ← Phase 1
├──────────────────────────────────────────────────────────┤
│ Socket RPCs: pane.set_metadata / .get / .clear           │  ← Phase 2
│ CLI: cmux set-metadata --pane, --title on new-pane       │
├──────────────────────────────────────────────────────────┤
│ SessionPaneSnapshot extension (metadata + sources)       │  ← Phase 3
├──────────────────────────────────────────────────────────┤
│ Tier 1 Phase 2 persistence machinery                     │  ← already built
└──────────────────────────────────────────────────────────┘
```

Each phase lands as its own PR. Phase 1 is a scaffolding PR that ships an in-memory store nobody uses yet. Phase 2 gives agents an API. Phase 3 makes it durable. The final PR in this ticket — Phase 4 — adds skill guidance so agents actually use the API with discipline.

---

## Phase 1 — `PaneMetadataStore` (in-memory)

**Deliverable:** a new store class that panes can read/write metadata through, in-memory only. Not visible to operators or agents yet.

### Current state

Panes are opaque leaves in the bonsplit split tree (`vendor/bonsplit/Sources/Bonsplit/Internal/Models/PaneState.swift:6-18`). `PaneState` has `id: PaneID`, `tabs: [TabItem]`, `selectedTabId: UUID?` — no metadata field. Surface metadata lives in `Sources/SurfaceMetadataStore.swift` (546 lines): keyed by `surfaceId`, `[String: Any]` value bag with `SourceRecord {source, ts}` sidecars, 64 KiB per-surface cap, canonical `MetadataKey` enum, precedence chain `explicit > declare > osc > heuristic`.

### Target state

A new `PaneMetadataStore` at `Sources/PaneMetadataStore.swift` mirroring the surface store:
- Keyed by `PaneID`.
- Same value type (`Any` with `SourceRecord` sidecar) and same JSON value fidelity rules as surfaces.
- Canonical keys enum starts narrower — `title`, `description` — but reuses the `MetadataKey` machinery from the surface store via a small refactor (shared `MetadataKey` namespace, per-layer allowed-key sets).
- Same 64 KiB per-pane cap, same precedence logic. Most pane writes will be `source: explicit` (agent or operator); the heuristic/OSC layers from surfaces don't apply to panes.
- Same monotonic revision counter pattern for autosave fingerprint integration.

### Why not share the surface store

Keyed by different identifier types, different consumer lifecycles (panes can outlive surfaces and vice versa), different eventual key sets. A thin shared helper (for the JSON value type, source record, cap enforcement) plus two separate stores is cleaner than one polymorphic store.

### Tests

Unit tests mirror `SurfaceMetadataStoreTests`: set/get/clear, source precedence, cap enforcement, revision counter, snapshot round-trip via `PersistedJSONValue`. Skip OSC/heuristic source tests (not applicable to panes in v1).

### Not in this phase

No RPC, no CLI, no persistence wiring, no UI. The store is written to tests only.

---

## Phase 2 — Socket RPCs + CLI

**Deliverable:** agents and the CLI can read and write pane metadata over the socket. Title parameter added to pane-creation commands.

### Current state

Pane-addressing socket commands today (`Sources/TerminalController.swift:2159-2176`): `pane.list`, `pane.focus`, `pane.surfaces`, `pane.create`, `pane.resize`, `pane.swap`, `pane.break`, `pane.join`, `pane.last`. No metadata family. Surface metadata RPCs at `Sources/TerminalController.swift:2151-2156`: `surface.set_metadata`, `surface.get_metadata`, `surface.clear_metadata`.

### Target state

- **New RPCs:** `pane.set_metadata`, `pane.get_metadata`, `pane.clear_metadata`. Same argument shapes as the surface equivalents (`--key`/`--value`/`--type` or `--json`, `--source`, `--mode merge|replace`). Off-main threading per the socket policy in project CLAUDE.md.
- **`pane.create` gains `title: String?`.** If supplied, the store is seeded with `{title: <value>, source: explicit}` at pane creation time, atomic with the pane id becoming valid. No seeding from the parent — the caller passes the full intended value.
- **`pane.set_metadata` response returns the prior value** for every key written. This is the substrate for the "read-then-write by convention" guidance — agents get the old value back without a separate round trip.
- **CLI:** `cmux set-metadata`, `cmux get-metadata`, `cmux clear-metadata` already exist for surfaces with `--surface` targeting. Add `--pane <ref>` as a parallel target; when `--pane` is supplied, the command routes to the pane RPCs. `cmux new-pane` and `cmux new-split` gain an optional `--title <text>` argument.

### Targeting semantics

When both `--surface` and `--pane` are omitted, default to the caller's current surface (existing behavior). When `--pane` is supplied, the command operates on pane metadata. `--surface` and `--pane` are mutually exclusive on metadata commands; passing both is a usage error.

### Short refs

`pane:N` refs already work per `TODO.md:22`. The CLI accepts them everywhere surfaces use `surface:N` today.

### Tests

- `tests_v2/test_pane_metadata.py`: set/get/clear round-trip, source precedence, cap enforcement, prior-value-in-response, short-ref targeting.
- `tests_v2/test_pane_create_title.py`: `pane.create` with and without `title`; verify seeded value, source = explicit.
- CLI round-trip: `cmux set-metadata --pane pane:N --key title --value "foo"` then `cmux get-metadata --pane pane:N`.

### Not in this phase

No persistence yet — restart wipes pane metadata. No UI rendering of the title. Skill guidance lands in Phase 4.

---

## Phase 3 — Persistence via `SessionPaneSnapshot`

**Deliverable:** pane metadata survives restart.

### Current state

Tier 1 Phase 2 (commit `329e6324`) persisted `SurfaceMetadataStore` losslessly via `Sources/PersistedMetadata.swift` (`PersistedJSONValue` type, source attribution). `SessionPaneSnapshot` currently carries `id`, layout shape, tab order, selected tab — no metadata field.

### Target state

- **`SessionPaneSnapshot` gains** `metadata: [String: PersistedJSONValue]?` and `metadataSources: [String: PersistedSourceRecord]?` — optional, additive, same shape Phase 2 introduced for the surface snapshot.
- **Snapshot write path:** when the session autosave fingerprint triggers, pane metadata is serialized from `PaneMetadataStore` into the snapshot alongside existing pane fields.
- **Restore path:** on session restore, `PaneMetadataStore.restoreFrom(snapshot:)` is called after `PaneID`s are injected (Tier 1 Phase 1 already made those stable across restart).
- **Autosave fingerprint:** `PaneMetadataStore`'s revision counter is added to `AppDelegate.sessionFingerprint(...)` alongside the existing surface counter, so pane metadata writes trigger an autosave tick within the 8-second debounce window.
- **Schema:** stays at v1 with additive-optional decoding, matching the Tier 1 rule. The snapshot is forward-compatible with older builds (they ignore the new fields) and older snapshots decode with empty pane metadata (new builds see `nil` and initialize fresh).

### Cap enforcement on restore

If a restored snapshot carries more than 64 KiB of metadata for a pane (shouldn't happen — cap is enforced on write — but defensively), restore truncates and logs a warning to `DebugEventLog`. Same rule Phase 2 used for surfaces.

### Tests

- Round-trip: set pane metadata → write snapshot → read snapshot → verify values and sources match.
- Mixed old/new snapshots: an older snapshot without pane metadata fields decodes without error; pane metadata starts empty.
- Cap enforcement on restore: oversized snapshot truncates with warning.

### Not in this phase

Still no UI rendering of the title. Skill guidance lands in Phase 4.

---

## Phase 4 — Skill guidance

**Deliverable:** `skills/cmux/SKILL.md` teaches agents how to use pane metadata correctly. Single source of truth for the `::` lineage convention.

### Current state

The Title Bar Fidelity work (in-flight in a sibling c11 pane) is adding a **Tab naming (mandatory)** section to `skills/cmux/references/orchestration.md` and related sections in `SKILL.md` that establish:
- `::` separator, parent-first lineage.
- Orchestrator names the child's tab before launching the sub-agent.
- Sub-agents orient via `cmux get-titlebar-state` and preserve the prefix when renaming.
- Description field carries a breadcrumb line that must be preserved on update.

That work targets **surface** titles (`cmux set-title` / `cmux rename-tab`). It lands before or concurrently with this ticket.

### Target state

A new short subsection in `skills/cmux/SKILL.md` — immediately after the surface-title section — titled **Pane titles (same rules, pane layer)**. Content:
- One-sentence pointer: "the `::` lineage, orchestrator-names-child, and read-before-write rules documented above for surface titles apply identically to pane titles; set via `cmux set-metadata --pane <ref> --key title --value <text>` or the `--title` argument on `cmux new-pane` / `cmux new-split`."
- When to prefer pane titles over surface titles: a multi-surface pane needs an identity that outlasts tab switches; a single-surface pane is usually fine naming the surface.
- `/clear` cue: after the agent runs `/clear`, ask the operator whether to rename the pane before proceeding. One sentence; the agent decides its own phrasing.
- Write-returns-prior-value note: `pane.set_metadata` responses include the prior value — use it to mutate the existing title rather than wipe-and-replace unless the new task is genuinely unrelated.

Keep it under 40 lines. The existing Title Bar Fidelity section carries the weight; this section is a cross-reference with pane-layer specifics.

### Not in this phase

Theming, chrome, visual rendering — all Ticket 2.

---

## Open questions (resolved in scoping; recorded for audit)

| Question | Resolution |
|----------|-----------|
| Storage: structured breadcrumb vs. plain text? | Plain text. Trust the LLM. |
| Who authors the suffix on split? | The spawning agent, via the `title` argument on `pane.create`. The skill tells the calling agent to always include a reasonable title with `::` lineage. |
| Originating pane on split: does it also get a suffix? | No. Name stays unchanged unless the agent rewrites it. |
| Merge/close: does the breadcrumb shorten when an ancestor closes? | No. Plain text; closure has no effect on descendants. |
| Operator override: can you wipe and restart? | Yes. `pane.set_metadata` with a new title replaces the previous value. |
| Windows parity? | Deferred. Windows don't split; the case is simpler and follows later. |
| Storage shape: minimal `name: String?` vs. full store? | Full store. Satisfies `TODO.md:38` parity in one stroke; leaves room for future pane metadata. |
| Fallback to surface title when pane is unnamed? | No chrome in this plan — punt to Ticket 2. Mechanism ships without UI; tree/CLI output is the only visibility. |

---

## Open questions (unresolved)

None blocking. Ticket 2 will address chrome-layer questions (dual-title stacking, close semantics, theming integration) on its own plan.

---

## Rollout

- Phase 1 → Phase 2 → Phase 3 → Phase 4, each its own PR.
- Phase 1 and Phase 4 are low-risk; Phases 2 and 3 touch shared infrastructure (socket dispatch, session snapshot) and deserve focused review.
- This ticket has no user-visible UX. Completion means agents and CLI can set pane titles that survive restart, and the skill documents how. Ticket 2 then adds the visual layer.

## Touched code (by phase)

- **Phase 1:** `Sources/PaneMetadataStore.swift` (new), tests. Light refactor of `Sources/SurfaceMetadataStore.swift` to extract shared helpers if useful.
- **Phase 2:** `Sources/TerminalController.swift` (new RPC handlers), `Sources/CLI/cmux.swift` (new CLI flags), `vendor/bonsplit/Sources/Bonsplit/...` only if `pane.create` signature needs adjustment for the `title` seed.
- **Phase 3:** `Sources/SessionPersistence.swift` (snapshot extension), `Sources/PersistedMetadata.swift` (reuse existing types), `Sources/AppDelegate.swift` (fingerprint integration).
- **Phase 4:** `skills/cmux/SKILL.md`, `skills/cmux/references/orchestration.md` (small cross-reference).

---

## Risks

- **Surface/pane confusion.** Agents may set pane titles when they meant surface titles or vice versa. Mitigation: skill guidance explicitly calls out when to use each; CLI error on `--surface` + `--pane` together.
- **Skill section drift.** Two places to read the `::` convention means two places to keep in sync. Mitigation: pane section is intentionally thin — one paragraph pointing at the surface section. If drift becomes a problem, inline the content and delete the cross-reference.
- **Persistence format drift.** Pane metadata adds optional fields to `SessionPaneSnapshot`. Future deletions of those fields would be a breaking change. Mitigation: same additive-only discipline as Tier 1.
