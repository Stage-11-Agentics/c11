import Foundation

/// Tracks live renderers across the app; the owner serializes access and tears them down.
/// Visibility is per panel, so selected panels in every area and window are protected.
struct MarkdownRendererRetentionPolicy: Sendable {
    static let defaultHiddenCapacity = 4

    let hiddenCapacity: Int
    private var oldestFirst: [UUID] = []
    private var visibleIDs: Set<UUID> = []
    private var pinnedIDs: Set<UUID> = []

    init(capacity: Int = Self.defaultHiddenCapacity) {
        self.hiddenCapacity = max(0, capacity)
    }

    /// Registers a newly created renderer as hidden. Re-registering is idempotent.
    mutating func insert(_ id: UUID) {
        guard !oldestFirst.contains(id) else { return }
        oldestFirst.append(id)
    }

    /// Records use, registering the renderer if needed.
    mutating func touch(_ id: UUID) {
        oldestFirst.removeAll { $0 == id }
        oldestFirst.append(id)
    }

    /// A visibility transition records use; repeated layout notifications do not.
    /// Unknown IDs are ignored, so late callbacks cannot resurrect removed renderers.
    mutating func setVisible(_ id: UUID, _ isVisible: Bool) {
        guard oldestFirst.contains(id), visibleIDs.contains(id) != isVisible else { return }
        if isVisible {
            visibleIDs.insert(id)
        } else {
            visibleIDs.remove(id)
        }
        touch(id)
    }

    /// Pin while a query or position capture is in flight. Pinning does not change recency.
    mutating func setPinned(_ id: UUID, _ isPinned: Bool) {
        guard oldestFirst.contains(id) else { return }
        if isPinned {
            pinnedIDs.insert(id)
        } else {
            pinnedIDs.remove(id)
        }
    }

    mutating func remove(_ id: UUID) {
        oldestFirst.removeAll { $0 == id }
        visibleIDs.remove(id)
        pinnedIDs.remove(id)
    }

    /// Oldest eligible hidden renderers needed to bring the total hidden count to the cap.
    /// Pinned hidden renderers consume capacity but cannot be candidates: if pins alone
    /// exceed the cap, every unpinned hidden renderer is eligible and the excess remains.
    /// This does not remove entries. After an asynchronous capture, the owner must check
    /// the current candidates again before teardown, then call remove after teardown.
    var evictionCandidates: [UUID] {
        let excess = max(0, oldestFirst.count - visibleIDs.count - hiddenCapacity)
        return Array(oldestFirst.lazy.filter {
            !visibleIDs.contains($0) && !pinnedIDs.contains($0)
        }.prefix(excess))
    }
}
