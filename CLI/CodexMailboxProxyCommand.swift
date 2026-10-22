import Darwin
import Foundation

/// Opt-in Codex mailbox route. The wrapper starts this as a child of the
/// interactive Codex process and launches the TUI with `--remote` pointed at
/// `listen`. Every byte between the TUI and the shared app-server daemon is
/// relayed unchanged; the frames are read only to learn which thread the TUI
/// displays. A doorbell is queued into that thread alone, while the TUI's own
/// thread switches wait, and counts as delivered only when the TUI's connection
/// receives the turn it started. Anything else is left to the typed doorbell.
enum CodexMailboxProxyCommand {
    struct Options {
        let listen: String
        let upstream: String?
        let codex: String?
        let log: String?
        let panelID: String
        let agentPID: pid_t
        let agentBirth: UInt64

        init?(arguments: [String], environment: [String: String]) {
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                guard ["--listen", "--upstream", "--codex", "--log"].contains(flag), index + 1 < arguments.count,
                      values[flag] == nil else { return nil }
                values[flag] = arguments[index + 1]
                index += 2
            }
            guard let listen = values["--listen"], listen.hasPrefix("/"),
                  values["--upstream"] != nil || values["--codex"] != nil,
                  let panel = environment["C11_PANEL_ID"] ?? environment["CMUX_SURFACE_ID"],
                  UUID(uuidString: panel) != nil,
                  let rawPID = environment["C11_AGENT_INTERACTIVE_PID"], let pid = pid_t(rawPID), pid > 1,
                  let birth = CodexProxyProcess.info(pid)?.birth else { return nil }
            self.listen = listen
            self.upstream = values["--upstream"]
            self.codex = values["--codex"]
            self.log = values["--log"]
            self.panelID = panel
            self.agentPID = pid
            self.agentBirth = birth
        }

        var agentAlive: Bool { CodexProxyProcess.info(agentPID)?.birth == agentBirth }
    }

    static let invitation = "You have mail: run c11 mailbox recv --ack when you want to receive it."

    /// Returns the process exit status. Nonzero means no socket was published,
    /// so the wrapper launches Codex unchanged.
    static func run(_ options: Options, connectApp: @escaping () throws -> Int32) -> Int32 {
        let log = CodexProxyLog(path: options.log)
        guard CodexProxySocket.privateDirectory(URL(fileURLWithPath: options.listen).deletingLastPathComponent().path) else {
            log.write(["event": "exit", "reason": "unsafe_directory"]); return 2
        }
        guard let upstream = options.upstream ?? CodexDaemon.socketPath(codex: options.codex!, log: log),
              let probe = CodexProxySocket.connect(upstream) else {
            log.write(["event": "exit", "reason": "upstream_unavailable"]); return 3
        }
        Darwin.close(probe)
        CodexProxySocket.removeStale(in: URL(fileURLWithPath: options.listen).deletingLastPathComponent().path)
        guard let listener = CodexProxySocket.listen(options.listen) else {
            log.write(["event": "exit", "reason": "listen_failed"]); return 4
        }
        log.write(["event": "ready", "upstream": upstream])
        let proxy = CodexMailboxProxy(options: options, upstream: upstream, log: log)
        proxy.subscribe(connectApp)
        let reason = proxy.serve(listener: listener)
        Darwin.close(listener)
        unlink(options.listen)
        log.write(["event": "exit", "reason": reason])
        return 0
    }
}

// MARK: - Displayed-thread tracking

/// Thread state as the TUI's own connection reports it. Only requests the TUI
/// sent and notifications delivered to the TUI count, so a thread the panel
/// does not show can never be chosen.
final class CodexThreadTracker {
    static let switchMethods: Set<String> = ["thread/start", "thread/resume", "thread/fork", "thread/unsubscribe"]
    private static let subscribeMethods: Set<String> = ["thread/start", "thread/resume", "thread/fork"]

    struct Snapshot {
        let connected: Bool
        let displayed: String?
        let idle: Bool
        let warm: Bool
        let switchesInFlight: Int
    }

