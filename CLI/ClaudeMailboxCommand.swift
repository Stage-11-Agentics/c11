import Darwin
import Foundation

/// Runs only as an async SessionStart hook. The original hook retains its
/// session binding across app restarts; no token or hook input is persisted.
/// Mail text passes through memory only; the app, never this bridge, claims it.
enum ClaudeMailboxCommand {
    struct Binding {
        let panelID: String
        let agentPID: pid_t
        let agentBirth: UInt64
        let sessionID: String
        let transcript: String
        let inbox: String
        let token: String
        // A reconnect is the same listener. A new SessionStart hook (including
        // resume with the same Claude session UUID) has a different identity.
        let registrationID = UUID().uuidString

        init?(environment: [String: String], input: Data) {
            guard input.count <= 64 * 1024,
                  let hook = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
                  hook["hook_event_name"] as? String == "SessionStart",
                  let session = hook["session_id"] as? String, UUID(uuidString: session) != nil,
                  let transcript = hook["transcript_path"] as? String, transcript.hasPrefix("/"),
                  URL(fileURLWithPath: transcript).lastPathComponent == session + ".jsonl",
                  let panel = environment["C11_PANEL_ID"] ?? environment["C11_TAB_ID"] ?? environment["CMUX_SURFACE_ID"],
                  UUID(uuidString: panel) != nil,
                  let rawPID = environment["C11_AGENT_INTERACTIVE_PID"], let pid = pid_t(rawPID), pid > 0,
                  let birth = ClaudeMailboxCommand.birth(of: pid),
                  let inbox = environment["CLAUDE_CODE_MESSAGING_SOCKET"], !inbox.isEmpty,
                  let token = environment["CLAUDE_CODE_MESSAGING_TOKEN"], !token.isEmpty,
                  token.utf8.count <= 16 * 1024 else { return nil }
            self.panelID = panel
            self.agentPID = pid
            self.agentBirth = birth
            self.sessionID = session
            self.transcript = transcript
            self.inbox = inbox
            self.token = token
        }

        var isAlive: Bool { ClaudeMailboxCommand.birth(of: agentPID) == agentBirth }
    }

    private static func birth(of pid: pid_t) -> UInt64? {
        #if os(macOS)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        #else
        guard let stat = LinuxProc.stat(pid), stat.state != "Z" else { return nil }
        return LinuxProc.epochMicroseconds(stat)
        #endif
    }

    /// Connection/authentication attempts must be bounded by the caller. The
    /// CLI uses one second so an absent app cannot outlive the harness watchdog.
    /// Only explicit refusals retire; disappearance/EOF never proves agent death.
    static func run(binding: Binding, connect: () throws -> Int32) {
        var failures = 0
        let carry = Carry()
        while binding.isAlive {
            let retry = autoreleasepool { () -> Bool in
                do {
                    let descriptor = try connect()
                    return try runConnection(binding: binding, descriptor: descriptor, carry: carry,
                                             registered: { failures = 0 })
                } catch ConnectionFailure.retired {
                    return false
                } catch Failure.invalidFrame {
                    return false
                } catch {
                    return true
                }
            }
            guard retry, binding.isAlive else { return }
            let until = uptime + min(2, 0.25 * pow(2, Double(min(failures, 3))))
            failures = min(failures + 1, 3)
            while binding.isAlive, uptime < until {
                Thread.sleep(forTimeInterval: min(0.1, max(0, until - uptime)))
            }
        }
    }

    enum ConnectionFailure: Error { case retired }

    /// C11H-184: an unconfirmed or queued inline delivery outlives its
    /// connection. A c11 relaunch replaces the app while Claude still holds
    /// the text; the new app never sent that delivery. On each new connection
    /// the bridge says which envelopes it holds (`holding`), so the app does
    /// not offer them again, and the acceptance names them (`carried`), so
    /// the app claims them. Without this the same mail reaches Claude twice.
    /// Carried watches are kept apart from the current connection's watch,
    /// so a new delivery never discards them, and a second reconnect keeps
    /// the older ones until each confirms or ends.
    private final class Carry {
        var late: LateWatch?
        var carried: [LateWatch] = []
    }

