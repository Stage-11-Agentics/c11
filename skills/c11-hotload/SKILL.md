---
name: c11-hotload
description: "Hot-reload workflow for c11 development: initial setup, tagged Debug builds via reload.sh, Release variants, the debug event log, and the tagged-build reporting format. Use when building, rebuilding, or launching c11 during development."
---

# c11 hotload

How to build, reload, and tail a c11 dev instance.

## Initial setup

```bash
./scripts/setup.sh
```

Initializes submodules and builds GhosttyKit.

## The tagged-build rule

**Never run bare `xcodebuild` or `open` an untagged `c11 DEV.app`.** Untagged builds share the default debug socket and bundle ID with any other agent's running instance, causing conflicts and stealing focus. Always reload with a tag:

```bash
./scripts/reload.sh --tag <your-branch-slug>
```

A tagged build gets its own name, bundle ID, socket, and derived data path so it runs isolated alongside anything else.

## Reload variants

| Command | What it does |
|---|---|
| `./scripts/reload.sh --tag <tag>` | Build and launch Debug, tagged (required tag) |
| `./scripts/reloadp.sh` | Build and launch Release (tears down running c11 via `pkill -x c11`) |
| `./scripts/reloads.sh` | Build and launch Release as "c11 STAGING" (isolated from production c11) |
| `./scripts/reload2.sh --tag <tag>` | Reload both Debug and Release (tag required for Debug) |

**Apply Release changes without killing the running app.** `reloadp.sh` starts with `pkill -x c11`, which tears down every c11 pane — fatal if another agent is mid-task in a sibling pane, or if the current agent session is itself hosted inside c11. To update the `.app` on disk without disturbing any running process, build only:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme c11 -configuration Release -destination 'platform=macOS' build
```

macOS lets you overwrite a running app's bundle — the already-loaded binary stays in memory, and the rebuilt `.app` is picked up on the next manual launch (⌘Q then relaunch). Use this when collaborating with other agents or when the user explicitly asks to avoid session churn.

**A rebuild-and-relaunch keeps agent resume only on a clean quit.** When a reload does restart the app over a running instance, let the script's clean quit drive the teardown — do **not** `pkill -9` / pre-kill it first. Browser and markdown surfaces restore either way, but agent terminals only resume their conversation when the prior process shut down cleanly; SIGKILL'd, they come back as bare shells.

## Build-only verification (no launch)

If you only need to verify the build compiles, use a tagged derivedDataPath:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme c11 -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/c11-<your-tag> build
```

## Driving a Release/staging build over the socket

A Release/staging build launched by `reloads.sh` binds its **own** socket in automation mode, so a CLI in another local shell can write to it when pointed at `C11_SOCKET_PATH=/tmp/c11-<slug>.sock`, where the slug is the tag lowercased with every non-alphanumeric run collapsed to a hyphen (`--tag rel-v0.65.2` binds `/tmp/c11-rel-v0-65-2.sock`; the script prints the exact path at launch). The script also clears the launching surface's C11/CMUX identity before opening the app. For socket-level validation during development, a tagged **Debug** build uses the same externally reachable automation mode via `C11_SOCKET=/tmp/c11-debug-<tag>.sock`.

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

The launcher unsets any inherited `C11_QA_LAUNCH`/`CMUX_QA_LAUNCH` and only sets it when `--qa` is passed, so a stray value in your shell can't silently flip a normal run into QA mode.

## Rebuilding GhosttyKit

When rebuilding `GhosttyKit.xcframework`, always use Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
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

All debug events (keys, mouse, focus, splits, tabs) go to a unified log in DEBUG builds:

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