    let condition = NSCondition()
    private var tui: Int?
    private var pending: [String: (method: String, ephemeral: Bool)] = [:]
    private var subscribed: [String] = []
    private var status: [String: String] = [:]
    private var warm: Set<String> = []
    private var started: [(thread: String, turn: String, at: TimeInterval)] = []
    private var switches = 0

    static func key(_ id: Any?) -> String? {
        if let id = id as? String { return "s" + id }
        if let id = id as? NSNumber { return "n" + id.stringValue }
        return nil
    }

    /// A frame the client sent. Called before the frame is forwarded.
    func client(_ connection: Int, _ message: [String: Any]) {
        condition.lock(); defer { condition.unlock() }
        let method = message["method"] as? String
        let params = message["params"] as? [String: Any] ?? [:]
        if method == "initialize", (params["clientInfo"] as? [String: Any])?["name"] as? String == "codex-tui" {
            tui = connection
            pending = [:]; subscribed = []; status = [:]; warm = []; started = []; switches = 0
        }
        guard connection == tui, let method, let id = Self.key(message["id"]) else { return }
        pending[id] = (method, params["ephemeral"] as? Bool == true)
        if Self.switchMethods.contains(method) { switches += 1 }
        if method == "thread/unsubscribe", let thread = params["threadId"] as? String {
            subscribed.removeAll { $0 == thread }
        }
    }

    /// A frame the server sent to a client connection.
    func server(_ connection: Int, _ message: [String: Any]) {
        condition.lock(); defer { condition.unlock(); condition.broadcast() }
        guard connection == tui else { return }
        if message["method"] == nil, let id = Self.key(message["id"]), let request = pending.removeValue(forKey: id) {
            if Self.switchMethods.contains(request.method) { switches = max(0, switches - 1) }
            guard Self.subscribeMethods.contains(request.method), !request.ephemeral,
                  let thread = (message["result"] as? [String: Any])?["thread"] as? [String: Any],
                  let threadID = thread["id"] as? String else { return }
            subscribed.removeAll { $0 == threadID }
            subscribed.append(threadID)
            if let type = (thread["status"] as? [String: Any])?["type"] as? String { status[threadID] = type }
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        guard let thread = params["threadId"] as? String else { return }
        switch message["method"] as? String {
        case "thread/status/changed":
            if let type = (params["status"] as? [String: Any])?["type"] as? String { status[thread] = type }
        case "turn/started":
            let turn = (params["turn"] as? [String: Any])?["id"] as? String ?? ""
            started.append((thread, turn, ProcessInfo.processInfo.systemUptime))
            if started.count > 64 { started.removeFirst(started.count - 64) }
        case "turn/completed":
            warm.insert(thread)
        case "thread/closed":
            subscribed.removeAll { $0 == thread }
        default:
            break
        }
    }

    func closed(_ connection: Int) {
        condition.lock(); defer { condition.unlock(); condition.broadcast() }
        guard connection == tui else { return }
        tui = nil; pending = [:]; subscribed = []; switches = 0
    }

    func snapshot() -> Snapshot {
        condition.lock(); defer { condition.unlock() }
        let displayed = subscribed.last
        return Snapshot(connected: tui != nil, displayed: displayed,
                        idle: displayed.map { status[$0] == "idle" } ?? false,
                        warm: displayed.map { warm.contains($0) } ?? false,
                        switchesInFlight: switches)
    }

    /// Waits for a turn on `thread` that reached the TUI at or after `since`.
    func waitForTurn(thread: String, since: TimeInterval, until deadline: TimeInterval) -> Bool {
        condition.lock(); defer { condition.unlock() }
        while true {
            if started.contains(where: { $0.thread == thread && $0.at >= since }) { return true }
            if tui == nil { return false }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return false }
            _ = condition.wait(until: Date().addingTimeInterval(remaining))
        }
    }
}

// MARK: - Proxy

private final class CodexMailboxProxy {
    private let options: CodexMailboxProxyCommand.Options
    private let upstream: String
    private let log: CodexProxyLog
    private let tracker = CodexThreadTracker()
    /// Held for a ring's whole life. Thread switches from the TUI wait on it.
    private let hold = NSLock()
    private let rings = DispatchQueue(label: "com.stage11.c11.codex-proxy.ring")
    private let state = NSLock()
    private var active = 0
    private var served = false
    private var connectionCount = 0

