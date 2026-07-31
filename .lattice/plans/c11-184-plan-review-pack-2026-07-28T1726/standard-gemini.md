# Standard Plan Review

### Executive Summary
The plan for C11-184 is exceptionally well-structured, thoroughly addressing the complex requirements of the "flagged" and "suppressed" agent states. It demonstrates a deep understanding of the existing architecture, correctly identifying the necessary seams for injecting these orthogonal modifiers without conflating them with the base lifecycle states. The plan's emphasis on strict commit boundaries, explicit separation of raw vs. signal-eligible notification indexes, and the preservation of PTY dimensions via portal-hosted banners are all marks of a mature architectural approach. The plan is sound and ready for execution, with only minor areas regarding rapid state revisions and AppKit z-order fragility needing clarification.

### The Plan's Intent vs. Its Execution
The intent is to add two orthogonal modifiers (`flag` and `suppressed`) that alter the presentation and signalling of the existing lifecycle states. The execution aligns perfectly with this intent. By treating these as canonical metadata keys and building a pure projection layer (`SurfaceAttentionSnapshot` and the `AttentionModel` reducer), the plan avoids the anti-pattern of exploding the state machine into combinatorial states (e.g., `flagged-working`, `suppressed-idle`). The execution faithfully implements the binding spec, particularly the nuanced rule that a flag overrides suppression.

### Architectural Assessment
The decomposition is precise and targets the correct layers:
- **State:** Canonical metadata at the `.explicit` tier ensures persistence across relaunches automatically.
- **Projection:** Introducing `AttentionModel.swift` to act as a pure reducer of raw lifecycle + modifiers into presented state centralizes the complex logic (e.g., suppression masking `waiting`, flags overriding suppression).
- **History vs. Signal:** Refactoring `TerminalNotificationStore` into raw and signal-eligible views elegantly solves the requirement that suppressed notifications leave a historical record but emit no immediate signals.
- **Presentation:** Injecting presentation traits (color override, explicit motion channel) into Bonsplit as generic host properties is the correct way to respect the submodule boundary while achieving the required visual treatments.

An alternative framing might have been to introduce a new overarching "AttentionStore" that entirely replaces `TerminalNotificationStore`. However, the plan's approach of augmenting the existing store with signal eligibility is less invasive and reuses the established history semantics effectively.

### Is This the Move?
Yes, this is absolutely the right move. The plan avoids common pitfalls:
- It doesn't modify the core `WorkspacePulseState` enum, preventing a combinatorial explosion of states.
- It doesn't put the banner in the terminal's SwiftUI layout flow, avoiding catastrophic PTY resizes that would break TUIs like `codex`.
- It explicitly handles the race condition between UI updates and metadata commits via `SurfaceAttentionService`.
- It dictates a fleet-scale performance latency gate, acknowledging that continuous SwiftUI animation on 40+ leaf nodes is a severe battery/latency risk.

### Key Strengths
1. **PTY Reflow Prevention:** Mounting the `SurfaceFlagBanner` in the AppKit portal overlay (`NSHostingView`) rather than the SwiftUI layout flow is a critical strength. It prevents terminal resize events that would otherwise garble active TUI sessions.
2. **Bonsplit Submodule Hygiene:** Extending Bonsplit with generic presentation properties (`alternate core color`, `breathe motion sampler`) rather than C11-specific `flagged` semantics is exactly how submodule boundaries should be managed.
3. **Serialized Commit Boundary:** The introduction of `SurfaceAttentionService` to own the complete commit boundary (metadata write -> projection refresh -> event emission) is a robust pattern that will prevent the UI from reading torn or transient state.
4. **Latency Gate & Fallback Ladder:** The plan anticipates the performance impact of fleet-scale animation and pre-registers a degradation ladder (dip-only -> static default -> static violet fallback). This is mature engineering.

### Weaknesses and Gaps
1. **Active-to-Active Reason Revision Spam:** The plan permits active-to-active reason revisions, stating it "emits one new `flag.raised` event and one updated direct notification." If an agent aggressively updates its flag reason (e.g., streaming a thought process), this could result in system notification spam. There is no mention of debouncing or rate-limiting these revisions.
2. **Banner Z-Order Fragility:** The plan states the banner must define its z-order explicitly against find, pane-interaction, notification-ring, etc. Managing z-index amongst multiple independent AppKit portal overlays hosted from different sources can be highly fragile and prone to regressions.
3. **System Notification Lifecycle:** When a flag is lowered via the in-app banner X, the plan doesn't explicitly state whether it attempts to revoke the pending direct system notification from the macOS Notification Center (via `UNUserNotificationCenter.removeDeliveredNotifications`). If not, stale notifications will linger in the OS UI.

### Alternatives Considered
- **Direct System Delivery vs. TerminalNotificationStore:** The plan explicitly bypasses `TerminalNotificationStore` for flag raises, using direct system delivery to prevent double-counting in the workspace pulse.
  - *Alternative:* Write to `TerminalNotificationStore` but tag it as a `flag` type, then filter it out of the waiting pulse counts.
  - *Why the plan's choice is better:* The plan's choice strictly adheres to the provided spec ("A flag does not write to TerminalNotificationStore"). It also cleanly separates the concept of a transient "attention demand" from a "terminal output completion record".

### Readiness Verdict
**Ready to execute.** The plan is exceptionally thorough and architecturally sound. The minor gaps identified can be handled during implementation.

### Questions for the Plan Author
1. **Revision Spam:** For active-to-active reason revisions, is there a need to debounce or rate-limit the emission of updated direct system notifications to prevent an agent from spamming the operator's macOS Notification Center?
2. **Notification Revocation:** When `lower(by: .operator)` or `lower(by: .agent)` is called, should the `SurfaceAttentionService` also proactively remove any delivered but unclicked system notifications from the macOS Notification Center?
3. **Z-Order Management:** For the `SurfaceFlagBanner` portal hosting, does C11 already have a robust, centralized z-index management system for its overlays, or will this rely on implicitly managed sibling order/hardcoded z-indexes?
4. **Bonsplit Sync:** The plan says to push to remote `main` for Bonsplit. Will this be pushed to the `Stage-11-Agentics/bonsplit` fork's main, or does it require an upstream PR to `almonk/bonsplit` to be merged before the parent C11 pointer can be updated?