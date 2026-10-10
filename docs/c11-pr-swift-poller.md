# c11 PR Swift poller

Advisory commit status `c11/pr-swift` for open pull requests whose head and base are both `Stage-11-Agentics/c11` (repository id `1212901838`). There is no Actions runner. Fork pull requests are not built. The status is not a required check.

The poller runs as the existing Atlas user, the same trust boundary as `remote-build.sh`. It yields when a `c11-sb-*` guest is running or an Atlas build slot is held, and while a build is running it checks again every 5 seconds. A new guest or the other slot's lock kills that build's process group and posts status `error` with description `yielded to Atlas work`. Pending (`build started`) is posted only after the second revalidation, immediately before exec. It does not reserve memory and it does not change `atlas_build_slots.py` or `remote_build.py`.

Nothing in this tree bootstraps the LaunchAgent. Arming waits for Atin's GO-LIVE. `c11-pr-swift-poller.py supervise` exits 2 unless `state/enabled.json` sets `enabled` to true, and exits 2 when the script sits inside the build worktree. The LaunchAgent template does not create that file, and this tree does not install it.

## The service

`supervise` is one long-running process under launchd. It holds `supervisor.lock` for its lifetime and keeps the queue, the rate-limit deadline, the credential client and the heads it has already reported in memory. Between cycles it sleeps until the next allowed poll (25 s, or the full `Retry-After` / reset deadline). On restart it rebuilds that state from the GitHub API: before building a head it reads the commit's combined status, and a head whose `c11/pr-swift` status is already `success` or `failure` is recorded and skipped. `error` (yielded) and `pending` (a crashed attempt) are built again. The only cross-invocation state is R2's `running.lock` and `running.json`. A disarmed supervisor (scope stop, `stuck`, 401) stays alive and idle so KeepAlive does not restart it into polling; a human clears the cause and restarts the service.

