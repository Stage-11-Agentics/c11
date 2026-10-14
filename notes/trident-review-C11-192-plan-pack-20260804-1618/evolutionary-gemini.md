# Evolutionary Review: C11-192 (Hang Signature Classifier)

### Executive Summary
The plan pivot is brilliant: it shifts from chasing a phantom UI bug to building a semantic, client-side hang classifier. The biggest opportunity here isn't just fixing Sentry grouping—it's turning the crash reporter into an edge-computing profiling agent. If this evolves well, the c11 team will never have to guess at a hang's root cause again; they will have a live, high-fidelity pipeline of exact stalls categorized by phase (SwiftUI, XPC, IPC, File I/O) across the fleet.

### What's Really Being Built
Beneath the surface of a "Sentry fingerprint fix", you are building a **Client-Side Stack Semantic Analyzer** and **Telemetry Router**. You are evolving the c11 client from a dumb error reporter into a self-aware profiling agent that understands its own execution state, parses its own stack traces, categorizes its own performance failures, and routes that metadata to the observability platform. It is a fundamental upgrade to the app's nervous system.

### How It Could Be Better
- **Context-Aware Classification**: Parsing stack symbols is great, but combining it with application state at the time of the hang is better. For example, if it's an XPC wait, *what* XPC service? If it's a SwiftUI layout hang, *which* workspace or pane was active?
- **Offline / Persistent Hang Logs**: The plan routes this intelligence to Sentry. But as seen in sibling ticket C11-191, local `~/Library/Logs/c11/hang.log` was the oracle that actually solved the issue! The signature classifier must also annotate the *local* hang log on the user's disk so that local debugging immediately benefits from the semantic cause.
- **Client-Side Deduplication**: One user hit the same 10-second hang 816 times, flooding Sentry. The classifier could maintain a session-level hash map of hang signatures and send 1 full report + 815 incremented counters, saving quota and noise.

### Mutations and Wild Ideas
- **Agent Back-Pressure via Socket**: If the semantic analyzer can classify a hang *while it is happening*, expose this state to the agents running inside c11 via the socket. If the UI is hanging because of excessive terminal updates from an agent, the agent could receive a back-pressure signal (`window.stalled`) and throttle its output!
- **The "Hang-to-Ticket" Pipeline**: What if this classifier could not only fingerprint the hang but automatically generate a formatted GitHub/Lattice issue with the disassembled stack and hypothesized root cause, skipping the Sentry middleman for known new signatures?
- **Proactive Auto-Recovery**: For specific, well-understood hang classes (like `runloop-idle` or a stuck XPC call), the monitor could trigger targeted recovery strategies (e.g., re-evaluating the runloop or severing a specific connection) rather than just watching it burn.

### What It Unlocks
- **Fleet-Wide Profiling**: By categorizing hangs (SwiftUI vs XPC vs syscall), engineering leadership can make data-driven decisions on whether to invest in SwiftUI optimization or XPC refactoring based on real fleet data.
- **Automated Regression Testing**: Tests can now assert "No SwiftUI layout hangs > 100ms" by hooking into the classifier during UI/E2E test runs, using the exact same code that runs in production.
- **Agent Performance Awareness**: Unlocks the ability to correlate agent actions (like rapid text output or frequent pane splitting) with specific main thread stall signatures.

### Sequencing and Compounding
1. **Immediate (As Planned)**: Ship the `MainThreadHangSignature` parser and Sentry integration to stop the bleeding and get real data.
2. **Next (Compounding)**: Pipe the `MainThreadHangSignature` output into the local `hang.log` so local devs get the exact same semantic insights without needing Sentry access.
3. **Defer**: Don't build auto-recovery or agent back-pressure yet. Focus entirely on observability, getting the signatures right, and separating the signal from the noise.

### The Flywheel
**The Observability-Fix Flywheel**:
Better hang classification → More precise Sentry issues → Developers fix the *actual* root causes faster (like C11-191) → Fewer generic hangs → The remaining unclassified hangs stand out more clearly → Developers refine the classifier rules → Better hang classification.
This plan is the crank that starts this flywheel.

### Concrete Suggestions
1. **Enrich the Local Log**: Modify `MainThreadHangMonitor` to append the calculated `hang.cause`, `hang.phase`, and `hang.culprit` to the local `~/Library/Logs/c11/hang.log`. This ensures local debugging is just as powerful as Sentry.
2. **Add a Rate Limiter**: Since one user generated 816 events, add a simple per-signature deduplicator or rate limiter per session. If `MainThreadHangSignature` is the same as the last 10 hangs, just increment a local counter and send a summary event on exit.
3. **Capture Agent/Workspace Context**: Add the ID of the currently focused workspace or active agent to the `tags:`. If an agent is blasting text and causing a SwiftUI layout hang, knowing *which* agent or what surface it was on is crucial context for the fix.

### Questions for the Plan Author
1. Should the semantic signature also be written to the local disk hang log, or is this strictly for Sentry?
2. How should we handle aggressive burst hangs (like the user with 816 events)? Should we implement client-side rate-limiting by signature hash to preserve the Sentry budget?
3. Can we capture the currently active Workspace ID or active Pane ID and attach it as a tag, so we know if certain environments trigger specific hang classes?
4. Are we confident `backtrace_symbols` parsing is robust enough across different macOS versions and SDKs, given the string format can occasionally drift?
5. Should we expose this hang telemetry over the c11 socket so agents can detect if they are overwhelming the UI?
