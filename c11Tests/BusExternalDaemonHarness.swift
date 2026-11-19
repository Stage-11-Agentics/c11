import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// C11H-72: #151's conformance suite, through the bus adapter, against EXTERNAL
// daemons: the CBUS-21 mock, the CBUS-20 dev constellation, or the Nov 3 real
// daemons. Pointing it at one is a configuration change, never code.
//
// Configuration: a JSON file named ONLY by the environment variable
// `C11_BUS_EXTERNAL`, which its own runner sets for its run (through
// `xcodebuild`'s `TEST_RUNNER_C11_BUS_EXTERNAL`). There is no shared default
// path: a test run never picks up another run's configuration (the 03:10 PST
// collision). Without it, the class skips.
//
//     {
//       "hosts": {                             // the suite's host names
//         "studio":  {"socket": "/…/studio/cbus.sock",  "control": "/…/studio/cbus-test.sock", "name": "alpha"},
//         "laptop": {"socket": "/…/laptop/cbus.sock", "control": "/…/laptop/cbus-test.sock"},
//         "prime":  {"socket": "/…/prime/cbus.sock",  "control": "/…/prime/cbus-test.sock"}
//       },
//       "app_host": "laptop",                  // T6A's forwarder, the certificate-eligible host
//       "daemon_deadline_s": 1.8,              // CBUS-19 rule 6.7; the harness's sendDeadline
//       "adapter_deadline_s": 2.0,             // A6's 2 s
//       "sealed": false,                       // true: wrap in #151's sealed harness
//       "lease": "<token>",                    // see below
//       "shared_world": false                  // true: the control sockets are ONE world (one mock
//                                              // process), so additive controls go to one daemon
//     }
//
// The section 11 controls are daemon-wide, so the harness runs only against
// daemons dedicated to the test: before any connection, every socket's folder
// must hold `c11-conformance.lease` containing the configuration's `lease`
// token (written by whoever starts those test daemons), and no socket may sit
// in the default CBUS_HOME. Otherwise the run fails with nothing sent.
//
// `name` is the host name the daemon serves, when it differs from the suite's.
// Every harness hook is one CBUS-19 section 11 operation on the test-control
// socket, sent to every daemon. Each test gets a fresh session id (rule 4.2:
// sessions never see each other's traffic), and the knobs are reset at start.
// When its runner sets `C11_BUS_WIRE_DIR`, the adapter's own wire (both ways)
// is captured there for the CBUS-19 checker gate.

struct BusExternalConfiguration: Decodable {
    struct Host: Decodable {
        let socket: String
        let control: String
        let name: String?
    }

    let hosts: [String: Host]
    let appHost: String
    let daemonDeadline: TimeInterval
    let adapterDeadline: TimeInterval
    let sealed: Bool
    let lease: String?
    /// The configured control sockets reach one world (a single mock process),
    /// so a control that adds rather than sets (`advance_clock`) goes to one.
    let sharedWorld: Bool

    enum CodingKeys: String, CodingKey {
        case hosts, sealed, lease
        case sharedWorld = "shared_world"
        case appHost = "app_host"
        case daemonDeadline = "daemon_deadline_s"
        case adapterDeadline = "adapter_deadline_s"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try container.decode([String: Host].self, forKey: .hosts)
        appHost = try container.decodeIfPresent(String.self, forKey: .appHost) ?? "laptop"
        daemonDeadline = try container.decodeIfPresent(TimeInterval.self, forKey: .daemonDeadline) ?? 1.8
        adapterDeadline = try container.decodeIfPresent(TimeInterval.self, forKey: .adapterDeadline) ?? 2.0
        sealed = try container.decodeIfPresent(Bool.self, forKey: .sealed) ?? false
        lease = try container.decodeIfPresent(String.self, forKey: .lease)
        sharedWorld = try container.decodeIfPresent(Bool.self, forKey: .sharedWorld) ?? false
    }

    static let leaseFile = "c11-conformance.lease"

