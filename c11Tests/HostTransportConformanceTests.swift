import CryptoKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// C11H-71 part A: the `HostTransport` conformance suite (contract A6, T1-T8).
// Written once against the interface. Each implementation subclasses
// `HostTransportConformanceSuite` and returns its harness: the in-memory
// reference implementation here, the relay in part C, the bus later
// (C11H-72), with no change to these tests. T7 (consumers see only the
// interface) is carried by the consumers' own tests, which run on the
// in-memory implementation with no relay present (parts B and E).

/// What the suite needs from an implementation under test.
protocol HostTransportHarness: AnyObject {
    func endpoint(_ host: String) -> any HostTransport
    func setAway(_ host: String, _ away: Bool)
    /// A peer that never answers within the deadline. Its sends are parked
    /// until `releaseLateAccepts`.
    func setSilent(_ host: String, _ silent: Bool)
    /// The silent peer now tries to accept every parked send; returns how many
    /// it attempted. An implementation that answered `none` must not apply
    /// any; one that answered `unknown` applies each, once.
    func releaseLateAccepts() -> Int
    /// Arrivals `host` quarantined (A6: kept, never applied).
    func quarantined(by host: String) -> [(id: String, code: HostTransportRefusal)]
    /// Whether `host` recorded an acknowledgement for `id` (within the retention).
    func isAcknowledged(_ id: String, by host: String) -> Bool
    /// Moves the implementation's clock (acknowledged-id retention).
    func advanceClock(by seconds: TimeInterval)
    func reconnect(_ a: String, _ b: String)
    func restart(_ host: String)
    func setTamper(_ tamper: (@Sendable (inout Data, inout Data?) -> Void)?)
    func setReceiverRefusal(_ refusal: HostTransportRefusal?)
    func setHoldLimit(_ limit: Int)
    var sendDeadline: TimeInterval { get }
    /// What this implementation promises on a timeout (the relay: `none`).
    var timeoutDelivery: HostTransportDelivery { get }
    var stampsRelay: Bool { get }
}

enum HostTransportTestIDs {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static func make() -> String { String((0..<26).map { _ in alphabet.randomElement()! }) }
}

class HostTransportConformanceSuite: XCTestCase {
    /// Nil on the abstract base: its tests skip.
    func makeHarness() -> HostTransportHarness? { nil }

    private func harness() throws -> HostTransportHarness {
        guard let harness = makeHarness() else { throw XCTSkip("abstract conformance suite") }
        return harness
    }

    func envelope(_ id: String = HostTransportTestIDs.make(), from: String = "id:sender", to: String? = "id:receiver",
                  body: String = "hello", topic: String? = nil, bodyRef: Bool = false) -> HostEnvelope {
        HostEnvelope(id: id, from: from, to: to, body: Data(body.utf8), topic: topic.map { Data($0.utf8) },
                     hasBodyRef: bodyRef)
    }

    /// Everything one stream hands over until it is quiet: envelopes are
    /// acknowledged; refusals are collected.
    func drainAll(_ inbox: any HostTransportInbox, quiet: TimeInterval = 0.15)
        async -> (envelopes: [HostEnvelope], refused: [(id: String, code: HostTransportRefusal)]) {
        var envelopes: [HostEnvelope] = [], refused: [(id: String, code: HostTransportRefusal)] = []
        while let incoming = await inbox.next(timeout: quiet) {
            switch incoming {
            case .envelope(let envelope):
                envelopes.append(envelope)
                await inbox.acknowledge(envelope.id)
            case .refused(let id, let code):
                refused.append((id, code))
            }
        }
        return (envelopes, refused)
    }

    /// Drain one stream, acknowledging each envelope, until it is quiet.
    func drain(_ inbox: any HostTransportInbox, quiet: TimeInterval = 0.15, acknowledge: Bool = true) async -> [HostEnvelope] {
        var out: [HostEnvelope] = []
        while let incoming = await inbox.next(timeout: quiet) {
            if case .envelope(let envelope) = incoming {
                out.append(envelope)
                if acknowledge { await inbox.acknowledge(envelope.id) }
            }
        }
        return out
    }

    // MARK: T1 order

