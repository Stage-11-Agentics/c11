import Foundation

/// Per-surface lifecycle state.
///
/// One of four discrete states, mirrored to canonical metadata under
/// `lifecycle_state` so that the sidebar, `c11 tree --json`, the socket,
/// and `c11 snapshot` / `restore` can observe it without coupling to
/// runtime Swift state.
///
/// State semantics (per the C11-25 plan):
///
/// - `active` — workspace selected, full-rate render, full input. The
///   surface is occluded=false / not-visible=false; libghostty drives
///   CVDisplayLink at full rate.
/// - `throttled` — workspace deselected. Terminals: surface is marked
///   occluded (`ghostty_surface_set_occlusion(visible=false)` →
///   libghostty pauses CVDisplayLink wakeups while the PTY continues
///   to drain). Browsers: WKWebView detached from the host view
///   hierarchy (cheap-tier suspension).
/// - `suspended` — reserved-only metadata value with NO accepting
///   transitions. The metadata validator rejects writes of this value
///   (see I4 review fix); kept in the enum so future PRs can wire it
///   without a schema migration but never enters runtime in C11-25.
/// - `hibernated` — operator-explicit. Browsers: WKWebView snapshot to
///   NSImage placeholder + WebContent process termination (ARC-grade).
///   Terminals: same throttle behavior as `throttled` (PTY drains;
///   SIGSTOP'ing the child is deferred). Survives c11 snapshot/restore;
///   only resumed by an operator action ("Resume Workspace").
///
/// Transition table:
///
///     active        → throttled, hibernated
///     throttled     → active,    hibernated
///     hibernated    → active
///     suspended     → (none — reserved; rejected at validator)
///     * → suspended → (none — reserved; rejected at validator)
///
/// Self-transitions (X → X) are accepted as a no-op so dispatchers can
/// idempotently call `transition(to:)` on every workspace-visibility tick
/// without bouncing the metadata store.
public enum SurfaceLifecycleState: String, Sendable, CaseIterable {
    case active
    case throttled
    case suspended
    case hibernated

    /// Canonical metadata key the state is mirrored to.
    public static let metadataKey = "lifecycle_state"

    /// Maximum length of the metadata string value. The longest case
    /// (`hibernated`) is 10 chars; the cap is 32 to leave headroom and
    /// match the `status` key's existing convention.
    public static let metadataMaxLength = 32

    /// Returns true if transitioning from `self` to `target` is allowed.
    ///
    /// Self-transitions are always allowed (idempotent no-op). Transitions
    /// into or out of `.suspended` are rejected in C11-25; the state is
    /// reserved for future PRs.
    public func canTransition(to target: SurfaceLifecycleState) -> Bool {
        if self == target { return true }
        switch (self, target) {
        case (.active, .throttled),
             (.throttled, .active),
             (.active, .hibernated),
             (.throttled, .hibernated),
             (.hibernated, .active):
            return true
        case (_, .suspended), (.suspended, _):
            return false
        default:
            return false
        }
    }

    /// True when the surface is operator-pinned to a non-active state and
    /// must not auto-resume on workspace selection. Only `hibernated`
    /// satisfies this in C11-25 — `throttled` rehydrates automatically on
    /// selection, and `suspended` is reserved.
    public var isOperatorPinned: Bool {
        switch self {
        case .hibernated: return true
        case .active, .throttled, .suspended: return false
        }
    }
}

/// Owns a surface's current `SurfaceLifecycleState`, gates transitions
/// through the validator, mirrors them to canonical metadata, and fires
/// a handler so panels can dispatch the AppKit-side work
/// (detach/bind WebView, set-occlusion, snapshot/terminate, …).
///
/// Lives on the panel/controller layer (TerminalPanel, BrowserPanel),
/// not the surface view, per plan §1.3 — the view is too low-level and
/// the panel is where workspace-visibility input arrives.
@MainActor
final class SurfaceLifecycleController {
    typealias Handler = (_ from: SurfaceLifecycleState, _ to: SurfaceLifecycleState) -> Void

    private(set) var workspaceId: UUID
    let surfaceId: UUID
    private(set) var state: SurfaceLifecycleState
    private let onTransition: Handler
    /// Reentrancy guard. The current dispatch graph is shallow — handlers
    /// run synchronously and don't loop back into `transition` — but if a
    /// future handler does (e.g. a hibernate-fail rollback), recursive
    /// re-entry would be hard to diagnose. Cheap insurance.
    private var isTransitioning = false

    init(
        workspaceId: UUID,
        surfaceId: UUID,
        initial: SurfaceLifecycleState = .active,
        onTransition: @escaping Handler
    ) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.state = initial
        self.onTransition = onTransition
    }

    /// Reparent the controller to a new workspace. Subsequent metadata
    /// writes flow to the new workspace; old-workspace metadata is left
    /// alone (prunes when the surface entry closes).
    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        self.workspaceId = newWorkspaceId
    }

    /// Transition to `target`. Returns whether the transition was applied.
    ///
    /// Behavior:
    /// - Rejects (returns `false`) if the validator forbids the transition.
    /// - Idempotent same-state calls return `true` without firing the handler
    ///   or writing metadata.
    /// - On a real transition, writes the new state to
    ///   `SurfaceMetadataStore` under `lifecycle_state` (default source
    ///   `.explicit` — operator/agent intent), then invokes the handler.
    /// - Reentrant calls from inside the handler are rejected (returns
    ///   `false`); a debug `assertionFailure` flags them in DEBUG so they
    ///   surface in tests.
    @discardableResult
    func transition(to target: SurfaceLifecycleState, source: MetadataSource = .explicit) -> Bool {
        if isTransitioning {
            assertionFailure(
                "SurfaceLifecycleController.transition reentered while a prior transition is in flight"
            )
            return false
        }
        guard state.canTransition(to: target) else { return false }
        if state == target { return true }
        let prior = state
        state = target
        SurfaceMetadataStore.shared.setInternal(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            key: SurfaceLifecycleState.metadataKey,
            value: target.rawValue,
            source: source
        )
        isTransitioning = true
        defer { isTransitioning = false }
        onTransition(prior, target)
        return true
    }
}