    enum Refusal: Error, Equatable { case noLease(String), defaultHome(String) }

    /// sol #152 finding 3: the harness touches only daemons leased to the test.
    func checkLease(home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        guard let token = lease?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw Refusal.noLease("the configuration has no lease")
        }
        let defaults = ["\(home)/Library/Application Support/cbus", "\(home)/.local/share/cbus"]
        for host in hosts.values {
            for path in [host.socket, host.control] {
                let folder = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
                if defaults.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) {
                    throw Refusal.defaultHome(path)
                }
                let file = URL(fileURLWithPath: folder).appendingPathComponent(Self.leaseFile)
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      text.trimmingCharacters(in: .whitespacesAndNewlines) == token else {
                    throw Refusal.noLease(folder)
                }
            }
        }
    }

    static func load() -> BusExternalConfiguration? {
        guard let path = ProcessInfo.processInfo.environment["C11_BUS_EXTERNAL"], !path.isEmpty,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(BusExternalConfiguration.self, from: data)
    }
}

/// Appends the adapter's wire to `<C11_BUS_WIRE_DIR>/<uuid>.ndjson` in
/// CBUS-19's checker format, only when the runner set that folder for its run.
final class BusWireCapture: @unchecked Sendable {
    private let handle: FileHandle?
    private let lock = NSLock()

