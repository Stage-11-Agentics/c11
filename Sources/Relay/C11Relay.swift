import Foundation
import Darwin

/// c11's prototype relay (plan ticket 14, Settled 9): the `c11` CLI in a c11
/// terminal on another machine reaches c11 through hc's own link to that
/// machine. Shared by the CLI (the requesting side) and the app (the serving
/// side).
///
/// Transport: hc's per-machine document store. The CLI writes a request into
/// a slot document on its own machine's c11 core; c11 receives the doc event
/// over its existing hc connection, claims the slot by compare-and-set, runs
/// the request and writes the reply into the same slot. Nothing else runs on
/// the remote machine and no second connection is opened.
///
/// Every request is signed with the calling terminal's own credential and a
/// nonce from c11's heartbeat, and every reply is signed back
/// (`C11RelayAuth`, C11H-176). See docs/c11-relay.md.
enum C11Relay {
    /// C11H-176: protocol 2 signs requests and replies. A protocol 1 request
    /// (an older relay kit) is refused as outdated, never served.
    static let protocolVersion = 2
    static let legacyProtocolVersion = 1
    static let slotCount = 32
    static let spoolName = "c11h.relay.spool"
    /// C11H-88: c11's heartbeat on each linked machine,
    /// `{"p":2,"at":<wall ms>,"up_at":<ms>,"down_at":<ms>,"n":<nonce>}`, written
    /// at link-up and every 2 s. C11H-176: `n` is a fresh random nonce each
    /// beat; a live request must carry one c11 issued recently. `up_at` is when c11's machine-link monitor last saw the
    /// link come up, `down_at` when it last saw it go down (absent if never).
    /// The CLI reads it when a claim times out, to say whether the link is up,
    /// just came back, or has gone quiet.
    static let seenName = "c11h.relay.seen"
    /// A heartbeat younger than this (three beats and slack) means c11 was
    /// answering over the link.
    static let seenFreshSeconds: Int64 = 8
    /// A drop this recent is named in the error.
    static let recentDropSeconds: Int64 = 120

    static func seenValue(at wallMilliseconds: Int64, upAt: Int64? = nil, downAt: Int64? = nil,
                          nonce: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["p": protocolVersion, "at": NSNumber(value: wallMilliseconds)]
        if let upAt { value["up_at"] = NSNumber(value: upAt) }
        if let downAt { value["down_at"] = NSNumber(value: downAt) }
        if let nonce { value["n"] = nonce }
        return value
    }

    /// The nonce in c11's heartbeat, or nil when there is none.
    static func nonce(fromSeen value: Any?) -> String? {
        guard let object = value as? [String: Any], (object["p"] as? NSNumber)?.intValue == protocolVersion,
              let nonce = object["n"] as? String, isNonce(nonce) else { return nil }
        return nonce
    }

    /// 16 random bytes as lowercase hex.
    static func isNonce(_ value: String) -> Bool {
        value.utf8.count == 32 && C11RelayAuth.data(hex: value) != nil
    }

    /// What the CLI can tell about the link from c11's heartbeat, in seconds before now.
    struct LinkView: Equatable, Sendable {
        /// Since c11 last wrote its heartbeat.
        let answered: Int64
        /// Since the link last went down, and since it last came up.
        let dropped: Int64?
        let back: Int64?

        /// The link went down and came back within `recentDropSeconds`, and c11 is answering again.
        var recentlyBack: Bool {
            guard let dropped, let back, back <= dropped else { return false }
            return back <= C11Relay.recentDropSeconds && answered < C11Relay.seenFreshSeconds
        }
    }

    static func linkView(_ value: Any?, now wallMilliseconds: Int64) -> LinkView? {
        guard let object = value as? [String: Any], (object["p"] as? NSNumber)?.intValue == protocolVersion,
              let at = (object["at"] as? NSNumber)?.int64Value else { return nil }
        func ago(_ key: String) -> Int64? {
            (object[key] as? NSNumber).map { max(0, (wallMilliseconds - $0.int64Value) / 1000) }
        }
        return LinkView(answered: max(0, (wallMilliseconds - at) / 1000), dropped: ago("down_at"), back: ago("up_at"))
    }

    /// Seconds since c11's heartbeat, or nil when there is none.
    static func secondsSinceSeen(_ value: Any?, now wallMilliseconds: Int64) -> Int64? {
        linkView(value, now: wallMilliseconds)?.answered
    }
    /// Lines larger than this are refused before they are written.
    static let maxLineBytes = 64 * 1024
    /// A reply larger than this is replaced by an error (hc's document limit is 1 MiB).
    static let maxResponseBytes = 900 * 1024
    static let spoolMaxRecords = 256
    static let spoolMaxBytes = 256 * 1024
    static let defaultClaimMilliseconds = 1500
    static let claimMillisecondsRange = 250...2500
    /// A slot whose request is older than this (by the requesting machine's own
    /// clock) belongs to a CLI that died; another CLI may take it.
    static let staleSlotMilliseconds: Int64 = 30_000

    static func slotName(_ index: Int) -> String { String(format: "c11h.relay.r%02d", index) }

    static func slotIndex(_ name: String) -> Int? {
        let prefix = "c11h.relay.r"
        guard name.hasPrefix(prefix) else { return nil }
        let digits = name.dropFirst(prefix.count)
        guard digits.count == 2, let index = Int(digits), (0..<slotCount).contains(index) else { return nil }
        return index
    }

    /// How long a read-only or spoolable call keeps waiting for c11 to claim
    /// it, so a machine link that drops and reconnects (typically 7-10 s) does
    /// not fail the call. The caller's own timeout caps it.
    static let reconnectToleranceSeconds: TimeInterval = 10

    /// Read-only socket methods: running one twice, or not at all, changes
    /// nothing. An explicit allowlist; anything not named here (every write,
    /// every unknown method) keeps the short claim bound. Mailbox peek is a
    /// read; send and ack are not. Each must also be admitted by
    /// `C11RelayPolicy`, which a test checks.
    static let safeReadMethods: Set<String> = [
        "system.ping", "system.capabilities", "system.identify", "system.tree", "system.brand",
        "window.list", "window.current", "workspace.list", "workspace.current", "workspace.get_metadata",
        "display.list",
        "panel.list", "panel.current", "panel.locate", "panel.family", "panel.get_metadata",
        "panel.get_titlebar_state", "area.list", "area.panels", "sidebar.state", "mailbox.resolve",
        C11RelayMethods.mailboxPeek,
    ]

