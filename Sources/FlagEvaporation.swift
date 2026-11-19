import AppKit
import Foundation
import QuartzCore

// C11H-330: evaporating flags.
//
// A flag kind may carry `evaporate_seconds`. While the operator looks at a
// flagged panel of that kind, a bar in the kind's color fills along the panel's
// top edge; after that many continuous seconds c11 lowers the flag itself
// (`flag.lowered`, by c11, cause evaporated).
//
// "Looking" is `PanelSeenTracker`'s being-seen panel: c11 frontmost, the
// panel's workspace selected in the key main window, the panel focused, and the
// window on screen with the screen awake and unlocked. Leaving resets the run
// (no pause); a re-raise restarts it. Everything is in memory: after a relaunch
// a run starts on the next look (AGENTS.md "Attention state stays simple").
//
// Cost. Evaluation runs on main from seen-panel changes, attention changes and
// registry edits only, never from keystroke, hit-test or draw paths. One
// one-shot timer exists only while a flagged evaporating panel is being seen.
// The bar is a Core Animation layer, so the render server draws the sweep.

/// The panel being looked at, with the inputs that decide its evaporation.
struct FlagEvaporationTarget: Equatable {
    var workspaceId: UUID
    var surfaceId: UUID
    var flagEpoch: Date
    var flagReason: String
    var kindId: String
    /// The flag's own color, so the bar matches its banner.
    var color: PanelFlagColorToken
    var seconds: Int

    /// Nil unless the seen panel is flagged with a registered kind that
    /// evaporates. `registryKind` is the live registry entry for the flag's kind.
    static func resolve(
        seen: (workspaceId: UUID, surfaceId: UUID)?,
        attention: PanelAttentionSnapshot?,
        registryKind: PanelFlagKind?
    ) -> FlagEvaporationTarget? {
        guard let seen,
              let attention,
              attention.workspaceId == seen.workspaceId,
              attention.surfaceId == seen.surfaceId,
              let reason = attention.flagReason,
              let epoch = attention.flagRaisedAt,
              let flagKind = attention.flagKind,
              let registryKind,
              registryKind.id == flagKind.id,
              let seconds = registryKind.evaporateSeconds,
              PanelFlagKind.evaporateSecondsRange.contains(seconds) else { return nil }
        return FlagEvaporationTarget(
            workspaceId: seen.workspaceId,
            surfaceId: seen.surfaceId,
            flagEpoch: epoch,
            flagReason: reason,
            kindId: flagKind.id,
            color: flagKind.color,
            seconds: seconds
        )
    }
}

struct FlagEvaporationRun: Equatable {
    var target: FlagEvaporationTarget
    var startedAt: Date

    var deadline: Date { startedAt.addingTimeInterval(TimeInterval(target.seconds)) }
}

enum FlagEvaporationStep: Equatable {
    /// Nothing runs and nothing should.
    case idle
    /// The current run continues untouched.
    case keep(FlagEvaporationRun)
    /// A run starts from zero; `replacing` is the run it ends, if any.
    case start(FlagEvaporationRun, replacing: FlagEvaporationRun?)
    /// The current run ends without lowering: the bar empties.
    case cancel(FlagEvaporationRun)
}

/// Pure state behind the controller. No AppKit, no clock of its own.
struct FlagEvaporationTracker {
    private(set) var run: FlagEvaporationRun?

    /// Reset, not pause: any change of target (another panel, a re-raise, a
    /// new reason, kind or duration) starts from zero, and no target ends it.
    mutating func update(target: FlagEvaporationTarget?, now: Date) -> FlagEvaporationStep {
        guard let target else {
            guard let current = run else { return .idle }
            run = nil
            return .cancel(current)
        }
        if let current = run, current.target == target { return .keep(current) }
        let prior = run
        let next = FlagEvaporationRun(target: target, startedAt: now)
        run = next
        return .start(next, replacing: prior)
    }

    /// The same target from zero: an accepted raise that changed nothing.
    mutating func restart(now: Date) -> FlagEvaporationStep {
        guard let current = run else { return .idle }
        let next = FlagEvaporationRun(target: current.target, startedAt: now)
        run = next
        return .start(next, replacing: current)
    }

    /// The current run once its deadline has passed, cleared so the lower it
    /// triggers reads as no run rather than a cancel.
    mutating func takeDue(now: Date) -> FlagEvaporationRun? {
        guard let current = run, now >= current.deadline else { return nil }
        run = nil
        return current
    }
}