    /// The run's capture folder, from its own runner; nil means no capture.
    static var folder: URL? {
        guard let path = ProcessInfo.processInfo.environment["C11_BUS_WIRE_DIR"], !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func newFile() -> FileHandle? {
        guard let folder else { return nil }
        let file = folder.appendingPathComponent("\(UUID().uuidString).ndjson")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        return try? FileHandle(forWritingTo: file)
    }

    init() { handle = Self.newFile() }

    var tap: CbusWireTap? {
        guard handle != nil else { return nil }
        return { [weak self] direction, connection, line in self?.record(direction, connection, line) }
    }

    private func record(_ direction: String, _ connection: String, _ line: Data) {
        var entry = Data("# @\(connection)\n\(direction) ".utf8)
        entry.append(line)
        entry.append(0x0A)
        lock.lock()
        handle?.write(entry)
        lock.unlock()
    }
}

final class BusExternalHarness: HostTransportHarness {
    let configuration: BusExternalConfiguration
    let session = "t" + String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20))
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("c11-bus-external-\(UUID().uuidString)", isDirectory: true)
    let capture = BusWireCapture()
    private var nextId = 0
    private let lock = NSLock()
    private var greeted: [BusHostTransport] = []
    /// What each host had quarantined before this harness started: a daemon's
    /// quarantine outlives a test (or a whole pass on the same mock), and a test
    /// must see only its own (mock run, finding C).
    private var quarantineBaseline: [String: Set<String>] = [:]

    enum Failure: Error, Equatable { case unbound([String]), appHostNotGranted(String) }

    /// Checks the lease before touching anything, then resets the knobs and
    /// greets every configured host in this harness's fresh session.
    static func make(_ configuration: BusExternalConfiguration,
                     beforeAppHostDecision: (BusExternalHarness) -> Void = { _ in }) throws -> BusExternalHarness {
        try configuration.checkLease()
        let harness = BusExternalHarness(configuration)
        let missing = harness.bindAll()
        if !missing.isEmpty { throw Failure.unbound(missing) }
        beforeAppHostDecision(harness)
        let registration = harness.ensureAppHostGranted()
        if registration != "granted" { throw Failure.appHostNotGranted(registration ?? "no answer") }
        for host in configuration.hosts.keys {
            harness.quarantineBaseline[host] = Set(harness.daemonQuarantine(host).map(\.id))
        }
        return harness
    }

    /// CBUS-23 rule 4.6 (C3): T6A's forwarder must be the session's GRANTED app
    /// host, or receivers discard its forwarded origins. The harness reads the
    /// registration from `hello`; a provisional one is decided with section 11's
    /// `set_app_host_registration` (a mock has no authority), and the harness
    /// waits for the `app_host` frame. Anything but `granted` fails the run.
    private func ensureAppHostGranted() -> String? {
        let app = configuration.appHost
        guard let transport = greeted.first(where: { $0.host == daemonName(app) }) else { return nil }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let control = { [self] in self.control(app, "set_app_host_registration",
                                                   ["host": daemonName(app), "registration": "granted"]) }
        Task.detached {
            var state = await transport.appHostRegistration()
            if state == "provisional" {
                _ = control()
                state = await transport.awaitAppHostDecision(timeout: 5)
            }
            box.set(["state": state ?? NSNull()])
            done.signal()
        }
        done.wait()
        return box.value?["state"] as? String
    }

    /// CBUS-19 rules 4.2 and 4.3: only `hello` binds `c11/<session>/<host>`,
    /// and a `send` to an unbound host is `host_unknown` (rule 6.2 row 8). The
    /// suite's first send must find every endpoint bound, so all say `hello`
    /// now and stay connected.
    private func bindAll() -> [String] {
        greeted = configuration.hosts.keys.sorted().map { bindingTransport($0) }
        return BusBinding.bind(greeted)
    }

    private init(_ configuration: BusExternalConfiguration) {
        self.configuration = configuration
        // Start from known knobs: whatever an earlier run left set is cleared.
        for host in configuration.hosts.keys.sorted() {
            controlAll("set_silent", ["host": daemonName(host), "silent": false])
            controlAll("set_away", ["host": daemonName(host), "away": false])
        }
        controlAll("set_tamper", [:])
        controlAll("set_receiver_refusal", ["code": NSNull()])
        controlAll("hold_max_envelopes", ["n": HostTransportBounds.maximumHeldEnvelopes])
    }

    deinit {
        BusStateSeqStore.forget(under: root)
        try? FileManager.default.removeItem(at: root)
    }

    func daemonName(_ host: String) -> String { configuration.hosts[host]?.name ?? host }

    // MARK: Section 11 control operations

    /// One operation on one daemon's control socket; its `result`, or nil.
    @discardableResult
    func control(_ host: String, _ method: String, _ params: [String: Any]) -> [String: Any]? {
        guard let path = configuration.hosts[host]?.control, let socket = CbusLineSocket.connect(path: path) else { return nil }
        let id: Int = lock.withLock {
            nextId += 1
            return nextId
        }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        socket.start(onFrame: { line in
            if (line["id"] as? String) == String(id) { box.set(line); done.signal() }
        }, onClose: { done.signal() })
        guard let data = CbusWire.encodeLine(["id": String(id), "method": method, "params": params]),
              socket.write(data, deadline: Date().addingTimeInterval(5)) else { socket.close(); return nil }
        _ = done.wait(timeout: .now() + 10)
        socket.close()
        return box.value?["result"] as? [String: Any]
    }

    /// Section 11: the harness sends each operation to every daemon in the test.
    @discardableResult
    func controlAll(_ method: String, _ params: [String: Any]) -> [[String: Any]] {
        configuration.hosts.keys.sorted().compactMap { control($0, method, params) }
    }

    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: Any]?
        func set(_ value: [String: Any]) { lock.withLock { stored = value } }
        var value: [String: Any]? { lock.withLock { stored } }
    }

    /// #151's tamper is a closure until C11H-119 makes it declarative; it is
    /// read here by applying it to fixed bytes, as section 11's `set_tamper`
    /// (reverse the body, then append, then XOR every topic byte).
    static func declarativeTamper(_ tamper: @Sendable (inout Data, inout Data?) -> Void) -> [String: Any] {
        let probe = Data([0x01, 0x02, 0x03])
        var body = probe, topic: Data? = Data([0x00])
        tamper(&body, &topic)
        var params: [String: Any] = [:]
        var rest = body
        if body.starts(with: probe.reversed()) {
            params["body_reverse"] = true
            rest = body.dropFirst(probe.count)
        } else if body.starts(with: probe) {
            rest = body.dropFirst(probe.count)
        }
        if !rest.isEmpty { params["body_append"] = Data(rest).base64EncodedString() }
        if let xor = topic?.first, xor != 0 { params["topic_xor"] = Int(xor) }
        return params
    }

    // MARK: HostTransportHarness

    private func bindingTransport(_ host: String) -> BusHostTransport {
        let lines = BusExternalLog.shared
        return BusHostTransport(host: daemonName(host), configuration: BusHostTransportConfiguration(
            socketPath: configuration.hosts[host]?.socket ?? "/nonexistent",
            stateDirectory: root.appendingPathComponent(host).appendingPathComponent("transport/bus", isDirectory: true),
            session: session, appHost: host == configuration.appHost, sendDeadline: configuration.adapterDeadline,
            peerPolicy: BusPeerPolicy { _ in true }, client: "c11-conformance",
            log: { lines.append($0) }, wireTap: capture.tap))
    }

    func endpoint(_ host: String) -> any HostTransport {
        BusRenamedTransport(bindingTransport(host), suiteName: host, rename: daemonName, unname: suiteName)
    }

    func suiteName(_ daemon: String) -> String {
        configuration.hosts.first { ($0.value.name ?? $0.key) == daemon }?.key ?? daemon
    }

    func setAway(_ host: String, _ away: Bool) { controlAll("set_away", ["host": daemonName(host), "away": away]) }
    func setSilent(_ host: String, _ silent: Bool) { controlAll("set_silent", ["host": daemonName(host), "silent": silent]) }
    func releaseLateAccepts() -> Int {
        controlAll("release_late_accepts", [:]).reduce(0) { $0 + (($1["released"] as? NSNumber)?.intValue ?? 0) }
    }
    func quarantined(by host: String) -> [(id: String, code: HostTransportRefusal)] {
        let before = quarantineBaseline[host] ?? []
        return daemonQuarantine(host).filter { !before.contains($0.id) }
    }

    private func daemonQuarantine(_ host: String) -> [(id: String, code: HostTransportRefusal)] {
        let list = control(host, "quarantined", ["host": daemonName(host)])?["quarantined"] as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let id = entry["id"] as? String, let code = entry["code"] as? String else { return nil }
            return (id, HostTransportRefusal(rawValue: code))
        }
    }
    func isAcknowledged(_ id: String, by host: String) -> Bool {
        (control(host, "is_acknowledged", ["id": id, "host": daemonName(host)])?["acknowledged"] as? Bool) ?? false
    }
    /// Section 11 sends each operation to every daemon; a clock advance is
    /// additive, so one world (a single mock process) gets it once (mock run, finding A).
    func advanceClock(by seconds: TimeInterval) {
        let params: [String: Any] = ["ms": max(1, Int(seconds * 1000))]
        if configuration.sharedWorld, let first = configuration.hosts.keys.sorted().first {
            control(first, "advance_clock", params)
        } else {
            controlAll("advance_clock", params)
        }
    }
    func reconnect(_ a: String, _ b: String) { controlAll("reconnect", ["a": daemonName(a), "b": daemonName(b)]) }
    func restart(_ host: String) {
        controlAll("restart", ["host": daemonName(host)])
        BusStateSeqStore.forget(under: root.appendingPathComponent(host))
    }
    func setTamper(_ tamper: (@Sendable (inout Data, inout Data?) -> Void)?) {
        controlAll("set_tamper", tamper.map(Self.declarativeTamper) ?? [:])
    }
    func setReceiverRefusal(_ refusal: HostTransportRefusal?) {
        controlAll("set_receiver_refusal", ["code": refusal?.rawValue ?? NSNull()])
    }
    func setHoldLimit(_ limit: Int) { controlAll("hold_max_envelopes", ["n": limit]) }
    var sendDeadline: TimeInterval { configuration.daemonDeadline }
    var timeoutDelivery: HostTransportDelivery { .unknown }
    var stampsRelay: Bool { false }
}

