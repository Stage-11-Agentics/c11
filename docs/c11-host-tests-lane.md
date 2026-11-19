# Host-app test lane (`c11Tests` after merges)

The host-app suite (`c11Tests`, scheme `c11-unit`) needs a running app, and no app runs on the build host or the laptop. This lane runs the full suite on `main`'s tip in a disposable sandbox guest after merges. It is never a merge gate: it posts no GitHub status, and a red run reaches the Lattice board.

## What a run does

`scripts/c11-host-tests.py run` runs on the build host as its existing user, from a staged SHA-verified copy at `~/c11-host-tests/bin/c11-host-tests.py`, under the LaunchAgent `com.stage11.c11-host-tests` (`StartInterval` 1800 s).

1. **Pick the tip.** Fetch `main` into its own clone (`~/c11-host-tests/worktree`). Skip when the tip already has a terminal result, when only docs changed since the last tested tip (`docs/`, `notes/` and top-level Markdown; Markdown under `c11Tests/`, `skills/` or `Resources/` reaches the app or its fixtures and counts as code; recorded as `skipped-docs`), or after three infrastructure errors at one tip (until a new tip or `--force`). Intermediate tips coalesce into the newest. A lock in `~/.c11-sandbox` keeps lane runs on one Tart host from overlapping, whatever their root, and a run starts by deleting the guests that killed runs recorded (below). Every board report that did not land (Lattice unreachable or timing out) is retried, oldest first, on the next wake; a newer result never hides an older undelivered one.
2. **Build.** `xcodebuild build-for-testing -scheme c11-unit` with Xcode 26.3, GhosttyKit from the SHA-keyed cache, through the tested checkout's own `scripts/atlas_build_slots.py` (a shared fleet lane; never an older installed copy). Slot admission waits at most 20 minutes, then the run defers. DerivedData is per dependency set under `cache/`, at most two kept. 30 minutes after slot admission. A build failure is red only when the log shows the code's own errors: compiler `file:line:col: error:` diagnostics, `Undefined symbols for architecture`, `ld: error` or `ld: symbol`, or `Multiple commands produce`; any other build exit is an infrastructure error.
3. **Wait for a free guest.** Only when no Tart VM is running, nothing under `~/.c11-sandbox/runs` changed in the last 10 minutes (an owner between `sandbox-down` and `sandbox-up`), one-minute load is under 40 and 45 GiB are free. A built run waits up to 15 minutes, then defers to the next wake.
4. **Guest.** First the run records the guest as its own in `~/.c11-sandbox/host-tests/owned/<vm>.json` (VM, root, PID, run), then, under `sandbox-up.sh`'s clone lock, clones `c11-sandbox-golden` as `c11-ht-<run>` (4 CPU, 8 GB), boot headless, tar the build host's `Xcode-26.3.app` and `Build/Products` (without dSYMs) into it, accept the license and run `xcodebuild -runFirstLaunch` inside the clone only, then `xcodebuild test-without-building -only-testing:c11Tests` in the guest's Aqua session, serial, 60-second per-test allowance, skipping every `all` row of `scripts/host-test-quarantine.tsv` (the guest is a clean machine, so `remote` rows run). The result bundle comes back by tar and is read with `xcresulttool` (120 s, one retry); a passing summary with a nonzero xcodebuild exit is an infrastructure error. Every phase starts only while the 25-minute guest deadline has time left and gets at most what is left, so no copy or test invocation begins after it. The clone is stopped without a graceful shutdown and deleted on every exit path. The golden image is only ever cloned. A lane guest holds the first golden's serial, so `sandbox-up.sh --allow-second` and `c11-guest-image.sh build a` treat it as using that slot.
5. **Record and report.** The outcome is written before any board call, so a Lattice fault can delay a report but never change or lose it. One JSONL row per run in `records/runs.jsonl`: tip, state, local timestamps, slot wait, build, guest wait, boot, copy, first-launch, test and teardown seconds, counts, failing tests with their first failure text, quarantine skips; each delivery attempt is its own `board_for` row. Failed runs keep their logs and result bundle under `results/<run>/` for 14 days.

The guest phase has a 25-minute ceiling and the whole run 90 minutes; the run ceiling is the sum of slot admission (20 min), build (30), guest wait (15) and guest phase (25), and the first two waits hold no guest. A timeout kills only the run's own process group, deletes only its own `c11-ht-*` VM, and is an infrastructure error, never a product failure. SIGTERM (an operator's `stop` or a `launchctl bootout`, which waits up to the plist's 120 s `ExitTimeOut`) records `stopped`, which counts toward nothing.

