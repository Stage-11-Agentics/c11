import Foundation

/// Formal handler protocol (Step 10). The dispatcher's registry stores
/// closures that invoke a handler's `deliver`. Stage 2 concrete handlers:
///   * `StdinMailboxHandler` (MailboxHandler.swift peer) — writes the framed
///     `<c11-msg>` block to the recipient's PTY.
///   * Silent — registered inline by `Workspace.startMailboxDispatcher()`.
protocol MailboxHandler {
    func deliver(
        envelope: MailboxEnvelope,
        to surfaceId: UUID,
        surfaceName: String
    ) async -> MailboxDispatcher.HandlerInvocationResult
}

extension MailboxHandler {
    /// Adapts a concrete handler into the closure shape the dispatcher's
    /// registry expects, so `registerHandler(name:, Self)` stays terse.
    func asDispatcherFunction() -> MailboxDispatcher.HandlerFunction {
        { envelope, surfaceId, name in
            await self.deliver(
                envelope: envelope,
                to: surfaceId,
                surfaceName: name
            )
        }
    }
}
