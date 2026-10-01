import AppKit
import Bonsplit
import Combine
import SwiftUI

/// AppKit host for the pane-interaction SwiftUI card. Used by every mount layer
/// where SwiftUI-only overlays can't sit above the content (terminal portal,
/// WebView-backed browser portal) because those contents are AppKit-hosted on
/// top of the SwiftUI view tree.
///
/// The host:
/// - Wraps `PaneInteractionCardView` inside an `NSHostingView` sized to fill its bounds.
/// - Becomes first responder while visible so terminal / WebView key routing stops
///   (their surface views lose first-responder status) — the plan's focus-choke-point
///   contract (§3.3, §4.7) leans on this.
/// - Blocks hit-testing everywhere inside its bounds, preventing scrim-through clicks
///   while still letting the card's buttons work.
/// - Subscribes to the provided `PaneInteractionRuntime.$active` stream and shows /
///   hides / rebuilds the root view automatically for a given `panelId`.
@MainActor
final class PaneInteractionOverlayHost: NSView {

    let panelId: UUID
    let runtime: PaneInteractionRuntime
    private var hostingView: NSHostingView<PaneInteractionCardView>?
    private var cancellable: AnyCancellable?
    private var textInputSelectionCancellable: AnyCancellable?
    /// Responder to restore when the overlay hides. Captured on show so the
    /// terminal / browser view that had focus before the dialog regains it
    /// without requiring a manual click (synthesis-critical §2.10).
    private weak var priorFirstResponder: NSResponder?
    /// Last textInput selection we acted on — used to detect `.field` transitions
    /// so we don't repeatedly call `makeFirstResponder` on the same target.
    private var lastTextInputSelection: TextInputSelectionField?

    init(panelId: UUID, runtime: PaneInteractionRuntime) {
        self.panelId = panelId
        self.runtime = runtime
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        isHidden = true

        cancellable = runtime.$active
            .receive(on: RunLoop.main)
            .sink { [weak self] active in
                self?.apply(interaction: active[panelId])
            }
        textInputSelectionCancellable = runtime.$textInputSelection
            .receive(on: RunLoop.main)
            .sink { [weak self] selections in
                self?.applyTextInputSelection(selections[panelId])
            }
        apply(interaction: runtime.active[panelId])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hit testing / focus

    override func hitTest(_ point: NSPoint) -> NSView? {
        // While hidden, pass through entirely so the underlying terminal / WebView
        // receives mouse events normally.
        guard !isHidden else { return nil }
        // While visible, swallow all clicks in our bounds so the scrim acts as a
        // modal barrier. The NSHostingView's own hit testing delivers button
        // presses correctly when they land inside the card.
        return super.hitTest(point) ?? self
    }

    override var acceptsFirstResponder: Bool { !isHidden }

    override func becomeFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }

    // Clicks on the scrim (outside the card): for `.textInput` cards, a click
    // on the scrim should move selection off `.field` — the user's way of
    // saying "I'm done editing, arrow keys should drive the buttons now."
    // Clicks still don't dismiss the dialog (modal barrier contract).
    override func mouseDown(with event: NSEvent) {
        if case .textInput? = runtime.active[panelId] {
            runtime.setTextInputSelection(panelId: panelId, .confirm)
        }
    }
    override func mouseUp(with event: NSEvent) { /* swallow */ }
    override func rightMouseDown(with event: NSEvent) { /* swallow */ }

