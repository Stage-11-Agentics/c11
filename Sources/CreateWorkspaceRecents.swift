import Foundation

// MARK: - Recents data model (C11-240)

/// One entry in the recents ring. Persisted as JSON in UserDefaults so we can
/// carry richer metadata (open count, last-opened timestamp, pin state) than
/// the legacy `[String]` representation. The legacy key is migrated on first
/// load.
///
/// `pinned` is a mirror: the ordered pins list (`CreateWorkspaceRecents.pinsKey`)
/// is the source of truth. The flag is still written so builds that predate the
/// pins key read the same pins.
struct RecentDirectory: Codable, Equatable, Identifiable {
    var path: String
    var lastOpenedAt: Date
    var openCount: Int
    var pinned: Bool

    var id: String { path }

    var displayName: String {
        let expanded = (path as NSString).expandingTildeInPath
        let last = URL(fileURLWithPath: expanded).lastPathComponent
        return last.isEmpty ? path : last
    }
}

/// Path helpers shared by the store, the sheet, and the CLI resolver.
enum RecentsPath {
    /// The one normal form for a recents key: whitespace trimmed, `~`
    /// expanded, `.`/`..`/`//` collapsed, trailing slash stripped. Symlinks are
    /// not resolved. The workspace root directory is standardized the same way,
    /// so the already-open match compares like with like.
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        var standardized = (expanded as NSString).standardizingPath
        while standardized.count > 1, standardized.hasSuffix("/") {
            standardized.removeLast()
        }
        return standardized
    }

    /// Absolute path with the home directory shown as `~`.
    static func displayPath(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Last path component of a display or absolute path (`~` for home).
    static func lastComponent(_ path: String) -> String {
        var s = Substring(path)
        while s.count > 1, s.hasSuffix("/") { s = s.dropLast() }
        guard let slash = s.lastIndex(of: "/") else { return String(s) }
        let tail = s[s.index(after: slash)...]
        return tail.isEmpty ? String(s) : String(tail)
    }

    /// Everything before the last component, without the trailing slash
    /// (`""` when there is no parent).
    static func parent(_ path: String) -> String {
        var s = Substring(path)
        while s.count > 1, s.hasSuffix("/") { s = s.dropLast() }
        guard let slash = s.lastIndex(of: "/") else { return "" }
        if slash == s.startIndex { return "" }
        return String(s[..<slash])
    }
}

/// Persistent ring of working directories the operator has previously used to
/// spawn a workspace, plus the ordered pins list.
enum CreateWorkspaceRecents {
    static let storageKey = "createWorkspace.recents.v2"
    static let pinsKey    = "createWorkspace.pins.v1"
    static let legacyKey  = "createWorkspace.recentDirectories"
    static let maxCount   = 250

    /// Recents plus the ordered pins. `entries[i].pinned` always equals
    /// `pins.contains(entries[i].path)`.
    struct State: Equatable {
        var entries: [RecentDirectory]
        var pins: [String]

        init(entries: [RecentDirectory] = [], pins: [String] = []) {
            self.entries = entries
            self.pins = pins
            syncPinnedFlags()
        }

        mutating func syncPinnedFlags() {
            let set = Set(pins)
            for i in entries.indices { entries[i].pinned = set.contains(entries[i].path) }
        }

        /// Bump an existing entry or add a new one at the front. Then enforce
        /// the cap: the oldest unpinned entry goes, never a pin.
        mutating func record(_ rawPath: String, now: Date = Date(), maxCount: Int = CreateWorkspaceRecents.maxCount) {
            let path = RecentsPath.normalize(rawPath)
            guard !path.isEmpty else { return }
            if let idx = entries.firstIndex(where: { RecentsPath.normalize($0.path) == path }) {
                let old = entries[idx].path
                entries[idx].path = path
                entries[idx].lastOpenedAt = now
                entries[idx].openCount += 1
                if old != path, let p = pins.firstIndex(of: old) { pins[p] = path }
            } else {
                entries.insert(
                    RecentDirectory(path: path, lastOpenedAt: now, openCount: 1, pinned: false),
                    at: 0
                )
            }
            enforceCap(maxCount, keeping: path)
            syncPinnedFlags()
        }

        /// Evict the oldest unpinned entries until `entries.count <= maxCount`,
        /// never a pin and never `keeping` (the entry just recorded). If
        /// nothing else is evictable the list stays over the cap.
        mutating func enforceCap(_ maxCount: Int = CreateWorkspaceRecents.maxCount, keeping: String? = nil) {
            let pinSet = Set(pins)
            while entries.count > maxCount {
                var victim: Int?
                for i in entries.indices where !pinSet.contains(entries[i].path) && entries[i].path != keeping {
                    // `<=` so a tie evicts the later (older-inserted) entry.
                    if victim == nil || entries[i].lastOpenedAt <= entries[victim!].lastOpenedAt {
                        victim = i
                    }
                }
                guard let victim else { break }
                entries.remove(at: victim)
            }
        }

        /// Pin at the end, or at `index` (clamped). Re-pinning moves the pin.
        /// Returns false when the path is not a recent.
        @discardableResult
        mutating func pin(_ path: String, at index: Int? = nil) -> Bool {
            guard entries.contains(where: { $0.path == path }) else { return false }
            pins.removeAll { $0 == path }
            let at = index.map { max(0, min(pins.count, $0)) } ?? pins.count
            pins.insert(path, at: at)
            syncPinnedFlags()
            return true
        }

