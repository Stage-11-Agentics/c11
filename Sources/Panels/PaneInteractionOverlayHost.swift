import AppKit
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

    // Prevent background mouseDown (on the scrim) from stealing focus back from
    // whatever child view currently needs it — the card manages its own focus.
    override func mouseDown(with event: NSEvent) { /* swallow */ }
    override func mouseUp(with event: NSEvent) { /* swallow */ }
    override func rightMouseDown(with event: NSEvent) { /* swallow */ }

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
            isHidden = false
            if let window {
                window.makeFirstResponder(self)
            }
        } else {
            isHidden = true
            hostingView?.removeFromSuperview()
            hostingView = nil
        }
    }

    // MARK: - Lifecycle

    deinit {
        cancellable?.cancel()
    }
}
