---
name: c11-computer-use
version: 1
description: Validate c11 as a product through the real macOS UI — screenshots, clicks, keyboard focus, area readability, visual recovery, user-path checks. Load when a maintainer/dev agent needs to see a c11 change exactly as the operator sees it (not just pass socket/CLI oracle checks). Distinct from the `c11` operating skill, which teaches an agent to use the room; this teaches testing the room through its real UI.
---

# c11 Computer-Use Validation

Maintainer skill: prove a c11 change works through the **real macOS UI**, the way the operator experiences it. Use it for behavior that is visual, spatial, focus-sensitive, pointer-driven, or human-ergonomic — the things a green socket/CLI oracle can't prove. Keep the socket for setup and deterministic oracle checks; keep computer-use for the UI path itself.

This is not the `c11` operating skill. That one teaches an agent to drive the room (splits, panels, status). This one teaches a maintainer agent to test the room as a product. Do not blur them.

## The hard rule: never validate against the operator's live c11

**On this machine, several c11 processes run at once** — the operator's production `/Applications/c11.app`, plus any tagged dev builds. They are **all named `c11`** in `ps` and in System Events. That ambiguity is a live footgun:

- **Never drive validation with global keystrokes.** `osascript … keystroke` (System Events) goes to whatever app is **frontmost** — which is almost always the operator's production c11, not your build. A blind global shortcut (say, a font-size or close-window chord) fired to "test your build" will hit the operator's real terminals. This has nearly happened; treat it as forbidden.
- **A full-screen `screencapture` grabs the frontmost app**, which may be production. Before you believe a screenshot is your build, confirm it — look for the tagged window title or the red **THIS IS A DEV BUILD** marker. Activation calls (`set frontmost`, `AXRaise`) frequently *fail silently* when the target is on another Space, so "I asked it to come forward" is not proof it did.

### Target a specific build unambiguously — by PID and window ID

Do this inside the sandbox guest (via `scripts/sandbox-exec.sh`), where the click cannot reach the operator. The same PID rule still matters there if more than one c11 is running.

- **Find your build's PID** (it launched from `…/DerivedData/c11-<tag>/…/c11 DEV <tag>.app`), then use the PID as the filter for everything. `unix id is <pid>` selects exactly one process no matter how many are named `c11`.
- **Screenshot the exact window, even when it's behind another app**, by CGWindowID:
  ```
  python3 -c "import Quartz;[print(w['kCGWindowNumber'], w.get('kCGWindowName')) for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID) if w.get('kCGWindowOwnerPID')==<pid>]"
  screencapture -l<windowNumber> -o out.png
  ```
- **Trigger UI actions on that build only**, via PID-scoped GUI scripting — safe with any number of c11 processes running, and it activates the correct one:
  ```
  osascript -e 'tell application "System Events" to tell (first process whose unix id is <pid>) \
    to click menu item "<Item>" of menu "<Menu>" of menu bar 1'
  ```
  Menu clicking exercises the real user path (it shares wiring with the keyboard shortcut and command palette) without the frontmost-app risk of raw keystrokes. To confirm a menu item exists first, read it: `get name of every menu item of menu "<Menu>" of menu bar 1`.

### Socket is setup and oracle, not the UI trigger

Use the tagged build's socket (`C11_SOCKET=/tmp/c11-debug-<tag>.sock`) to build the scene (workspaces, splits, seed terminals with size-revealing content) and to read state (`tree`, `read-screen`). The socket **cannot** drive AppKit menus, keys, the text box, settings, or the sidebar — that is exactly why the PID-scoped GUI-scripting path above exists for the actual UI trigger. `send` reaches PTYs only.

For comparable runs, set a tagged window's frame with `c11 resize-window --window <id> <width> <height>`. `-` keeps an edge; `- -` reads the frame. The top-left stays fixed, sizes clamp to the window minimum and screen, and the command does not focus. The response's `screen.display_id`, `screen.frame`, and `screen.visible_frame` identify the target's actual owning display used for that request and its clamp bounds. Restore the size or close the extra window before the run ends.

## Clicks, drags, and live tests run in a sandbox

Any click, drag, or app activation runs in a sandboxed c11, not in the operator's session. The operator's session is only for socket and CLI oracles, and for `screencapture -l` of a window that is already on screen.

```
scripts/sandbox-up.sh <run-id> <tagged.app> [--allow-second]
scripts/sandbox-exec.sh <run-id> <command> [args...]
scripts/sandbox-shot.sh <run-id> <host-png> [screencapture args...]
scripts/sandbox-down.sh <run-id>
scripts/sandbox-tests-v2.sh <run-id> [tests_v2/test_file.py ...]
```

`sandbox-up` clones a stopped golden image and launches the `.app` inside that guest. It does not boot the golden image. `--app-source local-app` (the default) is a bundle path on this machine. `--app-source atlas-build` is reserved for a later branch build on the Tart host and exits before SSH; it does not install Xcode. The Tart host is `C11_SANDBOX_HOST` (default `atlas`). Each clone keeps its golden image's serial, so Setup Assistant does not run. A second concurrent guest needs `--allow-second` and clones the second golden image (`c11-sandbox-golden-b`, its own serial), so it boots to the desktop too. Live `tests_v2` runs go through `sandbox-tests-v2.sh` after `sandbox-up`. They are python3 scripts, not pytest, they keep going after a failing file, and the suite has to match the app build. They never attach to the operator's c11. If `sandbox-up` is cut off, `sandbox-down <run-id>` removes the clone. Why this shape, and the one-time host setup, live in `docs/c11-sandbox-research.md`.

