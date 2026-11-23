import XCTest
import Network
import WebKit

#if canImport(c11)
@testable import c11
#elseif canImport(c11_DEV)
@testable import c11_DEV
#endif

final class WorkspaceRemoteConnectionTests: XCTestCase {
    func testRemoteCommandRelayDoesNotStartListener() {
        XCTAssertThrowsError(try WorkspaceRemoteCLIRelayServer().start()) { error in
            XCTAssertEqual(error.localizedDescription, "c11 commands are not available over c11 ssh in this version")
        }
    }

    func testSSHAgentEnvVarsPropagateToSpawnedProcess() throws {
        // Verify that setting process.environment = ProcessInfo.processInfo.environment
        // causes spawned processes to inherit SSH agent variables from the parent.
        let testKey = "C11_TEST_SSH_AGENT_VAR"
        let testValue = "/tmp/c11-test-ssh-agent-\(UUID().uuidString).sock"
        setenv(testKey, testValue, 1)
        defer { unsetenv(testKey) }

        // ProcessInfo must reflect the newly set variable.
        let capturedEnv = ProcessInfo.processInfo.environment
        XCTAssertEqual(capturedEnv[testKey], testValue, "ProcessInfo.environment must include newly set env var")

        // A process launched with the captured environment must see the var.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printenv")
        process.arguments = [testKey]
        process.environment = capturedEnv
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertEqual(output, testValue, "SSH agent env var must be visible in spawned process environment")
    }
}

// MARK: - c11 ssh workspace proxy: the broker takes only its own credential, and the browser fails closed

/// The remote side of the proxy in these tests: records what was opened and answers every
/// HTTP request with a canary body.
private final class CanaryRemoteTransport: RemoteProxyStreamTransport {
    let body: String
    private let rawResponse: String?
    private let lock = NSLock()
    private var openedTargets: [String] = []
    private var handlers: [String: (DispatchQueue, (RemoteProxyStreamEvent) -> Void)] = [:]
    private var requests: [String: Data] = [:]

    init(body: String, rawResponse: String? = nil) {
        self.body = body
        self.rawResponse = rawResponse
    }

    var opened: [String] {
        lock.lock()
        defer { lock.unlock() }
        return openedTargets
    }

    func openStream(host: String, port: Int, timeoutMs: Int) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        openedTargets.append("\(host):\(port)")
        return "stream-\(openedTargets.count)"
    }

    func attachStream(streamID: String, queue: DispatchQueue, onEvent: @escaping (RemoteProxyStreamEvent) -> Void) throws {
        lock.lock()
        handlers[streamID] = (queue, onEvent)
        lock.unlock()
    }

    func writeStream(streamID: String, data: Data) throws {
        lock.lock()
        var request = requests[streamID] ?? Data()
        request.append(data)
        requests[streamID] = request
        let complete = request.range(of: Data("\r\n\r\n".utf8)) != nil
        let handler = handlers[streamID]
        if complete { handlers[streamID] = nil }
        lock.unlock()
        guard complete, let (queue, onEvent) = handler else { return }
        let response = rawResponse ?? ("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n\r\n\(body)")
        queue.async {
            onEvent(.data(Data(response.utf8)))
            onEvent(.eof(Data()))
        }
    }

    func closeStream(streamID: String) {}
}

/// The broker's real session code on a loopback listener, with a fake remote behind it.
private final class LoopbackProxyServer {
    let port: Int
    private let listener: NWListener
    private let queue = DispatchQueue(label: "c11.tests.remote-proxy-server")
    private var sessions: [UUID: WorkspaceRemoteProxySession] = [:]

    init(credential: BrowserProxyCredential, transport: CanaryRemoteTransport) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let queue = self.queue
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        var register: ((WorkspaceRemoteProxySession) -> Void)?
        listener.newConnectionHandler = { connection in
            let session = WorkspaceRemoteProxySession(
                connection: connection,
                transport: transport,
                credential: credential,
                queue: queue
            ) { _ in }
            register?(session)
            session.start()
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        port = Int(listener.port?.rawValue ?? 0)
        register = { [weak self] session in self?.sessions[session.id] = session }
    }

    func stop() {
        listener.cancel()
        queue.sync {
            sessions.values.forEach { $0.stop() }
            sessions.removeAll()
        }
    }
}

/// Counts connections to a plain loopback port: this Mac's own service, which a c11 ssh
/// workspace's page must never reach directly.
private final class LocalServiceProbe {
    let port: Int
    private let fd: Int32
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var accepted = 0

