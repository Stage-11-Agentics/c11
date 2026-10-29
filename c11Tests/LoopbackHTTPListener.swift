import Foundation
import Network

/// A loopback-only HTTP/1.1 listener for tests of the app's own fetches
/// (favicons, search suggestions). It answers every request with a few bytes
/// plus the extra headers `headers(path)` returns, closes the connection, and
/// records each request's path and Cookie header.
final class LoopbackHTTPListener: @unchecked Sendable {
    struct Request {
        let path: String
        let cookie: String?
    }

    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "c11.tests.loopback-http-listener")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private let headers: @Sendable (String) -> [String]

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    init(headers: @escaping @Sendable (String) -> [String] = { _ in [] }) throws {
        self.headers = headers
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        var serve: ((NWConnection) -> Void)?
        listener.newConnectionHandler = { connection in serve?(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            listener.cancel()
            throw NWError.posix(.ETIMEDOUT)
        }
        self.port = port
        serve = { [weak self] connection in self?.serve(connection) }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(on: connection, buffer: Data())
    }

    private func receiveHead(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(on: connection, head: buffer.subdata(in: buffer.startIndex..<end.lowerBound))
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveHead(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(on connection: NWConnection, head: Data) {
        let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let path = requestLine.count > 1 ? String(requestLine[1]) : "/"
        let cookie = lines.dropFirst().first { $0.lowercased().hasPrefix("cookie:") }
            .map { String($0.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces) }
        lock.lock()
        recorded.append(Request(path: path, cookie: cookie))
        lock.unlock()

        let body = Data("ok".utf8)
        let responseHeaders = ["Content-Length: \(body.count)", "Connection: close"] + headers(path)
        var response = Data(("HTTP/1.1 200 OK\r\n" + responseHeaders.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
