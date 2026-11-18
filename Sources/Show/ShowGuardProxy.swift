import Foundation
import Bonsplit
import Network
import WebKit

/// C11H-377: the connection pin for a guarded show viewer. A host name can
/// answer one way when the guard checks it and another when WebKit connects
/// (DNS rebinding), so the guard's checks alone cannot keep a linked
/// machine's page off this Mac. Every connection from a guarded viewer's data
/// store goes through this SOCKS5 listener inside c11, on 127.0.0.1 only and
/// behind a per-process secret. It resolves the name once, refuses the
/// connection when any answer is forbidden (`ShowURLPolicy.isForbiddenAddress`),
/// and otherwise dials the exact address it checked. WebKit never resolves
/// the name itself. An open and a closed loopback port fail alike, before any
/// connection is made.
final class ShowGuardProxy: @unchecked Sendable {
    static let shared = ShowGuardProxy()

    /// Decides one destination. Tests inject both; the app resolves for real.
    struct Policy: @unchecked Sendable {
        var resolve: (String) -> [String]?
        var isForbidden: (String) -> Bool

        static let system = Policy(
            resolve: { ShowHostResolver.resolve($0, timeout: ShowGuardProxy.resolveTimeout) },
            isForbidden: { ShowURLPolicy.isForbiddenAddress($0, own: ShowOwnAddresses.currentWithoutResolving()) }
        )
    }

    /// What the proxy did with one request, for logs and tests.
    enum Outcome: Equatable {
        case connected(address: String)
        case refused(host: String)
        case unresolved(host: String)
        case failed
    }

    static let resolveTimeout: TimeInterval = 5
    static let startTimeout: TimeInterval = 2
    static let handshakeTimeout: TimeInterval = 15
    static let maxSessions = 256
    static let username = "c11-show"

    let policy: Policy
    let secret: String
    private let queue = DispatchQueue(label: "com.stage11.c11.show-guard-proxy")
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var sessions: [ObjectIdentifier: ShowGuardProxySession] = [:]
    /// Each request's outcome, for tests and debug logs.
    var onOutcome: ((Outcome) -> Void)?

    /// Picks the port a start binds. Tests inject a taken one to force a failed start.
    private let portSource: () -> UInt16?

    init(policy: Policy = .system, secret: String = UUID().uuidString + UUID().uuidString,
         portSource: @escaping () -> UInt16? = ShowGuardProxy.freeLoopbackPort) {
        self.policy = policy
        self.secret = secret
        self.portSource = portSource
    }

    /// The listening port, starting the listener on first use. Nil when it
    /// cannot listen; a viewer then gets an unusable proxy and loads nothing.
    func ensureStarted() -> UInt16? {
        lock.lock(); defer { lock.unlock() }
        if let boundPort, listener != nil { return boundPort }
        guard let port = portSource(), let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        // The first viewer loads at once: wait until the listener accepts, so
        // that load is not refused by a listener still starting. The wait
        // runs on the caller's thread, which is main through `pin`: on the
        // first start and on a restart after a listener failure, for at most
        // `startTimeout` (C11H-386 moves it off main).
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                ready.signal()
            case .failed:
                NSLog("ShowGuardProxy: listener failed on port %d", Int(port))
                ready.signal()
                // The forget waits for the lock, which a start holds across its wait for the next listener's
                // callbacks on this same queue: never take it here, or a start right after a failed one waits
                // out `startTimeout` behind this callback (C11H-402). A failed start was never stored, so only a
                // listener that failed after it was ready is forgotten.
                DispatchQueue.global(qos: .utility).async { [weak self, weak listener] in
                    guard let self, let listener else { return }
                    self.lock.lock()
                    if self.listener === listener { self.listener = nil; self.boundPort = nil }
                    self.lock.unlock()
                }
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + Self.startTimeout) == .success, listener.state == .ready else {
            listener.cancel()
            return nil
        }
        self.listener = listener
        self.boundPort = port
        return port
    }

    func stop() {
        lock.lock()
        let listener = self.listener, all = Array(sessions.values)
        self.listener = nil; boundPort = nil; sessions.removeAll()
        lock.unlock()
        listener?.cancel()
        all.forEach { $0.close() }
    }

    /// The configuration a guarded viewer's data store uses: this proxy and
    /// nothing else, with no failover to a direct connection.
    func proxyConfiguration() -> ProxyConfiguration {
        // Port 1 has no listener: if c11 cannot listen, the viewer loads nothing.
        let port = ensureStarted() ?? 1
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? 1)
        var configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        configuration.applyCredential(username: Self.username, password: secret)
        configuration.allowFailover = false
        return configuration
    }

    /// Points a guarded viewer's own data store at the proxy.
    @MainActor
    func pin(_ store: WKWebsiteDataStore) {
        store.proxyConfigurations = [proxyConfiguration()]
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard sessions.count < Self.maxSessions else {
            lock.unlock()
            connection.cancel()
            return
        }
        let session = ShowGuardProxySession(client: connection, proxy: self, queue: queue)
        sessions[ObjectIdentifier(session)] = session
        lock.unlock()
        session.start()
    }

    fileprivate func finished(_ session: ShowGuardProxySession) {
        lock.lock(); sessions.removeValue(forKey: ObjectIdentifier(session)); lock.unlock()
    }

    fileprivate func report(_ outcome: Outcome) {
#if DEBUG
        switch outcome {
        case .connected(let address): dlog("show.guardProxy connected address=\(address)")
        case .refused(let host): dlog("show.guardProxy refused host=\(host)")
        case .unresolved(let host): dlog("show.guardProxy unresolved host=\(host)")
        case .failed: dlog("show.guardProxy failed")
        }
#endif
        onOutcome?(outcome)
    }

    var sessionCount: Int { lock.lock(); defer { lock.unlock() }; return sessions.count }

    /// A port nothing listens on at this moment, on 127.0.0.1.
    static func freeLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        let port = UInt16(bigEndian: address.sin_port)
        return port == 0 ? nil : port
    }
}