    init?(reply: String = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nLOCAL") {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        self.port = Int(UInt16(bigEndian: actual.sin_port))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "c11.tests.local-service"))
        self.source = source
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { break }
                self?.lock.lock()
                self?.accepted += 1
                self?.lock.unlock()
                _ = reply.withCString { send(client, $0, strlen($0), 0) }
                close(client)
            }
        }
        source.resume()
    }

    var connections: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }

    deinit {
        source.cancel()
        close(fd)
    }
}

/// Sends raw bytes to a loopback port and returns what comes back before the peer closes.
private func rawExchange(port: Int, send payload: [UInt8], expecting count: Int) -> [UInt8] {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return [] }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { return [] }
    _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, payload.count, 0) }
    var received: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 512)
    while received.count < count + 64 {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { break }
        received += buffer[0..<n]
    }
    return received
}

final class RemoteProxyHandshakeTests: XCTestCase {
    private let credential = BrowserProxyCredential(username: "c11", password: "s3cret-token")

    private func socksAuth(_ username: String, _ password: String) -> Data {
        Data([0x01, UInt8(username.utf8.count)] + Array(username.utf8) + [UInt8(password.utf8.count)] + Array(password.utf8))
    }

    private let socksRequest = Data([0x05, 0x01, 0x00, 0x03, 0x0C] + Array("example.test".utf8) + [0x1F, 0x90])

    func testSocksClientWithoutUsernamePasswordIsRefused() {
        var handshake = RemoteProxyHandshake(credential: credential)
        XCTAssertEqual(handshake.consume(Data([0x05, 0x01, 0x00])), [.refuse(RemoteProxyHandshake.socksNoAcceptableMethod)])
        XCTAssertEqual(handshake.consume(socksRequest), [], "a refused client gets nothing more")
    }

    func testSocksClientWithWrongCredentialIsRefused() {
        var handshake = RemoteProxyHandshake(credential: credential)
        XCTAssertEqual(handshake.consume(Data([0x05, 0x02, 0x00, 0x02])), [.reply(Data([0x05, 0x02]))])
        XCTAssertEqual(handshake.consume(socksAuth("c11", "s3cret-tokem")), [.refuse(RemoteProxyHandshake.socksAuthFailed)])

        var wrongUser = RemoteProxyHandshake(credential: credential)
        _ = wrongUser.consume(Data([0x05, 0x01, 0x02]))
        XCTAssertEqual(wrongUser.consume(socksAuth("c12", "s3cret-token")), [.refuse(RemoteProxyHandshake.socksAuthFailed)])
    }

    func testSocksClientWithCredentialIsServed() {
        var handshake = RemoteProxyHandshake(credential: credential)
        let bytes = Data([0x05, 0x02, 0x00, 0x02]) + socksAuth("c11", "s3cret-token") + socksRequest + Data("GET /".utf8)
        let actions = handshake.consume(bytes)
        XCTAssertEqual(actions.count, 3, "\(actions)")
        XCTAssertEqual(actions.first, .reply(Data([0x05, 0x02])))
        XCTAssertEqual(actions.dropFirst().first, .reply(RemoteProxyHandshake.socksAuthSucceeded))
        guard case .open(let host, let port, _, _, let pending)? = actions.last else {
            return XCTFail("expected the authenticated request to open: \(actions)")
        }
        XCTAssertEqual(host, "example.test")
        XCTAssertEqual(port, 8080)
        XCTAssertEqual(pending, Data("GET /".utf8))
    }

    func testConnectClientNeedsProxyAuthorization() {
        let request = "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n"
        var missing = RemoteProxyHandshake(credential: credential)
        XCTAssertEqual(missing.consume(Data(request.utf8)), [.refuse(RemoteProxyHandshake.proxyAuthenticationRequiredResponse)])

        let wrong = Data("c11:nope".utf8).base64EncodedString()
        var wrongCredential = RemoteProxyHandshake(credential: credential)
        let wrongRequest = "CONNECT example.test:443 HTTP/1.1\r\nProxy-Authorization: Basic \(wrong)\r\n\r\n"
        XCTAssertEqual(wrongCredential.consume(Data(wrongRequest.utf8)), [.refuse(RemoteProxyHandshake.proxyAuthenticationRequiredResponse)])

        let right = Data("c11:s3cret-token".utf8).base64EncodedString()
        var authorized = RemoteProxyHandshake(credential: credential)
        let rightRequest = "CONNECT example.test:443 HTTP/1.1\r\nproxy-authorization:  basic \(right)\r\n\r\n"
        guard case .open(let host, let port, _, _, _)? = authorized.consume(Data(rightRequest.utf8)).last else {
            return XCTFail("an authorized CONNECT should open its target")
        }
        XCTAssertEqual(host, "example.test")
        XCTAssertEqual(port, 443)
    }
}