    static let safeReadCommands: Set<String> = ["ping", "list_status", "list_log"]

    static func isSafeRead(framing: Framing, line: String) -> Bool {
        switch framing {
        case .text:
            let name = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return safeReadCommands.contains(name)
        case .json:
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let method = object["method"] as? String else { return false }
            return safeReadMethods.contains(method)
        }
    }

    /// Whether a call may wait out a short reconnect before it is cancelled:
    /// reads (nothing to repeat) and spoolable telemetry (cancelled by
    /// compare-and-set, then queued). Never a write that cannot be queued.
    static func toleratesReconnect(framing: Framing, line: String) -> Bool {
        isSafeRead(framing: framing, line: line) || isSpoolable(framing: framing, line: line)
    }

    /// The claim window for one call: the usual bound, or for a call that
    /// tolerates a reconnect up to `reconnectToleranceSeconds` within the
    /// caller's `timeout`, including a shorter hook deadline.
    static func claimWindow(claimMilliseconds: Int, timeout: TimeInterval, tolerant: Bool) -> TimeInterval {
        let usual = Double(claimMilliseconds) / 1000
        guard tolerant else { return usual }
        return min(max(0.1, timeout), max(usual, reconnectToleranceSeconds))
    }

    static func claimMilliseconds(environment: [String: String]) -> Int {
        guard let raw = environment["C11_RELAY_CLAIM_MS"], let value = Int(raw) else { return defaultClaimMilliseconds }
        return min(max(value, claimMillisecondsRange.lowerBound), claimMillisecondsRange.upperBound)
    }

    enum Framing: String, Sendable {
        /// A v2 JSON request line; the reply is one JSON line.
        case json
        /// A v1 text command; the reply is text, possibly several lines.
        case text
    }

    /// A request as written into a slot.
    struct Request: Equatable, Sendable {
        let id: String
        /// Requesting machine's wall clock, epoch milliseconds.
        let at: Int64
        /// The caller's identity, from its terminal's environment.
        let panel: String
        let workspace: String?
        /// `HC_TERMINAL_ID` in the caller's terminal.
        let term: String
        let framing: Framing
        let line: String
        let timeoutMilliseconds: Int
        /// C11H-176: a nonce from c11's heartbeat (empty when the CLI had none).
        let nonce: String
        /// The terminal's creation id and link id, from its credential; empty
        /// when the terminal has none (c11 refuses it as `relay_auth_missing`).
        let creation: String
        let linkID: String
        /// HMAC of every field above under the terminal's credential; empty unsigned.
        let mac: String
        /// C11H-176: what the request was signed for. A live request runs
        /// only from a slot, a spooled one only from the spool, so neither can
        /// be replayed through the other path.
        let mode: Mode

        enum Mode: String, Sendable { case live, spool }

        var isSigned: Bool { !mac.isEmpty && !creation.isEmpty && !linkID.isEmpty }

        static let timeoutRange = 100...120_000

        var dictionary: [String: Any] {
            var value: [String: Any] = ["st": "req", "p": C11Relay.protocolVersion, "id": id, "at": at, "panel": panel,
                                        "term": term, "framing": framing.rawValue, "line": line, "timeout_ms": timeoutMilliseconds,
                                        "nonce": nonce, "creation": creation, "lk": linkID, "mac": mac, "use": mode.rawValue]
            if let workspace { value["workspace"] = workspace }
            return value
        }