    init(options: CodexMailboxProxyCommand.Options, upstream: String, log: CodexProxyLog) {
        self.options = options
        self.upstream = upstream
        self.log = log
    }

    func serve(listener: Int32) -> String {
        // No first-connection deadline: Codex can wait on its own startup
        // dialogs before it connects. The wrapper stops a proxy it gave up on.
        while true {
            let finished: String? = autoreleasepool {
                guard options.agentAlive else { return "agent_exited" }
                state.lock(); let live = active; let wasServed = served; state.unlock()
                if wasServed && live == 0 { return "tui_closed" }
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 500) > 0 else { return nil }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return nil }
                CodexProxySocket.noSignal(client)
                guard let peer = CodexProxySocket.peerPID(client),
                      CodexProxyProcess.descends(peer, from: options.agentPID, birth: options.agentBirth),
                      let server = CodexProxySocket.connect(upstream) else {
                    log.write(["event": "connection_refused"])
                    Darwin.close(client); return nil
                }
                state.lock(); active += 1; served = true; connectionCount += 1; let number = connectionCount; state.unlock()
                relay(client: client, server: server, number: number)
                return nil
            }
            if let finished { return finished }
        }
    }

    private func relay(client: Int32, server: Int32, number: Int) {
        let group = DispatchGroup()
        group.enter()
        Thread.detachNewThread { [self] in
            pumpClient(from: client, to: server, number: number)
            group.leave()
        }
        group.enter()
        Thread.detachNewThread { [self] in
            pumpServer(from: server, to: client, number: number)
            group.leave()
        }
        group.notify(queue: .global(qos: .utility)) { [self] in
            Darwin.close(client); Darwin.close(server)
            tracker.closed(number)
            log.write(["event": "connection_closed", "connection": number])
            state.lock(); active -= 1; state.unlock()
        }
    }

    /// TUI -> server. Frames are forwarded whole and in order; only a thread
    /// switch can wait, and only while a ring holds `hold`.
    private func pumpClient(from client: Int32, to server: Int32, number: Int) {
        var parser = CodexWebSocketParser(masked: true)
        var buffer = [UInt8](repeating: 0, count: 65536)
        defer { shutdown(server, SHUT_WR) }
        while true {
            let ok: Bool = autoreleasepool {
                let count = read(client, &buffer, buffer.count)
                if count < 0 && errno == EINTR { return true }
                guard count > 0 else { return false }
                for chunk in parser.feed(buffer[..<count]) {
                    let message = chunk.message.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let isSwitch = message.map { $0["id"] != nil && CodexThreadTracker.switchMethods.contains($0["method"] as? String ?? "") } ?? false
                    if isSwitch { hold.lock() }
                    if let message { tracker.client(number, message) }
                    let sent = CodexProxySocket.writeAll(server, chunk.raw)
                    if isSwitch { hold.unlock() }
                    if !sent { return false }
                }
                return true
            }
            if !ok { return }
        }
    }

    /// Server -> TUI. Bytes are forwarded as soon as they arrive and parsed after.
    private func pumpServer(from server: Int32, to client: Int32, number: Int) {
        var parser = CodexWebSocketParser(masked: false)
        var buffer = [UInt8](repeating: 0, count: 65536)
        defer { shutdown(client, SHUT_WR) }
        while true {
            let ok: Bool = autoreleasepool {
                let count = read(server, &buffer, buffer.count)
                if count < 0 && errno == EINTR { return true }
                guard count > 0 else { return false }
                guard CodexProxySocket.writeAll(client, buffer[..<count]) else { return false }
                for chunk in parser.feed(buffer[..<count]) {
                    if let data = chunk.message, let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        tracker.server(number, message)
                    }
                }
                return true
            }
            if !ok { return }
        }
    }

    // MARK: Mailbox subscription

    func subscribe(_ connectApp: @escaping () throws -> Int32) {
        Thread.detachNewThread { [self] in
            var delay: TimeInterval = 1
            while options.agentAlive {
                let retire: Bool = autoreleasepool {
                    guard let descriptor = try? connectApp(), let stream = try? CodexAppStream(descriptor: descriptor) else { return false }
                    return listen(stream)
                }
                if retire { return }
                // The relay keeps serving the TUI; only native delivery waits.
                Thread.sleep(forTimeInterval: delay)
                delay = min(delay * 2, 30)
            }
        }
    }

    /// Returns true when the subscription must not be retried.
    private func listen(_ stream: CodexAppStream) -> Bool {
        let requestID = UUID().uuidString
        do {
            try stream.write(["id": requestID, "method": "mailbox.native.subscribe",
                              "params": ["panel_id": options.panelID, "agent_pid": Int(options.agentPID),
                                         "route": "codex_queue", "session_id": UUID().uuidString, "can_queue": false]])
            guard let reply = try stream.read(deadline: uptime + 2), reply["id"] as? String == requestID else { return false }
            guard reply["ok"] as? Bool == true else {
                log.write(["event": "subscribe_refused"]); return true
            }
            log.write(["event": "subscribed"])
            while options.agentAlive {
                let next: Bool? = try autoreleasepool {
                    guard let frame = try stream.read(deadline: uptime + 1) else { return nil }
                    if frame["type"] as? String == "replaced" { return true }
                    guard frame["type"] as? String == "deliver", let delivery = frame["delivery_id"] as? String else { return nil }
                    let text = frame["text"] as? String
                    rings.async { [self] in
                        let result = text == CodexMailboxProxyCommand.invitation ? ring() : .rejected("unsupported_invitation")
                        switch result {
                        case .accepted: try? stream.write(["type": "accepted", "delivery_id": delivery])
                        case .rejected(let reason): try? stream.write(["type": "rejected", "delivery_id": delivery, "reason": reason])
                        case .ambiguous: break // The app's deadline hands the ids to the typed gate.
                        }
                    }
                    return nil
                }
                if next == true { log.write(["event": "replaced"]); return true }
            }
            return true
        } catch {
            log.write(["event": "subscription_lost"])
            return false
        }
    }

    // MARK: Ring

    enum RingResult: Equatable { case accepted, rejected(String), ambiguous }

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func ring() -> RingResult {
        hold.lock(); defer { hold.unlock() }
        let start = uptime
        let snapshot = tracker.snapshot()
        func finish(_ result: RingResult, _ reason: String, _ extra: [String: Any] = [:]) -> RingResult {
            var record: [String: Any] = ["event": "ring", "outcome": reason, "ms": Int((uptime - start) * 1000)]
            record.merge(extra) { $1 }
            log.write(record)
            return result
        }
        guard snapshot.connected, let thread = snapshot.displayed else { return finish(.rejected("no_tui_thread"), "no_tui_thread") }
        guard snapshot.switchesInFlight == 0 else { return finish(.rejected("thread_switch_in_flight"), "thread_switch_in_flight") }
        guard snapshot.idle else { return finish(.rejected("thread_not_idle"), "thread_not_idle") }
        // A thread's first turn can reach the TUI many seconds after it starts.
        guard snapshot.warm else { return finish(.rejected("thread_not_warm"), "thread_not_warm") }
        guard let rpc = CodexRPCClient(path: upstream, deadline: start + 0.5) else {
            return finish(.rejected("upstream_unavailable"), "upstream_unavailable")
        }
        defer { rpc.close() }
        let clientID = UUID().uuidString
        let input: [[String: Any]] = [["type": "text", "text": CodexMailboxProxyCommand.invitation, "text_elements": []]]
        guard let added = rpc.call("thread/queue/add", ["threadId": thread, "clientUserMessageId": clientID, "input": input],
                                   deadline: start + 0.8),
              let submission = (added["queuedSubmission"] as? [String: Any])?["id"] as? String else {
            return finish(.rejected("queue_error"), "queue_error")
        }
        let seen = tracker.waitForTurn(thread: thread, since: start, until: start + 1.5)
        let queued = rpc.call("thread/queue/list", ["threadId": thread], deadline: uptime + 0.3)
        let stillQueued = queued.map { (($0["data"] as? [[String: Any]]) ?? []).contains { $0["id"] as? String == submission } }
        if seen, stillQueued == false {
            return finish(.accepted, "accepted", ["thread": thread])
        }
        if stillQueued != false {
            let removed = rpc.call("thread/queue/delete", ["threadId": thread, "queuedSubmissionId": submission], deadline: uptime + 0.3)
            if removed?["deleted"] as? Bool == true {
                return finish(.rejected(seen ? "busy_race" : "unconfirmed_withdrawn"), seen ? "busy_race" : "unconfirmed_withdrawn")
            }
        }
        // Consumed but not seen by the TUI: stop it before a thread switch can
        // leave it running unwatched. Switches stay held until this returns.
        let turns = rpc.call("thread/turns/list", ["threadId": thread, "limit": 1, "cursor": NSNull(),
                                                   "sortDirection": NSNull(), "itemsView": NSNull()], deadline: uptime + 0.5)
        let turn = ((turns?["data"] as? [[String: Any]]) ?? []).first { turn in
            ((turn["items"] as? [[String: Any]]) ?? []).contains { $0["clientId"] as? String == clientID }
        }
        var interrupted = false
        if let turnID = turn?["id"] as? String {
            interrupted = rpc.call("turn/interrupt", ["threadId": thread, "turnId": turnID], deadline: uptime + 0.5) != nil
        }
        return finish(.ambiguous, "unconfirmed_interrupted", ["interrupted": interrupted])
    }
}

