import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// C11H-330: evaporating flags. The kind field and its JSON, the CLI parse, the
// registry's compatibility with older builds, the flag's display-only copy,
// the lower's provenance, and the pure tracker behind the controller.
final class FlagEvaporationTests: XCTestCase {

    // MARK: Kind field

    func testEvaporateSecondsRoundTripsUnderItsSnakeCaseKey() throws {
        let kind = PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: "🔥", evaporateSeconds: 5)
        let encoded = try JSONEncoder().encode(kind)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["evaporate_seconds"] as? Int, 5)
        XCTAssertNil(object["evaporateSeconds"])
        XCTAssertEqual(PanelFlagKind.fromJSON(object)?.evaporateSeconds, 5)
        XCTAssertEqual(try JSONDecoder().decode(PanelFlagKind.self, from: encoded), kind)
        XCTAssertEqual(kind.registryJSONObject["evaporate_seconds"] as? Int, 5)

        let never = PanelFlagKind(id: "plain", name: "Plain", color: .teal, emoji: nil)
        let neverObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(never)) as? [String: Any])
        XCTAssertNil(neverObject["evaporate_seconds"], "absent means never; the key is omitted")
        XCTAssertTrue(never.registryJSONObject["evaporate_seconds"] is NSNull, "flag.kind.list says null")
    }

    func testFlagCopyCarriesDisplayFieldsOnly() {
        let kind = PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: "🔥", evaporateSeconds: 5)
        XCTAssertNil(kind.jsonObject["evaporate_seconds"])
        XCTAssertNil(kind.displaySnapshot.evaporateSeconds)
        XCTAssertEqual(kind.displaySnapshot, PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: "🔥"))
    }

    func testEvaporateSecondsBounds() {
        func kind(_ seconds: Int?) -> PanelFlagKind {
            PanelFlagKind(id: "k", name: "K", color: .green, emoji: nil, evaporateSeconds: seconds)
        }
        XCTAssertTrue(kind(nil).isValid)
        XCTAssertTrue(kind(1).isValid)
        XCTAssertTrue(kind(600).isValid)
        XCTAssertFalse(kind(0).isValid)
        XCTAssertFalse(kind(601).isValid)
        XCTAssertFalse(kind(-5).isValid)
    }

    func testFromJSONTreatsAnUnreadableValueAsAnUnreadableEntry() {
        let base: [String: Any] = ["id": "k", "name": "K", "color": "green"]
        func read(_ value: Any) -> PanelFlagKind? {
            var object = base
            object["evaporate_seconds"] = value
            return PanelFlagKind.fromJSON(object)
        }
        XCTAssertEqual(read(30)?.evaporateSeconds, 30)
        XCTAssertNotNil(read(NSNull()), "null means never")
        XCTAssertNil(read(NSNull())?.evaporateSeconds)
        XCTAssertNil(read(0))
        XCTAssertNil(read(9_999))
        XCTAssertNil(read("5"))
        XCTAssertNil(read(true))
        XCTAssertNil(read(2.5))
    }

    // MARK: CLI

    func testEvaporateSecondsArgumentParse() {
        XCTAssertEqual(PanelFlagKind.parseEvaporateSecondsArgument("1"), 1)
        XCTAssertEqual(PanelFlagKind.parseEvaporateSecondsArgument("600"), 600)
        XCTAssertEqual(PanelFlagKind.parseEvaporateSecondsArgument(" 5 "), 5)
        for bad in ["", "0", "601", "abc", "5.0", "-3", "+3", "5s", "٣"] {
            XCTAssertNil(PanelFlagKind.parseEvaporateSecondsArgument(bad), bad)
        }
    }

    // MARK: Registry compatibility

    private func makeRegistry() -> (PanelFlagKindRegistry, UserDefaults, String) {
        let suite = "c11.tests.flag-evaporation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PanelFlagKindRegistry(defaults: defaults), defaults, suite)
    }

    private func storedEntries(_ defaults: UserDefaults) throws -> [[String: Any]] {
        let data = try XCTUnwrap(defaults.data(forKey: PanelFlagKindRegistry.storageKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    /// The shape c11 1.8.1 decodes: the same storage key, read as one array
    /// with synthesized Codable (which ignores keys it doesn't declare).
    private struct OneEightOneFlagKind: Codable {
        let id: String
        let name: String
        let color: String
        let emoji: String?
    }

    func testOlderBuildsKeepAKindThatEvaporates() throws {
        let (registry, defaults, suite) = makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        try registry.set(PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: "🔥", evaporateSeconds: 5))

        // c11 1.8.1 (same defaults domain as this build) decodes the whole array.
        let data = try XCTUnwrap(defaults.data(forKey: PanelFlagKindRegistry.storageKey))
        let oneX = try JSONDecoder().decode([OneEightOneFlagKind].self, from: data)
        XCTAssertTrue(oneX.contains { $0.id == "token-burn" && $0.color == "orange" })

        // h16 reads each entry on its own: id, name and a known color as strings,
        // emoji absent or a string. Extra keys are not looked at.
        let entry = try XCTUnwrap(try storedEntries(defaults).first { $0["id"] as? String == "token-burn" })
        XCTAssertNotNil(entry["name"] as? String)
        XCTAssertNotNil((entry["color"] as? String).flatMap(PanelFlagColorToken.init(rawValue:)))
        XCTAssertTrue(entry["emoji"] == nil || entry["emoji"] is String)
        XCTAssertEqual(entry["evaporate_seconds"] as? Int, 5)
    }

    func testWriteKeepsFieldsALaterBuildAdded() throws {
        let (registry, defaults, suite) = makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let later: [[String: Any]] = [
            ["id": "token-burn", "name": "Token Burn", "color": "orange", "evaporate_seconds": 5, "sound": "ping"],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: later), forKey: PanelFlagKindRegistry.storageKey)

        // An edit to another kind leaves the later field in place.
        try registry.set(PanelFlagKind(id: "other", name: "Other", color: .teal, emoji: nil))
        var tokenBurn = try XCTUnwrap(try storedEntries(defaults).first { $0["id"] as? String == "token-burn" })
        XCTAssertEqual(tokenBurn["sound"] as? String, "ping")

        // So does an edit to that kind itself.
        try registry.set(PanelFlagKind(id: "token-burn", name: "Burn", color: .orange, emoji: nil, evaporateSeconds: 5))
        tokenBurn = try XCTUnwrap(try storedEntries(defaults).first { $0["id"] as? String == "token-burn" })
        XCTAssertEqual(tokenBurn["sound"] as? String, "ping")
        XCTAssertEqual(tokenBurn["name"] as? String, "Burn")
    }

    func testClearingEvaporateSecondsRemovesTheKey() throws {
        let (registry, defaults, suite) = makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        try registry.set(PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: nil, evaporateSeconds: 5))
        try registry.set(PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: nil))
        let entry = try XCTUnwrap(try storedEntries(defaults).first { $0["id"] as? String == "token-burn" })
        XCTAssertNil(entry["evaporate_seconds"], "a known key is never carried over from the stored entry")
        XCTAssertNil(registry.kind(id: "token-burn")?.evaporateSeconds)
    }

    func testAValueOutsideThisBuildsRangeIsKeptVerbatim() throws {
        let (registry, defaults, suite) = makeRegistry()
        defer { defaults.removePersistentDomain(forName: suite) }
        let later: [[String: Any]] = [
            ["id": "slow", "name": "Slow", "color": "lime", "evaporate_seconds": 1_200],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: later), forKey: PanelFlagKindRegistry.storageKey)
        XCTAssertNil(registry.kind(id: "slow"))
        try registry.set(PanelFlagKind(id: "other", name: "Other", color: .teal, emoji: nil))
        let slow = try XCTUnwrap(try storedEntries(defaults).first { $0["id"] as? String == "slow" })
        XCTAssertEqual(slow["evaporate_seconds"] as? Int, 1_200)
    }

    // MARK: The flag's copy

    func testAReRaiseWithTheSameReasonStaysUnchanged() throws {
        let store = PanelMetadataStore.shared
        let workspace = UUID()
        let surface = UUID()
        defer { store.removeSurface(workspaceId: workspace, surfaceId: surface) }
        let kind = PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: "🔥", evaporateSeconds: 5)

        let raised = try store.mutateAttention(workspaceId: workspace, surfaceId: surface, flag: .raise("Burning", kind: kind))
        XCTAssertEqual(raised.result.applied[MetadataKey.flag], true)
        XCTAssertNil(raised.after.flagKind?.evaporateSeconds)
        let stored = store.getMetadata(workspaceId: workspace, surfaceId: surface).metadata[MetadataKey.flagKind] as? [String: Any]
        XCTAssertNil(stored?["evaporate_seconds"])

        let again = try store.mutateAttention(workspaceId: workspace, surfaceId: surface, flag: .raise("Burning", kind: kind))
        XCTAssertEqual(again.result.applied[MetadataKey.flag], false, "the registry's behavior field is not a change to the flag")
        XCTAssertEqual(again.after.flagRaisedAt, raised.after.flagRaisedAt)
    }

    // MARK: Provenance

    func testEvaporatedLowerCarriesItsCause() {
        let evaporated = EventEmitter.flagLoweredPayload(by: .c11, answer: nil, cause: .evaporated)
        XCTAssertEqual(evaporated["by"] as? String, "c11")
        XCTAssertEqual(evaporated["cause"] as? String, "evaporated")

        let operatorLower = EventEmitter.flagLoweredPayload(by: .operator, answer: nil, cause: nil)
        XCTAssertEqual(operatorLower["by"] as? String, "operator")
        XCTAssertNil(operatorLower["cause"], "an operator's lower keeps its existing shape")
    }

    // MARK: Target

    private let workspace = UUID()
    private let panelA = UUID()
    private let panelB = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_000)
    private let tokenBurn = PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: "🔥", evaporateSeconds: 3)

    private func attention(_ surface: UUID, reason: String? = "Burning", kind: PanelFlagKind? = nil, at: Date? = nil) -> PanelAttentionSnapshot {
        PanelAttentionSnapshot(
            workspaceId: workspace,
            surfaceId: surface,
            flagReason: reason,
            flagKind: reason == nil ? nil : (kind ?? tokenBurn.displaySnapshot),
            flagRaisedAt: reason == nil ? nil : (at ?? epoch),
            delegated: false
        )
    }

    func testResolveNeedsASeenFlaggedPanelOfAnEvaporatingKind() {
        let seenA = (workspaceId: workspace, surfaceId: panelA)
        let target = FlagEvaporationTarget.resolve(seen: seenA, attention: attention(panelA), registryKind: tokenBurn)
        XCTAssertEqual(target?.seconds, 3)
        XCTAssertEqual(target?.flagEpoch, epoch)
        XCTAssertEqual(target?.surfaceId, panelA)
        XCTAssertEqual(target?.color, .orange, "the bar takes the flag's own color")

        XCTAssertNil(FlagEvaporationTarget.resolve(seen: nil, attention: attention(panelA), registryKind: tokenBurn),
                     "not looked at")
        XCTAssertNil(FlagEvaporationTarget.resolve(seen: seenA, attention: attention(panelB), registryKind: tokenBurn),
                     "the flag is on another panel")
        XCTAssertNil(FlagEvaporationTarget.resolve(seen: seenA, attention: attention(panelA, reason: nil), registryKind: tokenBurn),
                     "not flagged")
        let generic = PanelAttentionSnapshot(workspaceId: workspace, surfaceId: panelA, flagReason: "Look", flagRaisedAt: epoch, delegated: false)
        XCTAssertNil(FlagEvaporationTarget.resolve(seen: seenA, attention: generic, registryKind: tokenBurn),
                     "a generic flag has no kind")
        XCTAssertNil(FlagEvaporationTarget.resolve(seen: seenA, attention: attention(panelA), registryKind: nil),
                     "the kind is no longer registered")
        let steady = PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: nil)
        XCTAssertNil(FlagEvaporationTarget.resolve(seen: seenA, attention: attention(panelA), registryKind: steady),
                     "the kind does not evaporate")
        let otherKind = PanelFlagKind(id: "other", name: "Other", color: .teal, emoji: nil, evaporateSeconds: 3)
        XCTAssertNil(FlagEvaporationTarget.resolve(seen: seenA, attention: attention(panelA), registryKind: otherKind),
                     "the registry entry must be the flag's own kind")
    }

    // MARK: Tracker

    private func target(_ surface: UUID, reason: String = "Burning", at: Date? = nil, seconds: Int = 3) -> FlagEvaporationTarget {
        FlagEvaporationTarget(workspaceId: workspace, surfaceId: surface, flagEpoch: at ?? epoch,
                              flagReason: reason, kindId: "token-burn", color: .orange, seconds: seconds)
    }

    func testRunStartsOnLookAndKeepsItsStartWhileLooking() {
        var tracker = FlagEvaporationTracker()
        let t0 = Date(timeIntervalSince1970: 10_000)
        guard case .start(let run, let replacing) = tracker.update(target: target(panelA), now: t0) else {
            return XCTFail("a seen evaporating flag starts a run")
        }
        XCTAssertNil(replacing)
        XCTAssertEqual(run.startedAt, t0)
        XCTAssertEqual(run.deadline, t0.addingTimeInterval(3))
        XCTAssertEqual(tracker.update(target: target(panelA), now: t0.addingTimeInterval(1)), .keep(run))
        XCTAssertEqual(tracker.run?.startedAt, t0)
    }

    func testLeavingResetsInsteadOfPausing() {
        var tracker = FlagEvaporationTracker()
        let t0 = Date(timeIntervalSince1970: 10_000)
        _ = tracker.update(target: target(panelB), now: t0)
        guard case .cancel = tracker.update(target: nil, now: t0.addingTimeInterval(2)) else {
            return XCTFail("leaving empties the bar")
        }
        XCTAssertNil(tracker.run)
        XCTAssertEqual(tracker.update(target: nil, now: t0.addingTimeInterval(3)), .idle)
        let back = t0.addingTimeInterval(4)
        guard case .start(let run, _) = tracker.update(target: target(panelB), now: back) else {
            return XCTFail("returning starts again")
        }
        XCTAssertEqual(run.startedAt, back, "the timer restarts from zero")
        XCTAssertNil(tracker.takeDue(now: back.addingTimeInterval(2)), "a paused timer would be due here (2 s + 2 s of looking)")
    }

    func testMovingToAnotherFlaggedPanelRestarts() {
        var tracker = FlagEvaporationTracker()
        let t0 = Date(timeIntervalSince1970: 10_000)
        _ = tracker.update(target: target(panelA), now: t0)
        guard case .start(let run, let replacing) = tracker.update(target: target(panelB), now: t0.addingTimeInterval(1)) else {
            return XCTFail("another panel starts its own run")
        }
        XCTAssertEqual(replacing?.target.surfaceId, panelA)
        XCTAssertEqual(run.target.surfaceId, panelB)
    }

    func testAReRaiseOrAChangedKindRestarts() {
        let t0 = Date(timeIntervalSince1970: 10_000)
        for changed in [
            target(panelA, at: epoch.addingTimeInterval(60)),
            target(panelA, reason: "Still burning"),
            target(panelA, seconds: 10),
        ] {
            var tracker = FlagEvaporationTracker()
            _ = tracker.update(target: target(panelA), now: t0)
            guard case .start(let run, let replacing) = tracker.update(target: changed, now: t0.addingTimeInterval(2)) else {
                return XCTFail("a re-raise restarts: \(changed)")
            }
            XCTAssertNotNil(replacing)
            XCTAssertEqual(run.startedAt, t0.addingTimeInterval(2))
        }
    }

    func testDueOnlyAtTheDeadlineAndThenNoCancel() {
        var tracker = FlagEvaporationTracker()
        let t0 = Date(timeIntervalSince1970: 10_000)
        _ = tracker.update(target: target(panelA), now: t0)
        XCTAssertNil(tracker.takeDue(now: t0.addingTimeInterval(2.9)))
        XCTAssertNotNil(tracker.run, "an early check keeps the run")
        let due = tracker.takeDue(now: t0.addingTimeInterval(3))
        XCTAssertEqual(due?.target.flagEpoch, epoch, "the lower is guarded by the epoch the run started on")
        XCTAssertNil(tracker.run)
        XCTAssertEqual(tracker.update(target: nil, now: t0.addingTimeInterval(3.1)), .idle,
                       "the lower that follows reads as no run, so the fade is not cut short")
    }

    // MARK: Repair 1

    /// Manual timers: `fireDue` runs what the controller scheduled up to `now`.
    @MainActor
    private final class FakeTimers {
        final class Item {
            let deadline: Date
            let fire: @MainActor () -> Void
            var cancelled = false
            init(deadline: Date, fire: @escaping @MainActor () -> Void) { self.deadline = deadline; self.fire = fire }
        }
        private(set) var items: [Item] = []

        func schedule(_ deadline: Date, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
            let item = Item(deadline: deadline, fire: fire)
            items.append(item)
            return { item.cancelled = true }
        }

        func fireDue(_ now: Date) {
            for item in items where !item.cancelled && item.deadline <= now {
                item.cancelled = true
                item.fire()
            }
        }
    }

    private final class Clock { var now = Date(timeIntervalSince1970: 50_000) }

    /// Records what the controller asks of a panel view.
    @MainActor
    private final class FakeBarHost: FlagEvaporationBarHost {
        private(set) var starts: [(duration: TimeInterval, elapsed: TimeInterval)] = []
        private(set) var cancels = 0
        private(set) var fades = 0
        func startEvaporationBar(color: NSColor, duration: TimeInterval, elapsed: TimeInterval) {
            starts.append((duration, elapsed))
        }
        func cancelEvaporationBar() { cancels += 1 }
        func prepareEvaporationFade() {}
        func evaporationLowered() { fades += 1 }
    }

    @MainActor
    private func controller(
        seen: (UUID, UUID)?,
        kind: PanelFlagKind,
        clock: Clock,
        timers: FakeTimers,
        active: Bool = true,
        barHost: @escaping @MainActor (FlagEvaporationTarget) -> FlagEvaporationBarHost? = { _ in nil }
    ) -> FlagEvaporationController {
        FlagEvaporationController(hooks: .init(
            seenPanel: { seen.map { (workspaceId: $0.0, surfaceId: $0.1) } },
            isSeen: { $0 == seen?.1 },
            registryKind: { $0 == kind.id ? kind : nil },
            now: { clock.now },
            schedule: { timers.schedule($0, $1) },
            barHost: barHost,
            afterLower: { _ in }
        ), active: active)
    }

    /// Astra on #332: a markdown panel's renderer, or a browser's portal
    /// slot, can mount after the seen refresh that starts the run. The bar
    /// arrives with its host, at the progress already made; the run keeps its
    /// start and deadline, with no leave-and-return or re-raise.
    @MainActor
    func testAHostThatMountsMidRunShowsTheRunningBar() throws {
        // The bar's colour reads NSApp's appearance for a host that is not a
        // view; the bare logic runner has no NSApp until something creates it.
        _ = NSApplication.shared
        let workspace = UUID(), panel = UUID()
        let kind = PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: "🔥", evaporateSeconds: 3)
        let clock = Clock(), timers = FakeTimers()
        var mounted: FakeBarHost?
        let evaporation = controller(seen: (workspace, panel), kind: kind, clock: clock, timers: timers,
                                     barHost: { _ in mounted })
        let service = PanelAttentionService(feedProjection: FeedProjectionBridge(), evaporation: evaporation)
        defer { service.remove(workspaceId: workspace, surfaceId: panel) }
        let raisedAt = clock.now

        try service.raise(workspaceId: workspace, surfaceId: panel, reason: "Burning", kind: kind, by: .agent, title: nil)
        let run = try XCTUnwrap(evaporation.currentRun, "the run starts with no host to show it")

        evaporation.barHostDidMount() // still no host: nothing to show, nothing breaks

        clock.now = raisedAt.addingTimeInterval(1)
        let first = FakeBarHost()
        mounted = first
        evaporation.attentionDidChange(surfaceId: panel)
        XCTAssertEqual(first.starts.count, 1, "a later evaluation of the unchanged run shows the bar on the new host")
        XCTAssertEqual(first.starts.first?.duration, 3)
        XCTAssertEqual(first.starts.first?.elapsed ?? -1, 1, accuracy: 0.0001, "at the second already looked at")
        XCTAssertEqual(evaporation.currentRun, run, "start and deadline unchanged")
        evaporation.barHostDidMount()
        evaporation.attentionDidChange(surfaceId: panel)
        XCTAssertEqual(first.starts.count, 1, "the host already showing it is left alone")

        clock.now = raisedAt.addingTimeInterval(2)
        let replacement = FakeBarHost()
        mounted = replacement
        evaporation.attentionDidChange(surfaceId: panel)
        XCTAssertEqual(replacement.starts.count, 0, "an evaluation keeps a host that still exists")
        evaporation.barHostDidMount()
        XCTAssertEqual(first.cancels, 1, "the replaced host empties its bar")
        XCTAssertEqual(replacement.starts.first?.elapsed ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(evaporation.currentRun, run)

        clock.now = raisedAt.addingTimeInterval(3)
        timers.fireDue(clock.now)
        XCTAssertFalse(PanelAttentionIndex.shared.snapshot(workspaceId: workspace, surfaceId: panel).isFlagged,
                       "lowered at the original deadline")
        XCTAssertEqual(replacement.fades, 1, "the host showing the sweep fades it")
        XCTAssertEqual(first.fades, 0)
    }

    /// Ruled: "a re-raise while focused restarts the timer", identical text
    /// included (burnwatch re-raises token-burn with the same reason).
    @MainActor
    func testAnIdenticalReRaiseRestartsTheRun() throws {
        let workspace = UUID(), panel = UUID()
        let kind = PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: "🔥", evaporateSeconds: 3)
        let clock = Clock(), timers = FakeTimers()
        let evaporation = controller(seen: (workspace, panel), kind: kind, clock: clock, timers: timers)
        let bridge = FeedProjectionBridge()
        let service = PanelAttentionService(feedProjection: bridge, evaporation: evaporation)
        defer { service.remove(workspaceId: workspace, surfaceId: panel) }
        func flagged() -> Bool { PanelAttentionIndex.shared.snapshot(workspaceId: workspace, surfaceId: panel).isFlagged }
        let raisedAt = clock.now

        try service.raise(workspaceId: workspace, surfaceId: panel, reason: "Burning", kind: kind, by: .agent, title: nil)
        XCTAssertEqual(evaporation.currentRun?.deadline, raisedAt.addingTimeInterval(3), "a seen evaporating flag starts a run")

        clock.now = raisedAt.addingTimeInterval(2)
        let again = try service.raise(workspaceId: workspace, surfaceId: panel, reason: "Burning", kind: kind, by: .agent, title: nil)
        XCTAssertEqual(again.applied[MetadataKey.flag], false, "the store stays idempotent")
        XCTAssertEqual(evaporation.currentRun?.deadline, raisedAt.addingTimeInterval(5), "the run restarts from the re-raise")

        clock.now = raisedAt.addingTimeInterval(3.5)
        timers.fireDue(clock.now)
        XCTAssertTrue(flagged(), "still raised past the original deadline")

        clock.now = raisedAt.addingTimeInterval(5.1)
        timers.fireDue(clock.now)
        XCTAssertFalse(flagged(), "lowered three seconds after the re-raise")
        let lowered = try XCTUnwrap(bridge.list(scope: .attention)["flag_lowered"] as? [String: Any])
        XCTAssertEqual(lowered["by"] as? String, "c11")
        XCTAssertEqual(lowered["cause"] as? String, "evaporated")
    }

    /// Design 5: the Feed tells an evaporation from an operator's lower, at
    /// every consumer: `feed.list`, the quick view's status line, `feed watch`.
    @MainActor
    func testTheFeedTellsAnEvaporationFromAnOperatorLower() throws {
        let workspace = UUID(), panel = UUID()
        let kind = PanelFlagKind(id: "token-burn", name: "Token Burn", color: .orange, emoji: "🔥", evaporateSeconds: 3)
        let inert = controller(seen: nil, kind: kind, clock: Clock(), timers: FakeTimers(), active: false)
        let bridge = FeedProjectionBridge()
        let service = PanelAttentionService(feedProjection: bridge, evaporation: inert)
        defer { service.remove(workspaceId: workspace, surfaceId: panel) }

        try service.raise(workspaceId: workspace, surfaceId: panel, reason: "Burning", kind: kind, by: .agent, title: nil)
        let listedFlagged = bridge.list(scope: .attention)
        try service.lower(workspaceId: workspace, surfaceId: panel, by: .operator)
        let byOperator = bridge.list(scope: .attention)
        let operatorLowered = try XCTUnwrap(byOperator["flag_lowered"] as? [String: Any])
        XCTAssertEqual(operatorLowered["by"] as? String, "operator")
        XCTAssertTrue(operatorLowered["cause"] is NSNull)
        XCTAssertNil(FeedQuickViewSnapshot(projection: bridge.snapshot(), now: Date()).evaporatedLine,
                     "the Feed says nothing for the operator's own lower")
        let operatorLine = try XCTUnwrap(FeedFlagLowered.cliLine(byOperator["flag_lowered"]))
        XCTAssertTrue(operatorLine.contains("by operator"))
        XCTAssertFalse(operatorLine.contains("evaporated"))
        XCTAssertTrue(FeedFlagLowered.feedListChanged(byOperator, listedFlagged))

        try service.raise(workspaceId: workspace, surfaceId: panel, reason: "Burning", kind: kind, by: .agent, title: nil)
        _ = bridge.list(scope: .attention)
        try service.lower(workspaceId: workspace, surfaceId: panel, by: .c11, cause: .evaporated)
        let evaporated = bridge.list(scope: .attention)
        let evaporatedLowered = try XCTUnwrap(evaporated["flag_lowered"] as? [String: Any])
        XCTAssertEqual(evaporatedLowered["by"] as? String, "c11")
        XCTAssertEqual(evaporatedLowered["cause"] as? String, "evaporated")
        XCTAssertEqual(evaporatedLowered["reason"] as? String, "Burning")
        XCTAssertEqual(FeedQuickViewSnapshot(projection: bridge.snapshot(), now: Date()).evaporatedLine,
                       "Evaporated: 🔥 Token Burn: Burning")
        XCTAssertTrue(try XCTUnwrap(FeedFlagLowered.cliLine(evaporated["flag_lowered"])).contains("by c11 (evaporated)"))
        XCTAssertTrue(FeedFlagLowered.feedListChanged(evaporated, byOperator),
                      "feed watch prints the evaporation even when the rows are the same")
        XCTAssertNil(FeedQuickViewSnapshot(projection: bridge.snapshot(), now: Date().addingTimeInterval(11 * 60)).evaporatedLine,
                     "the status line lets an old evaporation go")
    }

    /// C11H-359: who lowered a flag, why and its reason can come from another
    /// machine. `feed list` prints each control as `\xHH`, on one line.
    func testTheLoweredLinePrintsLinkedControlsAsText() throws {
        let controls = "\u{1B}]2;x\u{07}\u{1B}]9;y\u{07}\u{9B}31m\u{7F}\r\nz"
        func line(_ value: String) throws -> String {
            try XCTUnwrap(FeedFlagLowered.cliLine([
                "panel_id": "panel" + value, "by": "rigel" + value, "cause": "evaporated" + value,
                "reason": "Burning" + value, "lowered_at_ms": 0,
            ] as [String: Any], timeZone: TimeZone(identifier: "UTC")!))
        }
        let hostile = try line(controls), plain = try line(" plain")
        let scalars = hostile.unicodeScalars.map(\.value)
        XCTAssertFalse(scalars.contains { $0 < 0x20 || (0x7F...0x9F).contains($0) }, hostile)
        XCTAssertTrue(hostile.contains("by rigel\\x1B]2;x\\x07\\x1B]9;y\\x07\\x9B31m\\x7F\\x0D\\x0Az"), hostile)
        XCTAssertTrue(hostile.hasSuffix(": Burning\\x1B]2;x\\x07\\x1B]9;y\\x07\\x9B31m\\x7F\\x0D\\x0Az"), hostile)
        XCTAssertEqual(hostile.unicodeScalars.filter { $0 == "\n" }.count, plain.unicodeScalars.filter { $0 == "\n" }.count)
        XCTAssertEqual(plain, "last flag lowered: panel plain by rigel plain (evaporated plain) at 00:00:00: Burning plain",
                       "a plain value prints as before")
    }

    func testRestartKeepsTheTargetFromZero() {
        var tracker = FlagEvaporationTracker()
        let t0 = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(tracker.restart(now: t0), .idle, "nothing to restart")
        _ = tracker.update(target: target(panelA), now: t0)
        guard case .start(let run, let replacing) = tracker.restart(now: t0.addingTimeInterval(2)) else {
            return XCTFail("a restart starts again")
        }
        XCTAssertEqual(replacing?.startedAt, t0)
        XCTAssertEqual(run.target, target(panelA))
        XCTAssertEqual(run.deadline, t0.addingTimeInterval(5))
    }

    func testEveryEncodedKeyIsKnown() throws {
        let kind = PanelFlagKind(id: "k", name: "K", color: .green, emoji: "🔥", evaporateSeconds: 5)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(kind)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), PanelFlagKind.knownJSONKeys,
                       "a known key is never carried from a stored entry, so clearing it works")
    }

    @MainActor
    func testBarMountsOnTheTopEdgeAndStaysAboveItsHost() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let page = NSView(frame: host.bounds)
        host.addSubview(page)
        let mount = FlagEvaporationBarMount()
        mount.start(in: host, above: nil, color: .orange, duration: 3, elapsed: 0)
        let bar = try? XCTUnwrap(mount.bar)
        XCTAssertEqual(bar?.frame, NSRect(x: 0, y: 297, width: 400, height: 3), "top edge of an unflipped host")
        XCTAssertTrue(host.subviews.last === bar)
        XCTAssertEqual(bar?.modelProgress, 0, "a dropped sweep reads empty, never done")
        XCTAssertEqual(bar?.sweepStartProgress, 0, "a fresh run sweeps from empty")
        mount.start(in: host, above: nil, color: .orange, duration: 3, elapsed: 1.5)
        XCTAssertEqual(bar?.sweepStartProgress ?? -1, 0.5, accuracy: 0.0001, "a host that mounts mid-run shows the share already made")
        XCTAssertEqual(bar?.modelProgress, 0)

        let reAdded = NSView(frame: host.bounds)
        host.addSubview(reAdded)
        mount.keepAbove(reAdded, in: host)
        XCTAssertTrue(host.subviews.last === bar, "a re-added page goes under the bar")

        mount.cancel()
        XCTAssertEqual(bar?.isHidden, true)

        final class Flipped: NSView { override var isFlipped: Bool { true } }
        XCTAssertEqual(FlagEvaporationBarView.topEdgeFrame(in: NSRect(x: 0, y: 0, width: 400, height: 300), flipped: true),
                       NSRect(x: 0, y: 0, width: 400, height: 3))
        let flipped = Flipped(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let flippedMount = FlagEvaporationBarMount()
        flippedMount.start(in: flipped, above: nil, color: .cyan, duration: 3, elapsed: 0)
        XCTAssertEqual(flippedMount.bar?.frame, NSRect(x: 0, y: 0, width: 200, height: 3), "top edge of a flipped host")
    }
}
