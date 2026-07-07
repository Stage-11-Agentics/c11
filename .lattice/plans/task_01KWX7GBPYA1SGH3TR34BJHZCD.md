# C11-162 — Telemetry truth (liveness) + waiting-agent cluster · PLAN

**Ticket:** C11-162 (Wave 2, Truth & Stability). **SPEC IDs:** TEL-1..TEL-8. **Mode:** sub-agent-full. **Stops at:** `pr_open` (operator merges).
**Contract:** `docs/cycles/2026-07-truth-and-stability/{SPEC,EVALUATION,BUILDPLAN}.md`. **Design input:** `docs/c11-waiting-agent-cluster-plan.md` (commit with this ticket).
**Base:** post-DX-merge `origin/main`. Plan written against the **post-extraction** layout (dispatch under `Sources/SocketHandlers/`); model/view code (the bulk of TEL) was **not** moved by C11-159.

---

## 0. The load-bearing finding: c11 has two status surfaces, not one

This is the spine of the plan. The two "status" paths are independent and feed different UI regions:

| | **Sidebar pills** (what TEL-2 decays) | **Canonical metadata** (what TEL-1 timestamps) |
|---|---|---|
| Store | `Workspace.statusEntries: [String: SidebarStatusEntry]` (`@Published`, `Workspace.swift:5336`) + `Workspace.progress` (`SidebarProgressState`, `:5339`) | `SurfaceMetadataStore.shared` (`SurfaceMetadataStore.swift:83`) — `metadata` + parallel `sources` sidecar |
| Write path | `set_status`/`set_progress` → `TerminalController.setStatus` (`:18942`, writes `tab.statusEntries[key]` at `:18839`) / `setProgress` (`:19183`) | `surface.set_metadata` → `SocketHandlers/SurfaceHandlers.swift:1330` → `SurfaceMetadataStore.setMetadata` (`:390`) |
| CLI | `c11 set-status <key> <value>` (arbitrary key/value pill, e.g. `build: compiling`) | `c11 set-metadata --key status …`, `c11 set-agent`, etc. |
| Timestamp today | `SidebarStatusEntry.timestamp: Date` (`Workspace.swift:70`, stamped `Date()` at write, used only for display ordering) | `SourceRecord.ts: Double` (`SurfaceMetadataStore.swift:92`, stamped every applied write) |
| Renders in | Sidebar workspace row (`TabItemView`, `ContentView.swift:11257` → `SidebarMetadataRows` `:12908` → `SidebarMetadataEntryRow` `:12961`) | Title bar / surface manifest (`SurfaceManifestView.swift:45`) + `get_metadata` response |
| Observer | `Workspace` `ObservableObject` `@Published` — data-change only, **no clock timer** | `SurfaceMetadataStore` has **"no observer infrastructure"** (`SurfaceMetadataStore.swift:~498`) |

**Consequences the plan builds on:**
- **TEL-2 decay renders against `SidebarStatusEntry.timestamp`** (sidebar pills), not the metadata-store `ts`. Sidebar pills are arbitrary agent key/value entries; they are the "lying" surface the operator watches.
- **TEL-1's last-updated infra already exists end-to-end** in `SurfaceMetadataStore` and *already survives snapshot round-trip* (see §1). TEL-1 is verify + test + modest UI exposure, not build-from-scratch.
- **TEL-3/4 derived state** must be computed/stored at the `derived` precedence tier in `SurfaceMetadataStore` (the only store with tiers — hard requirement of TEL-3), then **projected into the `Workspace` `@Published` pill state** so the sidebar (which only observes `Workspace`) can show the takeover. A projector bridges the two stores.
- **We do NOT unify the two stores.** Unifying would force `TabItemView` (a typing-latency-sensitive `Equatable` view — CLAUDE.md hot-path list) to read `SurfaceMetadataStore`, adding store observation into the typing path. Rejected on hot-path grounds. The plan is **additive on the existing hot-path-safe `@Published` data flow.** (Recommended; flagged for plan-review in §4.)

---

