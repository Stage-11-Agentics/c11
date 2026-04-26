# Main-Thread Audit: DispatchQueue.main.sync in Socket Handlers

**Date:** 2026-04-24
**Branch:** c11-7/bounded-waits
**Author:** agent:opus-c11-7-plan
**Purpose:** Input for C11-4 (deadline-aware main actor bridge). Identifies which socket command handlers use `DispatchQueue.main.sync` in ways that block CLI callers indefinitely when the main thread is busy.

---

## Methodology

Grepped all `Sources/*.swift` files for `DispatchQueue.main.sync`. Each occurrence was traced back to its enclosing function and classified by call context:

- **SAFE**: The `main.sync` is either inside a debug-only code path, performs a read-only operation that completes in microseconds, or the enclosing function is not on the direct socket-handler call path.
- **RISKY**: The `main.sync` is in a live socket command handler invoked from the background accept-thread. The main thread may be busy (SwiftUI animations, workspace creation, window operations), causing the background thread to block indefinitely — the CLI caller blocks until `SO_RCVTIMEO` fires (10s default).
- **NEEDS_ASYNC**: RISKY and the fix path is clear: the mutation can be dispatched via a deadline-aware async + continuation pattern rather than a blocking sync. These are the highest-priority targets for C11-4.

**Threading context:** The socket accept loop runs on a detached thread (`Thread.detachNewThread` at line 1040). `processCommand` and `processV2Command` are called on that background thread. Every `DispatchQueue.main.sync` in a socket handler is a synchronous block of that thread waiting for the main thread — with no timeout.

---

## Summary

| File | Total occurrences | SAFE | RISKY | NEEDS_ASYNC |
|------|------------------|------|-------|-------------|
| Sources/TerminalController.swift | 103 | 46 | 38 | 19 |
| Sources/GhosttyTerminalView.swift | 1 | 1 | 0 | 0 |
| Sources/TabManager.swift | 1 | 1 | 0 | 0 |
| **Total** | **105** | **48** | **38** | **19** |

---

## Detail Table

### Non-socket-handler occurrences (SAFE)

| File:Line | Context | Classification | Reason |
|-----------|---------|----------------|--------|
| GhosttyTerminalView.swift:1881 | `performOnMain<T>` helper | SAFE | Called from internal UI paths (surface view), not socket handlers. |
| TabManager.swift:586 | VSync IOSurface timeline callback | SAFE | CoreVideo display link callback. Not a socket command path. |
| TerminalController.swift:3226 | `v2MainSync<T>` helper | SAFE | The helper itself; risk is in callers, classified below. |

### v2 handlers: workspace / window / surface / pane creation (NEEDS_ASYNC — Priority 1)

These are the highest-priority targets. They use `v2MainSync {}` to call `tabManager.addWorkspace`, `NSWindow` creation, and `Workspace.new*Surface/Split` methods. All of these can trigger SwiftUI layout passes, NSWindow creation, and Ghostty surface initialization — easily 50-500ms of main-thread time. Concurrent CLI calls (agent spinning up many workspaces) will queue behind each other on the main thread indefinitely.

| File:Line | Socket method | Classification | Reason |
|-----------|--------------|----------------|--------|
| TerminalController.swift:3592 | `window.create` | NEEDS_ASYNC | Calls `AppDelegate.createMainWindow()` — creates NSWindow, attaches tab manager, triggers layout. |
| TerminalController.swift:3629 | `workspace.list` | RISKY | Reads `tabManager.tabs`; fast when main is idle, blocks when main is busy with creation. |
| TerminalController.swift:3684 | `workspace.create` | NEEDS_ASYNC | Calls `tabManager.addWorkspace()` — creates a new tab, initializes terminal/UI state. Most expensive creation path. |
| TerminalController.swift:3715 | `workspace.select` | RISKY | Calls `tabManager.selectWorkspace()` — triggers sidebar re-render. |
| TerminalController.swift:3772 | `workspace.close` | RISKY | Calls `tabManager.closeWorkspace()` — triggers layout and cleanup. |
| TerminalController.swift:5163 | `surface.create` | NEEDS_ASYNC | Calls `ws.newTerminalSurface/newBrowserSurface/newMarkdownSurface` — creates bonsplit tab, allocates Ghostty surface or WKWebView. |
| TerminalController.swift:5221 | `surface.close` | RISKY | Calls bonsplit close + Ghostty/WebView teardown. |
| TerminalController.swift:6735 | `pane.create` | NEEDS_ASYNC | Calls `ws.newTerminalSplit/newBrowserSplit/newMarkdownSplit` — creates new bonsplit pane + surface. |