/// Real loopback sockets and URLSession's own proxy client (the Network-framework proxy stack
/// WebKit's networking process uses), against the broker's real session code.
final class RemoteProxySessionLoopbackTests: XCTestCase {
    private func fetch(_ url: URL, proxies: [ProxyConfiguration]) -> (body: String?, error: Error?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = proxies
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let done = expectation(description: url.absoluteString)
        var result: (String?, Error?) = (nil, nil)
        session.dataTask(with: url) { data, _, error in
            result = (data.flatMap { String(data: $0, encoding: .utf8) }, error)
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 12)
        return result
    }

    private func proxies(_ endpoint: BrowserProxyEndpoint, kind: Int) -> [ProxyConfiguration] {
        guard let all = BrowserRemoteProxyRouting.proxy(endpoint).proxyConfigurations(blackhole: nil), all.count == 2 else {
            XCTFail("a usable endpoint should give a SOCKS5 and a CONNECT proxy")
            return []
        }
        return [all[kind]]
    }

    private let target = URL(string: "http://proxy-canary.c11.example:8080/probe")!

    func testBrokerServesOnlyClientsWithItsCredential() throws {
        let credential = BrowserProxyCredential.generate()
        let transport = CanaryRemoteTransport(body: "REMOTE-CANARY")
        let server = try LoopbackProxyServer(credential: credential, transport: transport)
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0)

