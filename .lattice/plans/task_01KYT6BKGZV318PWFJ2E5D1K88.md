# C11-186: Make main-thread hangs survivable: async surface attach, out-of-process hang reporting, recovery manifest, detachable sessions

Main-thread hangs are unsurvivable: the app cannot report them, cannot recover from them, and the only remedy destroys every agent in the workspace. Close all four gaps.

EVIDENCE. A 14-hour deadlock on 0.60.1 (121): main blocked in GhosttyNSView.attachSurface inside a SwiftUI layout pass, 3 io-readers behind it, 97 threads idle, byte-identical across ~40 samples. MainThreadHangMonitor detected it in 2s and wrote 9,418 attachSurface frames to ~/Library/Logs/c11/hang.log. Nothing surfaced. Diagnosis took hours of external sampling to rediscover what the app had already written. Full analysis: notes/BUG-main-thread-deadlock-attachSurface.md, notes/c11-deadlock-final-sample.txt.

A. FIX THE DEADLOCK. attachSurface must not block main inside updateNSView; SwiftUI re-drives it every layout pass so the wait can never self-clear. Make the ghostty attach asynchronous, reusing the existing deferred-attach path (GhosttyTerminalView.swift:3290, :4492). Bound any residual synchronous wait to ~50ms with fallback to deferred. Underneath, shrink two ghostty critical sections: SharedGridSet.ref builds a grid (font discovery, face loading) while holding an exclusive Mutex; SharedGrid.getIndex/renderGlyph hold the write lock across rasterization. Construct outside the lock, acquire only to publish. Both are shared upstream code — offer to manaflow-ai rather than diverge.

B. GIVE THE EXISTING DIAGNOSTIC A CONSUMER. The socket survives main-thread wedges (ping and version answered throughout; only main-marshalling handlers returned empty). Add a main-thread-free `c11 doctor` reporting stall duration and top captured frame. Route hang.begin/persist to the out-of-process event channel (Resources/bin/c11 events tail). A hung main thread cannot draw AppKit, so an in-app banner is impossible by construction — the out-of-process path is the only one that can work.

C. WATCHDOG RECOVERY MANIFEST. When main is wedged past ~60s, the monitor thread — already alive, already writing files — dumps workspace layout, per-surface cwd, and agent session ids to disk. This was hand-assembled under duress during the incident; it should be automatic. Converts force-quit-then-archaeology into force-quit-then-one-command.

D. DETACHABLE SESSIONS. Agents are c11 descendants (claude <- zsh <- login <- c11), so the only remedy for any main-thread hang destroys the entire fleet — 22 agents mid-run in this incident. Not every future hang will be ours: Metal stalls, font-server hangs, AppKit bugs, input methods. The daemon/ and remote-daemon-status primitives already exist for SSH; turned inward, PTYs owned by a local daemon with surfaces as reattachable views makes this class of failure a nuisance instead of a disaster.

ALSO. Helpers under Resources/bin are not reaped with the host: `c11 events tail --instance com.stage11.c11-6063 --follow` survived the kill, following a dead socket. And `c11 version` reported 0.60.0 (118) while the running image was 0.60.1 (121) — a stale CLI is what makes a future diagnosis lie to you.

SEQUENCING. B first (small, makes every future hang self-reporting). Then A (kills this bug). Then C (insurance for hangs not yet found). D is strategic and the only one that changes the outcome class.

ACCEPTANCE. A main-thread hang is observable from outside the process without attaching a sampler; a surface attach cannot block main; a wedged instance leaves a machine-readable recovery manifest; and killing the host does not require killing the fleet.