    /// True means transport/readiness retry; false is definitive retirement.
    private static func runConnection(binding: Binding, descriptor: Int32, carry: Carry,
                                      registered: () -> Void) throws -> Bool {
        let stream = try ClaudeMailboxStream(descriptor: descriptor, isAlive: { binding.isAlive })
        defer { stream.close() }
        let requestID = UUID().uuidString
        try stream.write([
            "id": requestID, "method": "mailbox.native.subscribe",
            "params": ["panel_id": binding.panelID, "agent_pid": Int(binding.agentPID),
                       "route": "claude_inbox", "session_id": binding.registrationID,
                       "claude_session_id": binding.sessionID,
                       "can_queue": false, "supports_inline_mail": true]
        ], deadline: uptime + 1)
        guard let reply = try stream.read(deadline: uptime + 3) else { return true }
        guard reply["id"] as? String == requestID else { throw Failure.invalidFrame }
        guard reply["ok"] as? Bool == true else {
            // Ownership admission can wait two seconds for the first HC
            // inventory. A pending inventory is not a definitive rejection.
            guard reply["ok"] as? Bool == false,
                  let error = reply["error"] as? [String: Any] else { return false }
            if error["code"] as? String == "not_ready" { return true }
            let data = error["data"] as? [String: Any]
            return error["code"] as? String == "hc_inventory_pending"
                && data?["retryable"] as? Bool == true
                && data?["pre_dispatch"] as? Bool == true
        }
        registered()

        // A watch from an earlier connection is one this app never sent. Only
        // inline mail can be claimed by its envelope ids; anything else ends.
        if var previous = carry.late {
            carry.late = nil
            if !previous.ids.isEmpty, uptime < previous.until {
                previous.carried = true
                carry.carried.append(previous)
            }
        }
        carry.carried.removeAll { uptime >= $0.until }
        for held in carry.carried {
            try stream.write(["type": "holding", "delivery_id": held.deliveryID, "ids": held.ids], deadline: uptime + 1)
        }
        while binding.isAlive {
            let shouldContinue: Bool
            do {
                shouldContinue = try autoreleasepool { () throws -> Bool in
                    // No idle transcript or mailbox polling. The timeout only checks
                    // the harness lifetime, including PID reuse and orphaned hooks.
                    // An unconfirmed offer is watched briefly between frame reads.
                    let watches = carry.carried + [carry.late].compactMap { $0 }
                    let readDeadline = watches.map { min(uptime + 0.05, $0.until) }.min() ?? uptime + 1
                    guard let frame = try stream.read(deadline: readDeadline) else {
                        // Cleared only once the acceptance is written: a write
                        // lost to a closing connection is carried to the next.
                        for watch in carry.carried {
                            if (try? watch.observer.observe()) == true {
                                try stream.write(watch.acceptance, deadline: uptime + 0.2)
                                carry.carried.removeAll { $0.deliveryID == watch.deliveryID }
                            } else if uptime >= watch.until {
                                carry.carried.removeAll { $0.deliveryID == watch.deliveryID }
                            }
                        }
                        if let watch = carry.late {
                            if (try? watch.observer.observe()) == true {
                                try stream.write(watch.acceptance, deadline: uptime + 0.2)
                                carry.late = nil
                            } else if uptime >= watch.until {
                                carry.late = nil
                            }
                        }
                        return true
                    }
                    if frame["type"] as? String == "replaced" { return false }
                    guard frame["type"] as? String == "deliver" else { return true }
                    guard let deliveryID = frame["delivery_id"] as? String,
                          UUID(uuidString: deliveryID) != nil else { throw Failure.invalidFrame }
                    // A newer offer carries the same invitation text, so an older
                    // watch could not tell whose record it saw.
                    carry.late = nil
                    guard let text = frame["text"] as? String, !text.isEmpty,
                          frame["inline"] as? Bool == true || text == ClaudeMailboxAcceptance.invitation else {
                        try reject(stream, deliveryID, "unsupported_invitation")
                        return true
                    }
                    carry.late = try deliver(binding: binding, stream: stream, deliveryID: deliveryID, text: text,
                                             ids: frame["inline"] as? Bool == true ? inlineIDs(frame["ids"]) : [])
                    return true
                }
            } catch {
                // Replacement is written immediately before the app shuts down
                // the old stream. A concurrent acknowledgement can fail before
                // we read that final frame; consume it before deciding to retry.
                if stream.receivedReplacementBeforeClose() { return false }
                throw error
            }
            if !shouldContinue { return false }
        }
        return false
    }

    /// The app's own bound is two seconds from dispatch. Reporting first lets it
    /// log why the offer failed; the watch after it lets a slightly late
    /// confirmation still reach the app as `native_late_accept`.
    static let confirmWindow: TimeInterval = 1.8
    static let lateWindow: TimeInterval = 10
    /// A message queued behind a running turn reaches the agent at that turn's
    /// next tool boundary. Past this the Stop drain or the next ring has it.
    static let queuedWindow: TimeInterval = 300

