import AppKit
import Foundation
import WebKit

/// Per-surface snapshot of a hibernated browser surface.
///
/// Captured before the WebContent process is torn down so the panel can
/// render a placeholder image (instead of a blank rectangle) until the
/// operator resumes the workspace.
///
/// All fields are best-effort:
/// - `image` may be nil if `WKWebView.takeSnapshot` returns nil (rare;
///   typically only when the webview has zero size).
/// - `url` is the webview's current URL at capture time. Used to refire
///   `load(URLRequest:)` on resume.
/// - `scrollY` is read via `evaluateJavaScript("window.scrollY")` and is
///   replayed via JS on the resumed page's `didFinish` callback.
struct BrowserSurfaceSnapshot {
    let image: NSImage?
    let url: URL?
    let scrollY: CGFloat?
    let capturedAt: Date
}

/// In-memory store of per-surface browser snapshots used by the C11-25
/// ARC-grade hibernate tier.
///
/// Keyed by surface UUID. Populated by `capture(...)` before the
/// WebContent process is torn down; consumed by the placeholder render
/// path in `BrowserPanelView` and by the resume path that recreates the
/// WKWebView with the captured URL + scrollY.
///
/// Snapshots are NOT persisted across app launches in C11-25 — a
/// hibernated workspace restored from disk renders a neutral placeholder
/// until the operator resumes (C11-25 commit 8 wires the `lifecycle_state`
/// metadata through the snapshot/restore path so the lifecycle survives;
/// the IMAGE itself is in-memory-only for this PR — operator accepted
/// in §0a).
@MainActor
final class BrowserSnapshotStore {
    static let shared = BrowserSnapshotStore()

    private var snapshots: [UUID: BrowserSurfaceSnapshot] = [:]

    private init() {}

    /// Capture the current visible state of `webView` and store it under
    /// `surfaceId`. Calls `completion` on the main queue once all
    /// best-effort captures complete.
    ///
    /// The image is captured via `WKWebView.takeSnapshot(with:)` (public
    /// API); URL is read synchronously; scrollY is captured via JS.
    /// Each leg is independent — a failure in one does not abort the
    /// others. If the webview is in a degenerate state (zero bounds,
    /// no URL, JS bridge broken), the snapshot is still stored and the
    /// placeholder render path falls back to a neutral background.
    ///
    /// `fallbackURL` is used when `webView.url` is nil at capture time
    /// (e.g. restore-time hibernate fires before the freshly-mounted
    /// webview has finished its initial navigation). Without it, resume
    /// would have no URL to navigate back to.
    func capture(
        surfaceId: UUID,
        webView: WKWebView,
        fallbackURL: URL? = nil,
        completion: @escaping (BrowserSurfaceSnapshot) -> Void
    ) {
        let url = webView.url ?? fallbackURL
        let group = DispatchGroup()
        var capturedImage: NSImage?
        var capturedScrollY: CGFloat?

        group.enter()
        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.afterScreenUpdates = false
        webView.takeSnapshot(with: snapshotConfig) { image, _ in
            capturedImage = image
            group.leave()
        }

        group.enter()
        webView.evaluateJavaScript("window.scrollY") { result, _ in
            if let n = result as? NSNumber {
                capturedScrollY = CGFloat(n.doubleValue)
            }
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            let snapshot = BrowserSurfaceSnapshot(
                image: capturedImage,
                url: url,
                scrollY: capturedScrollY,
                capturedAt: Date()
            )
            self?.snapshots[surfaceId] = snapshot
            completion(snapshot)
        }
    }

    /// Direct-set used during snapshot/restore (C11-25 commit 8) when the
    /// image itself isn't available — the metadata says the surface was
    /// hibernated but the in-memory image cache is empty after a restart.
    /// Stores a metadata-only snapshot so the placeholder path renders a
    /// neutral background instead of the empty webview.
    func storeMetadataOnly(surfaceId: UUID, url: URL?) {
        snapshots[surfaceId] = BrowserSurfaceSnapshot(
            image: nil,
            url: url,
            scrollY: nil,
            capturedAt: Date()
        )
    }