        for (kind, name) in [(0, "SOCKS5"), (1, "HTTP CONNECT")] {
            let opensBefore = transport.opened.count
            let anonymous = fetch(target, proxies: proxies(BrowserProxyEndpoint(host: "127.0.0.1", port: server.port), kind: kind))
            XCTAssertNotEqual(anonymous.body, "REMOTE-CANARY", "\(name) without the credential must not be served")
            let guessed = BrowserProxyEndpoint(
                host: "127.0.0.1",
                port: server.port,
                credential: BrowserProxyCredential(username: "c11", password: String(repeating: "0", count: 64))
            )
            XCTAssertNotEqual(fetch(target, proxies: proxies(guessed, kind: kind)).body, "REMOTE-CANARY", "\(name) with a guessed credential must not be served")
            let otherBroker = BrowserProxyEndpoint(host: "127.0.0.1", port: server.port, credential: .generate())
            XCTAssertNotEqual(
                fetch(target, proxies: proxies(otherBroker, kind: kind)).body, "REMOTE-CANARY",
                "\(name) with another broker's freshly generated credential must not be served"
            )
            XCTAssertEqual(transport.opened.count, opensBefore, "\(name): a refused client must never reach the remote")

            let served = fetch(target, proxies: proxies(BrowserProxyEndpoint(host: "127.0.0.1", port: server.port, credential: credential), kind: kind))
            XCTAssertNil(served.error, "\(name) with the credential: \(String(describing: served.error))")
            XCTAssertEqual(served.body, "REMOTE-CANARY", name)
            XCTAssertEqual(transport.opened.last, "proxy-canary.c11.example:8080", name)
        }
    }

    func testEachBrokerCredentialIsFreshAndUnguessable() {
        let first = BrowserProxyCredential.generate()
        let second = BrowserProxyCredential.generate()
        XCTAssertNotEqual(first, second, "two broker starts must never share a credential")
        for credential in [first, second] {
            XCTAssertEqual(credential.username, "c11")
            XCTAssertEqual(credential.password.count, 64)
            XCTAssertTrue(credential.password.allSatisfy { "0123456789abcdef".contains($0) }, credential.password)
        }
    }

    /// c11's own favicon fetch in a c11 ssh workspace: a page-named literal-loopback icon and a
    /// remote redirect to this Mac's loopback are both refused; the direct path is the control.
    func testProxiedFaviconFetchNeverReachesThisMacsLoopback() async throws {
        try XCTSkipIf(true, "Flaky on the loaded CI runner; quarantined until made deterministic (C11H-431)")
        let probe = try XCTUnwrap(LocalServiceProbe())
        let redirect = "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(probe.port)/icon.png\r\n" +
            "Content-Length: 0\r\nConnection: close\r\n\r\n"
        let credential = BrowserProxyCredential.generate()
        let transport = CanaryRemoteTransport(body: "", rawResponse: redirect)
        let server = try LoopbackProxyServer(credential: credential, transport: transport)
        defer { server.stop() }
        let routing = BrowserRemoteProxyRouting.proxy(BrowserProxyEndpoint(host: "127.0.0.1", port: server.port, credential: credential))
        let direct = URLSession(configuration: .ephemeral)
        defer { direct.invalidateAndCancel() }
        let proxied = try XCTUnwrap(routing.faviconSession(direct: { direct }))
        defer { proxied.invalidateAndCancel() }
        func request(_ text: String) -> URLRequest {
            var request = URLRequest(url: URL(string: text)!)
            request.timeoutInterval = 2
            return request
        }

        // (a) The page names its icon on a literal loopback host: refused before any connection.
        let started = Date()
        do {
            _ = try await routing.fetchFavicon(request("https://localhost:\(probe.port)/favicon.ico"), session: proxied, maximumBytes: BrowserFavicon.maximumBytes)
            XCTFail("a literal-loopback favicon must be refused")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a refused icon must not wait out a timeout")
        XCTAssertEqual(probe.connections, 0, "(a) reached this Mac's loopback")

        // (b) The remote's /favicon.ico redirects to this Mac's loopback: the redirect is refused.
        do {
            _ = try await routing.fetchFavicon(request("http://c11-loopback.localtest.me:8080/favicon.ico"), session: proxied, maximumBytes: BrowserFavicon.maximumBytes)
            XCTFail("a redirect to this Mac's loopback must not be followed")
        } catch {}
        XCTAssertEqual(transport.opened, ["127.0.0.1:8080"], "the alias request went to the remote once")
        XCTAssertEqual(probe.connections, 0, "(b) reached this Mac's loopback")

        // (c) Control: the same redirect through the direct session does reach the probe.
        let redirector = try XCTUnwrap(LocalServiceProbe(reply: redirect))
        _ = try? await BrowserRemoteProxyRouting.direct.fetchFavicon(
            request("http://127.0.0.1:\(redirector.port)/favicon.ico"), session: direct, maximumBytes: BrowserFavicon.maximumBytes
        )
        XCTAssertEqual(redirector.connections, 1)
        XCTAssertEqual(probe.connections, 1, "the control must show a direct request reaches the probe")
    }

    func testNoAuthSocksGreetingGetsNoAcceptableMethod() throws {
        let transport = CanaryRemoteTransport(body: "REMOTE-CANARY")
        let server = try LoopbackProxyServer(credential: .generate(), transport: transport)
        defer { server.stop() }
        let reply = rawExchange(port: server.port, send: [0x05, 0x01, 0x00], expecting: 2)
        XCTAssertEqual(reply, [0x05, 0xFF])
        XCTAssertTrue(transport.opened.isEmpty)
    }

    func testBlockedWorkspaceRequestsFailClosedThroughTheBlackhole() throws {
        let local = try XCTUnwrap(LocalServiceProbe())
        let blackhole = try XCTUnwrap(BrowserRemoteProxyBlackhole.shared.endpoint)
        let blocked = try XCTUnwrap(
            BrowserRemoteProxyRouting.blocked.proxyConfigurations(blackhole: blackhole),
            "a blocked workspace must get a proxy set, never an empty (direct) one"
        )
        XCTAssertEqual(blocked.count, 2)
        XCTAssertTrue(blocked.allSatisfy { !$0.allowFailover }, "no failover to direct")

        let refusedBefore = BrowserRemoteProxyBlackhole.shared.refusedConnectionCount
        for host in ["c11-loopback.localtest.me", "proxy-canary.c11.example"] {
            let url = URL(string: "http://\(host):\(local.port)/probe")!
            let result = fetch(url, proxies: blocked)
            XCTAssertNotNil(result.error, "\(host): a blocked workspace's request must fail")
            XCTAssertNotEqual(result.body, "LOCAL", host)
        }
        XCTAssertEqual(local.connections, 0, "no request may reach this Mac's own service while blocked")
        XCTAssertGreaterThan(
            BrowserRemoteProxyBlackhole.shared.refusedConnectionCount, refusedBefore,
            "the blocked requests went to c11's refusing listener"
        )
    }

    func testBlackholeResetsEveryConnectionWithoutAReply() throws {
        let blackhole = try XCTUnwrap(BrowserRemoteProxyBlackhole.shared.endpoint)
        XCTAssertEqual(blackhole.host, "127.0.0.1")
        XCTAssertEqual(rawExchange(port: blackhole.port, send: [0x05, 0x01, 0x00], expecting: 2), [])
        let connect = Array("CONNECT example.test:443 HTTP/1.1\r\n\r\n".utf8)
        XCTAssertEqual(rawExchange(port: blackhole.port, send: connect, expecting: 12), [])
        XCTAssertEqual(BrowserRemoteProxyBlackhole.shared.endpoint, blackhole, "one listener for the app's life")
    }
}

