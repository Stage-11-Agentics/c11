# Adversarial Plan Review

### Executive Summary
This plan is a "won't fix" disguised as an observability improvement. The author was tasked with fixing a 10-second main thread hang caused by SwiftUI generic metadata instantiation. Instead of fixing the hang, the author discovered the Sentry issue was a grouping bucket for many different hangs, noted the metadata hang was only 5.7% of the bucket, and pivoted to building a custom client-side stack trace classifier to reorganize the Sentry dashboard. The plan explicitly declares view-tree restructuring a "non-goal" and re-writes the acceptance criteria to evade fixing the actual bug. If executed, the user experience does not improve: the app will still beachball for 10 seconds, we will just have 13 neatly categorized Sentry issues documenting it.

### How Plans Like This Fail
- **Bait and Switch Scope**: The plan completely abandons the original directive (fix a specific performance bottleneck) in favor of tooling work.
- **Client-Side Telemetry Parsing**: Building a custom frame-by-frame stack classifier (`MainThreadHangSignature`) in the client app to outsmart Sentry's grouping is notoriously brittle. The moment Apple updates SwiftUI or AttributeGraph internals in a macOS point release, the classifier's regexes or string-matches will break, dumping everything into an "unknown" bucket.
- **Solving the Dashboard, not the App**: The plan focuses entirely on how the errors are grouped in Sentry. It fails to recognize that 50 events of a 10-second main thread hang is a critical product failure, regardless of whether it represents 5.7% or 100% of a specific Sentry issue.

### Assumption Audit
- **Assumption (Load-bearing):** Because the generic metadata hang is only 5.7% of the events (50 events), it is not the primary issue and can be deferred.
  - *Challenge:* The author notes 1 user generated 816 of the 875 events. What if that 1 user generated all the AttributeGraph hangs, and the *other 6 users* generated the 50 generic metadata hangs? If so, the metadata hang is actually the most widespread issue across the user base.
- **Assumption:** Client-side stack parsing is the best way to fix Sentry grouping.
  - *Challenge:* Sentry SDKs allow setting the crashed/wedged thread explicitly or passing custom grouping fingerprints without needing to build a bespoke Swift-based backtrace parser for Apple's private frameworks (`SwiftUICore`, `AttributeGraph`, etc.).
- **Assumption:** "10422ms is the stall duration at the moment of a single sample, not time spent in the sampled frame."
  - *Challenge:* While technically true, if the thread hasn't returned to the runloop in 10 seconds, and the sample catches it in `swift_getTypeByMangledName`, it's highly probable the massive view tree layout *is* the root cause. Dismissing the sample as a single point in time ignores the reality of the beachball.
- **Assumption:** Because no `Button` explicitly owned by `c11` is named in the stack, there is no specific expensive Button to restructure.
  - *Challenge:* SwiftUI's type erasure and internal view wrapping frequently obscure the exact c11 view name. `NSHostingView` is the boundary. We know what views we host in AppKit (Sidebar, TabBar, Toolbars). This is a cop-out to avoid auditing the view trees.

### Blind Spots
- **The sibling ticket (C11-191):** The author notes 64% of the hangs are SwiftUI graph work, and explicitly points out "C11-191 is in this family." If C11-191 is already fixing the AttributeGraph hangs, then by the time C11-191 merges, the generic metadata hang will become the dominant unresolved issue in this bucket. The plan acts as if these issues are statically distributed.
- **The user experience:** What does the user see after this plan ships? The exact same 10-second hang. The plan offers no mitigation.
- **Maintenance burden:** Who owns `MainThreadHangSignature` when macOS 27 drops and the internal `AttributeGraph` stack frames change? We are taking on the maintenance of a mini-crash-reporter.

### Challenged Decisions
- **Amending the Acceptance Criteria:** The author unilaterally decides the original acceptance criteria ("a profile showing `swift_getTypeByMangledName` absent from the layout pass") cannot be met because they couldn't immediately find the view, so they change the goal to "generic-metadata exists as its own Sentry issue". This deserves massive pushback. You don't get to redefine a bug fix as an analytics task just because the bug is hard to find.
- **Client-side stack classification:** Why are we parsing `backtrace_symbols` strings in Swift production code? If Sentry is grouping by the hang monitor thread, the correct fix is to configure the Sentry SDK to treat the main thread as the crashed thread, or to pass a hash of the main thread's stack as the Sentry fingerprint. Building a semantic classifier for private Apple frameworks is over-engineering the wrong solution.

### Hindsight Preview
- In two months, we will look back and realize we spent days writing unit tests for a stack parser (including handling "module names with spaces") instead of wrapping the deepest `ForEach` in an `AnyView`.
- We will see a spike in "other compute" hangs because a macOS security update slightly renamed a `libswiftCore` frame, breaking our brittle `MainThreadHangSignature` parser.
- The 10-second hang will still be reported by users on GitHub, and we'll have to create *another* ticket to actually fix the SwiftUI view tree.

### Reality Stress Test
What happens if:
1. **Apple ships a macOS update** that changes `AttributeGraph` to a new layout engine. Our `MainThreadHangSignature` fails to classify 64% of our hangs.
2. **C11-191 merges**, eliminating the AttributeGraph hangs. Now our fancy classifier is mostly categorizing the metadata hangs we refused to fix.
3. **The user with 816 events stops using the app.** Suddenly our telemetry priorities shift drastically because the data was heavily skewed by one power user with a specific workspace topology.

### The Uncomfortable Truths
- The author couldn't find the `Button` causing the hang, so they wrote a telemetry tool to prove they didn't need to look for it.
- We are shipping a completely unfixed 10-second beachball to our users while patting ourselves on the back for having better dashboards.
- The Sentry misattribution (grouping on the watchdog thread) is a real problem, but fixing it should take 5 lines of Sentry SDK configuration (`scope.setFingerprint(...)`), not a new `MainThreadHangSignature` module with its own unit tests.

### Hard Questions for the Plan Author
1. You noted that 1 user generated 816 of the 875 events. How many of the 7 users experienced the 50 `generic-metadata` hangs? If it was 6 users, doesn't that make it the most widespread issue, despite the lower event count?
2. If C11-191 fixes the AttributeGraph hangs (64% of your bucket), won't the generic metadata hang immediately become the dominant issue anyway?
3. How does parsing `backtrace_symbols` strings in production Swift code survive the next macOS update when Apple renames internal `SwiftUICore` frames?
4. Why are we building semantic stack classification in the client instead of just passing the raw main thread stack to Sentry and using Sentry's built-in fingerprinting/grouping rules?
5. You claim "no metadata-stack event names a Button c11 owns". Which of our `NSHostingView` boundaries (Sidebar, Tab bar, Command Palette) have you actually audited with Time Profiler to rule out deeply nested generic chains?
6. If the plan succeeds perfectly, the user still experiences a 10-second hang. Is that acceptable for a "performance fix" ticket?
