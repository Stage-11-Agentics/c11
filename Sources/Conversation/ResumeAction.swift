import Foundation

/// Transient action returned by `ConversationStrategy.resume(...)`. Executed
/// by `Workspace` against a live `TerminalPanel`.
///
/// Every strategy that emits `typeCommand` MUST validate `ConversationRef.id`
/// against a documented grammar (regex or validator) and apply explicit
/// shell-quoting/escaping before interpolation. If the id fails validation
/// or the ref is still a placeholder, the strategy MUST return
/// `.skip(reason:)` rather than synthesizing a command.
public enum ResumeAction: Sendable, Equatable {
    /// Type `text` into the surface. If `submitWithReturn` is true, dispatch
    /// a real synthetic Return key event after the paste so line discipline
    /// executes the line outside bracketed-paste mode.
    case typeCommand(text: String, submitWithReturn: Bool)
    /// Strategy declined to resume. `reason` is recorded via Diagnostics.log.
    case skip(reason: String)
}