    func testT1EnvelopesArriveInTheSendersOrderAndTwoSendersKeepTheirOwn() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), c = h.endpoint("prime"), b = h.endpoint("laptop")
        var fromA: [String] = [], fromC: [String] = []
        for i in 0..<1_000 {
            let e = envelope(body: "a\(i)"); fromA.append(e.id)
            let r1 = await a.send(e, to: "laptop")
            XCTAssertEqual(r1, .delivered)
            if i % 10 == 0 {
                let f = envelope(body: "c\(i)"); fromC.append(f.id)
                let r2 = await c.send(f, to: "laptop")
                XCTAssertEqual(r2, .delivered)
            }
        }
        let gotA = await drain(b.receive(from: "studio")).map(\.id)
        let gotC = await drain(b.receive(from: "prime")).map(\.id)
        XCTAssertEqual(gotA, fromA)
        XCTAssertEqual(gotC, fromC)
    }

    // MARK: T2 at least once, applied once

    /// A consumer that applies idempotently: the applied id is recorded in the
    /// same write as the effect (here one dictionary write), then it acknowledges.
    final class DurableConsumer {
        private(set) var effects: [String: Int] = [:]
        func apply(_ envelope: HostEnvelope) {
            guard effects[envelope.id] == nil else { return }
            effects[envelope.id] = 1
        }
    }

    func testT2EachDurableEffectHappensOnceThroughDropsAndCrashesAtEveryStep() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let consumer = DurableConsumer()
        var ids: [String] = []
        for i in 0..<12 {
            let e = envelope(body: "t2-\(i)"); ids.append(e.id)
            let r3 = await a.send(e, to: "laptop")
            XCTAssertEqual(r3, .delivered)
        }
        var redeliveredAfterAck = 0
        var acknowledged: Set<String> = []
        for (step, id) in ids.enumerated() {
            var inbox = b.receive(from: "studio")
            guard case .envelope(let first)? = await inbox.next(timeout: 1) else { return XCTFail("step \(step): nothing") }
            XCTAssertEqual(first.id, id, "order holds through faults")
            switch step % 3 {
            case 0:
                // The link drops after the hand-out, before the apply.
                h.reconnect("studio", "laptop")
            case 1:
                // The consumer crashes after the apply, before the acknowledgement.
                consumer.apply(first)
                h.restart("laptop")
            default:
                consumer.apply(first)
                await inbox.acknowledge(first.id)
                acknowledged.insert(first.id)
                h.reconnect("studio", "laptop")
                continue
            }
            inbox = b.receive(from: "studio")
            guard case .envelope(let again)? = await inbox.next(timeout: 1) else { return XCTFail("step \(step): no redelivery") }
            XCTAssertEqual(again.id, id, "an unacknowledged envelope comes again, in order")
            consumer.apply(again)
            await inbox.acknowledge(again.id)
            acknowledged.insert(again.id)
        }
        h.reconnect("studio", "laptop")
        let rest = await drain(b.receive(from: "studio"))
        redeliveredAfterAck = rest.filter { acknowledged.contains($0.id) }.count
        XCTAssertEqual(redeliveredAfterAck, 0, "never again after a recorded acknowledgement")
        XCTAssertEqual(Set(consumer.effects.keys), Set(ids))
        XCTAssertTrue(consumer.effects.values.allSatisfy { $0 == 1 })
    }

    // MARK: T3 hold and return

    func testT3HeldEnvelopesArriveOnReturnInOrderBeforeAnythingNewerAndSurviveRestarts() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        h.setAway("laptop", true)
        var held: [String] = []
        for i in 0..<5 {
            let e = envelope(body: "held-\(i)"); held.append(e.id)
            guard case .held = await a.hold(e, for: "laptop") else { return XCTFail("hold \(i) was not held") }
        }
        guard case .away = await a.send(envelope(body: "fail fast"), to: "laptop") else { return XCTFail("send to an away host") }
        h.restart("studio")
        h.restart("laptop")
        h.setAway("laptop", false)
        let after = envelope(body: "after the return")
        let r4 = await h.endpoint("studio").send(after, to: "laptop")
        XCTAssertEqual(r4, .delivered)
        let got = await drain(h.endpoint("laptop").receive(from: "studio")).map(\.id)
        XCTAssertEqual(got, held + [after.id])
        _ = b
    }

    // MARK: T4 away vs unreachable, and the late accept

    func testT4AwayIsQuickAndNeverDeliveredLater() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        h.setAway("laptop", true)
        let started = Date()
        let e = envelope()
        guard case .away = await a.send(e, to: "laptop") else { return XCTFail("not away") }
        XCTAssertLessThan(Date().timeIntervalSince(started), HostTransportBounds.sendDeadline)
        h.setAway("laptop", false)
        let got = await drain(b.receive(from: "studio"))
        XCTAssertFalse(got.contains { $0.id == e.id }, "away keeps nothing")
    }

    func testT4ASilentPeerIsUnreachableAtTheDeadlineAndALateAcceptKeepsThePromise() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        h.setSilent("laptop", true)
        let started = Date()
        let e = envelope()
        let result = await a.send(e, to: "laptop")
        let took = Date().timeIntervalSince(started)
        guard case .unreachable(_, let delivery) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(delivery, h.timeoutDelivery)
        XCTAssertGreaterThanOrEqual(took, h.sendDeadline - 0.01)
        XCTAssertLessThanOrEqual(took, HostTransportBounds.sendDeadline + 0.5)
        h.setSilent("laptop", false)
        // The peer really tries to accept it late.
        XCTAssertEqual(h.releaseLateAccepts(), 1, "the late accept was attempted")
        let got = await drain(b.receive(from: "studio")).filter { $0.id == e.id }
        switch delivery {
        case .none:
            XCTAssertTrue(got.isEmpty, "delivery: none is never applied, even when the peer accepts late")
        case .unknown:
            XCTAssertEqual(got.count, 1, "an accepted unknown delivery arrives exactly once")
            let again = await a.send(e, to: "laptop")
            XCTAssertEqual(again, .delivered, "a resend under the same id is safe")
            let more = await drain(b.receive(from: "studio")).filter { $0.id == e.id }
            XCTAssertTrue(more.isEmpty, "the resend adds nothing")
        }
    }

    // MARK: T3/T5 hold admission and capacity (review 1)

    /// A retry of an id already held is that envelope: never refused, even
    /// with the queue full, and delivered once on return.
    func testT3ARetryOfAHeldIdIsNeverRefusedWhenTheQueueIsFull() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        h.setHoldLimit(2)
        h.setAway("laptop", true)
        let first = envelope(), second = envelope()
        for e in [first, second] { guard case .held = await a.hold(e, for: "laptop") else { return XCTFail("not held") } }
        guard case .held = await a.hold(first, for: "laptop") else { return XCTFail("a retry of a held id must answer held") }
        let third = await a.hold(envelope(), for: "laptop")
        XCTAssertEqual(third, .refused(.holdFull), "a new id still finds the queue full")
        h.setAway("laptop", false)
        let got = await drain(b.receive(from: "studio")).map(\.id)
        XCTAssertEqual(got, [first.id, second.id], "each held id arrives once")
    }

    func testT5HoldRefusesWhatSendRefuses() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        for away in [true, false] {
            h.setAway("laptop", away)
            let tooBig = await a.hold(envelope(body: String(repeating: "x", count: HostTransportBounds.maximumBodyBytes + 1)), for: "laptop")
            let withRef = await a.hold(envelope(body: "", bodyRef: true), for: "laptop")
            let topicOnly = await a.hold(envelope(to: nil, topic: "t"), for: "laptop")
            let invalid = await a.hold(envelope("not-a-ulid"), for: "laptop")
            XCTAssertEqual(tooBig, .refused(.envelopeTooLarge))
            XCTAssertEqual(withRef, .refused(.bodyRefCrossHost))
            XCTAssertEqual(topicOnly, .refused(.topicOnlyCrossHost))
            XCTAssertEqual(invalid, .refused(.invalidEnvelope))
        }
        h.setAway("laptop", false)
        let got = await drain(b.receive(from: "studio"))
        XCTAssertTrue(got.isEmpty)
    }

    /// An arrival that fails validation is quarantined, kept across a restart
    /// of the receiver, reported as refused and never handed over.
    func testT5AnInvalidArrivalIsQuarantinedNotApplied() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let e = envelope(body: "fine when sent")
        let sent = await a.send(e, to: "laptop")
        XCTAssertEqual(sent, .delivered)
        h.setTamper { body, _ in body.append(Data(count: HostTransportBounds.maximumBodyBytes + 512)) }
        let first = await drainAll(b.receive(from: "studio"))
        XCTAssertTrue(first.envelopes.isEmpty)
        XCTAssertEqual(first.refused.map(\.id), [e.id])
        XCTAssertEqual(first.refused.map(\.code), [.envelopeTooLarge])
        h.setTamper(nil)
        h.restart("laptop")
        XCTAssertEqual(h.quarantined(by: "laptop").map(\.id), [e.id], "quarantine survives a restart")
        let after = await drainAll(h.endpoint("laptop").receive(from: "studio"))
        XCTAssertTrue(after.envelopes.isEmpty && after.refused.isEmpty, "never handed over later")
    }

    // MARK: T6 forwarding keeps the origin (review 1)

    /// Studio mails Prime through the laptop (A8): Prime sees Studio as the origin.
    func testT6AForwardedEnvelopeKeepsItsOrigin() async throws {
        let h = try harness()
        let studio = h.endpoint("studio"), laptop = h.endpoint("laptop"), prime = h.endpoint("prime")
        let e = envelope(body: "to prime")
        let sent = await studio.send(e, to: "laptop")
        XCTAssertEqual(sent, .delivered)
        let atLaptop = await drain(laptop.receive(from: "studio"))
        let received = try XCTUnwrap(atLaptop.first)
        h.setAway("prime", true)
        guard case .held = await laptop.hold(received, for: "prime") else { return XCTFail("not held") }
        h.setAway("prime", false)
        let atPrime = await drain(prime.receive(from: "laptop"))
        let arrived = try XCTUnwrap(atPrime.first)
        XCTAssertEqual(arrived.id, e.id)
        XCTAssertEqual(arrived.stamps["origin_host"], "studio")
        XCTAssertEqual(arrived.stamps["machine"], "studio")
    }

    // MARK: Retention (review 1)

    /// An acknowledged id is remembered for 7 days, across a restart: a retry
    /// just before then is never delivered again.
    func testAnAcknowledgedIdIsRememberedForSevenDays() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let e = envelope()
        _ = await a.send(e, to: "laptop")
        let first = await drain(b.receive(from: "studio"))
        XCTAssertEqual(first.map(\.id), [e.id])
        // The contract's 7 days, literally: never derived from the constant under test.
        h.advanceClock(by: 7 * 24 * 3600 - 60)
        h.restart("laptop")
        XCTAssertTrue(h.isAcknowledged(e.id, by: "laptop"))
        let retried = await a.send(e, to: "laptop")
        XCTAssertEqual(retried, .delivered)
        let again = await drain(h.endpoint("laptop").receive(from: "studio"))
        XCTAssertTrue(again.isEmpty, "a retry inside the retention is never delivered again")
    }

    // MARK: T5 refused

    func testT5RefusalsAreNeverDeliveredOrRetried() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let tooBig = envelope(body: String(repeating: "x", count: HostTransportBounds.maximumBodyBytes + 1))
        let atBound = envelope(body: String(repeating: "x", count: HostTransportBounds.maximumBodyBytes))
        let withRef = envelope(body: "", bodyRef: true)
        let invalid = envelope("not-a-ulid")
        let r7 = await a.send(tooBig, to: "laptop")
        XCTAssertEqual(r7, .refused(.envelopeTooLarge))
        let r8 = await a.send(withRef, to: "laptop")
        XCTAssertEqual(r8, .refused(.bodyRefCrossHost))
        let r9 = await a.send(invalid, to: "laptop")
        XCTAssertEqual(r9, .refused(.invalidEnvelope))
        let r10 = await a.send(atBound, to: "laptop")
        XCTAssertEqual(r10, .delivered, "4096 bytes is within the bound")
        h.setReceiverRefusal(.layerIdentityRefused)
        let wrongCaller = envelope()
        let r11 = await a.send(wrongCaller, to: "laptop")
        XCTAssertEqual(r11, .refused(.layerIdentityRefused))
        h.setReceiverRefusal(nil)
        h.setHoldLimit(2)
        h.setAway("laptop", true)
        let kept = [envelope(), envelope()]
        for e in kept { guard case .held = await a.hold(e, for: "laptop") else { return XCTFail("not held") } }
        let overflow = envelope()
        let r12 = await a.hold(overflow, for: "laptop")
        XCTAssertEqual(r12, .refused(.holdFull))
        h.setAway("laptop", false)
        let drainedT5 = await drain(b.receive(from: "studio"))
        let got = Set(drainedT5.map(\.id))
        XCTAssertEqual(got, Set([atBound.id] + kept.map(\.id)))
    }

    // MARK: T5 whole-envelope bound (A6 Amendment 2)

    /// An independently encoded original envelope v1 of exactly `total` bytes
    /// (compact JSON, ASCII only, so it is its own canonical form): a small
    /// body, padded inside `ext`, so only the whole-envelope bound can refuse
    /// it. Returns the JSON and the envelope that carries it.
    func v1Fixture(_ total: Int) -> (json: Data, envelope: HostEnvelope) {
        let id = HostTransportTestIDs.make()
        let ts = "2026-11-02T05:00:00Z"
        func encoded(_ pad: Int) -> String {
            #"{"version":1,"id":"\#(id)","from":"id:sender","to":"id:receiver","ts":"\#(ts)","body":"small body","ext":{"pad":"\#(String(repeating: "x", count: pad))"}}"#
        }
        let pad = total - encoded(0).utf8.count
        let headers = #"{"version":1,"ts":"\#(ts)","ext":{"pad":"\#(String(repeating: "x", count: pad))"}}"#
        return (Data(encoded(pad).utf8),
                HostEnvelope(id: id, from: "id:sender", to: "id:receiver", body: Data("small body".utf8),
                             passthrough: Data(headers.utf8)))
    }

    /// 65,536 bytes of original envelope is delivered; 65,537 is refused
    /// `envelope_too_large` by send and hold, and is never delivered or
    /// retried through a late accept, a reconnect or a restart.
    func testT5TheWholeOriginalEnvelopeIsBoundedAt65536Bytes() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let fixtureAt = v1Fixture(65_536), fixtureOver = v1Fixture(65_537)
        XCTAssertEqual(fixtureAt.json.count, 65_536)
        XCTAssertEqual(fixtureOver.json.count, 65_537)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: fixtureOver.json), "a real envelope v1 JSON object")
        let atBound = fixtureAt.envelope, over = fixtureOver.envelope
        XCTAssertEqual(atBound.originalBytes, fixtureAt.json.count, "the measure is the encoded original")
        XCTAssertEqual(over.originalBytes, fixtureOver.json.count)
        let sentOver = await a.send(over, to: "laptop")
        XCTAssertEqual(sentOver, .refused(.envelopeTooLarge))
        h.setAway("laptop", true)
        let heldOver = await a.hold(over, for: "laptop")
        XCTAssertEqual(heldOver, .refused(.envelopeTooLarge))
        h.setAway("laptop", false)
        let sentAt = await a.send(atBound, to: "laptop")
        XCTAssertEqual(sentAt, .delivered, "65,536 bytes is within the bound")
        let first = await drainAll(b.receive(from: "studio"))
        XCTAssertEqual(first.envelopes.map(\.id), [atBound.id])
        XCTAssertEqual(first.envelopes.first?.originalBytes, 65_536, "a hop never changes the original size")
        XCTAssertTrue(first.refused.isEmpty, "a refused send never crossed, so nothing is quarantined")
        XCTAssertEqual(h.releaseLateAccepts(), 0)
        h.reconnect("studio", "laptop")
        h.restart("studio")
        h.restart("laptop")
        let after = await drainAll(h.endpoint("laptop").receive(from: "studio"))
        XCTAssertTrue(after.envelopes.isEmpty && after.refused.isEmpty, "nothing delivered or retried later")
        XCTAssertFalse(h.isAcknowledged(over.id, by: "laptop"))
    }

    // MARK: T5 header rules (A6 Amendment 2)

    /// The bus's header rules hold in every implementation: a lowercase id, or
    /// a `from`, `to` or `reply_to` over 256 characters, is refused
    /// `invalid_envelope` by send and hold and never delivered; 256 characters
    /// is delivered.
    func testT5HeaderRulesAnUppercaseULIDAndAddressesOf256Characters() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let at = "id:" + String(repeating: "a", count: 253), over = at + "a"
        XCTAssertEqual(at.unicodeScalars.count, 256)
        func make(from: String = "id:sender", to: String = "id:receiver", replyTo: String? = nil,
                  id: String = HostTransportTestIDs.make()) -> HostEnvelope {
            HostEnvelope(id: id, from: from, to: to, replyTo: replyTo, body: Data("hello".utf8))
        }
        let refused = [make(id: "01abcdefghjkmnpqrstvwxyz01"), make(from: over), make(to: over),
                       make(replyTo: over)]
        let admitted = [make(from: at), make(to: at), make(replyTo: at)]
        for e in refused {
            let sent = await a.send(e, to: "laptop")
            XCTAssertEqual(sent, .refused(.invalidEnvelope), e.id)
        }
        h.setAway("laptop", true)
        for e in refused {
            let held = await a.hold(e, for: "laptop")
            XCTAssertEqual(held, .refused(.invalidEnvelope), e.id)
        }
        h.setAway("laptop", false)
        for e in admitted {
            let sent = await a.send(e, to: "laptop")
            XCTAssertEqual(sent, .delivered, "256 characters is within the bound")
        }
        h.reconnect("studio", "laptop")
        let got = await drainAll(b.receive(from: "studio"))
        XCTAssertEqual(got.envelopes.map(\.id), admitted.map(\.id))
        XCTAssertTrue(got.refused.isEmpty, "a refused send never crossed")
    }

    /// sol's near-bound case: a number JCS prints longer than its digits
    /// (9999999999999999999 as 10000000000000000000) would be measured
    /// differently by different sides, so it is refused at admission, on
    /// send and hold, in every implementation; a safe integer is delivered.
    func testT5UnsafeNumbersAreRefusedSafeIntegersDelivered() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        func make(_ n: String) -> HostEnvelope {
            HostEnvelope(id: HostTransportTestIDs.make(), from: "id:sender", to: "id:receiver", body: Data("small body".utf8),
                         passthrough: Data(#"{"ext":{"n":\#(n),"pad":"\#(String(repeating: "x", count: 65_000))"}}"#.utf8))
        }
        let unsafe = [make("9999999999999999999"), make("1.5")], safe = make("9007199254740991")
        for e in unsafe {
            let sent = await a.send(e, to: "laptop")
            XCTAssertEqual(sent, .refused(.invalidEnvelope))
        }
        h.setAway("laptop", true)
        for e in unsafe {
            let held = await a.hold(e, for: "laptop")
            XCTAssertEqual(held, .refused(.invalidEnvelope))
        }
        h.setAway("laptop", false)
        let sent = await a.send(safe, to: "laptop")
        XCTAssertEqual(sent, .delivered)
        let got = await drainAll(b.receive(from: "studio"))
        XCTAssertEqual(got.envelopes.map(\.id), [safe.id])
        XCTAssertTrue(got.refused.isEmpty)
    }

    // MARK: T6 stamps

    func testT6EveryCarriedEnvelopeIsStampedWithItsOriginOnly() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let r13 = await a.send(envelope(), to: "laptop")
        XCTAssertEqual(r13, .delivered)
        let drained = await drain(b.receive(from: "studio"))
        let got = try XCTUnwrap(drained.first)
        XCTAssertEqual(got.stamps["origin_host"], "studio")
        XCTAssertEqual(got.stamps["machine"], "studio")
        XCTAssertEqual(got.stamps["relay"] == "true", h.stampsRelay)
        XCTAssertTrue(Set(got.stamps.keys).isSubset(of: HostTransportBounds.stampKeys))
        XCTAssertNil(got.stamps["cbus"])
    }

    // MARK: T8 opaque body and topic

    func testT8RoutingAndDedupeIgnoreBodiesAndTopics() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let id = HostTransportTestIDs.make()
        let first = envelope(id, body: "one", topic: "ci.status")
        let sameIdOtherBytes = envelope(id, body: "two, different", topic: "other.topic")
        let x = envelope(body: "zzz", topic: "a"), y = envelope(body: "", topic: "b")
        for e in [first, sameIdOtherBytes, x, y] { _ = await a.send(e, to: "laptop") }
        let got = await drain(b.receive(from: "studio"))
        XCTAssertEqual(got.map(\.id), [id, x.id, y.id], "the same id with other bytes is the same envelope")
        XCTAssertEqual(got.first?.body, first.body)
        let r14 = await a.send(sameIdOtherBytes, to: "laptop")
        XCTAssertEqual(r14, .delivered)
        let r15 = await drain(b.receive(from: "studio")).isEmpty
        XCTAssertTrue(r15, "an acknowledged id never comes again")
        let r16 = await a.send(envelope(to: nil, topic: "ci.status"), to: "laptop")
        XCTAssertEqual(r16, .refused(.topicOnlyCrossHost))
    }

    func testT8BytesChangedInTransitChangeNeitherDestinationNorDedupe() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        h.setTamper { body, topic in
            body = Data(body.reversed()) + Data([0xFF])
            topic = topic.map { Data($0.map { $0 ^ 0x5A }) }
        }
        let e = envelope(body: "route me", topic: "t")
        let r17 = await a.send(e, to: "laptop")
        XCTAssertEqual(r17, .delivered)
        let got = await drain(b.receive(from: "studio"))
        XCTAssertEqual(got.map(\.routingKey), [e.routingKey], "same destination, same id")
        h.setTamper(nil)
        let r18 = await a.send(e, to: "laptop")
        XCTAssertEqual(r18, .delivered)
        let r19 = await drain(b.receive(from: "studio")).isEmpty
        XCTAssertTrue(r19, "dedupe is by id, not by bytes")
    }

    /// Sealed mode: the two endpoints hold a key the transport does not. The
    /// transport carries only ciphertext, and order, hold and dedupe still hold.
    func testT8SealedBodiesAndTopicsStillRouteOrderHoldAndDedupe() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let key = SymmetricKey(size: .bits256)
        func seal(_ text: String) throws -> Data { try ChaChaPoly.seal(Data(text.utf8), using: key).combined }
        func open(_ data: Data) throws -> String {
            String(decoding: try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key), as: UTF8.self)
        }
        func sealed(_ text: String) throws -> HostEnvelope {
            HostEnvelope(id: HostTransportTestIDs.make(), from: "id:sender", to: "id:receiver",
                         body: try seal(text), topic: try seal("topic:\(text)"))
        }
        let live = try sealed("live")
        let r20 = await a.send(live, to: "laptop")
        XCTAssertEqual(r20, .delivered)
        h.setAway("laptop", true)
        let heldOnes = try (0..<3).map { try sealed("held-\($0)") }
        for e in heldOnes { guard case .held = await a.hold(e, for: "laptop") else { return XCTFail("not held") } }
        h.setAway("laptop", false)
        let got = await drain(b.receive(from: "studio"))
        XCTAssertEqual(got.map(\.id), [live.id] + heldOnes.map(\.id))
        XCTAssertEqual(try got.map { try open($0.body) }, ["live", "held-0", "held-1", "held-2"])
        XCTAssertEqual(try open(XCTUnwrap(got.last?.topic)), "topic:held-2")
        let r21 = await a.send(live, to: "laptop")
        XCTAssertEqual(r21, .delivered)
        let r22 = await drain(b.receive(from: "studio")).isEmpty
        XCTAssertTrue(r22)
    }

    // MARK: T9 stale state is dropped (A6 Amendment 1)

    func state(_ panel: UUID, _ key: String, _ seq: UInt64, body: String = "v",
               id: String = HostTransportTestIDs.make()) -> HostEnvelope {
        HostEnvelope(id: id, from: "id:sender", to: "c11:layer", body: Data(body.utf8),
                     state: .init(panel: panel, key: key, seq: seq))
    }

    func testT9ADelayedOldWriteArrivingAfterANewerOneIsDropped() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let panel = UUID(), other = UUID()
        let newer = state(panel, "metadata.title", 6, body: "new")
        let older = state(panel, "metadata.title", 5, body: "old")
        let raise7 = state(panel, "flag", 7, body: "raise"), lower8 = state(panel, "flag", 8, body: "lower")
        let otherKey = state(panel, "metadata.status", 1), otherPanel = state(other, "metadata.title", 1)
        let mail = envelope(body: "mail")
        for e in [newer, older, lower8, raise7, otherKey, otherPanel, mail] {
            let r = await a.send(e, to: "laptop")
            XCTAssertEqual(r, .delivered)
        }
        let got = await drain(b.receive(from: "studio")).map(\.id)
        XCTAssertEqual(got, [newer.id, lower8.id, otherKey.id, otherPanel.id, mail.id],
                       "the late seq 5 and the late raise are dropped; other keys, panels and mail are untouched")
        let again = await drain(b.receive(from: "studio"))
        XCTAssertTrue(again.isEmpty, "a dropped envelope is acknowledged, never handed over later")
        XCTAssertTrue(h.isAcknowledged(older.id, by: "laptop"), "the stale write is acknowledged")
        XCTAssertTrue(h.isAcknowledged(raise7.id, by: "laptop"), "the late raise is acknowledged")
    }

    /// A seq 5 write ends `unknown`/`none` against a silent peer; seq 6 is then
    /// delivered; the peer's late accept of seq 5 is released after that. It
    /// never undoes seq 6.
    func testT9AStaleLateCompletionNeverUndoesANewerWrite() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let panel = UUID()
        let older = state(panel, "metadata.title", 5, body: "old"), newer = state(panel, "metadata.title", 6, body: "new")
        h.setSilent("laptop", true)
        guard case .unreachable = await a.send(older, to: "laptop") else { return XCTFail("not unreachable") }
        h.setSilent("laptop", false)
        let sent = await a.send(newer, to: "laptop")
        XCTAssertEqual(sent, .delivered)
        let first = await drain(b.receive(from: "studio")).map(\.id)
        XCTAssertEqual(first, [newer.id])
        XCTAssertEqual(h.releaseLateAccepts(), 1, "the late completion was attempted")
        let late = await drain(b.receive(from: "studio")).map(\.id)
        XCTAssertTrue(late.isEmpty, "the late seq 5 never reaches the consumer")
        if h.timeoutDelivery == .unknown {
            XCTAssertTrue(h.isAcknowledged(older.id, by: "laptop"), "an applied-late stale write is acknowledged and dropped")
        }
    }

    /// A multi-key clear split into tombstones (title at 5, description at 6)
    /// is delayed past a title set at 7: each key stands alone.
    func testT9AMixedBatchKeepsEachKeyOnItsOwn() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let panel = UUID()
        let titleSet = state(panel, "metadata.title", 7)
        let titleClear = state(panel, "metadata.title", 5), descriptionClear = state(panel, "metadata.description", 6)
        for e in [titleSet, titleClear, descriptionClear] { _ = await a.send(e, to: "laptop") }
        let got = await drain(b.receive(from: "studio")).map(\.id)
        XCTAssertEqual(got, [titleSet.id, descriptionClear.id])
        // Reversed roles: the description is the newer one.
        let panel2 = UUID()
        let descriptionSet = state(panel2, "metadata.description", 7)
        let titleClear2 = state(panel2, "metadata.title", 5), descriptionClear2 = state(panel2, "metadata.description", 6)
        for e in [descriptionSet, titleClear2, descriptionClear2] { _ = await a.send(e, to: "laptop") }
        let got2 = await drain(b.receive(from: "studio")).map(\.id)
        XCTAssertEqual(got2, [descriptionSet.id, titleClear2.id])
    }

    /// `metadata.delegate` (a custom key) and `delegate` (delegation) never collide.
    func testT9ACustomKeyNamedDelegateNeverSuppressesUndelegate() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let panel = UUID()
        let custom = state(panel, "metadata.delegate", 8, body: "reviewer")
        let undelegate = state(panel, "delegate", 7, body: "undelegate")
        for e in [custom, undelegate] { _ = await a.send(e, to: "laptop") }
        let got = await drain(b.receive(from: "studio")).map(\.id)
        XCTAssertEqual(got, [custom.id, undelegate.id])
    }

    func testT9EqualSeqUnderAnotherIdIsDroppedButTheSameIdIsRedelivered() async throws {
        let h = try harness()
        let a = h.endpoint("studio"), b = h.endpoint("laptop")
        let panel = UUID()
        let first = state(panel, "flag", 3), twin = state(panel, "flag", 3)
        for e in [first, twin] { _ = await a.send(e, to: "laptop") }
        var inbox = b.receive(from: "studio")
        guard case .envelope(let handed)? = await inbox.next(timeout: 1) else { return XCTFail("nothing") }
        XCTAssertEqual(handed.id, first.id)
        h.reconnect("studio", "laptop")
        inbox = b.receive(from: "studio")
        let rest = await drain(inbox).map(\.id)
        XCTAssertEqual(rest, [first.id], "the same id comes again before its acknowledgement; the equal-seq twin never does")
    }
}

