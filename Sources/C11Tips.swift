import AppKit
import SwiftUI

/// C11H-127 part 2: contextual tips that teach c11 at the moment it matters.
/// Each tip shows once per profile, in a popover that never takes the
/// keyboard and never moves the layout, and never under `C11_QA_LAUNCH`.
enum C11Tip: String, CaseIterable, Equatable {
    /// After a reopen that reattached terminals that kept running.
    case keptRunning
    /// The first time a new terminal opens on another machine.
    case remoteLabel
    /// The first End Session close the operator makes.
    case endSession
}

/// When a tip may show, and which restored terminals survived the quit.
enum C11TipPolicy {
    static let shownKey = "c11.tips.shown"

    static func shown(defaults: UserDefaults = .standard) -> Set<C11Tip> {
        Set((defaults.stringArray(forKey: shownKey) ?? []).compactMap(C11Tip.init(rawValue:)))
    }

    static func markShown(_ tip: C11Tip, defaults: UserDefaults = .standard) {
        var names = defaults.stringArray(forKey: shownKey) ?? []
        guard !names.contains(tip.rawValue) else { return }
        names.append(tip.rawValue)
        defaults.set(names, forKey: shownKey)
    }

    static func mayOffer(_ tip: C11Tip, qa: QALaunchPolicy, shown: Set<C11Tip>) -> Bool {
        !qa.isActive && !shown.contains(tip)
    }

    /// How many of the terminals restored at launch are still the same live
    /// terminal: the session kept running while the app was closed. A
    /// restored panel recreated after its terminal ended has a new key and
    /// does not count.
    /// - restored: each restored panel and the terminal key it was saved with.
    /// - liveKey: the key a panel shows live now, or nil when it is not live.
    static func survivors(restored: [UUID: HCTerminalKey], liveKey: (UUID) -> HCTerminalKey?) -> Int {
        restored.reduce(0) { count, entry in liveKey(entry.key) == entry.value ? count + 1 : count }
    }

    /// The tip's text. `count` is used by `keptRunning`, `machine` by `remoteLabel`.
    static func copy(_ tip: C11Tip, count: Int = 0, machine: String = "") -> (title: String, detail: String) {
        switch tip {
        case .keptRunning:
            let title = count == 1
                ? String(localized: "c11.tip.keptRunning.one",
                         defaultValue: "Your terminal kept running while c11 was closed.")
                : String(format: String(localized: "c11.tip.keptRunning.other",
                                        defaultValue: "Your %lld terminals kept running while c11 was closed."),
                         Int64(count))
            return (title, String(localized: "c11.tip.keptRunning.detail",
                                  defaultValue: "Quitting c11 never ends them. Closing a panel does."))
        case .remoteLabel:
            return (String(format: String(localized: "c11.tip.remoteLabel.title",
                                          defaultValue: "This terminal runs on %@."), machine),
                    String(localized: "c11.tip.remoteLabel.detail",
                           defaultValue: "Its title bar names that machine. If the link drops, it says Reconnecting and the session keeps running."))
        case .endSession:
            return (String(localized: "c11.tip.endSession.title",
                           defaultValue: "That ended the terminal and everything it started."),
                    String(localized: "c11.tip.endSession.detail",
                           defaultValue: "Background jobs ended too. Quitting c11 instead keeps terminals running."))
        }
    }
}

/// Where a tip points: a view in a window, and the rect and edge it hangs from.
struct C11TipAnchor {
    weak var view: NSView?
    let rect: NSRect
    let edge: NSRectEdge
}

/// Shows one tip at a time. A tip asked for while another is up, or while
/// `isBlocked` says a sheet is in the way, waits its turn.
@MainActor
final class C11TipCenter: NSObject, NSPopoverDelegate {
    static let shared = C11TipCenter(suppressed: MessagesPageWriter.isRunningUnderXCTest())

    /// The What's different window is up: tips wait until it closes.
    var isBlocked: () -> Bool = { false }

    private struct Request {
        let tip: C11Tip
        let title: String
        let detail: String
        let anchor: () -> C11TipAnchor?
        var attempts = 0
    }

    private var queue: [Request] = []
    private var popover: NSPopover?
    private var shownTip: C11Tip?
    private var retry: DispatchWorkItem?
    private let defaults: UserDefaults
    private let qa: () -> QALaunchPolicy
    /// The app's center is silent under XCTest; a test's own center is not.
    private let suppressed: Bool

    /// The app is in front and the anchor window is on screen. A tip shown
    /// to an inactive app would close on the first click back, unseen.
    var canShowNow: (NSWindow) -> Bool = { window in
        NSApp.isActive && window.isVisible && window.occlusionState.contains(.visible)
            && window.attachedSheet == nil
    }

    init(defaults: UserDefaults = .standard, qa: @escaping () -> QALaunchPolicy = { QALaunchPolicy.current() },
         suppressed: Bool = false) {
        self.defaults = defaults
        self.qa = qa
        self.suppressed = suppressed
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive(_:)),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc nonisolated private func appBecameActive(_ notification: Notification) {
        MainActor.assumeIsolated { pump() }
    }