/// A panel view that can show the bar (terminal, browser and markdown hosts).
@MainActor
protocol FlagEvaporationBarHost: AnyObject {
    /// Fill to full by the end of `duration`, from the `elapsed` share
    /// already made (zero for a run that starts now; more for a host that
    /// mounted mid-run).
    func startEvaporationBar(color: NSColor, duration: TimeInterval, elapsed: TimeInterval)
    /// Empty the bar at once: focus left, or the flag changed under it.
    func cancelEvaporationBar()
    /// Just before c11 lowers the flag.
    func prepareEvaporationFade()
    /// After the lower applied. A host without a flag banner fades its bar here.
    func evaporationLowered()
}

@MainActor
final class FlagEvaporationController {
    /// Everything the controller reads from the app, injectable for tests.
    struct Hooks {
        /// The panel the operator is looking at (`PanelSeenTracker`'s rule).
        var seenPanel: @MainActor () -> (workspaceId: UUID, surfaceId: UUID)?
        /// The cheap check `attentionDidChange` runs on every projection.
        var isSeen: @MainActor (UUID) -> Bool
        var registryKind: (String) -> PanelFlagKind?
        var now: () -> Date
        /// Runs `fire` at `deadline`; returns a cancel.
        var schedule: @MainActor (Date, @escaping @MainActor () -> Void) -> () -> Void
        var barHost: @MainActor (FlagEvaporationTarget) -> FlagEvaporationBarHost?
        var afterLower: @MainActor (FlagEvaporationTarget) -> Void