        init(id: String, at: Int64, panel: String, workspace: String?, term: String, framing: Framing,
             line: String, timeoutMilliseconds: Int, nonce: String = "", creation: String = "",
             linkID: String = "", mac: String = "", mode: Mode = .live) {
            self.id = id; self.at = at; self.panel = panel; self.workspace = workspace; self.term = term
            self.framing = framing; self.line = line
            self.timeoutMilliseconds = min(max(timeoutMilliseconds, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
            self.nonce = nonce; self.creation = creation; self.linkID = linkID; self.mac = mac; self.mode = mode
        }

        /// The same request, signed with the terminal's credential for `mode`.
        func signed(with credential: C11RelayAuth.Credential, mode: Mode? = nil) -> Request {
            let mode = mode ?? self.mode
            let unsigned = Request(id: id, at: at, panel: panel, workspace: workspace, term: term, framing: framing,
                                   line: line, timeoutMilliseconds: timeoutMilliseconds, nonce: nonce,
                                   creation: credential.creation.uuidString.lowercased(), linkID: credential.linkID, mode: mode)
            return Request(id: id, at: at, panel: panel, workspace: workspace, term: term, framing: framing,
                           line: line, timeoutMilliseconds: timeoutMilliseconds, nonce: nonce,
                           creation: unsigned.creation, linkID: unsigned.linkID,
                           mac: C11RelayAuth.sign(unsigned, key: credential.key), mode: mode)
        }

        init?(_ value: Any?) {
            guard let object = value as? [String: Any], object["st"] as? String == "req",
                  (object["p"] as? NSNumber)?.intValue == C11Relay.protocolVersion,
                  let id = object["id"] as? String, UUID(uuidString: id) != nil,
                  let at = (object["at"] as? NSNumber)?.int64Value,
                  let panel = object["panel"] as? String, UUID(uuidString: panel) != nil,
                  let term = object["term"] as? String, !term.isEmpty, term.utf8.count <= 64,
                  let framingRaw = object["framing"] as? String, let framing = Framing(rawValue: framingRaw),
                  let line = object["line"] as? String, !line.isEmpty, line.utf8.count <= C11Relay.maxLineBytes,
                  !line.contains("\n"),
                  let timeout = (object["timeout_ms"] as? NSNumber)?.intValue,
                  Self.timeoutRange.contains(timeout) else { return nil }
            let workspace = object["workspace"] as? String
            if let workspace, UUID(uuidString: workspace) == nil { return nil }
            let nonce = object["nonce"] as? String ?? ""
            let creation = object["creation"] as? String ?? ""
            let linkID = object["lk"] as? String ?? ""
            let mac = object["mac"] as? String ?? ""
            guard let mode = Mode(rawValue: object["use"] as? String ?? Mode.live.rawValue),
                  nonce.isEmpty || C11Relay.isNonce(nonce),
                  creation.isEmpty || UUID(uuidString: creation) != nil,
                  linkID.isEmpty || C11RelayAuth.isLinkID(linkID),
                  mac.isEmpty || (mac.utf8.count == 64 && C11RelayAuth.data(hex: mac) != nil) else { return nil }
            self.init(id: id, at: at, panel: panel, workspace: workspace, term: term, framing: framing,
                      line: line, timeoutMilliseconds: timeout, nonce: nonce, creation: creation,
                      linkID: linkID, mac: mac, mode: mode)
        }
    }

    /// C11H-176: a request from a relay kit older than protocol 2. c11
    /// refuses it with `relay_kit_outdated` so the CLI says what to do.
    static func legacyRequest(_ value: Any?) -> (id: String, at: Int64)? {
        guard let object = value as? [String: Any], object["st"] as? String == "req",
              (object["p"] as? NSNumber)?.intValue == legacyProtocolVersion,
              let id = object["id"] as? String, UUID(uuidString: id) != nil,
              let at = (object["at"] as? NSNumber)?.int64Value else { return nil }
        return (id, at)
    }

    static func legacyRefusedValue(id: String, at: Int64, code: String, message: String) -> [String: Any] {
        ["st": "refused", "id": id, "at": at, "code": code, "message": message]
    }

    /// A slot's state as the requesting CLI reads it.
    enum SlotState: Equatable {
        case free
        case request(id: String, at: Int64)
        case claimed(id: String, at: Int64)
        /// `rmac`: c11's HMAC of the reply (C11H-176); empty when unsigned.
        case done(id: String, at: Int64, response: String, rmac: String)
        case refused(id: String, at: Int64, code: String, message: String)
        case unknown(at: Int64?)

        init(_ value: Any?) {
            guard let object = value as? [String: Any] else { self = .free; return }
            let id = object["id"] as? String ?? ""
            let at = (object["at"] as? NSNumber)?.int64Value
            switch object["st"] as? String {
            case "req": self = .request(id: id, at: at ?? 0)
            case "claimed": self = .claimed(id: id, at: at ?? 0)
            case "done": self = .done(id: id, at: at ?? 0, response: object["response"] as? String ?? "",
                                      rmac: object["rmac"] as? String ?? "")
            case "refused": self = .refused(id: id, at: at ?? 0, code: object["code"] as? String ?? "relay_refused",
                                             message: object["message"] as? String ?? "")
            default: self = .unknown(at: at)
            }
        }

        var requestID: String? {
            switch self {
            case .request(let id, _), .claimed(let id, _), .done(let id, _, _, _), .refused(let id, _, _, _): return id
            case .free, .unknown: return nil
            }
        }

        var at: Int64? {
            switch self {
            case .request(_, let at), .claimed(_, let at), .done(_, let at, _, _), .refused(_, let at, _, _): return at
            case .unknown(let at): return at
            case .free: return nil
            }
        }

        /// Free, or abandoned by a CLI that died more than `staleSlotMilliseconds` ago.
        func isAvailable(now: Int64) -> Bool {
            if case .free = self { return true }
            guard let at else { return true }
            return now - at > C11Relay.staleSlotMilliseconds || at - now > C11Relay.staleSlotMilliseconds
        }
    }

    static func claimedValue(_ request: Request) -> [String: Any] {
        ["st": "claimed", "id": request.id, "at": request.at]
    }

    /// The reply, signed with the caller's credential (`key`) so the CLI can
    /// tell it from a reply someone else wrote into the slot.
    static func doneValue(_ request: Request, response: String, key: Data) -> [String: Any] {
        guard response.utf8.count <= maxResponseBytes else {
            return refusedValue(request, code: "relay_response_too_large",
                                message: "The reply is larger than the relay carries.", key: key)
        }
        return ["st": "done", "id": request.id, "at": request.at, "response": response,
                "rmac": C11RelayAuth.replyMAC(requestID: request.id, response: response, key: key)]
    }

    /// A refusal. Once c11 has authenticated the caller it signs the refusal
    /// with the caller's credential (`key`); before that (identity, credential,
    /// an older kit) it cannot, and the CLI shows its own text for those.
    static func refusedValue(_ request: Request, code: String, message: String, key: Data? = nil) -> [String: Any] {
        var value: [String: Any] = ["st": "refused", "id": request.id, "at": request.at, "code": code, "message": message]
        if let key { value["rmac"] = C11RelayAuth.refusalMAC(requestID: request.id, code: code, message: message, key: key) }
        return value
    }

    // MARK: - Spool

    /// A spooled request, kept whole: its MAC covers every field (C11H-176).
    struct SpoolRecord: Equatable, Sendable {
        let request: Request

        init(_ request: Request) { self.request = request }

        var id: String { request.id }
        var at: Int64 { request.at }
        var panel: String { request.panel }
        var term: String { request.term }
        var framing: Framing { request.framing }
        var line: String { request.line }

        var dictionary: [String: Any] {
            var value = request.dictionary
            value.removeValue(forKey: "st")
            return value
        }

        init?(_ value: Any?) {
            guard var object = value as? [String: Any] else { return nil }
            object["st"] = "req"
            guard let request = Request(object) else { return nil }
            self.init(request)
        }
    }

    /// Records in order; malformed entries are skipped, never applied.
    static func spoolRecords(_ value: Any?) -> [SpoolRecord] {
        guard let object = value as? [String: Any], let records = object["records"] as? [Any] else { return [] }
        return records.compactMap(SpoolRecord.init)
    }

    enum SpoolAppend: Equatable {
        case appended([String: Any])
        case full

        static func == (lhs: SpoolAppend, rhs: SpoolAppend) -> Bool {
            switch (lhs, rhs) {
            case (.full, .full): return true
            case (.appended(let a), .appended(let b)): return NSDictionary(dictionary: a).isEqual(to: b)
            default: return false
            }
        }
    }

    /// The spool document with `record` appended, or `.full` when either bound
    /// would be crossed. The existing records are kept as they were.
    static func appending(_ record: SpoolRecord, to value: Any?) -> SpoolAppend {
        var records = (value as? [String: Any])?["records"] as? [Any] ?? []
        guard records.count < spoolMaxRecords else { return .full }
        records.append(record.dictionary)
        let next: [String: Any] = ["p": protocolVersion, "records": records]
        guard let data = try? JSONSerialization.data(withJSONObject: next), data.count <= spoolMaxBytes else { return .full }
        return .appended(next)
    }

    static let emptySpool: [String: Any] = ["p": protocolVersion, "records": [Any]()]

    /// Fire-and-forget telemetry that may wait in the spool while the link is
    /// down. Everything else fails fast and is never queued.
    static func isSpoolable(framing: Framing, line: String) -> Bool {
        switch framing {
        case .text:
            let name = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return ["set_status", "clear_status", "set_progress", "clear_progress", "log", "clear_log"].contains(name)
        case .json:
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let method = object["method"] as? String else { return false }
            return method == "agent.event.append"
        }
    }

    // MARK: - Manifest

    /// What the installer on the remote machine writes beside the relay CLI.
    struct Manifest: Equatable, Sendable {
        /// The kit's relay protocol: 2 takes a credential, 1 is an older kit
        /// whose `c11` c11 refuses as outdated (C11H-176).
        let protocolVersion: Int
        let session: String
        let home: String
        let bin: String
        let zdotdir: String
        let sentinel: String
        let cliSHA256: String
        /// C11H-392: the kit's bash startup file, which a kit before it lacks.
        var bashrc: String? = nil

        static func relativePath(session: String) -> String { ".local/share/c11/relay/\(session)/manifest.json" }

        /// Where a kit's manifest may live on its machine: 2.0's own path, then,
        /// while this app has adopted c11h's sessions (C11H-266), the c11h-era  // c11-2.0:legacy
        /// kit's path, which serves those sessions until the machine converges.
        static func relativePaths(session: String,
                                  adoption: C11AdoptionRecord? = HCLaunchPolicy.processNamespace) -> [String] {
            var paths = [relativePath(session: session)]
            if let root = adoption?.root, root != ".local/share/c11" {
                paths.append("\(root)/relay/\(session)/manifest.json")
            }
            return paths
        }

        init?(data: Data, session expected: String) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let version = (object["relay_protocol"] as? NSNumber)?.intValue,
                  (C11Relay.legacyProtocolVersion...C11Relay.protocolVersion).contains(version),
                  let session = object["session"] as? String, session == expected,
                  let home = object["home"] as? String, let bin = object["bin"] as? String,
                  let zdotdir = object["zdotdir"] as? String, let sentinel = object["sentinel"] as? String,
                  let sha = object["cli_sha256"] as? String,
                  sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
            // 2.0's kit, or the c11h-era kit an adopted session still uses (C11H-266).  // c11-2.0:legacy
            let roots = ["\(home)/.local/share/c11/relay/\(session)/"]
                + (HCLaunchPolicy.processNamespace.map { ["\(home)/\($0.root)/relay/\(session)/"] } ?? [])
            let bashrc = object["bashrc"] as? String
            guard object["bashrc"] == nil || bashrc != nil else { return nil }
            for path in [bin, zdotdir, sentinel] + (bashrc.map { [$0] } ?? []) {
                guard roots.contains(where: { path.hasPrefix($0) }), !path.contains(".."), !path.contains("\n"),
                      path.range(of: #"^[A-Za-z0-9._/@ -]+$"#, options: .regularExpression) != nil else { return nil }
            }
            self.protocolVersion = version
            self.session = session; self.home = home; self.bin = bin; self.zdotdir = zdotdir
            self.sentinel = sentinel; self.cliSHA256 = sha; self.bashrc = bashrc
        }

        /// Added to a terminal launched on that machine. ZDOTDIR loads the
        /// relay's zsh startup files (they source the user's own and then put
        /// the relay `c11` first); the socket paths name a file that is not a
        /// socket, so any other `c11` binary fails closed instead of reaching
        /// that machine's own c11. C11H-392: `C11_RELAY_BASHRC` names the
        /// kit's bash startup file, which the launch line gives a bash shell.
        var terminalEnvironment: [String: String] {
            var environment = ["ZDOTDIR": zdotdir, "C11_SOCKET_PATH": sentinel, "CMUX_SOCKET_PATH": sentinel,
                               "C11_RELAY_BIN": bin, C11RelayAuth.protocolVariable: String(protocolVersion)]
            if let bashrc { environment["C11_RELAY_BASHRC"] = bashrc }
            return environment
        }
    }
}

/// Relay-only socket methods. They answer only to a relayed request; the
/// local socket dispatcher has no route to them.
enum C11RelayMethods {
    static let mailboxSend = "c11h.relay.mailbox.send"
    static let mailboxPeek = "c11h.relay.mailbox.peek"
    static let mailboxAck = "c11h.relay.mailbox.ack"
    static let all: Set<String> = [mailboxSend, mailboxPeek, mailboxAck]
}

/// hc's document store as the relay uses it. `set` throws
/// `C11RelayStoreError.conflict` when `version` is stale.
protocol C11RelayDocStore: AnyObject {
    func get(_ name: String) throws -> (value: Any?, version: UInt64)
    func set(_ name: String, value: Any?, version: UInt64) throws -> UInt64
}

enum C11RelayStoreError: Error, Equatable {
    case conflict
    case unavailable(String)
}

/// Errors the requesting CLI reports. Each message names what happened and
/// whether anything was queued.
extension C11Relay {
    /// C11H-89: `mailbox recv --ack` printed envelopes, then the ack failed:
    /// they stay unread and come again, so a poller knows the next copy is a
    /// repeat.
    static func unacknowledgedMessage(printed: Int, reason: String) -> String {
        String(format: String(localized: "relay.cli.error.recvNotAcknowledged",
            defaultValue: "relay_ack_failed: printed %lld, not acknowledged; they will show again (%@)"),
            Int64(printed), reason)
    }

