---
name: c11-hotload
description: "Hot-reload workflow for c11 development: initial setup, tagged Debug builds via reload.sh, Release variants, the debug event log, and the tagged-build reporting format. Use when building, rebuilding, or launching c11 during development."
---

# c11 hotload

How to build, reload, and tail a c11 dev instance.

## Default: build on Atlas

From a provisioned delegator worktree on the laptop:

```bash
./scripts/remote-build.sh --tag <your-branch-slug>
```

This runs no local xcodebuild. It bundles the exact parent/submodule commits, overlays tracked modifications and untracked non-ignored files with content hashes, and retrieves the tagged Debug app plus logs and `result.json` under `build-remote/<invocation>/`. Tracked deletions, executable modes and symlinks are preserved. Dirty submodules are refused: commit and pin their changes first. Initialize the required submodules with `git submodule update --init --recursive ghostty vendor/bonsplit`; do not run `setup.sh` on the laptop to build GhosttyKit.

Atlas uses process-scoped Xcode 26.3 (`/Applications/Xcode-26.3.app/Contents/Developer`) and Zig 0.15.2 (`~/zig-0.15.2`). `C11_REMOTE_HOST` defaults to `atlas`; `--host` overrides it. `C11_REMOTE_DEVELOPER_DIR` and `C11_REMOTE_ZIG_DIR` override paths but the versions are checked. No global Xcode selection or credential provisioning happens.

The Atlas route admits at most two builds with separate per-tag caches. After one-minute load stays above 40 for 60 seconds it admits only one until load returns to 40 or below. Active builds finish. Same-tag requests serialize. The ordinary laptop `with-build-lock.sh` remains single-slot. Atlas builds outside this route must be coordinated with its capacity.

GitHub's scheduled native CI uses GitHub-hosted `macos-15` and
`macos-15-xlarge` runners. PRs keep the cheap Ubuntu lane;
`ci-hourly.yml`, `ci-macos-compat.yml`, and `build-ghosttykit.yml` run
hourly/manual against main. Each heavy workflow command uses
`scripts/with-build-lock.sh`; the process-scoped Xcode/Zig setup does not install
into `/usr/local` or change global Xcode state. No self-hosted runner is
registered or used in this PR. An access-restricted runner is a follow-up that
requires Atin to decide the repository, trigger, and network boundary.

For landing, the Merge Captain gates the exact PR head with fresh review, the
cheap PR checks, and an Atlas exact-head remote build for every Swift or native
change after the branch includes current `origin/main`. A docs-only change is
exempt only when the diff is limited to documentation or prose and contains no
Swift, native workflow, script, project, submodule, test, or build-input change.
The hourly main result is the post-merge authority; red main is fixed forward.
For Ghostty pointer changes, manually dispatch `Build GhosttyKit` on the
internal bump branch, wait for its prerelease non-`latest` artifact and bot
checksum commit, refresh PR checks at that bot-created head, then run the
exact-head Atlas gate before landing. The workflow keys on the ghostty SHA, so a
Bonsplit-only pointer bump needs no dispatch.

Remote failure returns nonzero, retrieves available logs, and preserves the previous local app without launching it. The default stages only; it never launches or restarts c11. Successful Debug retrieval rewrites only the app's host-specific daemon/repository paths and ad-hoc signs it; result.json records both Atlas and client executable hashes. Launch with QA startup dialogs suppressed only when a launch is authorized:

```bash
./scripts/launch-tagged-automation.sh <tag> --qa fresh
# Equivalent convenience on an authorized client:
./scripts/remote-build.sh --tag <tag> --launch
```

In the c11 1.0 run, packaged-app validation and computer use run on Atlas only. The laptop receives the app but does not launch it. On Atlas, launch the retained tagged app using its source checkout's `launch-tagged-automation.sh`. Never launch an untagged c11 DEV app.

Live proofs that need real agent panels (Claude Code, Codex, Grok receiving mail or running hooks) run in an Atlas sandbox guest: `scripts/sandbox-up.sh <run-id> <tagged.app> --agents claude,codex,grok`, then `scripts/sandbox-agent.sh <run-id> launch|c11|screen …`, then `sandbox-down` and `sandbox-agent.sh <run-id> verify-clean`. The retained Atlas copy of a remote build is under `~/c11-builds/<tag>/artifacts/<invocation>/`; running the sandbox scripts on Atlas with `C11_SANDBOX_HOST=local` against it skips the upload from the laptop. Details: the `c11-computer-use` skill.

## Remote variants

| Command | Result |
|---|---|
| `./scripts/remote-build.sh --tag <tag>` | Tagged Debug app, logs, source identity; no launch |
| `./scripts/remote-build.sh --tag <tag> --mode test -- -only-testing:c11LogicTests/<Class>` | Actual test action on Atlas; assertion results separate from compilation |
| `./scripts/remote-build.sh --tag <tag> --mode release` | Ad-hoc staging Release app; no publish or launch |
| `./scripts/remote-build.sh --tag <tag> --mode release --wmo --universal` | Release staging with production compilation settings |

Test selection uses the safe per-PID socket wrapper. Pass `-resultBundlePath <relative-path>.xcresult` to retrieve an xcresult. Signing/notarization for publication remains in GitHub Actions, with named approval of exact signed bytes; this route does not copy credentials.

## Existing on-Atlas entry points

A person working on Atlas may use `./scripts/reload.sh --tag <tag>` to build and launch Debug, or `./scripts/reloads.sh --tag <tag>` for staging. For coordinated builds prefer the remote route, including from an SSH client. Both scripts support `--no-launch` to stage and sign without CLI-shim/socket writes, quits or launches. Their default remains launch. Never run `reloadp.sh` over another agent's session: it terminates the running production app.

