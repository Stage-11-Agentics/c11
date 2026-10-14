MODEL=ugemini, LENS=standard

### 1. Correctness & soundness
The dispatcher pipeline (`validate -> resolve -> copy -> handlers -> cleaned`) and the new cross-workspace routing correctly fulfill the stated goals. The non-silent rejection safely handles dead letters by quarantining envelopes that resolve to zero recipients (`envelope.to != nil && recipients.isEmpty`), preventing silent blackholes. Cross-workspace routing correctly offloads global state resolution to the CLI via socket, meaning the per-workspace daemon naturally inherits cross-workspace capabilities without complex IPC locking.

There is a minor flaw in the copy pipeline:
*   `Sources/Mailbox/MailboxDispatcher.swift:231`: `let envelopeBytes = (try? envelope.encode()) ?? Data()` re-encodes the parsed payload but fails open to `Data()` (an empty byte array) if serialization fails. This could theoretically write empty files into recipient inboxes. The dispatcher already loaded the raw valid `Data` at line 197 (`let data = try Data(contentsOf: processingURL)`). Passing `data` straight through to `copyToInbox` would be safer and more efficient.

### 2. Design quality
*   **Per-workspace dispatcher**: Excellent separation of concerns. Keeping dispatch local to the workspace prevents cross-workspace blocking and simplifies filesystem isolation.
*   **CLI-routes-to-recipient-outbox**: This is a clever and robust way to achieve cross-workspace delivery without a heavy global orchestrator daemon.
*   **Local-first routing**: The `MailboxGlobalResolver` precedence (sender's workspace wins on collision) is exactly the right default. It prevents spooky action-at-a-distance when an operator accidentally launches two agents with the same name in different workspaces.
*   **Filesystem-as-transport**: Fits perfectly within the unix/CLI ethos, providing atomic durability and allowing raw bash scripts to natively participate without socket libraries.

### 3. API/contract clarity
*   The CLI surface (`--to-workspace` disambiguation, standard exit codes) is highly learnable and intuitive.
*   The V1 Envelope Schema (`MailboxEnvelope.swift`) provides a solid source of truth. Leaving `ext` as open `[String: Any]` allows organic metadata extension.
*   The `_dispatch.log` NDJSON shape and `.err` sidecar pattern for quarantined/rejected messages make the system incredibly debuggable for operators (`c11 mailbox trace`).

### 4. Consistency & fit
*   The implementation matches the c11 threading policy (e.g., using a dedicated `.utility` queue for fs-events and bounding `@MainActor` hops with an internal 2-second timeout in `invokeHandlerSynchronously` at `MailboxDispatcher.swift:344`).
*   There is some minor code duplication: `rejectUnresolved` (`MailboxDispatcher.swift:377`) and `quarantine` (`MailboxDispatcher.swift:396`) perform the exact same 5 lines of directory-creation and file-moving. These could easily be collapsed into a single utility.

### 5. Test coverage
*   The cross-workspace validation tags (T1-T6) prove that the edge cases (collisions, unknown recipients, raw file races) are thoroughly accounted for.
*   The gap around crash-recovery for `_processing/` sweeps is explicitly acknowledged as a Stage-2 limit and is an acceptable trade-off for the current release.

---

### Findings

**Blockers:**
*   None. The logic is defensive, sound, and matches the design intent.

**Important:**
*   None.

**Suggestions:**
*   `Sources/Mailbox/MailboxDispatcher.swift:231`: Stop re-encoding the envelope. Reuse the `data` constant from line 197 to avoid the `try? ... ?? Data()` fallback that could theoretically deliver empty 0-byte files.
*   `Sources/Mailbox/MailboxDispatcher.swift`: Deduplicate `rejectUnresolved` and `quarantine` methods, as their internals are identical.

**Verdict:**
**SHIP / MERGE** — The feature is structurally sound, safely isolated, and provides a powerful new messaging primitive for multi-agent workflows.
