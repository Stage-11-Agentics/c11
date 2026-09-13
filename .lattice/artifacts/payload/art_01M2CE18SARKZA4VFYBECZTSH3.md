# Plan Review: C11-222 — browser download wait --path misses files created empty and written in place

### 1. Verdict

**PASS**

### 2. Summary

Reviewed the plan for C11-222 against the task description and the live handler in `Sources/SocketHandlers/BrowserQueryHandlers.swift:782-915`, plus the delegator's plan comment on the Lattice ticket and the in-progress `DownloadPathWatcher.swift` in the delegator worktree. The plan file on disk is a verbatim copy of the task description and is not a plan; the real plan lives in the delegator's Lattice comment (extract a `DownloadPathWatcher` unit, directory source plus file-level source on the same serial queue, C11-209 invariants preserved, four `c11LogicTests` cases on real temp files, CI as the gate). That plan is technically sound, matches the ticket's preferred approach, and the worktree draft already handles the races a naive implementation would miss. The key concern is test validity: `Data.write(to:)` is atomic by default on Apple platforms, so the "write in place" regression test must be authored with a non-atomic write or it silently exercises the rename path that already worked.

### 3. Issues

**[MAJOR] Plan artifact — The plan file is the task description, not a plan**
`.lattice/plans/task_01M2CDH8T4EP2R7C91EVG0XJGV.md` is a byte-for-byte copy of the ticket description. The actual plan (new file, watcher design, invariants, test matrix, pbxproj wiring) exists only as a Lattice comment. The durable chain is description → plan → diff → review; a future reader or the code reviewer opening the plan file sees no decisions, no file list, no test matrix.
**Recommendation:** Copy the five-point plan from the delegator's comment (ev_01M2CDTKN04NKC0NB5D7F7D7H2) into the plan file, adding the concrete file list: `Sources/SocketHandlers/DownloadPathWatcher.swift` (new, c11 app target), `Sources/SocketHandlers/BrowserQueryHandlers.swift` (modified), `c11Tests/DownloadPathWatcherTests.swift` (new, `c11LogicTests` target only), `GhosttyTabs.xcodeproj/project.pbxproj` (modified). This is a paperwork fix, not a design fix.

**[MAJOR] Tests — The in-place write test must not use an atomic write API**
The whole point of the regression test is a file that is created empty and then grows in place. `Data.write(to:)` and `String.write(to:atomically:true)` write to a temp file and rename over the target. A test written that way passes against the directory-only watcher too, which makes it exactly the fake regression test the ticket forbids. The same applies to the "already-present-empty-then-filled" case.
**Recommendation:** Author the in-place cases with `FileHandle(forWritingAtPath:)` + `seekToEnd` + `write` + `synchronize`, or raw `open(O_WRONLY|O_APPEND)` + `write`. State in the test's doc comment why the atomic API is avoided. For the atomic-rename case, use temp-then-`moveItem` as `MailboxOutboxWatcherTests.writeEnvelopeAtomically` does, so the two paths are visibly distinct.

**[MINOR] Tests — Keep the suite fast; the timeout case needs a sub-second deadline**
`c11LogicTests` is the inner-loop target and CI's `build` gate. The plan's "never-filled times out" case, and the delayed-write cases, must not sleep for seconds. The ticket's shell repro appends after 2 s; the unit test should not copy that.
**Recommendation:** Use a timeout of roughly 0.3 s for the never-filled case and delay writes by roughly 50 to 100 ms in the ready cases, with `XCTestExpectation` ceilings of 1 to 2 s. Total added wall time should stay under about a second.

**[MINOR] Tests — Define the fd-closed assertion seam explicitly**
The plan promises "every opened fd is closed" but does not say how a test observes that. The worktree draft adds `descriptorAccounting()` returning opened and closed descriptor lists, read through `queue.sync`. That is a reasonable seam. Note the cancel handlers run asynchronously on the queue after `cancel()`, so the assertion must wait for the cancel handlers to land, not read immediately after `teardown()` returns.
**Recommendation:** After `teardown()`, either assert inside a short polling loop with a ceiling, or add a test-only hook that fires when both cancel handlers have run. Optionally cross-check with `fcntl(fd, F_GETFD) == -1` and `errno == EBADF` on the recorded descriptors.

