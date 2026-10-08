# C11-366: Mailbox push follow-ups from C11-365: drained doorbells, stillHolds on disconnect, transcript route wiring test

Small follow-ups left after C11-365 (#625, f440a14f0e). None blocks delivery.

1. Buffered doorbells for mail already drained still log `evicted` at the 64-entry cap. In the MouthKeys run on 2026-10-08, 373 of 373 messages after 15:11Z reached the coordinator by `recv --drain`, but the dispatch log showed one `evicted` per message for four hours. When a drain claims an envelope, drop its buffered stdin entry (or log `drained`), so the dispatch log tells the truth.
2. `JournalMailboxBoundary.stillHolds` ignores the connection state. An old idle edge can still reach the gate after SessionEnd marked the panel disconnected. The foreground-group and PID checks already stop any typing, so this is harmless, but requiring `current.connection == .live` is tighter.
3. Tests cover the boundary's `verifiedNativeClock` parameter but not its wiring. Add one assertion that `JournalContext.forTranscriptAppend(draft:eligible:)` sets `verifiedNativeClock` for a real Codex and Grok `turn.completed` draft (as built by `JournalTranscriptProducer.makeDraft`).