/// The adapter's log lines for an external run (ids and sizes only).
final class BusExternalLog: @unchecked Sendable {
    static let shared = BusExternalLog()
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
}

/// The suite's host names on the outside, the daemons' names on the inside,
/// for a mock that serves fixed names (`alpha`, `bravo`, `carol`).
final class BusRenamedTransport: HostTransport, @unchecked Sendable {
    private let base: BusHostTransport
    private let suiteName: String
    private let rename: (String) -> String
    private let unname: (String) -> String

    init(_ base: BusHostTransport, suiteName: String, rename: @escaping (String) -> String,
         unname: @escaping (String) -> String) {
        self.base = base
        self.suiteName = suiteName
        self.rename = rename
        self.unname = unname
    }

    var host: String { suiteName }
    func send(_ envelope: HostEnvelope, to host: String) async -> HostTransportResult {
        await base.send(outward(envelope), to: rename(host))
    }
    func hold(_ envelope: HostEnvelope, for host: String) async -> HostTransportResult {
        await base.hold(outward(envelope), for: rename(host))
    }
    func receive(from host: String) -> any HostTransportInbox {
        BusRenamedInbox(base.receive(from: rename(host)), unname: unname)
    }

    /// A forwarded envelope's carried origin, in the daemons' names.
    private func outward(_ envelope: HostEnvelope) -> HostEnvelope {
        var copy = envelope
        copy.stamps = envelope.stamps.mapValues(rename)
        return copy
    }
}

