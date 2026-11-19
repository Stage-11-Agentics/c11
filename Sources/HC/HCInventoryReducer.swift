import Foundation

/// hc's `machine.list`, judged one entry at a time. Shared by the reducer
/// (routes) and the session (audit, creations, Settings), so both refuse the
/// same machines for the same reasons.
enum HCMachineRoutes {
    typealias Route = (id: String, availability: HCMachineAvailability)

    struct Judgement {
        var routes: [String: Route] = [:]
        var refused: [String: HCMachineRefusal] = [:]
        /// Entries with no usable name: nothing can address them.
        var unnamed = 0
    }

    /// `reserved` is every core id this app's own cores hold (this one's and
    /// each shard's). Nil when `machines` is not a list.
    static func judge(_ value: HCJSONValue, reserved: Set<String>) -> Judgement? {
        guard let list = value["machines"].array else { return nil }
        var result = Judgement()
        // Counted over the whole list first, so no verdict depends on the order
        // hc lists its machines in (REPAIR-1, B3).
        var names: [String: Int] = [:], ids: [String: Int] = [:]
        for item in list {
            if let name = item["name"].string, !name.isEmpty { names[name, default: 0] += 1 }
            if let id = item["id"].string, !id.isEmpty { ids[id, default: 0] += 1 }
        }
        for item in list {
            guard let name = item["name"].string, !name.isEmpty else { result.unnamed += 1; continue }
            let id = item["id"].string ?? "", state = item["state"].string ?? ""
            let refusal: HCMachineRefusal?
            if names[name, default: 0] > 1 {
                refusal = .duplicate   // neither copy can be told from the other
            } else if id.isEmpty || state.isEmpty {
                refusal = .missingID
            } else if reserved.contains(id) {
                refusal = .localCoreID
            } else if ids[id, default: 0] > 1 {
                refusal = .duplicate   // two machines under one core id would share terminal keys
            } else {
                refusal = nil
            }
            if let refusal { result.refused[name] = refusal }
            else { result.routes[name] = (id, state == "connected" ? .connected : .disconnected) }
        }
        return result
    }
}

/// C11H-359 (L2): the core ids this app's own cores hold, one per shard:
/// read from each shard's `core.json` when the backend starts, and added as
/// each shard's core is verified. Read from any queue.
final class HCLocalCoreIDs: @unchecked Sendable {
    static let shared = HCLocalCoreIDs()

    private let lock = NSLock()
    private var ids: Set<String> = []

    func insert(_ id: String) {
        guard !id.isEmpty else { return }
        lock.lock(); ids.insert(id); lock.unlock()
    }

    func snapshot() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return ids
    }

    /// The id in a shard's `core.json`, when it has one.
    static func read(stateDirectory: URL) -> String? {
        struct Identity: Decodable { let id: String }
        guard let data = try? PrivateFileWriter.readPrivateFile(at: stateDirectory.appendingPathComponent("core.json"),
                                                                 maxBytes: 65536),
              let id = try? JSONDecoder().decode(Identity.self, from: data).id, !id.isEmpty else { return nil }
        return id
    }
}

/// Pure protocol reducer. Only a consistent snapshot plus ordered deltas can
/// confer readiness; retained records while pending confer no absence evidence.
struct HCInventoryReducer {
    let generation: UInt64
    let coreID: String
    var buildIdentity: HCBuildIdentity?
    private(set) var sequence: UInt64 = 0
    private(set) var readiness: HCReadiness = .pending(.inventoryPending)
    private var raw: [String: HCJSONValue] = [:]
    private var routes: [String: (id: String, availability: HCMachineAvailability)] = [:]
    /// C11H-359: machines the last list refused, and why.
    private(set) var refusedMachines: [String: HCMachineRefusal] = [:]
    /// C11H-359: addresses the last snapshot listed more than once. The first
    /// listing (hc lists this core's own record first) is kept.
    private(set) var droppedDuplicateAddresses = 0

