# Standard Plan Review

### Executive Summary
This is an excellent, mature engineering plan. It correctly identifies that the ticket's premise is a symptom of a systemic observability failure (Sentry grouping by the hang-monitor's stack rather than the wedged main thread) rather than a single massive SwiftUI view tree issue. Abandoning the phantom view-tree optimization to instead fix the telemetry grouping is exactly the right move. The plan is sound, evidence-based, and ready to execute.

### The Plan's Intent vs. Its Execution
The original intent of the ticket was to fix a 10-second hang supposedly caused by generic metadata instantiation. The plan shifts this intent to fixing the observability pipeline that misattributed 875 disparate hangs to this single cause. The execution perfectly aligns with this corrected intent: it builds a pure signature classifier, updates the Sentry client to support explicit fingerprints, and tests the logic against real production data.

### Architectural Assessment
The decomposition is strong and respects the project's testing policies:
1. Pure parsing/classification logic (`MainThreadHangSignature`) decoupled from Sentry.
2. Sentry client enhancements (`sentryCaptureWarning`/`Error`) to accept explicit fingerprints.
3. Integration in `MainThreadHangMonitor`.

By extracting the signature logic into a pure type, it can be tested exhaustively in `c11LogicTests` (which is fast and runs without the host app), perfectly matching the local development guidelines in `CLAUDE.md`. 

### Is This the Move?
Absolutely. Blindly refactoring `Button` modifiers based on a stack trace that only applies to 5.7% of the grouped events would have been a frustrating waste of time. Fixing the instrumentation first so that the actual top issues (like the 64% SwiftUI graph work) can be correctly isolated and tracked is the only correct path forward. The plan makes the right bets.

### Key Strengths
- **Evidence-driven:** The author didn't just accept the ticket's premise; they pulled the raw Sentry data, analyzed all 875 events, and proved the premise wrong.
- **Sentry Quota Awareness:** The author realized that grouping by exact stack would create 645 distinct issues (607 singletons), which would create noise. Grouping by a 13-category classifier is a smart way to maintain high signal-to-noise ratio.
- **Testability:** Utilizing verbatim frames from production reports for `MainThreadHangSignatureTests` ensures the parser actually handles edge cases (like `c11 DEV` module names).

### Weaknesses and Gaps
- **Sentry Tag Limits:** Sentry imposes strict length limits on tags (typically 200 characters). The plan proposes tagging `hang.top_symbol` and `hang.culprit`. Swift mangled names and demangled signatures can easily exceed this limit, which could cause Sentry to drop or truncate the tags. These high-cardinality, potentially long strings should likely be stored in the event `extra` (Contexts) payload rather than as indexable `tags`.
- **Amended Acceptance Criteria:** The plan rejects the original Time Profiler acceptance criteria. While technically justified, discarding the original criteria means the 50 real generic metadata hangs are left untouched for now. The plan mentions this, but it relies on a future unknown ticket to fix them. 
- **Sentry Cocoa SDK Quirks:** The plan assumes setting an explicit fingerprint will completely override Sentry's grouping. However, if `attachStacktrace = true` is still active, Sentry might still try to use the capturing thread's stack in its grouping heuristic unless the explicit fingerprint is correctly formatted and passed down to the native layer. 

### Alternatives Considered
- **Alternative:** Fix both the telemetry grouping *and* the 50 generic metadata hangs in one PR.
- **Why the plan's choice is better:** Mixing telemetry infrastructure changes with speculative view-tree optimizations makes the PR bloated, harder to review, and increases regression risk. Separating observability fixes from performance fixes is the disciplined choice.

### Readiness Verdict
**Ready to execute.** The shift in scope is fully justified by the data.

### Questions for the Plan Author
1. Swift symbol names can easily exceed Sentry's 200-character tag limit. Should `hang.top_symbol` and `hang.culprit` be stored in the event context (`extra`) instead of tags, while keeping bounded categories like `hang.cause` and `hang.phase` as tags?
2. Have you verified that passing an explicit fingerprint to `sentryCaptureWarning` completely overrides the default grouping behavior of the Sentry Cocoa SDK when `attachStacktrace = true` is set?
3. Since we are abandoning the fix for the 50 actual generic metadata hangs in this ticket, will you proactively spawn a new Lattice ticket for them, or wait for the new telemetry to prove they are a sustained trend?