## 1. Approach per SPEC ID

### TEL-1 — canonical keys carry last-updated, persisted, exposed (get_metadata + UI)
**State: ~80% already built.** `SourceRecord.ts` is set on every applied write (`SurfaceMetadataStore.swift:625,656`); `get_metadata` returns it in `metadata_sources` when `include_sources: true` (`SurfaceHandlers.swift:1422-1432`, each entry `{source, ts}` via `SourceRecord.toJSON()` `:94`); and it **already round-trips** through snapshots via `PersistedMetadataSource.ts` (`PersistedMetadata.swift:68-75`, `encodeSources`/`decodeSources` `:158-208`, carried in `SessionPanelSnapshot.metadataSources` `SessionPersistence.swift:341`).

Work remaining:
1. **Confirm coverage of status/progress/task/description** — all four are canonical keys through `set_metadata`; ts is stamped uniformly. No code change expected; assert via test.
2. **Expose to UI**: surface the last-updated ts where canonical metadata renders — the surface manifest / title bar (`SurfaceManifestView.swift`) as an age hint/tooltip. Small, additive.
3. **Idempotent-ts decision (design fork, §4-D1):** a same-value+same-source rewrite is an intentional no-op that *freezes* `ts` (`SurfaceMetadataStore.swift:647-654`). Recommendation: **leave the store contract unchanged** (canonical ts = last-*changed*); heartbeat/"still alive" freshness is handled by the sidebar path + derived liveness, not by mutating the store's dedupe/revision contract.
4. **Tests**: `c11-logic` — ts present after write; round-trip through `PersistedMetadataBridge` preserves ts; `get_metadata` returns last-updated. `tests_v2` socket — set canonical key, `get_metadata --sources`, assert `ts`; snapshot round-trip.