## Ownership

The lane deletes, stops or kills only what it recorded as its own: a VM listed in `host-tests/owned/`, and the process groups it started. A `c11-ht-` name alone is never authority, for the lane or for `sandbox-up.sh`. The record holds the lane's PID and the PID of the `tart` process that may be creating or starting the VM right now, each bound to that process's identity: its start time (`ps -o lstart`) and exact command line (`ps -o command`), and for the producer a command line that names the tart verb and the VM. A PID is signalled only while both still match; a gone, reused or unrecorded PID never authorizes a signal and only marks the claim stale. Every such producer starts under one lock that also decides yields, so none starts after a yield; a claim is released only after every producer has been stopped and reaped and the VM is gone. A claim's lane counts as alive only while that identity still matches, so a reused PID never holds anything up, and `sandbox-up.sh` never acts on a claim for anything but a `c11-ht-*` guest that is not a golden or an image. `stop --root R` signals R's own run (from `state/run.json`) and deletes only guests recorded under R whose run process is gone; a run's start sweeps only records whose process is gone.

## Owners come first

A lane guest is named `c11-ht-*`, outside `c11-sb-*`, so the PR poller and the main backstop never yield to it. An owner's `scripts/sandbox-up.sh` preempts the lane within one wall-clock deadline of 30 s (`C11_SANDBOX_LANE_YIELD_S`) from its first request, covering lock admission, the lane's own cleanup and forced cleanup:

- it writes `~/.c11-sandbox/lane-yield/<vm>` for every recorded lane guest, including one still waiting for or holding `clone.lock`; the lane watches for that from the moment it records the guest, stops and reaps its own in-flight `tart` producer, deletes its VM and then releases the claim;
- takeover starts with a quarter of the budget (at least 2.5 s) still left, and forced cleanup must end one second before the deadline so the owner's own clone lands inside it;
- takeover kills the recorded lane process and its recorded producer (each only while its recorded identity still matches) and waits until they are gone, then stops and deletes the VM, drops the claim once the VM is gone, and only then moves `clone.lock` to the owner, removing it only if it is still the lane's lock as recorded when takeover began, so two owners never take it from each other (the lane never removes a lock it no longer owns);
- every forced `tart` call is bounded by the time left; once it is spent, no step runs.

Measured with stand-ins and a frozen lane: request to owner clone 5.2 s at a 6 s budget and 28.9 s at the 30 s default.

The lane records that run as `yielded` and tries the same tip on a later wake. One guest at a time still holds.

## The board

Board writes go through `lattice` in `~/c11-host-tests/board` (a directory attached to `stage11/c11h`) as `agent:c11-host-tests`, with the lane's own token: the LaunchAgent sets `C11_HOST_TESTS_LATTICE` to `bin/lattice-lane`, a wrapper that loads `LATTICE_REMOTE_STAGE11_TOKEN` from `~/.config/stage11/c11-host-tests.env` (0600) for that one process. The build host's shared `~/.config/lattice/remotes.json`, which every other seat there uses, is never touched.

| Run | Board |
|---|---|
| failure (build or tests) | create a bug tagged `host-tests-red` ("c11Tests red on main <sha>") with build and test seconds, each failing test with the first line of its failure text (up to 200 characters; past 40 failures, "and N more (see evidence)"), counts and the evidence path; if one is open, comment on it instead |
| first success after red | one comment on the open `host-tests-red` ticket; whoever owns it closes it |
| infrastructure error | every third error in a row, counted across tips (so a lane failing at every new tip is not silent), on a `host-tests-infra` ticket with the log tail |
| success, yielded, deferred, skipped | nothing |

`--dry-run` records the action it would take and writes nothing to the board. Dry-run rows never mark a tip tested or count toward the infrastructure cap.

## Timing

Measured on the first proof (main `fef42002`, 2026-11-15 01:31, one-minute load 3.9): slot wait 0.5 s; build-for-testing 9 s warm (141 s into a fresh DerivedData); guest boot 13 s; copy 178 s (Xcode 3.7 GB, products, source mirror); Xcode first-launch 6 s; `test-without-building` 371 s for 1963 tests; teardown 3.5 s. A guest is held about 10 minutes and a warm run takes about 10 minutes end to end. The copy is the one large fixed cost; a derived guest image with Xcode preinstalled would remove most of it.