    /// `mailbox recv --panel` through the relay: a UUID passes as is; a ref
    /// (`panel:N`) or other handle is resolved with `panel.get_metadata` to
    /// its UUID, so c11's own-inbox check compares UUIDs. Unresolvable is an
    /// error, never the caller's inbox by default.
    static func canonicalPanel(_ requested: String?, resolve: (String) throws -> [String: Any]) throws -> String? {
        guard let requested, !requested.isEmpty else { return nil }
        if let uuid = UUID(uuidString: requested) { return uuid.uuidString }
        let payload = try resolve(requested)
        guard let panel = ((payload["panel_id"] ?? payload["surface_id"]) as? String).flatMap(UUID.init(uuidString:)) else {
            throw C11RelayCallError.refused(code: "not_found",
                message: String(localized: "relay.error.panelNotFound", defaultValue: "No panel matches that reference."))
        }
        return panel.uuidString
    }
}

enum C11RelayCallError: Error, Equatable {
    /// Nobody claimed the request in time; nothing ran. `spooled` says whether
    /// it waits in the spool.
    case unreachable(spooled: Bool, spoolFull: Bool, link: C11Relay.LinkView? = nil)
    case busy
    case tooLarge
    /// c11 claimed the request but no reply arrived in time; it may have run.
    case outcomeUnknown
    /// C11H-176: a reply arrived that c11 did not sign; it may have run.
    case replyUnverified
    case refused(code: String, message: String)
    case store(String)