// MARK: - The in-memory reference implementation

final class HostTransportMemoryHarness: HostTransportHarness {
    let network: HostTransportMemoryNetwork
    init(cancelsAtDeadline: Bool = true) {
        network = HostTransportMemoryNetwork(sendDeadline: 0.2)
        network.cancelsAtDeadline = cancelsAtDeadline
    }
    func endpoint(_ host: String) -> any HostTransport { network.endpoint(host) }
    func setAway(_ host: String, _ away: Bool) { network.setAway(host, away) }
    func setSilent(_ host: String, _ silent: Bool) { network.setSilent(host, silent) }
    func releaseLateAccepts() -> Int { network.releaseLateAccepts() }
    func quarantined(by host: String) -> [(id: String, code: HostTransportRefusal)] {
        network.quarantined(by: host).map { ($0.id, $0.code) }
    }
    func isAcknowledged(_ id: String, by host: String) -> Bool { network.isAcknowledged(id, by: host) }
    func advanceClock(by seconds: TimeInterval) { network.advanceClock(by: seconds) }
    func reconnect(_ a: String, _ b: String) { network.reconnect(a, b) }
    func restart(_ host: String) { network.restart(host) }
    func setTamper(_ tamper: (@Sendable (inout Data, inout Data?) -> Void)?) { network.tamper = tamper }
    func setReceiverRefusal(_ refusal: HostTransportRefusal?) { network.admit = { _, _ in refusal } }
    func setHoldLimit(_ limit: Int) { network.holdLimit = limit }
    var sendDeadline: TimeInterval { network.sendDeadline }
    var timeoutDelivery: HostTransportDelivery { network.cancelsAtDeadline ? .none : .unknown }
    var stampsRelay: Bool { network.stampsRelay }
}

