# c11 PR Swift poller

Advisory commit status `c11/pr-swift` for open pull requests whose head and base are both `Stage-11-Agentics/c11` (repository id `1212901838`). There is no Actions runner. Fork pull requests are not built. The status is not a required check.

The poller runs as the existing Atlas user, the same trust boundary as `remote-build.sh`. It yields when a `c11-sb-*` guest is running or an Atlas build slot is held, and while a build is running it checks again every 5 seconds. A new guest or the other slot's lock kills that build's process group and posts status `error` with description `yielded to Atlas work`. Pending (`build started`) is posted only after the second revalidation, immediately before exec. It does not reserve memory and it does not change `atlas_build_slots.py` or `remote_build.py`.

Nothing in this tree bootstraps the LaunchAgent. Arming waits for an implementation review PASS and for Atin to create the GitHub App. `c11-pr-swift-poller.py supervise` runs one cycle only when `state/enabled.json` sets `enabled` to true. The LaunchAgent template does not create that file, and this tree does not install it.

## Recovery

`running.lock` is held by the build process and inherited across `exec`. A free lock is not proof the build is gone: a descendant started with `close_fds=True` drops the fd and keeps the process group. On startup, and before every start, the supervisor probes the recorded pgid with `killpg(pgid, 0)`. If the group exists it sends TERM, then KILL after 10 seconds, and it does not clear `running.json` or admit a build until the probe returns ESRCH. If the group is still there after 60 seconds, or the lock is held and there is no pgid, it logs `stuck` and does not poll.

## Key rotation (by hand)

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

`stages.json` lists what was done (`plist_installed`, `app_installed`, `key_placed`). Teardown removes local state for every recorded stage. It uninstalls the App and does the authenticated absence check only if `app_installed` is recorded, and it destroys the key only after that check succeeds. An unknown stage is reconciled by hand and removes nothing.

## Scope

Before any status post, an installation token minted without repository narrowing must see `GET /installation/repositories` return exactly repository id `1212901838`. Anything else stops the poller. Runtime status posts use a token narrowed to that repository only after the check passes. `GET /app/installations/{id}` is not the repository inventory. A missing key does not fall back to `gh`, `GITHUB_TOKEN`, `~/.netrc`, or `~/.config/gh`.

## Budget measurements

Before the App exists, the 120 second budget is measured by hand with `scripts/remote-build.sh`, not by this process. The poller build, once armed, is Debug scheme `c11-logic`, class `HealthFlagsTests`, with both 60 second XCTest allowances. The hand command goes through `scripts/test-unit-local.sh`, whose scheme is `c11-unit`. On 2026-10-09, tag `fu-371r`, after one pre-warm (xcodebuild log 119 s, not a row), the three rows were 24 s (unchanged), 16 s (one line in `HealthFlagsTests.swift`), and 29 s (one line in `ContentView.swift`). Each executed 33 tests and logged `** TEST SUCCEEDED **`. Those spans are the xcodebuild log, after the slot was held. `/usr/bin/time` walls were 35 s, 268 s, and 78 s; the longer walls include waiting for an Atlas slot, which is outside the 120 s. They are a hand-run compile and test portion on that source base (scheme `c11-unit` via `remote-build.sh`), not this unarmed poller's measurement from slot acquisition through the status POST.

## Retention

`state/decisions.jsonl` keeps the last 200 lines. A result directory for an attempt that is no longer queued is eligible for deletion after 7 days. No sweeper is installed.