**[MINOR] Fix — Extraction must preserve the socket contract byte-for-byte**
The plan says the watch logic moves into a new unit but does not say the handler's observable behaviour stays identical. Three details are easy to drop during extraction: the synchronous fast path that returns `downloaded: true` before any await when the file is already ready; the `internal_error` with `data.path` when the parent directory cannot be opened (map `start()` returning `false` to this); and the `timeout` error's `timeout_ms` plus `requested_timeout_ms` data. `tests_v2/test_browser_api_extended_families.py:251` only asserts `downloaded`, so the socket suite will not catch a dropped error field.
**Recommendation:** Add one line to the plan: "response and error payloads of `browser.download.wait` are unchanged; the handler still calls `teardown()` unconditionally after `v2AwaitCallback` returns, on every exit path."

**[MINOR] Feasibility — pbxproj wiring is by hand; put the test in one target only**
Hand-wiring four pbxproj entries (PBXFileReference, PBXBuildFile, group child, Sources phase) is correct here and avoids the `xcodeproj` gem's whitespace churn. Two footguns from project history: C11-105 came from a test file living in `c11Tests/` on disk but in the wrong target, and the logic target is Strategy B (`BUNDLE_LOADER` on the app dylib), so the watcher source must be in the `c11` app target's Sources phase, not the test target's.
**Recommendation:** Wire `DownloadPathWatcher.swift` into the `c11` target Sources phase and `DownloadPathWatcherTests.swift` into `c11LogicTests` (phase `37DDE3B0A6A70E75A7B2BEDF`) only. Verify with `plutil -lint` and by grepping that each new file id appears in exactly one Sources phase. CI's `build` job is the runtime check.

**[MINOR] Alignment — Delete/rename rebind is beyond the ticket; acceptable but bound it in the writeup**
The plan adds `.delete`/`.rename` to the file mask and rebinds the file source from the cancel handler when the inode is replaced. The ticket did not ask for this. It is cheap and correct (a temp-then-rename over an existing empty file otherwise leaves the file source tracking a dead inode while the directory source still fires, so it would work anyway, but the rebind is cleaner). It cannot spin because every rebind is driven by a kqueue event, not a timer.
**Recommendation:** Keep it, but say in the PR description that it is a robustness addition and why it cannot loop. The `rebindingFileSource` flag must be reset in `terminate` (the draft does this).

### 4. Positive Observations

- **The real plan is well decomposed.** Extracting the watcher into a `TerminalController`-free class is the right move: it makes the ticket's preferred "file-level source" approach unit-testable on real temp files in the fast logic target, which the current inline closure cannot be. This directly answers the ticket's "where a `c11LogicTests` seam is reachable, add one".
- **The worktree draft already closes the races a plan reviewer would normally flag.** Idempotent attach (guard on `fileSource == nil`, so repeated directory events while the file is empty do not leak descriptors), a post-attach re-check for a write landing between `open()` and `resume()`, silent fallback to the directory source when the file open fails, `evaluate()` from the initial `start` body to cover "already exists and empty at call time", and a `[weak self]` cancel handler that closes its descriptor without needing `self`. That is the C11-209 discipline carried forward rather than re-derived.
- **Invariants are restated in the code comment, not just the plan.** The `DownloadPathWatcher` header documents fd ownership, single terminal path, single-writer queue confinement, idempotent teardown, and the "no main queue under an in-progress drain" rule with a pointer to `v2AwaitCallbackPumpingMainRunLoop`. The next person touching this path gets the reasoning inline.
- **Correct read of the build rules.** No local `xcodebuild`, CI as the gate, shell repro in the PR description rather than a fake CI test, and pbxproj edited by hand to avoid gem normalisation churn.
- **Worktree base is current.** The branch sits on a commit that already contains the C11-209 handler rewrite, so there is no risk of re-editing the pre-fix `.main` queue version.