Tests find fixtures through their compile-time source paths, so the guest also gets the checkout (without Git data or Zig caches, about 250 MB) at the same absolute path the build used.

## Install (after merge and the Orchestrator's GO-INSTALL)

On the build host, as its user:

```sh
mkdir -p "$HOME/c11-host-tests/bin" "$HOME/c11-host-tests/logs" "$HOME/c11-host-tests/board" "$HOME/Library/LaunchAgents"
git clone --no-tags https://github.com/Stage-11-Agentics/c11h.git "$HOME/c11-host-tests/worktree"
W="$HOME/c11-host-tests/worktree"
git -C "$W" show origin/main:scripts/c11-host-tests.py > "$HOME/c11-host-tests/bin/.c11-host-tests.py.new"
test "$(git -C "$W" show origin/main:scripts/c11-host-tests.py | shasum -a 256 | awk '{print $1}')" = \
     "$(shasum -a 256 "$HOME/c11-host-tests/bin/.c11-host-tests.py.new" | awk '{print $1}')"
chmod 700 "$HOME/c11-host-tests/bin/.c11-host-tests.py.new"
/bin/mv -f "$HOME/c11-host-tests/bin/.c11-host-tests.py.new" "$HOME/c11-host-tests/bin/c11-host-tests.py"
cat > "$HOME/c11-host-tests/bin/lattice-lane" <<'WRAPPER'
#!/bin/sh
# The lane's own board token, for this process only; never the shared remotes.json.
set -a
. "$HOME/.config/stage11/c11-host-tests.env"
set +a
exec "$HOME/.local/bin/lattice" "$@"
WRAPPER
chmod 700 "$HOME/c11-host-tests/bin/lattice-lane"
(cd "$HOME/c11-host-tests/board" && git init -q . && "$HOME/c11-host-tests/bin/lattice-lane" remote attach stage11 c11h)
sed "s|@HOME@|$HOME|g" "$W/scripts/launchd/com.stage11.c11-host-tests.plist.in" \
  > "$HOME/Library/LaunchAgents/com.stage11.c11-host-tests.plist"
plutil -lint "$HOME/Library/LaunchAgents/com.stage11.c11-host-tests.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.stage11.c11-host-tests.plist"
launchctl kickstart "gui/$(id -u)/com.stage11.c11-host-tests"
```

Before installing, mint the lane's token on the build host (`lattice server token create --user human:atin --machine atlas-host-tests --actor agent:c11-host-tests --project c11h --json`, per `platform/lattice-hosted.md`) straight into `~/.config/stage11/c11-host-tests.env` (0600) as `LATTICE_REMOTE_STAGE11_TOKEN=<token>`, never printing it. Update: stage and verify the new script the same way, `launchctl bootout`, run `stop` (below), replace `bin/c11-host-tests.py`, bootstrap. Never point the LaunchAgent at the worktree copy.

## Check, run, stop, remove

```sh
/usr/bin/python3 "$HOME/c11-host-tests/bin/c11-host-tests.py" health --root "$HOME/c11-host-tests"
tail -n 3 "$HOME/c11-host-tests/records/runs.jsonl"
tail -n 40 "$HOME/c11-host-tests/logs/launchd.err"
/usr/bin/python3 "$HOME/c11-host-tests/bin/c11-host-tests.py" run --root "$HOME/c11-host-tests" --ref main [--force] [--dry-run]
launchctl bootout "gui/$(id -u)/com.stage11.c11-host-tests"
/usr/bin/python3 "$HOME/c11-host-tests/bin/c11-host-tests.py" stop --root "$HOME/c11-host-tests"
/bin/rm -f "$HOME/Library/LaunchAgents/com.stage11.c11-host-tests.plist"
/bin/rm -rf "$HOME/c11-host-tests"
```

`health` prints the service state, the last event (deferrals, prepare failures, orphan deletions), the installed and `main` script SHA-256 (they must match), the active run, any live `c11-ht-*` guest and the last run. `stop` sends TERM to this root's recorded run (only while its recorded start time and command line still match) (whose handler kills its build and deletes its guest), then deletes only guests recorded under this root whose run is gone; another root's live guest is never touched. Removal never touches the PR poller, the main backstop, the perf lane, the goldens or the build slots.

## Tests

`python3 scripts/c11-host-tests-test.py` covers the tip, guest-gate, board and yield decisions with stand-in `tart` and `lattice`. `python3 tests/test_sandbox_lane_preempt.py` runs the real `sandbox-up.sh` against a stand-in `tart` and fails without the preemption.