### TEL-2 — sidebar status/progress pills visually decay by age (tunable 5m/15m)
1. **Decay stages**: `fresh` (< stale) → `stale` (≥ stale, < expiry: dim + relative-age indicator e.g. "5m") → `expired` (≥ expiry: gray out, `BrandColors.dim` #555555). Compute per pill from `now − SidebarStatusEntry.timestamp` (and a new `SidebarProgressState.timestamp`).
2. **Progress needs a timestamp**: `SidebarProgressState` (`Workspace.swift:4833`) has none; add `timestamp: Date`, stamp in `setProgress` (`TerminalController.swift:19183`).
3. **Re-render clock (TEL-5-safe)**: add a single coarse shared `SidebarDecayClock: ObservableObject` with `@Published var now`, driven by **one** ~30s timer (or reuse the 8s autosave tick, `AppDelegate.swift:3924`). Consumed **only** by the pill subviews (`SidebarMetadataEntryRow`, progress view) — **never** injected into `TabItemView`'s `Equatable` body (would break its typing fast-path). This is the critical hot-path boundary (§7-R1).
4. **Tunable thresholds**: new settings enum `SidebarStalenessSettings` (mirror `NotificationFlashDurationSettings`, `TerminalNotificationStore.swift:551`): `staleThresholdKey`/`expiryThresholdKey`, defaults 300s/900s, min low enough (≤10s) to allow the accelerated recorded demo. `@AppStorage`-bound `Slider`/`Stepper` rows in the Sidebar settings page (`c11App.swift:5341` `workspaceSidebarSettingsPage`, using `SettingsCardRow` `:6604`).

### TEL-3 — derive per-surface activity (working/idle) from existing signals, at `derived` tier
1. **Signal source (zero new hot-path work)**: `Workspace.PanelShellActivityState` (`Workspace.swift:5420`: `unknown`/`promptIdle`/`commandRunning`), already driven by shell-integration `report_shell_state` (`cmux-bash-integration.bash:361,384`), delivered off-main and transition-coalesced (`TerminalController.reportShellStateWorker:2259`, `shouldPublishShellActivity:604`). `commandRunning` ⇒ `working`, `promptIdle` ⇒ `idle`. Reconcile "still idle/working" on the existing **AgentDetector 10s sweep** (`AgentDetector.swift:87-88`, off-main, per-surface). Recency backstop: `SurfaceActivityTracker.lastActivity` (`Conversation/SurfaceActivity.swift:33`).
2. **New deriver** `SurfaceLivenessDeriver` following the documented `MetadataDeriver` seam (`skills/c11/references/metadata.md` §MetadataDeriver; reference impl `GitContextDeriver`). Writes a **new derived key `activity`** (values `working`/`idle`) via `SurfaceMetadataStore.setInternal(…, source: .derived)` (`:553`). Distinct key (not `status`) is required: derived writes to `status` would be rejected as lower-precedence and never stored, so the takeover (TEL-4) could not surface them.
3. **Precedence honored automatically**: `.derived` never overwrites `.explicit` (`MetadataSource.precedence`, `:59`); derived keys are excluded from snapshot capture (`PersistedMetadata.swift:144,163`) — correct, liveness recomputes on resume.
4. **EVT seam**: expose the working↔idle transition point cleanly so EVT (C11-163) can emit a `derived-liveness` event (EVT-2). If EVT lands first behind a stub, this completes it (per BUILDPLAN note).

### TEL-4 — expired explicit status → derived takes over the visible pill, visually distinct
1. **Projector** `SidebarActivityProjector` (pure value-in/value-out, testable in `c11-logic`, mirrors `WorktreeChipProjector`): inputs = explicit sidebar status entries (+ ages vs thresholds) and the per-surface derived `activity`; output = the visible pill model with `{ text, decayStage, isDerived }`.
2. **Per-surface → per-row aggregation**: sidebar rows are per-workspace (`TabItemView`), derived activity is per-surface. Rule: row shows derived `working` if any child surface is `working`, else `idle`; takeover engages only when the row's explicit status entries are all past **expiry**.
3. **Bridge to `@Published`**: projector output lands on a new `Workspace` field (e.g. `@Published var derivedActivity: SidebarActivityState?`) via the deriver's main-hop (same pattern as `setStatus`'s `DispatchQueue.main.async`).
4. **Distinct rendering**: derived pill styled unlike agent-claimed — e.g. outline/italic + a "derived" affordance, reusing the existing derived visual language (the restart-stale treatment at `ContentView.swift:12999` is the precedent). When the agent reports again, explicit is fresh and resumes automatically.

### TEL-5 — no per-keystroke/per-frame work
Guaranteed by construction: signal is the already-coalesced `PanelShellActivityState` transition + the existing 10s AgentDetector sweep + one ~30s decay clock. **Zero** additions to `hitTest()` (`TerminalWindowPortal.swift:252`), `TabItemView` body (`ContentView.swift:11257`), or `forceRefresh()` (`GhosttyTerminalView.swift:3690`). Verified by hot-path diff review (EVALUATION TEL-5).