    var cliMessage: String {
        switch self {
        case .unreachable(true, _, let link):
            return String(localized: "relay.error.unreachableSpooled",
                defaultValue: "relay_unreachable: c11 did not answer through the machine link; spooled, it applies when the link returns") + Self.linkNote(link)
        case .unreachable(false, true, let link):
            return String(localized: "relay.error.unreachableSpoolFull",
                defaultValue: "relay_unreachable: c11 did not answer through the machine link; the spool is full, so this was dropped") + Self.linkNote(link)
        case .unreachable(false, false, let link?) where link.recentlyBack:
            return String(format: String(localized: "relay.error.unreachableLinkBack",
                defaultValue: "relay_unreachable: the machine link to c11 dropped %lld s ago and has been back for %lld s; nothing ran. Retry."),
                link.dropped ?? 0, link.back ?? 0)
        case .unreachable(false, false, let link?) where link.answered < C11Relay.seenFreshSeconds:
            return String(format: String(localized: "relay.error.unreachableLinkUp",
                defaultValue: "relay_unreachable: c11 did not claim this call in time, but it answered over the machine link %lld s ago, so the link is up; nothing ran. Retry."),
                link.answered)
        case .unreachable(false, false, let link?):
            return String(format: String(localized: "relay.error.unreachableLinkQuiet",
                defaultValue: "relay_unreachable: no answer from c11 over the machine link for %lld s; the link is probably down and reconnects on its own (or the Mac running c11 is asleep); nothing ran. Retry shortly."),
                link.answered)
        case .unreachable(false, false, nil):
            return String(localized: "relay.error.unreachable",
                defaultValue: "relay_unreachable: c11 did not answer through the machine link (is the Mac running c11 awake?); nothing ran") + Self.linkNote(nil)
        case .busy:
            return String(localized: "relay.error.busy", defaultValue: "relay_busy: every relay slot is in use; retry")
        case .tooLarge:
            return String(localized: "relay.error.tooLarge",
                defaultValue: "relay_too_large: the request is larger than the relay carries")
        case .outcomeUnknown:
            return String(localized: "relay.error.outcomeUnknown",
                defaultValue: "relay_outcome_unknown: c11 took the request but its reply did not arrive in time; it may have run")
        case .replyUnverified:
            return String(localized: "relay.error.replyUnverified",
                defaultValue: "relay_reply_unverified: a reply arrived that c11 did not sign, so it was not used; the request may have run")
        case .refused(let code, let message):
            return message.isEmpty ? code : "\(code): \(message)"
        case .store(let detail):
            return String(format: String(localized: "relay.error.store", defaultValue: "relay_unavailable: %@"), detail)
        }
    }

    /// When c11 last answered over the link (and a recent drop), from its heartbeat.
    private static func linkNote(_ link: C11Relay.LinkView?) -> String {
        guard let link else {
            return String(localized: "relay.error.linkNoteNever", defaultValue: " (no answer from c11 over this link yet)")
        }
        if link.recentlyBack, let dropped = link.dropped, let back = link.back {
            return String(format: String(localized: "relay.error.linkNoteBack",
                defaultValue: " (the link dropped %lld s ago and has been back for %lld s)"), dropped, back)
        }
        return String(format: String(localized: "relay.error.linkNote", defaultValue: " (c11 last answered over the link %lld s ago)"), link.answered)
    }
}

/// Set once a call in this process found c11 unreachable. One CLI command
/// makes several socket calls; only the first waits out the claim bound, so
/// the whole command fails fast. Telemetry still reaches the spool.
final class C11RelayDownLatch {
    private(set) var isDown = false
    func markDown() { isDown = true }
}

/// The requesting side of one relayed call. Synchronous: the CLI is a
/// short-lived process. Clocks and sleeping are injected for tests.
final class C11RelayClient {
    struct Caller: Equatable {
        let panel: String
        let workspace: String?
        let term: String
        /// C11H-176: the terminal's relay credential. Without one, requests go
        /// unsigned and c11 refuses them (`relay_auth_missing`), so the
        /// refusal is seen on the Mac too.
        var credential: C11RelayAuth.Credential? = nil
    }

    private let store: C11RelayDocStore
    private let caller: Caller
    private let claimMilliseconds: Int
    private let wallMilliseconds: () -> Int64
    private let uptime: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let makeID: () -> String
    private let latch: C11RelayDownLatch
    private var nextStart: Int
    /// C11H-176: c11's latest heartbeat nonce, read once per client and
    /// again after a `relay_stale` refusal.
    private var nonce: String?
    private static let finePollSeconds: TimeInterval = 2
    /// C11H-97: told of each claim timeout (the relay folder's log).
    private let onClaimTimeout: ((C11Relay.Request, Int, Int, C11RelayCallError) -> Void)?

    init(store: C11RelayDocStore, caller: Caller, claimMilliseconds: Int = C11Relay.defaultClaimMilliseconds,
         wallMilliseconds: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         makeID: @escaping () -> String = { UUID().uuidString },
         latch: C11RelayDownLatch = C11RelayDownLatch(),
         firstSlot: Int = Int.random(in: 0..<C11Relay.slotCount),
         onClaimTimeout: ((_ request: C11Relay.Request, _ slot: Int, _ waitedMilliseconds: Int,
                           _ error: C11RelayCallError) -> Void)? = nil) {
        self.onClaimTimeout = onClaimTimeout
        self.store = store; self.caller = caller; self.claimMilliseconds = claimMilliseconds
        self.wallMilliseconds = wallMilliseconds; self.uptime = uptime; self.sleep = sleep; self.makeID = makeID
        self.latch = latch
        self.nextStart = firstSlot
    }

