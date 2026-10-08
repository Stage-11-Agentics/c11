import Foundation
import Combine
import Bonsplit

/// Transient reading state survives WebKit eviction; durable preferences stay on the panel.
struct MarkdownReadingPosition: Equatable {
    var line: Int = 1
    var offset: Double = 0
    var sourceMode = false
    var findQuery = ""
    var findOpen = false

    init() {}
    init?(state: [String: Any]) {
        guard let lines = state["lines"] as? [String: Any], let line = lines["first"] as? Int else { return nil }
        self.line = max(1, line)
        let offset = lines["offset"] as? Double ?? 0
        self.offset = offset.isFinite ? min(max(offset, -1_000_000), 1_000_000) : 0
        sourceMode = state["mode"] as? String == "source"
        let find = state["find"] as? [String: Any]
        let query = find?["query"] as? String ?? ""
        findQuery = String(query.prefix(8192))
        findOpen = find?["open"] as? Bool ?? false
    }
}

/// The app keeps all visible readers plus four recently hidden readers. Capture
/// is asynchronous; visibility and query epochs are checked again before teardown.
@MainActor
final class MarkdownRendererCache {
    static let shared = MarkdownRendererCache()
    let evictions = PassthroughSubject<UUID, Never>()
    let visibilityChanges = PassthroughSubject<UUID, Never>()
    private var policy = MarkdownRendererRetentionPolicy()
    @MainActor private final class Entry {
        weak var panel: MarkdownPanel?
        weak var renderer: MarkdownWebRenderer?
        var epoch = 0
        var capture: UUID?
        init(_ panel: MarkdownPanel) { self.panel = panel; renderer = panel.renderer }
    }
    private var entries: [UUID: Entry] = [:]

    func register(_ panel: MarkdownPanel) {
        entries[panel.id] = Entry(panel)
        policy.insert(panel.id)
        policy.setVisible(panel.id, panel.isRendererVisible)
        reconsider()
    }

    func visibilityChanged(_ panel: MarkdownPanel) {
        guard let entry = entries[panel.id] else { return }
#if DEBUG
        if !panel.isRendererVisible, let renderer = panel.renderer,
           let position = MarkdownReadingPosition(state: renderer.state) {
            dlog("markdown.renderer.hidden panel=\(panel.id.uuidString) line=\(position.line) offset=\(position.offset) width=\(renderer.webView.frame.width) height=\(renderer.webView.frame.height)")
        }
#endif
        entry.epoch += 1
        policy.setVisible(panel.id, panel.isRendererVisible)
        visibilityChanges.send(panel.id)
        reconsider()
    }

    func queryStarted(_ panel: MarkdownPanel) {
        guard let entry = entries[panel.id] else { return }
        entry.epoch += 1
        policy.setPinned(panel.id, true)
    }

    func queryFinished(_ panel: MarkdownPanel) {
        guard entries[panel.id] != nil else { return }
        policy.setPinned(panel.id, panel.renderer?.hasQueriesInFlight == true)
        reconsider()
    }

    func remove(_ panel: MarkdownPanel) {
        entries.removeValue(forKey: panel.id)
        policy.remove(panel.id)
        reconsider()
    }

    func reconsider() {
        for (id, entry) in entries where entry.panel == nil {
            entry.renderer?.close()
            entries.removeValue(forKey: id)
            policy.remove(id)
        }
        for id in policy.evictionCandidates {
            guard let entry = entries[id], entry.capture == nil,
                  let panel = entry.panel, let renderer = panel.renderer,
                  !renderer.hasQueriesInFlight, renderer.canCaptureReadingPosition else { continue }
            let token = UUID(), epoch = entry.epoch
            entry.capture = token
            renderer.captureReadingPosition { [weak self, weak panel, weak renderer] position in
                guard let self, let panel, let renderer,
                      let current = self.entries[id], current.capture == token else { return }
                current.capture = nil
                if current.epoch == epoch, !panel.isRendererVisible,
                   !renderer.hasQueriesInFlight, panel.renderer === renderer,
                   self.policy.evictionCandidates.contains(id) {
                    self.entries.removeValue(forKey: id)
                    self.policy.remove(id)
                    panel.evictRenderer(renderer, position: position)
                    self.evictions.send(id)
#if DEBUG
                    dlog("markdown.renderer.evicted panel=\(id.uuidString) line=\(position.line) offset=\(position.offset) source=\(position.sourceMode ? 1 : 0) width=\(renderer.webView.frame.width) height=\(renderer.webView.frame.height)")
#endif
                }
                self.reconsider()
            }
        }
    }
}
