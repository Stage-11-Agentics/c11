import Foundation

/// Executable feature policy shared by the socket server and bundled CLI.
/// Enable a pending entry only in the commit that implements its behavior.
struct CapabilityFeatures {
    enum ID: String, CaseIterable {
        case workspaceAreaTab = "vocabulary.workspace_area_tab"
        case explicitTab = "send.explicit_tab"
        case offlineEvents = "events.offline"
        case canonicalRoutingKeys = "routing.canonical_keys"
        case initialInput = "create.initial_input"
        case rawSend = "send.raw"
        case terminalSelection = "read_selection.terminal"
        case windowRouteWithoutFocus = "window.route_without_focus"
    }

    struct Entry {
        let id: ID
        let version: Int
        let enabled: Bool
    }

    struct Unsupported: Error {
        let id: ID
    }

    // Adding an id does not change this version. Changing an id's meaning does.
    static let schemaVersion = 1
    static let current = CapabilityFeatures(entries: [
        Entry(id: .workspaceAreaTab, version: 1, enabled: true),
        Entry(id: .explicitTab, version: 1, enabled: true),
        Entry(id: .offlineEvents, version: 1, enabled: true),
        Entry(id: .canonicalRoutingKeys, version: 1, enabled: true),
        Entry(id: .initialInput, version: 1, enabled: false),
        Entry(id: .rawSend, version: 1, enabled: false),
        Entry(id: .terminalSelection, version: 1, enabled: false),
        Entry(id: .windowRouteWithoutFocus, version: 1, enabled: false),
    ])

    private let entries: [ID: Entry]

    init(entries: [Entry]) {
        self.entries = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    func supports(_ id: ID) -> Bool {
        entries[id]?.enabled == true
    }

    /// Use this at the implementing dispatch seam so admission and discovery
    /// consume the same policy. A disabled or absent entry never runs the body.
    func dispatch<T>(_ id: ID, perform: () throws -> T) throws -> T {
        guard supports(id) else { throw Unsupported(id: id) }
        return try perform()
    }

    var payload: [[String: Any]] {
        entries.values.filter(\.enabled).sorted { $0.id.rawValue < $1.id.rawValue }
            .map { ["id": $0.id.rawValue, "version": $0.version] }
    }
}
