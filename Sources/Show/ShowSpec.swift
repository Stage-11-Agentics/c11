import Foundation

/// `c11 show` (C11H-228): the wire contract shared by the CLI and the app.
/// Content crosses the link by reference; control never does. The socket
/// methods are `show.open` and `show.close`; the durable record for a show
/// made while c11 is away is the hc document `c11h.show.<panel-uuid>` on the
/// agent's own machine (`ShowRecord`). See docs/c11-show-design.md.
enum ShowSpec {
    static let openMethod = "show.open"
    static let closeMethod = "show.close"
    /// hc's `file.read` and `machine.exec` both carry at most 8 MB.
    static let maxBytes = 8 * 1024 * 1024
    /// At most this many live viewers per calling panel; the next one replaces the oldest.
    static let maxViewersPerCaller = 8
    /// The scheme a shown file loads under (`c11-show://<machine>/<home-relative path>`).
    static let scheme = "c11-show"
    /// Schemes a viewer also serves and accepts as typed input: the retired
    /// line's (`Legacy.showScheme`), a hidden alias for addresses it saved.
    static let acceptedSchemes: [String] = [scheme, C11Identity.Legacy.showScheme]

    /// A scheme for identity comparisons: either accepted Show scheme is the
    /// current one, so a saved old address names the same page; any other
    /// scheme is only lowercased.
    static func canonicalScheme(_ raw: String?) -> String? {
        guard let lowered = raw?.lowercased() else { return nil }
        return acceptedSchemes.contains(lowered) ? scheme : lowered
    }
    /// The machine name in a shown address for a file on c11's own Mac.
    static let localMachine = "local"
    /// The panel metadata key that names what a viewer shows.
    static let metadataKey = "show.source"
    /// How long `show` waits for the load check by default, and its bounds.
    static let defaultWaitSeconds: Double = 15
    static let waitSecondsRange: ClosedRange<Double> = 1...60

    enum Code {
        static let notFound = "show_not_found"
        static let notFile = "show_not_a_file"
        static let tooLarge = "show_too_large"
        static let refusedURL = "show_url_refused"
        static let badDir = "show_dir_invalid"
        static let badSource = "show_invalid_source"
        static let noCaller = "show_no_caller"
        static let displayOnly = "show_viewer_display_only"
        static let unreachable = "show_source_unreachable"
    }

    static func tooLargeMessage() -> String {
        String(localized: "show.error.tooLarge",
               defaultValue: "too large to show; host it and `show <url>`.")
    }
}

/// What the agent asked to show, as it travels in `show.open` / `show.close`
/// params and in the durable record. A path is absolute on the caller's own
/// machine; c11 decides which machine that is (never a parameter).
struct ShowSourceSpec: Equatable, Sendable {
    enum Kind: String, Sendable { case path, url }

    var kind: Kind
    /// Absolute path (kind path) or the URL string (kind url).
    var target: String
    /// Absolute folder the page may fetch assets from (`--dir`), kind path only.
    var dir: String?
    /// The caller machine's home, for the readable address only. Never trusted for access.
    var home: String?

    init(kind: Kind, target: String, dir: String? = nil, home: String? = nil) {
        self.kind = kind; self.target = target; self.dir = dir; self.home = home
    }

    static func path(_ path: String, dir: String? = nil, home: String? = nil) -> ShowSourceSpec {
        ShowSourceSpec(kind: .path, target: path, dir: dir, home: home)
    }

    static func url(_ url: String) -> ShowSourceSpec { ShowSourceSpec(kind: .url, target: url) }

    var dictionary: [String: Any] {
        var value: [String: Any] = ["kind": kind.rawValue, kind == .path ? "path" : "url": target]
        if let dir { value["dir"] = dir }
        if let home { value["home"] = home }
        return value
    }

    init?(_ value: Any?) {
        guard let object = value as? [String: Any],
              let kind = Kind(rawValue: object["kind"] as? String ?? "") else { return nil }
        let raw = object[kind == .path ? "path" : "url"] as? String ?? ""
        guard !raw.isEmpty, raw.utf8.count <= 4096, !raw.contains("\0"), !raw.contains("\n") else { return nil }
        let dir = object["dir"] as? String
        let home = object["home"] as? String
        if kind == .path {
            guard raw.hasPrefix("/") else { return nil }
            if let dir { guard dir.hasPrefix("/"), !dir.contains("\0"), dir.utf8.count <= 4096 else { return nil } }
        } else if dir != nil {
            return nil
        }
        if let home { guard home.hasPrefix("/"), home.utf8.count <= 4096 else { return nil } }
        self.init(kind: kind, target: raw, dir: dir, home: home)
    }