    /// Sends one request line and returns c11's reply text. `timeout` bounds
    /// the wait for the reply once c11 has claimed the request. A write that
    /// cannot be queued waits only the claim bound before it is cancelled; a
    /// read or spoolable call (`toleratesReconnect`) waits up to
    /// `reconnectToleranceSeconds`, within `timeout`, which then covers claim
    /// and reply together. A claimed request is never sent again.
    func call(line: String, framing: C11Relay.Framing, timeout: TimeInterval) throws -> String {
        guard line.utf8.count <= C11Relay.maxLineBytes, !line.contains("\n") else { throw C11RelayCallError.tooLarge }
        do {
            return try attempt(line: line, framing: framing, timeout: timeout)
        } catch C11RelayCallError.refused(let code, _) where code == C11RelayAuth.staleCode && !latch.isDown {
            // Nothing ran: the nonce was too old (c11 restarted, or the link
            // was down for a while). Once more with a fresh one.
            nonce = nil
            return try attempt(line: line, framing: framing, timeout: timeout)
        }
    }

    /// c11's latest heartbeat nonce on this machine, or "" when it has none
    /// (c11 is not answering; the call then times out or spools).
    private func currentNonce() -> String {
        if let nonce { return nonce }
        let read = ((try? store.get(C11Relay.seenName)).flatMap { C11Relay.nonce(fromSeen: $0.value) }) ?? ""
        if !read.isEmpty { nonce = read }
        return read
    }

    private func attempt(line: String, framing: C11Relay.Framing, timeout: TimeInterval) throws -> String {
        var request = C11Relay.Request(id: makeID(), at: wallMilliseconds(), panel: caller.panel,
                                        workspace: caller.workspace, term: caller.term, framing: framing, line: line,
                                        timeoutMilliseconds: Int(max(0.1, timeout) * 1000),
                                        nonce: latch.isDown ? "" : currentNonce())
        if let credential = caller.credential { request = request.signed(with: credential) }
        guard !latch.isDown else { throw unreachable(request) }
        let tolerant = C11Relay.toleratesReconnect(framing: framing, line: line)
        let window = C11Relay.claimWindow(claimMilliseconds: claimMilliseconds, timeout: timeout, tolerant: tolerant)
        let (slot, written) = try acquire(request)
        let claimStart = uptime()
        let claimDeadline = claimStart + window
        var version = written
        var claimed = false
        // Wait for c11 to claim it.
        while !claimed {
            let (value, current) = try read(slot)
            if current != version {
                let state = C11Relay.SlotState(value)
                guard state.requestID == request.id else { throw C11RelayCallError.store("relay slot was taken over") }
                version = current
                switch state {
                case .claimed: claimed = true
                case .done(_, _, let response, let rmac):
                    free(slot, version: current); return try verified(response, rmac: rmac, request: request)
                case .refused(_, _, let code, let message):
                    free(slot, version: current); throw refusal(code: code, message: message, value: value, request: request)
                default: break
                }
                continue
            }
            if uptime() >= claimDeadline {
                // Cancel by compare-and-set: either this cancel or c11's claim wins, never both.
                do {
                    _ = try store.set(C11Relay.slotName(slot), value: nil, version: version)
                } catch C11RelayStoreError.conflict {
                    continue
                }
                latch.markDown()
                let error = unreachable(request)
                let waited = Int((uptime() - claimDeadline) * 1000 + window * 1000)
                onClaimTimeout?(request, slot, waited, error)
                throw error
            }
            // Poll finely for the usual bound, then gently while riding out a reconnect.
            sleep(uptime() - claimStart < Self.finePollSeconds ? 0.01 : 0.05)
        }
        // Claimed: wait for the reply within the request's own deadline. A call
        // that rode out a reconnect shares one deadline between claim and reply,
        // so the caller's timeout (and the process deadline under it) still holds.
        let replyDeadline = tolerant ? claimStart + max(0.1, timeout)
                                     : uptime() + max(0.1, timeout)
        while true {
            let (value, current) = try read(slot)
            if current != version {
                let state = C11Relay.SlotState(value)
                guard state.requestID == request.id else { throw C11RelayCallError.outcomeUnknown }
                version = current
                switch state {
                case .done(_, _, let response, let rmac):
                    free(slot, version: current); return try verified(response, rmac: rmac, request: request)
                case .refused(_, _, let code, let message):
                    free(slot, version: current)
                    // After the claim, only a refusal c11 signed says nothing ran.
                    let rmac = (value as? [String: Any])?["rmac"] as? String ?? ""
                    if let credential = caller.credential,
                       C11RelayAuth.isValidRefusal(rmac, requestID: request.id, code: code, message: message, key: credential.key) {
                        throw C11RelayCallError.refused(code: code, message: message)
                    }
                    throw C11RelayCallError.outcomeUnknown
                default: break
                }
            }
            if uptime() >= replyDeadline {
                free(slot, version: version)
                throw C11RelayCallError.outcomeUnknown
            }
            sleep(0.01)
        }
    }

    /// A reply is used only when c11 signed it with this terminal's
    /// credential: a reply someone else wrote into the slot is refused.
    private func verified(_ response: String, rmac: String, request: C11Relay.Request) throws -> String {
        guard let credential = caller.credential,
              C11RelayAuth.isValidReply(rmac, requestID: request.id, response: response, key: credential.key) else {
            throw C11RelayCallError.replyUnverified
        }
        return response
    }

    /// A refusal as the CLI reports it: c11's own words when c11 signed it
    /// with this terminal's credential, else the CLI's text for that code.
    private func refusal(code: String, message: String, value: Any?, request: C11Relay.Request) -> C11RelayCallError {
        let rmac = (value as? [String: Any])?["rmac"] as? String ?? ""
        if let credential = caller.credential,
           C11RelayAuth.isValidRefusal(rmac, requestID: request.id, code: code, message: message, key: credential.key) {
            return .refused(code: code, message: message)
        }
        let shown = C11RelayAuth.unsignedRefusal(code: code)
        return .refused(code: shown.code, message: shown.message)
    }

