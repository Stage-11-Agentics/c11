# Trident Mailbox Review
## Lens: Critical (ugemini)

Here is a critical analysis of the c11 mailbox feature, highlighting predicted failure modes, races, and security issues across the codebase as it stands on `main`.

### 1. Concurrency & Races

**Trigger:** `recentlySeen` ring buffer eviction + `FSEvents` coalescing.
**Symptom:** Silent duplication of messages.
**Blast Radius:** The recipient receives the same message multiple times. Depending on the recipient's implementation, this could lead to duplicate actions (e.g., duplicated git commits, duplicate network requests).
**Likelihood:** Medium.
**File/Line:** `Sources/Mailbox/MailboxDispatcher.swift:481-492`
**Explanation:** The `recentlySeen` cache has a hard cap of 1024 (`recentlySeenCap`). If a workspace sustains a burst of >1024 messages within FSEvents' coalescing window or before the `gcTimer` sweeps stale `.tmp` files, an older FSEvent for a message that was already moved to `_processing/` might replay. The `try FileManager.default.moveItem` (Step 1) catches `ENOENT` to handle this gracefully, but if a malicious or buggy agent writes a *new* file with the *same* ID after eviction, FSEvents will trigger, `recentlySeen` won't block it, and the new file will overwrite the `_processing/` state of a potentially still-running job, or cause dual-dispatch if the first job finished. Even worse, if the original sender crashes mid-write and retries with the same ULID, or if `MailboxIO` atomic writes replay across processes, FSEvents can present the file again.

**Trigger:** GC Sweep race with active write.
**Symptom:** `_outbox/` files disappear before FSEvents triggers.
**Blast Radius:** Message silently lost.
**Likelihood:** Low, but possible on slow storage or CPU starvation.
**Explanation:** The GC sweep deletes `.tmp` files older than 5 minutes. If an agent writing to the outbox takes > 5 minutes to complete the write and `rename` to `.msg` (e.g., system sleep, CPU starvation, or a large `body_ref` copy hanging), the GC might delete the `.tmp` file out from under the writer. The writer's atomic move will then fail (`ENOENT`). The writer believes the write failed, but depending on the retry logic, this could result in dropped messages.

**Trigger:** Synchronous main thread blocking in `StdinMailboxHandler`.
**Symptom:** Mailbox dispatcher hangs for 2 seconds, dropping throughput to 0.5 msg/sec.
**Blast Radius:** Local DoS of the dispatcher queue.
**Likelihood:** High.
**File/Line:** `Sources/Mailbox/MailboxDispatcher.swift:391-418`, `Sources/Mailbox/StdinMailboxHandler.swift`
**Explanation:** The `invokeHandlerSynchronously` uses a 2-second timeout `semaphore.wait`. However, the handler's execution (`await handler(…)`) jumps to `@MainActor` to write to the PTY. If the main thread is blocked (e.g., heavy AppKit layout, a hang in a different panel, or a user drag operation), the PTY write blocks. After 2 seconds, the dispatcher's utility queue logs a `timeout` and continues to the *next* handler/cleanup, **but the `Task` executing on the main actor is still running**. When the main thread unblocks, the delayed PTY write will execute, potentially pasting out of order with newer messages that were dispatched later but hit an unblocked main thread.

### 2. Resolution Correctness Under Churn

**Trigger:** Recipient surface title change/close race between CLI resolve and Dispatcher resolve.
**Symptom:** Message routed to wrong surface or rejected at recipient.
**Blast Radius:** Confidential message delivered to unintended agent, or lost message.
**Likelihood:** Medium.
**File/Line:** `CLI/c11.swift:16851-16894`, `Sources/Mailbox/MailboxDispatcher.swift:281-285`
**Explanation:** `c11 mailbox send` calls `mailbox.resolve` synchronously. It gets back a target `workspaceId`. It writes to `target_workspace_id/_outbox/`. The dispatcher in `target_workspace_id` then picks it up (async, fsevents driven) and calls `resolveRecipients` using `MailboxSurfaceResolver`. Between the CLI resolution and the Dispatcher resolution, the recipient could change its title, or close. If it closes, `recipients.isEmpty` is true, and the dispatcher quarantines the message in `_rejected/` — correct behavior. BUT, if *another* surface in that workspace assumes the target title during the race window, the message is delivered to the *new* surface. Surface titles are non-unique and mutable by the agent. This is a TOCTOU (Time of Check to Time of Use) vulnerability for routing.

**Trigger:** Socket unreachability fallback masks ambiguity.
**Symptom:** Silent misdelivery or rejection.
**Blast Radius:** Unexpected agent behavior.
**Likelihood:** Low to Medium.
**File/Line:** `CLI/c11.swift:16868-16872`
**Explanation:** If the global socket is unreachable, `resolveMailboxTargetWorkspace` silently falls back to `senderWorkspaceId`. If the intended recipient is in another workspace, the sender's workspace dispatcher will pick it up, fail to resolve it locally, and move it to `_rejected/`. The sender receives `exit 0` and assumes delivery was successful.

### 3. The Cross-Workspace Seam