        static let live = Hooks(
            seenPanel: {
                guard PanelSeenTracker.shared.interruptions.isEmpty else { return nil }
                return AppDelegate.shared?.operatorSeenPanel()
            },
            isSeen: { PanelSeenTracker.shared.isBeingSeen(panelId: $0) },
            registryKind: { PanelFlagKindRegistry.shared.kind(id: $0) },
            now: { Date() },
            schedule: { deadline, fire in
                let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: item)
                return { item.cancel() }
            },
            barHost: { FlagEvaporationController.liveBarHost(for: $0) },
            afterLower: { target in
                AppDelegate.shared?.workspaceContainingPanel(
                    panelId: target.surfaceId,
                    preferredWorkspaceId: target.workspaceId
                )?.workspace.recheckMailboxDoorbellAfterFlagLower(surfaceId: target.surfaceId)
            }
        )
    }

    static let shared = FlagEvaporationController(hooks: .live, active: false)

    private let hooks: Hooks
    /// The live controller stays inert until `install()`; a test one starts active.
    private var active: Bool
    /// The service whose flags this controller lowers.
    weak var service: PanelAttentionService?
    private var tracker = FlagEvaporationTracker()
    private var cancelTimer: (() -> Void)?
    private var registryObserver: NSObjectProtocol?
    /// The view showing the bar, so a cancel reaches it after focus moved.
    private weak var barHost: FlagEvaporationBarHost?

    init(hooks: Hooks, active: Bool = true) {
        self.hooks = hooks
        self.active = active
    }

    func install() {
        guard !active else { return }
        active = true
        PanelSeenTracker.shared.onSeenChange = { [weak self] in self?.evaluate() }
        registryObserver = NotificationCenter.default.addObserver(
            forName: PanelFlagKindRegistry.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate()
    }

    /// A flag changed on `surfaceId`. Only the seen panel or the running one
    /// can change the outcome, so other panels cost one comparison.
    func attentionDidChange(surfaceId: UUID) {
        guard active else { return }
        guard surfaceId == tracker.run?.target.surfaceId
            || hooks.isSeen(surfaceId) else { return }
        evaluate()
    }

    /// Any accepted raise on `surfaceId`, including one that repeats the
    /// flag's own text and changes nothing in the store: the run restarts from
    /// zero (ruled: "a re-raise while focused restarts the timer").
    func raiseAccepted(surfaceId: UUID, runBefore: FlagEvaporationRun?) {
        guard active else { return }
        evaluate()
        // A raise that changed the flag already restarted the run through
        // `attentionDidChange`; restart only one that left it untouched.
        guard let run = tracker.run, run.target.surfaceId == surfaceId, run == runBefore else { return }
        apply(tracker.restart(now: hooks.now()))
    }

    var currentRun: FlagEvaporationRun? { tracker.run }

    /// A view that can show the bar mounted or replaced the one showing it:
    /// a markdown renderer's container took its web view (a first visit
    /// mounts it after the seen refresh), or a browser's web view joined a
    /// portal slot. The running bar moves there at the progress already made;
    /// the run's start and deadline stay. One check when nothing is running.
    func barHostDidMount() {
        guard active, tracker.run != nil else { return }
        adoptBarHost()
    }

    func evaluate() {
        apply(tracker.update(target: currentTarget(), now: hooks.now()))
    }

    private func currentTarget() -> FlagEvaporationTarget? {
        guard let seen = hooks.seenPanel() else { return nil }
        let attention = PanelAttentionIndex.shared.snapshot(
            workspaceId: seen.workspaceId,
            surfaceId: seen.surfaceId
        )
        // Read the registry only for a named flag: the common unflagged case
        // stays a dictionary lookup.
        guard attention.isFlagged, let kindId = attention.flagKind?.id else { return nil }
        return FlagEvaporationTarget.resolve(
            seen: seen,
            attention: attention,
            registryKind: hooks.registryKind(kindId)
        )
    }

    private func apply(_ step: FlagEvaporationStep) {
        switch step {
        case .idle:
            return
        case .keep:
            // A run that started before its host existed picks it up on any
            // later evaluation too, not only on the mount hook.
            if barHost == nil { adoptBarHost() }
        case .cancel:
            stopTimer()
            barHost?.cancelEvaporationBar()
            barHost = nil
        case .start(let run, _):
            stopTimer()
            barHost?.cancelEvaporationBar()
            barHost = nil
            adoptBarHost()
            schedule(at: run.deadline)
        }
    }

    /// Shows the running bar on the run's host when that host is not the one
    /// already showing it, filled to the share of the run already elapsed.
    private func adoptBarHost() {
        guard let run = tracker.run, let host = hooks.barHost(run.target), host !== barHost else { return }
        barHost?.cancelEvaporationBar()
        barHost = host
        let duration = TimeInterval(run.target.seconds)
        let elapsed = min(max(0, hooks.now().timeIntervalSince(run.startedAt)), duration)
        host.startEvaporationBar(
            color: Self.barColor(run.target.color, host: host),
            duration: duration,
            elapsed: elapsed
        )
    }

    private func schedule(at deadline: Date) {
        cancelTimer = hooks.schedule(deadline) { [weak self] in self?.timerFired() }
    }

    private func stopTimer() {
        cancelTimer?()
        cancelTimer = nil
    }

    private func timerFired() {
        cancelTimer = nil
        // Re-read the live state first: a missed focus change must never
        // lower a flag on a panel the operator no longer sees, and a revision
        // (new reason, kind or epoch) restarts the run here. Everything below
        // runs on the main actor with no suspension, so no raise can land
        // between this check and the lower; `expectedFlagEpoch` is a second
        // line of defence that catches a lower-and-raise, not a revision.
        evaluate()
        guard let run = tracker.takeDue(now: hooks.now()) else {
            // Fired a hair early: wait out the rest. A new run already has
            // its own timer from `apply`.
            if cancelTimer == nil, let run = tracker.run { schedule(at: run.deadline) }
            return
        }
        let host = barHost
        barHost = nil
        host?.prepareEvaporationFade()
        let result = try? (service ?? PanelAttentionService.shared).lower(
            workspaceId: run.target.workspaceId,
            surfaceId: run.target.surfaceId,
            by: .c11,
            expectedFlagEpoch: run.target.flagEpoch,
            cause: .evaporated
        )
        guard result?.applied[MetadataKey.flag] == true else {
            host?.cancelEvaporationBar()
            evaluate()
            return
        }
        host?.evaporationLowered()
        hooks.afterLower(run.target)
    }

    private static func liveBarHost(for target: FlagEvaporationTarget) -> FlagEvaporationBarHost? {
        guard let panel = AppDelegate.shared?.workspaceContainingPanel(
            panelId: target.surfaceId,
            preferredWorkspaceId: target.workspaceId
        )?.workspace.panels[target.surfaceId] else { return nil }
        if let terminal = panel as? TerminalPanel { return terminal.surface.hostedView }
        if let browser = panel as? BrowserPanel { return WindowBrowserSlotView.enclosing(browser.webView) }
        if let markdown = panel as? MarkdownPanel {
            return markdown.renderer?.webView.superview as? MarkdownWebViewContainer
        }
        return nil
    }

    private static func barColor(_ token: PanelFlagColorToken, host: FlagEvaporationBarHost) -> NSColor {
        let appearance = (host as? NSView)?.effectiveAppearance ?? NSApp.effectiveAppearance
        let light = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        return NSColor(hex: token.hex(lightBackground: light))
            ?? NSColor(red: 157.0 / 255.0, green: 138.0 / 255.0, blue: 217.0 / 255.0, alpha: 1)
    }
}