### v2 handlers: reads and simpler mutations (RISKY)

These block the background thread while waiting for main, but the main-thread work is fast when the main thread is actually available. They become a problem under load when the main thread is occupied with creation/animation work from concurrent commands.

| File:Line | Socket method | Classification | Reason |
|-----------|--------------|----------------|--------|
| TerminalController.swift:7693 | `notification.list` | RISKY | Reads notification store. Fast, but blocks if main is occupied. |
| TerminalController.swift:7710 | `notification.clear` | RISKY | Clears notification store. Fast mutation but synchronous. |

### Debug-mode-only v2 handlers (SAFE)

All `v2Debug*` handlers (lines 11743–12059) gate themselves on DEBUG builds or explicit debug API access. Not reached in production automation.

| File:Line | Handler group | Classification | Reason |
|-----------|--------------|----------------|--------|
| 11743–12059 | `v2DebugType`, `v2DebugToggleCommandPalette`, `v2DebugCommandPalette*`, etc. | SAFE | DEBUG-only handlers; not in production socket handler hot path. |

### v1 (legacy) handlers: workspace and surface mutations (NEEDS_ASYNC — Priority 2)

| File:Line | v1 command | Classification | Reason |
|-----------|-----------|----------------|--------|
| TerminalController.swift:13521 | `new_workspace` | NEEDS_ASYNC | Calls `tabManager.addTab` — same risk as `workspace.create`. |
| TerminalController.swift:13545 | `new_split` | NEEDS_ASYNC | Calls `tabManager.newSplit` — creates bonsplit pane. |
| TerminalController.swift:16848 | `new_surface` | NEEDS_ASYNC | Creates new surface in current pane. |
| TerminalController.swift:14493 | `close_workspace` | RISKY | Calls `tabManager.closeTab`. |
| TerminalController.swift:14506 | `select_workspace` | RISKY | Calls `tabManager.selectTab`. |
| TerminalController.swift:13600 | `focus_surface` | RISKY | Calls `tabManager.focusSurface`. |
| TerminalController.swift:15234 | `focus_pane` | RISKY | Calls `bonsplitController.focusPane`. |
| TerminalController.swift:15262 | `focus_surface_by_panel` | RISKY | Calls `tabManager.focusSurface`. |
| TerminalController.swift:15297 | `drag_surface_to_split` | NEEDS_ASYNC | Calls `bonsplitController.splitPane` — creates new pane. |

### v1 handlers: input injection (RISKY)

Terminal input injection calls Ghostty surface APIs on main. Not creation-heavy, but can block if main is rendering or processing events.

| File:Line | v1 command | Classification | Reason |
|-----------|-----------|----------------|--------|
| TerminalController.swift:14697 | `send_input` | RISKY | Calls `ghostty_surface_key` — must be on main, fast but blocks under load. |
| TerminalController.swift:14771 | `send_workspace` | RISKY | Input to workspace terminal. Main.sync to resolve target, then async for the actual inject. |
| TerminalController.swift:14858 | `send_surface` | RISKY | Input to specific surface. Same pattern. |

### v1 handlers: sidebar telemetry (RISKY — special case)

The `set-metadata`, `set-status`, `report_*` commands correctly use `DispatchQueue.main.async` for the actual mutation (fire-and-forget, returns "OK" immediately). These are **SAFE** for the CLI blocking problem. However, a few telemetry commands still use `main.sync` for the mutation:

| File:Line | v1 command | Classification | Reason |
|-----------|-----------|----------------|--------|
| TerminalController.swift:15986 | `log` / `append_log` | RISKY | Uses `main.sync` to append a log entry. This is a hotpath for agents. Should use `main.async`. |
| TerminalController.swift:16003 | `clear_log` | RISKY | Uses `main.sync` for log clear. Low-frequency, acceptable risk. |
| TerminalController.swift:15944 | `clear_meta_block` | RISKY | Uses `main.sync` for metadata block removal. |
| TerminalController.swift:15958 | `list_meta_blocks` | SAFE | Read-only, fast. |

