# c11 PR Swift poller

Advisory commit status `c11/pr-swift` for open pull requests whose head and base are both `Stage-11-Agentics/c11` (repository id `1212901838`). There is no Actions runner. Fork pull requests are not built. The status is not a required check.

The poller runs as the existing Atlas user, the same trust boundary as `remote-build.sh`. It yields when a `c11-sb-*` guest is running or an Atlas build slot is held, and while a build is running it checks again every 5 seconds. A new guest or the other slot's lock kills that build's process group and posts status `error` with description `yielded to Atlas work`. Pending (`build started`) is posted only after the second revalidation, immediately before exec. It does not reserve memory and it does not change `atlas_build_slots.py` or `remote_build.py`.

**Live on Atlas since 2026-10-10** (Atin's GO-LIVE, gh mode). **Maintenance owner: Atin and the Orchestrator fleet.** Nothing in this tree bootstraps the LaunchAgent; the install below is done by hand. `c11-pr-swift-poller.py supervise` exits 2 unless `state/enabled.json` sets `enabled` to true, and exits 2 when the script sits inside the build worktree.

## Install (Atlas, user atinwoodard)

The layout sits outside any other checkout:

| Path | What |
|---|---|
| `~/c11-poller/bin/` | `c11-pr-swift-poller.py` and `atlas_build_slots.py`, copied byte for byte from `origin/main` |
| `~/c11-poller/worktree/` | the poller's own clone of c11 with `ghostty` and `vendor/bonsplit` initialized; it builds there |
| `~/c11-poller/cache/DerivedData-<key>/` | warm build caches, one per dependency set (see below), at most 3 |
| `~/c11-poller/state/` | `enabled.json`, `stages.json`, `decisions.jsonl`, `events.jsonl`, `supervisor.log`, `results/` |
| `~/.config/c11-pr-swift/credential.json` | `{"mode": "gh", "gh": "/opt/homebrew/bin/gh"}`, mode 600 |
| `~/Library/LaunchAgents/com.stage11.c11-pr-swift-poller.plist` | `render-plist --home ~` output; its PATH puts `/opt/homebrew/bin` first so `tart` and `git` resolve under launchd |

Steps: copy `bin/`, clone the worktree, write `credential.json` and record `gh_configured` in `stages.json`, pre-warm `cache/DerivedData-<key>` for `main`'s key with one `c11-logic` build through `atlas_build_slots.py` (a cold first build would otherwise post a false budget failure; `dependency_key` in the script computes the key), write `enabled.json` with the worktree path, install the plist, record `plist_installed`, then `launchctl bootstrap gui/$(id -u) <plist>`.

## Maintenance

- **Health:** `launchctl print gui/$(id -u)/com.stage11.c11-pr-swift-poller` (state running, `runs` stays 1); `tail ~/c11-poller/state/decisions.jsonl` (one `result` per build, with `build_seconds` and `post_seconds`); `~/c11-poller/state/supervisor.log` for tracebacks.
- **Update after a merge:** copy the two scripts from a fresh `origin/main` into `bin/`, compare SHA-256 against `git show origin/main:<path>`, then `launchctl kickstart -k gui/$(id -u)/com.stage11.c11-pr-swift-poller`. The restart rebuilds its queue from GitHub and skips heads that already carry `success` or `failure`.
- **Disarmed** (`scope-stop`, `stuck`, `unauthorized` in the decisions): the process idles on purpose. Fix the cause (for example `gh auth status` as atinwoodard), then kickstart.
- **Build caches:** DerivedData is keyed by dependency set: `cache/DerivedData-<key>`, where `<key>` is the first 12 hex of SHA-256 over both `Package.resolved` files (the xcodeproj one and the root one) and the `ghostty` and `vendor/bonsplit` gitlinks. One shared DerivedData broke live on 2026-10-10: `main` pins Sparkle 2.9.3 and older heads pin 2.8.1, and Xcode reused a precompiled Sparkle module across them. Before each build the poller marks its key most recent and removes all but the 3 most recently used caches (`cache-pruned` in the decisions). The first build of a new key is cold (about 115 s).
- **`cache: stale module`:** if a build log still says `has been modified since the module file`, the poller posts `error` "cache: stale module" (never `failure`) and does not rebuild that head until a new push or a restart. If that error POST misses all three tries, the poller keeps it as a status-only retry: each cycle reposts the error, never reruns the build, and marks the head reported once a POST is accepted. Delete that key's `cache/DerivedData-<key>` and kickstart if it recurs.
- **`ghosttykit_missing`:** the head's Ghostty commit has no `~/.cache/cmux/ghosttykit/<gitlink>/` entry on Atlas. The poller passes over that head without network calls and builds it once the entry exists; other heads are not held up. When `scripts/ghosttykit-checksums.txt` on `main` pins that gitlink, fetch it with `scripts/download-prebuilt-ghosttykit.sh` (`GHOSTTY_SHA=<gitlink>`, extracted into a staging directory and then moved to `~/.cache/cmux/ghosttykit/<gitlink>/`); otherwise building it is a human or ticket decision.
- **Stop now** (a wrong PR built, a fork touched, a crash loop): `launchctl bootout gui/$(id -u)/com.stage11.c11-pr-swift-poller`, then teardown if it should stay off.

## The service

`supervise` is one long-running process under launchd. It holds `supervisor.lock` for its lifetime and keeps the queue, the rate-limit deadline, the credential client and the heads it has already reported in memory. Between cycles it sleeps until the next allowed poll (25 s, or the full `Retry-After` / reset deadline). On restart it rebuilds that state from the GitHub API: before building a head it reads the commit's combined status, and a head whose `c11/pr-swift` status is already `success` or `failure` is recorded and skipped. `error` (yielded) and `pending` (a crashed attempt) are built again. The only cross-invocation state is R2's `running.lock` and `running.json`. A disarmed supervisor (scope stop, `stuck`, 401) stays alive and idle so KeepAlive does not restart it into polling; a human clears the cause and restarts the service.

Each attempt gets a fresh attempt id. The build runs through `atlas_build_slots.py`; its stdout and stderr go to `state/results/<attempt>-<n>.log` beside the result bundle `state/results/<attempt>-<n>`, and that log decides the result. GhosttyKit is linked from `~/.cache/cmux/ghosttykit/<ghostty gitlink>/` (the commit's `ghostty` gitlink, never the parent SHA).

Layout on Atlas: `~/c11-poller/bin/` holds `c11-pr-swift-poller.py` and `atlas_build_slots.py`, `~/c11-poller/state/` the runtime state, and the build worktree lives elsewhere (`enabled.json` names it).

## Status delivery and budget (Orchestrator ruling)

There is no outbox. Each status POST gets three tries, waiting `Retry-After` when the response gives one and 1 s then 2 s otherwise. If all three fail the poller logs `status_undelivered` and moves on; the head is not marked reported, so the next cycle builds it again and posts a fresh result. The one exception is a stale-module cache fault: its `error` is retried status-only each cycle, without rebuilding (see Maintenance). The budget is classified once, from slot acquisition (the child's `acquired_at` in `running.json`) to the end of the build, across the single cache retry. Posting time is excluded from the 120 s and logged separately as `post_seconds` next to `build_seconds` on the `result` decision.

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

On Atlas: `/usr/bin/python3 ~/c11-poller/bin/c11-pr-swift-poller.py teardown --root ~/c11-poller`, then remove `~/c11-poller/bin`, `~/c11-poller/worktree` and the then-empty `~/c11-poller` by hand (teardown removes only `state/` and `cache/`). Stages recorded on Atlas: `gh_configured`, `plist_installed`.

In gh mode, teardown is the bootout plus removing the poller's `state/` and `cache/` directories (there is no App to uninstall). Every completed teardown removes those two directories last, `stages.json` after everything else; if a removal fails (an absent path counts as removed), teardown prints the error, exits 2 and keeps `stages.json` so it can be run again.

An unknown stage is reconciled by hand and removes nothing.

## App-mode scope

Before any status post, an installation token minted without repository narrowing must see `GET /installation/repositories` return exactly repository id `1212901838`. Anything else stops the poller. Runtime status posts use a token narrowed to that repository only after the check passes. `GET /app/installations/{id}` is not the repository inventory. In App mode a missing key does not fall back to `gh`, `GITHUB_TOKEN`, `~/.netrc`, or `~/.config/gh`; gh mode is chosen only by `credential.json`.

## Budget measurements

**Live, 2026-10-10 (gh mode, `c11-logic` + `HealthFlagsTests`, slot acquisition to build end, 33 tests and `** TEST SUCCEEDED **` each):** cold pre-warm of an empty DerivedData on `main` `e37f51124f`: 115 s (by hand, same argv). First live status: PR #632 at `a932e8226f46`, `success` / `99s`, POST 0.9 s. Warm builds: #632 99 s, #586 102 s, #585 60 s, all under 120 s. The margin is thinnest when consecutive heads sit on different `main` bases (about 100 s); heads close to the last-built tree come in near 60 s.

Before going live, the 120 second budget was measured by hand with `scripts/remote-build.sh`, not by this process. The poller build, once armed, is Debug scheme `c11-logic`, class `HealthFlagsTests`, with both 60 second XCTest allowances. The hand command goes through `scripts/test-unit-local.sh`, whose scheme is `c11-unit`. On 2026-10-09, tag `fu-371r`, after one pre-warm (xcodebuild log 119 s, not a row), the three rows were 24 s (unchanged), 16 s (one line in `HealthFlagsTests.swift`), and 29 s (one line in `ContentView.swift`). Each executed 33 tests and logged `** TEST SUCCEEDED **`. Those spans are the xcodebuild log, after the slot was held. `/usr/bin/time` walls were 35 s, 268 s, and 78 s; the longer walls include waiting for an Atlas slot, which is outside the 120 s. They are a hand-run compile and test portion on that source base (scheme `c11-unit` via `remote-build.sh`), not this unarmed poller's measurement from slot acquisition to build end. At the C11-371 ship head (same command, warm tag, an incremental compile after rebasing on newer `main`), the slot-held span from build log creation to `result.json` was 44 s, with 33 tests and `** TEST SUCCEEDED **`; total wall was 55 s.

## Retention

`state/decisions.jsonl` keeps the last 200 lines. A result directory for an attempt that is no longer queued is eligible for deletion after 7 days. No sweeper is installed.

## Fixtures

`scripts/c11-pr-swift-poller-test.py` runs the real `supervise`, `child` and `teardown` commands. Tools are swapped, not code paths: `C11_POLLER_FAKE_HTTP` points the real `AppClient` (real JWT signing with a disposable key) or `GhClient` (a fake `gh` on PATH) at a file-driven fake GitHub, and `C11_POLLER_GIT`, `C11_POLLER_TART`, `C11_POLLER_ZIG`, `C11_POLLER_XCODEBUILD`, `C11_POLLER_KIT_CACHE`, `C11_POLLER_LAUNCHCTL`, `C11_POLLER_PLIST`, `C11_ATLAS_SLOTS_DIR` and `C11_POLLER_CADENCE_S` name the stand-ins. `supervise --cycles N` stops after N cycles. The LaunchAgent sets none of these.
