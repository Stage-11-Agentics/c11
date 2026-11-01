/// One AppKit terminateLater request. Claim the reply before dismissing its
/// sheet: dismissal can reenter through the sheet completion or window close.
@MainActor
final class DeferredTerminationReply {
    private var reply: ((Bool) -> Void)?

    init(reply: @escaping (Bool) -> Void) {
        self.reply = reply
    }

    @discardableResult
    func resolve(_ shouldTerminate: Bool, beforeReply: () -> Void = {}) -> Bool {
        guard let reply else { return false }
        self.reply = nil
        beforeReply()
        reply(shouldTerminate)
        return true
    }
}
