# Proving drags in a sandbox guest

How C11H-207 proved cross-window drags (workspace cards, panel tabs, tear-off) with real pointer
input in a `sandbox-up.sh` guest. The scenario script is `scripts/guest-cross-window-drag.py`; the
pointer driver is `scripts/guest-xdrag.m`.

- **cliclick cannot start a SwiftUI drag.** Its events carry timestamp 0, and `.onDrag` never
  begins a drag session from them (a sidebar resize, a plain mouse drag, still works). Compile
  `guest-xdrag.m` in the guest with its Command Line Tools
  (`clang -fobjc-arc -framework Foundation -framework ApplicationServices guest-xdrag.m -o xdrag`)
  and drag with `xdrag X1 Y1 X2 Y2 [steps] [hold_ms]` in global points: timestamped HID events with
  click state 1 and mouse deltas, able to cross from one window into another.
- **Read drag points off a screenshot.** In these guests the accessibility tree stops at the window
  chrome (about 100 elements, no SwiftUI identifiers), so `sidebar.workspace.<uuid>` lookups find
  nothing. Take the phase's "before" shot, read the points, pass them in; the socket (`tree`,
  `hc-diagnostics`, `get-metadata`, `browser eval`) judges the result.
- **A narrow area folds its strip** into one block. Give a drag source at least one wide area.
- **Wait for the drop, not a clock.** A loaded the build host starves the guest (a 9 s app hang at load 800
  on 2026-11-05) and drops land seconds late. After the mouse-up, wait for the app's own debug-log
  line (`tab.drop`, `pane.drop`, `sidebar.crossWindowDrop.*`, `drag.tearOff.release`) before
  checking. If a drag session never sees its mouse-up, the next phase's drag drives it; rerun on a
  quieter host rather than trust the result.
- **The share caches files.** Upload each edited script under a new name, and write screenshots to
  `/tmp` in the guest before copying them to the share (a direct `screencapture` there can stall).
- **The window a drag starts in can come forward at release** (AppKit's deferred ordering for its
  mouse-down) over the window being dropped into. The app tolerates this (`SidebarForeignHover`);
  a proof should still show the drop landing where the preview pointed.
