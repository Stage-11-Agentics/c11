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

    // Arrow / Tab / Return routing for `.confirm` cards. SwiftUI `onKeyPress`
    // inside the hosted card never fires because this NSView owns first
    // responder (the card has no focused SwiftUI anchor). Esc + Space still
    // flow through `.keyboardShortcut` on the buttons via AppKit's command
    // chain, so only the keys without shortcut bindings need handling here.
    //
    // keyCode values: left=123, right=124, tab=48, return=36, numpad enter=76.
    override func keyDown(with event: NSEvent) {
        guard !isHidden else {
            super.keyDown(with: event)
            return
        }
        switch runtime.active[panelId] {
        case .confirm?:
            switch Int(event.keyCode) {
            case 123:
                runtime.moveConfirmSelection(panelId: panelId, direction: .left)
            case 124:
                runtime.moveConfirmSelection(panelId: panelId, direction: .right)
            case 48:
                runtime.moveConfirmSelection(panelId: panelId, direction: .toggle)
            case 36, 76:
                runtime.acceptSelectedConfirm(panelId: panelId)
            default:
                super.keyDown(with: event)
            }
        case .textInput?:
            // This path only fires when the overlay host has first responder
            // (selection is .cancel or .confirm). The text field intercepts
            // Tab itself to leave `.field`; keys while .field-focused go to
            // the field's editor, not here.
            let shift = event.modifierFlags.contains(.shift)
            switch Int(event.keyCode) {
            case 123:
                runtime.moveTextInputSelection(panelId: panelId, direction: .left)
            case 124:
                runtime.moveTextInputSelection(panelId: panelId, direction: .right)
            case 48:
                runtime.cycleTextInputSelection(panelId: panelId, backward: shift)
            case 36, 76:
                runtime.acceptSelectedTextInput(panelId: panelId)
            default:
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
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
                if wasHidden, priorFirstResponder == nil,
                   let prior = window.firstResponder, prior !== self {
                    priorFirstResponder = prior
                }
                forciblyAcquireFirstResponder(in: window)
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
        guard let window else { return }
        switch selection {
        case .field:
            if let textField = findTextField(in: hostingView) {
                window.makeFirstResponder(textField)
            }
        case .cancel, .confirm:
            forciblyAcquireFirstResponder(in: window)
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