    /// The duplicates the last install dropped, once: a later install, or a
    /// stale `missed` frame the reducer ignores, never reports them again.
    mutating func takeDroppedDuplicateAddresses() -> Int {
        defer { droppedDuplicateAddresses = 0 }
        return droppedDuplicateAddresses
    }
    private(set) var needsRefresh = false
    private var unknownKinds: Set<String> = []
    /// Every core id this app's own cores hold. A linked machine's route may
    /// never claim one (C11H-359, L2); this core's id is always included.
    private let reservedCoreIDs: @Sendable () -> Set<String>

    init(generation: UInt64, coreID: String, buildIdentity: HCBuildIdentity? = nil,
         reservedCoreIDs: @escaping @Sendable () -> Set<String> = { [] }) {
        self.generation = generation; self.coreID = coreID; self.buildIdentity = buildIdentity
        self.reservedCoreIDs = reservedCoreIDs
    }

    var snapshot: HCInventorySnapshot {
        var records: [HCTerminalKey: HCTerminalRecord] = [:]
        for value in raw.values {
            if let record = try? decodeRecord(value) { records[record.key] = record }
        }
        return HCInventorySnapshot(readiness: readiness, revision: revision, records: records,
                                   buildIdentity: buildIdentity, machines: routes.mapValues(\.availability))
    }
    var revision: HCRevision { HCRevision(connectionGeneration: generation, sequence: sequence) }

    mutating func invalidate(_ reason: HCUnavailableReason) {
        readiness = .pending(reason); needsRefresh = true
    }

    /// C11H-359 (M6, L2): one bad entry refuses that machine, never the list.
    /// Its terminals are skipped, so the shard and every other machine stay usable.
    mutating func setMachines(_ value: HCJSONValue) throws {
        guard let judged = HCMachineRoutes.judge(value, reserved: reservedCoreIDs().union([coreID])) else {
            throw HCUnavailableReason.malformedResponse
        }
        let next = judged.routes
        refusedMachines = judged.refused
        // A different route cannot inherit time verified against the prior core.
        for (address, value) in raw {
            guard let machine = address.split(separator: "/").dropLast().first.map(String.init),
                  routes[machine]?.id != next[machine]?.id || routes[machine]?.availability != next[machine]?.availability,
                  var object = value.object else { continue }
            object["status_ms"] = .null
            raw[address] = .object(object)
        }
        routes = next
    }

    mutating func install(_ value: HCJSONValue) throws {
        guard let seq = value["seq"].uint, let terminals = value["terminals"].array else {
            invalidate(.malformedResponse); throw HCUnavailableReason.malformedResponse
        }
        var next: [String: HCJSONValue] = [:]
        var duplicates = 0
        do {
            for terminal in terminals {
                guard let address = terminal["address"].string else { throw HCUnavailableReason.malformedResponse }
                if isOnRefusedMachine(address) { continue }
                // C11H-359 (M7): a doubled address keeps its first listing,
                // which is this core's own; it never refuses the shard.
                if next[address] != nil { duplicates += 1; continue }
                _ = try decodeRecord(terminal)
                next[address] = try withoutMirrorTimestamp(terminal)
            }
        } catch { invalidate(.malformedResponse); throw error }
        raw = next; sequence = seq; needsRefresh = false
        droppedDuplicateAddresses = duplicates
        readiness = .ready(revision)
    }

    mutating func apply(_ message: HCJSONValue, generation incomingGeneration: UInt64) throws {
        guard incomingGeneration == generation else { return }
        do { try reduce(message) }
        catch { invalidate(.malformedResponse); throw error }
    }