### TEL-6 — waiting-agent cluster restyle (scaffold exists; rename + lit-inversion remain)
**Verified on `origin/main`:** the two-row cluster already exists — `SidebarWaitingAgentCluster` (`ContentView.swift:10600`), `WaitingAgentRow` (`:10649`), `WorkspaceNavRow`/`WorkspaceArrowButton` (arrows wired to `TabManager.selectNext/PreviousTab`, disabled at first/last, auto-repeat). **Unbuilt:** (a) the rename — label is still `statusBar.nextNotification.title` = "Next Notification" (`:10656`); (b) the lit-state — still solid gold fill `isLit ? cmuxAccentColor()` (`:10703`). Work:
1. **Rename** → "Waiting Agent" (new localized string; keep the ⌥V/`jumpToUnread` behavior and shortcut hint unchanged).
2. **Lit-state inversion** per design doc: off-white paper fill (`BrandColors.paperFill` #E8E2D0, already defined `:19`) with content flipped to void, ⌥V subdued, thin gold hairline; no motion. Replace the gold-fill branch at `:10703-10710`.
3. **Confirm** arrow rest/hover/disabled + adaptive sizing tiers against the doc; adjust only where they diverge.
4. **Integrate with the liveness work** so the sidebar region is touched once (this ticket owns both).
5. **Commit** `docs/c11-waiting-agent-cluster-plan.md` with the ticket.

### TEL-7 — recorded scenarios (2)
Scripted + recorded on a tagged build: (a) agent sets status → goes silent → pill decays on schedule → flips to derived; (b) agent that never self-reports but produces terminal output → sidebar shows derived `working` with no agent cooperation. Uses accelerated thresholds (§ validation). Recordings attached `--role validation`.

### TEL-8 — skill docs
Update `skills/c11/references/metadata.md`: age/decay semantics (thresholds, stages, tunables), the derived-liveness `activity` key + takeover behavior, and the `MetadataDeriver` note for `SurfaceLivenessDeriver`. **Run `scripts/sync-installed-skills.sh c11`** (HARD RULE) in the same PR.

---

## 2. File-level change map (post-extraction layout)

**Model / store (not moved by extraction):**
- `Sources/SurfaceMetadataStore.swift` — add `activity` to canonical keys (`MetadataKey`, `:11`); no ts change (D1). `setInternal` is the derived write path (exists).
- `Sources/Workspace.swift` — `SidebarProgressState` (+`timestamp`, `:4833`); new `@Published var derivedActivity` (`:5339` block); aggregation helper; possibly `SidebarStatusEntry` decay-stage helper.
- `Sources/PersistedMetadata.swift` / `Sources/SessionPersistence.swift` — no change (ts already persists); add round-trip test coverage only.
- `Sources/Conversation/SurfaceActivity.swift` — read-only source of recency; no change expected.

**New files:**
- `Sources/SurfaceLivenessDeriver.swift` — the `MetadataDeriver` computing working/idle.
- `Sources/Sidebar/SidebarActivityProjector.swift` — pure projector (explicit+derived → visible pill).
- `Sources/SidebarDecayClock.swift` — the single coarse re-render clock.
- `SidebarStalenessSettings` — settings enum (co-locate near existing settings enums or in `TerminalNotificationStore.swift`-style).

**View / settings:**
- `Sources/ContentView.swift` — `SidebarMetadataEntryRow` (`:12961`) + progress view (`:11774`) consume the decay clock + render stages; `WaitingAgentRow` (`:10649`) rename + lit-inversion. **`TabItemView` `Equatable` `==` (`:11260`) must NOT gain new stored-property reads without updating `==`** (§7-R1).
- `Sources/c11App.swift` — `SidebarStalenessSettings` `@AppStorage` bindings (`~:4447`) + threshold rows in `workspaceSidebarSettingsPage` (`:5341`).

**Dispatch layer (extracted — minimal contact):**
- `Sources/SocketHandlers/SurfaceHandlers.swift` — `v2SurfaceGetMetadata` (`:1390`) already returns ts via sources; optionally add an explicit last-updated surfacing. `set_status`/`set_progress` dispatch cases live in `SocketHandlers/SocketDispatch.swift:531,573` but delegate to `setStatus`/`setProgress` which **remain in `TerminalController.swift`** — edit those in place (`:18942`, `:19183`).

**Writer of derived pill (bridge to main):** deriver → `TabManager`/`Workspace` main-hop, mirroring `setStatus`'s `DispatchQueue.main.async` (`TerminalController.swift:18821`).

**Docs / skill:** `skills/c11/references/metadata.md` + `scripts/sync-installed-skills.sh c11`; commit `docs/c11-waiting-agent-cluster-plan.md`.

**Localization:** `Resources/Localizable.xcstrings` (en source), then 6-locale pass (ja, uk, ko, zh-Hans, zh-Hant, ru).

---

## 3. Sub-agent execution plan (sub-agent-full)

On RESUME, work runs in sub-agent tabs on my pane (atomic spawn per the c11 skill); I coordinate and own all status bumps. Proposed buckets (each ~independent):
- **B1 — Metadata ts (TEL-1):** verification + tests + manifest exposure. Small.
- **B2 — Sidebar decay (TEL-2 + TEL-5 clock):** `SidebarDecayClock`, progress timestamp, decay-stage rendering, settings. Medium.
- **B3 — Derived liveness (TEL-3/4):** `SurfaceLivenessDeriver`, `activity` key, projector, `@Published` bridge, takeover render. Medium-high — the seam-heavy bucket; I keep this coherent (may not fully parallelize with B2 since both touch `ContentView` sidebar region — sequence B2→B3 or split by file to avoid collision).
- **B4 — Waiting-agent cluster (TEL-6):** rename + lit-inversion + doc commit. Small-medium, isolated to `WaitingAgentRow`.
- **B5 — Localization pass:** 6 translator sub-agents in parallel after English strings settle.
- **B6 — Validation/scenarios (TEL-7 + screenshots):** after build green; owns recordings.
Doc/skill (TEL-8) folds into whichever bucket touches the referenced behavior; I run the sync script.

---

## 4. Design decisions / forks (for plan-review)

- **D1 — Canonical `ts` = last-changed (idempotent no-op freezes it).** Recommend leaving the store's dedupe/revision contract unchanged; heartbeat freshness is handled by the sidebar path (fresh `Date()` per `set-status`) + derived liveness. *Alt:* refresh ts on same-value rewrite (heartbeat) — rejected: destabilizes revision/autosave fingerprint for marginal gain.
- **D2 — Two stores, not unified (additive projector).** Recommend additive decay on the existing `@Published` sidebar flow + a projector bridging `SurfaceMetadataStore` derived tier → `Workspace`. *Alt:* unify sidebar onto `SurfaceMetadataStore` — rejected: forces store observation into the `Equatable` `TabItemView` typing hot path.
- **D3 — Derived state uses a new `activity` key, not `status`.** Required so derived values are actually stored (not precedence-rejected) and available for time-based takeover.
- **D4 — Single coarse decay clock (~30s), consumed only by pill subviews.** Keeps `TabItemView` `Equatable` fast-path intact. *Alt:* per-row `TimelineView` — rejected: risks re-eval churn near the typing path.
- **D5 — Per-surface derived → per-row aggregation** (row `working` if any child surface working). Reasonable default; plan-review may prefer a different rollup.

---

## 5. Test plan per EVALUATION row

- **TEL-1 (autonomous):** `c11-logic` — `SurfaceMetadataStore` stamps ts on status/progress/task/description; `PersistedMetadataBridge` round-trip preserves ts. `tests_v2` — set canonical key → `get_metadata --sources` returns last-updated; survives snapshot round-trip.
- **TEL-2 (operator-assisted + felt):** scripted decay demo on tagged build with accelerated thresholds; screenshots at fresh/stale/expired. Unit: decay-stage classifier (`now−ts` vs thresholds) in `c11-logic`.
- **TEL-3 (autonomous):** harness — one silent pane vs one output-producing pane; read `activity` via `get_metadata`; assert `idle` vs `working`. Deriver unit tests (stub `PanelShellActivityState` transitions) in `c11-logic`.
- **TEL-4 (autonomous + operator-assisted):** projector unit tests (fresh explicit → explicit; expired explicit + derived → derived-distinct). Scripted takeover demo + screenshot.
- **TEL-5 (autonomous):** hot-path diff review — assert no diff to `hitTest`/`TabItemView` body/`forceRefresh`; no new per-keystroke timer. Artifact = diff audit vs CLAUDE.md hot-path list.
- **TEL-6 (operator-assisted + felt):** tagged-build screenshots (rest + lit + arrows) vs the cluster-plan design spec.
- **TEL-7 (autonomous, recorded):** both scenarios scripted + recorded; artifacts on ticket.
- **TEL-8 (autonomous):** skill diff in PR; `sync-installed-skills.sh` run recorded.

Test topology: `c11-logic` = local loop (projector, deriver, decay classifier, ts round-trip). Host tests via `scripts/test-unit-local.sh`. `tests_v2` against a tagged build socket. Never `open` an untagged DEV.app. New tests verify **runtime behavior**, not source shape (test-quality policy).

---

## 6. Validation-artifact plan (attach `--role validation`)

- Decay screenshots: fresh / stale / expired (TEL-2).
- Derived-takeover screenshot: derived-distinct pill (TEL-4).
- Waiting-agent cluster screenshots: rest + lit + arrow states (TEL-6).
- Two recorded scenarios (TEL-7).
- TEL-3 `get_metadata` transcript: silent vs output-producing pane.
- TEL-5 hot-path diff-audit note.
- **Accelerated-demo hook:** `SidebarStalenessSettings` min ≤10s (settings-driven) so decay/takeover are demonstrable in seconds; if insufficient, a QA-gated env override (`C11_SIDEBAR_STALE_SECONDS`/`_EXPIRE_SECONDS`) read at launch. Documented, not persisted.

Bar (operator decision 2026-07-06): **tagged build + recorded live scenario proof**; CI green necessary, not sufficient.

---

## 7. Risks & seams

- **R1 (highest) — `TabItemView` `Equatable` typing fast-path.** It skips body re-eval during typing via `==` (`ContentView.swift:11260`; CLAUDE.md hot-path list). The decay clock and derived-pill state must be consumed by **child** views (`SidebarMetadataEntryRow`, progress view), not read in `TabItemView`'s body, and any new `tab` property that *is* read there must be added to `==`. Mitigation: projector emits a small value type; clock observed one level down; explicit `==` review in code-review.
- **R2 — off-main telemetry (CLAUDE.md).** Deriver runs off-main (AgentDetector queue / shell-state worker), hops to main only for the `@Published` mutation. No `DispatchQueue.main.sync` on telemetry paths.
- **R3 — TEL↔EVT seam.** Derived-liveness transition is an EVT-2 taxonomy member. Provide a clean transition hook; if EVT lands first behind a stub, complete it (BUILDPLAN, acceptable logged seam). Coordinate via orchestrator, don't build the event stream here.
- **R4 — two-store coherence.** Decay (sidebar) vs canonical ts (manifest) surfaces are legitimately different (§0); documented so plan-review can push back if unification is expected.
- **R5 — dlog `#if DEBUG`**, custom UTType additions (none expected), submodule discipline (none expected — pure Swift/app work).
- **R6 — build lock**: acquire `xcodebuild` resource before any build/test; heartbeat; release immediately (per boot §3).

---

## 8. Localization (certain)

New user-facing strings, all `String(localized:"…", defaultValue:"…")` at call site, English only in code:
- "Waiting Agent" (rename, TEL-6).
- Settings labels/subtitles for staleness + expiry thresholds (TEL-2).
- Relative-age indicator ("%dm", "%dh") and any derived-pill label ("idle"/"working"/"derived") text (TEL-2/4).
Then delegate a **6-locale pass** (ja, uk, ko, zh-Hans, zh-Hant, ru) — one translator sub-agent per locale in parallel — syncing `Resources/Localizable.xcstrings`.

---

## 8b. Plan-Review status (infra flag — NOT findings)

The board's auto plan-review (triple) **did not run**: it spawns a c11 review pane in the orchestrator's workspace (`DB29BC45`, `pane:57`) and the split failed — first `Failed to write to socket`, then on a manual headless re-fire `pane_too_small` (`won't split pane:57 … below the 640×340pt minimum`). `LATTICE_SPAWN_BACKEND=headless` did not redirect it off the pane backend. This is orchestrator-workspace infra, not a plan defect; forcing `--allow-undersized`/splitting another delegator's workspace from here would steamroll it. **Flagged to the orchestrator to re-fire from a roomier workspace (or `--allow-undersized`).** When findings land, they get triaged into a `## N. Plan-Review Cycle K Resolutions (AUTHORITATIVE …)` block here. On RESUME, plan-validation runs first regardless (boot §3).

## 9. Boundaries

Out of scope (SPEC): model inference for liveness, local-model scrollback observation, events socket-subscribe. No hot-path work. No upstream push. Stops at `pr_open`; operator merges.
