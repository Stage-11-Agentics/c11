import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// C11H-72: the bus adapter on the bus's HostTransport socket protocol v1
// (CBUS-19). Part A's conformance suite (T1-T9) runs on it unchanged, against
// an in-process fake daemon on real Unix sockets; the tests below cover what
// only the adapter does: its failure results, frames, the durable stale-state
// table, stamps, opaque logging, the carried envelope and the selection seam.

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class BusHostTransportHarness: HostTransportHarness {
    let core = FakeCbusCore()
    let root: URL
    let log = LockedLines()
    var peerPolicy = BusPeerPolicy.sameProcess
    /// The adapter's own deadline (A6's 2 s, scaled down); the daemon answers
    /// a little before it, as CBUS-19's 1,800 ms do before 2 s.
    let adapterDeadline: TimeInterval = 0.25
    /// The suite's forwarder in T6A says `app_host: true` at hello, and the
    /// daemon registers it as the session's app host (CBUS-19 rule 4.6).
    static let appHostName = "laptop"

    /// Endpoints greeted at start, kept for the harness's life.
    private var greeted: [BusHostTransport] = []

    /// `bindAll`: say `hello` for the suite's three hosts before any test runs,
    /// as a faithful daemon needs (CBUS-19 rules 4.2, 4.3 and 6.2 row 8).
    init(bindAll: Bool = true) {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("c11-bus-\(UUID().uuidString)", isDirectory: true)
        core.daemonDeadline = 0.18
        // T6A's forwarder holds the join certificate's app-host eligibility.
        core.eligibleAppHosts = [Self.appHostName]
        if bindAll {
            greeted = ["studio", "laptop", "prime"].map { BusHostTransport(host: $0, configuration: configuration($0)) }
            _ = BusBinding.bind(greeted)
        }
    }

    deinit {
        core.stop()
        BusStateSeqStore.forget(under: root)
        try? FileManager.default.removeItem(at: root)
    }

    func stateDirectory(_ host: String) -> URL {
        root.appendingPathComponent(host).appendingPathComponent("transport/bus", isDirectory: true)
    }

    func configuration(_ host: String) -> BusHostTransportConfiguration {
        let lines = log
        return BusHostTransportConfiguration(socketPath: core.socketPath(host), stateDirectory: stateDirectory(host),
                                             session: "c11-test", appHost: host == Self.appHostName,
                                             sendDeadline: adapterDeadline,
                                             peerPolicy: peerPolicy, log: { lines.append($0) })
    }

    func endpoint(_ host: String) -> any HostTransport { BusHostTransport(host: host, configuration: configuration(host)) }
    func setAway(_ host: String, _ away: Bool) { core.setAway(host, away) }
    func setSilent(_ host: String, _ silent: Bool) { core.setSilent(host, silent) }
    func releaseLateAccepts() -> Int { core.releaseLateAccepts() }
    func quarantined(by host: String) -> [(id: String, code: HostTransportRefusal)] {
        BusQuarantineStore.at(stateDirectory(host)).entries().map { ($0.id, HostTransportRefusal(rawValue: $0.code)) }
    }
    func isAcknowledged(_ id: String, by host: String) -> Bool { core.isAcknowledged(id, by: host) }
    func advanceClock(by seconds: TimeInterval) { core.advanceClock(by: seconds) }
    func reconnect(_ a: String, _ b: String) { core.reconnect(a, b) }
    func restart(_ host: String) {
        core.restart(host)
        // The adapter's own process restarts too: only what is on disk survives.
        BusStateSeqStore.forget(under: root.appendingPathComponent(host))
    }
    func setTamper(_ tamper: (@Sendable (inout Data, inout Data?) -> Void)?) { core.tamper = tamper }
    func setReceiverRefusal(_ refusal: HostTransportRefusal?) { core.receiverRefusal = refusal?.rawValue }
    func setHoldLimit(_ limit: Int) { core.holdLimit = limit }
    /// When `unreachable` arrives: the daemon's deadline (CBUS-19 rule 6.7).
    var sendDeadline: TimeInterval { core.daemonDeadline }
    /// A store-and-forward bus has no cancel path (SPEC 12.5).
    var timeoutDelivery: HostTransportDelivery { .unknown }
    var stampsRelay: Bool { false }
}

/// Greets endpoints from synchronous harness code.
enum BusBinding {
    /// The hosts that did not get a `hello` answer.
    static func bind(_ transports: [BusHostTransport]) -> [String] {
        let failed = BusExternalHarness.ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            var missing: [String] = []
            for transport in transports where !(await transport.bind()) { missing.append(transport.host) }
            failed.set(["missing": missing])
            done.signal()
        }
        done.wait()
        return failed.value?["missing"] as? [String] ?? []
    }
}

final class BusHostTransportConformanceTests: HostTransportConformanceSuite {
    override func makeHarness() -> HostTransportHarness? { BusHostTransportHarness() }
}