/// The SOCKS5 parts the proxy speaks (RFC 1928, with RFC 1929 passwords).
enum ShowSOCKS {
    enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case notAllowed = 0x02
        case hostUnreachable = 0x04
        case connectionRefused = 0x05
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    struct Request: Equatable {
        let host: String
        let port: UInt16
        /// The client named a host, not an address.
        let isName: Bool
    }

    enum Parse<T: Equatable>: Equatable {
        case needMore
        case invalid
        case done(T, consumed: Int)
    }

    /// The greeting: whether the client offers username and password.
    static func parseGreeting(_ data: [UInt8]) -> Parse<Bool> {
        guard data.count >= 2 else { return .needMore }
        guard data[0] == 5 else { return .invalid }
        let count = Int(data[1])
        guard data.count >= 2 + count else { return .needMore }
        return .done(data[2..<(2 + count)].contains(0x02), consumed: 2 + count)
    }

    static func parseCredentials(_ data: [UInt8]) -> Parse<[String]> {
        guard data.count >= 2 else { return .needMore }
        guard data[0] == 1 else { return .invalid }
        let userLength = Int(data[1])
        guard data.count >= 2 + userLength + 1 else { return .needMore }
        let passwordLength = Int(data[2 + userLength])
        let end = 3 + userLength + passwordLength
        guard data.count >= end else { return .needMore }
        let user = String(decoding: data[2..<(2 + userLength)], as: UTF8.self)
        let password = String(decoding: data[(3 + userLength)..<end], as: UTF8.self)
        return .done([user, password], consumed: end)
    }

    /// A CONNECT request; anything else is `.invalid` (the caller replies
    /// "command not supported").
    static func parseRequest(_ data: [UInt8]) -> Parse<Request> {
        guard data.count >= 4 else { return .needMore }
        guard data[0] == 5, data[1] == 1, data[2] == 0 else { return .invalid }
        var cursor = 4
        let host: String
        let isName: Bool
        switch data[3] {
        case 1:
            guard data.count >= cursor + 4 + 2 else { return .needMore }
            host = data[cursor..<(cursor + 4)].map(String.init).joined(separator: ".")
            cursor += 4
            isName = false
        case 3:
            guard data.count >= cursor + 1 else { return .needMore }
            let length = Int(data[cursor])
            guard length > 0 else { return .invalid }
            guard data.count >= cursor + 1 + length + 2 else { return .needMore }
            host = String(decoding: data[(cursor + 1)..<(cursor + 1 + length)], as: UTF8.self).lowercased()
            cursor += 1 + length
            isName = true
        case 4:
            guard data.count >= cursor + 16 + 2 else { return .needMore }
            host = ShowURLPolicy.canonicalIPv6(Array(data[cursor..<(cursor + 16)]))
            cursor += 16
            isName = false
        default:
            return .invalid
        }
        let port = UInt16(data[cursor]) << 8 | UInt16(data[cursor + 1])
        return .done(Request(host: host, port: port, isName: isName), consumed: cursor + 2)
    }

    static func reply(_ code: Reply) -> Data { Data([5, code.rawValue, 0, 1, 0, 0, 0, 0, 0, 0]) }
}

/// One client connection: handshake, the destination decision, then bytes
/// both ways until either side ends.
private final class ShowGuardProxySession: @unchecked Sendable {
    private enum Stage { case greeting, credentials, request, resolving, connecting, splicing, closing, closed }

    private let client: NWConnection
    private weak var proxy: ShowGuardProxy?
    private let queue: DispatchQueue
    private var upstream: NWConnection?
    private var buffer: [UInt8] = []
    private var stage: Stage = .greeting
    private var openHalves = 2