    /// Appends a record to the spool, retrying compare-and-set conflicts.
    func spool(_ record: C11Relay.SpoolRecord) throws -> Bool {
        for _ in 0..<8 {
            let (value, version) = try read(name: C11Relay.spoolName)
            switch C11Relay.appending(record, to: value) {
            case .full: return false
            case .appended(let next):
                do { _ = try store.set(C11Relay.spoolName, value: next, version: version); return true }
                catch C11RelayStoreError.conflict { continue }
                catch let C11RelayStoreError.unavailable(detail) { throw C11RelayCallError.store(detail) }
            }
        }
        return false
    }

    private func unreachable(_ request: C11Relay.Request) -> C11RelayCallError {
        // C11H-88: say whether c11 has been answering, so a busy relay does
        // not read as a sleeping host. One bounded read; none if it fails.
        let link = (try? store.get(C11Relay.seenName)).flatMap { C11Relay.linkView($0.value, now: wallMilliseconds()) }
        guard C11Relay.isSpoolable(framing: request.framing, line: request.line) else {
            return .unreachable(spooled: false, spoolFull: false, link: link)
        }
        // The live request was cancelled before c11 claimed it, so it never
        // ran; the spool gets the same request signed for the spool only.
        let spooledRequest = caller.credential.map { request.signed(with: $0, mode: .spool) } ?? request
        let spooled = (try? spool(C11Relay.SpoolRecord(spooledRequest))) ?? false
        return .unreachable(spooled: spooled, spoolFull: !spooled, link: link)
    }

    private func acquire(_ request: C11Relay.Request) throws -> (Int, UInt64) {
        let start = nextStart
        for offset in 0..<C11Relay.slotCount {
            let slot = (start + offset) % C11Relay.slotCount
            let (value, version) = try read(slot)
            guard C11Relay.SlotState(value).isAvailable(now: wallMilliseconds()) else { continue }
            do {
                let written = try store.set(C11Relay.slotName(slot), value: request.dictionary, version: version)
                nextStart = slot
                return (slot, written)
            } catch C11RelayStoreError.conflict {
                continue
            } catch let C11RelayStoreError.unavailable(detail) {
                throw C11RelayCallError.store(detail)
            }
        }
        throw C11RelayCallError.busy
    }

    private func free(_ slot: Int, version: UInt64) {
        _ = try? store.set(C11Relay.slotName(slot), value: nil, version: version)
    }

    private func read(_ slot: Int) throws -> (Any?, UInt64) { try read(name: C11Relay.slotName(slot)) }

    private func read(name: String) throws -> (Any?, UInt64) {
        do { return try store.get(name) }
        catch let C11RelayStoreError.unavailable(detail) { throw C11RelayCallError.store(detail) }
    }
}

/// C11H-97: traces that tell "never reached c11" from "served empty".
enum C11RelayTrace {
    /// The relay folder's own log on the relayed machine (the CLI side).
    static func logURL(home: String, session: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".local/share/c11/relay/\(session)", isDirectory: true)
            .appendingPathComponent("log")
    }

    static let logLimitBytes = 256 * 1024

    /// The v2 JSON method, or the v1 text verb.
    static func method(framing: C11Relay.Framing, line: String) -> String {
        switch framing {
        case .text:
            return line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        case .json:
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let method = object["method"] as? String else { return "" }
            return method
        }
    }

    /// For a mailbox peek or ack reply, how many envelopes it carried or claimed.
    static func count(method: String, response: String) -> Int? {
        guard method == C11RelayMethods.mailboxPeek || method == C11RelayMethods.mailboxAck,
              let object = (try? JSONSerialization.jsonObject(with: Data(response.utf8))) as? [String: Any],
              let result = object["result"] as? [String: Any] else { return nil }
        if let messages = result["messages"] as? [Any] { return messages.count }
        return (result["acked"] as? NSNumber)?.intValue
    }

    /// One served call, as c11 logs it.
    static func servedLine(machine: String, slot: String, request: C11Relay.Request, response: String,
                           claimMilliseconds: Int?, late: Bool) -> String {
        let method = method(framing: request.framing, line: request.line)
        var line = "\(late ? "late" : "served") \(machine) \(slot) method=\(method.isEmpty ? "?" : method) panel=\(request.panel)"
            + " claim_ms=\(claimMilliseconds.map(String.init) ?? "rescan") reply_bytes=\(response.utf8.count)"
        if let count = count(method: method, response: response) { line += " count=\(count)" }
        return line
    }

    /// One CLI-side claim timeout, as the relay folder's log records it.
    static func timeoutLine(at date: Date, session: String, slot: Int?, request: C11Relay.Request,
                            waitedMilliseconds: Int, error: C11RelayCallError) -> String {
        let stamp = ISO8601DateFormatter().string(from: date)
        var spooled = false
        var link: C11Relay.LinkView?
        if case .unreachable(let s, _, let l) = error { spooled = s; link = l }
        func value(_ v: Int64?) -> String { v.map(String.init) ?? "none" }
        let method = method(framing: request.framing, line: request.line)
        return "\(stamp) claim_timeout session=\(session) slot=\(slot.map(String.init) ?? "none") method=\(method.isEmpty ? "?" : method)"
            + " panel=\(request.panel) waited_ms=\(waitedMilliseconds) spooled=\(spooled)"
            + " answered_s=\(value(link?.answered)) dropped_s=\(value(link?.dropped)) back_s=\(value(link?.back))"
    }

