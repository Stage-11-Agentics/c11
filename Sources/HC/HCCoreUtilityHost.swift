import Darwin
import Foundation

/// A blocking, plain (unframed) JSON-RPC client for one hc core socket, for
/// `c11-core` (C11H-37). `hello` with `generation` only keeps the connection
/// newline-delimited, as `C11RelayHCStore` does; notifications are skipped.
final class HCCorePlainClient: HCCoreLink {
    private let fd: Int32
    private var buffer = Data()
    private var nextID = 1
    let peerUID: UInt32?
    let peerPID: Int32?
    private(set) var hello: [String: Any] = [:]

    init(path: String, timeout: TimeInterval = 5) throws {
        guard path.utf8.count < 104 else { throw HCCoreRPCError(code: "connect", message: "socket path too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HCCoreRPCError(code: "connect", message: "socket() failed") }
        #if os(macOS)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                strncpy(UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), source, capacity)
            }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw HCCoreRPCError(code: "connect", message: "nothing answers on \(path)")
        }
        self.fd = fd
        #if os(macOS)
        var uid: uid_t = 0, gid: gid_t = 0
        peerUID = getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        var pid: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        peerPID = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 ? pid : nil
        #else
        let peer = LinuxProc.peerCredentials(fd)
        peerUID = peer?.uid
        peerPID = peer?.pid
        #endif
        do { hello = try call("hello", ["generation": 1], timeout: timeout) } catch {
            Darwin.close(fd)
            throw error
        }
    }

    deinit { close() }

    private var closed = false
    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }

    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        guard !closed else { throw HCCoreRPCError(code: "closed", message: "connection closed") }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: suseconds_t((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let id = nextID
        nextID += 1
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        var line = try JSONSerialization.data(withJSONObject: request)
        line.append(0x0A)
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw HCCoreRPCError(code: "write", message: "the core closed the connection") }
                offset += written
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let reply = try readLine(deadline: deadline)
            guard let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { continue }
            guard (object["id"] as? NSNumber)?.intValue == id else { continue }
            if let error = object["error"] as? [String: Any] {
                let kind = (error["data"] as? [String: Any])?["kind"] as? String
                let code = kind ?? (error["code"] as? String) ?? (error["code"] as? NSNumber).map { "\($0)" } ?? "error"
                throw HCCoreRPCError(code: code, message: error["message"] as? String ?? "")
            }
            return (object["result"] as? [String: Any]) ?? [:]
        }
    }

    private func readLine(deadline: Date) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            guard Date() < deadline else { throw HCCoreRPCError(code: "timeout", message: "the core did not answer in time") }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                throw HCCoreRPCError(code: "timeout", message: "the core did not answer in time")
            }
            guard count > 0 else { throw HCCoreRPCError(code: "closed", message: "the core closed the connection") }
            buffer.append(contentsOf: chunk[0..<count])
            guard buffer.count < 16 * 1024 * 1024 else { throw HCCoreRPCError(code: "oversize", message: "reply too large") }
        }
    }
}

/// The real machine for `c11-core`. Read-only except for what an action asks for.
struct HCCoreSystemHost: HCCoreHost {
    let bundleIdentifier: String?
    let appSupport: URL
    /// Reused across checks: its digest cache keys on the pin's file identity.
    let verifier = HCBuildVerifier()

    init(bundleIdentifier: String?,
         appSupport: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")) {
        self.bundleIdentifier = bundleIdentifier
        self.appSupport = appSupport
    }

    var uid: UInt32 { getuid() }

    var machineName: String {
        #if !os(macOS)
        return LinuxProc.hostName
        #else
        var size = 0
        sysctlbyname("kern.hostname", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(size, 1))
        guard sysctlbyname("kern.hostname", &name, &size, nil, 0) == 0 else { return "this Mac" }
        let host = String(cString: name)
        return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
        #endif
    }

    func now() -> Date { Date() }