    init(client: NWConnection, proxy: ShowGuardProxy, queue: DispatchQueue) {
        self.client = client
        self.proxy = proxy
        self.queue = queue
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + ShowGuardProxy.handshakeTimeout) { [weak self] in
            guard let self, self.stage != .splicing, self.stage != .closed else { return }
            self.close()
        }
        readHandshake()
    }

    private func readHandshake() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, self.stage != .closed else { return }
            if let data { self.buffer.append(contentsOf: data) }
            self.advance()
            if self.stage == .greeting || self.stage == .credentials || self.stage == .request {
                if complete || error != nil { self.close(); return }
                self.readHandshake()
            }
        }
    }

    private func advance() {
        while true {
            switch stage {
            case .greeting:
                switch ShowSOCKS.parseGreeting(buffer) {
                case .needMore: return
                case .invalid: close(); return
                case .done(let offersPassword, let consumed):
                    buffer.removeFirst(consumed)
                    guard offersPassword else { sendAndClose(Data([5, 0xFF])); return }
                    send(Data([5, 0x02]))
                    stage = .credentials
                }
            case .credentials:
                switch ShowSOCKS.parseCredentials(buffer) {
                case .needMore: return
                case .invalid: close(); return
                case .done(let pair, let consumed):
                    buffer.removeFirst(consumed)
                    guard let proxy, pair == [ShowGuardProxy.username, proxy.secret] else {
                        sendAndClose(Data([1, 1])); return
                    }
                    send(Data([1, 0]))
                    stage = .request
                }
            case .request:
                switch ShowSOCKS.parseRequest(buffer) {
                case .needMore: return
                case .invalid: sendAndClose(ShowSOCKS.reply(.commandNotSupported)); return
                case .done(let request, let consumed):
                    buffer.removeFirst(consumed)
                    stage = .resolving
                    decide(request)
                    return
                }
            default:
                return
            }
        }
    }

    /// Resolve once, check every answer, and dial only an address checked here.
    private func decide(_ request: ShowSOCKS.Request) {
        guard let proxy else { close(); return }
        let policy = proxy.policy
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let answers = request.isName ? policy.resolve(request.host) : [request.host]
            let verdict: (ShowGuardProxy.Outcome, String?)
            if let answers, let first = answers.first {
                verdict = answers.contains(where: policy.isForbidden)
                    ? (.refused(host: request.host), nil)
                    : (.connected(address: first), first)
            } else {
                verdict = (.unresolved(host: request.host), nil)
            }
            self?.queue.async { self?.act(on: verdict, port: request.port) }
        }
    }

    private func act(on verdict: (ShowGuardProxy.Outcome, String?), port: UInt16) {
        guard stage == .resolving else { return }
        guard let address = verdict.1, let nwPort = NWEndpoint.Port(rawValue: port) else {
            proxy?.report(verdict.0)
            if case .unresolved = verdict.0 { sendAndClose(ShowSOCKS.reply(.hostUnreachable)) } else { sendAndClose(ShowSOCKS.reply(.notAllowed)) }
            return
        }
        stage = .connecting
        let host = NWEndpoint.Host(address)
        let connection = NWConnection(host: host, port: nwPort, using: .tcp)
        upstream = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard self.stage == .connecting else { return }
                self.proxy?.report(verdict.0)
                self.stage = .splicing
                self.send(ShowSOCKS.reply(.succeeded))
                if !self.buffer.isEmpty {
                    let early = Data(self.buffer); self.buffer.removeAll()
                    connection.send(content: early, completion: .contentProcessed { _ in })
                }
                self.pump(from: self.client, to: connection)
                self.pump(from: connection, to: self.client)
            case .waiting, .failed:
                guard self.stage == .connecting else {
                    if case .failed = state { self.close() }
                    return
                }
                self.proxy?.report(.failed)
                self.upstream?.cancel()
                self.sendAndClose(ShowSOCKS.reply(.connectionRefused))
            case .cancelled:
                self.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.stage == .splicing else { return }
            let finish = complete || error != nil
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self else { return }
                    if sendError != nil { self.close(); return }
                    if finish { self.halfClose(sink) } else { self.pump(from: source, to: sink) }
                })
                return
            }
            if finish { self.halfClose(sink) } else { self.pump(from: source, to: sink) }
        }
    }

    private func halfClose(_ sink: NWConnection) {
        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        openHalves -= 1
        if openHalves <= 0 { close() }
    }

    private func send(_ data: Data) {
        client.send(content: data, completion: .contentProcessed { _ in })
    }

    /// A refusal: the reply reaches the client before the connection ends
    /// (`cancel` alone would drop it).
    private func sendAndClose(_ data: Data) {
        guard stage != .closed else { return }
        stage = .closing
        client.send(content: data, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { [weak self] _ in self?.queue.async { self?.close() } })
    }

    func close() {
        guard stage != .closed else { return }
        stage = .closed
        upstream?.cancel()
        client.cancel()
        proxy?.finished(self)
    }
}