Each attempt gets a fresh attempt id. The build runs through `atlas_build_slots.py`; its stdout and stderr go to `state/results/<attempt>-<n>.log` beside the result bundle `state/results/<attempt>-<n>`, and that log decides the result. GhosttyKit is linked from `~/.cache/cmux/ghosttykit/<ghostty gitlink>/` (the commit's `ghostty` gitlink, never the parent SHA).

Layout on Atlas: `~/c11-poller/bin/` holds `c11-pr-swift-poller.py` and `atlas_build_slots.py`, `~/c11-poller/state/` the runtime state, and the build worktree lives elsewhere (`enabled.json` names it).

## Status delivery and budget (Orchestrator ruling)

There is no outbox. Each status POST gets three tries, waiting `Retry-After` when the response gives one and 1 s then 2 s otherwise. If all three fail the poller logs `status_undelivered` and moves on; the head is not marked reported, so the next cycle builds it again and posts a fresh result. The budget is classified once, from slot acquisition (the child's `acquired_at` in `running.json`) to the end of the build, across the single cache retry. Posting time is excluded from the 120 s and logged separately as `post_seconds` next to `build_seconds` on the `result` decision.

## Recovery

`running.lock` is held by the build process and inherited across `exec`. A free lock is not proof the build is gone: a descendant started with `close_fds=True` drops the fd and keeps the process group. On startup, and before every start, the supervisor probes the recorded pgid with `killpg(pgid, 0)`. If the group exists it sends TERM, then KILL after 10 seconds, and it does not clear `running.json` or admit a build until the probe returns ESRCH. If the group is still there after 60 seconds, or the lock is held and there is no pgid, it logs `stuck` and does not poll.

## Credentials

**gh mode is the active credential** (Atin's decision): the poller posts with the GitHub login Atlas already has (`gh` as BenevolentFutures, `~/.config/gh/hosts.yml`). That token is already readable by every build on Atlas, so an App adds no protection on this host; it would only narrow the poller's own identity. `~/.config/c11-pr-swift/credential.json` containing `{"mode": "gh"}` (optionally `"gh": "<path>"`; otherwise `gh` on PATH, then `/opt/homebrew/bin/gh`, since launchd's PATH has no Homebrew) selects it. Each request runs `gh auth token --hostname github.com` with `GH_TOKEN` and `GITHUB_TOKEN` removed from its environment, uses the token as the Bearer for that request only, and never logs or writes it. Scope: `GET /repos/Stage-11-Agentics/c11` must return id `1212901838`, that full name, and `permissions.push` true, or the poller disarms. If `gh` cannot produce a token, that outcome is kept apart from "missing", "revoked" and "no status": before a build the cycle starts nothing and logs `credential-unavailable` (the head stays queued and is retried after the cadence); while a build runs the check counts as unknown, so the build continues and the next 5 s tick checks again; in the build child it is a refusal before pending (exit 3), so nothing is posted. The same calls, admission, status context and rate-limit handling apply in both modes (a gh token gets 5000 requests an hour).

**GitHub App mode is the upgrade path** and needs only config: place `app.json` (`app_id`, `installation_id`) and `private-key.pem` in `~/.config/c11-pr-swift/`. When `app.json` exists it wins over `credential.json`. The App-mode scope check and key rotation are below.

## App key rotation (by hand)

No automated rotation. The previous key stays on disk until it has been shown to fail.

1. Generate a new key in the App settings.
2. Write it as `private-key.pem.new` (mode 600).
3. Verify it authenticates (`GET /app`).
4. `mv private-key.pem private-key.pem.old`, then `mv .new` into place.
5. Delete the old key in the App UI.
6. Verify the old key fails `GET /app`.
7. Delete `.old`.

`rotate_swap` performs steps 3 and 4 and refuses to move the live key until the new file authenticates. `rotate_drop_old` performs step 7 and refuses while the old file still authenticates.

## Teardown

`stages.json` lists what was done (`plist_installed`, `gh_configured`, and in App mode `app_installed`, `key_placed`). Teardown removes local state for every recorded stage, in order, and exits 2 at the first check that fails.

- `plist_installed`: `launchctl bootout`, then the plist is removed only when `launchctl print` no longer finds the service, the group recorded in `running.json` is ESRCH, and no process holds `supervisor.lock`.
- `app_installed`: `DELETE /app/installations/{id}` with the App JWT, then the authenticated absence check: `GET /app` must return this App's id (the key still works), and `GET /app/installations` must not list the installation. A rejected key is not absence.
- `key_placed`: the key is destroyed only after the checks above pass.
- `gh_configured`: removes the poller's `credential.json`. The gh login itself is not touched.

In gh mode, teardown is the bootout plus removing the poller's `state/` and `cache/` directories (there is no App to uninstall). Every completed teardown removes those two directories last, `stages.json` after everything else; if a removal fails (an absent path counts as removed), teardown prints the error, exits 2 and keeps `stages.json` so it can be run again.

An unknown stage is reconciled by hand and removes nothing.

## App-mode scope

Before any status post, an installation token minted without repository narrowing must see `GET /installation/repositories` return exactly repository id `1212901838`. Anything else stops the poller. Runtime status posts use a token narrowed to that repository only after the check passes. `GET /app/installations/{id}` is not the repository inventory. In App mode a missing key does not fall back to `gh`, `GITHUB_TOKEN`, `~/.netrc`, or `~/.config/gh`; gh mode is chosen only by `credential.json`.

## Budget measurements

Until GO-LIVE, the 120 second budget is measured by hand with `scripts/remote-build.sh`, not by this process. The poller build, once armed, is Debug scheme `c11-logic`, class `HealthFlagsTests`, with both 60 second XCTest allowances. The hand command goes through `scripts/test-unit-local.sh`, whose scheme is `c11-unit`. On 2026-10-09, tag `fu-371r`, after one pre-warm (xcodebuild log 119 s, not a row), the three rows were 24 s (unchanged), 16 s (one line in `HealthFlagsTests.swift`), and 29 s (one line in `ContentView.swift`). Each executed 33 tests and logged `** TEST SUCCEEDED **`. Those spans are the xcodebuild log, after the slot was held. `/usr/bin/time` walls were 35 s, 268 s, and 78 s; the longer walls include waiting for an Atlas slot, which is outside the 120 s. They are a hand-run compile and test portion on that source base (scheme `c11-unit` via `remote-build.sh`), not this unarmed poller's measurement from slot acquisition to build end. At the C11-371 ship head (same command, warm tag, an incremental compile after rebasing on newer `main`), the slot-held span from build log creation to `result.json` was 44 s, with 33 tests and `** TEST SUCCEEDED **`; total wall was 55 s.

## Retention

`state/decisions.jsonl` keeps the last 200 lines. A result directory for an attempt that is no longer queued is eligible for deletion after 7 days. No sweeper is installed.

## Fixtures

`scripts/c11-pr-swift-poller-test.py` runs the real `supervise`, `child` and `teardown` commands. Tools are swapped, not code paths: `C11_POLLER_FAKE_HTTP` points the real `AppClient` (real JWT signing with a disposable key) or `GhClient` (a fake `gh` on PATH) at a file-driven fake GitHub, and `C11_POLLER_GIT`, `C11_POLLER_TART`, `C11_POLLER_ZIG`, `C11_POLLER_XCODEBUILD`, `C11_POLLER_KIT_CACHE`, `C11_POLLER_LAUNCHCTL`, `C11_POLLER_PLIST`, `C11_ATLAS_SLOTS_DIR` and `C11_POLLER_CADENCE_S` name the stand-ins. `supervise --cycles N` stops after N cycles. The LaunchAgent sets none of these.