final class BusRenamedInbox: HostTransportInbox, @unchecked Sendable {
    private let base: any HostTransportInbox
    private let unname: (String) -> String

    init(_ base: any HostTransportInbox, unname: @escaping (String) -> String) {
        self.base = base
        self.unname = unname
    }

    func next(timeout: TimeInterval) async -> HostTransportIncoming? {
        guard let incoming = await base.next(timeout: timeout) else { return nil }
        guard case .envelope(var envelope) = incoming else { return incoming }
        envelope.stamps = envelope.stamps.mapValues(unname)
        return .envelope(envelope)
    }

    func acknowledge(_ id: String) async { await base.acknowledge(id) }
}

/// #151's suite against external daemons; skips without a configuration.
final class BusExternalDaemonConformanceTests: HostTransportConformanceSuite {
    override func makeHarness() -> HostTransportHarness? {
        guard let configuration = BusExternalConfiguration.load() else { return nil }
        do {
            let harness = try BusExternalHarness.make(configuration)
            return configuration.sealed ? HostTransportSealedHarness(harness) : harness
        } catch {
            // A configuration was given: refusing it is a failure, never a quiet skip.
            XCTFail("the external harness refused its configuration: \(error)")
            return nil
        }
    }
}

/// The external path proven before the mock lands: the same harness and
/// configuration, pointed at FakeCbusCore's sockets and its section 11 control
/// sockets, with daemon names that differ from the suite's (alpha, bravo,
/// carol), so the run against the mock is only a configuration change.
final class BusExternalHarnessSelfTests: HostTransportConformanceSuite {
    static let names = ["studio": "alpha", "laptop": "bravo", "prime": "carol"]

    final class SelfHarness: HostTransportHarness {
        let core = FakeCbusCore()
        let external: BusExternalHarness

        init(sharedWorld: Bool = false, before: (FakeCbusCore) -> Void = { _ in }) {
            core.sharesOneWorld = sharedWorld
            before(core)
            core.daemonDeadline = 0.18
            core.eligibleAppHosts = ["bravo"]
            // No authority in reach: the app host's claim is provisional until the
            // harness decides it, so the whole suite runs through the grant path.
            core.grantsAppHostAtHello = false
            var hosts: [String: Any] = [:]
            for (suite, daemon) in BusExternalHarnessSelfTests.names {
                hosts[suite] = ["socket": core.socketPath(daemon), "control": core.controlSocketPath(daemon), "name": daemon]
            }
            let token = UUID().uuidString
            try! token.write(to: core.directory.appendingPathComponent(BusExternalConfiguration.leaseFile),
                             atomically: true, encoding: .utf8)
            let json: [String: Any] = ["hosts": hosts, "app_host": "laptop", "daemon_deadline_s": 0.18,
                                       "adapter_deadline_s": 0.25, "sealed": false, "lease": token,
                                       "shared_world": sharedWorld]
            let data = try! JSONSerialization.data(withJSONObject: json)
            external = try! BusExternalHarness.make(try! JSONDecoder().decode(BusExternalConfiguration.self, from: data))
        }