    // Arrow / Tab / Return / Escape routing for pane-interaction cards. SwiftUI
    // `onKeyPress` inside the hosted card never fires because this NSView owns
    // first responder (the card has no focused SwiftUI anchor).
    //
    // keyCode values: left=123, right=124, tab=48, return=36, numpad enter=76.
    override func keyDown(with event: NSEvent) {
        guard !isHidden else {
            super.keyDown(with: event)
            return
        }
        if runtime.handleKeyDown(
            panelId: panelId,
            keyCode: Int(event.keyCode),
            shift: event.modifierFlags.contains(.shift)
        ) {
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Content

    private func apply(interaction: PaneInteraction?) {
        if let interaction {
            let rootView = PaneInteractionCardView(
                panelId: panelId,
                interaction: interaction,
                runtime: runtime
            )
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
                // Capture the prior first responder on first show so we can
                // restore it when the overlay hides. Don't overwrite on
                // subsequent `apply` calls (queue advance) — we want the
                // responder from before the FIRST card appeared.
                if wasHidden {
                    capturePriorFirstResponderIfNeeded(in: window)
                }
                requestKeyboardFocus(reason: "apply")
            }
        } else {
            isHidden = true
            hostingView?.removeFromSuperview()
            hostingView = nil
            // Restore whoever had focus before we took it. If the responder
            // has since been torn down (panel close during dialog), fall
            // back to nil so the window's next-responder chain can resolve.
            if let window {
                if let prior = priorFirstResponder, prior.acceptsFirstResponder {
                    window.makeFirstResponder(prior)
                } else {
                    window.makeFirstResponder(nil)
                }
            }
            priorFirstResponder = nil
            lastTextInputSelection = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !isHidden, runtime.active[panelId] != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.requestKeyboardFocus(reason: "viewDidMoveToWindow")
        }
    }

    /// Take first responder for the overlay, retrying if the current responder
    /// refuses to resign. WKWebView-hosted WebContentView refuses
    /// `resignFirstResponder` in common states (focused form field, active IME
    /// composition, etc.). When that happens, Return / arrow / Tab routed to the
    /// leftover WKWebView responder — manifesting as "pressing Enter on a pane
    /// close dialog refreshes the adjacent browser pane" and arrow/tab keys
    /// failing to navigate the dialog buttons. Clearing the responder chain
    /// with `makeFirstResponder(nil)` and retrying gets past that veto; a final
    /// async retry covers the case where release only lands after the current
    /// event completes.
    private func forciblyAcquireFirstResponder(in window: NSWindow) {
        if window.firstResponder === self { return }
        if window.makeFirstResponder(self) { return }
#if DEBUG
        dlog(
            "paneInteraction.focus firstResponderSteal failed=1 prior=" +
            String(describing: window.firstResponder.map { type(of: $0) })
        )
#endif
        window.makeFirstResponder(nil)
        if window.makeFirstResponder(self) { return }
#if DEBUG
        dlog("paneInteraction.focus firstResponderSteal retryAfterNil failed=1")
#endif
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
        if let hostingView,
           let textField = (prior as? NSTextView)?.delegate as? NSTextField,
           textField.isDescendant(of: hostingView) {
            return
        }
        priorFirstResponder = prior
    }

    /// Ensure the visible interaction owns the relevant keyboard target. Confirm
    /// cards use the overlay host itself; text-input cards keep the field editor
    /// as first responder while `.field` is selected.
    @discardableResult
    func requestKeyboardFocus(reason: String) -> Bool {
        guard !isHidden, runtime.active[panelId] != nil, let window else { return false }
        capturePriorFirstResponderIfNeeded(in: window)
        if case .textInput? = runtime.active[panelId],
           runtime.textInputSelection[panelId] == .field,
           let textField = findTextField(in: hostingView) {
            if window.firstResponder === textField ||
                ((window.firstResponder as? NSTextView)?.delegate as? NSTextField) === textField {
                return true
            }
            return window.makeFirstResponder(textField)
        }
        forciblyAcquireFirstResponder(in: window)
#if DEBUG
        if window.firstResponder !== self {
            dlog(
                "paneInteraction.focus requestFailed reason=\(reason) responder=" +
                String(describing: window.firstResponder.map { type(of: $0) })
            )
        }
#endif
        return window.firstResponder === self
    }

    /// Mirror the runtime's textInput selection into AppKit responder state.
    /// `.field`  → find the embedded NSTextField and make it first responder.
    /// `.cancel` / `.confirm` → take responder ourselves so keyDown routes
    /// arrow/tab/return to the selected button.
    private func applyTextInputSelection(_ selection: TextInputSelectionField?) {
        guard let selection else {
            lastTextInputSelection = nil
            return
        }
        guard case .textInput? = runtime.active[panelId], !isHidden else { return }
        if lastTextInputSelection == selection { return }
        lastTextInputSelection = selection
        switch selection {
        case .field:
            _ = requestKeyboardFocus(reason: "textInputSelection.field")
        case .cancel, .confirm:
            _ = requestKeyboardFocus(reason: "textInputSelection.button")
        }
    }

    private func findTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField { return tf }
        for sub in view.subviews {
            if let tf = findTextField(in: sub) { return tf }
        }
        return nil
    }

    // MARK: - Lifecycle

    deinit {
        cancellable?.cancel()
        textInputSelectionCancellable?.cancel()
    }
}