/// The same suite with every body and topic sealed by the endpoints (T8).
final class BusHostTransportSealedConformanceTests: HostTransportConformanceSuite {
    override func makeHarness() -> HostTransportHarness? { HostTransportSealedHarness(BusHostTransportHarness()) }
}

final class BusHostTransportTests: XCTestCase {
    private func envelope(_ body: String = "hello", to: String? = "id:receiver", topic: String? = nil,
                          passthrough: String = "", state: HostEnvelope.StateHeader? = nil,
                          stamps: [String: String] = [:]) -> HostEnvelope {
        HostEnvelope(id: HostTransportTestIDs.make(), from: "id:sender", to: to, body: Data(body.utf8),
                     topic: topic.map { Data($0.utf8) }, passthrough: Data(passthrough.utf8), stamps: stamps, state: state)
    }

    private func drain(_ inbox: any HostTransportInbox) async -> [HostEnvelope] {
        var out: [HostEnvelope] = []
        while let incoming = await inbox.next(timeout: 0.15) {
            if case .envelope(let e) = incoming { out.append(e); await inbox.acknowledge(e.id) }
        }
        return out
    }

    // MARK: Failure results

    func testMissingSocketIsDaemonDown() async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("c11-bus-missing-\(UUID())")
        let configuration = BusHostTransportConfiguration(socketPath: directory.appendingPathComponent("cbus.sock").path,
                                                          stateDirectory: directory, sendDeadline: 0.2,
                                                          peerPolicy: .sameProcess)
        let transport = BusHostTransport(host: "studio", configuration: configuration)
        let sent = await transport.send(envelope(), to: "laptop")
        XCTAssertEqual(sent, .unreachable(reason: "daemon_down", delivery: .unknown), "CBUS-19 rule 10.4")
        let held = await transport.hold(envelope(), for: "laptop")
        XCTAssertEqual(held, .unreachable(reason: "daemon_down", delivery: .unknown))
        let started = Date()
        let incoming = await transport.receive(from: "laptop").next(timeout: 0.3)
        XCTAssertNil(incoming, "a stream with no daemon is suspended and invents nothing")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testAConnectionLostAfterTheWholeRequestWentOutIsResentOnceThenUnknown() async {
        let h = BusHostTransportHarness()
        h.core.dropOnMethods = ["send"]
        let result = await h.endpoint("studio").send(envelope(), to: "laptop")
        XCTAssertEqual(result, .unreachable(reason: "daemon_closed", delivery: .unknown))
        XCTAssertEqual(h.core.count("send"), 2, "rule 10.4: one resend of the same envelope within the deadline")
    }

    func testTheAdapterSendsWhatItWasGivenAndTheDaemonRefuses() async {
        let h = BusHostTransportHarness()
        let tooBig = envelope(String(repeating: "x", count: HostTransportBounds.maximumBodyBytes + 1))
        let result = await h.endpoint("studio").send(tooBig, to: "laptop")
        XCTAssertEqual(result, .refused(.envelopeTooLarge))
        XCTAssertEqual(h.core.count("send"), 1, "rule 6.2: the adapter neither normalizes nor pre-refuses")
    }

    func testASocketPathThatIsNotTheOwnersSocketIsDaemonDown() async throws {
        let h = BusHostTransportHarness(bindAll: false)
        let real = h.core.socketPath("studio")
        let link = h.root.appendingPathComponent("link.sock")
        try FileManager.default.createDirectory(at: h.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real)
        var configuration = h.configuration("studio")
        configuration.socketPath = link.path
        let result = await BusHostTransport(host: "studio", configuration: configuration).send(envelope(), to: "laptop")
        XCTAssertEqual(result, .unreachable(reason: "daemon_down", delivery: .unknown), "rule 1.3: a symlink is not the socket")
        XCTAssertEqual(h.core.count("hello"), 0)
    }

    func testDaemonErrorsFollowRule10Point4() async {
        let h = BusHostTransportHarness()
        let a = h.endpoint("studio")
        h.core.responseFor["send"] = ["error": ["code": "internal", "message": "store full"]]
        let internalError = await a.send(envelope(), to: "laptop")
        XCTAssertEqual(internalError, .unreachable(reason: "internal", delivery: .unknown),
                       "the bus answers unknown, never none (CBUS-19 section 16)")
        h.core.responseFor["send"] = ["error": ["code": "daemon_stopping", "message": "stopping"]]
        let before = h.core.count("send")
        let stopping = await a.send(envelope(), to: "laptop")
        XCTAssertEqual(stopping, .unreachable(reason: "daemon_stopping", delivery: .unknown))
        XCTAssertEqual(h.core.count("send") - before, 2, "a stopping daemon gets one resend")
        h.core.responseFor["send"] = ["error": ["code": "bad_request", "message": "params"]]
        let defect = await a.send(envelope(), to: "laptop")
        XCTAssertEqual(defect, .refused(.protocolError), "an adapter defect is never blamed on the envelope")
        h.core.responseFor["send"] = ["error": ["code": "some_future_code", "message": "?"]]
        let unknownError = await a.send(envelope(), to: "laptop")
        XCTAssertEqual(unknownError, .unreachable(reason: "some_future_code", delivery: .unknown),
                       "an error the adapter cannot read may have written something")
    }

