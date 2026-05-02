# c11 — Tier 1 Persistence Plan

**Status:** plan (not scheduled). **Author:** conversation 2026-04-18.
**Revised:** 2026-04-18 after Trident plan review — fixed metadata-type fidelity,
reframed Phase 1 as a constructor refactor (not a remap removal), added
namespace/safety gates to Phases 4–5, and split rollout into Tier 1a
(durability) and Tier 1b (recovery UX).
**Scope:** surface-level metadata, panel identity, status-entry continuity, and a
Claude session-resume affordance.
**Companion plan:** [workspace-level metadata](./c11-workspace-metadata-persistence-plan.md) —
that plan explicitly parked "Restoring `SurfaceMetadataStore` across restart"; this plan claims it.
**Non-goal (Tier 2):** resuming live PTYs. Moves PTY ownership into `c11d` so shells survive app restart. Separate effort.

---

## Motivation

Two linked problems:

1. **The M-series features don't survive restart.** M1 (`terminal_type`),
   M3 sidebar chips (`model`, `role`, `status`), and M7 title/description all
   route through `SurfaceMetadataStore` (`Sources/SurfaceMetadataStore.swift`),
   which is documented as in-memory only
   (`Sources/SurfaceMetadataStore.swift:21`: *"In-memory only. Consumers that need
   durability persist externally."*). Every customization an operator or agent
   writes to a surface dies on reboot.
2. **Restart obliterates recoverability.** Even with PTYs gone, if we knew
   *what* was running in each surface (cwd, last command, Claude session id),
   we could offer a one-tap recreate/resume — turning catastrophic loss into a
   minor speed bump. That requires the metadata *and* something that can map a
   restored surface back to an external agent session without hooking into the
   agent itself (c11 observes from the outside — see memory
   `feedback_c11mux_no_agent_hooks.md`).

The plumbing substrate is already ~80% built: `Sources/SessionPersistence.swift`
snapshots window frames, workspace list, split tree, tab order, titles,
directories, sidebar width, logs, progress, git state, and truncated scrollback
to Application Support (`SessionPersistenceStore.defaultSnapshotFileURL`,
`Sources/SessionPersistence.swift:402-425`) every 8s. What is *not* ~80% built:
panel identity stability (Phase 1), the metadata value contract (Phase 2), and
the external-agent association layer (Phase 4). This plan closes the gaps and
adds the resume layer on top.

---

## Decisions (locked)

From the scoping conversation, amended after Trident review:

1. **Panel UUIDs become stable across restart via restore-time ID injection.**
   The `oldToNewPanelIds` remap is removed, *and* panel/surface constructors
   for terminal/browser/markdown must accept a restore-time `id` instead of
   minting a fresh `UUID()`. This is a constructor refactor, not a cleanup
   (see Phase 1).
2. **`SurfaceMetadataStore` joins the snapshot with lossless JSON fidelity.**
   The live store is `[String: Any]` with `SourceRecord {source, ts}` sidecars
   (`Sources/SurfaceMetadataStore.swift:71-75`). The persisted form must
   preserve both — string-only would silently break canonical numeric keys
   like `progress`. Full contents, 64 KiB per surface cap already enforced
   upstream; 32 MiB worst-case ceiling accepted, with a size metric gate
   (see Phase 2).
3. **`statusEntries` becomes persistent.** Today they're captured in the
   snapshot but discarded on restore (`Sources/Workspace.swift:246`). Stop
   discarding. Stamp each restored entry with a "last seen before restart"
   marker so stale state isn't misleading. Includes fidelity fix for `url`,
   `priority`, `format` fields currently dropped at serialization.
4. **`titleBarCollapsed` / `titleBarUserCollapsed` stay ephemeral.** Reset to
   default on restart. Simpler; revisit if users ask. Rationale: UX choice is
   session-local and almost always reset by user anyway once they resume work.
5. **Schema stays at v1 with optional decoding.** New fields are optional,
   decoded with defaults. Optional decoding covers the additive path; a v2
   bump is reserved for semantic (not structural) changes.
6. **Autosave fingerprint hooks via explicit monotonic revision counters.**
   Per-store counters (metadata store, status store) increment on every
   mutation; no-op writes (same key, same value, same source) skip the
   increment. `AppDelegate.sessionFingerprint(...)` consumes the counters.
7. **Rollout splits into Tier 1a (durability, Phases 1–3) and Tier 1b
   (recovery UX, Phases 4–5).** 1a ships first and stands alone; 1b
   re-justifies after 1a lands, M7 settles, and we have real measurement
   data. See Rollout order.

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ Recovery UI (title-bar "Resume" chip, CLI recreate cmd)  │  ← Phase 5  ┐
├──────────────────────────────────────────────────────────┤            │ Tier 1b
│ ClaudeSessionIndex (reads ~/.claude/projects/*)          │  ← Phase 4  ┘
├──────────────────────────────────────────────────────────┤
│ Persistent SurfaceMetadataStore + statusEntries          │  ← Phases 2–3  ┐
├──────────────────────────────────────────────────────────┤               │ Tier 1a
│ Stable panel UUIDs (constructor-level ID injection)      │  ← Phase 1     ┘
├──────────────────────────────────────────────────────────┤
│ Existing session snapshot + 8s autosave                  │  ← already built
└──────────────────────────────────────────────────────────┘
```

Each phase lands as its own PR, in order. Tier 1a is invisible plumbing that
makes M-series features durable. Tier 1b is the user-visible recovery layer
gated on Tier 1a + opt-out + shell-prompt safety.

---

## Phase 1 — Stable panel UUIDs (constructor refactor)

**Deliverable:** panel UUIDs survive across restart. Downstream systems
(metadata, status, logs, scrollback) can key by `panelId` without remap.

### Current state

Today the restore path in `Workspace.restore(from:)`
(`Sources/Workspace.swift:~215`) builds a layout tree by creating *new* panels
with fresh `UUID()` values, then records an `oldToNewPanelIds: [UUID: UUID]`
mapping. Scrollback, focus restoration, and a few other paths use that
mapping. Metadata (currently in-memory) isn't restored at all.

Panel IDs are minted inside constructors today:

- `Sources/Panels/BrowserPanel.swift:381` (and other call sites in the same
  file — 1039, 1082, 1218, 8491, 8746 — per grep).
- `Sources/Panels/MarkdownPanel.swift:72`.
- Terminal panels via `GhosttyTerminalView.swift` around the surface
  initializer (`id: UUID()`).

"Drop the remap" therefore **understates the work** — the remap exists to
paper over the constructor-level `UUID()` calls. Real stability requires
changing the constructors (or wrappers) to accept an optional restore-time
`id` parameter.

### Change

Two alternatives; Tier 1a ships **Alternative A**.

**Alternative A (adopted): restore-time ID injection.** Add an optional
`id: UUID?` parameter to each panel initializer that the normal creation path
leaves `nil` (falls through to `UUID()`). The restore path passes the
`SessionPanelSnapshot.id` explicitly. The `oldToNewPanelIds` mapping becomes
identity and can be removed.

Call sites touched:

- `Sources/Panels/BrowserPanel.swift` — `BrowserPanel.init` accepts
  `id: UUID? = nil`; usages at creation time (new tab, duplicate, split) leave
  it `nil`.
- `Sources/Panels/MarkdownPanel.swift:72` — same pattern.
- `Sources/GhosttyTerminalView.swift` — terminal surface initializer accepts
  the restore id; `Workspace.restore(from:)` threads the snapshot id through.
- `Sources/Workspace.swift:261-264` (focused panel fallback) — simplifies to
  direct lookup on `snapshot.focusedPanelId`.
- `Sources/Workspace.swift:~551` (scrollback fallback registration) —
  simplifies; `terminalPanel.id` already equals the snapshot id by construction.
- `Sources/Workspace.swift:~425-436` (scrollback takeover) — simplifies; no
  remap.

**Alternative B (rejected for Tier 1a): persistent alias layer.** Keep
runtime UUIDs ephemeral but add a `persistentSurfaceId: UUID` alongside on
each panel, used exclusively for metadata/status keying. Lower implementation
risk (no constructor surgery) but the user-visible `surface.list` IDs change
on every restart, which breaks external consumers (Lattice, CLI, scripted
tests) just as surely. Rejected because the external-consumer contract
change is the same in both paths; only Alternative A fixes it cleanly.

### Socket-API contract change

Stable panel UUIDs change an **implicit contract**: today external consumers
(Lattice, long-lived CLI sessions, scripts holding panel IDs) that cache
panel IDs see them silently invalidated on restart. Post-Phase-1, cached IDs
silently become valid again, which is arguably worse if the consumer assumed
they'd be invalidated.

Actions:

1. Document the new guarantee in `docs/socket-api-reference.md`: "Panel IDs
   are stable across app restarts within the same machine."
2. Audit external consumers: `CLI/cmux.swift` (no local cache — safe),
   `lattice-stage-11-plugin` (unknown — needs check), any agent Python
   harness in `tests_v2/` that snapshots IDs across sessions (check).
3. Add a debug/opt-out env var `CMUX_DISABLE_STABLE_PANEL_IDS=1` that
   re-enables the old remap for one release as a rollback safety net.

### Risks

- **Collision across independently-running cmux instances on the same
  machine.** Two home-directory-sharing users or a dotfiles-sync'd session
  across machines could theoretically see the same UUID. UUIDv4 collision
  probability is negligible; not a real concern in practice.
- **SwiftUI/AppKit view-identity dependencies on fresh UUIDs.** Some views
  may be using the UUID as a SwiftUI `id` and relying on regeneration to
  reset internal state. Audit `TabItemView`, `GhosttySurfaceScrollView`, and
  any `View.id(...)` modifier hanging off panel IDs. If any view depends on
  the id changing, force a view-level reset signal instead (e.g., a
  `restoredFromSnapshot: Bool` marker that resets caches explicitly).
- **Rollback path.** The `CMUX_DISABLE_STABLE_PANEL_IDS` flag (above) plus
  keeping `oldToNewPanelIds` code paths dead-but-present for one release
  gives a fast revert.

### Phase 1 tests

- `cmuxTests/PanelIdentityRestoreTests.swift`: round-trip a workspace snapshot
  with N panels of each type (terminal, browser, markdown); assert post-restore
  `panels.keys` equals pre-save `panels.keys`.
- `tests_v2/test_panel_id_stability.py`: create a surface, note its id via
  `surface.list`, save-and-restore session (via test harness), assert the same
  id reappears. CI-wired (socket test; uses tagged `CMUX_SOCKET` per project
  testing policy).
- `cmuxTests/PanelIdentityViewResetTests.swift`: mount a restored `TabItemView`
  (or equivalent) and assert no stale cached state survives where it shouldn't
  (e.g., notification counters).
- Regression: confirm focus-restoration, scrollback replay, and status-entry
  dedupe keep working without the remap.

---

## Phase 2 — Persist `SurfaceMetadataStore` (lossless)

**Deliverable:** canonical and custom metadata keys on every surface survive
restart, with full value-type fidelity and source attribution. M1/M3/M7
features become durable.

### Data model (lossless)

The live store is `[String: Any]` with numeric canonical keys like `progress`
(0.0–1.0 `NSNumber`) and a sidecar `SourceRecord(source: MetadataSource, ts:
TimeInterval)` per key (`Sources/SurfaceMetadataStore.swift:71-75`). A
string-only persisted form would silently drop types and timestamps — a
direct M2 spec violation. Use a Codable JSON wrapper instead.

```swift
// JSON-equivalent value: string | number | bool | array | object | null.
// Handwritten Codable impl; small (~40 lines). Roundtrips through
// JSONSerialization for the [String: Any] live store.
enum PersistedJSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([PersistedJSONValue])
    case object([String: PersistedJSONValue])
    case null
}

struct PersistedMetadataSource: Codable, Sendable {
    var source: String      // MetadataSource.rawValue
    var ts: TimeInterval    // seconds since 1970
}

struct SessionPanelSnapshot: Codable, Sendable {
    // existing fields...
    var metadata: [String: PersistedJSONValue]?        // NEW — lossless
    var metadataSources: [String: PersistedMetadataSource]?  // NEW — full sidecar
}
```

Both optional; additive-only. Empty dicts encode as `nil`.

### Save path

`SurfaceMetadataStore.getMetadata(workspaceId:surfaceId:)` already returns
`(metadata: [String: Any], sources: [String: [String: Any]])`
(`Sources/SurfaceMetadataStore.swift:256`). Add a thin adapter:

```swift
func snapshot(for surfaceId: UUID, in workspaceId: UUID)
  -> (metadata: [String: PersistedJSONValue],
      sources: [String: PersistedMetadataSource])
```

`AppSessionSnapshot.build(...)` calls this per panel at save time.

### Restore path

`Workspace.restore(from:)` calls a new
`SurfaceMetadataStore.load(surfaceId:metadata:sources:)` per restored panel,
*before* `pruneSurfaceMetadata` so the pruner sees the restored entries as
live. Because panel UUIDs are stable (Phase 1), the metadata keys line up
naturally — no remap required.

Conflict policy on restore: the stored `metadataSources[key].source` is
preserved on load. A subsequent write from a different source follows the
existing M2 precedence chain (`explicit > declare > osc > heuristic`); no new
precedence rule is introduced.

### Size & per-key policy

- The existing 64 KiB per-surface cap (`SurfaceMetadataStore`) continues to
  hold.
- Snapshots exceeding `SessionPersistencePolicy.maxPanelsPerWorkspace` (512)
  already truncate panels; metadata follows that truncation automatically.
- **New OSLog metric** emitted once per autosave: total metadata bytes
  across all panels. Lets us see real-world sizes and address rogue-agent
  bloat if it happens.
- **Per-non-canonical-key cap (open question, deferred).** Whether to impose
  a ≤4 KiB cap per non-canonical key to bound pathological bloat. Track in
  Open questions.

### Autosave fingerprint (explicit design)

`AppDelegate.sessionFingerprint(...)` (around `AppDelegate.swift:3548`) today
hashes cardinality counts, not values. That blind spot is pre-existing and
out of scope to fix wholesale. For this plan:

1. Add `metadataStoreRevision: UInt64` on `SurfaceMetadataStore`, incremented
   atomically on every mutation that actually changes state. **No-op writes
   skip the increment**: `set(key, value, source)` where `(key, value, source)`
   already matches returns early without bumping the counter. This prevents
   continuous-autosave churn from agents re-reporting unchanged progress.
2. Add `statusStoreRevision: UInt64` on `Workspace` for `statusEntries`
   mutations, with the same no-op dedupe rule.
3. Include both counters in the fingerprint hash. Counters live in-memory
   only (reset across workspace close/reopen is fine; autosave still fires
   correctly on the first mutation after reopen).

### M2 spec amendment

The original M2 metadata spec (since removed) stated *"In-memory only.
Consumers that need durability persist externally."* This plan supersedes
that line; durable persistence behavior should be documented inline with
the metadata code or in `skills/c11/references/metadata.md` when Phase 2
ships.

### Phase 2 tests

- `tests_v2/test_m2_metadata_persistence.py`: set metadata via
  `surface.set_metadata` (including numeric `progress`), save-and-restore
  session, `surface.get_metadata` returns the same values AND the same
  source/ts sidecar. CI-wired socket test.
- `cmuxTests/SurfaceMetadataStoreCodableTests.swift`: round-trip through JSON,
  including numeric, bool, array, nested-object values; empty-dict → nil
  encoding; timestamp preservation.
- `cmuxTests/MetadataStoreRevisionCounterTests.swift`: mutations bump counter,
  no-op writes don't, bump is atomic across threads.
- `tests_v2/test_m7_titlebar_description_roundtrip.py` (already on disk per
  `git status`): extend to assert description survives restart with full
  source attribution intact.
- Regression: `pruneSurfaceMetadata` still clears orphan entries when a
  panel is removed mid-session.

---

## Phase 3 — Persist `statusEntries` (with fidelity fix)

**Deliverable:** workspace-scoped sidebar status pills survive restart,
flagged as stale until the agent refreshes them. All fields on
`SidebarStatusEntry` (including `url`, `priority`, `format`) round-trip.

### Current state

`statusEntries: [String: SidebarStatusEntry]` is workspace-scoped
(`Sources/Workspace.swift:4903`) and already serialized in
`SessionWorkspaceSnapshot.statusEntries` (`Sources/SessionPersistence.swift:339`),
but discarded on restore (`Sources/Workspace.swift:246` with comment:
*"ephemeral runtime state tied to running processes"*). `agentPIDs` is
similarly cleared (line 247).

**Fidelity gap:** `SidebarStatusEntry` carries `url: URL?`, `priority: Int`,
and `format: SidebarMetadataFormat` (`Sources/Workspace.swift:67-69`) that
the persisted `SessionStatusEntrySnapshot` (`Sources/SessionPersistence.swift:199-205`)
does not carry. Phase 3 extends the snapshot to close the gap.

**Scope note:** per-surface status pills are **not in scope** for this plan.
The live model is workspace-scoped only. An earlier draft said "per-surface
and per-workspace"; that was wrong — corrected here.

### Change

Extend `SessionStatusEntrySnapshot`:

```swift
struct SessionStatusEntrySnapshot: Codable, Sendable {
    // existing fields: key, value, icon, color, timestamp...
    var url: String?                // URL as String for Codable simplicity
    var priority: Int?              // optional; defaults to existing default on decode
    var format: String?             // SidebarMetadataFormat raw value
    var staleFromRestart: Bool?     // NEW — true on restored entries
}
```

Replace `removeAll()` on restore with a stamping restore:

```swift
// Was: statusEntries.removeAll()
statusEntries = snapshot.statusEntries.reduce(into: [:]) { acc, entry in
    acc[entry.key] = SidebarStatusEntry(
        value: entry.value,
        color: entry.color,
        url: entry.url.flatMap(URL.init(string:)),
        priority: entry.priority ?? defaultPriority,
        format: entry.format.flatMap(SidebarMetadataFormat.init(rawValue:)) ?? .plain,
        updatedAt: entry.updatedAt,
        staleFromRestart: true
    )
}
```

Add `staleFromRestart: Bool` to `SidebarStatusEntry`. Sidebar rendering
greys out or italicizes stale entries.

### Stale-flag clearing against existing dedupe

`shouldReplaceStatusEntry` in `TerminalController.swift:~338-356` skips
rewrites when the incoming payload matches the existing one. That dedupe
would prevent `staleFromRestart` from ever clearing if an agent re-announces
an identical status. Fix: treat the `staleFromRestart: true → false` transition
as always-replace, even if `(value, color, url, priority, format)` are
identical. Concretely, the dedupe predicate becomes:

```swift
func shouldReplaceStatusEntry(existing: SidebarStatusEntry,
                              incoming: SidebarStatusEntry) -> Bool {
    if existing.staleFromRestart && !incoming.staleFromRestart { return true }
    return /* existing payload comparison */
}
```

### Persistence of `staleFromRestart` across subsequent saves

Once restored as `staleFromRestart: true`, the flag serializes back out on
the next 8s autosave and persists across subsequent restarts until the
agent clears it. No aging rule in this plan; tracked in Open questions.

`agentPIDs` stays cleared on restore — a PID from a prior boot is
meaningless.

### Phase 3 tests

- `tests_v2/test_status_entry_persistence.py`: set status (including `url`,
  `priority`, `format`), snapshot, restore, read status via socket, assert
  all fields + stale flag present; write identical status from agent,
  assert stale flag clears via the override path.
- `cmuxTests/StatusEntryDedupeTests.swift`: `shouldReplaceStatusEntry` unit
  tests covering the stale→live transition path.
- Visual regression: mount `SidebarStatusChip` with `staleFromRestart=true`
  in a hosting view, assert opacity/italic treatment applied.

---

## Phase 4 — Claude session index (observe-from-outside)

**Deliverable:** c11 can associate a terminal surface with a recent Claude
Code session by scanning `~/.claude/projects/` — without any cooperation from
Claude itself. Gated behind a feature flag + opt-out.

### Mechanism

Claude Code writes session transcripts to
`~/.claude/projects/<cwd-slug>/<session-id>.jsonl`. The cwd-slug algorithm
was empirically confirmed against local data on 2026-04-18:

- **Rule:** every non-alphanumeric character in the cwd is replaced with `-`.
  `/`, `_`, `.`, spaces, and other punctuation all map to `-`. Alphanumeric
  runs are preserved. A leading `-` appears because the cwd starts with `/`.
- **Examples (all confirmed from real `~/.claude/projects/` data):**
  - `/Users/atin/Projects/Stage11/code/cmux` → `-Users-atin-Projects-Stage11-code-cmux`
  - `/Users/atin/Projects/Stage11/code/005_cybentic_project/structure/state/worktrees/worker-1`
    → `-Users-atin-Projects-Stage11-code-005-cybentic-project-structure-state-worktrees-worker-1`
    (underscores → `-`)
  - `/Users/atin/Projects/Gregorovich/.worktrees/test-feature`
    → `-Users-atin-Projects-Gregorovich--worktrees-test-feature`
    (dot → `-`, producing a double-dash after the preceding `/`)
- **Lossiness:** the transform is many-to-one. `/foo/bar`, `/foo-bar`,
  `/foo_bar`, `/foo.bar`, and `/foo bar` all slug to `-foo-bar`.
- **Safeguard (mandatory):** every candidate session file carries a `cwd`
  field in its first line. Parse and compare against the surface's cwd
  exactly before accepting a match. Collision-safe.

Reference implementation (Swift):

```swift
func claudeCwdSlug(_ cwd: String) -> String {
    String(cwd.unicodeScalars.map { scalar in
        let cs = CharacterSet.alphanumerics
        return cs.contains(scalar) ? Character(scalar) : "-"
    })
}
```

New module `Sources/ClaudeSessionIndex.swift` (~150 lines with bounds and
safety):

```swift
struct ClaudeSession {
    let id: UUID
    let cwd: String
    let startedAt: Date
    let lastModified: Date
    let messageCount: Int
    // First-user-message preview intentionally OMITTED from v1 — see Privacy.
}

enum ClaudeSessionIndex {
    // Path override honored (e.g., for testing, sandboxed homes).
    static var rootOverride: URL? = nil

    static func sessions(forCwd cwd: String, limit: Int = 5) -> [ClaudeSession]
    static func mostRecent(forCwd cwd: String,
                           within: TimeInterval = 86_400) -> ClaudeSession?
}
```

Implementation bounds (all enforced):

- Scan runs off-main via a serial queue.
- Per-cwd cache TTL 30s (bounded staleness).
- Depth-1 only (no recursion into subdirectories).
- `mtime` sort; only the top-`limit` files are parsed.
- Per-file read cap 64 KiB (first + last lines only; truncate if larger).
- **Every candidate session's first-line `cwd` field must match the surface's
  cwd exactly**, or the session is rejected. The slug transform is
  many-to-one, so this check is mandatory for correctness — not optional.
- Per-scan timeout 250ms; partial results returned on timeout.
- Symlinks inside `~/.claude/projects/` are not followed.
- Files >10 MiB are skipped (assume corrupted or non-standard).
- No write access to `~/.claude/` — strictly read-only.
- Returns `[]` silently if the directory doesn't exist (non-Claude user).

### Feature flag & opt-out

- `CMUX_EXPERIMENTAL_SESSION_INDEX=1` environment variable gates the entire
  Phase 4 code path. Off by default in Tier 1b's first release; flipped on
  after the cwd-slug algorithm is confirmed.
- User-facing opt-out: `CMUX_DISABLE_SESSION_INDEX=1` (also readable from
  user settings) — respected even when the feature flag is on. This is the
  enterprise/privacy opt-out.
- When disabled, the rest of the plan degrades gracefully: Phase 5 falls
  through to `directory` / "Restore cwd" affordances.

### Recording the association

When a surface is focused, if `ClaudeSessionIndex.mostRecent(forCwd:)`
returns a session, write it into the surface metadata under **namespaced**
canonical keys via the M2 precedence chain:

- `agent.claude.session_id` (was: `claude_session_id`)
- `agent.claude.session_started_at` (was: `claude_session_started_at`)

Namespacing prevents future-agent key collisions and gives room for a neutral
`agent.session_id` / `agent.kind` envelope if we generalize. The bare
non-namespaced keys are **not** used.

Writes flow through `SurfaceMetadataStore.set(..., source: .heuristic)` — the
existing M2 precedence chain (`explicit > declare > osc > heuristic`) means a
real agent write beats the inferred value automatically, without a bespoke
"external write wins" rule.

### Clobbering guard on first focus

If restored metadata already contains a valid `agent.claude.session_id` with
source `.declare` or `.explicit`, the focus-time scan does **not** overwrite
it. (M2 precedence handles this for free once we use `source: .heuristic`.)
Only heuristic-source values can be replaced by a newer heuristic value, and
only if `startedAt` is strictly greater than the stored one.

Trigger points:

- Surface focus (debounced 1s).
- Surface creation for terminals — record immediately only if the feature
  flag is on.
- On `surface.set_metadata` from an agent with the namespaced key, the M2
  precedence rule applies automatically; no bespoke "external wins" rule
  needed.

### Remote-daemon workspaces

Workspaces attached to a `WorkspaceRemoteDaemonManifest` run on a different
machine, where `~/.claude/projects/` is not on the local Mac. Phase 4
**explicitly does not support** remote-daemon workspaces in v1 — the scan
runs locally and returns `[]`. A remote equivalent (ask c11d on the remote
to run the scan) is deferred. See Appendix.

### Privacy posture

- Transcripts contain user prompts, tool outputs, and code. Phase 4
  accesses this data but writes only the session UUID, not prompt content.
- `firstUserMessagePreview` is **deferred to a followup plan** (originally
  listed in the struct). Reading and persisting user-prompt text crosses a
  trust line this plan is not ready to defend.
- The `CMUX_DISABLE_SESSION_INDEX=1` opt-out above is the enforcement
  mechanism.
- Document the transcript-read behavior in a short `docs/c11-privacy.md` (new)
  when Phase 4 ships.

### Cross-agent generalization

- Codex: `~/.codex/sessions/` (TBD shape; deferred).
- Gemini: unclear whether it persists sessions to disk; investigate before
  committing.

Phase 4 ships the Claude index only. A `SessionIndex` protocol is not
introduced in this plan; revisit when the second integration arrives.

### Phase 4 tests

- `cmuxTests/ClaudeSessionIndexTests.swift`: feed a synthetic
  `~/.claude/projects/` tree via `rootOverride`; assert `mostRecent(forCwd:)`
  returns correct session, respects recency window, respects timeout on a
  synthetic slow filesystem, skips oversized / symlinked / hidden files.
- `cmuxTests/ClaudeCwdSlugAlgorithmTests.swift`: table-driven tests for the
  confirmed slug algorithm (non-alphanumeric → `-`), including underscores,
  dots producing double-dashes, spaces, and Unicode. Plus a test that a
  collision case (`/foo-bar/baz` vs `/foo/bar-baz`) is resolved correctly
  by the first-line `cwd` verification.
- `tests_v2/test_claude_session_association.py`: create a surface in a cwd
  with a known Claude session fixture, focus it, assert
  `surface.get_metadata` reports `agent.claude.session_id` with
  `source=heuristic`. CI-wired.
- `cmuxTests/ClaudeSessionPrecedenceTests.swift`: an explicit write with
  `source=declare` is not clobbered by a focus-time scan.

---

## Phase 5 — Recovery UI (with safety gate)

**Deliverable:** a restored surface offers a clear path to recreate what was
running, with a shell-prompt safety gate for anything that executes a
command in the pane.

### Title-bar resume affordance

When a restored terminal surface has `agent.claude.session_id` in its
metadata, render a compact "Resume Claude session" chip in the title bar
(M7 territory).

Fallback chain (most specific → least):

1. `agent.claude.session_id` → "Resume Claude session".
2. `agent.codex.session_id` → "Resume Codex session" (when Codex adapter
   arrives).
3. Last known `directory` exists on disk → "Reopen in `<dir>`".
4. `directory` exists but command unknown → "Restore cwd".
5. `directory` no longer exists (deleted worktree) → "Restore cwd
   (unavailable)" disabled chip with tooltip.

### Shell-prompt safety gate (mandatory)

Clicking the chip must not blindly inject keystrokes into a pane that might
be in Vim, nano, a REPL, or mid-command. Before dispatching `panel.send_text`:

1. **Prefer copy-to-clipboard by default.** The chip's primary action is
   "copy `claude --resume <id>` to clipboard." A secondary menu item
   ("Send to pane") is the opt-in execute path.
2. **Execute only with confirmation.** If the user chooses "Send to pane,"
   show a one-time confirmation sheet: *"This will type the command into
   your terminal. Continue only if your shell is at a prompt."*
   Remember-the-choice per-workspace.
3. **No heuristic prompt detection in v1.** Detecting shell vs. non-shell
   state reliably requires cooperation from Ghostty we don't have yet.
   Copy-first sidesteps the whole problem.

This is the "restore historical context" vs. "drive active command
execution" trust-bar distinction — v1 defaults to the former.

### Feature flag

Phase 5 ships under the same `CMUX_EXPERIMENTAL_SESSION_INDEX` flag as
Phase 4. The chip also respects `CMUX_DISABLE_SESSION_INDEX`.

### Localization

All new user-facing strings use `String(localized: "key.name", defaultValue:
"English text")` per project CLAUDE.md. Keys land in
`Resources/Localizable.xcstrings` with English + Japanese translations for:
`phase5.chip.resume_claude`, `phase5.chip.reopen_in_dir`,
`phase5.chip.restore_cwd`, `phase5.chip.unavailable`,
`phase5.menu.copy_command`, `phase5.menu.send_to_pane`,
`phase5.confirm.send_title`, `phase5.confirm.send_body`.

### CLI mirror

`cmux surface recreate [<surface-id>]` emits the same command string to
stdout (no pane injection, no shell quoting concerns beyond standard
`ShellEscaping` — add that helper if it doesn't exist). Target shell is
user-agnostic: output is the bare command, not a heredoc or sourced script.

### Sidebar hint

Stale status entries (from Phase 3) already signal "this is pre-restart."
No change to sidebar in Phase 5 v1.

### Failure handling

If `claude --resume <id>` fails (session corrupted, Claude upgraded its
schema), the user sees the error in their terminal — c11 does not
intercept. A small toast ("Resume failed. Try 'Start fresh Claude
session.'") appears when the CLI exits non-zero within 5s, but only when
the command was executed via the chip's "Send to pane" path (we know we
sent it).

### Phase 5 tests

- `cmuxTests/ResumeChipTests.swift`: chip renders with namespaced
  `agent.claude.session_id`; default click path copies to clipboard;
  "Send to pane" path requires confirmation; worktree-deleted cwd yields
  disabled chip.
- `cmuxTests/ShellEscapingTests.swift`: `cmux surface recreate` output
  correctly escapes cwds with spaces and special characters.
- `tests_v2/test_surface_recreate_cli.py`: populate a surface with metadata
  (including deleted-cwd edge case), run `cmux surface recreate`, assert
  output format.
- Localization test: all new strings resolve under English and Japanese.

---

## Rollout order

Tier 1a must land first. Tier 1b re-justifies after Tier 1a lands.

### Tier 1a — Durability (ships first)

| Phase | Lands what | User-visible? | Blocks on |
|-------|------------|---------------|-----------|
| 1 | Stable panel UUIDs (constructor refactor) | No (internal) | — |
| 2 | `SurfaceMetadataStore` persistence (lossless) | Indirectly (M-series features durable) | 1 |
| 3 | `statusEntries` persistence (with fidelity fix) | Yes (stale chips on restart) | 1 |

Each phase is a separate PR. After Phase 3 ships, Tier 1a is complete.
**Stop-point.** Tier 1b re-justifies at this boundary; do not treat
Phase 4 as the default next step.

### Tier 1b — Recovery UX (ships after re-justification)

| Phase | Lands what | User-visible? | Blocks on |
|-------|------------|---------------|-----------|
| 4 | Claude session index (flagged off) | No (metadata writes only) | 2 + cwd-slug confirmation |
| 5 | Recovery UI (copy-first, flagged) | Yes (resume chip, CLI) | 4 + M7 settlement |

Tier 1b prerequisites (must be true before starting Phase 4):

1. Tier 1a shipped and stable for ≥1 release.
2. ~~M7 title-bar work merged~~ — already done (confirmed 2026-04-18).
3. ~~Cwd-slug algorithm empirically confirmed~~ — done 2026-04-18; see
   Phase 4 "Mechanism" for the rule + safeguard.
4. Measurement from Tier 1a: metadata size, autosave frequency, store
   revision rates. Establishes a baseline before Phase 4 adds write volume.

### Coordination

- **Companion workspace-metadata plan.** Both plans touch
  `Sources/SessionPersistence.swift` at `:330` (workspace snapshot) and `:243`
  (panel snapshot). Whichever lands first does the schema extension;
  whichever lands second rebases onto it. Named owner for the joint
  autosave-fingerprint design: whoever picks up Phase 2 of this plan.
- **M7 work.** Already merged; no coordination needed.
- **`lattice-stage-11-plugin`.** Out of scope — plugin is known to be out
  of date relative to c11 and not a blocker for Phase 1.

---

## Open questions

1. **Stale-status aging.** Phase 3 marks entries `staleFromRestart=true`
   until the next write. Should we age them out after N hours if no write
   arrives? Leaning no — let the agent or the user clear them — but a
   "Clear stale statuses" context-menu action in the sidebar may be worth
   a small followup.
2. **Per-non-canonical-key cap.** Whether Phase 2 should enforce a ≤4 KiB
   cap per custom (non-canonical) metadata key to bound pathological
   bloat. Revisit after the size metric gives us real numbers.
3. **Codex / Gemini parity in Phase 4.** Ship Claude-only first
   (generalization deferred until Codex session storage shape is
   confirmed). Document the asymmetry in `docs/c11-charter.md` so
   operators aren't surprised.
4. **`agent.claude.session_started_at` canonical format.** ISO 8601 string
   or epoch seconds? Go with ISO 8601 for human-readable debug dumps
   unless there's a reason not to.
5. **Resumed-session failure UX.** The toast-on-non-zero-exit described in
   Phase 5 is the v1 plan, but the 5s heuristic may be wrong for slow
   sessions. Measurement gate after Phase 5 ships.
6. **Companion plan's workspace-level metadata fingerprint interaction.**
   Ensure the workspace metadata revision counter and the surface metadata
   revision counter don't both fire on the same logical user action (e.g.,
   a "rename workspace" that also updates a surface title).
7. **Rollback for Phase 1.** Keep the dead `oldToNewPanelIds` code paths
   for one release behind `CMUX_DISABLE_STABLE_PANEL_IDS`, or delete them
   immediately? Leaning keep-for-one-release.

---

## Appendix — what this plan does not do

- **Does not persist running PTYs.** That's Tier 2 — move PTY ownership
  into `c11d`, make the Swift app a reattaching viewer.
- **Does not persist `titleBarCollapsed` / `titleBarUserCollapsed`.** Per
  the scoping conversation, title-bar collapse state resets to default on
  restart.
- **Does not persist remote-daemon connection state.** Transient; Tier 2
  may reopen this.
- **Does not support remote-daemon workspaces in Phase 4.** The Claude
  scan is local-only in v1. Remote session indexing (ask c11d to run the
  scan on the remote) is a deferred addition.
- **Does not persist `firstUserMessagePreview`.** Reading and storing user
  prompt text crosses a privacy line this plan is not ready to defend.
  Deferred to a followup.
- **Does not introduce a `SessionIndex` protocol.** Claude-only in Tier
  1b; abstract when the second integration arrives.
- **Does not introduce a `WorkspaceMetadataStore` class.** The companion
  workspace-metadata plan handles workspace-level durability.
- **Does not change `SurfaceMetadataStore`'s 64 KiB cap** or the canonical
  key list. Additive only.
- **Does not execute commands in panes without explicit user consent.**
  Phase 5 defaults to copy-to-clipboard; pane execution requires a
  confirmation step.

Ship Tier 1a. Measure. Then re-justify Tier 1b.
