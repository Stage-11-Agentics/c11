import Darwin
import Foundation

/// `c11-core` (C11H-37): a standalone terminal utility for c11's own hc core.
///
/// It runs from any terminal and always reaches the core c11 itself launches:
/// the session and socket come from `HCLaunchPolicy` for this build, never from
/// `HC_SESSION`, `HC_SOCKET` or `PATH`. Before reading or changing anything it
/// proves, read-only, that the peer is this user's process serving c11's pinned
/// build for this session, with `HCBuildVerifier`, the app's own checks. It never
/// starts a core of its own, never runs `hc update`, never kills by name, and
/// never touches the holder. hc lets any process of this user drive its socket,
/// so the utility widens nothing; it never goes through c11's app socket.
///
/// Everything that touches the machine goes through `HCCoreHost`, so tests use a
/// fake core and a fake process table; no live process is signalled on a host.
enum HCCoreUtility {
    static let schema = "c11.core/1"
    static let actionSchema = "c11.core.action/1"
}

// MARK: - Refusals and exit codes

enum HCCoreExit {
    static let ok: Int32 = 0
    static let usage: Int32 = 2
    static let notOurCore: Int32 = 3
    static let notRunning: Int32 = 4
    static let actionFailed: Int32 = 5
    static let declined: Int32 = 6
    /// C11H-352: `end-abandoned` on a session that is not abandoned.
    static let notAbandoned: Int32 = 7
}

enum HCCoreRefusal: String, Error, Equatable, Sendable {
    case coreNotRunning = "core_not_running"
    case socketNotOwned = "socket_not_owned"
    case wrongSession = "wrong_session"
    case notC11hPin = "not_c11_pin"

    var exitCode: Int32 { self == .coreNotRunning ? HCCoreExit.notRunning : HCCoreExit.notOurCore }
}

struct HCCoreCheck: Equatable, Sendable {
    let check: String
    let ok: Bool
    let detail: String

    var json: [String: Any] { ["check": check, "ok": ok, "detail": detail] }
}

// MARK: - Wire and host seams

struct HCCoreRPCError: Error, Equatable, CustomStringConvertible, Sendable {
    let code: String
    let message: String
    var description: String { "\(code): \(message)" }
}

/// One plain (unframed) JSON-RPC connection to an hc core, after `hello`.
protocol HCCoreLink: AnyObject {
    var peerUID: UInt32? { get }
    var peerPID: Int32? { get }
    var hello: [String: Any] { get }
    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) throws -> [String: Any]
    func close()
}

extension HCCoreLink {
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        try call(method, params, timeout: 5)
    }
}

struct HCCoreSocketFacts: Equatable, Sendable {
    let isSocket: Bool
    let ownerUID: UInt32
}

struct HCCoreProcessFacts: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let uid: UInt32
    let startedAt: Date
}

/// One row of a process table sample: CPU percent and resident bytes.
struct HCCoreProcessSample: Equatable, Sendable {
    let pid: Int32
    let parentPID: Int32
    let cpuPercent: Double
    let residentBytes: UInt64
}

struct HCCorePanelRef: Equatable, Sendable {
    let ref: String?
    let workspace: String?
}

protocol HCCoreHost {
    var uid: UInt32 { get }
    var machineName: String { get }
    func now() -> Date
    func socketFacts(_ path: String) -> HCCoreSocketFacts?
    func connect(_ path: String) throws -> HCCoreLink
    /// `HCBuildVerifier.verifyStateEndpoint`: core.lock and core.json are this session's.
    func verifyStateEndpoint(_ configuration: HCLaunchConfiguration, coreID: String) throws
    /// `HCBuildVerifier.verify`: uid, pid, protocol, executable path and SHA-256 against the pin.
    func verifyPeer(_ evidence: HCPeerEvidence, _ configuration: HCLaunchConfiguration) throws -> HCVerifiedPeer
    func process(_ pid: Int32) -> HCCoreProcessFacts?
    func processTable() -> [HCCoreProcessSample]
    /// When the terminal's tty last carried output, or nil.
    func ttyLastOutput(pid: Int32) -> Date?
    /// c11's own panel map: panel UUID (lowercased) to `panel:N` and workspace title.
    func panelMap() -> [String: HCCorePanelRef]
    func sleep(_ seconds: TimeInterval)
}

// MARK: - Opening a verified core

struct HCCoreConnection {
    let configuration: HCLaunchConfiguration
    let link: HCCoreLink
    let status: [String: Any]
    let verified: HCVerifiedPeer
    let checks: [HCCoreCheck]
    var corePID: Int32 { verified.identity.process.pid }
    var coreID: String { verified.identity.coreID }
}

enum HCCoreOpenResult {
    case verified(HCCoreConnection)
    case refused(HCCoreRefusal, checks: [HCCoreCheck], detail: String)
}