// MARK: - Daemon resolution

private enum CodexDaemon {
    /// The socket the TUI would use itself. The relay never starts a daemon:
    /// Codex's own launch path decides that (`features.daemon_auto_start`), and
    /// a CLI and daemon of different versions keep that path, which can warn.
    static func socketPath(codex: String, log: CodexProxyLog) -> String? {
        let status = version(codex)
        guard let status, status["status"] as? String == "running",
              let path = status["socketPath"] as? String, path.hasPrefix("/") else { return nil }
        guard let cli = status["cliVersion"] as? String, cli == status["appServerVersion"] as? String else {
            log.write(["event": "version_mismatch"]); return nil
        }
        return path
    }

    private static func version(_ codex: String) -> [String: Any]? {
        guard let data = run(codex, ["app-server", "daemon", "version"], timeout: 3) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func run(_ codex: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codex)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["C11_CODEX_WRAPPER_REENTRY"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        var data = Data()
        let reader = DispatchQueue.global(qos: .utility)
        let readDone = DispatchSemaphore(value: 0)
        reader.async { data = output.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        return process.terminationStatus == 0 ? data : nil
    }
}

// MARK: - WebSocket framing

/// Splits a byte stream into the HTTP upgrade and whole WebSocket frames.
/// `raw` is exactly the bytes received; `message` is a completed text message.
struct CodexWebSocketParser {
    struct Chunk { let raw: [UInt8]; let message: Data? }
    let masked: Bool
    private var buffer: [UInt8] = []
    private var upgraded = false
    private var fragments: [UInt8] = []
    private var collecting = false

    init(masked: Bool) { self.masked = masked }

    mutating func feed<S: Sequence>(_ bytes: S) -> [Chunk] where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
        var chunks: [Chunk] = []
        if !upgraded {
            guard let end = Self.headerEnd(buffer) else {
                if buffer.count > 64 * 1024 { chunks.append(Chunk(raw: buffer, message: nil)); buffer = []; upgraded = true }
                return chunks
            }
            chunks.append(Chunk(raw: Array(buffer[..<end]), message: nil))
            buffer.removeFirst(end)
            upgraded = true
        }
        var offset = 0
        while buffer.count - offset >= 2 {
            let first = buffer[offset], second = buffer[offset + 1]
            var length = Int(second & 0x7F)
            var header = 2
            if length == 126 {
                guard buffer.count - offset >= 4 else { break }
                length = Int(buffer[offset + 2]) << 8 | Int(buffer[offset + 3]); header = 4
            } else if length == 127 {
                guard buffer.count - offset >= 10 else { break }
                length = (0..<8).reduce(0) { $0 << 8 | Int(buffer[offset + 2 + $1]) }; header = 10
            }
            let hasMask = second & 0x80 != 0
            let maskOffset = offset + header
            if hasMask { header += 4 }
            guard length >= 0, buffer.count - offset >= header + length else { break }
            let payloadStart = offset + header
            let opcode = first & 0x0F
            if opcode == 1 || opcode == 2 || (opcode == 0 && collecting) {
                if opcode != 0 { fragments = []; collecting = true }
                if hasMask {
                    let mask = Array(buffer[maskOffset..<maskOffset + 4])
                    fragments.reserveCapacity(fragments.count + length)
                    for index in 0..<length { fragments.append(buffer[payloadStart + index] ^ mask[index & 3]) }
                } else {
                    fragments.append(contentsOf: buffer[payloadStart..<payloadStart + length])
                }
            }
            var message: Data?
            if first & 0x80 != 0, collecting, opcode <= 2 {
                message = Data(fragments); fragments = []; collecting = false
            }
            chunks.append(Chunk(raw: Array(buffer[offset..<payloadStart + length]), message: message))
            offset = payloadStart + length
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return chunks
    }

    private static func headerEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 3..<bytes.count where bytes[index - 3] == 13 && bytes[index - 2] == 10 && bytes[index - 1] == 13 && bytes[index] == 10 {
            return index + 1
        }
        return nil
    }

    static func encodeClientText(_ data: Data) -> [UInt8] {
        var frame: [UInt8] = [0x81]
        let count = data.count
        if count < 126 { frame.append(0x80 | UInt8(count)) }
        else if count < 65536 { frame += [UInt8(0xFE), UInt8(count >> 8), UInt8(count & 0xFF)] }
        else { frame.append(UInt8(0xFF)); frame += (0..<8).reversed().map { UInt8((count >> ($0 * 8)) & 0xFF) } }
        var mask = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&mask, 4)
        frame += mask
        for (index, byte) in data.enumerated() { frame.append(byte ^ mask[index & 3]) }
        return frame
    }
}