### v1 handlers: read-only queries (SAFE)

| File:Line | v1 command | Classification | Reason |
|-----------|-----------|----------------|--------|
| TerminalController.swift:13506 | `list_workspaces` | SAFE | Read-only workspace list. |
| TerminalController.swift:13578 | `list_surfaces` | SAFE | Read-only surface list. |
| TerminalController.swift:13723 | `list_notifications` | SAFE | Read-only notification list. |
| TerminalController.swift:14527 | `current_workspace` | SAFE | Read UUID, fast. |
| TerminalController.swift:15154 | `list_panes` | SAFE | Read-only pane list. |
| TerminalController.swift:15178 | `list_pane_surfaces` | SAFE | Read-only surface list in pane. |
| TerminalController.swift:12344 | `read_screen` | SAFE | Reads terminal buffer. Fast unless scrollback is huge. |

### v1 handlers: drag/overlay/pasteboard (SAFE)

| File:Line | v1 command | Classification | Reason |
|-----------|-----------|----------------|--------|
| TerminalController.swift:12783 | `set_drag_pasteboard` | SAFE | Fast NSPasteboard operation. |
| TerminalController.swift:12790 | `clear_drag_pasteboard` | SAFE | Fast NSPasteboard clear. |
| TerminalController.swift:12809 | `overlay_hit_gate` | SAFE | Reads DragOverlayRoutingPolicy. Fast. |
| TerminalController.swift:12833 | `overlay_drop_gate` | SAFE | Same. |
| TerminalController.swift:12855 | `portal_hit_gate` | SAFE | Same. |
| TerminalController.swift:12878 | `sidebar_overlay_gate` | SAFE | Same. |

---

## Recommended Migration Priority for C11-4

### Tier 1: Fix immediately (blocking automation workflows)

These are the handlers that agents call in rapid succession when setting up workspaces. A single busy main-thread event can cause a cascade of CLI timeouts.

1. **`workspace.create`** (TC:3684) — most-called creation path, highest blast radius
2. **`surface.create`** (TC:5163) — second most-called, creates terminal/browser/markdown surfaces
3. **`pane.create`** (TC:6735) — split creation, often called right after workspace/surface create
4. **`window.create`** (TC:3592) — less frequent but creates an NSWindow (expensive)
5. **`new_workspace` / `new_split`** (TC:13521, 13545) — v1 equivalents used by older agents

### Tier 2: Fix as part of the same pass (low-friction wins)

6. **`log` / `append_log`** (TC:15986) — telemetry hotpath; should already be using `.async` like `set-status` does
7. **`workspace.select` / `workspace.close`** (TC:3715, 3772) — commonly called; mutations are fast but sync-blocked under load

### Tier 3: Low priority (read-only or low-frequency)

8. Notification list/clear, sidebar metadata reads — already fast; migrate in a cleanup pass

---

## Recommended Approach for NEEDS_ASYNC Handlers

The cleanest solution for Tier 1 handlers is a `withCheckedContinuation` / `Task { @MainActor }` pattern with a caller-side deadline:

```swift
// Pattern: deadline-aware main actor dispatch (server side)
func v2MainAsync<T: Sendable>(
    deadline: TimeInterval = 10.0,
    _ body: @MainActor @Sendable () -> T
) async throws -> T {
    try await withTimeout(seconds: deadline) {
        await MainActor.run { body() }
    }
}
```

The socket handler then becomes an `async` function dispatched onto a Swift Concurrency executor with a deadline, and the accept-loop spawns a `Task` per connection rather than blocking the thread.

The minimal change that doesn't require restructuring the entire accept loop is to keep the background-thread handler but replace `DispatchQueue.main.sync` with a semaphore+timeout pattern:

```swift
func v2MainSyncWithDeadline<T>(seconds: TimeInterval = 10.0, _ body: () -> T) -> T? {
    if Thread.isMainThread { return body() }
    var result: T?
    let sema = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
        result = body()
        sema.signal()
    }
    let waited = sema.wait(timeout: .now() + seconds)
    return waited == .success ? result : nil
}
```

This is the "minimal change" path. The full Swift Concurrency refactor is cleaner but requires rearchitecting the accept loop. C11-4 should decide between these two approaches.