        mutating func unpin(_ path: String) {
            pins.removeAll { $0 == path }
            syncPinnedFlags()
        }

        mutating func togglePin(_ path: String) {
            if pins.contains(path) { unpin(path) } else { pin(path) }
        }

        /// Move an existing pin so it lands at `index` in the final order.
        mutating func movePin(_ path: String, to index: Int) {
            guard pins.contains(path) else { return }
            pin(path, at: index)
        }

        /// Drop the entry and its pin.
        mutating func remove(_ path: String) {
            entries.removeAll { $0.path == path }
            pins.removeAll { $0 == path }
        }
    }

    enum LoadOutcome {
        case ok(State)
        /// Stored data exists but does not decode. Callers must not save over it.
        case unreadable
    }

    // MARK: Load

    static func loadOutcome(defaults: UserDefaults = .standard) -> LoadOutcome {
        var entries: [RecentDirectory]
        var migratedLegacy = false
        if let data = defaults.data(forKey: storageKey) {
            guard let decoded = try? JSONDecoder().decode([RecentDirectory].self, from: data) else {
                return .unreadable
            }
            entries = decoded
        } else if let legacy = defaults.array(forKey: legacyKey) as? [String], !legacy.isEmpty {
            let now = Date()
            entries = legacy.enumerated().map { idx, p in
                RecentDirectory(
                    path: p,
                    lastOpenedAt: now.addingTimeInterval(TimeInterval(-idx)),
                    openCount: 1,
                    pinned: false
                )
            }
            migratedLegacy = true
        } else {
            entries = []
        }

        var pins: [String]
        var needsPinsWrite = false
        if let pinData = defaults.data(forKey: pinsKey) {
            guard let decoded = try? JSONDecoder().decode([String].self, from: pinData) else {
                return .unreadable
            }
            pins = decoded
        } else {
            // First run with the pins key: keep every existing pin, in the order
            // the list used to show them (pinned first, most recent first).
            pins = entries
                .enumerated()
                .filter { $0.element.pinned }
                .sorted {
                    $0.element.lastOpenedAt != $1.element.lastOpenedAt
                        ? $0.element.lastOpenedAt > $1.element.lastOpenedAt
                        : $0.offset < $1.offset
                }
                .map { $0.element.path }
            needsPinsWrite = true
        }
        // A pin only means something while its directory is a recent.
        let known = Set(entries.map(\.path))
        var seen = Set<String>()
        pins = pins.filter { known.contains($0) && seen.insert($0).inserted }

        let state = State(entries: entries, pins: pins)
        if needsPinsWrite || migratedLegacy {
            write(state, defaults: defaults)
            if migratedLegacy { defaults.removeObject(forKey: legacyKey) }
        }
        return .ok(state)
    }

    /// Entries for display; empty when the stored data is unreadable.
    static func loadState(defaults: UserDefaults = .standard) -> State {
        if case .ok(let state) = loadOutcome(defaults: defaults) { return state }
        return State()
    }

    static func load(defaults: UserDefaults = .standard) -> [RecentDirectory] {
        loadState(defaults: defaults).entries
    }

    static func pins(defaults: UserDefaults = .standard) -> [String] {
        loadState(defaults: defaults).pins
    }

    // MARK: Save

    private static func write(_ state: State, defaults: UserDefaults) {
        var s = state
        s.enforceCap()
        s.syncPinnedFlags()
        if let data = try? JSONEncoder().encode(s.entries) {
            defaults.set(data, forKey: storageKey)
        }
        if let data = try? JSONEncoder().encode(s.pins) {
            defaults.set(data, forKey: pinsKey)
        }
    }

    /// Load, mutate, save. A decode failure leaves the stored data untouched
    /// and reports false.
    @discardableResult
    static func mutate(defaults: UserDefaults = .standard, _ body: (inout State) -> Void) -> Bool {
        guard case .ok(var state) = loadOutcome(defaults: defaults) else { return false }
        body(&state)
        write(state, defaults: defaults)
        return true
    }

    // MARK: Convenience mutators

    static func record(_ path: String, now: Date = Date(), defaults: UserDefaults = .standard) {
        mutate(defaults: defaults) { $0.record(path, now: now) }
    }

    static func togglePin(_ path: String, defaults: UserDefaults = .standard) {
        mutate(defaults: defaults) { $0.togglePin(path) }
    }

    static func pin(_ path: String, at index: Int? = nil, defaults: UserDefaults = .standard) {
        mutate(defaults: defaults) { $0.pin(path, at: index) }
    }

    static func unpin(_ path: String, defaults: UserDefaults = .standard) {
        mutate(defaults: defaults) { $0.unpin(path) }
    }

    static func movePin(_ path: String, to index: Int, defaults: UserDefaults = .standard) {
        mutate(defaults: defaults) { $0.movePin(path, to: index) }
    }

    static func remove(_ path: String, defaults: UserDefaults = .standard) {
        mutate(defaults: defaults) { $0.remove(path) }
    }
}