    private mutating func reduce(_ message: HCJSONValue) throws {
        guard message["jsonrpc"].string == "2.0", let method = message["method"].string,
              let seq = message["params"]["seq"].uint else { throw HCUnavailableReason.malformedResponse }
        let params = message["params"]
        if method == "missed" {
            guard seq >= sequence else { return }
            try install(params); return
        }
        if method == "heartbeat" {
            if seq > sequence { invalidate(.inventoryPending) }
            return
        }
        guard method == "event" else { throw HCUnavailableReason.malformedResponse }
        guard seq > sequence else { return }
        guard case .ready = readiness else { return }
        guard sequence < UInt64.max, seq == sequence + 1 else { invalidate(.inventoryPending); return }
        guard let kind = params["type"].string else { throw HCUnavailableReason.malformedResponse }
        let known = ["created", "restarted", "removed", "finished", "lost", "status", "turn", "title", "labels", "keep", "size", "foreground"]
        if !known.contains(kind) {
            sequence = seq; readiness = .ready(revision)
            if kind != "doc", unknownKinds.insert(kind).inserted { needsRefresh = true }
            return
        }
        guard let address = params["terminal"].string else { throw HCUnavailableReason.malformedResponse }
        // A refused machine's terminals stay out of the key space (C11H-359).
        if isOnRefusedMachine(address) { sequence = seq; readiness = .ready(revision); return }
        let data = params["data"]
        if kind == "removed" {
            // Remote mirror disappearance is inventory absence, not end evidence.
            // Lifecycle consumers must retain remote identities across link loss.
            guard raw.removeValue(forKey: address) != nil else { throw HCUnavailableReason.malformedResponse }
        } else if kind == "created" || kind == "restarted" {
            guard data["address"].string == address else { throw HCUnavailableReason.malformedResponse }
            // C11H-359 (M7): hc keeps a terminal's created_ms for its whole
            // life, restarts included. An event that would replace a record
            // with another terminal's is refused; the resnapshot it triggers
            // keeps this core's own record.
            if let held = raw[address]?["created_ms"], held != .null, data["created_ms"] != held {
                throw HCUnavailableReason.malformedResponse
            }
            raw[address] = try withoutMirrorTimestamp(data)
        } else {
            if let full = data["record"].object {
                let record = HCJSONValue.object(full)
                guard record["address"].string == address else { throw HCUnavailableReason.malformedResponse }
                raw[address] = try withoutMirrorTimestamp(record)
            } else {
                guard var record = raw[address]?.object else { throw HCUnavailableReason.malformedResponse }
                let keys: [String]
                switch kind {
                case "finished", "lost":
                    guard data["reason"].string != nil else { throw HCUnavailableReason.malformedResponse }
                    record["state"] = .string(kind == "lost" ? "live" : "finished")
                    if kind == "lost" { record["pid"] = .null }
                    record["foreground"] = .null
                    keys = ["reason", "exit_code", "signal", "finished_ms"]
                case "status":
                    if record["status"]?["state"] != data["status"]["state"] { record["status_ms"] = .null }
                    keys = ["status", "records", "reported"]
                case "turn": keys = ["turn"]
                case "title": keys = ["title"]
                case "labels": keys = ["labels"]
                case "keep": keys = ["keep"]
                case "size": keys = ["cols", "rows"]
                case "foreground": keys = []; record["foreground"] = data
                default: throw HCUnavailableReason.malformedResponse
                }
                for key in keys {
                    guard let value = data.object?[key] else { throw HCUnavailableReason.malformedResponse }
                    record[key] = value
                }
                let value = HCJSONValue.object(record)
                _ = try decodeRecord(value); raw[address] = value
            }
        }
        sequence = seq; readiness = .ready(revision)
    }

