# Standard Plan Review

### Executive Summary
The plan is highly rigorous, explicitly adapting to the latest operator overrides and repo-specific `CLAUDE.md` constraints. It successfully transitions the agent-state marks to a shape-based vocabulary, disentangles the upstream `Bonsplit` changes from `c11` metadata, and implements a robust, leaf-isolated animation architecture to satisfy strict typing-latency performance contracts. By avoiding over-engineering (e.g., dropping the breathe animation and skipping a complex fleet harness as instructed by the operator), this plan is structurally sound and ready to execute.

### The Plan's Intent vs. Its Execution
The intent is to make the four lifecycle states distinguishable by shape alone, removing the reliance on color, and to lay the groundwork for C11-184 (flagged/suppressed agents). The execution perfectly matches this intent. The plan implements the "Static marks" setting, respects the Reduce Motion accessibility override, and carefully threads the needle on the `flagged` and `suppressed` integration by adding default-false seams now, meaning the UI code doesn't need a rewrite in the next ticket. It properly restricts itself from expanding into C11-184 territory (no socket/metadata/CLI work).

### Architectural Assessment
The architecture is exceptionally strong, specifically regarding the performance contract:
- **One Shared Clock:** Rejecting per-mark `TimelineView`s or timers in favor of a single shared clock with stable UUID-based offsets is the correct approach to prevent timer proliferation and CPU churn at fleet scale.
- **Leaf Isolation:** Confining the animation state and clock subscription strictly within the mark leaf views ensures that the parent `TabItemView` and workspace cards do not re-evaluate their bodies on every beat. Relying on `Equatable` conformance is exactly the right mechanism here.
- **Projection vs. Visual Dimming:** Implementing `suppressed` as a pure-function projection in `SidebarActivityProjector` (falling back to `working`/`idle`/`cold` instead of `.waiting`) rather than a visual opacity treatment simplifies the renderers significantly.

### Is This the Move?
Yes. Given the project's strict typing-latency constraints (detailed in `CLAUDE.md`), introducing continuous or beat-based animations is a massive risk. The plan hedges this risk perfectly by avoiding `TerminalSurface.forceRefresh()` work, pausing off-screen animations, and isolating repaints. Furthermore, the decision to push `Bonsplit` cleanly upstream first (Phase 1) and then commit the submodule pointer in the parent (Phase 2) avoids the classic submodule desync failure pattern described in the repo conventions.

### Key Strengths
1. **Operator Alignment:** Rapidly incorporates the operator's override (flashing core for flagged waiting, standard fill for flagged working, no breathe animation, no heavy QA harness), preventing wasted effort.
2. **Submodule Discipline:** Outlining the exact git commands for verifying remote-main ancestry before committing the `vendor/bonsplit` pointer prevents orphaning the submodule commit.
3. **Localization Compliance:** Recognizing that `Localizable.xcstrings` should not be modified manually and deferring translation to a later sub-agent stage respects the project's localization policy ("Write English only").
4. **Test Scheme Selection:** By narrowing tests to `c11-logic` (`SidebarActivityProjectorTests`, `WorkspacePulseMarkRowMetricsTests`), the plan avoids the heavy `c11-unit` XCTest host overhead, keeping validation fast and safe for local execution.

### Weaknesses and Gaps
1. **Clock Pausing Mechanism:** The plan mentions "stop the shared timer with no live registrations or while the app is inactive" and "use scroll viewport intersection... rather than assuming SwiftUI pauses offscreen content". While conceptually sound, detecting scroll viewport intersection in SwiftUI can sometimes trigger its own layout/scroll performance issues.
2. **Flagged Color in Upstream Bonsplit:** The plan mentions "expose modifier inputs with defaults without importing c11 metadata concepts" for Bonsplit. If the violet color (`#9D8AD9`) is strictly a C11 concept, providing an `isFlagged` boolean to `TabActivityMark` might violate Bonsplit's generic nature if Bonsplit hardcodes the violet color.

### Alternatives Considered
- **Per-mark `TimelineView`:** The obvious, idiomatic SwiftUI alternative for animations. The plan rightly rejects this because at fleet scale (40+ marks), 40 decoupled timers would demolish the typing latency budget.
- **Visual Suppression:** Applying an opacity filter (dimming) for suppressed agents instead of lifecycle projection. The plan correctly adopts the projection approach, meaning the UI only ever draws 4 fundamental states (no combinatorial explosion of dimmed variants).

### Readiness Verdict
**Ready to execute.** The plan is meticulous, fully accounts for the performance and architectural constraints, and is ready for implementation without structural revisions.

### Questions for the Plan Author
1. For the upstream-clean Bonsplit changes in `TabActivityMark`: To keep Bonsplit truly agnostic of c11's attention model, will you pass an `isFlagged: Bool` (and hardcode violet in Bonsplit), or will you pass an optional `overrideColor: Color?` so c11 injects the violet tint and Bonsplit remains ignorant of the "flagged" concept?
2. For scroll viewport intersection in Phase 2: Are you planning to use a `GeometryReader` or `.onAppear`/`.onDisappear` for the tabs? If `GeometryReader` is used inside the scroll view, are you confident it won't introduce layout thrashing on the tab bar during scroll events?