        deinit { core.stop() }

        func endpoint(_ host: String) -> any HostTransport { external.endpoint(host) }
        func setAway(_ host: String, _ away: Bool) { external.setAway(host, away) }
        func setSilent(_ host: String, _ silent: Bool) { external.setSilent(host, silent) }
        func releaseLateAccepts() -> Int { external.releaseLateAccepts() }
        func quarantined(by host: String) -> [(id: String, code: HostTransportRefusal)] { external.quarantined(by: host) }
        func isAcknowledged(_ id: String, by host: String) -> Bool { external.isAcknowledged(id, by: host) }
        func advanceClock(by seconds: TimeInterval) { external.advanceClock(by: seconds) }
        func reconnect(_ a: String, _ b: String) { external.reconnect(a, b) }
        func restart(_ host: String) { external.restart(host) }
        func setTamper(_ tamper: (@Sendable (inout Data, inout Data?) -> Void)?) { external.setTamper(tamper) }
        func setReceiverRefusal(_ refusal: HostTransportRefusal?) { external.setReceiverRefusal(refusal) }
        func setHoldLimit(_ limit: Int) { external.setHoldLimit(limit) }
        var sendDeadline: TimeInterval { external.sendDeadline }
        var timeoutDelivery: HostTransportDelivery { external.timeoutDelivery }
        var stampsRelay: Bool { external.stampsRelay }
    }

    override func makeHarness() -> HostTransportHarness? { SelfHarness() }

    /// sol #152 finding 2: the suite's first send in a fresh session finds the
    /// receiving endpoint bound, because the harness greeted every host.
    func testTheFirstSendOfAFreshSessionIsDelivered() async {
        let h = SelfHarness()
        let first = HostEnvelope(id: HostTransportTestIDs.make(), from: "id:s", to: "id:r", body: Data("first".utf8))
        let result = await h.endpoint("studio").send(first, to: "laptop")
        XCTAssertEqual(result, .delivered)
    }