    func testAHelloErrorOrAnotherProtocolSendsNothing() async {
        let h = BusHostTransportHarness()
        h.core.helloError = "protocol_unsupported"
        let refused = await h.endpoint("studio").send(envelope(), to: "laptop")
        XCTAssertEqual(refused, .unreachable(reason: "protocol_unsupported", delivery: .unknown))
        h.core.helloError = nil
        h.core.helloProtocol = CbusWire.protocolVersion + 1
        let other = await h.endpoint("studio").send(envelope(), to: "laptop")
        XCTAssertEqual(other, .unreachable(reason: "protocol_unsupported", delivery: .unknown))
        XCTAssertEqual(h.core.count("send"), 0)
    }

    func testAnUntrustedPeerIsDaemonDownBeforeAnyLine() async {
        let h = BusHostTransportHarness(bindAll: false)
        h.peerPolicy = .refuseAll
        let result = await h.endpoint("studio").send(envelope(), to: "laptop")
        XCTAssertEqual(result, .unreachable(reason: "daemon_down", delivery: .unknown), "rule 1.3, answered as rule 10.4")
        XCTAssertEqual(h.core.count("hello") + h.core.count("send"), 0, "not even the greeting goes to an untrusted peer")
    }

    // MARK: Frames

    func testBadOrRejectedFramesAreQuarantinedAndAcknowledged() async {
        let h = BusHostTransportHarness()
        let inbox = h.endpoint("laptop").receive(from: "studio")
        _ = await inbox.next(timeout: 0.1) // subscribes
        let garbled = HostTransportTestIDs.make()
        h.core.inject(from: "studio", to: "laptop", ["frame": "envelope", "from_host": "studio", "envelope_id": garbled,
                                                    "envelope": "not json", "stamps": ["origin_host": "studio", "machine": "studio"]])
        let first = await inbox.next(timeout: 1)
        XCTAssertEqual(first, .refused(id: garbled, .invalidEnvelope))
        let real = envelope()
        let json = String(decoding: CbusWire.envelopeJSON(real)!, as: UTF8.self)
        h.core.inject(from: "studio", to: "laptop", ["frame": "envelope", "from_host": "studio", "envelope_id": real.id,
                                                    "envelope": json, "stamps": ["origin_host": "prime", "machine": "prime"]])
        let second = await inbox.next(timeout: 1)
        XCTAssertEqual(second, .refused(id: real.id, .invalidEnvelope), "a frame on studio's stream must be stamped studio")
        let rejected = HostTransportTestIDs.make()
        for chunk in 0..<2 {
            h.core.inject(from: "studio", to: "laptop", ["frame": "rejected", "from_host": "studio", "envelope_id": rejected,
                                                        "code": "envelope_too_large", "raw_bytes": 2, "chunk": chunk,
                                                        "chunks": 2, "raw": Data([0x7B]).base64EncodedString()])
        }
        let third = await inbox.next(timeout: 1)
        XCTAssertEqual(third, .refused(id: rejected, .envelopeTooLarge), "two chunks, one refusal")
        let none = await inbox.next(timeout: 0.2)
        XCTAssertNil(none, "reported once, after its last chunk")
        for id in [garbled, real.id, rejected] {
            XCTAssertTrue(h.core.wasAcknowledgeRequested(id), "quarantined once, never handed again")
        }
    }

    func testAReplacedSubscriptionStaysQuietAndNeverTakesTheStreamBack() async {
        let h = BusHostTransportHarness()
        let first = h.endpoint("laptop").receive(from: "studio")
        _ = await first.next(timeout: 0.1)
        let second = h.endpoint("laptop").receive(from: "studio")
        _ = await second.next(timeout: 0.1)
        _ = await first.next(timeout: 0.2) // reads its `closed replaced`
        _ = await first.next(timeout: 0.2)
        XCTAssertEqual(h.core.count("receive"), 2, "the replaced stream does not subscribe again")
        _ = await h.endpoint("studio").send(envelope("to the new one"), to: "laptop")
        guard case .envelope(let got)? = await second.next(timeout: 1) else { return XCTFail("the new stream lost it") }
        XCTAssertEqual(got.body, Data("to the new one".utf8))
    }

