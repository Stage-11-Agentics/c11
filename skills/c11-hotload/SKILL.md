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

## Build-only verification (no launch)

If you only need to verify the build compiles, use a tagged derivedDataPath:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme c11 -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/c11-<your-tag> build
```

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

### Implementation

- `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`
- Free function `dlog("message")` — logs with timestamp and appends to file in real time
- Entire file is `#if DEBUG`; all call sites must be wrapped in `#if DEBUG` / `#endif`
- 500-entry ring buffer; `DebugEventLog.shared.dump()` writes full buffer to file
- Key events logged in `AppDelegate.swift` (monitor, performKeyEquivalent)
- Mouse/UI events logged inline in views (ContentView, BrowserPanelView, etc.)
- Focus events: `focus.panel`, `focus.bonsplit`, `focus.firstResponder`, `focus.moveFocus`
- Bonsplit events: `tab.select`, `tab.close`, `tab.dragStart`, `tab.drop`, `pane.focus`, `pane.drop`, `divider.dragStart`
