# C11-204: Insecure-HTTP alert uses app-modal runModal and can wedge c11 for hours

FOUND BY. C11-198's classification of the local hang log (21,253 captures, Jun 15 - Aug 9).

EVIDENCE. BrowserPanel.presentInsecureHTTPAlert is the deepest c11 frame on 4,747 main-thread hang captures across 6 episodes on 1 pid. Median episode 8.5 minutes, MAX 6.8 HOURS (24,601,422 ms) with main blocked the whole time. It is the single largest capture-count culprit in the runloop-idle family.

MECHANISM. Sources/Panels/BrowserPanel.swift:3936-3940. When an alert window is available the alert is presented with beginSheetModal (non-blocking, correct). The fallback path is 'handleResponse(alert.runModal())' - an APP-MODAL NSAlert that spins a nested run loop on main and blocks the entire application until a human dismisses it. Nothing times out. Nothing dismisses it programmatically. Every terminal, every pane, every agent in the window is frozen for as long as the alert sits there.

WHY IT BITES. The alert fires on http:// navigation. c11's browser surfaces are routinely driven by agents over the socket ('c11 browser open <url>'), often while the window is backgrounded and nobody is watching. An agent navigates to an http:// URL, the modal goes up behind an unwatched window, and c11 is wedged until the operator finds it. That is the 6.8-hour episode.

FIX DIRECTIONS.
  - Never fall back to app-modal runModal. If there is no window to sheet onto, present the decision non-blockingly and default-deny on a timeout, or route the prompt to the requesting surface.
  - When the navigation was initiated over the socket rather than by a human, do not prompt at all: resolve from policy (deny, or allow if the caller opted in) and report the decision back to the caller.
  - Whatever path is chosen, the decisionHandler must always be invoked, and never from a nested run loop on main.

ACCEPTANCE. Driving a c11 browser surface to an http:// URL over the socket, with the window backgrounded, does not block the main thread: other panes stay interactive and the hang watchdog records no episode with presentInsecureHTTPAlert on the stack.

RELATED. C11-198 (#413) reclassifies this stack out of runloop-idle so it stops being filed as benign idle and starts reaching Sentry with hang.culprit naming it. That makes the bug visible; it does not fix it.
