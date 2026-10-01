import AppKit
import Combine
import SwiftUI

/// AppKit host for the workspace-scoped close-confirmation card.
///
/// Mirrors `PaneInteractionOverlayHost` but at workspace scope and without
/// the multi-interaction runtime apparatus. The host:
/// - Paints a near-black scrim (`BrandColors.black` @ 0.85 alpha) covering
///   its bounds via its own layer; `NSHostingView<WorkspaceCloseCardView>`
///   renders the centered card on top.
/// - Swallows hit testing while visible so the scrim acts as a modal barrier.
/// - Becomes first responder while visible and routes Esc → cancel,
///   Return / numpad-enter → confirm.
/// - Captures the prior first responder on first show and restores it on
///   hide — same WKWebView resign-veto retry as the pane-close host.
/// - Fades in / out via `alphaValue` (120-180ms) to keep the destructive
///   action's appearance deliberate without stalling the user.
@MainActor
final class WorkspaceCloseOverlayHost: NSView {

    let runtime: WorkspaceCloseInteractionRuntime
    private var hostingView: NSHostingView<WorkspaceCloseCardView>?
    private var cancellable: AnyCancellable?
    private weak var priorFirstResponder: NSResponder?

    init(runtime: WorkspaceCloseInteractionRuntime) {
        self.runtime = runtime
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = BrandColors.black.withAlphaComponent(0.85).cgColor
        autoresizingMask = [.width, .height]
        alphaValue = 0.0
        isHidden = true
        setAccessibilityLabel(
            String(
                localized: "accessibility.closeWorkspaceOverlay.label",
                defaultValue: "Close workspace confirmation"
            )
        )
        setAccessibilityHelp(
            String(
                localized: "accessibility.closeWorkspaceOverlay.hint",
                defaultValue: "Use the arrow keys or Tab to choose a button, then press Return. Escape cancels."
            )
        )

        cancellable = runtime.$active
            .receive(on: RunLoop.main)
            .sink { [weak self] content in
                self?.apply(content: content)
            }
        apply(content: runtime.active)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hit testing / focus

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point) ?? self
    }

    override var acceptsFirstResponder: Bool { !isHidden }

    override func mouseDown(with event: NSEvent) { /* swallow */ }
    override func mouseUp(with event: NSEvent) { /* swallow */ }
    override func rightMouseDown(with event: NSEvent) { /* swallow */ }

    /// Route arrow / Tab / Return / Esc through the runtime's selection
    /// handler. Cancel is selected on present so Return falls into the safe
    /// path; a deliberate arrow/Tab move is required to confirm the
    /// destructive action. Mirrors `PaneInteractionOverlayHost` so the two
    /// dialogs share keyboard behavior.
    override func keyDown(with event: NSEvent) {
        guard !isHidden, runtime.active != nil else {
            super.keyDown(with: event)
            return
        }
        if runtime.handleKeyDown(
            keyCode: Int(event.keyCode),
            shift: event.modifierFlags.contains(.shift)
        ) {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Content

    private func apply(content: ConfirmContent?) {
        if let content {
            let rootView = WorkspaceCloseCardView(content: content, runtime: runtime)
            if let hostingView {
                hostingView.rootView = rootView
            } else {
                let hv = NSHostingView(rootView: rootView)
                hv.frame = bounds
                hv.autoresizingMask = [.width, .height]
                addSubview(hv)
                hostingView = hv
            }
            let wasHidden = isHidden
            isHidden = false
            if let window {
                if wasHidden {
                    capturePriorFirstResponderIfNeeded(in: window)
                }
                forciblyAcquireFirstResponder(in: window)
            }
            if wasHidden {
                fadeIn()
            }
        } else {
            fadeOut { [weak self] in
                guard let self else { return }
                self.isHidden = true
                self.hostingView?.removeFromSuperview()
                self.hostingView = nil
                if let window = self.window {
                    if let prior = self.priorFirstResponder, prior.acceptsFirstResponder {
                        window.makeFirstResponder(prior)
                    } else {
                        window.makeFirstResponder(nil)
                    }
                }
                self.priorFirstResponder = nil
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !isHidden, runtime.active != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            self.forciblyAcquireFirstResponder(in: window)
        }
    }

    // MARK: - Fade

    private func fadeIn() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = 1.0
        }
    }

    private func fadeOut(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            ctx.completionHandler = completion
            self.animator().alphaValue = 0.0
        }
    }

    // MARK: - First responder dance

    /// Take first responder for the overlay, retrying if the current responder
    /// refuses to resign. WKWebView-hosted WebContentView refuses
    /// `resignFirstResponder` in common states; clearing the responder chain
    /// with `makeFirstResponder(nil)` and retrying gets past that veto.
    /// Mirrors `PaneInteractionOverlayHost.forciblyAcquireFirstResponder`.
    private func forciblyAcquireFirstResponder(in window: NSWindow) {
        if window.firstResponder === self { return }
        if window.makeFirstResponder(self) { return }
        window.makeFirstResponder(nil)
        if window.makeFirstResponder(self) { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isHidden, let window = self.window else { return }
            if window.firstResponder === self { return }
            window.makeFirstResponder(nil)
            _ = window.makeFirstResponder(self)
        }
    }

    private func capturePriorFirstResponderIfNeeded(in window: NSWindow) {
        guard priorFirstResponder == nil,
              let prior = window.firstResponder,
              prior !== self
        else { return }
        if let hostingView,
           let priorView = prior as? NSView,
           priorView.isDescendant(of: hostingView) {
            return
        }
        priorFirstResponder = prior
    }

    // MARK: - Lifecycle

    deinit {
        cancellable?.cancel()
    }
}