/// One short-lived app-server connection for a ring.
private final class CodexRPCClient {
    private var fd: Int32
    private var parser = CodexWebSocketParser(masked: false)
    private var next = 0

    init?(path: String, deadline: TimeInterval) {
        guard let descriptor = CodexProxySocket.connect(path) else { return nil }
        fd = descriptor
        var key = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&key, 16)
        let request = "GET /rpc HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(Data(key).base64EncodedString())\r\n\r\n"
        guard CodexProxySocket.writeAll(fd, Array(request.utf8)) else { close(); return nil }
        // The server sends nothing after the upgrade until `initialize`.
        var reply: [CodexWebSocketParser.Chunk] = []
        while reply.isEmpty {
            guard let chunks = receive(deadline: deadline) else { close(); return nil }
            reply = chunks
        }
        guard String(decoding: reply[0].raw, as: UTF8.self).hasPrefix("HTTP/1.1 101") else { close(); return nil }
        guard call("initialize", ["clientInfo": ["name": "c11-mailbox", "title": NSNull(), "version": "1"],
                                  "capabilities": ["experimentalApi": true]], deadline: deadline) != nil,
              send(["method": "initialized"]) else { close(); return nil }
    }

    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }

    private func send(_ object: [String: Any]) -> Bool {
        guard fd >= 0, let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return CodexProxySocket.writeAll(fd, CodexWebSocketParser.encodeClientText(data))
    }

    private func receive(deadline: TimeInterval) -> [CodexWebSocketParser.Chunk]? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard fd >= 0, remaining > 0, poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up))) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return parser.feed(buffer[..<count])
    }

    /// The result object, or nil for an error, a closed connection or the deadline.
    func call(_ method: String, _ params: [String: Any], deadline: TimeInterval) -> [String: Any]? {
        next += 1
        let id = "c11-\(next)"
        guard send(["id": id, "method": method, "params": params]) else { return nil }
        while let chunks = receive(deadline: deadline) {
            for chunk in chunks {
                guard let data = chunk.message,
                      let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      message["id"] as? String == id else { continue }
                return message["result"] as? [String: Any]
            }
        }
        return nil
    }
}

