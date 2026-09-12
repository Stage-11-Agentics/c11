C11-212 validation — PASS

Exact parent head: face08225e4bf930140c412a799f49927069d947
Ghostty fork SHA: d4431f804d5ef1ee350898742fabc0d40e86c7ca
Generated GhosttyKit SHA256: e96d70a22ac62fa6d52e2996ada20a06acaa2b21e5af18a0726428714162e9d1

Build/launch commands:
- C11_QA_LAUNCH=fresh ./scripts/reload.sh --tag c11-212
- ./scripts/launch-tagged-automation.sh c11-212 --qa fresh --env MallocStackLogging=1
- C11_SOCKET_PATH=/tmp/c11-debug-c11-212.sock c11 read-screen --workspace workspace:1 --surface surface:2 --scrollback
- /usr/bin/malloc_history "$PID" -q -allBySize (filtered to stacks containing readTerminalTextBase64 and heap.CAllocator.alloc)

Matched workload in both builds:
- 3,000 real scrollback lines, each generated with jot -w 'C11-212-{BASE|AFTER}-%04d-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX' 3000 1
- 50 full-scrollback read-screen requests against workspace:1/surface:2

Before (old 7604624d8 framework symlink):
- pre-snapshot after 4 reads: 12 target-stack blocks / 2,102,272 bytes
- post-snapshot after 50 additional reads: 162 target-stack blocks / 28,380,672 bytes
- delta: 150 blocks / 26,278,400 bytes = 3 blocks and 525,568 bytes retained per request

After (downloaded xcframework-d4431f804... after unlinking, not writing through, the old framework symlink):
- pre-snapshot: 0 target-stack blocks / 0 bytes
- post-snapshot after 50 identical reads: 0 target-stack blocks / 0 bytes
- delta: 0 blocks / 0 bytes = 0 retained blocks and bytes per request

Functional/double-free guard:
- read-screen returned the expected visible line and the 3,000th seeded scrollback line.
- The same fixed export is the shared free routine for read_text and read_selection: ghostty_surface_free_text(_: *Surface, ptr: *Text) -> ptr.deinit(). Per Orchestrator ruling, the 50 fixed-build read_text repetitions with zero retained target allocations, a live tagged process, and no malloc/double-free/corruption/crash diagnostics cover the section 4.3 double-free guard.
- Mouse-selection drive was attempted only against the tagged window but was not achievable reliably in the headless environment. A fresh isolated computer-use validator was given a bounded final attempt; if unsuccessful, this is recorded as: selection path validated by shared free routine + read_text repetitions; mouse-selection drive not achievable headlessly.
- Fresh-validator evidence: it resolved tagged PID 24189 and CGWindowID 473 (Workspace 1, 1120x840), captured /tmp/c11-212-selection-before.png, and confirmed System Events exposed neither an AX window nor menu bar for that exact PID (Invalid index -1719). It sent no pointer/keyboard input, never activated the app, and never mutated the clipboard. Full report: /tmp/c11-212-selection-validator-result.md.
- Exact-window screenshot showing the tagged DEV marker and readable panes: /tmp/c11-212-after.png
- Tagged PID 24189 remained alive after the repeated reads. Unified-log scan showed only MallocStackLogging startup notices, with no malloc error, double free, corruption, abort, or crash diagnostic.

Bounded ABI audit:
- Parsed matching ghostty.h prototypes and embedded.zig exports.
- 70 matching header/export pairs compared; 0 parameter-count mismatches.
- Informational inventory: 89 header names, 72 embedded exports, 19 header-only, 2 export-only.
- No follow-up ticket is required.

Deviation notes:
- The first tagged build accidentally propagated MallocStackLogging into build subprocesses and stalled; it was interrupted and rerun normally. MallocStackLogging was enabled only for both measurement launches.
- git fetch/pull used --no-tags because an unrelated nightly tag conflicts locally.