extension HCCoreUtility {
    static func open(_ configuration: HCLaunchConfiguration, host: HCCoreHost) -> HCCoreOpenResult {
        var checks: [HCCoreCheck] = []
        let path = configuration.socketURL.path
        func refuse(_ refusal: HCCoreRefusal, _ check: String, _ detail: String) -> HCCoreOpenResult {
            checks.append(HCCoreCheck(check: check, ok: false, detail: detail))
            return .refused(refusal, checks: checks, detail: detail)
        }
        guard let socket = host.socketFacts(path) else {
            return refuse(.coreNotRunning, "socket", "no socket at \(path)")
        }
        guard socket.isSocket, socket.ownerUID == host.uid else {
            return refuse(.socketNotOwned, "socket_owner", socket.isSocket
                ? "owner uid \(socket.ownerUID), want \(host.uid)" : "\(path) is not a socket")
        }
        checks.append(HCCoreCheck(check: "socket_owner", ok: true, detail: "uid \(host.uid)"))
        let link: HCCoreLink
        do { link = try host.connect(path) } catch {
            return refuse(.coreNotRunning, "connect", "nothing answers on \(path)")
        }
        let status: [String: Any]
        do { status = try link.call("server.status") } catch {
            link.close()
            return refuse(.coreNotRunning, "status", "the core did not answer server.status")
        }
        let hello = link.hello
        guard let coreID = (hello["core"] as? [String: Any])?["id"] as? String, !coreID.isEmpty,
              (status["core"] as? [String: Any])?["id"] as? String == coreID,
              let version = hello["version"] as? String, status["version"] as? String == version,
              let statusPID = (status["pid"] as? NSNumber).map({ $0.int32Value }) else {
            link.close()
            return refuse(.notC11hPin, "hello", "hello and server.status disagree, or are not hc's")
        }
        guard link.peerUID == host.uid, let peerPID = link.peerPID, peerPID == statusPID else {
            link.close()
            return refuse(.socketNotOwned, "peer", "peer uid \(link.peerUID.map { String($0) } ?? "?") pid \(link.peerPID.map { String($0) } ?? "?"), status pid \(statusPID)")
        }
        checks.append(HCCoreCheck(check: "peer", ok: true, detail: "pid \(peerPID), uid \(host.uid)"))
        do { try host.verifyStateEndpoint(configuration, coreID: coreID) } catch {
            link.close()
            return refuse(.wrongSession, "session", "core \(coreID) is not session \(configuration.session)'s (core.lock/core.json)")
        }
        checks.append(HCCoreCheck(check: "session", ok: true, detail: configuration.session))
        let generation = (hello["generation"] as? NSNumber)?.intValue ?? configuration.pin.protocolGeneration
        let evidence = HCPeerEvidence(
            uid: host.uid, pid: peerPID, statusPID: statusPID, coreID: coreID, version: version,
            protocolGeneration: generation,
            methods: Set((hello["methods"] as? [String]) ?? []),
            features: Set((hello["features"] as? [String]) ?? []))
        let verified: HCVerifiedPeer
        do { verified = try host.verifyPeer(evidence, configuration) } catch {
            link.close()
            let reason = error as? HCUnavailableReason
            if reason == .foreignSession {
                return refuse(.wrongSession, "pin", "the core is not this session's")
            }
            if reason == .coreUnreachable || reason == .connectionLost {
                return refuse(.coreNotRunning, "pin", "the core went away while it was checked")
            }
            return refuse(.notC11hPin, "pin", "peer pid \(peerPID) is not c11's hc \(configuration.pin.version)")
        }
        guard verified.isPinnedBuild else {
            link.close()
            let served = verified.identity
            return refuse(.notC11hPin, "pin", "peer pid \(peerPID) runs \(served.executablePath) (sha \(short(served.pin.executableSHA256)), hc \(served.pin.version)), want \(configuration.executableURL.path) (sha \(short(configuration.pin.executableSHA256)))")
        }
        checks.append(HCCoreCheck(check: "pin", ok: true, detail: "hc \(version), sha \(short(configuration.pin.executableSHA256))"))
        return .verified(HCCoreConnection(configuration: configuration, link: link, status: status,
                                          verified: verified, checks: checks))
    }

    static func short(_ sha: String) -> String {
        sha.count > 12 ? "\(sha.prefix(8))…\(sha.suffix(4))" : sha
    }
}

// MARK: - Addresses and printable text (C11H-357)

extension HCCoreUtility {
    /// The longest local id and machine name c11-core reads. hc numbers its
    /// terminals from `t1`, so a real id stays far shorter.
    static let localAddressLimit = 24
    static let machineNameLimit = 64

    /// hc's terminal address and nothing else: `tN` (`HCLocalTerminalAddress`,
    /// the rule the app's attach path applies) or `<machine>/tN` with an
    /// `isAddressMachineName` machine. Every address c11-core lists, shows or
    /// opens passes this first; an hc record whose address fails it is
    /// dropped, never repaired.
    static func isTerminalAddress(_ raw: String) -> Bool {
        guard raw.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let local = parts.last.map(String.init),
              local.count <= localAddressLimit, HCLocalTerminalAddress.isValid(local) else { return false }
        guard parts.count == 2 else { return true }
        return isAddressMachineName(String(parts[0]))
    }