final class HostTransportMemoryConformanceTests: HostTransportConformanceSuite {
    override func makeHarness() -> HostTransportHarness? { HostTransportMemoryHarness() }
}

/// The same suite on a variant that cannot cancel at its deadline: T4's
/// `delivery: unknown` branch (a late accept applies once, a same-id resend
/// adds nothing).
final class HostTransportMemoryUnknownDeliveryTests: HostTransportConformanceSuite {
    override func makeHarness() -> HostTransportHarness? { HostTransportMemoryHarness(cancelsAtDeadline: false) }
}

/// Sealed mode (A6 T8; review 1): any harness, with every body and topic
/// sealed by the endpoints (ChaChaPoly, a key the implementation never has).
/// The whole suite runs through it unchanged. Sealing adds a fixed overhead
/// that the envelope declares, so the bound still measures what the sender gave.
final class HostTransportSealedHarness: HostTransportHarness {
    let inner: HostTransportHarness
    let key = SymmetricKey(size: .bits256)
    init(_ inner: HostTransportHarness) { self.inner = inner }
    func endpoint(_ host: String) -> any HostTransport { SealedTransport(inner.endpoint(host), key: key) }
    func setAway(_ host: String, _ away: Bool) { inner.setAway(host, away) }
    func setSilent(_ host: String, _ silent: Bool) { inner.setSilent(host, silent) }
    func releaseLateAccepts() -> Int { inner.releaseLateAccepts() }
    func quarantined(by host: String) -> [(id: String, code: HostTransportRefusal)] { inner.quarantined(by: host) }
    func isAcknowledged(_ id: String, by host: String) -> Bool { inner.isAcknowledged(id, by: host) }
    func advanceClock(by seconds: TimeInterval) { inner.advanceClock(by: seconds) }
    func reconnect(_ a: String, _ b: String) { inner.reconnect(a, b) }
    func restart(_ host: String) { inner.restart(host) }
    func setTamper(_ tamper: (@Sendable (inout Data, inout Data?) -> Void)?) { inner.setTamper(tamper) }
    func setReceiverRefusal(_ refusal: HostTransportRefusal?) { inner.setReceiverRefusal(refusal) }
    func setHoldLimit(_ limit: Int) { inner.setHoldLimit(limit) }
    var sendDeadline: TimeInterval { inner.sendDeadline }
    var timeoutDelivery: HostTransportDelivery { inner.timeoutDelivery }
    var stampsRelay: Bool { inner.stampsRelay }