    private struct LateWatch {
        let deliveryID: String
        let observer: ClaudeMailboxAcceptance
        let until: TimeInterval
        /// The envelopes an inline delivery carried, as the app named them.
        var ids: [String] = []
        /// Set when the watch began on an earlier connection.
        var carried = false

        var acceptance: [String: Any] {
            var frame: [String: Any] = ["type": "accepted", "delivery_id": deliveryID]
            if carried { frame["carried"] = true; frame["ids"] = ids }
            return frame
        }
    }

    /// Envelope ids are ULIDs; at most one inline batch's worth is kept.
    static func inlineIDs(_ value: Any?) -> [String] {
        guard let values = value as? [String], values.count <= 1_024 else { return [] }
        let ids = values.filter { $0.utf8.count == 26 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) } }
        return ids.count == values.count ? ids : []
    }

    private static func reject(_ stream: ClaudeMailboxStream, _ deliveryID: String, _ reason: String) throws {
        try stream.write(["type": "rejected", "delivery_id": deliveryID, "reason": reason], deadline: uptime + 0.2)
    }

    private static func deliver(binding: Binding, stream: ClaudeMailboxStream, deliveryID: String,
                                text: String, ids: [String] = []) throws -> LateWatch? {
        let deadline = uptime + confirmWindow
        guard binding.isAlive else { throw Failure.closed }
        // Until the inbox write starts, nothing has been sent, so these
        // rejections are definite and name what was missing.
        let transcript = ClaudeMailboxAcceptance.transcriptPath(hookPath: binding.transcript, sessionID: binding.sessionID)
        guard let observer = try? ClaudeMailboxAcceptance(path: transcript, sessionID: binding.sessionID, text: text) else {
            try reject(stream, deliveryID, "transcript_unavailable")
            return nil
        }
        guard let inbox = try? ClaudeMailboxStream(path: binding.inbox, deadline: min(deadline, uptime + 0.3),
                                                  isAlive: { binding.isAlive }) else {
            try reject(stream, deliveryID, "inbox_unavailable")
            return nil
        }
        do {
            // The token is never persisted, printed, or passed in argv.
            try inbox.write(["type": "auth", "token": binding.token], deadline: deadline)
            try inbox.write(["type": "user", "message": ["role": "user", "content": text]], deadline: deadline)
            inbox.close()
        } catch {
            // A partial write may still arrive, so keep watching for it.
            inbox.close()
            try reject(stream, deliveryID, "inbox_write_failed")
            return LateWatch(deliveryID: deliveryID, observer: observer, until: uptime + lateWindow, ids: ids)
        }
        while uptime < deadline, binding.isAlive, stream.isConnected {
            if try observer.observe() {
                try stream.write(["type": "accepted", "delivery_id": deliveryID], deadline: uptime + 0.2)
                return nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard binding.isAlive, stream.isConnected else { return nil }
        if observer.queued {
            // Not delivered yet, and not failed: the typed doorbell would only
            // add a second copy. The mail stays unread until the agent has it.
            try stream.write(["type": "queued", "delivery_id": deliveryID], deadline: uptime + 0.2)
            return LateWatch(deliveryID: deliveryID, observer: observer, until: uptime + queuedWindow, ids: ids)
        }
        // Explicit inbound policy (crossSessionInbound refuse or hold) accepts
        // the write and answers nothing, so it is indistinguishable here from a
        // slow harness or a changed acceptance marker. Silence is not acceptance.
        try reject(stream, deliveryID, "unconfirmed")
        return LateWatch(deliveryID: deliveryID, observer: observer, until: uptime + lateWindow, ids: ids)
    }

    fileprivate enum Failure: Error { case closed, invalidFrame, unavailable, timeout }
    fileprivate static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// A bounded newline-JSON transport. The app connection is authenticated by
/// the normal CLI machinery before its descriptor is handed over here.
private final class ClaudeMailboxStream {
    private var fd: Int32
    private var pending = Data()
    private let isAlive: () -> Bool

    init(descriptor: Int32, isAlive: @escaping () -> Bool) throws {
        fd = descriptor
        self.isAlive = isAlive
        #if os(macOS)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif   // Linux has no SO_NOSIGPIPE; the CLI ignores SIGPIPE at start (c11.swift).
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close()
            throw ClaudeMailboxCommand.Failure.unavailable
        }
    }

    convenience init(path: String, deadline: TimeInterval, isAlive: @escaping () -> Bool) throws {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ClaudeMailboxCommand.Failure.unavailable
        }
        var metadata = stat()
        guard stat(path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFSOCK else { throw ClaudeMailboxCommand.Failure.unavailable }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClaudeMailboxCommand.Failure.unavailable }
        try self.init(descriptor: descriptor, isAlive: isAlive)
        address.sun_family = sa_family_t(AF_UNIX)
        #if os(macOS)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { target in
                _ = strcpy(UnsafeMutableRawPointer(target).assumingMemoryBound(to: CChar.self), source)
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS, try ready(events: Int16(POLLOUT), deadline: deadline) else {
                throw ClaudeMailboxCommand.Failure.unavailable
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                throw ClaudeMailboxCommand.Failure.unavailable
            }
        }
        // The listener must run as this user before any byte is sent (C11H-364).
        guard C11UserRuntime.peerIsUser(fd, expected: SocketClient.expectedPeerUserID) else {
            throw ClaudeMailboxCommand.Failure.unavailable
        }
    }

    deinit { close() }
    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    var isConnected: Bool {
        guard fd >= 0 else { return false }
        var descriptor = pollfd(fd: fd, events: 0, revents: 0)
        guard poll(&descriptor, 1, 0) >= 0 else { return errno == EINTR }
        return descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) == 0
    }

    func receivedReplacementBeforeClose() -> Bool {
        let deadline = ClaudeMailboxCommand.uptime + 0.05
        while ClaudeMailboxCommand.uptime < deadline, let frame = try? read(deadline: deadline) {
            if frame["type"] as? String == "replaced" { return true }
        }
        return false
    }

    private func ready(events: Int16, deadline: TimeInterval) throws -> Bool {
        while true {
            guard isAlive() else { throw ClaudeMailboxCommand.Failure.closed }
            let remaining = deadline - ClaudeMailboxCommand.uptime
            if remaining <= 0 { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 100).rounded(.up)))
            if result < 0, errno == EINTR { continue }
            guard result >= 0 else { throw ClaudeMailboxCommand.Failure.closed }
            if descriptor.revents & events != 0 { return true }
            if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                throw ClaudeMailboxCommand.Failure.closed
            }
            // A poll slice can expire while the caller's deadline still has time.
            if result == 0 { continue }
        }
    }

    func write(_ object: [String: Any], deadline: TimeInterval) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        var offset = 0
        while offset < data.count {
            guard try ready(events: Int16(POLLOUT), deadline: deadline) else {
                throw ClaudeMailboxCommand.Failure.timeout
            }
            let sent = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if sent < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard sent > 0 else { throw ClaudeMailboxCommand.Failure.closed }
            offset += sent
        }
    }

    func read(deadline: TimeInterval) throws -> [String: Any]? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                guard newline <= 512 * 1024 else { throw ClaudeMailboxCommand.Failure.invalidFrame }
                let frame = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else {
                    throw ClaudeMailboxCommand.Failure.invalidFrame
                }
                return object
            }
            // Inline mail plus JSON escaping (MailboxInlineBatch.budget).
            guard pending.count <= 512 * 1024 else { throw ClaudeMailboxCommand.Failure.invalidFrame }
            guard try ready(events: Int16(POLLIN), deadline: deadline) else { return nil }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw ClaudeMailboxCommand.Failure.closed }
            pending.append(contentsOf: buffer[..<count])
        }
    }
}