**Trigger:** Disconnected Outbox write vs Dispatcher start.
**Symptom:** Messages stranded in an outbox that is never watched.
**Blast Radius:** Messages silently never delivered.
**Likelihood:** High.
**File/Line:** `CLI/c11.swift:16812-16818`, `Sources/Workspace.swift:5892-5937`
**Explanation:** `c11 mailbox send` creates `targetWorkspaceId/_outbox/` if it doesn't exist (`try FileManager.default.createDirectory(...)`) and writes the message. However, the dispatcher for a workspace is only created in `Workspace.startMailboxDispatcher()`, which is called by `TabManager` after a workspace is wired in. If a background process creates a workspace via API but the UI hasn't instantiated it yet, or if a zombie workspace directory exists, the CLI will happily write to its outbox, but no `MailboxDispatcher` is running to read it. The sender gets a success, but the message is stranded forever.

**Trigger:** Split-brain trace logs.
**Symptom:** Sender cannot trace a message sent across workspaces.
**Blast Radius:** Observability failure.
**Likelihood:** Guaranteed on cross-workspace errors.
**File/Line:** `CLI/c11.swift:16981-16982`
**Explanation:** The CLI `trace` command (`runMailboxTraceCommand`) reads the dispatch log of the *caller's* workspace (`MailboxLayout.dispatchLogURL(state: stateURL, workspaceId: workspaceId)`). When a message is sent across workspaces, it is written to the *recipient's* outbox. The *recipient's* dispatcher logs the lifecycle events (received, resolved, handler outcome) in the *recipient's* `_dispatch.log`. The sender running `c11 mailbox trace <id>` will see absolutely nothing, hiding `_rejected/` quarantines or timeout failures from the sender.

### 4. Delivery Integrity

**Trigger:** PTY terminal state corruption via injection.
**Symptom:** Attacker escapes framing or executes arbitrary commands.
**Blast Radius:** RCE or terminal hijacking in the recipient context.
**Likelihood:** High (for complex payloads).
**File/Line:** `Sources/Mailbox/StdinMailboxHandler.swift`
**Explanation:** The handler pastes `<c11-msg>...` blocks directly into the PTY. If the recipient shell is in raw mode (e.g., running `vim`, `fzf`, or another agent TUI), the PTY write bypasses shell quoting and is interpreted as keystrokes by the application. If the recipient agent is expecting JSON but gets arbitrary bytes because it wasn't expecting an envelope *at that moment*, its state machine corrupts. Furthermore, while XML escaping prevents forging the closing tag in the *payload*, it does not protect against control characters. An attacker can include `\x03` (Ctrl-C), `\x04` (Ctrl-D), ANSI escape sequences, or bracketed paste escapes within the escaped body to disrupt the recipient shell or spoof terminal responses.

**Trigger:** Large payloads exceed PTY buffer.
**Symptom:** Truncated envelopes or dropped messages.
**Blast Radius:** Incomplete message delivery.
**Likelihood:** High.
**File/Line:** `Sources/Mailbox/StdinMailboxHandler.swift:31-33`
**Explanation:** The maximum body size is 4KB. The PTY `TerminalPanel.sendText` performs a buffered byte append. Writing >4KB of data rapidly to a PTY, especially across boundaries, can overwhelm the internal AppKit or terminal emulator buffers, leading to dropped bytes. The framing `<c11-msg>...` might be incomplete on the receiving end, causing the recipient's parser to hang waiting for the closing tag.

### 5. Durability & Lifecycle

**Trigger:** Crash in `_processing/` window.
**Symptom:** Message stranded in `_processing/` forever.
**Blast Radius:** Message loss.
**Likelihood:** Low.
**File/Line:** `Sources/Mailbox/MailboxDispatcher.swift:231-241`
**Explanation:** (Acknowledged Stage-2 gap). A message is moved from `_outbox/` to `_processing/`. If c11 crashes before the copy to the recipient's inbox and log append, the message is permanently stranded. When c11 restarts, the dispatcher only watches `_outbox/` and has no recovery sweep for `_processing/`.

**Trigger:** Unbounded file accumulation.
**Symptom:** Disk exhaustion and degraded resolution performance.
**Blast Radius:** System instability.
**Likelihood:** High over time.
**File/Line:** `Sources/Mailbox/MailboxDispatcher.swift:305-313`
**Explanation:** The `_dispatch.log` grows unbounded. More critically, the `_rejected/` directory grows unbounded for malformed messages or unresolved cross-workspace writes. A spammy agent failing to resolve a name will rapidly fill `_rejected/` with `.msg` and `.err` files. There is no quota or eviction mechanism.

### 6. Scale & Abuse

**Trigger:** Inbox unbounded growth.
**Symptom:** Receiver IO degradation or disk fill.
**Blast Radius:** DoS of a specific agent or system.
**Likelihood:** High.
**Explanation:** Senders write to the outbox, dispatcher copies to the inbox. There is no per-surface inbox cap implemented in Stage 2. A rogue agent can `send` repeatedly, filling a recipient's inbox until the disk is full.

### Production-Readiness Verdict

**NOT READY FOR WIDE PRODUCTION.**
The cross-workspace routing logic introduces severe TOCTOU races and breaks observability (trace logs). The synchronous `@MainActor` PTY writes present a significant denial-of-service vector for the dispatcher queue. The lack of PTY control character sanitization allows trivial terminal hijacking between agents.

**Most Likely Real-World Failure Mode:**
**The Split-Brain Trace Trap.** Operators heavily rely on observability to debug multi-agent orchestration. A sender agent will write to another workspace, the recipient will close or change its title just before dispatch, the message will go to `target_workspace/_rejected/`, and the sender will run `c11 mailbox trace <id>` and get zero output. The operator will be completely blind to the failure, leading to massive debugging friction during dogfooding.