    /// ChaChaPoly's combined form: 12-byte nonce + 16-byte tag.
    static let overhead = 28

    final class SealedTransport: HostTransport, @unchecked Sendable {
        let base: any HostTransport
        let key: SymmetricKey
        init(_ base: any HostTransport, key: SymmetricKey) { self.base = base; self.key = key }
        var host: String { base.host }
        func send(_ envelope: HostEnvelope, to host: String) async -> HostTransportResult {
            await base.send(seal(envelope), to: host)
        }
        func hold(_ envelope: HostEnvelope, for host: String) async -> HostTransportResult {
            await base.hold(seal(envelope), for: host)
        }
        func receive(from host: String) -> any HostTransportInbox { SealedInbox(base.receive(from: host), key: key) }
        private func seal(_ e: HostEnvelope) -> HostEnvelope {
            // An envelope that already arrived sealed was opened on receipt; seal it again.
            let body = (try? ChaChaPoly.seal(e.body, using: key).combined) ?? e.body
            let topic = e.topic.flatMap { try? ChaChaPoly.seal($0, using: key).combined }
            return e.replacingOpaque(body: body, topic: topic, bodyOverhead: HostTransportSealedHarness.overhead)
        }
    }

    final class SealedInbox: HostTransportInbox, @unchecked Sendable {
        let base: any HostTransportInbox
        let key: SymmetricKey
        init(_ base: any HostTransportInbox, key: SymmetricKey) { self.base = base; self.key = key }
        func next(timeout: TimeInterval) async -> HostTransportIncoming? {
            guard let incoming = await base.next(timeout: timeout) else { return nil }
            guard case .envelope(let e) = incoming else { return incoming }
            // Opened only here, at the recipient. Bytes changed in transit no
            // longer open; they are handed over as they came (T8 tamper).
            func open(_ data: Data) -> Data? { try? ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key) }
            guard let body = open(e.body) else { return .envelope(e) }
            return .envelope(e.replacingOpaque(body: body, topic: e.topic.map { open($0) ?? $0 }, bodyOverhead: 0))
        }
        func acknowledge(_ id: String) async { await base.acknowledge(id) }
    }
}