    /// sol #152 finding 3: daemons not leased to the test are never touched:
    /// no lease, a wrong token or the default CBUS_HOME is refused before any
    /// connection, with no control request and no hello reaching the daemon.
    func testDaemonsNotLeasedToTheTestAreNeverTouched() throws {
        let core = FakeCbusCore()
        defer { core.stop() }
        var hosts: [String: Any] = [:]
        for (suite, daemon) in Self.names {
            hosts[suite] = ["socket": core.socketPath(daemon), "control": core.controlSocketPath(daemon), "name": daemon]
        }
        func config(_ extra: [String: Any], hosts: [String: Any]) throws -> BusExternalConfiguration {
            var json: [String: Any] = ["hosts": hosts, "app_host": "laptop"]
            json.merge(extra) { $1 }
            return try JSONDecoder().decode(BusExternalConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertThrowsError(try BusExternalHarness.make(config([:], hosts: hosts)), "no lease in the configuration")
        XCTAssertThrowsError(try BusExternalHarness.make(config(["lease": "abc"], hosts: hosts)), "no lease file beside the sockets")
        try "other".write(to: core.directory.appendingPathComponent(BusExternalConfiguration.leaseFile), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BusExternalHarness.make(config(["lease": "abc"], hosts: hosts)), "another run's lease")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let defaultHome = ["studio": ["socket": "\(home)/Library/Application Support/cbus/cbus.sock",
                                     "control": "\(home)/Library/Application Support/cbus/cbus-test.sock"]]
        XCTAssertThrowsError(try config(["lease": "abc"], hosts: defaultHome).checkLease()) { error in
            guard case BusExternalConfiguration.Refusal.defaultHome = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(core.controlRequestCount(), 0, "no control operation reached the daemon")
        XCTAssertEqual(core.count("hello"), 0, "no connection said hello")
    }

    /// Mock run, finding A: one world gets a clock advance once, not once per
    /// configured control socket.
    func testASharedWorldAdvancesItsClockOnce() {
        let h = SelfHarness(sharedWorld: true)
        h.advanceClock(by: 100)
        XCTAssertEqual(h.core.clockOffsets(), ["alpha": 100, "bravo": 100, "carol": 100], "one advance of the one world")
    }

    /// Mock run, finding C: a daemon's quarantine outlives a test or a pass; each
    /// harness reports only what was quarantined after it started.
    func testQuarantineFromBeforeTheHarnessIsNotReported() {
        let oldID = HostTransportTestIDs.make(), newID = HostTransportTestIDs.make()
        let h = SelfHarness { core in core.recordRejected(host: "bravo", id: oldID, code: "invalid_envelope") }
        XCTAssertTrue(h.quarantined(by: "laptop").isEmpty, "an earlier test's or pass's quarantine is not this test's")
        h.core.recordRejected(host: "bravo", id: newID, code: "envelope_too_large")
        XCTAssertEqual(h.quarantined(by: "laptop").map(\.id), [newID])
    }

    /// C3: a claim the authority refused never runs the suite: the harness
    /// fails loudly instead of letting T6A fail on a discarded origin.
    func testARefusedAppHostRegistrationFailsTheRunLoudly() throws {
        let core = FakeCbusCore()
        defer { core.stop() }
        core.eligibleAppHosts = ["bravo"]
        core.grantsAppHostAtHello = false
        var hosts: [String: Any] = [:]
        for (suite, daemon) in Self.names {
            hosts[suite] = ["socket": core.socketPath(daemon), "control": core.controlSocketPath(daemon), "name": daemon]
        }
        let token = UUID().uuidString
        try token.write(to: core.directory.appendingPathComponent(BusExternalConfiguration.leaseFile), atomically: true, encoding: .utf8)
        let json: [String: Any] = ["hosts": hosts, "app_host": "laptop", "lease": token]
        let configuration = try JSONDecoder().decode(BusExternalConfiguration.self, from: JSONSerialization.data(withJSONObject: json))
        // Refusal follows the provisional hello on the real control/frame path.
        // A refused registration is never a valid hello result (rule 2.2).
        XCTAssertThrowsError(try BusExternalHarness.make(configuration, beforeAppHostDecision: { harness in
            let result = harness.control("laptop", "set_app_host_registration",
                                         ["host": "bravo", "registration": "refused"])
            XCTAssertEqual(result?["registration"] as? String, "refused")
        })) { error in
            XCTAssertEqual(error as? BusExternalHarness.Failure, .appHostNotGranted("refused"))
        }
    }

    func testTheTamperClosureReadsAsSection11Params() {
        let t8 = BusExternalHarness.declarativeTamper { body, topic in
            body = Data(body.reversed()) + Data([0xFF])
            topic = topic.map { Data($0.map { $0 ^ 0x5A }) }
        }
        XCTAssertEqual(t8["body_reverse"] as? Bool, true)
        XCTAssertEqual(t8["body_append"] as? String, Data([0xFF]).base64EncodedString())
        XCTAssertEqual(t8["topic_xor"] as? Int, 0x5A)
        let t5 = BusExternalHarness.declarativeTamper { body, _ in body.append(Data(count: 4608)) }
        XCTAssertNil(t5["body_reverse"])
        XCTAssertEqual(Data(base64Encoded: t5["body_append"] as? String ?? "")?.count, 4608)
        XCTAssertNil(t5["topic_xor"])
    }
}
