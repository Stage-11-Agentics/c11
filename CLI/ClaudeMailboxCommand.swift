import Darwin
import Foundation

/// Runs only as an async SessionStart hook. All failures are advisory: closing
/// the subscription restores the app's ordinary typed doorbell decision.
enum ClaudeMailboxCommand {
    struct Binding {
        let panelID: String
        let agentPID: pid_t
        let agentBirth: UInt64
        let sessionID: String
        let transcript: String
        let inbox: String
        let token: String

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
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    static func run(binding: Binding, descriptor: Int32) throws {
        let stream = try ClaudeMailboxStream(descriptor: descriptor)
        let requestID = UUID().uuidString
        // A resume can retain Claude's session UUID. The registration itself
        // is always fresh, so replacement retires the previous hook connection.
        try stream.write([
            "id": requestID, "method": "mailbox.native.subscribe",
            "params": ["panel_id": binding.panelID, "agent_pid": Int(binding.agentPID),
                       "route": "claude_inbox", "session_id": UUID().uuidString,
                       "can_queue": false]
        ], deadline: uptime + 1)
        guard let reply = try stream.read(deadline: uptime + 1),
              reply["id"] as? String == requestID, reply["ok"] as? Bool == true else { return }

        var late: LateWatch?
        while binding.isAlive {
            let shouldContinue = try autoreleasepool { () throws -> Bool in
                // No idle transcript or mailbox polling. The timeout only checks
                // the harness lifetime, including PID reuse and orphaned hooks.
                // An unconfirmed offer is watched briefly between frame reads.
                let readDeadline = late.map { min(uptime + 0.05, $0.until) } ?? uptime + 1
                guard let frame = try stream.read(deadline: readDeadline) else {
                    if let watch = late {
                        if (try? watch.observer.observe()) == true {
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
                      UUID(uuidString: deliveryID) != nil else { throw Failure.invalidFrame }
                // A newer offer carries the same invitation text, so an older
                // watch could not tell whose record it saw.
                late = nil
                guard frame["text"] as? String == ClaudeMailboxAcceptance.invitation else {
                    try reject(stream, deliveryID, "unsupported_invitation")
                    return true
                }
                late = try deliver(binding: binding, stream: stream, deliveryID: deliveryID)
                return true
            }
            if !shouldContinue { return }
        }
    }

    /// The app's own bound is two seconds from dispatch. Reporting first lets it
    /// log why the offer failed; the watch after it lets a slightly late
    /// confirmation still reach the app as `native_late_accept`.
    static let confirmWindow: TimeInterval = 1.8
    static let lateWindow: TimeInterval = 10

    private struct LateWatch {
        let deliveryID: String
        let observer: ClaudeMailboxAcceptance
        let until: TimeInterval
    }

    private static func reject(_ stream: ClaudeMailboxStream, _ deliveryID: String, _ reason: String) throws {
        try stream.write(["type": "rejected", "delivery_id": deliveryID, "reason": reason], deadline: uptime + 0.2)
    }

    private static func deliver(binding: Binding, stream: ClaudeMailboxStream, deliveryID: String) throws -> LateWatch? {
        let deadline = uptime + confirmWindow
        guard binding.isAlive else { throw Failure.closed }
        // Until the inbox write starts, nothing has been sent, so these
        // rejections are definite and name what was missing.
        guard let observer = try? ClaudeMailboxAcceptance(path: binding.transcript, sessionID: binding.sessionID) else {
            try reject(stream, deliveryID, "transcript_unavailable")
            return nil
        }
        guard let inbox = try? ClaudeMailboxStream(path: binding.inbox, deadline: min(deadline, uptime + 0.3)) else {
            try reject(stream, deliveryID, "inbox_unavailable")
            return nil
        }
        do {
            // The token is never persisted, printed, or passed in argv.
            try inbox.write(["type": "auth", "token": binding.token], deadline: deadline)
            try inbox.write(["type": "user", "message": ["role": "user",
                            "content": ClaudeMailboxAcceptance.invitation]], deadline: deadline)
            inbox.close()
        } catch {
            // A partial write may still arrive, so keep watching for it.
            inbox.close()
            try reject(stream, deliveryID, "inbox_write_failed")
            return LateWatch(deliveryID: deliveryID, observer: observer, until: uptime + lateWindow)
        }
        while uptime < deadline, binding.isAlive, stream.isConnected {
            if try observer.observe() {
                try stream.write(["type": "accepted", "delivery_id": deliveryID], deadline: uptime + 0.2)
                return nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard binding.isAlive, stream.isConnected else { return nil }
        // Explicit inbound policy (crossSessionInbound refuse or hold) accepts
        // the write and answers nothing, so it is indistinguishable here from a
        // slow harness or a changed acceptance marker. Silence is not acceptance.
        try reject(stream, deliveryID, "unconfirmed")
        return LateWatch(deliveryID: deliveryID, observer: observer, until: uptime + lateWindow)
    }

    fileprivate enum Failure: Error { case closed, invalidFrame, unavailable, timeout }
    fileprivate static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// A bounded newline-JSON transport. The app connection is authenticated by
/// the normal CLI machinery before its descriptor is handed over here.
private final class ClaudeMailboxStream {
    private var fd: Int32
    private var pending = Data()

    init(descriptor: Int32) throws {
        fd = descriptor
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close()
            throw ClaudeMailboxCommand.Failure.unavailable
        }
    }

    convenience init(path: String, deadline: TimeInterval) throws {
        var address = sockaddr_un()
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ClaudeMailboxCommand.Failure.unavailable
        }
        var metadata = stat()
        guard stat(path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFSOCK else { throw ClaudeMailboxCommand.Failure.unavailable }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClaudeMailboxCommand.Failure.unavailable }
        try self.init(descriptor: descriptor)
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
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

    private func ready(events: Int16, deadline: TimeInterval) throws -> Bool {
        while true {
            let remaining = deadline - ClaudeMailboxCommand.uptime
            if remaining <= 0 { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000, 1_000).rounded(.up)))
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
                let frame = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                    throw ClaudeMailboxCommand.Failure.invalidFrame
                }
                return object
            }
            guard pending.count <= 64 * 1024 else { throw ClaudeMailboxCommand.Failure.invalidFrame }
            guard try ready(events: Int16(POLLIN), deadline: deadline) else { return nil }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw ClaudeMailboxCommand.Failure.closed }
            pending.append(contentsOf: buffer[..<count])
        }
    }
}