    /// Appends one line to `url`, bounded: past `limit` the file becomes
    /// `<name>.1` (replacing the older one) first. Writes only a regular file
    /// in an existing directory, never through a symlink. False when nothing
    /// was written.
    /// `beforeOpen` runs between the checks and the open; tests use it to
    /// swap the entry in that gap, where only `O_NOFOLLOW` still protects.
    @discardableResult
    static func append(_ line: String, to url: URL, limit: Int = logLimitBytes,
                       beforeOpen: (() -> Void)? = nil) -> Bool {
        var info = stat()
        let folder = url.deletingLastPathComponent().path
        guard lstat(folder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        let path = url.path
        let bytes = Array((line + "\n").utf8)
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else { return false }
            if Int(info.st_size) + bytes.count > limit { _ = rename(path, path + ".1") }
        }
        beforeOpen?()
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

/// C11H-134: a Claude Stop hook's mail drain on another machine. The inbox
/// lives with c11, so the hook peeks it through the relay (nothing is
/// claimed), writes what fits the hook's context budget to the harness, and
/// only then acknowledges exactly the messages it wrote. A dropped link or a
/// failed write claims nothing; a failed acknowledgement leaves the written
/// mail unread, so it is shown again rather than lost.
enum C11RelayHookDrain {
    struct Plan: Equatable {
        /// The hook's stdout JSON, without its trailing newline.
        let json: String
        /// The messages that JSON carries, oldest first: what gets acknowledged.
        let ids: [String]
    }

    enum Outcome: Equatable {
        /// Nothing written: no mail, the link was down, or the write failed.
        case none
        /// Written and acknowledged.
        case delivered(Int)
        /// Written, but the acknowledgement failed; the mail stays unread.
        case deliveredUnacknowledged(Int)

        var wroteMail: Bool { self != .none }
    }

    /// The relayed form of a Claude hook's journal draft: its own session id
    /// (and a parent's) dropped, since c11 owns this panel by hc's identity
    /// and attributes a sessionless event to it. A subagent's event is not
    /// sent: without its session it would read as the main agent's.
    static func journalEvent(_ draft: JournalDraft?) -> [String: Any]? {
        guard var draft, !draft.isChild else { return nil }
        draft.sessionID = nil
        draft.parentSessionID = nil
        guard (try? draft.validate()) != nil, let data = try? draft.canonicalData() else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// C11H-328: the `agent.report` a relayed Claude hook sends after its
    /// journal edge, built as a local hook builds it, for the caller's own
    /// panel. A Stop's final message is Claude's own field, else the bounded
    /// tail of its transcript on this machine. Nil when the hook reports
    /// nothing. Never spooled, so its text never reaches disk.
    static func agentReport(subcommand: String, panel: String, object: [String: Any], transcriptPath: String?,
                            environment: [String: String], now: Date = Date(),
                            readTranscript: (String) -> ClaudeStopTranscript.ReadResult? = { ClaudeStopTranscript.read(path: $0) })
        -> [String: Any]? {
        let stopText = ["stop", "idle"].contains(subcommand)
            ? ClaudeStopTranscript.StopText.read(hookMessage: object["last_assistant_message"] as? String,
                                                 transcriptPath: transcriptPath, readTranscript: readTranscript).report
            : nil
        return ClaudeAgentReport.hookParams(subcommand: subcommand, panelId: panel, object: object,
                                            stopText: stopText, environment: environment, now: now)
    }

    /// Peeked messages (`[{"id", "envelope"}]`, oldest first) as hook output.
    /// The first message is always carried whole; later ones stop at the
    /// budget, as the local drain does, and the rest are announced.
    static func plan(messages: [[String: Any]], format: MailboxHookFormat,
                     budget: Int = MailboxHookOutput.contextBudget) -> Plan? {
        var framed: [MailboxDelivery.Message] = []
        var ids: [String] = []
        var used = 0
        let readable = messages.compactMap { message -> (String, String)? in
            guard let id = message["id"] as? String, !id.isEmpty, let raw = message["envelope"] as? String else { return nil }
            return (id, raw)
        }
        for (id, raw) in readable {
            // The same message the local Stop drain frames (c11's agentMessage),
            // in one delivery whose boundary this machine mints.
            let message = MailboxDrain.agentMessage(data: Data(raw.utf8), fallbackId: id)
            let size = MailboxDelivery.cost(message).count
            if !framed.isEmpty, used + size > budget { break }
            framed.append(message)
            ids.append(id)
            used += size
        }
        guard !framed.isEmpty else { return nil }
        let context = MailboxHookOutput.context(messages: framed, remaining: readable.count - framed.count)
        let json = MailboxHookOutput.render(MailboxHookOutput.payload(context: context, format: format))
        return json.isEmpty ? nil : Plan(json: json, ids: ids)
    }

    /// Claude kills a Stop hook at 10 s and discards its output; every relay
    /// call this hook makes must be answered before this age of the process.
    static let hookBudgetSeconds: TimeInterval = 9
    /// The longest a relay reply is waited for once c11 claimed the request.
    static let replySeconds: TimeInterval = 2

    /// The timeout for the next relay call by a hook process this old, or nil
    /// when there is no time left to make the call at all. A read or spoolable
    /// call (the peek, a journal edge) spends it on claim and reply together;
    /// a write (the ack) first waits its usual claim bound, which this leaves
    /// room for, so either kind is answered before `hookBudgetSeconds`.
    static func replyTimeout(processElapsedSeconds: TimeInterval?, claimSeconds: TimeInterval) -> TimeInterval? {
        let left = hookBudgetSeconds - (processElapsedSeconds ?? 0) - claimSeconds
        return left >= 0.1 ? min(replySeconds, left) : nil
    }

    /// One drain: `call` sends a relay method and returns its result (it
    /// throws on refusal or an unreachable link); `write` puts the hook JSON
    /// on stdout and says whether it got there. Only a Stop that may drain
    /// (a real turn end, not a Stop-hook continuation) before the claim
    /// cutoff peeks, so a turn that delivered mail always ends at its next Stop.
    static func run(format: MailboxHookFormat, input: MailboxHookInput, processElapsedSeconds: TimeInterval?,
                    call: (_ method: String, _ params: [String: Any]) throws -> [String: Any],
                    write: (String) -> Bool) -> Outcome {
        guard MailboxHookOutput.shouldDrain(format: format, input: input),
              MailboxHookOutput.mayClaim(processElapsedSeconds: processElapsedSeconds),
              let peeked = try? call(C11RelayMethods.mailboxPeek, [:]),
              let plan = plan(messages: peeked["messages"] as? [[String: Any]] ?? [], format: format),
              write(plan.json + "\n") else { return .none }
        do {
            _ = try call(C11RelayMethods.mailboxAck, ["ids": plan.ids])
            return .delivered(plan.ids.count)
        } catch {
            return .deliveredUnacknowledged(plan.ids.count)
        }
    }
}
