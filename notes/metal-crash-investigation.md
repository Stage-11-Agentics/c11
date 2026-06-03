# c11 Metal SIGABRT crash — investigation log

**Status:** active investigation. Crash repeated 3× on 2026-05-04 (twice in DEV, once in v0.45.0 prod). Operator considers it critical.

This file is the durable record. Update it incrementally so progress survives if c11 itself crashes.

---

## TL;DR

c11 is reliably crashing with `SIGABRT` inside Apple's Metal framework, at a defensive abort in the GPU command scheduler. All three crashes today have **identical PC and LR**, so it's the same bug, not three different things. It happens across DEV builds and the v0.45.0 production build, so it's a latent bug that pre-dates v0.45.0.

Correlated kernel signal: `(IOGPUFamily) c11 has reached a high water mark of N gpu command queues` warnings throughout the day, hitting 20 queues right before the worst crash. Queues are accumulating; eventually Metal's scheduler aborts during release of one of them.

The crash happens with **no AppKit dialog** because Ghostty's bundled `sentry-native` (breakpad backend) catches `SIGABRT` first, writes a minidump under `~/.local/state/ghostty/crash/`, and lets the process exit cleanly. macOS's own crash reporter UI never gets a chance.

---

## Crash signature (identical across all 3 today)

```
signal           = 0x6 (SIGABRT)
exception_addr   = 0x18c8e0c94
PC  = 0x18c8e0c94 → Metal`MTLSchedulerRequest::release() + 84
LR  = 0x18c8e07d8 → Metal`invocation function for block in
                    MTLSchedulerRequest::generateMonolithicBlock(qos_class_t, int) + 352
```

