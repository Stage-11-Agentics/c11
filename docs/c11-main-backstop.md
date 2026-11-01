# Atlas main-tip backstop

`c11/main-atlas` reports an app build, the full eight-worker logic suite, serial host tests, six built-CLI Python checks and the shell watcher checks. Atlas applies both `all` and `atlas` quarantine rows and records them. Every native suite must execute at least one test. A successful slow run stays successful; build/test failures are `failure`, infrastructure/result-reading faults are `error`, and yields post nothing. An xcodebuild stage (app, logic or host) that fails in under a minute with a linker or CodeSign stale-cache shape logs `stale-cache`, empties that dependency key's DerivedData except `SourcePackages` and reruns the gate once from the app build, with new result bundle paths; the rerun's result is the status. Result bundles are read through the poller's reader: 120 seconds, one retry, then `error` whose `c11/main-atlas` description is the reason (`result unreadable: xcresulttool timed out after 120s 104s`).

GitHub's `CI main (macOS)` remains a separate hourly/dispatch clean-machine check, with its own status and green-record skip. An Atlas pass cannot skip or overwrite that check. Neither lane is a self-hosted Actions runner.

## Deployment gate

C11-466's overnight run authorizes manual dry runs only. Do not install or change any LaunchAgent until the Orchestrator sends `GO-INSTALL C11-466`. The PR poller's installation, credentials and slot script stay untouched by every command below. Maintenance owner: Atin and the Orchestrator fleet.

## Trust and scheduling

The installed controller and its helper copies live outside the build checkout in `~/c11-main-backstop/bin`. Install/update fetch these bytes from the fixed Stage-11-Agentics/c11 main tip and save a SHA-256 manifest. There is no input for a branch, SHA, repository URL or arbitrary build command. The clone fetches only pinned main and the two pinned Stage 11 submodule repositories. A persistent accepted-main SHA detects history rewrites; a non-fast-forward update refuses to build until an operator reconciles that history. Main is resolved after slot admission and revalidated after preparation, immediately before any checkout code runs.

A single supervisor owns the root. It tries the existing poller slot runner with `--poller`, taking slot 1 and its normal high-load guard. Admission is nonblocking: a busy slot returns capacity deferral. Eligible same-repository PR heads without a terminal `c11/pr-swift` status get priority before admission, again in the admitted child, and every 30 seconds during a build. A new PR or sandbox guest terminates the backstop's process tree and releases the slot. Unknown queue state prevents admission. Queue inspection uses GitHub; it never modifies the poller's memory or files. A PR head the poller itself has suppressed for an infrastructure problem can conservatively hold the backstop; health logs make that visible.

Normal main advances leave the current build running. There is no per-push queue: after completion the next admission reads the newest main tip, so intermediate pending pushes are replaced. Completed tips are remembered locally. Failed tips wait for a new tip or `--force`. An interrupted tip stays eligible. The hard attempt limit is 15 minutes including preparation; deadline expiry is a capacity/infrastructure deferral, never a product failure.

## Manual dry run

Copy these files into an isolated scratch `bin` directory on Atlas: `c11-main-backstop.py`, `c11-pr-swift-poller.py`, `host_test_quarantine.py`. Run:

```bash
/usr/bin/python3 ~/c11-466-scratch/bin/c11-main-backstop.py once --root ~/c11-466-scratch --force
```

This executes the real fixed gate but posts **no status**. Exit 0 means success or unchanged; 75 means capacity deferral; 1 means failure/error. Repeat once to measure the warm cache. The installed slot runner is read-only. Dry runs use their own checkout, result directories and dependency-keyed DerivedData. They do not borrow the poller's cache. `state/events.jsonl` includes local timestamps, source SHA, load average, each stage duration and xcresult counts; each `state/results/<attempt>/` retains logs and result bundles. A sandbox guest makes the manual run defer too.

## Install and update (after GO-INSTALL)

Run on Atlas from a trusted clone containing the merged scripts:

```bash
python3 scripts/c11-main-backstop-service.py install --source "$PWD"
python3 ~/c11-main-backstop/bin/c11-main-backstop-service.py health
```

The service uses Atlas's existing `gh` login, as the poller does; it writes no credential file. Its label is `com.stage11.c11-main-backstop`. The plist supplies only the fixed installed supervisor command with `--publish`. Publishing additionally requires the default root and `state/enabled.json`.

Update fetches and verifies all replacement files **before** stopping the independent backstop. Stop bootouts only this label and requires process-tree recovery using the staged new controller. The previous `bin` is retained as `previous`, then the staged directory is renamed into place and the service bootstraps:

```bash
python3 ~/c11-main-backstop/bin/c11-main-backstop-service.py update --source /path/to/trusted/c11
python3 ~/c11-main-backstop/bin/c11-main-backstop-service.py health
```

If recovery refuses because the supervisor is still unwinding, leave it stopped, check the log and repeat the update after recovery; never remove a held lock. A failed bootstrap leaves the verified new files and the previous controller available. Roll back with:

```bash
python3 ~/c11-main-backstop/bin/c11-main-backstop-service.py rollback
```

## Health, stop and teardown

```bash
python3 ~/c11-main-backstop/bin/c11-main-backstop-service.py health
tail -20 ~/c11-main-backstop/state/events.jsonl
tail -40 ~/c11-main-backstop/state/supervisor.log
python3 ~/c11-main-backstop/bin/c11-main-backstop-service.py stop
python3 ~/c11-main-backstop/bin/c11-main-backstop-service.py teardown
```

Health prints the exact service, installed manifest, last completed result and active process record. `stop` retains caches and evidence. `teardown` first stops and verifies recovery, then removes only this service's plist and `~/c11-main-backstop`. It never bootouts the PR poller, removes its files, changes shared slots, or deletes the gh login. Keep evidence externally before teardown. Cache/result retention is operator-managed; stop before pruning this root.

## Acceptance

On Atlas, `python3 scripts/c11-main-backstop-test.py` executes real temporary Git histories, gate subprocesses, private slot contention and process-tree cancellation with fixture tool responses. It does not contact GitHub or use the shared slots. `python3 scripts/c11-main-backstop-mutations.py /path/to/evidence` removes each guarded behavior in a disposable copy, requires each named test to fail, then runs the restored suite. The overnight evidence includes per-guard mutations and the real main-tip warm run; fixtures alone are not a timing claim for the native suite.
