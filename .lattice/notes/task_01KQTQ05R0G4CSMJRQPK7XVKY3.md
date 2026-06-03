# C11-25 Plan — Surface lifecycle perf

**Ticket:** C11-25 (`task_01KQTQ05R0G4CSMJRQPK7XVKY3`)
**Branch:** `c11-25-surface-lifecycle`
**Plan author:** `agent:claude-opus-4-7-c11-25-plan` (2026-05-04)
**Plan amended by:** `agent:claude-opus-4-7-c11-25` (delegator, 2026-05-04 — operator decisions)
**Status:** planned (operator-approved scope); ready for Impl

---

## 0. Summary

This PR ships the per-surface lifecycle primitive (`active` / `throttled` / `suspended` / `hibernated`) that all five lifecycle-perf improvements pivot on, plus five of the six behaviors that ride it: cheap-tier browser detach in non-focused workspaces, **ARC-grade browser snapshot+terminate** for hibernated workspaces, libghostty occlusion-driven terminal throttle in non-focused workspaces, per-surface CPU/MEM telemetry rendered in the sidebar (using the `_webProcessIdentifier` WebKit SPI), and a "Hibernate workspace" right-click action. **The only deferred item is the per-surface 30 fps cap (plan-numbering item 4, ticket-numbering improvement #3) → C11-25c.** Operator override (2026-05-04): plan's original split-recommendation rejected; ARC-grade is in scope; SPI approved. **What this PR explicitly does not ship:** per-surface fps cap (libghostty seam), process-level SIGSTOP of terminal children.

---

## 0a. Operator decisions (2026-05-04)

Captured here so Impl reads from a single coherent source.

1. **Scope.** Plan's recommended split rejected. **Bundle items 1-cheap + 1-ARC + 3 + 5 + 6 in this PR.** Defer only item 4 (per-surface 30 fps cap) → C11-25c. Lands 5 of 6 DoD criteria.
2. **WebKit SPI.** `_webProcessIdentifier` usage approved for item 5 (per-surface CPU/MEM). Consistent with existing c11 WebKit SPI usage; flag in PR description.
3. **ARC-grade tier.** Snapshot to NSImage placeholder, terminate WebContent process on `hibernated` (and reserved for `suspended`). Restore on focus must refire `WKWebView.load(url:)` with cookies preserved (WKHTTPCookieStore is process-pool-level and survives) and best-effort scroll-position restore (capture scrollY from a bridge before terminate; restore via JS injection on load). Acceptable to land "scroll restore is best effort" if a clean restore proves intricate.

## 1. Lifecycle primitive design

### 1.1 The four states (concrete definitions)

| State | Terminal surface | Browser surface | Markdown surface |
|-------|------------------|-----------------|------------------|
| **`active`** | Visible in pane, workspace selected; libghostty drives CVDisplayLink at full rate; PTY drains; AppKit first-responder eligible. | WKWebView attached to host view hierarchy; CoreAnimation drives compositor; full input. | WKWebView attached; live reload watching files. |
| **`throttled`** | Visible in pane but workspace deselected; `ghostty_surface_set_occlusion(false)` so libghostty pauses CVDisplayLink wakeups. PTY continues to drain (child must not block on stdout). | WKWebView **detached** from view hierarchy via `BrowserWindowPortal.detachWebView()`; AppKit/CoreAnimation stops driving compositor work. WKWebView object retained; no process termination. JS continues unless WK paused (out of scope; cheap tier only). | Same detach behavior as browser. Any file-watcher remains live (cheap; not the cost center). |
| **`suspended`** | Reserved. Not used in this PR; no terminal surface ever transitions here. (Future: a SIGSTOP-tier "deep throttle" when an idle workspace stays deselected for long enough.) | Reserved. Defined in the enum so the metadata key has an upgrade path. ARC-grade snapshot+terminate lands in **C11-25b** as the implementation of this state for browsers. | Reserved. |
| **`hibernated`** | Operator-explicit (right-click "Hibernate workspace"). For terminals: identical to `throttled` for now (PTY keeps draining; future: SIGSTOP child PID, but defer). | Identical to `throttled` cheap-tier in this PR (detach). When C11-25b lands ARC-grade, hibernate becomes "snapshot + terminate". | Identical to `throttled`. |

In this PR, `suspended` is declared in the enum but never entered; `hibernated` is entered via operator action. The split between `throttled` (auto) and `hibernated` (operator-explicit) matters because `hibernated` should survive c11 snapshot/restore as hibernated, while `throttled` should rehydrate to `active` on the first focus after restore.

### 1.2 Allowed transitions and triggers

```
                   workspace deselected
                  ┌─────────────────────┐
                  ▼                     │
   ┌──────► active ◄──────────────► throttled ──┐
   │           │                         ▲       │  workspace
   │           │                         │       │  selected
   │           │       op: "Hibernate"   │       │
   │           ▼                         │       │
   │     hibernated ◄──────────────────────┘     │
   │           │                                 │
   │           │  workspace selected             │
   │           ▼                                 │
   └─────  suspended (reserved)  ◄───────────────┘
                  (not entered in this PR)
```

Triggers:
- `active → throttled`: workspace deselect (handed by `WorkspaceContentView` `isWorkspaceVisible` flipping false; see §1.4).
- `throttled → active`: workspace select.
- `active|throttled → hibernated`: operator right-click "Hibernate workspace".
- `hibernated → active`: workspace becomes selected again (same hook as `throttled → active`).
- `* → suspended`: not in this PR.

### 1.3 Where the state lives — recommendation

**Both, with the typed enum as source of truth.** Concretely:

- A typed Swift enum `SurfaceLifecycleState` (probably in a new `Sources/SurfaceLifecycle.swift`) is the runtime authority. It carries the value, the transition validator, and the dispatcher that calls into AppKit (`detachWebView`, `setOcclusion`, etc.).
- The state is mirrored to the canonical metadata key `"lifecycle_state"` (string, ≤32) on every transition, written with `MetadataSource.explicit` via `SurfaceMetadataStore`. This makes the state visible to the sidebar, `c11 tree --json`, the socket, and `c11 snapshot`/`restore` without coupling rendering to runtime Swift state.
- The reverse path (metadata write → Swift state) is *one-way only* on cold paths: `lifecycle_state` is read on `c11 restore` to seed the initial transition, but not subscribed to during steady-state operation. This avoids a metadata-write-during-typing reentrancy on the hot path.

Rationale: lifecycle transitions trigger native AppKit calls (detach, occlusion, CoreAnimation invalidation) that need typed access and can't tolerate metadata-blob roundtrips. But every observability and persistence consumer already speaks metadata — mirroring there for free is strictly better than building a parallel readout. The 64 KiB per-surface metadata cap is irrelevant; we add one short string.

`SurfaceLifecycleState` belongs on the panel/controller layer (`TerminalPanel`, `BrowserPanel`), not on the surface view itself. The view is too low-level — the panel is where workspace-visibility input arrives and where dispatch to the right native call lives.

### 1.4 Workspace-selection → lifecycle hook (the natural seam)

The hook point already exists. `Sources/ContentView.swift:2106-2145` wires every workspace's `isWorkspaceVisible` and `workspacePortalPriority` (0/1/2) into `WorkspaceContentView` based on `selectedWorkspaceId` and `retiringWorkspaceId`. `WorkspaceContentView` (`Sources/WorkspaceContentView.swift:43-52, 76-114`) computes `isVisibleInUI` per panel via `panelVisibleInUI(...)` and propagates to the panel layer.

Today the propagation only sets the `isVisibleInUI: Bool` gate, which is consumed for focus-following and z-priority. The lifecycle layer is added as a thin transformer: `panelVisibleInUI(...) → SurfaceLifecycleState` (true → `active`, false → `throttled` unless already `hibernated`), with the dispatcher invoked once on transition rather than on every render.

There is **no need for a new "workspace deselected" event**. The existing `isWorkspaceVisible` flip is the event; the lifecycle dispatcher hangs off it.

### 1.5 Persistence semantics across `c11 snapshot` / `restore`

| State at snapshot | State after restore |
|-------------------|---------------------|
| `active` | `active` if its workspace is selected at restore time, else `throttled`. Driven by the same workspace-selection hook above; no special-case code needed. |
| `throttled` | `throttled` if its workspace is still deselected; flips to `active` on first selection. Same auto path. |
| `suspended` | Same as `throttled` (this PR doesn't enter `suspended`; if C11-25b puts a browser there, restore should rehydrate to `active` only on the first focus event, not on snapshot apply). |
| `hibernated` | **Persists as `hibernated`.** Operator-intent; survives reload. Workspace selection alone does not auto-resume; operator must right-click → "Resume workspace" (the menu item flips text on hibernated workspaces). |

`lifecycle_state` is written through `SurfaceMetadataStore` with source `explicit`, so it flows through `WorkspacePlanCapture.swift:17` and `WorkspaceLayoutExecutor.swift:124-125` for free. No new persistence code; the snapshot/restore path already preserves arbitrary metadata.

`cc --resume` interaction: a hibernated workspace's terminal surfaces, when their workspace is later resumed, restart through the existing `AgentRestartRegistry` path. `cc` resumes via `claude.session_id` exactly as it does today after `c11 restart`. **No changes to the cc-resume wiring.**

### 1.6 Typing-latency invariant — the rule

**Lifecycle transitions execute outside every typing-latency hot path. Full stop.** Specifically:

- **`WindowTerminalHostView.hitTest()`** (`Sources/TerminalWindowPortal.swift`): pointer-events-only guard already in place. The lifecycle layer never adds work here. (CLAUDE.md confirms.)
- **`TabItemView`** (`Sources/ContentView.swift:8444-8451`): the `Equatable` contract gates body re-evaluation during typing. The lifecycle layer adds the `lifecycle_state` to the canonical-metadata projection that `TabItemView` already reads via `TerminalController.canonicalMetadataSnapshot()`. **This is allowed because the snapshot is a precomputed `let` parameter** (the existing pattern for canonical metadata fields). No new `@ObservedObject` / `@EnvironmentObject` properties are added; no `@Binding` changes; the `==` function gains exactly one string comparison for the new state.
- **`TerminalSurface.forceRefresh()`** (`Sources/GhosttyTerminalView.swift:3471-3510`): zero allocations, zero file I/O, zero formatting in this function or anything it calls during the hot path. Lifecycle dispatch is not invoked from `forceRefresh`. Occlusion is set on workspace-selection edge transitions only (a few times per second under heavy use, not per keystroke).
- **CPU/MEM sampler** runs on a background `DispatchSourceTimer` at a fixed cadence (proposed: 2 Hz, tunable to 1 Hz via `UserDefaults`). It never touches main; it writes results to an `os_unfair_lock`-protected dictionary that the sidebar reads via `let` projection. Sample takes the small hit of `proc_pid_rusage` — measured at <0.1ms per surface in prior c11 work — never on the keystroke path.

## 2. Scope decision

| # | Improvement | Recommendation | Why |
|---|---|---|---|
| 1 | Browser suspension cheap-tier (NSView detach) | **Ship now.** | The mechanism (`BrowserWindowPortal.detachWebView()` at `Sources/BrowserWindowPortal.swift:2787-2805`) already exists. Wiring it into the new lifecycle dispatcher is ~1 commit. Delivers the <1% CPU criterion on its own. |
| 2 | Browser suspension ARC-grade (snapshot + terminate WebContent) | **Ship now (operator override 2026-05-04).** | `WKWebView.takeSnapshot(with:completionHandler:)` is public API; `_webProcessIdentifier` is the SPI accessor for the WebContent PID (same SPI item 5 uses). Terminate via the WebKit-supported teardown path (preferred: `WKWebView.close()` if/when available; fallback: detach + nil-out config + release; last-resort: `kill(pid, SIGTERM)` against `_webProcessIdentifier`). Restore: refire `WKWebView.load(url:)` — cookies survive because `WKHTTPCookieStore` is process-pool-level. Scroll-position restore is best-effort: capture `scrollY` via JS bridge before terminate, replay on `didFinish` via `evaluateJavaScript`. **DoD impact:** delivers the <50 MB criterion. Restore-flow regression risk acknowledged; covered by validation harness in §5.5. |
| 3 | Terminal throttle in non-focused workspaces | **Ship now.** | `TerminalSurface.setOcclusion(_:)` (`GhosttyTerminalView.swift:3537-3540`) wraps `ghostty_surface_set_occlusion` which already throttles libghostty's CVDisplayLink. Wiring it into the lifecycle dispatcher is ~1 commit. PTY drains continue (libghostty's existing decoupling); no agent-side change needed. Delivers <2 Hz criterion. |
| 4 | Per-surface 30 fps cap | **Defer to C11-25c.** | No existing seam; libghostty owns its own CVDisplayLink (`Sources/GhosttyTerminalView.swift:3351, 3525`). Adding a per-surface cap requires either a libghostty patch (submodule change to `manaflow/ghostty`) or a Swift-side throttling wrapper around the surface's `setNeedsDisplay` calls. The latter is plausible but reaches into the typing-latency hot path; needs its own design pass. The DoD criterion's intent — "a spammy producer can't flood the renderer" — is partially addressed by item 3 (when the workspace is not focused, the occlusion path caps redraws regardless of producer). **Recommend C11-25c be sized as its own ticket with a dedicated typing-latency review.** |
| 5 | Per-surface CPU/MEM in sidebar | **Ship now.** | New `SurfaceMetricsSampler` runs on a `DispatchSourceTimer`, queries `proc_pid_rusage` for terminal child shells (PID known via `terminalSurface.tty` → `lsof`-style lookup or, simpler, the ghostty-managed child PID accessor — needs a small accessor patch on the Swift side). Browsers map via `WKWebView._webProcessIdentifier` (SPI, but accepted by App Review historically — flag for operator). Sidebar adds two small monospace rows per `TabItemView`. |
| 6 | Right-click "Hibernate workspace" | **Ship now.** | Pure composition over the new primitive. Adds two menu items in `c11App.swift:1308-1403` (Hibernate / Resume Workspace, mutually exclusive on workspace state); calls a `TabManager.hibernateWorkspace(_:)` which iterates panels and dispatches each surface to `hibernated`. Localization: ~2 strings × 6 locales = 12 entries. |

**Final sequencing (operator-decided 2026-05-04):**

1. **C11-25 (this PR):** lifecycle primitive + items 1-cheap, 1-ARC (item 2 in plan numbering), 3, 5, 6.
2. **C11-25c** (follow-up): item 4 (per-surface fps cap), needs typing-latency review and possibly a libghostty seam.

Estimated PR size: ~1700–2000 LoC across 9–10 commits. The ARC-grade tier adds ~500–800 LoC concentrated in browser portal + snapshot/restore plumbing; the cheap-tier and ARC-grade share the same lifecycle dispatch path so the cost is incremental, not duplicative.

## 3. Commit grouping

Order matters: lifecycle primitive → consumers → operator-facing. Each commit is independently green and reviewable.

| # | Title | LoC est. | Files (high-level) | Why this position |
|---|-------|----------|--------------------|-------------------|
| 1 | `Add SurfaceLifecycleState primitive + metadata mirror` | ~150 | `Sources/SurfaceLifecycle.swift` (new), `Sources/SurfaceMetadataStore.swift` (canonical key), `Sources/PaneMetadataStore.swift` (no change expected; pane-level is out of scope) | Foundation. Defines the enum, the dispatcher protocol, and the metadata key. No call sites yet. Tests: enum transition validator (pure unit), metadata key registration. |
| 2 | `Wire workspace-selection → lifecycle dispatch (terminal: occlusion)` | ~120 | `Sources/WorkspaceContentView.swift`, `Sources/TerminalController.swift` (panel-side hook), `Sources/Panels/TerminalPanelView.swift` | First consumer. On `isWorkspaceVisible` flip → call `terminalSurface.setOcclusion(visible:)` for every terminal in the workspace. **No change to forceRefresh.** Delivers DoD criterion #3 (<2 Hz terminal renderers). |
| 3 | `Wire workspace-selection → lifecycle dispatch (browser: cheap detach)` | ~150 | `Sources/Panels/BrowserPanel.swift`, `Sources/Panels/BrowserPanelView.swift`, `Sources/BrowserWindowPortal.swift` (no new surface API; reuses `detachWebView`/`bind` already at `BrowserWindowPortal.swift:2787-3030`) | Second consumer. On `throttled` → `detachWebView`; on `active` → `bind`. Delivers DoD criterion #1 (<1% CPU browsers). |
| 4 | `Add browser snapshot+terminate plumbing (ARC-grade)` | ~280 | `Sources/BrowserSnapshotStore.swift` (new — captures `WKWebView.takeSnapshot` → NSImage cache keyed by surface UUID; preserves URL + scrollY), `Sources/BrowserWindowPortal.swift` (snapshot-into-placeholder swap, WebContent termination via `_webProcessIdentifier` SPI / WebKit teardown), `Sources/Panels/BrowserPanelView.swift` (placeholder NSImageView render path during `hibernated`/`suspended`) | Adds the snapshot/terminate primitive used by hibernate. Independent of cheap-tier; cheap-tier remains the auto path for `throttled`. Delivers DoD criterion #2 (<50 MB browsers). |
| 5 | `Wire hibernated state → ARC-grade browsers (snapshot+terminate dispatch)` | ~120 | `Sources/Panels/BrowserPanel.swift`, `Sources/SurfaceLifecycle.swift` | On `* → hibernated`: snapshot, swap placeholder, terminate WebContent. On `hibernated → active`: re-create WKWebView, `load(url:)`, evaluate scrollY restore on `didFinish`. Composes commits 1+4. |
| 6 | `Add SurfaceMetricsSampler + sidebar CPU/MEM render` | ~250 | `Sources/SurfaceMetricsSampler.swift` (new), `Sources/ContentView.swift` (`TabItemView` body — reads precomputed snapshot only; **no new observed objects**), `Sources/TerminalController.swift` (snapshot publisher) | Uses `_webProcessIdentifier` SPI for browser PID; uses ghostty child-PID accessor for terminals. Delivers DoD criterion #5. **Risk:** typing-latency review for `TabItemView` change required (see §5). |
| 7 | `Add "Hibernate Workspace" / "Resume Workspace" right-click + localization` | ~120 + 12 string entries | `Sources/c11App.swift` (workspace context menu at lines 1308-1403), `Resources/Localizable.xcstrings` (en source only; translator pass per CLAUDE.md follows in a fresh c11 surface), `Sources/TabManager.swift` (`hibernateWorkspace(_:)`/`resumeWorkspace(_:)`) | Operator-facing surface. Composes 1+2+3+4+5. Delivers DoD criterion #6. |
| 8 | `Wire snapshot/restore for hibernated workspaces` | ~120 | `Sources/WorkspaceLayoutExecutor.swift`, `Sources/WorkspaceSnapshotConverter.swift`, `Sources/WorkspaceApplyPlan.swift` | Persistence: read `lifecycle_state == "hibernated"` on apply; on restore, hibernated browsers come up with placeholder NSImage rendered from disk-cached snapshot if present, else a neutral placeholder; resume on operator action triggers reload. `throttled` is implicit from workspace-selection state. |
| 9 | `Tests + DoD measurement harness` | ~300 | `tests_v2/test_surface_lifecycle.py` (new — socket-driven; runs on CI/VM per testing policy), `c11Tests/SurfaceLifecycleTests.swift` (transition validator unit tests) | Last. Verifies the DoD criteria scripted (see §4). |

**Total estimate:** ~1700–2000 LoC + ~12 i18n entries + 2 test files. Larger commits (#4, #6, #9) sit at 250–300 LoC; the rest are well under 200.

## 4. DoD measurement plan

| Criterion | Measurement approach | What "pass" looks like |
|-----------|----------------------|------------------------|
| Browsers in non-focused workspaces <1% CPU | `top -l 1 -pid <pid> -stats cpu` against the WebContent process bound to a detached WKWebView. Sampled 5× over 30s after workspace deselect. The `_webProcessIdentifier` SPI gives the PID; if SPI is rejected, fall back to "all WebContent procs whose `WKProcessPool` belongs to detached webviews" via summing. | Mean CPU ≤1% for at least 4/5 samples. (Cheap-tier detach removes the surface from CoreAnimation; CPU drops to idle. Pre-fix baseline is 5-15% per webview under steady-state JS animation.) |
| Browsers in non-focused workspaces <50 MB (snapshot tier) | Hibernate the workspace via `c11 workspace.hibernate <ref>`. Sample WebContent process RSS via `_webProcessIdentifier` (or `ps -o rss -p <pid>`) before hibernate and ~2 s after. After hibernate, the WebContent process should be gone (`kill -0 <pid>` returns exit 1), so post-hibernate RSS attributable to that webview is 0. The host-side residue (NSImage placeholder + WKWebViewConfiguration retention + Swift wrappers) should be <50 MB per surface — measured by the c11 process's RSS delta against a baseline before any of the test webviews loaded. | Per-surface host RSS delta after hibernate ≤50 MB; WebContent process is terminated. |
| Terminal renderers in non-focused workspaces <2 Hz | A debug socket command (added in commit 7's harness) `surface.report_render_metrics` returns last-frame-timestamp deltas from libghostty. Smoke harness deselects the workspace, runs `yes | head -c 1G` in a deselected terminal, samples for 10s, asserts the inter-frame interval is ≥500ms (i.e. ≤2 Hz). | Median inter-frame interval ≥500ms over the 10s window. |
| No surface exceeds 30 fps redraw | **Not measured in this PR.** Deferred with item 4 to C11-25c. (Note that for non-focused workspaces, item 3's <2 Hz cap is strictly stronger than 30 fps.) | n/a — see C11-25c. The "while focused, the radar still pegs" case stands until C11-25c. |
| Sidebar shows per-surface CPU/MEM | Smoke harness opens 3 surfaces with predictable load (idle shell, `yes > /dev/null`, an idle browser), reads `c11 tree --json` (which exposes `lifecycle_state` and the new `metrics` block on each surface), asserts the rough orders of magnitude. UI-side is verified by tagged-build screenshot (operator computer-use scenario) — see §5 validation depth. | `tree --json` shows `metrics.cpu_pct`, `metrics.rss_mb` on every surface; sidebar screenshot shows the values rendered next to the agent chip. |
| Right-click "Hibernate" works | Socket-driven: `c11 workspace.hibernate <ref>` (added as part of commit 5's plumbing) returns `ok`; `c11 surface.list --workspace <ref> --json` shows every surface in `lifecycle_state: hibernated`; webviews are detached (`browser.is_attached == false`); workspace can be `c11 workspace.resume`'d, all surfaces flip back to `active`. UI-side: tagged-build computer-use confirms the menu items render correctly localized. | All assertions pass. |

Where a criterion is hard to measure scripted (sidebar UI rendering), the cheapest acceptable harness is a tagged-build screenshot via the `c11-computer-use` validation skill, captured by the Validate sub-agent.

## 5. Risk callouts

### 5.1 Typing-latency hot paths touched

- **`TabItemView` body in `Sources/ContentView.swift:8444-8451`** — commit 4 adds two new fields (`cpu_pct`, `rss_mb`) to the canonical-metadata snapshot the tab item reads as a precomputed `let`. **Mitigation:** the `==` function in TabItemView's `Equatable` conformance is updated to compare these new fields. No new `@ObservedObject` / `@EnvironmentObject` / `@Binding`. Sampler writes to a separate `os_unfair_lock`-protected dictionary; snapshot publisher reads it on `objectWillChange` schedules that are not keystroke-driven.
- **`WorkspaceContentView`** — commit 2-3 add a transition dispatch on `isWorkspaceVisible` change. **Mitigation:** dispatch is on `onChange(of: isWorkspaceVisible)` (workspace-selection edge events only — at most once per workspace switch, not per keystroke). Inside the dispatch, every native call is on the main thread but bounded (`detachWebView` is O(1); `setOcclusion` is one libghostty call; metadata write is one dictionary update).
- **`TerminalSurface.forceRefresh`** — **not touched.** `setOcclusion` is called from a different code path entirely.
- **`WindowTerminalHostView.hitTest`** — **not touched.**

### 5.2 Submodule changes (Ghostty)

**None expected for this PR.** `ghostty_surface_set_occlusion` already exists in the libghostty C API and is wired in `setOcclusion` (line 3537). No new C symbols required. **Item 4 (deferred to C11-25c) is where a libghostty seam may be needed** — flag it for that ticket.

### 5.3 Localization

New user-visible strings:
- `contextMenu.hibernateWorkspace` → "Hibernate Workspace"
- `contextMenu.resumeWorkspace` → "Resume Workspace"

Total: 2 new keys × 6 locales = 12 translation entries. Per CLAUDE.md, after Impl lands the English strings, a Translator sub-agent runs in a fresh c11 surface to fill in `Localizable.xcstrings` for ja, uk, ko, zh-Hans, zh-Hant, ru.

Sidebar CPU/MEM rendering uses numeric formatting only (no new strings) — uses `Measurement` + `MeasurementFormatter` localized output for byte counts, and `NumberFormatter` percent style for CPU. This is locale-aware out of the box; no new keys needed.

### 5.4 Cross-cutting concerns

- **Focus management.** Hibernated workspaces should not become first-responder targets. The existing `isWorkspaceInputActive` / `isVisibleInUI` gates already block this. Verify in commit 5: hibernated webviews don't claim first responder when the workspace is selected briefly during snapshot/restore.
- **Drag-and-drop.** Hibernated browsers are detached from the view hierarchy; drops onto the workspace must not crash. **Mitigation:** the existing `bonsplitController.isInteractive = isWorkspaceInputActive` gate (`Sources/WorkspaceContentView.swift:61`) already blocks drops on inactive workspaces.
- **Find overlay.** `SurfaceSearchOverlay` (CLAUDE.md notes it must mount from `GhosttySurfaceScrollView`) is per-surface; throttling/occlusion does not affect mount. Verify in commit 7 harness: a `cmd-f` on a `throttled` surface that becomes `active` again works first try.
- **Snapshot/restore.** Covered in §1.5. Commit 6 explicit.
- **Mailbox delivery to suspended surfaces.** Mailbox delivery is via PTY stdin (`mailbox.delivery: stdin`) and the PTY drains in every state — the framed `<c11-msg>` block reaches the surface even when throttled/hibernated. This is correct: mailbox is asynchronous; the recipient's idleness or throttling does not change the delivery contract. Document in the C11-25 PR description.
- **Per-pane lifecycle.** This PR scopes lifecycle to **per-surface**, with workspace-level operations (hibernate workspace) iterating surfaces. Per-pane operations (hibernate one pane in a workspace while leaving siblings active) are not in scope; the primitive supports it but no UI is wired.
- **Multi-window c11.** `isWorkspaceVisible` is per-window (via the existing `tabManager` ownership). A workspace selected in window A but not window B is `active` in A — which is correct because workspaces are per-window today. No multi-window aliasing.

### 5.5 Validation depth

Per CLAUDE.md, never run tests locally. The Validate sub-agent runs:
- `gh workflow run test-e2e.yml` (E2E + UI suite).
- `tests_v2/test_surface_lifecycle.py` (new, socket-driven; on CI / VM).
- `c11Tests/SurfaceLifecycleTests.swift` (unit; on CI).
- A **tagged-build computer-use scenario** for the UI-visible parts: confirm the right-click menu items render, the sidebar shows CPU/MEM, switching workspaces visibly detaches/reattaches browsers without flicker. Per CLAUDE.md, the validator launches via `./scripts/reload.sh --tag c11-25` and `./scripts/launch-tagged-automation.sh c11-25`.

The harness runs the tagged build for at least one full "browser-heavy workspace deselect → 60s wait → reselect" cycle and snapshots `top` output before/after to capture the per-process CPU drop. Artifacts checked into `notes/c11-25-validation/`.

## 6. Do NOT ship in this PR

Explicit list. Anything below is deferred:

- Per-surface 30 fps redraw cap. Goes to **C11-25c**. (Operator-decided 2026-05-04: this is the only deferred behavior; libghostty seam needs its own typing-latency review pass.)
- SIGSTOP/SIGCONT of terminal child processes for hibernation. (Considered for hibernated terminals; defer until operator demand surfaces. The current "PTY drains, libghostty paused" is sufficient for the listed DoD criteria.)
- Per-pane (rather than per-workspace) hibernate UI. Primitive supports it; UI doesn't.
- Lifecycle subscription stream (an inotify-style "tell me when any surface state changes" socket method). Useful for Lattice/Mycelium consumers, but defer until a consumer actually asks.
- Markdown surface lifecycle beyond detach. Markdown surfaces are cheap; the detach already handled by the cheap tier covers the cost. Live-reload watchers staying alive in `throttled` is acceptable.
- Lifecycle entry into `suspended` for any surface kind. The state is reserved, not entered.

## 7. Adjacent observations

(Recorded for future tickets; not in scope.)

- `Sources/WorkspaceContentView.swift:43-52` — `panelVisibleInUI` is a static method; the visibility logic could grow a small "was visible recently" hysteresis to avoid thrash on rapid workspace cycling. Out of scope here, but if the lifecycle dispatcher gets noisy in steady-state telemetry, debouncing the trigger is a sensible follow-up.
- `Sources/BrowserWindowPortal.swift:2696-2705` — there's a 30ms-delayed `runHostedWebViewRefreshPass` in `refreshHostedWebViewPresentation`. After cheap-tier detach lands, this delayed-rebind path may produce a visible flash on workspace reselect. Watch for it during validation.
- `_dispatch.log` in the c11 mailbox dispatcher does not yet record envelopes that arrive while the recipient is `hibernated`. The existing PTY-write goes through; the *agent's* attention timing is the only thing that changes. Probably nothing to fix; surface for awareness.
- `TabManager.swift:535-573` — there's a CVDisplayLink in `TabManager` that's separate from libghostty's per-surface CVDisplayLink. Worth a sweep someday to confirm there's no double-pumping; not on the C11-25 critical path.

## 8. Open questions for the operator

Both resolved 2026-05-04 — see §0a above. ARC-grade tier in scope; SPI approved; only the 30 fps cap deferred.

(End of plan.)