    /// Look up a snapshot for a given surface. Returns nil when no
    /// hibernate has been performed (or when the cache was cleared on
    /// resume).
    func snapshot(forSurfaceId id: UUID) -> BrowserSurfaceSnapshot? {
        return snapshots[id]
    }

    /// Drop the cached snapshot. Called on resume after the WKWebView
    /// has been recreated and the placeholder is no longer needed.
    func clear(forSurfaceId id: UUID) {
        snapshots.removeValue(forKey: id)
    }
}

// MARK: - WebContent process identification (SPI)

/// Access to `_webProcessIdentifier`, the WKWebView SPI returning the pid
/// of the underlying WebContent process. Used by the ARC-grade hibernate
/// tier (forceful SIGTERM fallback when graceful release does not reap
/// the process) and by the per-surface CPU/MEM sampler (C11-25 commit 6).
///
/// SPI usage approved for C11-25 by the operator (2026-05-04). The
/// existing c11 codebase uses similar private-selector access in several
/// other paths.
extension WKWebView {
    /// Returns the pid of the WebContent process backing this webview, or
    /// nil when the SPI is unavailable (would mean the WebKit framework
    /// changed shape — log once and degrade gracefully) or when no
    /// process is currently bound.
    var c11_webProcessIdentifier: pid_t? {
        let key = "_webProcessIdentifier"
        guard responds(to: NSSelectorFromString(key)) else { return nil }
        guard let raw = value(forKey: key) as? NSNumber else { return nil }
        let pid = raw.int32Value
        return pid > 0 ? pid : nil
    }
}

// MARK: - WebContent termination helper

/// Tear down a WKWebView's WebContent process. Used by the ARC-grade
/// hibernate path — captures the snapshot first, then calls this helper
/// to release the live process.
@MainActor
enum BrowserWebContentTerminator {
    /// Outcome of a teardown attempt — surfaced for logging and DoD
    /// verification.
    enum Result {
        /// Graceful teardown only — `stopLoading + delegates nil` was
        /// performed; ARC will reap the WebContent process when the last
        /// strong reference to the WKWebView drops.
        case graceful
        /// Forceful — graceful path was performed, AND we sent SIGTERM to
        /// the WebContent pid because we observed it was still alive.
        /// Currently unused in C11-25; reserved as a fallback the panel
        /// can invoke if RSS measurement during validation shows the
        /// process is not being reaped.
        case sigterm(pid: pid_t)
        /// No WebContent process was bound — webview was already inert.
        case noProcess
    }

    /// Graceful teardown. Stops loading, nils delegates, removes from
    /// superview. The caller should release its strong reference to the
    /// WKWebView immediately after this returns; ARC then reaps the
    /// WebContent process. C11-25 validation will measure RSS to confirm.
    @discardableResult
    static func tearDownGracefully(_ webView: WKWebView) -> Result {
        let pid = webView.c11_webProcessIdentifier
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        if pid != nil {
            return .graceful
        }
        return .noProcess
    }

    /// Send SIGTERM to the WebContent process. ONLY for the fallback
    /// path when the graceful teardown has not reaped the process within
    /// a measurement window. The pid is read via the
    /// `_webProcessIdentifier` SPI; if the SPI returns nil (rare), this
    /// is a no-op. Logs the action for forensic review.
    @discardableResult
    static func forceTerminateWebContentProcess(_ webView: WKWebView) -> Result {
        guard let pid = webView.c11_webProcessIdentifier else {
            return .noProcess
        }
        let rc = kill(pid, SIGTERM)
        #if DEBUG
        NSLog("[c11.lifecycle] forceTerminateWebContentProcess pid=\(pid) rc=\(rc)")
        #else
        _ = rc
        #endif
        return .sigterm(pid: pid)
    }
}