final class HostTransportMemorySealedConformanceTests: HostTransportConformanceSuite {
    override func makeHarness() -> HostTransportHarness? { HostTransportSealedHarness(HostTransportMemoryHarness()) }
}

/// Admission is the same pure check in every implementation.
final class HostEnvelopeAdmissionTests: XCTestCase {
    // A6 Amendment 2 header rules, one method per rule.
    private func e(id: String = HostTransportTestIDs.make(), from: String = "id:s", to: String = "id:r",
                   replyTo: String? = nil) -> HostEnvelope {
        HostEnvelope(id: id, from: from, to: to, replyTo: replyTo, body: Data())
    }
    private let at = "id:" + String(repeating: "é", count: 253)  // 256 code points, 509 bytes
    private var over: String { at + "a" }

    /// Escapes, non-ASCII, safe integers and whitespace in the sender's headers:
    /// the measure is their RFC 8785 serialization, written out by hand here,
    /// with `body` as "" and `topic` left out, plus the body's and topic's
    /// own bytes.
    func testTheMeasureIsTheCanonicalJSONOfTheOriginal() {
        let id = HostTransportTestIDs.make(), reply = HostTransportTestIDs.make()
        let headers = """
        { "version": 1, "ts": "2026-11-02T05:00:00.123Z", "urgent": true, "ttl_seconds": 3600,
          "content_type": "text/plain",
          "ext": { "n": [9007199254740991, -9007199254740991, 0, -7, null, false], "s": "\\u0007",
                   "q": "a\\"b\\\\c\\nd\\/e" } }
        """
        let e = HostEnvelope(id: id, from: "id:s/é", to: "id:r", replyTo: "id:q", inReplyTo: reply,
                             body: Data("a\"b\\c\nd\u{1}/é😀".utf8), topic: Data("t\tx".utf8),
                             passthrough: Data(headers.utf8))
        let canonical = #"{"version":1,"id":"\#(id)","from":"id:s/é","to":"id:r","reply_to":"id:q","in_reply_to":"\#(reply)","body":"","ts":"2026-11-02T05:00:00.123Z","urgent":true,"ttl_seconds":3600,"content_type":"text/plain","ext":{"n":[9007199254740991,-9007199254740991,0,-7,null,false],"s":"\u0007","q":"a\"b\\c\nd/e"}}"#
        XCTAssertEqual(e.originalBytes, canonical.utf8.count + e.body.count + (e.topic?.count ?? 0))
        XCTAssertNil(HostEnvelopeAdmission.refusal(e))
    }