// MARK: - App stream

/// Newline-JSON stream to the c11 socket, already authenticated by the CLI.
private final class CodexAppStream {
    private let fd: Int32
    private var pending = Data()
    private let writeLock = NSLock()

    init(descriptor: Int32) throws {
        guard descriptor >= 0 else { throw CodexProxySocket.Failure.closed }
        fd = descriptor
        CodexProxySocket.noSignal(fd)
    }

    deinit { Darwin.close(fd) }

    func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        writeLock.lock(); defer { writeLock.unlock() }
        guard CodexProxySocket.writeAll(fd, [UInt8](data)) else { throw CodexProxySocket.Failure.closed }
    }

    func read(deadline: TimeInterval) throws -> [String: Any]? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { return object }
                continue
            }
            guard pending.count <= 64 * 1024 else { throw CodexProxySocket.Failure.closed }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32((remaining * 1000).rounded(.up)))
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw CodexProxySocket.Failure.closed }
            if ready == 0 { return nil }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodexProxySocket.Failure.closed }
            pending.append(contentsOf: buffer[..<count])
        }
    }
}

// MARK: - Sockets and processes

enum CodexProxySocket {
    enum Failure: Error { case closed }

    static func noSignal(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The directory must already exist, belong to this user, be 0700 and not
    /// be a symlink, so no other user can reach or replace the socket.
    static func privateDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700
    }