    func testStampsComeFromTheDaemonsFrameNeverFromTheEnvelope() async {
        let h = BusHostTransportHarness()
        let forged = envelope(passthrough: #"{"ext":{"c11h":{"origin_host":"forged","machine":"forged","relay":true}}}"#,
                              stamps: ["origin_host": "forged", "machine": "forged", "relay": "true"])
        _ = await h.endpoint("studio").send(forged, to: "laptop")
        let got = await drain(h.endpoint("laptop").receive(from: "studio"))
        XCTAssertEqual(got.first?.stamps, ["origin_host": "studio", "machine": "studio"])
        XCTAssertFalse(String(decoding: got.first?.passthrough ?? Data(), as: UTF8.self).contains("forged"),
                       "carried stamps are dropped, not passed through")
        // Another sender's bytes may carry them anyway (CBUS-19 rule 5.4's
        // exception, review finding 2): the frame's attested stamps still win.
        let inbox = h.endpoint("laptop").receive(from: "studio")
        _ = await inbox.next(timeout: 0.1)
        let id = HostTransportTestIDs.make()
        let carried = #"{"body":"x","ext":{"c11h":{"machine":"forged","origin_host":"forged"}},"from":"id:s","id":"\#(id)","to":"id:r","ts":"2026-11-02T06:40:00.000Z","version":1}"#
        h.core.inject(from: "studio", to: "laptop", ["frame": "envelope", "from_host": "studio", "envelope_id": id,
                                                    "envelope": carried, "stamps": ["origin_host": "studio", "machine": "studio"]])
        guard case .envelope(let injected)? = await inbox.next(timeout: 1) else { return XCTFail("not handed") }
        XCTAssertEqual(injected.stamps, ["origin_host": "studio", "machine": "studio"])
    }

    func testCarriedOriginIsKeptOnlyWhenTheBusSaysTheHopIsTheAppHost() async {
        let h = BusHostTransportHarness()
        func carried(_ id: String) -> String {
            #"{"body":"x","ext":{"c11h":{"machine":"studio","origin_host":"studio"}},"from":"id:s","id":"\#(id)","to":"id:r","ts":"2026-11-02T06:40:00.000Z","version":1}"#
        }
        // The bus says the hop is the session's app host: what it forwards keeps
        // its first origin (A8, T6A; CBUS-19 rule 5.5).
        let fromAppHost = h.endpoint("prime").receive(from: "laptop")
        _ = await fromAppHost.next(timeout: 0.1)
        let forwarded = HostTransportTestIDs.make()
        h.core.inject(from: "laptop", to: "prime", ["frame": "envelope", "from_host": "laptop", "envelope_id": forwarded,
                                                    "envelope": carried(forwarded), "stamps": ["origin_host": "laptop", "machine": "laptop"],
                                                    "from_app_host": true])
        guard case .envelope(let kept)? = await fromAppHost.next(timeout: 1) else { return XCTFail("not handed") }
        XCTAssertEqual(kept.stamps, ["origin_host": "studio", "machine": "studio"])
        // The bus says it is not: a non-app-host carried origin is never surfaced.
        let fromPrime = h.endpoint("laptop").receive(from: "prime")
        _ = await fromPrime.next(timeout: 0.1)
        let claimed = HostTransportTestIDs.make()
        h.core.inject(from: "prime", to: "laptop", ["frame": "envelope", "from_host": "prime", "envelope_id": claimed,
                                                    "envelope": carried(claimed), "stamps": ["origin_host": "prime", "machine": "prime"],
                                                    "from_app_host": false])
        guard case .envelope(let replaced)? = await fromPrime.next(timeout: 1) else { return XCTFail("not handed") }
        XCTAssertEqual(replaced.stamps, ["origin_host": "prime", "machine": "prime"])
    }

    /// C2 (Lead 01:05): app-host eligibility comes from the join certificate. A
    /// host that merely claims it in `hello` is refused and carries nothing;
    /// as an ordinary host its carried origin is never honored.
    func testANonEligibleAppHostClaimantIsRefusedAndItsCarriedOriginNeverHonored() async throws {
        let h = BusHostTransportHarness()
        var claimant = h.configuration("prime")
        claimant.appHost = true
        let claimed = await BusHostTransport(host: "prime", configuration: claimant).send(envelope(), to: "laptop")
        XCTAssertEqual(claimed, .refused(.appHostIneligible),
                       "a claim alone is not enough: only the certificate-eligible machine is the app host")
        XCTAssertEqual(h.core.count("send"), 0)
        // The same machine as an ordinary host forwards an envelope it received:
        // its carried origin (studio) is discarded, and the receiver sees prime.
        let e = envelope("to laptop via prime")
        _ = await h.endpoint("studio").send(e, to: "prime")
        let atPrime = await drain(h.endpoint("prime").receive(from: "studio"))
        let received = try XCTUnwrap(atPrime.first)
        XCTAssertEqual(received.stamps["origin_host"], "studio")
        _ = await h.endpoint("prime").send(received, to: "laptop")
        let atLaptop = await drain(h.endpoint("laptop").receive(from: "prime"))
        XCTAssertEqual(try XCTUnwrap(atLaptop.first).stamps, ["origin_host": "prime", "machine": "prime"])
    }

