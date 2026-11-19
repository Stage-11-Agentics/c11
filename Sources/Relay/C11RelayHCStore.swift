import Foundation
import Darwin

/// The relay CLI's connection to its own machine's c11 hc core: line-framed
/// JSON-RPC over the core's Unix socket, `doc.get` and `doc.set` only. Every
/// read and write is bounded; a core that does not answer fails the call.
final class C11RelayHCStore: C11RelayDocStore {
    private let path: String
    private let timeout: TimeInterval
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextID = 1

    init(socketPath: String, timeout: TimeInterval = 1.0) {
        self.path = socketPath
        self.timeout = timeout
    }

    deinit { close() }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        buffer.removeAll()
    }

    func get(_ name: String) throws -> (value: Any?, version: UInt64) {
        let result = try call("doc.get", ["name": name])
        guard let version = (result["version"] as? NSNumber)?.uint64Value else {
            throw C11RelayStoreError.unavailable("malformed doc.get reply")
        }
        let value = result["value"]
        return (value is NSNull ? nil : value, version)
    }

    func set(_ name: String, value: Any?, version: UInt64) throws -> UInt64 {
        let result = try call("doc.set", ["name": name, "value": value ?? NSNull(), "version": version])
        guard let written = (result["version"] as? NSNumber)?.uint64Value else {
            throw C11RelayStoreError.unavailable("malformed doc.set reply")
        }
        return written
    }

    private func connect() throws {
        guard fd < 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw C11RelayStoreError.unavailable("hc socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw C11RelayStoreError.unavailable("socket() failed") }
        #if os(macOS)
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif   // Linux has no SO_NOSIGPIPE; the CLI ignores SIGPIPE at start (c11.swift).
        var tv = timeval(tv_sec: Int(timeout), tv_usec: suseconds_t((timeout - floor(timeout)) * 1_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(socket)
            throw C11RelayStoreError.unavailable("c11's hc core on this machine is not running (\(path))")
        }
        fd = socket
        do {
            let hello = try roundTrip("hello", ["generation": 1])
            guard (hello["generation"] as? NSNumber)?.intValue == 1 else {
                throw C11RelayStoreError.unavailable("hc core speaks another protocol generation")
            }
        } catch {
            close()
            throw error
        }
    }

    private func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        try connect()
        do { return try roundTrip(method, params) }
        catch { if case C11RelayStoreError.conflict = error {} else { close() }; throw error }
    }

    private func roundTrip(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let request: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request),
              var data = try? JSONSerialization.data(withJSONObject: request) else {
            throw C11RelayStoreError.unavailable("unencodable request")
        }
        data.append(0x0A)
        try writeAll(data)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            let line = try readLine(deadline: deadline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                throw C11RelayStoreError.unavailable("malformed hc reply")
            }
            // Notifications carry no id; skip them.
            guard let replyID = (message["id"] as? NSNumber)?.intValue, replyID == id else { continue }
            if let error = message["error"] as? [String: Any] {
                let kind = (error["data"] as? [String: Any])?["kind"] as? String ?? ""
                if kind == "conflict" { throw C11RelayStoreError.conflict }
                throw C11RelayStoreError.unavailable("\(method) failed: \(kind.isEmpty ? (error["message"] as? String ?? "error") : kind)")
            }
            guard let result = message["result"] as? [String: Any] else {
                throw C11RelayStoreError.unavailable("malformed hc reply")
            }
            return result
        }
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw C11RelayStoreError.unavailable("hc core write failed") }
            offset += written
        }
    }

    private func readLine(deadline: TimeInterval) throws -> Data {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            guard buffer.count <= 4 << 20 else { throw C11RelayStoreError.unavailable("hc reply too large") }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw C11RelayStoreError.unavailable("hc core did not answer in time")
            }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                throw C11RelayStoreError.unavailable("hc core did not answer in time")
            }
            guard count > 0 else { throw C11RelayStoreError.unavailable("hc core closed the connection") }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
