import Foundation

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

/// C11H-267: the bounded work a Quit runs before its final reply when Keep
/// Terminals After Quit is off. One stop per process: a second Quit, or an
/// update relaunch that arrives during it, joins the stop in flight. Main is
/// never blocked: `work` runs as a task, and `onFinish` runs once, on main,
/// when the work returns or `seconds` pass, whichever is first.
@MainActor
final class QuitTerminalStop {
    enum State: Equatable { case idle, stopping, finished }

    private(set) var state: State = .idle
    private var onFinish: ((_ summary: String?, _ timedOut: Bool) -> Void)?

    /// False, and `onFinish` is dropped, when a stop already started: the
    /// first caller's reply answers the termination.
    @discardableResult
    func begin(seconds: TimeInterval, work: @escaping @MainActor () async -> String,
               onFinish: @escaping (_ summary: String?, _ timedOut: Bool) -> Void) -> Bool {
        guard state == .idle else { return false }
        state = .stopping
        self.onFinish = onFinish
        Task { @MainActor [weak self] in
            let summary = await work()
            self?.finish(summary, timedOut: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.finish(nil, timedOut: true) }
        }
        return true
    }

    private func finish(_ summary: String?, timedOut: Bool) {
        guard state == .stopping, let onFinish else { return }
        state = .finished
        self.onFinish = nil
        onFinish(summary, timedOut)
    }
}

/// C11H-267: what a Quit with Keep Terminals After Quit off does, in order:
/// End All's end path over this app's own terminals (local and on linked
/// machines), then a stop of this app's own local cores, all by one deadline.
/// The local cores stop last because a linked machine's end travels over them.
@MainActor
struct QuitTerminalEnder {
    /// End All's selection of this install's terminals.
    var identities: @MainActor () async -> [HCPanelIdentity]
    /// The explicit-end coordinator, origin `endAll`.
    var requestEnd: @MainActor ([HCPanelIdentity]) -> Void
    /// Whether every end settled within the given seconds.
    var awaitEnds: @MainActor ([UUID], TimeInterval) async -> Bool
    /// This app's own local shard cores, stopped by the deadline.
    var stopLocalCores: @MainActor (UInt64) async -> [Int: HCQuitStopOutcome]
    /// Share of the time left that the ends may wait before the cores stop.
    var endsShare = 0.6

    func run(deadline: UInt64) async -> String {
        let targets = await identities()
        requestEnd(targets)
        let left = deadline > HCMonotonic.now ? Double(deadline - HCMonotonic.now) / 1_000_000_000 : 0
        let settled = targets.isEmpty ? true : await awaitEnds(targets.map(\.panelID), left * endsShare)
        let cores = await stopLocalCores(deadline)
        let coreText = cores.sorted { $0.key < $1.key }.map { "s\($0.key)=\($0.value.rawValue)" }
        return (["ends=\(targets.count)", "settled=\(settled ? 1 : 0)"] + coreText).joined(separator: " ")
    }
}