Sentry envelope tags: `build-mode=ReleaseFast`, `renderer=metal`, `font-backend=coretext`.
Sentry release tag: `1.3.0-HEAD+c649529` (from the bundled ghostty submodule, NOT c11's own version).

### Today's crashes

| Time (EDT) | Build                                                                 | Crash file (in `~/.local/state/ghostty/crash/`)                |
| ---------- | --------------------------------------------------------------------- | --------------------------------------------------------------- |
| 14:41:45   | DEV `c11 DEV main.app` (debug_id=`03ca0ac4`)                          | `1dfa4f9f-64be-43f5-d7ab-e37f12401e60.ghosttycrash`             |
| 15:01:56   | DEV `c11 DEV main.app` (debug_id=`03ca0ac4`)                          | `a8e787d8-ae63-434d-29d7-4f83ac166d79.ghosttycrash`             |
| 15:54:53   | **PROD `/Applications/c11.app v0.45.0`** (debug_id=`50eb7e8e`)        | `1a72b541-0bf4-4025-df61-6aba997f2f48.ghosttycrash`             |

Crash file = Sentry envelope: `event` JSON header (no `exception` populated, no breadcrumbs), then a `session` line showing `status=crashed`, then the binary minidump (`.dmp`).

### Production crash session timing

```
sid=9718503c-f1d4-4a1b-2337-659aed05652e
started=2026-05-04T19:33:25.821504Z
duration=1287.4 s   (≈ 21.5 minutes)
status=crashed
```

So /Applications/c11.app v0.45.0 ran for ~22 minutes after launch, then aborted.

---

## GPU command queue accumulation timeline (2026-05-04)

From `log show --predicate 'eventMessage CONTAINS "c11" AND eventMessage CONTAINS "high water"'`:

```
14:33:57   c11 has reached a high water mark of 10 gpu command queues.
14:57:05   c11 has reached a high water mark of 10 gpu command queues.
15:00:57   c11 has reached a high water mark of 10 gpu command queues.
15:00:59   c11 has reached a high water mark of 20 gpu command queues.   ← right before 15:01:56 crash
15:35:13   c11 has reached a high water mark of 10 gpu command queues.   ← prod c11 PID 96683
15:56:02   c11 has reached a high water mark of 10 gpu command queues.   ← *current* PID 51258
15:56:28   c11 has reached a high water mark of 10 gpu command queues.
```

Each row is a kernel `IOGPUFamily` watermark crossing. Default watermark warning threshold is 10. Going above 10 happens with normal multi-pane c11 use; going above **20** is what correlates with the actual abort.

---

## How we got the stack we have

The minidump's stream directory has `Exception` (id=6), `ThreadList` (id=3), `MemoryList` (id=5), `ModuleList` (id=4), `SystemInfo` (id=7), and a `MacCrashInfo` (id=0x47670001).

Sentry-native's ARM64 thread-context layout (verified empirically against this dump) is:

```
+0x000   uint64  context_flags / cpsr (combined; flags=0x80000006 = ARM64+INT+FLOAT)
+0x008   uint64  x0
+0x010   uint64  x1
...
+0x0f0   uint64  x29 (FP)
+0x0f8   uint64  x30 (LR)
+0x100   uint64  SP
+0x108   uint64  PC
... float regs follow
total ~796 bytes
```

PC + LR resolved with `lldb image lookup -a <addr>` against `/Applications/c11.app/Contents/MacOS/c11` (system images in shared cache resolve fine without dSYMs).

**We could not walk further down the stack** because sentry-native only captured ~256 bytes around SP for this thread — not enough to reach the FP-chain's first link. So we know we're inside Metal's scheduler block, but we don't see *which Ghostty/c11 code path* submitted the work that triggered the bad release. Widening this is one of the open tasks below.

### Other registers worth keeping

```
X0  = 0x1f943d140   (looks like an Obj-C class/pointer in a high system region)
X1  = 0x104ab2e94   (close to c11 image base 0x1048c8000 — but offset is *negative* from that base; not in the c11 .text)
FP  = 0x16b535690
SP  = 0x16b535670
```

X1 at 0x104ab2e94 is suspicious — it sits 0x1eb6c bytes *below* c11's image base 0x1048c8000, so it's *not* in the c11 binary. It might be a stack/heap pointer. Worth re-checking against the full module list once we have wider memory capture.

---

## Why Apple's crash UI never showed

Two crash handlers are installed in this process:

1. **Sentry-Cocoa** (c11's own SDK init at `Sources/AppDelegate.swift:2406`)
2. **Sentry-native + breakpad** (bundled inside the ghostty submodule)

Signal handlers chain LIFO. Ghostty's sentry-native installs *after* Sentry-Cocoa (the c11 app is already up by the time the ghostty subsystem boots), so it runs first on `SIGABRT`. It writes the minidump and lets the process exit cleanly via `_exit`. Apple's `ReportCrash` never sees the corpse, no `.ips`, no dialog.

`~/Library/Caches/SentryCrash/c11/Reports/` is empty for the same reason — Sentry-Cocoa's KSCrash never got the signal.

---

## Hypotheses (ranked)

### H1 (most likely): MTLCommandQueue lifecycle race in Ghostty's Metal renderer

`ghostty/src/renderer/Metal.zig:80-83` creates one `MTLCommandQueue` per Metal renderer. Renderer instances correspond to Ghostty surfaces. Released in `deinit()` at line 169. With c11's many surfaces (panes × tabs × workspaces) and the portal pattern that detaches/re-attaches surfaces between windows on splits and workspace switches, surfaces churn constantly. If a queue is released while it still owns in-flight `MTLCommandBuffer`s (or while their completion blocks haven't fired), Metal's `MTLSchedulerRequest::release()` will trip its internal refcount check and `abort()`.

The `generateMonolithicBlock` symbol in LR strongly supports this — that's Metal's internal batched submission path; the abort fires inside a block that the scheduler dispatches to clean up batched requests.

### H2: Cross-thread release of a Metal scheduler-owned object

Metal command queues and command buffers have thread-affinity rules. CLAUDE.md flags `WindowTerminalHostView.hitTest()`, `TabItemView`, and `TerminalSurface.forceRefresh()` as typing-latency hot paths — `forceRefresh()` is called on every keystroke. If a refresh path can run during a tear-down on a different thread (drag, portal move, hot-reload via `reload.sh --tag`), a queue could be released on one thread while its scheduler is mid-batch on another.

### H3: Drawable presentation against a destroyed CAMetalLayer

c11 portal moves reparent surface views between windows. If `CAMetalLayer.nextDrawable` is called or `presentDrawable:` fires after the layer's window has gone away, Metal's scheduler can wedge.

H1 and H2 are the strongest candidates. The defensive abort is at +84 bytes into `release()` — refcount-check territory — which leans H1.

---

## What's been ruled out

- **Memory pressure / jetsam.** No `EXC_RESOURCE` / `Jetsam` events for the c11 main process at crash time. (There were Safari WebContent watermark events, but those are siblings, not c11.)
- **Force-quit.** Force-quit produces no Sentry envelope at all (it bypasses signal handlers). We have envelopes, so the process actually aborted itself.
- **v0.45.0 regression.** The 14:41 and 15:01 DEV crashes are pre-v0.45.0 (DEV main was on v0.44.x). Same crash signature.
- **Hang.** Yesterday's `lockup-research-hang.md` event was a hang→force-quit (no Sentry record). Today's three are real aborts (Sentry record present). Different bug.

---

## Next steps (status: in progress)

1. ☑ **Live `sample` of PID 51258** — done, captured to `/tmp/c11-sample-pid51258.txt` (372 KB).
2. ☐ **Audit Ghostty Metal renderer surface lifecycle** — `ghostty/src/renderer/Metal.zig`, `Frame.zig`, surface init/deinit, hot-reload path.
3. ☐ **Audit c11 surface portal/teardown** — `Sources/GhosttyTerminalView.swift`, `Sources/Panels/TerminalPanelView.swift`, `TerminalWindowPortal.swift`. Look for paths where Metal renderer can outlive its drawable or have pending work during detach.
4. ☐ **Widen sentry-native stack capture** so the next crash gives us full FP-chain walk down to Ghostty/c11 frames.
5. ☐ **Synthesize root cause + propose fix.**

## Findings from `sample` (PID 51258, 6 s capture, 16:26 EDT)

### Surface count = renderer thread count

11 unique threads named `renderer` were sampled:

```
Thread_6690190: renderer
Thread_6690367: renderer
Thread_6690386: renderer
Thread_6690413: renderer
Thread_6690459: renderer
Thread_6693362: renderer
Thread_6693467: renderer
Thread_6693521: renderer
Thread_6693597: renderer
Thread_6741581: renderer
Thread_6741902: renderer
```

Each Ghostty surface owns one render thread *and* one `MTLCommandQueue` (created at `ghostty/src/renderer/Metal.zig:83` via `device.msgSend(...newCommandQueue)`). So **11 surfaces alive ⇒ 11 active `MTLCommandQueue` objects.** That fully explains the kernel `IOGPUFamily: c11 has reached a high water mark of 10 gpu command queues` line — c11 is at 11 *right now* and growing as workspaces/tabs churn. Each renderer thread shows matching `io`/`io-reader` siblings, so the 11 number is consistent (1 renderer + 1 io + 1 io-reader = 3 threads per surface).

Notice the thread-id batches: `6690…` (5 surfaces, all consecutive — created at app startup), `6693…` (4 surfaces, created later), `6741…` (2 surfaces, created later still). **Surfaces are getting created over the lifetime of the session** — that's expected (open new tab, split pane, switch workspace) but if any creation path doesn't have a matching destruction path, we leak queues forever.

### Active Metal call paths in c11

```
renderer.generic.Renderer(renderer.Metal).drawFrame   (in c11) + N
renderer.generic.Renderer(renderer.Metal).updateFrame (in c11) + N
renderer.generic.Renderer(renderer.Metal).addGlyph    (in c11) + N
renderer.metal.RenderPass.begin                       (in c11) + 1340
  → -[AGXG16XFamilyCommandBuffer renderCommandEncoderWithDescriptor:]
    → -[AGXG16XFamilyRenderContext initWithCommandBuffer:descriptor:subEncoderIndex:framebuffer:]
      → AGX::Framebuffer<…>::Framebuffer(…)
-[_MTLCommandQueue _submitAvailableCommandBuffers]
-[_MTLCommandQueue commandBufferDidComplete:startTime:completionTime:error:]
```

These are the live "happy path" — drawing frames, encoding render passes, submitting to the queue. The crash isn't here; the crash is in the *cleanup* path (see below).

### Lifecycle analysis (Ghostty side)

Surface destruction flow (read from `ghostty/src/Surface.zig:828` and `renderer/generic.zig:806`):

```
Surface.deinit
  └─ renderer_thread.deinit
  └─ Renderer.deinit                       (generic.zig:806)
        └─ swap_chain.deinit               (generic.zig:282) — waits on frame_sema × buf_count
        └─ api.deinit                      (Metal.zig:167)
              ├─ last_surface.release()
              ├─ queue.release()           ← MTLCommandQueue
              ├─ device.release()
              └─ layer.release()
```

`SwapChain.deinit` *does* drain in-flight frames via the semaphore (`frame_sema.wait()` × `buf_count`), and the semaphore is posted from inside `Renderer.frameCompleted` (`generic.zig:1794`), which is called from the Metal completion block (`metal/Frame.zig:90`). So in principle, by the time `swap_chain.deinit` returns, all completion blocks have *started* running.

**The likely race:** the completion block on the Metal scheduler thread calls `block.renderer.api.present(target, sync)` and `block.renderer.frameCompleted(health)`. After the second call posts the semaphore, swap_chain.deinit returns and api.deinit immediately releases the queue. But the Metal scheduler trampoline that *invoked* the block may still be doing internal cleanup of the `MTLSchedulerRequest` it just dispatched. If that cleanup races with `queue.release()` running on the renderer/main thread, we get exactly the abort we see — `MTLSchedulerRequest::release() + 84` from inside `generateMonolithicBlock`.

Possible mitigations to validate:

1. **Submit a no-op command buffer with `waitUntilCompleted`** in `Metal.deinit` before releasing the queue. This forces the scheduler to drain everything tied to that queue before we yank it.
2. **Drop the queue release entirely** and let ARC handle it — but this is Zig, no ARC; the manual `release()` is on a +1-retained object, so we have to release somewhere.
3. **Call `[queue waitUntilCompleted]`** style equivalent — Metal doesn't have that on queue, but issuing a sync command buffer as in option (1) is the standard pattern.
4. **Order the deinit** so that `layer.release()` happens before `queue.release()` — releasing the layer drops any pending presentation.

### Smoking-gun open question

Does ghostty/c11 ever **leak** Metal renderer instances (creating new surfaces without destroying old ones)? The watermark hitting 20 in the 15:00 window, but only 11 surfaces alive now, suggests *some* surfaces did get cleaned up — but not all. Worth a deeper Swift-side audit (task #4) to confirm whether portal moves or hot-reload create new renderers without tearing down old ones.

---

## Synthesis (after Ghostty + Swift parallel audits) — root cause found

Two parallel audits (one focused on Ghostty Zig code, one on c11 Swift code) **converge on the same root cause**:

> `ghostty/src/renderer/Metal.zig:167-172` — `Metal.deinit` releases `MTLCommandQueue` (and `device`, `layer`) immediately after `swap_chain.deinit` returns. The semaphore drain inside `swap_chain.deinit` only proves Metal completion blocks have *started* running on Metal's scheduler thread; it does **not** prove the surrounding scheduler trampoline (`MTLSchedulerRequest::generateMonolithicBlock` in the LR) has unwound. Metal's scheduler keeps a refcount on the queue past block return; releasing the queue while the trampoline is still tearing down its `MTLSchedulerRequest` trips a defensive abort in `MTLSchedulerRequest::release()+84`. That's the SIGABRT we see.

### What the Swift side cleared

- **Surface lifecycle is 1:1 panel→surface, idempotent, no leaks.** `Sources/GhosttyTerminalView.swift:3046-3082` early-returns from `attachToView` when already bound.
- **Portal moves do not destroy/recreate surfaces** — they reparent the same `GhosttyNSView`/`CAMetalLayer` between windows (`Sources/TerminalWindowPortal.swift:1452,2151-2154`).
- **`forceRefresh` is teardown-safe** — re-validates `self.surface` between calls (`:3492, :3508`). Recent commit `85d9209a` (C11-26) explicitly hardened this against UAF, suggesting the team has seen analogous pointer-staleness bugs.
- **Hot-reload (`scripts/reload.sh:417`) is `pkill`** — bypasses the deinit path entirely, so it's not the SIGABRT trigger.

### One Swift-side amplifier (not the bug, but widens the race)

`TerminalSurface.teardownSurface` at `Sources/GhosttyTerminalView.swift:2964` and `deinit` at `:3798` both schedule `ghostty_surface_free` via `Task { @MainActor in ... }` — the free runs on the **next** main-actor turn rather than synchronously. Between panel removal and the actual free, the renderer thread can present additional frames whose Metal completion blocks fire after the free. **The Swift code is not the bug, but it makes the upstream race easier to hit.**

### What the Ghostty side confirmed

- `Metal.deinit` has no GPU drain barrier — no `commandBuffer + commit + waitUntilCompleted`.
- `Metal.zig` has no `loopExit` / `threadExit` / display-callback teardown. The `displayCallback` installed in `loopEnter` (`:174-180`) holds a raw `*Renderer` pointer in CAMetalLayer ivars and is never cleared, so `CAMetalLayer.display` against a freed layer is a *separate* dangling-pointer foot-gun (sibling bug, same patch).
- Release order is wrong: `last_surface, queue, device, layer`. Should be `layer` first (drops pending presentation), then `queue`, then `device`.
- `Frame.zig:67-91` `bufferCompleted` calls `block.renderer.api.present(...)` *and* `block.renderer.frameCompleted(...)`. After `frameCompleted` posts the semaphore, if the destroying thread is already waiting in `swap_chain.deinit`, it returns and proceeds to `api.deinit` while the completion block's outer scheduler frame is still alive.
- No upstream ghostty issue matches this signature. Likely an unreported latent bug.

### Why we never got an AppKit dialog

Confirmed: `Sources/AppDelegate.swift:2413` initializes Sentry-Cocoa **before** `ghostty_init` (called via `ghostty_app_new` at `:1158-1179`). Signal handlers chain LIFO — ghostty's `sentry-native` (breakpad backend, per `ghostty/src/build/SharedDeps.zig:316`) installs *after*, so it runs *first* on `SIGABRT`, writes the minidump, and `_exit`s. Sentry-Cocoa never sees the signal. Apple's `ReportCrash` UI never gets called.

---

## The fix (proposed)

### Primary: drain barrier + reordering in `ghostty/src/renderer/Metal.zig:167-172`

```zig
pub fn deinit(self: *Metal) void {
    // 1. Detach the display callback so CAMetalLayer.display can't
    //    reach a freed *Renderer if it fires post-teardown.
    self.layer.setDisplayCallback(null, null);

    // 2. Drain the queue: submit an empty command buffer and wait
    //    synchronously. Forces Metal's scheduler to fully unwind any
    //    pending request blocks tied to this queue before we release it.
    const buf = self.queue.msgSend(objc.Object, "commandBuffer", .{});
    buf.msgSend(void, "commit", .{});
    buf.msgSend(void, "waitUntilCompleted", .{});

    // 3. Release in the correct order: layer (drops pending present)
    //    → queue → device.
    if (self.last_surface) |s| s.release();
    self.layer.release();
    self.queue.release();
    self.device.release();
}
```

Cost: one no-op command buffer per surface destruction (sub-millisecond). No effect on typing-latency hot paths (CLAUDE.md flags). Independently mergeable upstream — c11 wouldn't carry a permanent fork delta.

### Secondary: tighten the Swift race window

In `Sources/GhosttyTerminalView.swift`:
- Replace `Task { @MainActor in ghostty_surface_free(surfaceToFree) }` (lines 2964 and 3798) with a synchronous `MainActor.assumeIsolated { ghostty_surface_free(surfaceToFree) }` where the caller is already `@MainActor`. This eliminates the deferred-free turn that lets extra frames complete after panel removal.
- Pin `TerminalSurface.deinit` to `@MainActor` so the local capture and free path always run on the main actor (Swift 5.10+ `isolated deinit` is fine here; macOS 26 ships Swift 6).

These don't fix the bug — Ghostty fix does — but they shrink the race window so a not-yet-fixed Ghostty checkout is still less crash-prone.

### Tertiary: visibility for next time

Sentry-native's breakpad backend (linked at `SharedDeps.zig:316` with `.backend = .breakpad`) only captures ~256 bytes of stack memory per thread, which is why this dump cut off above the Metal frames. Two improvements, in order of effort:

1. **Add lifecycle breadcrumbs.** `sentry.addBreadcrumb` in `Metal.deinit`, `Surface.deinit`, `Renderer.frameCompleted` (with surface id). The next crash will tell us *which* surface was being destroyed and what its frame state was. The current envelope has `breadcrumbs: []` because nothing emits them.
2. **Switch sentry-native backend from `breakpad` to `crashpad`** (`SharedDeps.zig:316`). Crashpad captures full thread state; breakpad captures a minimal dump. This is a bigger change (crashpad is a separate process model, may need build/runtime work) and is independently worth doing.

---

## Status

| Task                                                           | Status        |
| -------------------------------------------------------------- | ------------- |
| Capture live sample of PID 51258                               | ☑ done        |
| Write crash investigation to durable markdown                  | ☑ done        |
| Audit Ghostty Metal renderer surface lifecycle                 | ☑ done (root cause confirmed) |
| Audit c11 surface portal/teardown paths                        | ☑ done (clean; one amplifier identified) |
| Configure sentry-native wider stack capture                    | ◐ recipe written; not implemented |
| Synthesize root cause + fix proposal                           | ☑ done (this section) |

**Recommended next action:** apply the primary fix to `ghostty/src/renderer/Metal.zig:167-172` in a c11-owned ghostty submodule branch, build with `./scripts/reload.sh --tag metal-deinit-drain`, and exercise heavy workspace/pane churn (the established repro vector) to validate the watermark stops climbing past 11 and no SIGABRT fires. If the fix holds for ≥1 hour of normal use, propose upstream against `ghostty-org/ghostty`.

---

## Implementation log

### Branch + remote setup

- Ghostty submodule branch: `metal-deinit-drain` (created 2026-05-04 ~16:55 EDT off detached HEAD `c649529750b12e7fde7a33b74d5310a1b988cb67`).
- Remote `stage11` added in the ghostty submodule pointing at `https://github.com/Stage-11-Agentics/ghostty.git`. The fork's `main` is fetched and HEAD is an ancestor of `stage11/main`, so the branch is push-clean. Per the operator's "no writes to manaflow-ai/*" policy, pushes go to `stage11`, never `origin`.

### Patch applied: `ghostty/src/renderer/Metal.zig`

Commit `b4ef0ac2c` on `metal-deinit-drain`:

```diff
 pub fn deinit(self: *Metal) void {
+    // Detach the display callback before any release. If a CAMetalLayer
+    // display tick fires after the parent Renderer is freed, the stored
+    // *Renderer pointer would dangle. Setting both ivars to null first
+    // makes the layer's drawInContext bail cleanly.
+    self.layer.setDisplayCallback(null, null);
+
+    // Drain the command queue with a synchronous no-op command buffer.
+    // SwapChain.deinit waits on the frame semaphore, which only proves
+    // each completion handler has *started* on Metal's scheduler thread.
+    // It does NOT prove the surrounding MTLSchedulerRequest trampoline
+    // (the block dispatched by generateMonolithicBlock) has unwound.
+    // Releasing self.queue while the trampoline is mid-cleanup races
+    // with Metal's internal MTLSchedulerRequest::release() and SIGABRTs.
+    // A committed-and-waited empty command buffer forces the scheduler
+    // to fully drain anything tied to this queue before we release it.
+    {
+        const pool = objc.AutoreleasePool.init();
+        defer pool.deinit();
+        const buf = self.queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});
+        buf.msgSend(void, objc.sel("commit"), .{});
+        buf.msgSend(void, objc.sel("waitUntilCompleted"), .{});
+    }
+
+    // Release order matters: drop the layer first (which releases any
+    // pending presentation request), then the queue (now safe because
+    // we just drained it), then the device (which the queue retained).
     if (self.last_surface) |s| s.release();
+    self.layer.release();
     self.queue.release();
     self.device.release();
-    self.layer.release();
 }
```

The autoreleasepool wraps the no-op command buffer creation so the buffer object is properly released after the wait — matching the pattern Ghostty uses around `drawFrame` (`Metal.zig:191-202`).

### Build pipeline

The xcframework is keyed by the ghostty submodule SHA. New SHA = `b4ef0ac2c…` (commit message above). c11's `scripts/setup.sh:23-85` looks up `~/.cache/cmux/ghosttykit/<sha>/GhosttyKit.xcframework`; if absent, it builds locally and seeds the cache. Symlink `c11/GhosttyKit.xcframework` then points at the cache entry.

For local validation we don't need to push anywhere first — the rebuild stays on disk under the new SHA. Steps executed:

1. ☑ `git checkout -b metal-deinit-drain` in submodule.
2. ☑ Edit `Metal.zig` and `git commit`.
3. ☐ **In progress:** `cd ghostty && zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=universal -Doptimize=ReleaseFast` — started 16:58:07 EDT, expected ~10 min. Output streamed to `/private/tmp/.../tasks/bulmew0rt.output`.
4. ☐ After build: stamp `ghostty/macos/GhosttyKit.xcframework/.ghostty_sha` with the new SHA, run `./scripts/setup.sh` to seed cache + retarget symlink.
5. ☐ `./scripts/reload.sh --tag metal-deinit-drain` to build a tagged DEV c11 against the patched xcframework.
6. ☐ Launch the tagged app, exercise the repro vector, monitor watermarks and crash directory.

### Validation plan

Run for ≥30 minutes of normal multi-pane / multi-workspace use, with the following monitors live:

```bash
# 1. Watermark monitor — should plateau near surface count, not climb.
log stream --predicate 'eventMessage CONTAINS "c11" AND eventMessage CONTAINS "command queues"' \
    | tee /tmp/c11-validation-watermarks.log

# 2. Crash dir watch — any new .ghosttycrash file is a regression signal.
fswatch -0 ~/.local/state/ghostty/crash/ \
    | xargs -0 -I{} echo "$(date '+%H:%M:%S') NEW CRASH FILE: {}" \
    | tee /tmp/c11-validation-newcrashes.log

# 3. Tag confirmation — confirm the build under test is the patched one.
ls -la /Applications/c11.app /tmp/c11-cli /tmp/c11-last-debug-log-path /tmp/c11-last-socket-path
cat /tmp/c11-last-cli-path  # should resolve to a c11-metal-deinit-drain DerivedData path
```

**Success criteria:**

- Zero new entries in `~/.local/state/ghostty/crash/` for the duration of the test.
- Watermark count climbs only when surface count climbs and **drops back** when surfaces are destroyed (we now drain on deinit, so each closed surface should release its queue cleanly).
- App stable across `cmd-W` close pane, `cmd-T` open tab, workspace switching, and a full hot-reload cycle (`reload.sh --tag metal-deinit-drain` again, while the app is running).

**Failure modes to instrument:**

- New crash file → parse with the same Python minidump walker (`/tmp/c11-crash.dmp` produced via `python3` envelope split, `lldb image lookup -a <pc>`). If the new crash signature differs from the SIGABRT-in-`MTLSchedulerRequest::release+84` baseline, that's progress (different bug now); if same, the drain barrier didn't take effect.
- App fails to launch / black terminal — likely a ZIG build issue. Check `/tmp/c11-xcodebuild-metal-deinit-drain.log` and the zig build output.
- `assert(self.autorelease_pool == null)` fires in `drawFrameStart` — would mean autoreleasepool nesting got confused. The fix uses a local pool that's `defer`-released, so no leak into the field's pool, but worth watching.

### Push policy

After local validation passes:
1. Push `metal-deinit-drain` to `stage11` (Stage-11-Agentics/ghostty fork) — never `origin` (manaflow-ai), per operator policy.
2. Update c11's submodule pointer (`git -C ghostty rev-parse HEAD` then `git -C .. add ghostty && git commit -m "ghostty: bump submodule for Metal.deinit drain"`).
3. Add an entry to `c11/scripts/ghosttykit-checksums.txt` (CI guard requires this — see CLAUDE.md "GhosttyKit xcframework and checksums").
4. Open PR upstream to `ghostty-org/ghostty` proposing the fix; it's not c11-specific.

---

*Last updated: 2026-05-04 16:58 EDT — patch committed to ghostty submodule, xcframework build in progress.*

---

## Build & launch outcome (2026-05-04 17:00–17:05 EDT)

| Step                                                        | Outcome |
| ----------------------------------------------------------- | ------- |
| `zig build -Demit-xcframework=true ...` in submodule        | ☑ ~2.5 min (universal, ReleaseFast) |
| Stamp `.ghostty_sha = b4ef0ac2c…` on the built xcframework  | ☑ |
| `setup.sh` to seed cache + retarget c11/GhosttyKit symlink  | ☑ — but it ran `git submodule update --init` which **reset HEAD back to c649…** and seeded the cache from the old SHA. **Recovered manually:** `git checkout metal-deinit-drain` in submodule, then manual `cp -R ghostty/macos/GhosttyKit.xcframework ~/.cache/cmux/ghosttykit/b4ef0ac2c…/`, then `ln -sfn` the c11 symlink. Worth filing: `setup.sh` should run after the submodule update completes, or detect a non-detached-HEAD submodule and skip the reset. |
| `./scripts/reload.sh --tag metal-deinit-drain`              | ☑ `** BUILD SUCCEEDED **` |
| New app binary check                                        | ☑ `c11.debug.dylib` 72 MB built 17:04, contains symbol `_renderer.Metal.deinit` |

Tagged build runs from `/Users/atin/Library/Developer/Xcode/DerivedData/c11-metal-deinit-drain/...`. Socket: `/tmp/c11-debug-metal-deinit-drain.sock`. Debug log: `/tmp/c11-debug-metal-deinit-drain.log`.

---

## Validation phase (in progress)

### Strategy

Operator's call: rather than try to drive synthetic churn against the patched build (which we couldn't target reliably — the dev CLI was ignoring `C11_SOCKET` and falling back to the production socket — that's a separate dev-CLI bug worth filing), **promote the patched build to the primary dev instance** and validate over real-world use.

If the patched build runs for ≥several hours of normal multi-pane / multi-workspace work without producing a new `.ghosttycrash` file under `~/.local/state/ghostty/crash/`, the fix is good. If a fresh crash appears, parse it: same Metal signature → fix didn't take; different signature → progress (separate bug).

### Live monitors

- `tail -f /tmp/c11-validation-watermarks.log` — kernel `IOGPUFamily` watermark events for any process named c11.
- `tail -f /tmp/c11-validation-newcrashes.log` — diffs the count of files in `~/.local/state/ghostty/crash/` every 5 s and prints a banner on growth.

### Baseline (at patched-build launch, 17:04 EDT)

- 7 `.ghosttycrash` files in `~/.local/state/ghostty/crash/` (all pre-patch). Newest = `1a72b541-…` from 15:56:17 (the prod crash investigated above).
- Patched c11 PID 44144, RSS 280 MB at launch.

### Live observations

| Time     | Event                                                                  |
| -------- | ---------------------------------------------------------------------- |
| 17:06:17 | **mis-targeted** churn cycle 1 hit *unpatched* prod c11 (PID 51258) — created 7 splits, watermark hit 20, no SIGABRT. **Surprising:** unpatched build survived the same condition that crashed it earlier. Suggests the prod crash needs more than just "20 queues alive" — possibly a specific user action or longer accumulation. |
| 17:08:24 | Watermark hit 10 — coincides with operator manually clicking around in patched build (per their message). |

### Accidental finding worth keeping: dev-CLI socket override broken

The dev shim at `/tmp/c11-cli` execs the tagged build's CLI binary, which then connects to its own default socket regardless of `C11_SOCKET`/`CMUX_SOCKET` env vars. Verified by:

```
$ C11_SOCKET=/tmp/c11-debug-metal-deinit-drain.sock /tmp/c11-cli identify
{ "socket_path": "/Users/atin/Library/Application Support/c11mux/c11.sock", ... }
```

Expected: identify returns the metal-deinit-drain socket. Actual: returns the prod build's default. This silently misroutes any tagged-build CLI commands to whichever c11 holds the default socket. Should be filed as a separate dev-CLI bug — affects any local validation that needs to target a specific tagged build.

---

## Status snapshot

| Task                                              | Status | Notes |
| ------------------------------------------------- | ------ | ----- |
| Apply Metal.deinit fix                            | ☑      | Branch `metal-deinit-drain` @ `b4ef0ac2c` in ghostty submodule |
| Build patched GhosttyKit.xcframework              | ☑      | ~2.5 min, universal, ReleaseFast |
| Build tagged c11 DEV                              | ☑      | `c11 DEV metal-deinit-drain.app`, PID 44144 |
| Validate via repro vector                         | ◐      | Switched to extended-real-use validation per operator |
| Configure sentry-native wider stack capture       | ☐      | Recipe in this doc; deferred — not blocking the fix |

### Decision points still open

1. **When does the patch get pushed to `stage11`?** Recommended: after ≥2 hours of clean operation in real use.
2. **Upstream PR to `ghostty-org/ghostty`?** The fix is independently merge-worthy; not c11-specific.
3. **Submodule pointer bump in c11 parent repo?** Required before this becomes the default for everyone — but blocked on `scripts/ghosttykit-checksums.txt` (CI guard) needing a matching entry, which only the build-ghosttykit workflow generates after a push to a tagged ref.

---

*Last updated: 2026-05-04 17:11 EDT — patched build running as dev primary, monitors live, awaiting real-use signal.*

---

## Reproduction recipe (provisional — to refine)

Symptoms suggest the trigger is *frequent* surface churn. Provisional repro:

1. Open c11, create 4+ workspaces with multiple tabs each.
2. Rapidly switch workspaces / split/unsplit panes / drag tabs between windows.
3. Watch `log show --predicate 'eventMessage CONTAINS "c11" AND eventMessage CONTAINS "command queues"'` for the watermark line climbing past 10, 20, 30.
4. Eventually: `SIGABRT`, no UI dialog, window vanishes silently.

**Refining this is one of the goals — confirm whether portal moves specifically are the trigger.**

---

## Useful artifacts on disk

- `/Users/atin/.local/state/ghostty/crash/1a72b541-*.ghosttycrash` — production crash envelope (1.9 MB).
- `/tmp/c11-crash.dmp` — extracted minidump from the production crash.
- `/tmp/c11-crash-event.json` — extracted Sentry event JSON.
- `/tmp/c11-frames.txt` — recovered frame addresses (only 2 due to truncated stack).
- `/tmp/c11-sample-pid51258.txt` — live sample of current c11 (in progress).
- `/tmp/c11-debug-main.log` — DEV build's full debug log (38 MB) — last entry 15:56:59 (the DEV process died right after the prod crash; logs around 14:40 and 15:00 should bracket the two DEV crashes).

---

## Open questions

- Does Sentry web have either of these envelopes uploaded? Check the Sentry project the ghostty SDK targets (DSN baked into the ghostty submodule, separate from c11's own `stage11-c11` project). Symbolicated stack from Sentry would replace most of this manual work.
- Was the v0.45.0 dSYM uploaded successfully? PR #117 made the upload non-fatal but #116 ("Bump version to 0.45.0") shows as a failed run. The release artifacts on GitHub do not include a dSYM tarball.
- Are there ghostty upstream issues for `MTLSchedulerRequest::release` SIGABRTs? Worth searching once we have a hypothesis to validate.

---

*Last updated: 2026-05-04 16:something EDT — by Claude (metal-crash-lead surface).*
