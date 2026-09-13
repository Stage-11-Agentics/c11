# C11-222: browser download wait --path misses files created empty and written in place

## Problem

`v2BrowserDownloadWait` in Sources/SocketHandlers/BrowserQueryHandlers.swift (the `if let path` branch, ~line 792 onward) watches the target's parent directory with a `DispatchSource.makeFileSystemObjectSource` and treats the file as ready only when `pathIsReady()` sees `size > 0`. A file that is created empty and then written in place produces one directory event at create time (size still 0, so not ready) and no further directory event for the data write, because the directory's own vnode does not change when a child's contents change. The wait then runs to its full timeout even though the file appeared and filled.

Atomic-rename writes (`mv` into place, which is what a real WKDownload does) work, which is why the C11-209 validation passed. Pre-existing, unchanged by C11-209, confirmed real by its delegator.

## Fix

When the directory event fires and the file now exists but is not yet ready, open the file itself with `O_EVTONLY` and attach a second `DispatchSourceFileSystemObject` on that fd watching `.write, .extend, .attrib` on the same `watchQueue`, and check `pathIsReady()` from its handler. Also handle the case where the file already exists and is empty at the time of the initial call (attach the file source immediately). Keep the C11-209 invariants exactly: every fd is owned by its source and closed from the cancel handler only, `finishOnce` is the single terminal path, everything that mutates shared state runs on `watchQueue`, and the `v2AwaitCallback` deadline-unwind path cancels every live source. Do not reintroduce any `.main` queue usage in this path and do not widen the timeout cap.

If you find a simpler correct approach (for example, a bounded low-frequency size poll on `watchQueue` as a fallback after the first directory event), that is acceptable if it cannot spin, but the file-level source is preferred.

## Tests

Where a `c11LogicTests` seam is reachable, add one; if the handler is too entangled with `TerminalController` for a unit test, say so plainly rather than writing a fake test. A shell-level validation script (write a file empty, then append bytes 2 s later, and assert `c11 browser download wait --path <p>` returns early) belongs in the PR description as a repro even if it cannot run in CI. Do not run `xcodebuild` locally on this machine (one build per machine rule); CI is the gate.

## Validation

Push, open the PR, watch `gh pr checks`, iterate until green.
