# C11-139: Crash-class stability: session/conversation data loss, main-thread socket freezes, destructive scripts, hot-path races

## Crash-class stability: data loss, main-thread freezes, destructive scripts

Source: `notes/c11-audit-merged-2026-06-09.md` P0.3, P0.4, P0.5, P2.9. Validated against HEAD `b3dfc10bc`. Theme: stop losing user data, stop freezing the app from the socket, and stop SIGKILLing the operator's own processes. The scripts (section C) are the most urgent — they've already destroyed a running tag once.

### A. Session/conversation data loss (P0.3) — 4 live items (1 already fixed)
- **Saves while the launch resume-picker is open clobber `session-*.json`.** While the sheet (`AppDelegate.swift:3354-3372` `LaunchResumePicker.presentSheet`) is open, the live tabManager is empty; the save-skip gate `shouldSkipSessionSaveDuringStartupRestore` (`:4077-4082`) keys on `isApplyingStartupSessionRestore`, set true only *after* the picker resolves (`:3395`). `buildSessionSnapshot` returns a non-nil empty snapshot, and `applicationWillTerminate` (`:2940`) writes it then `promoteToClean`s (`:2943`) — quit-while-deciding permanently destroys the prior session. **Fix:** gate all saves on a picker-open flag until the restore decision resolves.
- **`readConversationsByPanelIdSync` returns `[:]` on its 2s timeout, dropping ALL refs** (`Workspace.swift:416-428`, write `.empty` per panel at `:758`), plus a data race: `nonisolated(unsafe) var captured` (`:421`) is written by the detached Task (`:423`) after the caller reads it (`:427`). **Fix:** on timeout, abort the snapshot / `promoteToClean` instead of persisting `.empty`; synchronize `captured`.
- **`SessionPersistence.load` returns nil on any decode error / version mismatch** (`SessionPersistence.swift:472-480`, `try?`), and the next `save` (`:483-497`, atomic) clobbers the file — no `.corrupt` sidecar, no migration. **Fix:** rename to a `.corrupt` sidecar before allowing the next save.
- **Shutdown write-ordering race:** terminate path writes synchronously (`persistSessionSnapshot` `:4243-4270`, `shouldWriteSessionSnapshotSynchronously` `:4195-4200`) while autosaves run on `sessionPersistenceQueue.async` (`:4268`); `stopSessionAutosaveTimer()` (`:2946`) runs *after* the terminate save, so a queued autosave can still race — last-writer-wins. **Fix:** drain/cancel the persistence queue (barrier sync) before the terminate write.
- **Already fixed by C11-131, do NOT chase:** `markAllUnknown` tombstone-resurrection. The production dirty-sentinel path now calls `reclassifyAfterCrash` (`Store.swift:224-246`), which guards `.alive || .suspended` and leaves `.tombstoned` untouched. `markAllUnknown` survives only on the intentional `app restart --no-resume` path.

### B. Main-thread freezes reachable from the socket (P0.4) — all 4 CONFIRMED
The off-main worker set is tiny (`socketWorkerV2Methods`, `TerminalController.swift:1811-1816`, only 4 `surface.*` methods), so these non-worker handlers run under `DispatchQueue.main.sync` (`:1906`):
- **`pane.confirm` beachballs the whole app:** `v2PaneConfirm` (`:9642`) `assert(!Thread.isMainThread)` (`:9648`) is violated; `semaphore.wait(timeout: 300s)` runs on main. **Fix:** add `pane.confirm` to the off-main worker dispatch set.
- **`feedback.submit` freezes main ~35s then fails:** `v2FeedbackSubmit` (~`:10316-10362`) blocks on `semaphore.wait(timeout: 35)` (`:10357`) while its unstructured `Task` (`:10328`) inherits `@MainActor` and can never start. **Fix:** `Task.detached` or dispatch off-main.
- **Concurrent browser commands wedge a socket thread:** `v2AwaitCallback` (~`:10531-10560`) nested `CFRunLoopRun()` (`:10558`) with `CFRunLoopStop` on a single loop (`:10545/10555`); a concurrent browser eval stops the wrong loop level and deadlocks inside `main.sync`. **Fix:** route browser eval/await off-main (the semaphore branch is correct).
- **Pipe-buffer deadlock in workspace git probes:** `TabManager.runCommandResult` (~`:2020-2079`) waits for process exit (`:2053/2067`) *before* draining pipes (`:2070-2071`); >64KB of `git status` fills the pipe buffer and the no-timeout path wedges forever. **Fix:** drain stdout/stderr concurrently while awaiting exit.

### C. Destructive scripts (P0.5) — all CONFIRMED, URGENT
- `scripts/rebuild.sh:9-10` — `pkill -9 -f "c11"` + `pkill -9 -f "cmux"` SIGKILL the prod app and every agent with `c11`/`cmux` in its command line. Stale cmux-era script. **Delete or guard.**
- `scripts/prune-tags.sh:49` — `running_tags()` sed `s|.*DerivedData/(c11|cmux)-...|` uses `|` as both delimiter and alternation → errors out → returns nothing → running tagged builds are NOT protected (verified live: the weekly launchd agent deleted a running tag). **Fix:** change the sed delimiter (e.g. `s#…#…#`).
- `scripts/smoke-test-ci.sh:25-26` — `pkill -x "c11"` + `pkill -x "cmux"`, no CI guard → kills the operator's prod c11 when run locally. **Fix:** gate on a `$CI` check.

### D. Hot-path data races (P2.9) — both CONFIRMED
- `applyDefaultBackground` (`GhosttyTerminalView.swift:1803`) is called at `:2002` from the Ghostty `GHOSTTY_ACTION_COLOR_CHANGE` callback **without** the `performOnMain {}` wrapper its sibling actions use (`:1987,:2008`), mutating `defaultBackgroundColor`/`Opacity`/`UpdateScope` off-main. **Fix:** wrap the call in `performOnMain {}`.
- `UpdateDriver.lastFeedURLString` (`UpdateDriver.swift:11`) — plain `var` written by Sparkle's `recordFeedURLString` (`:252`) off-main, read by `resolvedFeedURLString`/`formatErrorForLog` with no lock. Low-frequency. **Fix:** lock or confine to main.

### Acceptance
Quit-while-deciding at the resume picker preserves the prior session; a 2s conversation-read timeout does not zero out refs; `pane.confirm`/`feedback.submit`/concurrent `browser.eval` and a >64KB `git status` probe never freeze the app; the three scripts can no longer kill a running prod c11; the two races are wrapped/locked.