    /// The address names a machine this list refused, or an empty one.
    private func isOnRefusedMachine(_ address: String) -> Bool {
        let pieces = address.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return false }
        return pieces[0].isEmpty || refusedMachines[String(pieces[0])] != nil
    }

    /// Root timestamps in a remote mirror can lag the word: pin 0.1.16's
    /// status event omits status_ms. Only an owning-core get may restore it.
    private func withoutMirrorTimestamp(_ value: HCJSONValue) throws -> HCJSONValue {
        let record = try decodeRecord(value)
        guard record.machineName != nil, var object = value.object else { return value }
        object["status_ms"] = .null
        return .object(object)
    }

    struct StatusTarget: Equatable, Sendable {
        let key: HCTerminalKey
        let address: String
        let machine: String
        let status: String
        let turn: Int64
    }

    func statusTarget(for key: HCTerminalKey, status: String, turn: Int64) -> StatusTarget? {
        guard case .ready = readiness else { return nil }
        for (address, value) in raw {
            guard let record = try? decodeRecord(value), record.key == key,
                  let machine = record.machineName, record.machineAvailability == .connected,
                  record.status == status, record.turn == turn else { continue }
            return StatusTarget(key: key, address: address, machine: machine, status: status, turn: turn)
        }
        return nil
    }

    /// Installs only time; this is enrichment of the current sequence, not a
    /// synthetic event or a reason to make a pending inventory ready.
    mutating func installStatusTimestamp(_ reply: HCJSONValue, matching target: StatusTarget) -> HCTerminalRecord? {
        guard statusTarget(for: target.key, status: target.status, turn: target.turn) == target,
              let returnedAddress = reply["address"].string,
              [target.address, "\(target.key.owningCoreID)/\(target.key.localAddress)"].contains(returnedAddress),
              routes[target.machine]?.id == target.key.owningCoreID,
              reply["status"]["state"].string == target.status,
              reply["turn"].integer == target.turn,
              let timestamp = reply["status_ms"].integer, timestamp >= 0,
              var record = raw[target.address]?.object else { return nil }
        record["status_ms"] = .integer(timestamp)
        raw[target.address] = .object(record)
        return try? decodeRecord(.object(record))
    }

    private func decodeRecord(_ value: HCJSONValue) throws -> HCTerminalRecord {
        guard let address = value["address"].string, let state = value["state"].string,
              ["live", "finished"].contains(state), let labels = value["labels"].object else {
            throw HCUnavailableReason.malformedResponse
        }
        let pieces = address.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count), let local = pieces.last, local.first == "t", local.count > 1 else {
            throw HCUnavailableReason.malformedResponse
        }
        let machine = pieces.count == 2 ? String(pieces[0]) : nil
        let owner: String
        let availability: HCMachineAvailability
        if let machine {
            guard let route = routes[machine] else { throw HCUnavailableReason.inventoryPending }
            owner = route.id; availability = route.availability
        } else { owner = coreID; availability = .local }
        var decodedLabels: [String: String] = [:]
        for (key, value) in labels {
            guard let text = value.string else { throw HCUnavailableReason.malformedResponse }
            decodedLabels[key] = text
        }
        func optionalInt(_ value: HCJSONValue) throws -> Int32? {
            if value == .null { return nil }
            guard let n = value.integer, let exact = Int32(exactly: n) else { throw HCUnavailableReason.malformedResponse }
            return exact
        }
        func optionalString(_ value: HCJSONValue) throws -> String? {
            if value == .null { return nil }
            guard let s = value.string else { throw HCUnavailableReason.malformedResponse }; return s
        }
        let pid = try optionalInt(value["pid"])
        let fg: HCForeground?
        if value["foreground"] == .null { fg = nil }
        else {
            guard value["foreground"].object != nil else { throw HCUnavailableReason.malformedResponse }
            let f = value["foreground"]
            fg = HCForeground(pid: try optionalInt(f["pid"]), name: try optionalString(f["name"]),
                              argv: f["argv"].array?.compactMap(\.string), cwd: try optionalString(f["cwd"]))
        }
        guard let cols = value["cols"].integer.flatMap(UInt16.init(exactly:)),
              let rows = value["rows"].integer.flatMap(UInt16.init(exactly:)) else { throw HCUnavailableReason.malformedResponse }
        let status = value["status"] == .null ? nil : try optionalString(value["status"]["state"])
        return HCTerminalRecord(key: HCTerminalKey(owningCoreID: owner, localAddress: String(local)),
            state: state == "finished" ? .finished : (pid == nil ? .starting : .running), labels: decodedLabels,
            machineName: machine, machineAvailability: availability, pid: pid, cwd: try optionalString(value["cwd"]),
            foreground: fg, title: try optionalString(value["title"]), status: status,
            statusTimestampMilliseconds: value["status_ms"].integer, turn: value["turn"].integer,
            grid: HCGridSize(columns: cols, rows: rows), screenExact: value["screen"].string.map { $0 == "exact" },
            exitCode: try optionalInt(value["exit_code"]), exitSignal: try optionalInt(value["signal"]),
            endReason: try optionalString(value["reason"]),
            finishedMilliseconds: value["finished_ms"].integer.flatMap { $0 > 0 ? $0 : nil })
    }
}
