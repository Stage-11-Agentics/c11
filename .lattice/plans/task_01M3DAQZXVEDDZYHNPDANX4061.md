# C11-235: c11: a socket-created tab (new-surface) gets no PTY until it is focused; start the PTY at creation

A terminal surface created over the socket with new-surface into a pane where another tab is selected never starts its PTY until a human focuses it, so an automation that creates a hosting tab and waits for a shell hangs. launch-agent-created surfaces do not have this problem. Expected: a socket-created terminal surface starts its PTY at creation regardless of focus. Found by the Overwatch seat launcher (hands-on surface, 2026-09-25).