    /// CBUS-23: `app_host_ineligible` is a refusal, never a retry loop. Every
    /// later send answers it at once, and no channel says `hello` again.
    func testAnIneligibleAppHostClaimIsARefusalNeverARetryLoop() async {
        let h = BusHostTransportHarness(bindAll: false)
        var claimant = h.configuration("prime")
        claimant.appHost = true
        let transport = BusHostTransport(host: "prime", configuration: claimant)
        for _ in 0..<3 {
            let result = await transport.send(envelope(), to: "laptop")
            XCTAssertEqual(result, .refused(.appHostIneligible))
        }
        let inbox = transport.receive(from: "studio")
        for _ in 0..<3 { _ = await inbox.next(timeout: 0.1) }
        XCTAssertEqual(h.core.count("hello"), 2, "one hello for the sends, one for the stream; never again")
        XCTAssertEqual(h.core.count("send") + h.core.count("receive"), 0)
    }

    /// CBUS-23 rule 4.6: `hello` reports the registration, and the authority's
    /// decision arrives as an `app_host` frame. Until the grant, receivers
    /// discard the provisional app host's forwarded origins; after it, they keep them.
    func testTheAppHostRegistrationSignalAndItsEffectOnForwardedOrigins() async throws {
        let h = BusHostTransportHarness(bindAll: false)
        h.core.grantsAppHostAtHello = false
        let studio = h.endpoint("studio"), laptop = h.endpoint("laptop") as! BusHostTransport, prime = h.endpoint("prime")
        _ = await (prime as! BusHostTransport).bind()
        let registration = await laptop.appHostRegistration()
        XCTAssertEqual(registration, "provisional")
        func forwardedOrigin() async throws -> String? {
            let e = envelope("forward me")
            _ = await studio.send(e, to: "laptop")
            let atLaptop = await drain(laptop.receive(from: "studio"))
            let received = try XCTUnwrap(atLaptop.first)
            _ = await laptop.send(received, to: "prime")
            let atPrime = await drain(prime.receive(from: "laptop"))
            return try XCTUnwrap(atPrime.first).stamps["origin_host"]
        }
        let before = try await forwardedOrigin()
        XCTAssertEqual(before, "laptop", "a provisional app host's forwarded origin is not kept")
        XCTAssertEqual(h.core.decideAppHost("laptop", "granted"), "granted")
        let decided = await laptop.awaitAppHostDecision(timeout: 2)
        XCTAssertEqual(decided, "granted", "the app_host frame reached the adapter")
        let after = try await forwardedOrigin()
        XCTAssertEqual(after, "studio", "once granted, the forwarded origin is kept")
    }

    /// Tripwire for SPEC 12.5 at c4a7fd0, a daemon that discards every carried
    /// origin: it erases a forwarded envelope's true origin before the adapter
    /// sees it. The adapter reports the attested hop and never invents the lost
    /// origin, so #151's T6A (`origin_host == "studio"`) fails loudly against
    /// such a daemon instead of passing.
    func testADaemonThatDiscardsCarriedOriginIsCaughtByT6A() async throws {
        let h = BusHostTransportHarness()
        h.core.discardsCarriedOrigin = true
        let e = envelope("to prime")
        let sent = await h.endpoint("studio").send(e, to: "laptop")
        XCTAssertEqual(sent, .delivered)
        let atLaptop = await drain(h.endpoint("laptop").receive(from: "studio"))
        let received = try XCTUnwrap(atLaptop.first)
        XCTAssertEqual(received.stamps["origin_host"], "studio")
        h.setAway("prime", true)
        guard case .held = await h.endpoint("laptop").hold(received, for: "prime") else { return XCTFail("not held") }
        h.setAway("prime", false)
        let atPrime = await drain(h.endpoint("prime").receive(from: "laptop"))
        let arrived = try XCTUnwrap(atPrime.first)
        XCTAssertEqual(arrived.id, e.id)
        XCTAssertEqual(arrived.stamps, ["origin_host": "laptop", "machine": "laptop"],
                       "the attested hop, never an invented origin")
        XCTAssertNotEqual(arrived.stamps["origin_host"], "studio", "so T6A's own check fails against this daemon")
    }

    // MARK: The adapter's own stale-state check (A6 Amendment 1)