### Live agent proofs run in the sandbox

A proof that needs real agents (a Claude Code, Codex, or Grok panel receiving mail, hooks firing, a turn running) runs in the sandbox guest, never in a tagged build on the operator's laptop:

```
scripts/sandbox-up.sh <run-id> <tagged.app> --agents claude,codex,grok
scripts/sandbox-agent.sh <run-id> launch <claude|codex|grok> <brief.md> --title lc-claude
scripts/sandbox-agent.sh <run-id> c11 new-panel --workspace workspace:2 --no-focus  # any guest c11 command; this one makes a shell panel
scripts/sandbox-agent.sh <run-id> c11 send --workspace workspace:2 --panel panel:12 "c11 mailbox send --to lc-claude --body 'reply PONG'"
scripts/sandbox-agent.sh <run-id> screen panel:6 --workspace workspace:2 --lines 60
scripts/sandbox-down.sh <run-id>
scripts/sandbox-agent.sh <run-id> verify-clean            # after down; --control while up proves the scan sees guest files
```

`--agents` copies the Tart host's installed agent CLIs into the clone and stages one access credential per kind from the Overwatch seat logins on that host (`seat.sh export-cred`). Credentials go host to guest on SSH stdin and live only in the clone; the golden image never holds one, and `verify-clean` searches its disk for them after `sandbox-down`. `launch` delivers the brief as a file pointer through the guest's `c11 launch-agent`, opts the panel into mailbox push, and waits for the composer. `mailbox send` needs a sender panel, so send mail from a shell panel inside the guest workspace, as above; that is also what an agent sees. An operator draft is `c11 send --raw --no-submit`. A kind whose account is out of quota starts logged in and then shows the provider's limit screen: read the screen before calling a delivery failure. `C11_SANDBOX_CLAUDE_ACCOUNT` picks the Claude call-sign.

## Launch discipline

- Launch **only tagged builds** (`./scripts/reload.sh --tag <tag>`, or `./scripts/launch-tagged-automation.sh <tag> --qa fresh`). Never `open` an untagged `c11 DEV.app` — it conflicts with the operator's running instance. For a click, drag, or activation check, pass that `.app` to `scripts/sandbox-up.sh` instead of opening it on the operator's session.
- Suppress the startup dialogs for automation: `C11_QA_LAUNCH=fresh` (the skills-install and resume-picker sheets otherwise block coordinate-driven UI). `reload.sh --tag` does **not** set it; export it yourself or use `launch-tagged-automation.sh --qa`.
- Quit only **your** build when done — `kill <your-pid>`, never a blanket match on `c11`.

## Handing validation to a fresh agent

A watched validation pass runs in a fresh context, so the result doesn't inherit the builder's assumptions. Open a new panel, start interactive `codex --yolo` (never `codex exec`, which the operator can't watch), and send a file-backed prompt naming the tagged app and window, the scenario, success criteria, safety boundaries, expected artifacts, and your workspace and panel refs so it can report back with `c11 send`. Works across harnesses: Claude can hand to Codex, Codex to another Codex panel.

## Reading what the app actually did

- **Capture stdout by launching the binary directly.** `open` sends it nowhere, and libraries that
  log with `print`/`fputs` rather than `os_log` are then invisible to `log stream` too. Run
  `"<app>/Contents/MacOS/c11" > /tmp/<tag>-stdout.log 2>&1 &` with the same env
  `launch-tagged-automation.sh` sets (`C11_SOCKET_MODE`, `C11_SOCKET_PATH`, `CMUXD_UNIX_PATH`,
  `C11_DEBUG_LOG`, `C11_QA_LAUNCH`), unsetting the inherited `C11_*` vars first. This is how
  you read an SDK's own debug output instead of inferring it.
- **Wedge the main thread from outside, with no code seam**, when you need a real beachball:

  ```bash
  lldb -p <pid> -b \
    -o 'expr -l objc -- (void)[[NSThread class] performSelectorOnMainThread:@selector(sleepUntilDate:) withObject:[NSDate dateWithTimeIntervalSinceNow:12.0] waitUntilDone:NO]' \
    -o detach
  ```

  lldb stops every thread while attached, so no watchdog sees a false hang; the block runs only once
  the process resumes. Note the stall the watchdog measures includes the attach time, and the
  attach gets slower as you repeat it — pace episodes rather than firing them back to back.

## Prove it, don't assert it

- Capture before/after artifacts for any claim about visible behavior. For size/layout changes, seed terminals with distinctive, size-revealing content so the delta is unmistakable across areas.
- "It executed" is not enough. Inspect `c11 tree --no-layout` before calling a run good: if areas are too small for a human to read, rebalance and count that as part of validation, not cleanup.
- Prefer repeatable harness scenarios over one-off manual runs, and feed what you learn back into reusable scenarios and this skill.
