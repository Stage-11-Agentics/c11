# C11-141: Performance & resource hygiene (typing hot path, SwiftUI render cost, unbounded stores, teardown leaks, metadata)

## Performance & resource hygiene

Source: `notes/c11-audit-merged-2026-06-09.md` P1.1, P2.3, P2.4, P2.7, P2.8. Validated against HEAD `b3dfc10bc`. Theme: typing latency, SwiftUI render cost, and unbounded/leaked in-memory state. **Sequencing:** touches `GhosttyTerminalView.swift`/`ContentView.swift`/`TerminalController.swift` — coordinate with the Stability and Socket-surface tickets (don't parallel-worktree all three).

### A. Typing-latency hot path (P1.1)
- **Per-keystroke pasteboard XPC (CONFIRMED):** `forceRefresh("keyDown.textInput")` → `TerminalSurface.forceRefresh` (`GhosttyTerminalView.swift:3674`) → `forceRefreshSurface()` (`:4640`) → `updateSurfaceSize()` → `activeSurfaceResizeDeferralReason()` (`:4534`) → `hasTabDragPasteboardTypes()` reads `NSPasteboard(name:.drag).types` — an XPC roundtrip every keystroke, with no size-unchanged short-circuit first. The `isDragResizeEvent` check (commit `d089f6df1`) runs *after* the pasteboard read (`:4496`), so it does not prevent it. **Fix:** gate on `isDragResizeEvent(NSApp.currentEvent?.type)` before reading the pasteboard. (Violates the documented `forceRefresh` no-allocations rule.)
- **Sidebar sampler invalidates the whole sidebar 2-10 Hz (CONFIRMED):** `SurfaceMetricsSampler.tick()` bumps `@Published revision` unconditionally every tick (`:279-280`) regardless of whether any sample changed; the sidebar observes it (`ContentView.swift:8394`) and re-runs the per-tab precompute (`canonicalMetadataSnapshot` at `TerminalController.swift:11142`, `themedSidebarTabColors`, `AgentChipResolver`, worktree chips) at `ContentView.swift:8540-8587` — O(workspaces) every tick. The `TabItemView.equatable()` gate only skips leaf render, not the precompute. **Fix:** bump `revision` only when a sample actually changed; or hoist precompute behind sample equality.
- **`handleCustomShortcut` per keyDown (CONFIRMED `AppDelegate.swift:10159-10200`):** 5× `String(localized:)` (`:10187-10191`) + `NSApp.windows.compactMap{}.first{}` recursive `findStaticText` (`:10193-10200`) before any modifier early-out. **Fix:** early-return when no app-shortcut modifier present; cache the localized title array.
- **`TabItemView.==` compares colors via `hexString()` (CONFIRMED `ContentView.swift:11244-11245`):** NSColor→String conversion inside the equality hot path during typing-triggered diffing. **Fix:** compare NSColor components directly or precompute the hex once.
- **`hitTest` pointer branch reads drag pasteboard per `mouseMoved` (PARTIAL — keystroke half fixed):** the `isPointerEvent` gate (`TerminalWindowPortal.swift:254-264`, from C11-133) already excludes keyboard events; `:281` still fires `NSPasteboard(name:.drag).types` on every `mouseMoved`. **Fix:** short-circuit `DragOverlayRoutingPolicy` on event type before the pasteboard read for hover-only moves.
- **Eager `focusLog` interpolation (minor):** `focusLog` guards on `focusDebugEnabled` internally (`:4106`) but call sites build the interpolated string eagerly (not `@autoclosure`). On the scroll path, not typing. **Fix:** make `focusLog` take `@autoclosure () -> String`.

### B. SwiftUI structural perf (P2.4) — CONFIRMED, worse than stated
- **`ContentView.body` `AnyView` chain (CONFIRMED, ~30+ deep, not 16):** `ContentView.swift:2461-2854+` wraps `view = AnyView(view.onReceive/.onChange{})` 30+ times, each erasing type and defeating structural diffing; observes six observable objects so any chatty `@Published` re-evaluates the heavy body. **Fix:** replace the `AnyView` chain with a dedicated `ViewModifier` stack.
- **Autosave fingerprint blocks main (CONFIRMED `AppDelegate.swift:3855-3863,3995`):** the autosave timer runs on `queue:.main` (`:3855`) and calls `Workspace.readConversationsByPanelIdSync(timeout:0.5)` synchronously on main (`:3995`) every 8s. **Fix:** move the fingerprint read off-main, post result back. (Related to the Stability ticket's P0.3 sync-read issue — same method.)
- **`SurfaceMetricsSampler` missing `mach_timebase` conversion (CONFIRMED `:346`):** `proc_pid_rusage_v4` `ri_user_time &+ ri_system_time` is returned raw and `tick()` divides by `1e9` treating it as ns (`:260`), but these are mach-time units → CPU% understated ~41.7× on Apple Silicon (timebase 125/3). **Fix:** apply `mach_timebase_info` numer/denom before the ns division.

### C. Unbounded in-memory stores (P2.3)
- **Notifications array (CONFIRMED unbounded):** `insert(at:0)` no cap (`TerminalNotificationStore.swift:901`); `didSet` runs O(n) `buildIndexes` + `refreshDockBadge` per mutation (`:687-691`). **Fix:** ring of N.
- **Browser per-surface dicts (CONFIRMED)** — pruned only on explicit clear (shared with Socket-surface ticket P1.4). **Fix:** prune on surface close.
- **Snapshot images (CONFIRMED)** — `BrowserSnapshotStore.clear` fires only on resume/removal; hibernated-never-resumed images persist (shared with P1.4). **Fix:** evict on close + cap.
- **Scrollback temp dir** — present and stale-named `cmux-session-scrollback` (`SessionPersistence.swift:539`). **Fix:** rename + clean.
- **Drop, do NOT chase:** mailbox dedup ring — already bounded via `recentlySeenCap` (`MailboxDispatcher.swift:444-445`).

### D. Lifecycle / teardown leaks (P2.7) — CONFIRMED, narrowed
- **Block-based NotificationCenter observers never removed:** `GhosttyTerminalView.appObservers` (added `:1203,1212`) never removed (deinit `:4036` ignores it) — leaks per terminal surface; `TabManager.observers` (added `:1083,1096`) not cleared in deinit (`:1119-1122`). (The scroll-view subview's observers ARE cleaned at `:7119` — narrow the claim to those two sites.) **Fix:** clear both in deinit.
- **`browser.download.wait` leaks its observer on timeout (CONFIRMED `:13372-13389`)** — `.browserDownloadEventDidArrive` removed only inside its own handler; on `v2AwaitCallback` timeout it leaks. **Fix:** remove on the timeout path too.
- **Drop, do NOT chase:** per-markdown-panel mouse monitors — installed app-wide (`MarkdownPanelView.swift:550`) but removed in deinit (`:521-523`); not a leak.

### E. Metadata store consistency (P2.8) — all CONFIRMED
- **64KiB cap excludes the `sources` sidecar:** cap encodes only `blob` (`SurfaceMetadataStore.swift:539-540,623-626`); `sblob` never counted. **Fix:** include sidecar in the cap.
- **char-vs-byte cap inconsistency:** per-key validation uses `s.count` (Characters, `:222/294/312`); payload cap uses `encoded.count` (UTF-8 bytes) — multibyte strings pass per-key yet blow the byte cap. **Fix:** unify on byte limits.
- **`removeSurface`/`pruneWorkspace` queue ordering:** serial queue (`:139`); reads use `queue.sync` (`:358,376,468`) while removals use `queue.async` (`:481,490,504`) — nondeterministic ordering (no corruption). **Fix:** make removals sync / barrier.
- **`enforceSizeCap` can drop a canonical key (CONFIRMED `PersistedMetadata.swift:105`)** — eviction picks the largest-encoding key with no canonical-key protection. **Fix:** protect canonical keys.
- **`sameJSONValue` `1`==`true` dedup (CONFIRMED `:643`)** — NSNumber branch runs before the Bool branch and `Bool` bridges to NSNumber, deduping a type-changing write as a no-op. **Fix:** distinguish Bool from numeric.

### Acceptance
No XPC/pasteboard roundtrip or localized-string lookup on the keystroke path; the sidebar repaints only when a metric actually changes; sidebar CPU% reads true; notifications/snapshot/browser stores are capped or evicted on close; the two confirmed observer leaks are cleared in deinit; the metadata cap counts the sidecar and protects canonical keys.