    /// sol #152 finding 1: the adapter's table is per session and attested
    /// sending host (CBUS-19 rule 9.1). prime's wrong-host record for studio's
    /// panel at seq 100 (which the layer refuses, A5) never makes studio's own
    /// seq 6 look stale, before or after the receiver restarts.
    func testAWrongHostRecordFromOneSenderNeverShadowsTheOwnersStateFromAnother() async {
        let h = BusHostTransportHarness()
        let panel = UUID()
        func record(_ seq: UInt64) -> HostEnvelope { envelope("v\(seq)", to: "c11:layer", state: .init(panel: panel, key: "flag", seq: seq)) }
        let wrongHost = record(100), owners = record(6)
        _ = await h.endpoint("prime").send(wrongHost, to: "laptop")
        let fromPrime = await drain(h.endpoint("laptop").receive(from: "prime")).map(\.id)
        XCTAssertEqual(fromPrime, [wrongHost.id], "handed to the layer, which refuses it as layer_wrong_host")
        _ = await h.endpoint("studio").send(owners, to: "laptop")
        let fromAtlas = await drain(h.endpoint("laptop").receive(from: "studio")).map(\.id)
        XCTAssertEqual(fromAtlas, [owners.id], "the owner's own record is never shadowed by another sender's")
        h.restart("laptop")
        let wrongAgain = record(101), ownersNext = record(7)
        _ = await h.endpoint("prime").send(wrongAgain, to: "laptop")
        _ = await drain(h.endpoint("laptop").receive(from: "prime"))
        _ = await h.endpoint("studio").send(ownersNext, to: "laptop")
        let afterRestart = await drain(h.endpoint("laptop").receive(from: "studio")).map(\.id)
        XCTAssertEqual(afterRestart, [ownersNext.id], "nor after the receiver restarts")
    }

    /// sol #152 finding 2: the fake daemon binds endpoints per session, as
    /// CBUS-19 does. A `send` to a host that has not said `hello` in the
    /// session is `unreachable(host_unknown)` and writes nothing; a `hold`
    /// waits and is delivered once that host binds (rule 7.2).
    func testASendToAHostNotYetBoundIsHostUnknownAndAHoldWaitsForTheBinding() async {
        let h = BusHostTransportHarness(bindAll: false)
        let a = h.endpoint("studio")
        let sent = await a.send(envelope("too early"), to: "laptop")
        XCTAssertEqual(sent, .unreachable(reason: "host_unknown", delivery: .unknown))
        let kept = envelope("kept for laptop")
        guard case .held = await a.hold(kept, for: "laptop") else { return XCTFail("a hold to an unbound host is kept") }
        let laptop = h.endpoint("laptop")
        let drained = await drain(laptop.receive(from: "studio")).map(\.id)
        XCTAssertEqual(drained, [kept.id], "delivered once laptop binds; the early send never")
    }

    func testTheAdapterDropsStaleStateWhenTheDaemonDoesNot() async {
        let h = BusHostTransportHarness()
        h.core.enforcesStaleState = false
        let panel = UUID()
        let newer = envelope("new", to: "c11:layer", state: .init(panel: panel, key: "flag", seq: 6))
        let older = envelope("old", to: "c11:layer", state: .init(panel: panel, key: "flag", seq: 5))
        for e in [newer, older] { _ = await h.endpoint("studio").send(e, to: "laptop") }
        let got = await drain(h.endpoint("laptop").receive(from: "studio")).map(\.id)
        XCTAssertEqual(got, [newer.id])
        XCTAssertTrue(h.core.isAcknowledged(older.id, by: "laptop"), "a dropped envelope is acknowledged")
    }

    func testTheStaleStateTableSurvivesARestartOfTheReceiver() async {
        let h = BusHostTransportHarness()
        h.core.enforcesStaleState = false
        let panel = UUID()
        _ = await h.endpoint("studio").send(envelope("new", to: "c11:layer", state: .init(panel: panel, key: "flag", seq: 6)),
                                           to: "laptop")
        let first = await drain(h.endpoint("laptop").receive(from: "studio"))
        XCTAssertEqual(first.count, 1)
        h.restart("laptop")
        let late = envelope("old", to: "c11:layer", state: .init(panel: panel, key: "flag", seq: 5))
        _ = await h.endpoint("studio").send(late, to: "laptop")
        let second = await drain(h.endpoint("laptop").receive(from: "studio"))
        XCTAssertTrue(second.isEmpty, "a restarted receiver still knows seq 6 and drops the late seq 5")
    }

    func testTheTableIsOnDiskBeforeTheEnvelopeIsHandedOut() async throws {
        let h = BusHostTransportHarness()
        h.core.enforcesStaleState = false
        let e = envelope(to: "c11:layer", state: .init(panel: UUID(), key: "metadata.title", seq: 3))
        _ = await h.endpoint("studio").send(e, to: "laptop")
        guard case .envelope(let got)? = await h.endpoint("laptop").receive(from: "studio").next(timeout: 1) else {
            return XCTFail("nothing handed out")
        }
        XCTAssertEqual(got.id, e.id)
        let table = h.stateDirectory("laptop").appendingPathComponent("state-seq/c11-test/studio.json")
        let saved = try String(contentsOf: table, encoding: .utf8)
        XCTAssertTrue(saved.contains(e.id), "written before the hand-out, not after the acknowledgement")
    }