    /// What an implementation adds under ext.c11h, and a ts the bus adapter
    /// synthesized, are removed before measuring; the sender's own empty ext
    /// still counts.
    func testImplementationKeysAndASynthesizedTsAreNotCounted() {
        let id = HostTransportTestIDs.make()
        func measure(_ headers: String) -> Int {
            HostEnvelope(id: id, from: "id:s", to: "id:r", body: Data("hi".utf8), passthrough: Data(headers.utf8)).originalBytes
        }
        let clean = measure(#"{"ts":"2026-11-02T05:00:00Z","ext":{"app":"x"}}"#)
        let carried = measure(#"{"ts":"2026-11-02T05:00:00Z","ext":{"app":"x","c11h":{"origin_host":"studio","machine":"studio","relay":true,"encoding":"base64","body_overhead":28}}}"#)
        XCTAssertEqual(carried, clean)
        let noTs = measure("")
        XCTAssertEqual(measure(#"{"ts":"2026-11-02T05:00:00Z","ext":{"c11h":{"ts_added":true}}}"#), noTs,
                       "a synthesized ts and the ext it emptied are not counted")
        // Any empty ext or ext.c11h, original or emptied, is taken out, so an
        // ordinary hop never changes the number (sol verify 2).
        XCTAssertEqual(measure(#"{"ext":{}}"#), noTs, "an original empty ext is not counted")
        XCTAssertEqual(measure(#"{"ext":{"c11h":{}}}"#), noTs, "an original empty ext.c11h is not counted")
        XCTAssertEqual(measure(#"{"ext":{"app":"x","c11h":{}}}"#), measure(#"{"ext":{"app":"x"}}"#))
        let hops: [(original: String, carried: String)] = [
            (#"{"ext":{}}"#, #"{"ts":"2026-11-02T05:00:00Z","ext":{"c11h":{"ts_added":true}}}"#),
            (#"{"ext":{"c11h":{}}}"#, #"{"ext":{"c11h":{"origin_host":"studio","machine":"studio","encoding":"base64","body_overhead":28}}}"#),
            (#"{"ts":"2026-11-02T05:00:00Z","ext":{}}"#, #"{"ts":"2026-11-02T05:00:00Z","ext":{"c11h":{"relay":true}}}"#),
        ]
        for hop in hops {
            XCTAssertEqual(measure(hop.carried), measure(hop.original), "a hop keeps the number: \(hop.original)")
        }
    }

    /// Keys that differ only by Unicode normalization are distinct JSON keys,
    /// and both count (sol verify, non-blocking).
    func testKeysThatDifferOnlyByNormalizationBothCount() {
        let id = HostTransportTestIDs.make()
        func measure(_ headers: String) -> Int {
            HostEnvelope(id: id, from: "id:s", to: "id:r", body: Data(), passthrough: Data(headers.utf8)).originalBytes
        }
        let both = measure(#"{"ext":{"\u00e9":1,"e\u0301":2}}"#)
        XCTAssertEqual(both, measure("") + ",\"ext\":{\"\u{e9}\":1,\"e\u{301}\":2}".utf8.count)
    }

    /// Every number in the headers is a safe integer, the one form JCS and
    /// every implementation print alike; anything else is invalid_envelope.
    func testNumbersMustBeSafeIntegers() {
        func refusal(_ headers: String) -> HostTransportRefusal? {
            HostEnvelopeAdmission.refusal(HostEnvelope(id: HostTransportTestIDs.make(), from: "id:s", to: "id:r",
                                                       body: Data(), passthrough: Data(headers.utf8)))
        }
        XCTAssertNil(refusal(#"{"ttl_seconds":3600,"ext":{"a":[9007199254740991,-9007199254740991,0,true]}}"#))
        for unsafe in ["9007199254740992", "-9007199254740992", "9999999999999999999", "1.5", "100.0", "1e2", "-0.5"] {
            XCTAssertEqual(refusal(#"{"ext":{"n":\#(unsafe)}}"#), .invalidEnvelope, unsafe)
            XCTAssertEqual(refusal(#"{"ext":{"deep":[{"n":\#(unsafe)}]}}"#), .invalidEnvelope, "nested \(unsafe)")
        }
        XCTAssertEqual(refusal(#"{"ttl_seconds":1.5}"#), .invalidEnvelope)
        let bigSeq = HostEnvelope(id: HostTransportTestIDs.make(), from: "id:s", to: "id:r", body: Data(),
                                  state: .init(panel: UUID(), key: "flag", seq: 1 << 53))
        XCTAssertEqual(HostEnvelopeAdmission.refusal(bigSeq), .invalidEnvelope, "a state seq is a safe integer too")
    }

    /// Body and topic count as their own bytes, never scanned for escapes,
    /// less a sealing layer's overhead.
    func testBodyAndTopicCountAsTheirBytes() {
        let id = HostTransportTestIDs.make()
        func size(_ body: Data, _ topic: Data? = nil, overhead: Int = 0) -> Int {
            HostEnvelope(id: id, from: "id:s", to: "id:r", body: body, topic: topic, bodyOverhead: overhead).originalBytes
        }
        let empty = size(Data())
        XCTAssertEqual(size(Data([0xFF, 0xFE])), empty + 2)
        XCTAssertEqual(size(Data("\"\n\u{1}".utf8)), empty + 3, "escapes the JSON would need are not counted")
        XCTAssertEqual(size(Data(), Data("t\tx".utf8)), empty + 3, "the topic adds its bytes and no key")
        XCTAssertEqual(size(Data(count: 10 + 28), Data(count: 3 + 28), overhead: 28), empty + 13,
                       "a sealed copy measures as its plaintext did, at any hop")
    }

    /// passthrough is the JSON object of the other v1 headers, or nothing.
    func testPassthroughMustBeAnObjectOfTheOtherHeaders() {
        func refusal(_ headers: Data) -> HostTransportRefusal? {
            HostEnvelopeAdmission.refusal(HostEnvelope(id: HostTransportTestIDs.make(), from: "id:s", to: "id:r",
                                                       body: Data(), passthrough: headers))
        }
        XCTAssertNil(refusal(Data()))
        XCTAssertNil(refusal(Data(#"{"urgent":false,"ext":{"a":1}}"#.utf8)))
        XCTAssertEqual(refusal(Data(repeating: 0x20, count: 8)), .invalidEnvelope, "raw bytes cannot ride as v1 JSON")
        XCTAssertEqual(refusal(Data("[1]".utf8)), .invalidEnvelope)
        XCTAssertEqual(refusal(Data(#"{"id":"x"}"#.utf8)), .invalidEnvelope, "routing fields are not passthrough")
        XCTAssertEqual(refusal(Data(#"{"pad":"x"}"#.utf8)), .invalidEnvelope, "no unknown top-level key")
        XCTAssertEqual(refusal(Data(#"{"ext":"x"}"#.utf8)), .invalidEnvelope, "ext is an object")
    }

    // MARK: The bus's fixtures (Lead 01:36, CBUS-19 owner's gate row)

    /// The bus's own examples (constellation-bus main 06c0522, CBUS-23,
    /// schema/hosttransport-examples-large.ndjson, vendored under
    /// Fixtures/hosttransport): every envelope a send or hold carries, and the
    /// rejected arrival, is decoded as the receiving adapter would (base64
    /// undone, body_overhead taken as overhead, the other headers passed
    /// through as the sender wrote them) and measured here. Each outcome, refusal code and stated byte count must
    /// match the bus's. Every disagreeing line is listed.
    func testTheBusFixturesMeasureAsTheBusExpects() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/hosttransport/hosttransport-examples-large.ndjson")
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        // Sizes the bus states in its comments, by the line of the envelope.
        let stated: [Int: [(what: String, bytes: Int)]] = [
            18: [("envelope", 65_536)],                    // line 15: "65,536 bytes: delivered"
            22: [("envelope", 65_536), ("body", 2), ("topic", 1)],  // lines 20-21
            26: [("envelope", 65_536)],                    // lines 24-25: "at 65,536 delivered"
            32: [("envelope", 65_536)],                    // line 30: "1 ... at 65,536 are delivered"
            34: [("envelope", 65_536)],                    // line 30: "-(2^53-1) at 65,536"
            45: [("envelope", 65_536)],                    // line 44: "at 65,536 with it, delivered"
            48: [("body", 3_000)],                         // line 47: "its decoded 3,000 bytes count"
            50: [("body", 3_000)],                         // line 47
            54: [("envelope", 65_536)],                    // lines 52-53: "65,536 is delivered"
            59: [("body", 4_096)],                         // line 58: "the original is 4,096"
            62: [("topic", 256)],                          // line 61: "the original topic is 256"
            71: [("body", 4_608)],                         // lines 64-65: "to a 4,608-byte body"
        ]
        var disagreements: [String] = []
        var checked = 0
        var seen: Set<Int> = []
        for (index, line) in lines.enumerated() {
            let number = index + 1
            var envelopeJSON: Data?
            var expectedCode: String?
            var expectedMessage = ""
            if line.hasPrefix("C: "), let request = json(line.dropFirst(3)),
               ["send", "hold"].contains(request["method"] as? String ?? ""),
               let params = request["params"] as? NSDictionary, let carried = params["envelope"] as? String,
               index + 1 < lines.count, let reply = json(lines[index + 1].dropFirst(3)),
               let result = reply["result"] as? NSDictionary {
                envelopeJSON = Data(carried.utf8)
                expectedCode = result["outcome"] as? String == "delivered" ? nil : (result["code"] as? String ?? "?")
                expectedMessage = result["message"] as? String ?? ""
            } else if line.hasPrefix("D: "), let frame = json(line.dropFirst(3)), frame["frame"] as? String == "rejected",
                      let raw = (frame["raw"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                envelopeJSON = raw
                expectedCode = frame["code"] as? String
            }
            guard let envelopeJSON else { continue }
            checked += 1
            seen.insert(number)
            guard let e = busEnvelope(envelopeJSON) else {
                disagreements.append("line \(number): ours could not decode the envelope")
                continue
            }
            let ours = HostEnvelopeAdmission.refusal(e)?.rawValue
            if ours != expectedCode {
                disagreements.append("line \(number): outcome ours \(ours ?? "delivered") vs bus \(expectedCode ?? "delivered")")
            }
            var sizes: [(what: String, bytes: Int)] = []
            for what in ["envelope", "body", "topic"] {
                if let match = expectedMessage.range(of: "\(what) is [0-9]+ bytes", options: .regularExpression) {
                    let digits = expectedMessage[match].split(separator: " ")[2]
                    sizes.append((what, Int(digits)!))
                }
            }
            sizes += stated[number] ?? []
            for size in sizes {
                let ourBytes: Int
                switch size.what {
                case "envelope": ourBytes = e.originalBytes
                case "body": ourBytes = e.body.count - e.bodyOverhead
                default: ourBytes = (e.topic?.count ?? 0) - e.bodyOverhead
                }
                if ourBytes != size.bytes {
                    disagreements.append("line \(number): \(size.what) ours \(ourBytes) vs bus \(size.bytes)")
                }
            }
        }
        XCTAssertEqual(checked, 23, "21 sends, one hold and one rejected arrival")
        XCTAssertEqual(Set(stated.keys).subtracting(seen), [], "every stated size names an envelope line")
        XCTAssertEqual(disagreements, [], disagreements.joined(separator: "; "))
    }

    private func json<S: StringProtocol>(_ text: S) -> NSDictionary? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
    }

    /// A bus envelope as the receiving adapter decodes it: routing fields,
    /// body and topic (base64 undone where ext.c11h.encoding says so),
    /// body_overhead as overhead, and the other v1 headers as passthrough.
    private func busEnvelope(_ data: Data) -> HostEnvelope? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let id = object["id"] as? String, let from = object["from"] as? String,
              let body = object["body"] as? String else { return nil }
        let c11 = (object["ext"] as? NSDictionary)?["c11h"] as? NSDictionary
        let encoding = c11?["encoding"] as? NSDictionary
        func bytes(_ field: String, _ text: String) -> Data? {
            encoding?[field] as? String == "base64" ? Data(base64Encoded: text) : Data(text.utf8)
        }
        guard let bodyBytes = bytes("body", body) else { return nil }
        let topic = (object["topic"] as? String).flatMap { bytes("topic", $0) }
        // The other headers exactly as the sender wrote them: re-encoding would
        // turn a sender's 1.0 into 1 and hide it from the number policy.
        guard let members = topLevelMembers(data) else { return nil }
        let headerKeys: Set<String> = ["version", "ts", "urgent", "ttl_seconds", "content_type", "ext"]
        var passthrough = Data("{".utf8)
        for (key, raw) in members where headerKeys.contains(key) {
            if passthrough.count > 1 { passthrough.append(Data(",".utf8)) }
            passthrough.append(Data("\"\(key)\":".utf8))
            passthrough.append(raw)
        }
        passthrough.append(Data("}".utf8))
        return HostEnvelope(id: id, from: from, to: object["to"] as? String, replyTo: object["reply_to"] as? String,
                            inReplyTo: object["in_reply_to"] as? String, body: bodyBytes, topic: topic,
                            hasBodyRef: object["body_ref"] != nil, passthrough: passthrough,
                            bodyOverhead: (c11?["body_overhead"] as? NSNumber)?.intValue ?? 0)
    }

    /// The raw bytes of each top-level member of a JSON object, unparsed.
    private func topLevelMembers(_ data: Data) -> [(key: String, raw: Data)]? {
        let b = [UInt8](data)
        var i = 0
        func skipSpace() { while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 } }
        func skipString() -> Bool {
            guard i < b.count, b[i] == 0x22 else { return false }
            i += 1
            while i < b.count {
                if b[i] == 0x5C { i += 2; continue }
                if b[i] == 0x22 { i += 1; return true }
                i += 1
            }
            return false
        }
        func skipValue() -> Bool {
            guard i < b.count else { return false }
            if b[i] == 0x22 { return skipString() }
            if b[i] == 0x7B || b[i] == 0x5B {
                var depth = 0
                while i < b.count {
                    if b[i] == 0x22 { guard skipString() else { return false }; continue }
                    if b[i] == 0x7B || b[i] == 0x5B { depth += 1 }
                    if b[i] == 0x7D || b[i] == 0x5D { depth -= 1; if depth == 0 { i += 1; return true } }
                    i += 1
                }
                return false
            }
            while i < b.count, ![0x2C, 0x7D, 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
            return true
        }
        skipSpace()
        guard i < b.count, b[i] == 0x7B else { return nil }
        i += 1
        var members: [(key: String, raw: Data)] = []
        while true {
            skipSpace()
            if i < b.count, b[i] == 0x7D { return members }
            let keyStart = i
            guard skipString(),
                  let key = try? JSONSerialization.jsonObject(with: Data(b[keyStart..<i]), options: .fragmentsAllowed) as? String
            else { return nil }
            skipSpace()
            guard i < b.count, b[i] == 0x3A else { return nil }
            i += 1
            skipSpace()
            let valueStart = i
            guard skipValue() else { return nil }
            members.append((key, Data(b[valueStart..<i])))
            skipSpace()
            if i < b.count, b[i] == 0x2C { i += 1; continue }
            guard i < b.count, b[i] == 0x7D else { return nil }
            return members
        }
    }

    func testTheIdIsAnUppercaseULID() {
        let id = HostTransportTestIDs.make()
        XCTAssertNil(HostEnvelopeAdmission.refusal(e(id: id)))
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(id: "01abcdefghjkmnpqrstvwxyz01")), .invalidEnvelope)
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(id: id + "\n")), .invalidEnvelope, "no trailing newline")
    }

    func testFromIsAtMost256Characters() {
        XCTAssertNil(HostEnvelopeAdmission.refusal(e(from: at)), "counted in code points, not bytes")
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(from: over)), .invalidEnvelope)
    }

    func testToIsAtMost256Characters() {
        XCTAssertNil(HostEnvelopeAdmission.refusal(e(to: at)))
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(to: over)), .invalidEnvelope)
    }

    func testReplyToIsAtMost256Characters() {
        XCTAssertNil(HostEnvelopeAdmission.refusal(e(replyTo: at)))
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(replyTo: over)), .invalidEnvelope)
    }

    func testAdmissionReadsHeadersAndLengthsOnly() {
        let id = HostTransportTestIDs.make()
        func e(_ body: Data, topic: Data? = nil, to: String? = "id:r", ref: Bool = false, id: String = id) -> HostEnvelope {
            HostEnvelope(id: id, from: "id:s", to: to, body: body, topic: topic, hasBodyRef: ref)
        }
        XCTAssertNil(HostEnvelopeAdmission.refusal(e(Data(repeating: 0xFF, count: 4096))), "any bytes, at the bound")
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(Data(count: 4097))), .envelopeTooLarge)
        let sealedAtBound = HostEnvelope(id: id, from: "id:s", to: "id:r", body: Data(count: 4096 + 28), bodyOverhead: 28)
        XCTAssertNil(HostEnvelopeAdmission.refusal(sealedAtBound), "a sealing layer's overhead is not counted")
        let sealedOver = HostEnvelope(id: id, from: "id:s", to: "id:r", body: Data(count: 4097 + 28), bodyOverhead: 28)
        XCTAssertEqual(HostEnvelopeAdmission.refusal(sealedOver), .envelopeTooLarge)
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(Data(), topic: Data(count: 257))), .envelopeTooLarge)
        // A6 Amendment 2: the canonical (RFC 8785) length of the original envelope v1.
        let bare = HostEnvelope(id: id, from: "id:s", to: "id:r", body: Data())
        XCTAssertEqual(bare.originalBytes, #"{"version":1,"id":"\#(id)","from":"id:s","to":"id:r","body":""}"#.utf8.count,
                       "every byte of the JSON, and version always counts")
        func padded(_ n: Int) -> HostEnvelope {
            HostEnvelope(id: id, from: "id:s", to: "id:r", body: Data("0123456789".utf8),
                         passthrough: Data(#"{"ext":{"pad":"\#(String(repeating: "x", count: n))"}}"#.utf8))
        }
        let base = padded(0).originalBytes
        let atBound = padded(65_536 - base)
        XCTAssertEqual(atBound.originalBytes, 65_536)
        XCTAssertNil(HostEnvelopeAdmission.refusal(atBound))
        XCTAssertEqual(HostEnvelopeAdmission.refusal(padded(65_537 - base)), .envelopeTooLarge, "a large ext is refused")
        let sealed = atBound.replacingOpaque(body: Data(count: 10 + 28), topic: nil, bodyOverhead: 28)
        XCTAssertEqual(sealed.originalBytes, 65_536, "sealing never changes the original size")
        XCTAssertNil(HostEnvelopeAdmission.refusal(sealed))
        let stamped = HostEnvelope(id: id, from: "id:s", to: "id:r", body: Data("0123456789".utf8),
                                   passthrough: atBound.passthrough, stamps: ["origin_host": "studio", "machine": "studio"])
        XCTAssertEqual(stamped.originalBytes, 65_536, "stamps are not counted")
        let panel = UUID()
        let withState = HostEnvelope(id: id, from: "id:s", to: "id:r", body: Data(),
                                     state: .init(panel: panel, key: "flag", seq: 12))
        XCTAssertEqual(withState.originalBytes,
                       #"{"version":1,"id":"\#(id)","from":"id:s","to":"id:r","body":"","ext":{"c11h":{"state":{"panel":"\#(panel.uuidString)","key":"flag","seq":12}}}}"#.utf8.count,
                       "the sender's ext.c11h.state is part of the original")
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(Data(), to: nil)), .topicOnlyCrossHost)
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(Data(), to: "")), .topicOnlyCrossHost)
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(Data(), ref: true)), .bodyRefCrossHost)
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(Data(), id: "01ABC")), .invalidEnvelope)
        XCTAssertEqual(HostEnvelopeAdmission.refusal(e(Data(), id: String(repeating: "U", count: 26))), .invalidEnvelope,
                       "U is not Crockford base32")
    }
}