/// The bar on a host with no flag banner (browser, markdown): mounted on the
/// host's top edge, faded on its own when the flag evaporates.
@MainActor
final class FlagEvaporationBarMount {
    private(set) var bar: FlagEvaporationBarView?
    private var generation: UInt64 = 0

    func start(in host: NSView, above sibling: NSView?, color: NSColor, duration: TimeInterval, elapsed: TimeInterval) {
        generation &+= 1
        let bar: FlagEvaporationBarView
        if let existing = self.bar {
            bar = existing
        } else {
            bar = FlagEvaporationBarView(frame: .zero)
            self.bar = bar
        }
        bar.autoresizingMask = host.isFlipped ? [.width, .maxYMargin] : [.width, .minYMargin]
        if bar.superview !== host {
            bar.removeFromSuperview()
            host.addSubview(bar, positioned: .above, relativeTo: sibling)
        }
        bar.frame = FlagEvaporationBarView.topEdgeFrame(in: host.bounds, flipped: host.isFlipped)
        bar.start(color: color, duration: duration, elapsed: elapsed)
    }

    func cancel() {
        generation &+= 1
        bar?.cancel()
    }

    func fadeOut() {
        guard let bar, !bar.isHidden else { return }
        let generation = self.generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = FlagEvaporationBarView.fadeDuration
            bar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A run that started during the fade keeps its bar.
                guard let self, self.generation == generation else { return }
                bar.cancel()
            }
        })
    }

    /// Keep the bar above a view its host just added (markdown re-adds its web view).
    func keepAbove(_ added: NSView, in host: NSView) {
        guard let bar, added !== bar, bar.superview === host, host.subviews.last !== bar else { return }
        host.addSubview(bar, positioned: .above, relativeTo: nil)
    }
}

/// A thin bar along a panel's top edge that fills left to right. Overlay only:
/// it never changes the panel's geometry and never takes a click.
final class FlagEvaporationBarView: NSView {
    static let thickness: CGFloat = 3
    static let fadeDuration: TimeInterval = 0.25

    private let fill = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.actions = ["bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(fill)
        sizeFill()
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeFill()
    }

    /// Bounds and position, never frame: the fill carries a scale transform.
    private func sizeFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.bounds = CGRect(origin: .zero, size: bounds.size)
        fill.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
    }

    static func topEdgeFrame(in bounds: CGRect, flipped: Bool) -> CGRect {
        CGRect(x: 0, y: flipped ? 0 : max(0, bounds.height - thickness), width: bounds.width, height: thickness)
    }

    /// Fill linearly to full by the end of `duration`, starting from the
    /// `elapsed` share (a host that mounted mid-run). The model value is
    /// empty, so a sweep the layer ever drops reads as not started, never done;
    /// the finished sweep holds full until the lower fades it.
    func start(color: NSColor, duration: TimeInterval, elapsed: TimeInterval = 0) {
        // Replace a fade still in flight from the previous run.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = 1
        }
        alphaValue = 1
        isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = color.cgColor
        fill.removeAllAnimations()
        fill.transform = CATransform3DMakeScale(0, 1, 1)
        CATransaction.commit()
        let sweep = CABasicAnimation(keyPath: "transform.scale.x")
        let made = duration > 0 ? min(max(elapsed / duration, 0), 1) : 1
        sweep.fromValue = made
        sweep.toValue = 1
        sweep.duration = max(0.01, duration - elapsed)
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.fillMode = .forwards
        sweep.isRemovedOnCompletion = false
        fill.add(sweep, forKey: "evaporate")
    }

    /// The fill's model width as a fraction (0 empty, 1 full), what shows if
    /// the sweep animation is ever dropped.
    var modelProgress: CGFloat { fill.transform.m11 }

    /// Where the running sweep starts (0 for a fresh run), nil when none runs.
    var sweepStartProgress: Double? {
        ((fill.animation(forKey: "evaporate") as? CABasicAnimation)?.fromValue as? NSNumber)?.doubleValue
    }

    /// Empty the bar at once.
    func cancel() {
        fill.removeAllAnimations()
        isHidden = true
        alphaValue = 1
    }

}