    // MARK: Opaque bodies

    func testLogsCarryIdsAndSizesButNeverABodyOrTopic() async {
        let h = BusHostTransportHarness()
        let body = "BODY-MARKER-7f3", topic = "TOPIC-MARKER-9c1"
        let e = envelope(body, topic: topic)
        _ = await h.endpoint("studio").send(e, to: "laptop")
        h.setAway("prime", true)
        _ = await h.endpoint("studio").hold(envelope(body, topic: topic), for: "prime")
        _ = await drain(h.endpoint("laptop").receive(from: "studio"))
        let lines = h.log.all
        XCTAssertTrue(lines.contains { $0.contains("id=\(e.id)") && $0.contains("body_bytes=\(body.utf8.count)") })
        for marker in [body, topic] {
            XCTAssertFalse(lines.contains { $0.contains(marker) }, "no log line carries \(marker)")
        }
    }

    // MARK: The carried envelope

    func testTheCarriedEnvelopeIsV1AndEveryByteComesBack() throws {
        let body = Data((0...255).map(UInt8.init)), topic = Data([0, 0xFF, 0x0A, 0x22])
        let passthrough = Data(#"{"ext":{"x":1},"ts":"2026-11-02T00:00:00Z"}"#.utf8)
        let state = HostEnvelope.StateHeader(panel: UUID(), key: "metadata.delegate", seq: (1 << 52) + 7)
        let e = HostEnvelope(id: HostTransportTestIDs.make(), from: "id:a", to: "c11:layer", replyTo: "id:r",
                             inReplyTo: HostTransportTestIDs.make(), body: body, topic: topic, passthrough: passthrough,
                             stamps: ["origin_host": "sender-claim"], state: state)
        let json = try XCTUnwrap(CbusWire.envelopeJSON(e))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let v1: Set<String> = ["version", "id", "from", "ts", "body", "to", "topic", "reply_to", "in_reply_to", "urgent",
                               "ttl_seconds", "body_ref", "content_type", "ext"]
        XCTAssertTrue(Set(object.keys).isSubset(of: v1), "c11 envelope v1 allows no other top-level key")
        XCTAssertTrue(Set(["version", "id", "from", "ts", "body"]).isSubset(of: Set(object.keys)))
        XCTAssertEqual(object["topic"] as? String, topic.base64EncodedString(), "rule 5.2: base64 in its own field")
        let encoding = (((object["ext"] as? [String: Any])?["c11h"] as? [String: Any])?["encoding"] as? [String: String])
        XCTAssertEqual(encoding, ["body": "base64", "topic": "base64"])
        let back = try XCTUnwrap(CbusWire.hostEnvelope(json: json, originHost: "studio", machine: "studio"))
        XCTAssertEqual(back.routingKey, e.routingKey)
        XCTAssertEqual(back.body, body)
        XCTAssertEqual(back.topic, topic)
        XCTAssertEqual(back.state, state)
        let keptExt = try XCTUnwrap((try JSONSerialization.jsonObject(with: back.passthrough) as? [String: Any])?["ext"] as? [String: Any])
        let keptState = try XCTUnwrap((keptExt["c11h"] as? [String: Any])?["state"] as? [String: Any])
        XCTAssertEqual(keptState["key"] as? String, "metadata.delegate", "rule 5.5: ext.c11h.state stays in the ext passed through")
        XCTAssertNil((keptExt["c11h"] as? [String: Any])?["encoding"], "the adapter's own keys are stripped")
        XCTAssertEqual(back.stamps, ["origin_host": "studio", "machine": "studio"])
        let kept = try XCTUnwrap(try JSONSerialization.jsonObject(with: back.passthrough) as? [String: Any])
        XCTAssertEqual(kept["ts"] as? String, "2026-11-02T00:00:00Z")
        XCTAssertEqual((kept["ext"] as? [String: Any])?["x"] as? Int, 1)
        // A6 Amendment 2: passthrough is the JSON object of v1's other headers;
        // an unknown key or raw bytes are refused, never silently dropped.
        let unknownKey = HostEnvelope(id: HostTransportTestIDs.make(), from: "id:a", to: "id:b", body: Data("x".utf8),
                                      passthrough: Data(#"{"zzz":"not v1"}"#.utf8))
        XCTAssertNil(CbusWire.envelopeJSON(unknownKey))
        let rawBytes = HostEnvelope(id: HostTransportTestIDs.make(), from: "id:a", to: "id:b", body: Data("x".utf8),
                                    passthrough: Data(repeating: 0x20, count: 8))
        XCTAssertNil(CbusWire.envelopeJSON(rawBytes))
        let text = HostEnvelope(id: HostTransportTestIDs.make(), from: "id:a", to: "id:b", body: Data("plain \"text\" é".utf8),
                                topic: Data("ci.status".utf8))
        let textObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(CbusWire.envelopeJSON(text))) as? [String: Any])
        XCTAssertEqual(textObject["body"] as? String, "plain \"text\" é", "text bodies travel as themselves")
        XCTAssertEqual(textObject["topic"] as? String, "ci.status")
        let textBack = try XCTUnwrap(CbusWire.hostEnvelope(json: XCTUnwrap(CbusWire.envelopeJSON(text)), originHost: "a", machine: "a"))
        XCTAssertTrue(textBack.passthrough.isEmpty, "a ts the adapter added is not a passthrough field")
    }

    // MARK: A6 Amendment 2 (#155's measure), as the fake daemon applies it

    /// Every number in the headers is a safe integer, and the whole envelope is
    /// at most 65,536 bytes by #155's one measure: body and topic as given, plus
    /// the JCS bytes of the rest without implementation keys or an added `ts`.
    func testTheFakeAppliesAmendment2sNumbersAndMeasure() async {
        let h = BusHostTransportHarness()
        let a = h.endpoint("studio")
        func with(_ ext: String, id: String = HostTransportTestIDs.make()) -> HostEnvelope {
            HostEnvelope(id: id, from: "id:s", to: "id:r", body: Data("small".utf8), passthrough: Data("{\"ext\":\(ext)}".utf8))
        }
        let fraction = await a.send(with(#"{"n":1.5}"#), to: "laptop")
        XCTAssertEqual(fraction, .refused(.invalidEnvelope))
        let unsafe = await a.send(with(#"{"n":9007199254740992}"#), to: "laptop")
        XCTAssertEqual(unsafe, .refused(.invalidEnvelope))
        let safe = await a.send(with(#"{"n":9007199254740991}"#), to: "laptop")
        XCTAssertEqual(safe, .delivered)
        func sized(_ total: Int) -> HostEnvelope {
            let id = HostTransportTestIDs.make()
            let skeleton: [String: Any] = ["body": "", "ext": ["pad": ""], "from": "id:s", "id": id, "to": "id:r", "version": 1]
            let pad = total - "small".utf8.count - JCS.encode(skeleton).utf8.count
            return with("{\"pad\":\"\(String(repeating: "p", count: pad))\"}", id: id)
        }
        let atBound = await a.send(sized(65_536), to: "laptop")
        XCTAssertEqual(atBound, .delivered, "65,536 bytes by the one measure")
        let over = await a.send(sized(65_537), to: "laptop")
        XCTAssertEqual(over, .refused(.envelopeTooLarge))
    }

    // MARK: Selection (plan section 3)

    func testWithoutTheFlagConsumersGetTheRelayAndNoBusIsBuilt() {
        let relay = HostTransportMemoryNetwork().endpoint("studio")
        XCTAssertEqual(HostTransportSelection.mode(environment: [:]), .relay)
        XCTAssertEqual(HostTransportSelection.mode(environment: ["C11_HOST_TRANSPORT_BUS": "live"]), .relay,
                       "only the test value turns anything on")
        var built = false
        let chosen = HostTransportSelection.transport(relay: relay, mode: .relay) {
            built = true
            return relay
        }
        XCTAssertTrue(chosen === relay)
        XCTAssertFalse(built)
    }

    func testWithTheFlagOnlyTestRecipientsReachTheBus() async {
        let relayNetwork = HostTransportMemoryNetwork(), busNetwork = HostTransportMemoryNetwork()
        let mode = HostTransportSelection.mode(environment: ["C11_HOST_TRANSPORT_BUS": "test"])
        XCTAssertEqual(mode, .busTestTraffic)
        let chosen = HostTransportSelection.transport(relay: relayNetwork.endpoint("studio"), mode: mode) {
            busNetwork.endpoint("studio")
        }
        let test = envelope(to: "c11:bus-test"), testRun = envelope(to: "c11:bus-test/7")
        let layer = envelope(to: "c11:layer"), mail = envelope(to: "id:\(UUID().uuidString)")
        let lookalike = envelope(to: "c11:bus-testing")
        for e in [test, layer, mail, lookalike] { _ = await chosen.send(e, to: "laptop") }
        _ = await chosen.hold(testRun, for: "laptop")
        let onBus = await drain(busNetwork.endpoint("laptop").receive(from: "studio")).map(\.id)
        let onRelay = await drain(relayNetwork.endpoint("laptop").receive(from: "studio")).map(\.id)
        XCTAssertEqual(onBus, [test.id, testRun.id])
        XCTAssertEqual(onRelay, [layer.id, mail.id, lookalike.id])
        XCTAssertTrue(chosen is HostTransportTestTrafficRouter)
    }
}