/// Started by the c11 Grok wrapper beside an interactive Grok it launched in
/// leader mode on a private socket. It offers the fixed invitation to the bound
/// session through Grok's own ACP leader, never claims mail, stores nothing,
/// and never answers a permission request (the TUI owns those). Any failure
/// leaves the app's typed doorbell decision in place.
enum GrokMailboxCommand {
    struct Binding {
        let panelID: String
        let agentPID: pid_t
        let agentBirth: UInt64
        let sessionID: String
        let leaderSocket: String
        let grok: String
        let registry: String

        init?(environment: [String: String], arguments: [String]) {
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let key = arguments[index]
                guard ["--leader-socket", "--session-id", "--grok", "--registry"].contains(key),
                      index + 1 < arguments.count, values[key] == nil else { return nil }
                values[key] = arguments[index + 1]
                index += 2
            }
            guard let socket = values["--leader-socket"], socket.hasPrefix("/"),
                  let session = values["--session-id"], UUID(uuidString: session) != nil,
                  let grok = values["--grok"], grok.hasPrefix("/"),
                  let registry = values["--registry"], registry.hasPrefix("/"),
                  let panel = environment["C11_PANEL_ID"] ?? environment["CMUX_SURFACE_ID"],
                  UUID(uuidString: panel) != nil,
                  let rawPID = environment["C11_AGENT_INTERACTIVE_PID"], let pid = pid_t(rawPID), pid > 1,
                  let birth = GrokMailboxCommand.birth(of: pid) else { return nil }
            panelID = panel
            agentPID = pid
            agentBirth = birth
            // Grok keys sessions by the exact string it was given (the wrapper's
            // uuidgen is uppercase); comparisons elsewhere ignore case.
            sessionID = session
            leaderSocket = socket
            self.grok = grok
            self.registry = registry
        }