    /// Requests waiting their turn, for tests.
    var pendingTips: [C11Tip] { queue.map(\.tip) }

    /// Ask for a tip. Nothing happens when it has shown before or under QA.
    func offer(_ tip: C11Tip, count: Int = 0, machine: String = "",
               anchor: @escaping () -> C11TipAnchor?) {
        guard !suppressed,
              C11TipPolicy.mayOffer(tip, qa: qa(), shown: C11TipPolicy.shown(defaults: defaults)),
              shownTip != tip, !queue.contains(where: { $0.tip == tip }) else { return }
        let text = C11TipPolicy.copy(tip, count: count, machine: machine)
        queue.append(Request(tip: tip, title: text.title, detail: text.detail, anchor: anchor))
        pump()
    }

    /// Call when whatever blocked tips (the What's different window) is gone.
    func resume() { pump() }

    private func pump() {
        guard popover?.isShown != true, !queue.isEmpty else { return }
        guard !isBlocked() else { return }
        // C11H-138: a tip never lands on an open machine or agent picker; it
        // waits, and the picker resumes the queue when it closes.
        guard !MachinePickerPresenter.shared.isShown, !AgentPickerPresenter.shared.isShown else { return }
        var request = queue.removeFirst()
        // The anchor may not be on screen yet (a panel still attaching):
        // look again every half second for up to ten seconds.
        guard let anchor = request.anchor(), let view = anchor.view, let window = view.window else {
            request.attempts += 1
            if request.attempts < 20 { queue.insert(request, at: 0) }
            scheduleRetry()
            return
        }
        // On screen but the app is behind another one: keep it for when the
        // operator comes back (didBecomeActive pumps again). Not an attempt.
        guard canShowNow(window) else {
            queue.insert(request, at: 0)
            return
        }
        show(request, anchor: anchor, view: view, window: window)
    }

    private func scheduleRetry() {
        retry?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.pump() }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func show(_ request: Request, anchor: C11TipAnchor, view: NSView, window: NSWindow) {
        C11TipPolicy.markShown(request.tip, defaults: defaults)
        let popover = NSPopover()
        // Transient: a click anywhere else closes it. It never holds the
        // keyboard, so typing (Escape and Return too) keeps going to the terminal.
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: C11TipView(
            tip: request.tip, title: request.title, detail: request.detail,
            onDone: { [weak self] in self?.popover?.performClose(nil) }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        // Whichever window holds the keyboard keeps it, even when the tip
        // points into another window.
        let keyWindow = NSApp.keyWindow
        self.popover = popover
        shownTip = request.tip
        popover.show(relativeTo: anchor.rect, of: view, preferredEdge: anchor.edge)
        if let keyWindow, NSApp.keyWindow !== keyWindow { keyWindow.makeKey() }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            // A previous tip still animating closed must not clear the next one.
            guard (notification.object as? NSPopover) === popover else { return }
            popover = nil
            shownTip = nil
            pump()
        }
    }

    /// An operator closed panels whose sessions ended. A close an agent asked
    /// for over the socket teaches nothing to the operator and is skipped.
    static func noteSessionsEnded(count: Int, window: NSWindow?) {
        guard count > 0, SocketCommandContext.current == nil else { return }
        weak var target = window
        // After the close has run, so the anchor is the window that remains.
        DispatchQueue.main.async {
            shared.offer(.endSession) {
                windowAnchor(target?.isVisible == true ? target : AppDelegate.shared?.tipWindow())
            }
        }
    }

    /// The top edge of a terminal, where its title bar and machine label sit.
    static func hostedViewAnchor(_ view: NSView) -> C11TipAnchor? {
        // A terminal in a workspace the operator is not looking at stays in
        // the window, hidden: wait until it is on screen.
        guard view.window != nil, !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return nil }
        let bounds = view.bounds
        let y = view.isFlipped ? bounds.minY : bounds.maxY - 2
        return C11TipAnchor(view: view, rect: NSRect(x: bounds.minX + 24, y: y, width: 2, height: 2),
                             edge: view.isFlipped ? .minY : .maxY)
    }

    /// Top centre of a window's content, for tips about the whole window.
    static func windowAnchor(_ window: NSWindow?) -> C11TipAnchor? {
        guard let view = window?.contentView else { return nil }
        let bounds = view.bounds
        let y = view.isFlipped ? bounds.minY + 4 : bounds.maxY - 4
        return C11TipAnchor(view: view, rect: NSRect(x: bounds.midX - 1, y: y - 1, width: 2, height: 2),
                             edge: view.isFlipped ? .maxY : .minY)
    }
}

/// One tip: a line that says what happened, a line on what it means, Got It.
struct C11TipView: View {
    let tip: C11Tip
    let title: String
    let detail: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(String(localized: "whatsDifferent.done", defaultValue: "Got It"), action: onDone)
                    .controlSize(.small)
                    // C11H-166: name it for AX (AXDescription), not only its title.
                    .accessibilityLabel(Text(String(localized: "whatsDifferent.done", defaultValue: "Got It")))
                    .accessibilityIdentifier("c11.tip.\(tip.rawValue).done")
            }
        }
        .padding(14)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("c11.tip.\(tip.rawValue)")
    }
}