    func socketFacts(_ path: String) -> HCCoreSocketFacts? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return HCCoreSocketFacts(isSocket: info.st_mode & S_IFMT == S_IFSOCK, ownerUID: info.st_uid)
    }

    func connect(_ path: String) throws -> HCCoreLink { try HCCorePlainClient(path: path) }

    func verifyStateEndpoint(_ configuration: HCLaunchConfiguration, coreID: String) throws {
        try HCBuildVerifier.verifyStateEndpoint(configuration, expectedCoreID: coreID)
    }

    func verifyPeer(_ evidence: HCPeerEvidence, _ configuration: HCLaunchConfiguration) throws -> HCVerifiedPeer {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let verifier = self.verifier
        Task.detached {
            do { box.set(.success(try await verifier.verify(evidence, configuration: configuration))) }
            catch { box.set(.failure(error)) }
            done.signal()
        }
        done.wait()
        return try box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<HCVerifiedPeer, Error> = .failure(HCUnavailableReason.connectionLost)
        func set(_ value: Result<HCVerifiedPeer, Error>) { lock.lock(); self.value = value; lock.unlock() }
        func get() throws -> HCVerifiedPeer { lock.lock(); defer { lock.unlock() }; return try value.get() }
    }

    func process(_ pid: Int32) -> HCCoreProcessFacts? {
        #if !os(macOS)
        guard let stat = LinuxProc.stat(pid), stat.state != "Z", let uid = LinuxProc.uid(pid),
              let started = LinuxProc.startDate(pid) else { return nil }
        return HCCoreProcessFacts(pid: pid, parentPID: stat.parentPID, uid: uid, startedAt: started)
        #else
        guard let info = Self.kinfo(pid) else { return nil }
        let start = info.kp_proc.p_starttime
        return HCCoreProcessFacts(pid: pid, parentPID: info.kp_eproc.e_ppid, uid: info.kp_eproc.e_ucred.cr_uid,
                                  startedAt: Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1e6))
        #endif
    }

    #if os(macOS)
    static func kinfo(_ pid: Int32) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid,
              info.kp_proc.p_stat != CChar(SZOMB) else { return nil }
        return info
    }
    #endif

    /// One `ps` sample per refresh, never per terminal.
    func processTable() -> [HCCoreProcessSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid=,%cpu=,rss="]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Self.parsePS(String(decoding: data, as: UTF8.self))
    }

    static func parsePS(_ text: String) -> [HCCoreProcessSample] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 4, let pid = Int32(f[0]), let ppid = Int32(f[1]),
                  let cpu = Double(f[2].replacingOccurrences(of: ",", with: ".")), let rss = UInt64(f[3]) else { return nil }
            return HCCoreProcessSample(pid: pid, parentPID: ppid, cpuPercent: cpu, residentBytes: rss * 1024)
        }
    }

    func ttyLastOutput(pid: Int32) -> Date? {
        #if !os(macOS)
        return nil   // c11-core's tty clock is macOS-only
        #else
        guard let info = Self.kinfo(pid) else { return nil }
        let device = info.kp_eproc.e_tdev
        guard device != -1, let name = devname(device, S_IFCHR) else { return nil }
        var st = stat()
        guard stat("/dev/" + String(cString: name), &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        #endif
    }

    /// c11's own files, read-only: `session-<bid>.json` (workspace titles) and
    /// `panel-allocations-<bid>.json` (durable `panel:N`).
    func panelMap() -> [String: HCCorePanelRef] {
        Self.panelMap(session: read("session-"), allocations: read("panel-allocations-"))
    }

    private func read(_ prefix: String) -> Data? {
        let id = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? C11Identity.releaseBundleIdentifier
        let safe = id.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let url = appSupport.appendingPathComponent(C11Identity.stateDirectoryName, isDirectory: true)
            .appendingPathComponent("\(prefix)\(safe).json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: 32 * 1024 * 1024)
    }

    static func panelMap(session: Data?, allocations: Data?) -> [String: HCCorePanelRef] {
        var numbers: [String: Int] = [:]
        if let allocations, let object = (try? JSONSerialization.jsonObject(with: allocations)) as? [String: Any] {
            for panel in (object["panels"] as? [[String: Any]]) ?? [] {
                if let id = (panel["id"] as? String)?.lowercased(), let number = (panel["number"] as? NSNumber)?.intValue {
                    numbers[id] = number
                }
            }
        }
        var workspaces: [String: String] = [:]
        if let session, let object = (try? JSONSerialization.jsonObject(with: session)) as? [String: Any] {
            for window in (object["windows"] as? [[String: Any]]) ?? [] {
                let manager = window["tabManager"] as? [String: Any]
                for workspace in (manager?["workspaces"] as? [[String: Any]]) ?? [] {
                    let title = [workspace["customTitle"], workspace["processTitle"], workspace["stableDefaultTitle"]]
                        .compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }.first
                    for panel in (workspace["panels"] as? [[String: Any]]) ?? [] {
                        if let id = (panel["id"] as? String)?.lowercased(), let title { workspaces[id] = title }
                    }
                }
            }
        }
        var map: [String: HCCorePanelRef] = [:]
        for id in Set(numbers.keys).union(workspaces.keys) {
            map[id] = HCCorePanelRef(ref: numbers[id].map { "panel:\($0)" }, workspace: workspaces[id])
        }
        return map
    }

    func sleep(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}