    /// The dedupe identity of the source (with its caller): what it shows and
    /// from where. `home` is display only and not part of it.
    var key: String { "\(kind.rawValue)\u{1F}\(target)\u{1F}\(dir ?? "")" }

    /// `show close <self>` names `shown`: the same kind and target, and the
    /// same `--dir` only when the close gave one. One rule for the CLI's
    /// record, the viewers and Feed. A nil closer (`show close`) names all.
    static func closes(_ closer: ShowSourceSpec?, _ shown: ShowSourceSpec) -> Bool {
        guard let closer else { return true }
        return shown.kind == closer.kind && shown.target == closer.target && (closer.dir == nil || shown.dir == closer.dir)
    }

    /// File extension, lowercased (path kind).
    var pathExtension: String { (target as NSString).pathExtension.lowercased() }

    /// Markdown opens in c11's markdown viewer; everything else in a browser viewer.
    var isMarkdown: Bool { kind == .path && ["md", "markdown", "mdown", "mkd"].contains(pathExtension) }
}

/// The readable address of a shown file: `c11-show://<machine>/<path>`, the
/// path home-relative when it is under the caller's home (`studio/Projects/x.html`)
/// and `/_/<absolute path>` otherwise. The scheme handler maps an address back
/// only through the viewer's own registered source, never by parsing it.
enum ShowAddress {
    static let outsideHomeMarker = "_"

    static func urlPath(forAbsolute path: String, home: String?) -> String {
        if let home, !home.isEmpty {
            let base = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
            // The home folder itself is the root, so `--dir ~` scopes `/`.
            if path == base || path == base + "/" { return "/" }
            let prefix = base + "/"
            if path.hasPrefix(prefix) { return "/" + String(path.dropFirst(prefix.count)) }
        }
        return "/" + outsideHomeMarker + path
    }

    /// The absolute path a URL path names, given the same home.
    static func absolutePath(forURLPath urlPath: String, home: String?) -> String? {
        guard urlPath.hasPrefix("/") else { return nil }
        let marker = "/" + outsideHomeMarker + "/"
        if urlPath.hasPrefix(marker) { return String(urlPath.dropFirst(marker.count - 1)) }
        guard let home, !home.isEmpty else { return nil }
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        return base + urlPath
    }

    /// A DNS-safe host label for a machine name.
    static func host(forMachine machine: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let lowered = machine.lowercased().map { allowed.contains($0) ? $0 : "-" }
        let label = String(lowered).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return label.isEmpty ? "machine" : String(label.prefix(63))
    }

    static func url(machine: String, path: String, home: String?) -> URL? {
        var components = URLComponents()
        components.scheme = ShowSpec.scheme
        components.host = host(forMachine: machine)
        components.path = urlPath(forAbsolute: path, home: home)
        return components.url
    }
}

/// The key a record entry is signed with: the terminal's relay credential.
struct ShowEntrySigner: Equatable, Sendable {
    var linkID: String
    var creation: UUID
    var key: Data

    init(linkID: String, creation: UUID, key: Data) { self.linkID = linkID; self.creation = creation; self.key = key }
    init(_ credential: C11RelayAuth.Credential) { self.init(linkID: credential.linkID, creation: credential.creation, key: credential.key) }
}

/// The durable record of what one panel showed (`c11h.show.<panel-uuid>` in
/// its machine's hc document store). The CLI on that machine writes entries;
/// c11 updates their state with compare-and-set. Kept small (well under hc's
/// 1 MiB document cap): at most `maxEntries`, oldest dropped first.
///
/// States: `live` (the CLI is asking c11 now; the drain leaves it alone),
/// `waiting` (c11 was away; the next drain turns it into one Feed row),
/// `noticed` (the row exists; a restart rebuilds the same row, never a second),
/// `opened` and `dismissed` (done), `closed` (the agent closed it).
struct ShowRecord: Equatable, Sendable {
    static let protocolVersion = 1
    static let maxEntries = 16
    static let namePrefix = "c11h.show."

    static func name(panel: UUID) -> String { namePrefix + panel.uuidString.lowercased() }

    static func panel(fromName name: String) -> UUID? {
        guard name.hasPrefix(namePrefix) else { return nil }
        let rest = String(name.dropFirst(namePrefix.count))
        guard rest.count == 36, let uuid = UUID(uuidString: rest), rest == uuid.uuidString.lowercased() else { return nil }
        return uuid
    }

    enum State: String, Sendable { case live, waiting, noticed, opened, dismissed, closed }

    struct Entry: Equatable, Sendable {
        var id: String
        var source: ShowSourceSpec
        /// Wall milliseconds on the agent's machine when it showed.
        var at: Int64
        var state: State
        /// C11H-176 style signature: the terminal's creation, link id and an
        /// HMAC under its relay credential over (panel, id, at, source). Any
        /// process of the user on that machine can write a document; only the
        /// terminal can sign, so c11 surfaces signed entries only.
        var creation: String?
        var linkID: String?
        var mac: String?

