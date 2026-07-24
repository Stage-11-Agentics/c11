---
name: c11-computer-use
version: 1
description: Validate c11 as a product through the real macOS UI — screenshots, clicks, keyboard focus, pane readability, visual recovery, user-path checks. Load when a maintainer/dev agent needs to see a c11 change exactly as the operator sees it (not just pass socket/CLI oracle checks). Distinct from the `c11` operating skill, which teaches an agent to use the room; this teaches testing the room through its real UI.
---

# c11 Computer-Use Validation

Maintainer skill: prove a c11 change works through the **real macOS UI**, the way the operator experiences it. Use it for behavior that is visual, spatial, focus-sensitive, pointer-driven, or human-ergonomic — the things a green socket/CLI oracle can't prove. Keep the socket for setup and deterministic oracle checks; keep computer-use for the UI path itself.

This is not the `c11` operating skill. That one teaches an agent to drive the room (splits, surfaces, status). This one teaches a maintainer agent to test the room as a product. Do not blur them.

## The hard rule: never validate against the operator's live c11

**On this machine, several c11 processes run at once** — the operator's production `/Applications/c11.app`, plus any tagged dev builds. They are **all named `c11`** in `ps` and in System Events. That ambiguity is a live footgun:

- **Never drive validation with global keystrokes.** `osascript … keystroke` (System Events) goes to whatever app is **frontmost** — which is almost always the operator's production c11, not your build. A blind global shortcut (say, a font-size or close-window chord) fired to "test your build" will hit the operator's real terminals. This has nearly happened; treat it as forbidden.
- **A full-screen `screencapture` grabs the frontmost app**, which may be production. Before you believe a screenshot is your build, confirm it — look for the tagged window title or the red **THIS IS A DEV BUILD** marker. Activation calls (`set frontmost`, `AXRaise`) frequently *fail silently* when the target is on another Space, so "I asked it to come forward" is not proof it did.

### Target a specific build unambiguously — by PID and window ID

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

## Launch discipline

- Launch **only tagged builds** (`./scripts/reload.sh --tag <tag>`, or `./scripts/launch-tagged-automation.sh <tag> --qa fresh`). Never `open` an untagged `c11 DEV.app` — it conflicts with the operator's running instance.
- Suppress the startup dialogs for automation: `C11_QA_LAUNCH=fresh` (the skills-install and resume-picker sheets otherwise block coordinate-driven UI). `reload.sh --tag` does **not** set it; export it yourself or use `launch-tagged-automation.sh --qa`.
- Quit only **your** build when done — `kill <your-pid>`, never a blanket match on `c11`.

## Prove it, don't assert it

- Capture before/after artifacts for any claim about visible behavior. For size/layout changes, seed terminals with distinctive, size-revealing content so the delta is unmistakable across panes.
- "It executed" is not enough. Inspect `c11 tree --no-layout` before calling a run good: if panes are too small for a human to read, rebalance and count that as part of validation, not cleanup.
- Prefer repeatable harness scenarios over one-off manual runs, and feed what you learn back into reusable scenarios and this skill.