    /// The machine in `<machine>/tN`: 1 to 64 ASCII letters, digits, `.`, `_`
    /// or `-`, starting with a letter or digit, and never c11-core's own word
    /// `local`. It covers every name `link`, pairing and Add Machine create.
    static func isAddressMachineName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        func alphanumeric(_ s: Unicode.Scalar) -> Bool { s.isASCII && CharacterSet.alphanumerics.contains(s) }
        guard let first = scalars.first, alphanumeric(first), scalars.count <= machineNameLimit, name != "local" else { return false }
        return scalars.allSatisfy { alphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// Text from hc or a linked machine, safe to print on a terminal: each C0
    /// control, DEL and C1 control becomes a visible `\xHH`, so the text cannot
    /// start a line, move the cursor or send an escape sequence. Command output
    /// may keep its line feeds.
    static func printable(_ value: String, keepLineFeeds: Bool = false) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if (code < 0x20 || (0x7F...0x9F).contains(code)) && !(keepLineFeeds && code == 0x0A) {
                out.append(contentsOf: String(format: "\\x%02X", code).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// `show` and `open` refuse an argument that is not an hc address.
    static func addressRefusal(_ verb: String, _ address: String) -> String {
        "\(verb) <terminal>: \(printable(address)) is not a terminal address (tN or <machine>/tN)"
    }

    /// `link` refuses a name that is not a machine name.
    static func linkNameRefusal(_ machine: String) -> String {
        "link <machine>: \(printable(machine)) is not a machine name"
    }
}

// MARK: - Snapshot

struct HCCoreTerminal: Equatable {
    struct Agent: Equatable { let name: String; let status: String?; let statusAt: Date?; let turn: Int? }
    struct Foreground: Equatable { let name: String; let pid: Int32? }
    struct LastActive: Equatable { let at: Date; let source: String }

    let address: String
    let machine: String
    let state: String
    let pid: Int32?
    let agent: Agent?
    let foreground: Foreground?
    let cwd: String?
    let launchedAt: Date?
    let lastActive: LastActive?
    let cpuPercent: Double?
    let memoryBytes: UInt64?
    let cols: Int?
    let rows: Int?
    let screenCopy: String?
    let exitCode: Int?
    let panelID: String?
    let panel: HCCorePanelRef?

    var isLocal: Bool { machine == "local" }
    var panelLink: String? { panelID.map { "c11://panel/\($0)" } }
}

struct HCCoreMachine: Equatable {
    let name: String
    let state: String
    let version: String?
    let host: String?
}

struct HCCoreSnapshot: Equatable {
    let generatedAt: Date
    let machineName: String
    let session: String
    let socket: String
    let pin: HCPin
    let pinPath: String
    let checks: [HCCoreCheck]
    let corePID: Int32
    let coreVersion: String
    let coreID: String
    let coreStartedAt: Date?
    let holderPID: Int32?
    let holderStartedAt: Date?
    let terminals: [HCCoreTerminal]
    let machines: [HCCoreMachine]
    /// C11H-357: hc records dropped because their address is not hc's shape, or
    /// because a `terminal.get` reply named another terminal than the one asked.
    var refused = 0

    var live: [HCCoreTerminal] { terminals.filter { $0.state == "live" } }
}

extension HCCoreUtility {
    /// Reads c11's verified core: status, every terminal (with `terminal.get`
    /// for labels and pids), machines, and local stats from the host.
    static func snapshot(_ connection: HCCoreConnection, host: HCCoreHost) throws -> HCCoreSnapshot {
        let link = connection.link
        let listed = try link.call("terminal.list", ["all": true])
        // C11H-357: a linked machine's records reach this list through hc
        // unchecked. Only hc's own address shape is read, and a reply is kept
        // only when it describes the terminal that was asked for.
        var records: [[String: Any]] = []
        var refused = 0
        var seen = Set<String>()
        for row in (listed["terminals"] as? [[String: Any]]) ?? [] {
            guard let address = row["address"] as? String, isTerminalAddress(address) else {
                refused += 1
                continue
            }
            guard seen.insert(address).inserted,
                  let got = try? link.call("terminal.get", ["terminal": address]) else { continue }
            let record = (got["terminal"] as? [String: Any]) ?? got
            // Scalars, not `==`: Swift's string equality treats canonically
            // equivalent spellings (a KELVIN SIGN for `K`) as the same address.
            guard (record["address"] as? String)?.unicodeScalars.elementsEqual(address.unicodeScalars) == true else {
                refused += 1
                continue
            }
            records.append(record)
        }
        let machinesValue = (try? link.call("machine.list")) ?? [:]
        let machines = ((machinesValue["machines"] as? [[String: Any]]) ?? []).compactMap { value -> HCCoreMachine? in
            guard let name = value["name"] as? String else { return nil }
            return HCCoreMachine(name: name, state: value["state"] as? String ?? "unknown",
                                 version: value["version"] as? String, host: value["host"] as? String)
        }
        let table = host.processTable()
        let panels = host.panelMap()
        let terminals = records.map { terminal(from: $0, table: table, panels: panels, host: host) }
            // Undated records sort last, away from watch's starting cursor.
            .sorted { ($0.launchedAt ?? .distantFuture, $0.address) < ($1.launchedAt ?? .distantFuture, $1.address) }
        let holder = holderPID(of: terminals, host: host, corePID: connection.corePID)
        return HCCoreSnapshot(
            generatedAt: host.now(), machineName: host.machineName,
            session: connection.configuration.session, socket: connection.configuration.socketURL.path,
            pin: connection.configuration.pin, pinPath: connection.configuration.executableURL.path,
            checks: connection.checks, corePID: connection.corePID,
            coreVersion: connection.verified.identity.pin.version, coreID: connection.coreID,
            coreStartedAt: host.process(connection.corePID)?.startedAt,
            holderPID: holder, holderStartedAt: holder.flatMap { host.process($0)?.startedAt },
            terminals: terminals, machines: machines, refused: refused)
    }

    /// The holder is the parent of every local terminal's root process, and a
    /// child of the core that spawned it (or of launchd after a core restart).
    static func holderPID(of terminals: [HCCoreTerminal], host: HCCoreHost, corePID: Int32) -> Int32? {
        let parents = terminals.filter { $0.isLocal && $0.state == "live" }
            .compactMap { $0.pid.flatMap { host.process($0)?.parentPID } }
        guard let first = parents.first, first > 1, first != corePID,
              parents.allSatisfy({ $0 == first }), host.process(first)?.uid == host.uid else { return nil }
        return first
    }

    static func terminal(from record: [String: Any], table: [HCCoreProcessSample],
                         panels: [String: HCCorePanelRef], host: HCCoreHost) -> HCCoreTerminal {
        let address = record["address"] as? String ?? "?"
        let slash = address.firstIndex(of: "/")
        let machine = slash.map { String(address[..<$0]) } ?? "local"
        let local = slash == nil
        let state = record["state"] as? String ?? "unknown"
        let pid = local ? int32(record["pid"]) : nil
        let foregroundValue = record["foreground"] as? [String: Any]
        let foreground = foregroundValue.flatMap { value -> HCCoreTerminal.Foreground? in
            guard let name = value["name"] as? String, !name.isEmpty else { return nil }
            return HCCoreTerminal.Foreground(name: name, pid: local ? int32(value["pid"]) : nil)
        }
        let statusValue = record["status"]
        let statusState = (statusValue as? [String: Any])?["state"] as? String ?? statusValue as? String
        let statusAt = date(milliseconds: record["status_ms"])
        let agentName = record["agent"] as? String
        // hc names a plain shell's agent "sh"; only a real agent carries a status.
        let agent: HCCoreTerminal.Agent? = agentName.flatMap { name in
            (name.isEmpty || (name == "sh" && statusState == nil)) ? nil
                : HCCoreTerminal.Agent(name: name, status: statusState, statusAt: statusAt, turn: int(record["turn"]))
        }
        let tty = local ? (foreground?.pid ?? pid).flatMap { host.ttyLastOutput(pid: $0) } : nil
        let lastActive: HCCoreTerminal.LastActive? = {
            switch (tty, statusAt) {
            case let (tty?, status?): return status > tty ? .init(at: status, source: "status") : .init(at: tty, source: "tty")
            case let (tty?, nil): return .init(at: tty, source: "tty")
            case let (nil, status?): return .init(at: status, source: "status")
            default: return nil
            }
        }()
        let usage = (local && state == "live") ? pid.flatMap { treeUsage(root: $0, table: table) } : nil
        let screen = record["screen"] as? String
        // c11 labels its terminals with a panel UUID; anything else is not c11's.
        let panelID = ((record["labels"] as? [String: Any])?["c11.panel"] as? String)
            .flatMap(UUID.init(uuidString:))?.uuidString.lowercased()
        return HCCoreTerminal(
            address: address, machine: machine, state: state, pid: pid, agent: agent, foreground: foreground,
            cwd: (foregroundValue?["cwd"] as? String) ?? (record["cwd"] as? String),
            launchedAt: date(milliseconds: record["created_ms"]), lastActive: lastActive,
            cpuPercent: usage?.cpu, memoryBytes: usage?.memory,
            cols: int(record["cols"]), rows: int(record["rows"]),
            screenCopy: screen.map { $0 == "exact" ? "exact" : "rebuilt" },
            exitCode: int(record["exit_code"]), panelID: panelID,
            panel: panelID.flatMap { panels[$0] })
    }

    /// CPU and memory of a terminal's root process and every descendant.
    static func treeUsage(root: Int32, table: [HCCoreProcessSample]) -> (cpu: Double, memory: UInt64)? {
        guard table.contains(where: { $0.pid == root }) else { return nil }
        var children: [Int32: [HCCoreProcessSample]] = [:]
        for row in table { children[row.parentPID, default: []].append(row) }
        var cpu = 0.0, memory: UInt64 = 0, stack = [root], seen = Set<Int32>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if let row = table.first(where: { $0.pid == pid }) { cpu += row.cpuPercent; memory += row.residentBytes }
            stack.append(contentsOf: (children[pid] ?? []).map(\.pid))
        }
        return (cpu, memory)
    }

    static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    static func int32(_ value: Any?) -> Int32? { (value as? NSNumber).map { $0.int32Value } }
    /// 2100-01-01. A time from hc past it is not a time (C11H-357): a remote
    /// value near `Double.greatestFiniteMagnitude` would trap the screens'
    /// whole-second arithmetic.
    static let latestMilliseconds = 4_102_444_800_000.0

    static func date(milliseconds value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0, ms < latestMilliseconds else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

// MARK: - c11.core/1 JSON

extension HCCoreUtility {
    /// A JSON value or `null`.
    static func n(_ value: Any?) -> Any { value ?? NSNull() }

    static func iso(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func uptime(_ start: Date?, now: Date) -> Any {
        guard let start else { return NSNull() }
        return max(0, Int(now.timeIntervalSince(start)))
    }

    static func json(_ snapshot: HCCoreSnapshot) -> [String: Any] {
        let now = snapshot.generatedAt
        let live = snapshot.terminals.filter { $0.state == "live" }.count
        let finished = snapshot.terminals.filter { $0.state == "finished" }.count
        let items: [[String: Any]] = snapshot.terminals.map { t in
            var item: [String: Any] = [
                "address": t.address, "machine": t.machine, "state": t.state,
                "agent": n(t.agent.map { a -> Any in
                    ["name": a.name, "status": n(a.status), "status_at": iso(a.statusAt), "turn": n(a.turn)]
                }),
                "foreground": n(t.foreground.map { f -> Any in ["name": f.name, "pid": n(f.pid)] }),
                "cwd": n(t.cwd),
                "launched_at": iso(t.launchedAt),
                "last_active": n(t.lastActive.map { l -> Any in ["at": iso(l.at), "source": l.source] }),
                "cpu_percent": n(t.cpuPercent.map { ($0 * 10).rounded() / 10 }),
                "memory_bytes": n(t.memoryBytes),
                "size": n(t.cols.flatMap { cols in t.rows.map { ["cols": cols, "rows": $0] } }),
                "screen_copy": n(t.screenCopy),
                "c11_panel": n(t.panelID.map { id -> Any in
                    ["id": id, "ref": n(t.panel?.ref), "workspace": n(t.panel?.workspace), "link": "c11://panel/\(id)"]
                }),
                "open": n(t.state == "live"
                    ? ["watch": "c11-core open \(t.address)", "take_over": "c11-core open \(t.address) --take-over"]
                    : nil),
            ]
            if let exit = t.exitCode { item["exit_code"] = exit }
            return item
        }
        let linked = snapshot.machines.filter { $0.name != "local" }
        return [
            "schema": schema,
            "generated_at": iso(now),
            "machine": snapshot.machineName,
            "session": snapshot.session,
            "socket": snapshot.socket,
            "verified": ["ok": true,
                         "pin": ["version": snapshot.pin.version, "path": snapshot.pinPath, "sha256": snapshot.pin.executableSHA256],
                         "checks": snapshot.checks.map(\.json)],
            "core": ["version": snapshot.coreVersion, "pid": snapshot.corePID, "core_id": snapshot.coreID,
                     "started_at": iso(snapshot.coreStartedAt), "uptime_s": uptime(snapshot.coreStartedAt, now: now)],
            "holder": n(snapshot.holderPID.map { pid -> Any in
                ["pid": pid, "started_at": iso(snapshot.holderStartedAt), "uptime_s": uptime(snapshot.holderStartedAt, now: now),
                 "terminals_owned": snapshot.terminals.filter { $0.isLocal && $0.state == "live" }.count]
            }),
            "terminals": ["count": ["live": live, "finished": finished,
                                    "starting": snapshot.terminals.filter { $0.state == "starting" }.count],
                          "items": items, "refused": snapshot.refused],
            "machines": [["name": "local", "state": "local", "host": snapshot.machineName]] + linked.map { m -> [String: Any] in
                ["name": m.name, "state": m.state, "version": n(m.version),
                 "pin_ok": n(m.version.map { $0 == snapshot.pin.version })]
            },
            "actions": [["name": "restart", "available": true]] + linked.map { m -> [String: Any] in
                m.state == "connected"
                    ? ["name": "reconnect", "machine": m.name, "available": false, "why": "connected"]
                    : ["name": "reconnect", "machine": m.name, "available": true]
            },
        ]
    }

    /// A refusal as JSON: nothing from a core that isn't c11's is read.
    static func refusalJSON(_ refusal: HCCoreRefusal, checks: [HCCoreCheck], detail: String,
                            configuration: HCLaunchConfiguration) -> [String: Any] {
        ["schema": schema, "ok": false,
         "session": configuration.session, "socket": configuration.socketURL.path,
         "verified": ["ok": false, "checks": checks.map(\.json)],
         "error": ["code": refusal.rawValue, "detail": detail]]
    }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        // JSONSerialization escapes only U+0000 to U+001F. DEL and the C1
        // controls can only sit inside JSON strings, where `\uXXXX` is the same
        // value, so they are escaped too and never reach a terminal raw.
        var out = String.UnicodeScalarView()
        for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
            if (0x7F...0x9F).contains(scalar.value) {
                out.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}

// MARK: - Screens

struct HCCoreStyle {
    var color: Bool
    var links: Bool

    static let plain = HCCoreStyle(color: false, links: false)

    func paint(_ text: String, _ code: String) -> String { color ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    func bold(_ t: String) -> String { paint(t, "1") }
    func dim(_ t: String) -> String { paint(t, "2") }
    func green(_ t: String) -> String { paint(t, "32") }
    func yellow(_ t: String) -> String { paint(t, "33") }
    func red(_ t: String) -> String { paint(t, "31") }

    /// OSC 8: c11's terminals open `c11://panel/<id>` on ⌘-click. Elsewhere
    /// the link would do nothing, so the text says where it works.
    func link(_ text: String, _ url: String) -> String {
        links ? "\u{1B}]8;;\(url)\u{1B}\\\(text)\u{1B}]8;;\u{1B}\\" : text
    }
}

extension HCCoreUtility {
    /// A table cell: printable (C11H-357), then cut or padded to `width`.
    static func pad(_ raw: String, _ width: Int) -> String {
        let s = printable(raw)
        let count = s.count
        return count >= width ? String(s.prefix(width)) : s + String(repeating: " ", count: width - count)
    }

    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        let m = s / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h ago" }
        return h > 0 ? "\(h)h \(m % 60)m ago" : "\(m)m ago"
    }

    static func duration(_ start: Date?, now: Date) -> String {
        guard let start else { return "—" }
        let s = max(0, Int(now.timeIntervalSince(start))), m = s / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        return h > 0 ? "\(h)h \(m % 60)m" : "\(m)m"
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1fG", mb / 1024) : "\(Int(mb.rounded()))M"
    }

    static func shortPath(_ path: String?, home: String) -> String {
        guard var path else { return "—" }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
        guard path.count > 15 else { return path }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count > 2 ? "\(parts[0])/…/\(parts.suffix(2).joined(separator: "/"))".suffixFit(15) : path.suffixFit(15)
    }

    static func agentText(_ t: HCCoreTerminal) -> String {
        guard let agent = t.agent else { return "—" }
        return printable([agent.name, agent.status].compactMap { $0 }.joined(separator: " "))
    }

    static func panelText(_ t: HCCoreTerminal, style: HCCoreStyle) -> String {
        guard let id = t.panelID else { return "—" }
        let ref = printable(t.panel?.ref ?? "panel")
        return style.link("\(ref) ↗", "c11://panel/\(id)")
    }

    static func refusedLine(_ count: Int) -> String {
        "\(count) hc record(s) not shown: not an hc terminal address, or not the terminal asked for"
    }

    /// The status list (`c11-core`). Lines stay within 120 columns.
    static func renderStatus(_ s: HCCoreSnapshot, style: HCCoreStyle, home: String, all: Bool = false, insideC11h: Bool) -> String {
        let now = s.generatedAt
        var out: [String] = []
        out.append("\(style.bold("c11 core")) · session \(style.bold(s.session)) · \(s.machineName)        \(style.green("✓ c11's pin"))")
        out.append("  core     herdr-core \(s.coreVersion)  pid \(s.corePID)  up \(duration(s.coreStartedAt, now: now))  \(style.dim("sha \(short(s.pin.executableSHA256))"))")
        if let holder = s.holderPID {
            out.append("  holder   pid \(holder)  up \(duration(s.holderStartedAt, now: now))  holds \(s.terminals.filter { $0.isLocal && $0.state == "live" }.count) terminals  \(style.dim("if it ends, every terminal ends"))")
        }
        out.append("")
        let live = s.live
        let finished = s.terminals.filter { $0.state == "finished" }
        let hint = insideC11h ? "⌘-click a c11 panel to jump to it" : "jump: inside c11"
        out.append("\(style.bold("terminals"))  \(style.green("\(live.count) live")) · \(finished.count) finished    \(style.dim(hint))")
        out.append("  " + style.dim([pad("ADDR", 10), pad("AGENT", 16), pad("FOREGROUND", 12), pad("CWD", 16), pad("LAUNCHED", 15),
                                     pad("LAST ACTIVE", 15), pad("CPU", 5), pad("MEM", 6), pad("SCREEN COPY", 12), "C11 PANEL"].joined()))
        let shown = all ? live + finished : Array(live.prefix(40))
        for t in shown where t.state == "live" || all {
            let last = t.lastActive.map { ago($0.at, now: now) + ($0.source == "status" ? " (st)" : "") } ?? "—"
            let copy = t.screenCopy == "rebuilt" ? style.yellow(pad("rebuilt", 12)) : pad(t.screenCopy ?? "—", 12)
            let state = t.state == "live" ? "" : " " + style.dim("(\(printable(t.state))\(t.exitCode.map { ", exit \($0)" } ?? ""))")
            out.append("  " + pad(t.address, 10) + pad(agentText(t), 16) + pad(t.foreground?.name ?? "—", 12)
                + pad(shortPath(t.cwd, home: home), 16)
                + pad(t.launchedAt.map { "\(clock($0)) (\(duration($0, now: now)))" } ?? "—", 15)
                + pad(last, 15) + pad(t.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—", 5)
                + pad(memory(t.memoryBytes), 6) + copy + panelText(t, style: style) + state)
        }
        if !all, live.count > shown.count || !finished.isEmpty {
            var more: [String] = []
            if live.count > shown.count { more.append("\(live.count - shown.count) more live") }
            if !finished.isEmpty { more.append("\(finished.count) finished") }
            out.append("  " + style.dim("… " + more.joined(separator: " · ") + " (--all lists them)"))
        }
        if s.refused > 0 { out.append("  " + style.yellow(refusedLine(s.refused))) }
        out.append("")
        out.append("  " + style.dim("SCREEN COPY  exact: hc holds a faithful copy of the screen."))
        out.append("  " + style.dim("             rebuilt: redrawn from the last 1 MiB of output after a core crash;"))
        out.append("  " + style.dim("             colors or layout can be off until the program repaints."))
        out.append("  " + style.dim("(st)         last active from the agent's status; remote ttys are not read."))
        out.append("")
        let linked = s.machines.filter { $0.name != "local" }
        let machineLine = (["local \(s.machineName)"] + linked.map { m in
            "\(printable(m.name)) " + (m.state == "connected" ? style.green("connected") : style.yellow(printable(m.state)))
                + (m.version.map { " \(printable($0))" + ($0 == s.pin.version ? " " + style.green("✓ pin") : " " + style.red("✗ not the pin")) } ?? "")
        }).joined(separator: " · ")
        out.append("\(style.bold("machines"))   \(machineLine)")
        out.append("")
        out.append(style.dim("c11-core show <t> · open <t> [--take-over] · watch · restart · reconnect <machine> · link <machine> · --json"))
        return out.joined(separator: "\n")
    }

    /// One terminal in detail (`c11-core show <t>`).
    static func renderShow(_ t: HCCoreTerminal, snapshot s: HCCoreSnapshot, style: HCCoreStyle, home: String, insideC11h: Bool) -> String {
        let now = s.generatedAt
        var out: [String] = []
        let agent = printable(t.agent.map { a in "\(a.name) · \(a.status ?? "—")" + (a.turn.map { " (turn \($0))" } ?? "") } ?? (t.foreground?.name ?? "—"))
        out.append("\(style.bold(t.address))  \(agent)    \(t.machine) · \(t.state == "live" ? style.green("live") : printable(t.state))")
        if let id = t.panelID {
            let where_ = printable([t.panel?.ref, t.panel?.workspace.map { "workspace \($0)" }].compactMap { $0 }.joined(separator: " · "))
            out.append("  c11 panel      \(panelText(t, style: style))  \(style.dim(where_.isEmpty ? id : where_))")
            out.append("                 " + style.dim(insideC11h ? "⌘-click to jump: c11://panel/\(id)"
                                                                 : "c11://panel/\(id) (jump: inside c11; Terminal.app cannot open c11 links)"))
        } else {
            out.append("  c11 panel      — " + style.dim("(no c11 panel shows this terminal)"))
        }
        out.append("  launched       " + (t.launchedAt.map { "\(iso($0) as? String ?? "") (\(ago($0, now: now)))" } ?? "—"))
        out.append("  last active    " + (t.lastActive.map { "\(ago($0.at, now: now)) " + style.dim($0.source == "tty" ? "(last output on its tty)" : "(the agent's last status change)") } ?? "—"))
        out.append("  cwd            " + (t.cwd.map { printable(shortPath($0, home: home) == $0 ? $0 : $0.replacingOccurrences(of: home, with: "~")) } ?? "—"))
        out.append("  foreground     " + (t.foreground.map { printable($0.name) + ($0.pid.map { "  " + style.dim("pid \($0)") } ?? "") } ?? "—"))
        out.append("  cpu / memory   " + (t.cpuPercent.map { String(format: "%.1f%%", $0) + " · " + memory(t.memoryBytes) + "  " + style.dim("(its processes)") } ?? "—"))
        out.append("  size           " + ((t.cols != nil && t.rows != nil) ? "\(t.cols!)×\(t.rows!)  " + style.dim("(set by the client active last)") : "—"))
        out.append("  screen copy    " + (t.screenCopy.map { $0 == "exact" ? "exact  " + style.dim("(hc holds a faithful copy of the screen)")
            : style.yellow("rebuilt") + "  " + style.dim("(redrawn from the last 1 MiB of output after a core crash)") } ?? "—"))
        if t.state == "live" {
            out.append("")
            out.append("  open outside c11")
            out.append("    c11-core open \(t.address)               " + style.dim("Terminal.app, watch only: never types or resizes"))
            out.append("    c11-core open \(t.address) --take-over   " + style.dim("Terminal.app, types and takes the size (asks first)"))
        }
        return out.joined(separator: "\n")
    }
}

private extension String {
    func suffixFit(_ width: Int) -> String {
        count <= width ? self : "…" + suffix(width - 1)
    }
}

// MARK: - open in Terminal.app

struct HCCoreOpenPlan: Equatable {
    let address: String
    let takeOver: Bool
    /// The `.command` Terminal.app runs. The address appears in it once, as
    /// the shell-quoted argument of its `exec` line.
    let script: String
    let fileName: String
}

/// `openPlan` refuses an address that is not hc's shape (C11H-357).
struct HCCoreInvalidAddress: Error, Equatable, CustomStringConvertible {
    var description: String { "not an hc terminal address (tN or <machine>/tN)" }
}

extension HCCoreUtility {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Watch-only by default (`--observe`: never types, never resizes). A
    /// take-over is a plain attach, which types and takes the size.
    /// C11H-357: the address is checked again here, where it meets a shell
    /// script, and enters the script only as the quoted `exec` argument.
    static func openPlan(address: String, takeOver: Bool, configuration: HCLaunchConfiguration) throws -> HCCoreOpenPlan {
        guard isTerminalAddress(address) else { throw HCCoreInvalidAddress() }
        let attach = takeOver ? "attach" : "attach --observe"
        let script = """
        #!/bin/sh
        # c11-core open\(takeOver ? " --take-over" : ""): one of c11's terminals in this window. ctrl+\\ detaches.
        rm -f "$0"
        export HC_SESSION=\(shellQuote(configuration.session)) HC_SOCKET=\(shellQuote(configuration.socketURL.path))
        exec \(shellQuote(configuration.executableURL.path)) \(attach) \(shellQuote(address))

        """
        let safe = address.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        return HCCoreOpenPlan(address: address, takeOver: takeOver, script: script,
                              fileName: "open-\(String(safe))-\(UUID().uuidString.prefix(8).lowercased()).command")
    }

    static func takeOverWarning(_ t: HCCoreTerminal) -> String {
        var lines = ["\(t.address) is open in c11\(t.panel?.ref.map { " (\(printable($0)))" } ?? ""). Taking it over in Terminal.app means:",
                     "  • both windows type into the same program, interleaved",
                     "  • the terminal takes Terminal.app's size; c11's panel shows cut or wrapped lines",
                     "    until you type in it again, and c11's input guard may misread the composer meanwhile"]
        if t.panelID == nil { lines[0] = "\(t.address) takes Terminal.app's size while you type there." }
        return lines.joined(separator: "\n")
    }
}

// MARK: - restart

enum HCCoreRestartOutcome {
    case restarted(HCCoreConnection)
    case failed(String)
}

extension HCCoreUtility {
    /// The planned restart, as c11's own recovery does it (`HCRecoveryCoordinator`):
    /// `server.restart` to the verified core (a lost reply is tolerated), wait for
    /// that exact process to exit, then wait for a verified core of the same
    /// session and core id in a new process. The holder keeps every program.
    static func restart(_ connection: HCCoreConnection, host: HCCoreHost, timeout: TimeInterval = 30) -> HCCoreRestartOutcome {
        let oldPID = connection.corePID
        let oldStart = host.process(oldPID)?.startedAt
        let configuration = connection.configuration
        _ = try? connection.link.call("server.restart", [:], timeout: 5)
        connection.link.close()
        let deadline = host.now().addingTimeInterval(timeout)
        func oldIsRunning() -> Bool {
            guard let facts = host.process(oldPID) else { return false }
            return oldStart == nil || facts.startedAt == oldStart
        }
        while oldIsRunning() {
            guard host.now() < deadline else { return .failed("the core (pid \(oldPID)) did not stop within \(Int(timeout)) s") }
            host.sleep(0.05)
        }
        while host.now() < deadline {
            if case .verified(let next) = open(configuration, host: host) {
                if next.corePID != oldPID, next.coreID == connection.coreID { return .restarted(next) }
                next.link.close()
            }
            host.sleep(0.25)
        }
        return .failed("the core stopped, but no verified core of session \(configuration.session) came back within \(Int(timeout)) s. c11 starts its core when it reconnects; if c11 is not running, open it.")
    }
}

// MARK: - link <machine>

enum HCCoreLinkPlan: Equatable {
    case ready([String])
    case refused(String)
}

extension HCCoreUtility {
    /// `link <machine>` uses the via script the install guide renders (remote
    /// machine section, step 2), and only if it runs c11's pinned hc for this
    /// session by its full path. It never renders one: the linked machine's
    /// paths are its own. `machine` is hc's name for it.
    /// A name `link` and pairing accept: an `isAddressMachineName`, never hc's
    /// own `default`. It is checked scalar by scalar.
    static func isLinkMachineName(_ name: String) -> Bool {
        name != "default" && isAddressMachineName(name)
    }

    /// A c11 terminal's environment, here or on a linked machine: the one
    /// rule `c11 machine link` and `c11-core link` use to refuse `--yes`
    /// (`scripts/c11-atlas-link.sh pair` applies the same three variables).
    static func insideC11Terminal(_ environment: [String: String]) -> Bool {
        ["C11_PANEL_ID", "C11_SURFACE_ID", "CMUX_SURFACE_ID"].contains { !(environment[$0] ?? "").isEmpty }
    }

    /// C11H-365: inside a c11 terminal a link is the operator's typed answer,
    /// never `--yes`, so an agent's shell there cannot link a machine. Nil
    /// when `link` may go on: no `--yes`, or outside a c11 terminal.
    static func linkYesRefusal(machine: String, yes: Bool, environment: [String: String]) -> String? {
        guard yes, insideC11Terminal(environment) else { return nil }
        return "link: --yes isn't accepted inside a c11 terminal. Linking gives c11 a shell on \(printable(machine)) as you, so the operator answers the question here, or uses Settings > Herder Topography > Add Machine."
    }

    /// The ssh target a via script dials, read as Update reads it; nil when
    /// the script is missing or not one c11 rendered.
    static func linkSSHTarget(script: String?) -> String? {
        script.flatMap { HCMachineSetup.ViaInfo.parse($0)?.target }
    }

    /// C11H-365: the plan `c11-core link` prints before it asks. It names the
    /// ssh target the via dials, or says it can't be read.
    static func linkPlanLines(machine: String, viaPath: String, script: String?) -> [String] {
        let target = linkSSHTarget(script: script).map { "ssh target \(printable($0))" } ?? "ssh target unreadable"
        return [
            "Plan (nothing changes until you say yes):",
            "  machine add \(machine), through \(printable(viaPath)) (\(target)), which runs c11's pinned hc on \(machine) by its full path,",
            "  checked against this build's pin at every dial. Linking gives c11 a shell on \(machine) as you (c11 guide trust).",
            "  herdr-app's default session is not touched on either machine.",
        ]
    }

    /// C11H-332: `linkPlan` for `c11-core link`, with a refused admission
    /// audited (`link refused via_unchecked`) like every other link entry point.
    static func admitLink(via: URL, script: String?, machine: String, configuration: HCLaunchConfiguration,
                          audit: C11AuditLog = .shared) -> HCCoreLinkPlan {
        let plan = linkPlan(via: via, script: script, machine: machine, configuration: configuration)
        if case .refused = plan {
            audit.append(C11AuditRecord(kind: .link, via: "c11-core", outcome: "refused",
                                        machine: isLinkMachineName(machine) ? machine : "invalid",
                                        session: configuration.session, path: via.path,
                                        code: script == nil ? "via_missing" : "via_unchecked"))
        }
        return plan
    }

    /// C11H-332: `c11-core link` for a machine already in the core's list.
    /// Its stored via is migrated or found unusable (`HCStoredLinks.review`);
    /// an unusable one is recorded here, as this command's own refusal,
    /// before the command returns. The app's session review records its own.
    static func reviewExistingLink(machine: String, viaPath: String?, home: URL, configuration: HCLaunchConfiguration,
                                   linkScript: URL?, adopted: Bool = HCLaunchPolicy.processNamespace != nil,
                                   audit: C11AuditLog = .shared) -> HCStoredLinks.Verdict {
        let verdict = HCStoredLinks.review(machine: machine, viaPath: viaPath, home: home,
                                           pinSHA256: configuration.pin.executableSHA256, mayWrite: true,
                                           linkScript: linkScript, adopted: adopted, audit: audit)
        if case .unusable(let code) = verdict {
            _ = audit.append(C11AuditRecord(kind: .link, via: "c11-core", outcome: "unusable",
                                            machine: isLinkMachineName(machine) ? machine : "invalid",
                                            session: configuration.session, path: viaPath, code: code,
                                            detail: "c11 won't use this link; hc may still redial it until you Update or Remove it"))
        }
        return verdict
    }

    static func linkPlan(via: URL, script: String?, machine: String, configuration: HCLaunchConfiguration) -> HCCoreLinkPlan {
        guard let script else {
            return .refused("no via script at \(via.path). For a build with a bundled helper, install and render it first: docs/c11-remote-core.md.")
        }
        let pinDirectory = "\(configuration.pin.version)-\(configuration.pin.executableSHA256.prefix(12))"
        let suffix = "/.local/share/c11/hc/\(pinDirectory)/herdr-core"
        let words = script.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // C11H-332: the launcher must check this pin at every dial: the word
        // before the executable is `sha256=<this build's executable hash>`.
        let pinWord = "sha256=\(configuration.pin.executableSHA256.lowercased())"
        let matches = words.indices.contains { index in
            let executable = words[index]
            guard executable.hasPrefix("/"), executable.hasSuffix(suffix), index > 0, words[index - 1] == pinWord,
                  index + 3 < words.count,
                  words[index + 1] == "connect", words[index + 2] == "--session",
                  words[index + 3].trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) == configuration.session else { return false }
            let remoteHome = String(executable.dropLast(suffix.count))
            return !remoteHome.isEmpty && !remoteHome.contains("..")
                && words.contains("XDG_CONFIG_HOME=\(remoteHome)/.local/share/c11/config")
        }
        guard matches else {
            return .refused("\(via.path) does not run c11's hc \(configuration.pin.version) for session \(configuration.session) by its full path, checked against this build's pin (render --sha); see docs/c11-remote-core.md for bundled-helper setup.")
        }
        // C11H-361: and its ssh forwards nothing (no agent, X11 or ports).
        guard HCStoredLinks.forwardsNothing(script) else {
            return .refused("\(via.path) lets ssh forward this Mac's agent, X11 or ports; render it again with this build's link script (docs/c11-remote-core.md).")
        }
        return .ready(["machine", "add", "--name", machine, "--session", configuration.session, "--via", via.path])
    }

    /// Runs c11's pinned binary against c11's verified core: the session and
    /// socket are explicit and nothing else is inherited. `interactive` keeps
    /// the terminal attached (a machine login may ask for a code).
    static func runPinned(_ arguments: [String], configuration: HCLaunchConfiguration,
                          interactive: Bool = false, timeout: TimeInterval = 90) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = arguments
        var environment = configuration.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !agent.isEmpty {
            environment["SSH_AUTH_SOCK"] = agent // a key held only by ssh-agent can still log in
        }
        process.environment = environment
        let pipe = Pipe()
        if !interactive {
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return (-1, "could not run \(configuration.executableURL.path): \(error)") }
        // Drain the pipe on its own thread so a chatty child cannot block on a
        // full pipe, and wait for the child first so the timeout always applies.
        let drained = DispatchSemaphore(value: 0)
        let output = OutputBox()
        if !interactive {
            let reader = pipe.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                output.set(reader.readDataToEndOfFile())
                drained.signal()
            }
        } else {
            drained.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
            return (-1, "timed out after \(Int(timeout)) s")
        }
        _ = drained.wait(timeout: .now() + 5)
        return (process.terminationStatus, String(decoding: output.get(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    /// `reconnect <machine>`: hc 0.1.16 has no other redial than `machine login`.
    static func reconnectPlan(machine: String) -> [String] { ["machine", "login", machine] }
}

// MARK: - consent

enum HCCoreConsent: Equatable {
    case proceed
    case needsYes
    case declined
}

extension HCCoreUtility {
    /// Whether an action may go ahead. Watch-only `open` needs no consent; a
    /// take-over, restart, reconnect or link does. `--yes` gives it; without
    /// it, `--json` or no TTY refuses (`needs_yes`) and nothing is asked; on a
    /// TTY only an explicit yes proceeds. `answer` is nil when nothing was asked.
    static func consent(required: Bool, yes: Bool, json: Bool, tty: Bool, answer: Bool?) -> HCCoreConsent {
        guard required, !yes else { return .proceed }
        guard !json, tty else { return .needsYes }
        return answer == true ? .proceed : .declined
    }

    /// Whether the CLI should ask at all: only when consent is required, not
    /// given by `--yes`, and there is a terminal and no `--json`.
    static func shouldAsk(required: Bool, yes: Bool, json: Bool, tty: Bool) -> Bool {
        required && !yes && !json && tty
    }
}

// MARK: - watch frame

extension HCCoreUtility {
    static func renderWatch(_ s: HCCoreSnapshot, selected: Int, style: HCCoreStyle, home: String, insideC11h: Bool) -> String {
        let now = s.generatedAt
        let live = s.live
        var out: [String] = []
        let linked = s.machines.filter { $0.name != "local" }.map { "\(printable($0.name)) " + ($0.state == "connected" ? style.green($0.state) : style.yellow(printable($0.state))) }
        out.append("\(style.bold("c11 core")) · \(s.session) · \(s.machineName)  \(style.green("✓ pin"))  core \(s.corePID) up \(duration(s.coreStartedAt, now: now))"
            + (s.holderPID.map { "  holder \($0)" } ?? "") + "  \(style.green("\(live.count) live"))" + (linked.isEmpty ? "" : "  " + linked.joined(separator: " · ")))
        out.append("")
        out.append("  " + style.dim([pad("ADDR", 10), pad("AGENT", 16), pad("FOREGROUND", 12), pad("LAUNCHED", 16),
                                     pad("LAST ACTIVE", 14), pad("CPU", 5), pad("MEM", 6), pad("SCREEN COPY", 12), "C11 PANEL"].joined()))
        for (index, t) in live.enumerated() {
            let row = pad(t.address, 10) + pad(agentText(t), 16) + pad(t.foreground?.name ?? "—", 12)
                + pad(t.launchedAt.map { "\(clock($0)) (\(duration($0, now: now)))" } ?? "—", 16)
                + pad(t.lastActive.map { ago($0.at, now: now) } ?? "—", 14) + pad(t.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—", 5)
                + pad(memory(t.memoryBytes), 6) + pad(t.screenCopy ?? "—", 12) + panelText(t, style: style)
            out.append((index == selected ? "▸ " : "  ") + row)
        }
        if s.refused > 0 { out.append("  " + style.yellow(refusedLine(s.refused))) }
        if live.indices.contains(selected) {
            let t = live[selected]
            out.append("")
            out.append("  \(style.bold(t.address))  \(agentText(t)) · \(t.cwd.map { printable($0.replacingOccurrences(of: home, with: "~")) } ?? "—")"
                + ((t.cols != nil && t.rows != nil) ? " · \(t.cols!)×\(t.rows!)" : "")
                + (t.panelID != nil ? " · c11 panel " + panelText(t, style: style) : ""))
        }
        out.append("")
        let jump = insideC11h ? "⌘-click c11 panel: jump   " : ""
        out.append(style.dim("↑↓ select   \(jump)o open in Terminal (watch only)   O take over in Terminal   r restart core   q quit"))
        return out.joined(separator: "\n")
    }
}