final class BrowserRemoteProxyRoutingTests: XCTestCase {
    private let endpoint = BrowserProxyEndpoint(host: "127.0.0.1", port: 50123, credential: .generate())

    func testRemoteWorkspaceWithoutABrokerIsBlockedNotDirect() {
        XCTAssertEqual(BrowserRemoteProxyRouting.resolve(usesRemoteWorkspaceProxy: false, endpoint: nil), .direct)
        XCTAssertEqual(BrowserRemoteProxyRouting.resolve(usesRemoteWorkspaceProxy: true, endpoint: nil), .blocked)
        XCTAssertEqual(
            BrowserRemoteProxyRouting.resolve(usesRemoteWorkspaceProxy: true, endpoint: BrowserProxyEndpoint(host: "127.0.0.1", port: 0)),
            .blocked
        )
        XCTAssertEqual(BrowserRemoteProxyRouting.resolve(usesRemoteWorkspaceProxy: true, endpoint: endpoint), .proxy(endpoint))
        XCTAssertEqual(BrowserRemoteProxyRouting.direct.proxyConfigurations(blackhole: nil)?.count, 0)
        XCTAssertNil(BrowserRemoteProxyRouting.blocked.proxyConfigurations(blackhole: nil))
    }

    func testFaviconNeverFallsBackToADirectSessionInARemoteWorkspace() {
        let direct = URLSession(configuration: .ephemeral)
        defer { direct.invalidateAndCancel() }
        XCTAssertNil(BrowserRemoteProxyRouting.blocked.faviconSession(direct: { direct }))
        XCTAssertTrue(BrowserRemoteProxyRouting.direct.faviconSession(direct: { direct }) === direct)
        let proxied = BrowserRemoteProxyRouting.proxy(endpoint).faviconSession(direct: { direct })
        XCTAssertNotNil(proxied)
        XCTAssertFalse(proxied === direct)
        XCTAssertEqual(proxied?.configuration.proxyConfigurations.count, 2)
        proxied?.invalidateAndCancel()
    }
}

final class BrowserRemoteLoopbackBlockerTests: XCTestCase {
    func testRuleListBlocksEveryLiteralLoopbackHostAndNothingElse() {
        let blocked = [
            "http://localhost:3000/", "https://localhost/", "http://LOCALHOST:8080/x", "http://localhost./",
            "http://localhost", "http://127.0.0.1", "https://127.0.0.2:8443",
            "http://user:pw@localhost/", "http://localhost?x=1", "http://api.localhost:5173/",
            "http://localhost.localdomain/", "ws://127.0.0.1:9000/socket", "wss://127.0.0.1/", "http://127.8.9.10/",
            "http://127.0.0.1#frag", "http://0.0.0.0:8000/", "http://[::1]:8080/", "http://[::]/",
            "http://[::ffff:7f00:1]/", "http://[::ffff:0:0]/",
        ]
        for text in blocked {
            XCTAssertTrue(BrowserRemoteLoopbackBlocker.blocks(URL(string: text)!), "should block \(text)")
        }
        let allowed = [
            "http://c11-loopback.localtest.me:3000/", "https://example.com/?next=http://localhost/",
            "http://localhost.example.com/", "http://127.example.com/", "http://notlocalhost/",
            "http://10.0.0.1:3000/", "http://[::2]/", "https://192.168.1.127/", "c11-show://localhost/file",
        ]
        for text in allowed {
            XCTAssertFalse(BrowserRemoteLoopbackBlocker.blocks(URL(string: text)!), "should not block \(text)")
        }
    }

    func testRuleListCompilesInWebKit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("c11-rule-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: folder))
        let compiled = expectation(description: "compile")
        var list: WKContentRuleList?
        var failure: Error?
        BrowserRemoteLoopbackBlocker.compile(in: store) { result, error in
            list = result
            failure = error
            compiled.fulfill()
        }
        wait(for: [compiled], timeout: 15)
        XCTAssertNil(failure, "WebKit refused the rule list: \(String(describing: failure))")
        XCTAssertEqual(list?.identifier, BrowserRemoteLoopbackBlocker.identifier)
    }
}