        var isAlive: Bool { GrokMailboxCommand.birth(of: agentPID) == agentBirth }

        /// The leader is up once its socket exists. Grok refuses leader mode
        /// under a sandbox profile and never creates one: typed mail stays.
        func waitForLeader(timeout: TimeInterval = 15) -> Bool {
            let until = GrokMailboxCommand.uptime + timeout
            while GrokMailboxCommand.uptime < until, isAlive {
                var metadata = stat()
                if stat(leaderSocket, &metadata) == 0, metadata.st_uid == getuid(),
                   metadata.st_mode & S_IFMT == S_IFSOCK { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return false
        }
    }

    static let confirmWindow: TimeInterval = 1.8
    static let lateWindow: TimeInterval = 10

    enum Outcome { case ended, clientFailed, subscribeRefused }

    static func run(binding: Binding, descriptor: Int32) throws -> Outcome {
        signal(SIGPIPE, SIG_IGN)
        var client = readyClient(binding)
        defer { client?.terminate() }
        guard client != nil else { return .clientFailed }
        let stream = try ClaudeMailboxStream(descriptor: descriptor, isAlive: { binding.isAlive })
        let requestID = UUID().uuidString
        try stream.write([
            "id": requestID, "method": "mailbox.native.subscribe",
            "params": ["panel_id": binding.panelID, "agent_pid": Int(binding.agentPID),
                       "route": "grok_leader", "session_id": UUID().uuidString, "can_queue": false]
        ], deadline: uptime + 1)
        guard let reply = try stream.read(deadline: uptime + 1),
              reply["id"] as? String == requestID, reply["ok"] as? Bool == true else { return .subscribeRefused }

        var late: (deliveryID: String, until: TimeInterval)?
        while binding.isAlive {
            let shouldContinue = try autoreleasepool { () throws -> Bool in
                let readDeadline = late.map { min(uptime + 0.05, $0.until) } ?? uptime + 1
                guard let frame = try stream.read(deadline: readDeadline) else {
                    if let watch = late {
                        if client?.confirmed == true {
                            late = nil
                            try stream.write(["type": "accepted", "delivery_id": watch.deliveryID], deadline: uptime + 0.2)
                        } else if uptime >= watch.until {
                            late = nil
                        }
                    }
                    return true
                }
                if frame["type"] as? String == "replaced" { return false }
                guard frame["type"] as? String == "deliver" else { return true }
                guard let deliveryID = frame["delivery_id"] as? String,
                      UUID(uuidString: deliveryID) != nil else { throw ClaudeMailboxCommand.Failure.invalidFrame }
                late = nil
                guard frame["text"] as? String == ClaudeMailboxAcceptance.invitation else {
                    try reject(stream, deliveryID, "unsupported_invitation")
                    return true
                }
                // Refuse before anything is sent when the TUI may be showing
                // another session: the typed doorbell types into what it shows.
                guard let registry = FileManager.default.contents(atPath: binding.registry),
                      GrokMailboxAcceptance.showsOnlyBoundSession(registry: registry, pid: binding.agentPID,
                                                                  birthMicros: binding.agentBirth,
                                                                  sessionID: binding.sessionID) else {
                    try reject(stream, deliveryID, "session_conflict")
                    return true
                }
                guard let current = client, current.isReady else {
                    client?.terminate()
                    client = GrokLeaderClient(grok: binding.grok, socket: binding.leaderSocket,
                                              sessionID: binding.sessionID)
                    try reject(stream, deliveryID, "not_ready")
                    return true
                }
                guard current.prompt(ClaudeMailboxAcceptance.invitation) else {
                    try reject(stream, deliveryID, "inbox_write_failed")
                    return true
                }
                let deadline = uptime + confirmWindow
                while uptime < deadline, binding.isAlive, stream.isConnected {
                    if current.confirmed {
                        try stream.write(["type": "accepted", "delivery_id": deliveryID], deadline: uptime + 0.2)
                        return true
                    }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                guard binding.isAlive, stream.isConnected else { return false }
                try reject(stream, deliveryID, "unconfirmed")
                late = (deliveryID, uptime + lateWindow)
                return true
            }
            if !shouldContinue { return .ended }
        }
        return .ended
    }

    /// One ACP client stays connected for the sidecar's life, so a delivery is
    /// a single write: starting a client can take seconds.
    private static func readyClient(_ binding: Binding, timeout: TimeInterval = 10) -> GrokLeaderClient? {
        let until = uptime + timeout
        guard let client = GrokLeaderClient(grok: binding.grok, socket: binding.leaderSocket,
                                            sessionID: binding.sessionID) else { return nil }
        while uptime < until, binding.isAlive, client.isRunning {
            if client.isReady { return client }
            Thread.sleep(forTimeInterval: 0.05)
        }
        client.terminate()
        return nil
    }

    private static func reject(_ stream: ClaudeMailboxStream, _ deliveryID: String, _ reason: String) throws {
        try stream.write(["type": "rejected", "delivery_id": deliveryID, "reason": reason], deadline: uptime + 0.2)
    }

    static func birth(of pid: pid_t) -> UInt64? {
        #if os(macOS)
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        #else
        guard let stat = LinuxProc.stat(pid), stat.state != "Z" else { return nil }
        return LinuxProc.epochMicroseconds(stat)
        #endif
    }

    fileprivate static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// `grok agent --leader --leader-socket <path> stdio`: an ACP client of the
/// panel's private leader. Output is drained continuously and discarded,
/// except the initialize reply and echoes of an armed invitation.
private final class GrokLeaderClient {
    private let sessionID: String
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffered = Data()
    private var initialized = false
    private var armedPromptID: Int?
    private var hit = false
    private var nextID = 1

    init?(grok: String, socket: String, sessionID: String) {
        self.sessionID = sessionID
        process.executableURL = URL(fileURLWithPath: grok)
        process.arguments = ["agent", "--leader", "--leader-socket", socket, "stdio"]
        // The client is Grok's own proxy; it needs no c11 identity or socket.
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("C11_") && !$0.key.hasPrefix("CMUX_")
        }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consume(data)
        }
        do { try process.run() } catch { return nil }
        guard send(.initialize) != nil else {
            terminate()
            return nil
        }
    }

    deinit { terminate() }

    var isRunning: Bool { process.isRunning }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return initialized && process.isRunning }
    var confirmed: Bool { lock.lock(); defer { lock.unlock() }; return hit }

