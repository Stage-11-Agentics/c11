# C11-171 root-cause analysis (v0.58.0 staging blocker)

## Defect 1 — `set_status`/`set_progress` bypass the evented canonical store

`c11 set-status <key> <value>` → `TerminalController.upsertSidebarMetadata` writes ONLY the
tab-scoped display store `tab.statusEntries[key]` (a `SidebarStatusEntry`). It never touches
`SurfaceMetadataStore`. Same for `set_progress` → `tab.progress`. Consequences:
- No `metadata.changed` event (only `SurfaceMetadataStore.setInternal`/`setMetadataLocked` emit,
  and only for `canonicalMetadataEventKeys`).
- No canonical `metadata_sources[key].ts` last-updated stamp; `get_metadata` shows nothing.

The sidebar *display* decay already works off `SidebarStatusEntry.timestamp` (ContentView
`SidebarMetadataEntryRow`), so acceptance (a)'s "pill decays" was already satisfied; the gap is the
canonical store + event stream.

Also: `EventEmitter.canonicalMetadataEventKeys = [status, title, description]` — **missing
`progress`**, which EVT-2 explicitly lists (status/title/description/progress).

### Fix 1
- Mirror canonical keys from the fast path into `SurfaceMetadataStore` at `.explicit` tier
  (surface = explicit `--surface`/`--panel` within the target tab, else `tab.focusedPanelId`):
  - `set_status <k> <v>` mirrors when `k ∈ {status, task, role, model, progress}` (agent-reportable
    canonical keys); arbitrary display chips (build/deploy) stay display-only.
  - `set_progress <v>` mirrors `progress` (number).
- Add `progress` to `canonicalMetadataEventKeys` (EVT-2).
- CLI `forwardSidebarMetadataCommand` resolves `--surface <ref>` → `--surface=<uuid>`.
- `log` audited: no canonical metadata target → stays display-only (append-only log entries).
- Threading: display write stays in `DispatchQueue.main.async`; the store mirror uses
  `setInternal` (store's own serial queue) — no `DispatchQueue.main.sync`.

## Defect 2 — derived liveness never fires in Release

`liveness.derived` events: **3 ever**, all in the C11-167 dev instance; **zero** in any
staging/prod instance. Root cause is a scope-resolution mismatch:

Shell integration (`cmux-zsh-integration.zsh`) reports on preexec/precmd:
`report_shell_state <state> --tab=$CMUX_TAB_ID --panel=$CMUX_PANEL_ID`. Per
`GhosttyTerminalView` env injection, **`CMUX_TAB_ID` is a legacy alias for the SURFACE uuid**
(not the workspace). So `--tab` = surface uuid.

`TerminalController.explicitSocketScope` treats `--tab` as the **workspace** id, so
`reportShellState`/`reportShellStateWorker` call `tabManagerFor(tabId: surfaceUUID)` →
`contextContainingTabId` matches on `tab.id` (workspace) → **no match → nil → silent no-op**.
So `updatePanelShellActivityState` → `onShellActivityChanged` → deriver is never reached.

Every *other* `report_*` fast path (git branch, directory, ports) has an app-side fallback
(git polling, OSC-7 PWD, ps sweep), so nobody noticed. Shell-activity/liveness has no fallback.
`tests_v2/test_telemetry_off_main.py` and the C11-167 test drive it with `--tab=<real workspace
uuid>`, which resolves — masking the bug in tests.

### Fix 2
- Resolve the workspace from the **panel** (surface) via
  `AppDelegate.workspaceContainingPanel(panelId:preferredWorkspaceId:)` in both the v1
  (`TerminalController.reportShellState`) and v2 (`SocketDispatch.reportShellStateWorker`) paths,
  routed through a pure `resolveShellActivityTarget(panelId:workspaceForPanel:)` helper for
  c11-logic testing. `--panel` is always the authoritative surface; `--tab` is only a hint.
- Backward compatible: tests sending `--tab=<workspace>` still resolve (preferred lookup hits).