        static let macLabel = "c11h-show-record"

        var dictionary: [String: Any] {
            var value: [String: Any] = ["id": id, "source": source.dictionary, "at": NSNumber(value: at), "st": state.rawValue]
            if let creation { value["creation"] = creation }
            if let linkID { value["lk"] = linkID }
            if let mac { value["mac"] = mac }
            return value
        }

        init(id: String, source: ShowSourceSpec, at: Int64, state: State,
             creation: String? = nil, linkID: String? = nil, mac: String? = nil) {
            self.id = id; self.source = source; self.at = at; self.state = state
            self.creation = creation; self.linkID = linkID; self.mac = mac
        }

        init?(_ value: Any?) {
            guard let object = value as? [String: Any],
                  let id = object["id"] as? String, UUID(uuidString: id) != nil,
                  let source = ShowSourceSpec(object["source"]),
                  let at = (object["at"] as? NSNumber)?.int64Value,
                  let state = State(rawValue: object["st"] as? String ?? "") else { return nil }
            self.init(id: id, source: source, at: at, state: state, creation: object["creation"] as? String,
                      linkID: object["lk"] as? String, mac: object["mac"] as? String)
        }

        /// The signed fields include the state, so an entry cannot be moved
        /// back to `waiting` (or any state) without the terminal's key.
        static func macFields(panel: UUID, id: String, at: Int64, source: ShowSourceSpec, state: State) -> [String] {
            [panel.uuidString.lowercased(), id.lowercased(), String(at), source.kind.rawValue, source.target, source.dir ?? "",
             state.rawValue]
        }

        /// This entry signed with the terminal's credential.
        func signed(panel: UUID, credential: C11RelayAuth.Credential) -> Entry {
            signed(panel: panel, signer: ShowEntrySigner(credential))
        }

        func signed(panel: UUID, signer: ShowEntrySigner) -> Entry {
            var entry = self
            entry.creation = signer.creation.uuidString.lowercased()
            entry.linkID = signer.linkID
            entry.mac = C11RelayAuth.mac(key: signer.key, label: Self.macLabel,
                                          fields: Self.macFields(panel: panel, id: id, at: at, source: source, state: state))
            return entry
        }

        /// Whether `key` (the terminal credential c11 derives) signed this entry, in this state.
        func isSigned(panel: UUID, key: Data) -> Bool {
            guard let mac else { return false }
            return C11RelayAuth.isValid(mac: mac, key: key, label: Self.macLabel,
                                         fields: Self.macFields(panel: panel, id: id, at: at, source: source, state: state))
        }
    }

    var panel: UUID
    var entries: [Entry]

    init(panel: UUID, entries: [Entry] = []) { self.panel = panel; self.entries = entries }

    init?(panel: UUID, value: Any?) {
        guard let object = value as? [String: Any],
              (object["p"] as? NSNumber)?.intValue == Self.protocolVersion,
              (object["panel"] as? String).flatMap(UUID.init(uuidString:)) == panel else { return nil }
        self.init(panel: panel, entries: (object["entries"] as? [Any] ?? []).compactMap(Entry.init))
    }

    var dictionary: [String: Any] {
        ["p": Self.protocolVersion, "panel": panel.uuidString.lowercased(), "entries": entries.map(\.dictionary)]
    }

    /// Adds or replaces the entry for `source` (one entry per source; a re-show
    /// takes the newest id, time and state), dropping the oldest past the cap.
    mutating func upsert(id: String, source: ShowSourceSpec, at: Int64, state: State,
                         credential: C11RelayAuth.Credential? = nil) {
        entries.removeAll { $0.source.key == source.key }
        let entry = Entry(id: id, source: source, at: at, state: state)
        entries.append(credential.map { entry.signed(panel: panel, credential: $0) } ?? entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    /// Sets the state of entry `id`, signed again by `signer` (the terminal's
    /// key: the CLI's credential, or the same key c11 derives). Without one
    /// the old signature no longer matches, so c11 never surfaces the entry.
    /// False when it is gone.
    @discardableResult
    mutating func setState(_ state: State, id: String, signer: ShowEntrySigner? = nil) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries[index].state = state
        if let signer { entries[index] = entries[index].signed(panel: panel, signer: signer) }
        return true
    }

    /// Marks every entry for `source` (or every entry, when nil) closed.
    mutating func close(source: ShowSourceSpec?) {
        for index in entries.indices where ShowSourceSpec.closes(source, entries[index].source) {
            entries[index].state = .closed
        }
    }
}