A clean quit preserves agent resume; do not pre-kill the app before a reload. Use QA fresh/resume deliberately for validation.

## Driving a Release/staging build over the socket

A Release/staging build launched by `reloads.sh` binds its **own** socket in automation mode, so a CLI in another local shell can write to it when pointed at `C11_SOCKET_PATH=/tmp/c11-<slug>.sock`, where the slug is the tag lowercased with every non-alphanumeric run collapsed to a hyphen (`--tag rel-v0.65.2` binds `/tmp/c11-rel-v0-65-2.sock`; the script prints the exact path at launch). The script also clears the launching panel's inherited c11 identity before opening the app. For socket-level validation during development, a tagged **Debug** build uses the same externally reachable automation mode via `C11_SOCKET=/tmp/c11-debug-<tag>.sock`.

## QA / automation launch (suppress the startup dialogs)

A normal launch can present two blocking dialogs before the GUI is usable: the **Agent Skills** install/update sheet and the **"Resume previous session?"** picker. For automated QA they're just modals in the way. The `C11_QA_LAUNCH` env var suppresses **both** and makes the resume decision deterministic:

| `C11_QA_LAUNCH` | Skill sheet | Resume picker | Session |
|---|---|---|---|
| `fresh` (or any non-`resume` value) | suppressed | suppressed | clean slate, no restore |
| `resume` | suppressed | suppressed | silently restores the prior session |
| unset / empty | may show | may show | normal interactive launch |

It's read fresh each launch and never persisted, so it can't leak into a later non-QA run. Default is **fresh** — automation usually wants a known-empty start; `resume` is the deliberate opt-in.

```bash
# Tagged automation launcher — dedicated flag:
./scripts/launch-tagged-automation.sh <tag> --qa           # fresh (clean slate)
./scripts/launch-tagged-automation.sh <tag> --qa resume    # restore prior session

# Any other launch path — set the env var directly:
C11_QA_LAUNCH=fresh open "/path/to/c11 DEV <tag>.app"

# Release/staging build — QA mode is passed through to the app:
C11_QA_LAUNCH=fresh ./scripts/reloads.sh --tag <tag>
C11_QA_LAUNCH=resume ./scripts/reloads.sh --tag <tag>
```

The launcher unsets any inherited `C11_QA_LAUNCH` and only sets it when `--qa` is passed, so a stray value in your shell can't silently flip a normal run into QA mode.

## Rebuilding GhosttyKit

When rebuilding `GhosttyKit.xcframework`, always use Release optimizations:

```bash
# On Atlas only, coordinated with its build slots:
cd ghostty && ../scripts/with-build-lock.sh zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

## Reporting a tagged reload in chat

When reporting a tagged reload result to the user, use the format for your agent type.

**Claude Code** (markdown link, cmd+clickable):
```markdown
=======================================================
[c11 DEV <tag-name>.app](file:///Users/<user>/Library/Developer/Xcode/DerivedData/c11-<tag-name>/Build/Products/Debug/c11%20DEV%20<tag-name>.app)
=======================================================
```

**Codex** (plain text):
```
=======================================================
[<tag-name>: file:///Users/<user>/Library/Developer/Xcode/DerivedData/c11-<tag-name>/Build/Products/Debug/c11%20DEV%20<tag-name>.app](file:///Users/<user>/Library/Developer/Xcode/DerivedData/c11-<tag-name>/Build/Products/Debug/c11%20DEV%20<tag-name>.app)
=======================================================
```

Never use `/tmp/c11-<tag>/...` app links in chat output. If the expected DerivedData path is missing, resolve the real `.app` path and report that `file://` URL.

## Tag hygiene

Before launching a new tagged run, clean up any older tags you started in this session (quit the old tagged app, remove its `/tmp` socket / derived data).

**Prune stale tags periodically.** Each `reload.sh --tag` leaves ~3.5G behind in DerivedData and `/tmp` that nothing auto-cleans — across many iterations this consumes hundreds of GB:

```bash
./scripts/prune-tags.sh           # dry run
./scripts/prune-tags.sh --yes     # actually delete
./scripts/prune-tags.sh --keep <tag>   # protect an additional tag
```

Running tags are auto-protected. A weekly launchd job (`scripts/launchd/com.stage11.c11-prune-tags.plist`) runs `--yes` automatically; reach for manual prune when you want space back sooner.

## Debug event log

All debug events (keys, mouse, focus, splits, panels) go to a unified log in DEBUG builds:

```bash
tail -f "$(cat /tmp/c11-last-debug-log-path 2>/dev/null || echo /tmp/c11-debug.log)"
```

- Untagged Debug app: `/tmp/c11-debug.log`
- Tagged Debug app (`reload.sh --tag <tag>`): `/tmp/c11-debug-<tag>.log`
- `reload.sh` writes the current path to `/tmp/c11-last-debug-log-path`
- `reload.sh` writes the selected dev CLI path to `/tmp/c11-last-cli-path`
- `reload.sh` updates `/tmp/c11-cli`, `$HOME/.local/bin/c11-dev`, and `$HOME/.local/bin/cmux-dev` (compat alias) to that CLI

### Adding a log call

The `dlog("message")` free function lives in `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`. The whole file is `#if DEBUG`, so every call site must also be wrapped in `#if DEBUG` / `#endif`. Existing event names include `focus.*`, `tab.*`, `pane.*`, and `divider.*`; grep for a nearby category before inventing a new one.