    /// A relay killed with its terminal cannot unlink its own files. Names
    /// carry the Codex process id; remove those whose process is gone.
    static func removeStale(in directory: String) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            guard name.hasPrefix("codex-"), name.hasSuffix(".sock") || name.hasSuffix(".log"),
                  let pid = pid_t(name.dropFirst(6).prefix { $0.isNumber }), pid > 1,
                  kill(pid, 0) != 0, errno == ESRCH else { continue }
            unlink(directory + "/" + name)
        }
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { target in
                _ = strcpy(UnsafeMutableRawPointer(target).assumingMemoryBound(to: CChar.self), source)
            }
        }
        return address
    }

    static func connect(_ path: String) -> Int32? {
        guard var address = address(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        noSignal(fd)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    /// Binds a temporary name and renames it into place once listening, so the
    /// TUI can never find a socket that refuses its connection.
    static func listen(_ path: String) -> Int32? {
        let temporary = path + ".\(getpid()).tmp"
        guard var address = address(temporary), Self.address(path) != nil else { return nil }
        unlink(temporary)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(temporary, 0o600) == 0, Darwin.listen(fd, 8) == 0, rename(temporary, path) == 0 else {
            Darwin.close(fd); unlink(temporary); return nil
        }
        return fd
    }

    static func peerPID(_ fd: Int32) -> pid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return nil }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    static func writeAll<C: Collection>(_ fd: Int32, _ bytes: C) -> Bool where C.Element == UInt8 {
        let data = Array(bytes)
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if sent < 0 && errno == EINTR { continue }
            guard sent > 0 else { return false }
            offset += sent
        }
        return true
    }
}

enum CodexProxyProcess {
    static func info(_ pid: pid_t) -> (parent: pid_t, birth: UInt64)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB) else { return nil }
        return (pid_t(info.pbi_ppid), info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    /// The node launcher runs the native TUI as its child, so the TUI is a
    /// descendant of the wrapper's PID rather than the PID itself.
    static func descends(_ pid: pid_t, from ancestor: pid_t, birth: UInt64) -> Bool {
        var current = pid
        for _ in 0..<32 {
            guard let node = info(current) else { return false }
            if current == ancestor { return node.birth == birth }
            guard node.parent > 1 else { return false }
            current = node.parent
        }
        return false
    }
}

/// Optional JSON-lines diagnostics in the proxy's private directory. Thread
/// ids, outcomes and timings only; never message text or credentials.
final class CodexProxyLog {
    private let handle: FileHandle?
    private let lock = NSLock()

    init(path: String?) {
        guard let path, path.hasPrefix("/") else { handle = nil; return }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        handle = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
    }

    func write(_ record: [String: Any]) {
        guard let handle else { return }
        var record = record
        record["t"] = Date().timeIntervalSince1970
        record["pid"] = Int(getpid())
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }
}