    func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Arms confirmation, then writes the delivery requests (the prompt alone).
    /// The leader runs it in the bound session even though this client never
    /// loaded it; `GrokLeaderRequest` says why it must never load it.
    func prompt(_ text: String) -> Bool {
        lock.lock()
        hit = false
        armedPromptID = nil
        lock.unlock()
        for request in GrokLeaderRequest.delivery(sessionID: sessionID, text: text) {
            if request.method == "session/prompt" {
                lock.lock()
                armedPromptID = nextID
                lock.unlock()
            }
            guard send(request) != nil else { return false }
        }
        return true
    }

    private func send(_ request: GrokLeaderRequest) -> Int? {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        guard let data = request.frame(id: id) else { return nil }
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { return nil }
        return id
    }

    private func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffered.append(data)
        while let newline = buffered.firstIndex(of: 0x0A) {
            let line = Data(buffered[..<newline])
            buffered.removeSubrange(...newline)
            guard let frame = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            let id = (frame["id"] as? NSNumber)?.intValue
            if id == 1, frame["method"] == nil, frame["result"] != nil { initialized = true }
            guard let armed = armedPromptID, !hit else { continue }
            if (id == armed && frame["method"] == nil && frame["result"] != nil)
                || GrokMailboxAcceptance.confirms(frame: frame, sessionID: sessionID) {
                hit = true
            }
        }
        // A line this long is no protocol frame the sidecar needs.
        if buffered.count > 8 * 1024 * 1024 { buffered.removeAll() }
    }
}
