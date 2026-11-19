import AppKit
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-126: the machine roster (store, colors, chip resolution, width) and
/// its socket methods.
final class MachineRosterTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "c11.machineRoster.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        drainMain() // land this test's queued roster writes before the suite goes
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Runs everything already queued on main, the roster's defaults writes included.
    private func drainMain() {
        let drained = expectation(description: "main drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 10)
    }

    func testSetStoresNormalizedFieldsAndPersistsAcrossInstances() throws {
        let roster = MachineRoster(defaults: defaults)
        let saved = try roster.set(id: " Studio ", name: .set("  Build Studio "), color: .set("3fa7d6"))
        XCTAssertEqual(saved, MachineRosterEntry(id: "studio", name: "Build Studio", color: "#3FA7D6"))

        drainMain() // the defaults write lands on main
        let reopened = MachineRoster(defaults: defaults)
        XCTAssertEqual(reopened.entry(id: "STUDIO"), saved)
        XCTAssertEqual(reopened.all().map(\.id), ["studio"])
    }

    func testFieldsChangeIndependentlyAndAnEmptyEntryIsRemoved() throws {
        let roster = MachineRoster(defaults: defaults)
        try roster.set(id: "local", name: .set("Laptop"), color: .keep)
        try roster.set(id: "local", name: .keep, color: .set("#11223344"))
        XCTAssertEqual(roster.entry(id: "local"), MachineRosterEntry(id: "local", name: "Laptop", color: "#11223344"))

        try roster.set(id: "local", name: .clear, color: .keep)
        XCTAssertEqual(roster.entry(id: "local"), MachineRosterEntry(id: "local", name: nil, color: "#11223344"))

        // An empty string clears too; with both fields unset the entry goes.
        let last = try roster.set(id: "local", name: .keep, color: .set(""))
        XCTAssertNil(last)
        XCTAssertNil(roster.entry(id: "local"))
        XCTAssertTrue(roster.all().isEmpty)
    }

    func testHereMeansThisMacAndInvalidInputIsRefusedWithoutWriting() {
        XCTAssertEqual(MachineRoster.normalizedID("here"), MachineRoster.localID)
        XCTAssertEqual(MachineRoster.normalizedID("LOCAL"), MachineRoster.localID)
        XCTAssertEqual(MachineRoster.normalizedID("prime-box.2"), "prime-box.2")
        XCTAssertNil(MachineRoster.normalizedID("studio/x"))
        XCTAssertNil(MachineRoster.normalizedID(""))

        let roster = MachineRoster(defaults: defaults)
        XCTAssertThrowsError(try roster.set(id: "studio", name: .keep, color: .set("blue"))) {
            XCTAssertEqual($0 as? MachineRosterError, .invalidColor)
        }
        XCTAssertThrowsError(try roster.set(id: "studio", name: .keep, color: .set("#12345"))) {
            XCTAssertEqual($0 as? MachineRosterError, .invalidColor)
        }
        XCTAssertThrowsError(try roster.set(id: "studio", name: .set("two\nlines"), color: .keep)) {
            XCTAssertEqual($0 as? MachineRosterError, .invalidName)
        }
        XCTAssertThrowsError(try roster.set(id: "studio", name: .set(String(repeating: "x", count: 49)), color: .keep)) {
            XCTAssertEqual($0 as? MachineRosterError, .invalidName)
        }
        XCTAssertThrowsError(try roster.set(id: "a b", name: .set("A"), color: .keep)) {
            XCTAssertEqual($0 as? MachineRosterError, .invalidID)
        }
        XCTAssertTrue(roster.all().isEmpty)
    }

    func testRemoveAndTheEntryCap() throws {
        let roster = MachineRoster(defaults: defaults)
        XCTAssertFalse(try roster.remove(id: "studio"))
        for index in 0..<MachineRoster.maxEntries {
            try roster.set(id: "m\(index)", name: .set("M\(index)"), color: .keep)
        }
        XCTAssertThrowsError(try roster.set(id: "one-more", name: .set("X"), color: .keep)) {
            XCTAssertEqual($0 as? MachineRosterError, .tooManyMachines)
        }
        XCTAssertTrue(try roster.remove(id: "m0"))
        XCTAssertNil(roster.entry(id: "m0"))
        XCTAssertEqual(roster.all().count, MachineRoster.maxEntries - 1)
    }

    func testChangesAnnounceOnlyWhenTheStoreChanges() throws {
        let roster = MachineRoster(defaults: defaults)
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: MachineRoster.didChangeNotification, object: roster, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        try roster.set(id: "studio", name: .set("Studio"), color: .keep)
        try roster.set(id: "studio", name: .set("Studio"), color: .keep)
        XCTAssertEqual(posts, 1)
        try roster.remove(id: "studio")
        XCTAssertEqual(posts, 2)
    }

    // C11H-300: UserDefaults notifies inside `set`, and a `queue: .main`
    // observer holds the writer until main runs it. The roster must not hold
    // its lock there, or a main-thread read deadlocks against the write. The
    // cache answers reads before the write lands.
    func testTheRosterStaysReadableWhileItsDefaultsNotify() throws {
        let roster = MachineRoster(defaults: defaults)
        var readable: [Bool] = []
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in
            let read = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = roster.all(); read.signal() }
            readable.append(read.wait(timeout: .now() + 5) == .success)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try roster.set(id: "studio", name: .set("Studio"), color: .keep)
        XCTAssertEqual(roster.entry(id: "studio")?.name, "Studio")
        XCTAssertTrue(try roster.remove(id: "studio"))
        drainMain()
        XCTAssertEqual(readable, [true, true])
        XCTAssertNil(MachineRoster(defaults: defaults).entry(id: "studio"))
    }

    // A change made on a socket worker is written to defaults on main.
    func testAChangeFromAWorkerIsPersistedOnMain() throws {
        let roster = MachineRoster(defaults: defaults)
        let persisted = expectation(description: "persisted")
        var onMain = false
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: nil
        ) { _ in
            onMain = Thread.isMainThread
            persisted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        DispatchQueue.global().async { _ = try? roster.set(id: "studio", name: .set("Studio"), color: .keep) }
        wait(for: [persisted], timeout: 10)
        XCTAssertTrue(onMain)
        XCTAssertEqual(MachineRoster(defaults: defaults).entry(id: "studio")?.name, "Studio")
    }

    // MARK: Colors

    func testHexParsingAndRoundTrip() throws {
        XCTAssertEqual(MachineRosterColor.normalized("#3fa7d6"), "#3FA7D6")
        XCTAssertEqual(MachineRosterColor.normalized("3FA7D680"), "#3FA7D680")
        XCTAssertNil(MachineRosterColor.normalized("#3FA"))
        XCTAssertNil(MachineRosterColor.normalized("#GGGGGG"))
        let color = try XCTUnwrap(MachineRosterColor.nsColor("#3FA7D6"))
        XCTAssertEqual(MachineRosterColor.hex(from: color), "#3FA7D6")
        let translucent = try XCTUnwrap(MachineRosterColor.nsColor("#3FA7D680"))
        XCTAssertEqual(MachineRosterColor.hex(from: translucent), "#3FA7D680")
    }

    func testTextContrastFollowsTheTintAndTheAppearance() {
        let light = (r: 0.93, g: 0.93, b: 0.93)
        let dark = (r: 0.12, g: 0.12, b: 0.12)
        // Opaque tints decide alone.
        XCTAssertFalse(MachineRosterColor.prefersWhiteText(fill: "#FFE14D", background: dark), "yellow takes black text")
        XCTAssertTrue(MachineRosterColor.prefersWhiteText(fill: "#1B2A6B", background: light), "navy takes white text")
        // A faint tint reads like the bar under it: black in light mode, white in dark.
        XCTAssertFalse(MachineRosterColor.prefersWhiteText(fill: "#3FA7D640", background: light))
        XCTAssertTrue(MachineRosterColor.prefersWhiteText(fill: "#3FA7D640", background: dark))
        // The pick is the higher WCAG ratio, so it always clears 3:1 (large text).
        for hex in ["#FF0000", "#00FF00", "#0000FF", "#808080", "#3FA7D6", "#F5A623"] {
            let c = MachineRosterColor.components(hex)!
            let lum = MachineRosterColor.luminance(r: c.r, g: c.g, b: c.b)
            let white = MachineRosterColor.prefersWhiteText(fill: hex, background: light)
            let ratio = MachineRosterColor.contrastRatio(lum, white ? 1 : 0)
            XCTAssertGreaterThanOrEqual(ratio, 3, hex)
        }
    }

    // MARK: Chip

    func testPlacementCarriesTheRosterKeyAndAppliesNameAndColor() throws {
        let local = try XCTUnwrap(SessionPlacement.make(
            lifecycle: .new, persistence: .nonpersistent, machineName: "Laptop", isLocal: true
        ))
        XCTAssertEqual(local.machineKey, MachineRoster.localID)
        XCTAssertEqual(local.machineName, "Laptop")

        let remote = try XCTUnwrap(SessionPlacement.make(
            lifecycle: .new, persistence: .nonpersistent, machineName: "studio"
        ))
        XCTAssertEqual(remote.machineKey, "studio")
        XCTAssertEqual(remote.machineName, "Studio")

        let roster = MachineRoster(defaults: defaults)
        XCTAssertEqual(remote.applyingRoster(roster), remote, "no entry keeps today's chip")
        try roster.set(id: "studio", name: .keep, color: .set("#3FA7D6"))
        let colorOnly = remote.applyingRoster(roster)
        XCTAssertEqual(colorOnly.machineName, "Studio")
        XCTAssertEqual(colorOnly.tint, "#3FA7D6")
        try roster.set(id: "studio", name: .set("Workbench"), color: .keep)
        XCTAssertEqual(remote.applyingRoster(roster).machineName, "Workbench")
        XCTAssertEqual(remote.applyingRoster(roster).accessibilityLabel.contains("Workbench"), true)
        XCTAssertEqual(local.applyingRoster(roster), local, "another machine's entry does not touch this one")
    }

    func testChipWidthIsSharedFloorsAtTheSampleAndIsCapped() throws {
        let base = SessionPlacement.metrics(multiplier: 1)
        XCTAssertEqual(SessionPlacement.metrics(multiplier: 1, configuredNames: ["Studio"]), base,
                       "a short name keeps today's width")
        let longer = SessionPlacement.metrics(multiplier: 1, configuredNames: ["Studio", "Laptop Studio"])
        XCTAssertGreaterThan(longer.hostSlot, base.hostSlot)
        XCTAssertEqual(longer.width - longer.hostSlot, base.width - base.hostSlot, "only the host slot grows")
        let capped = SessionPlacement.metrics(
            multiplier: 1,
            configuredNames: [String(repeating: "W", count: 48)]
        )
        XCTAssertEqual(capped.hostSlot, ceil(base.hostSlot * SessionPlacement.hostSlotCapFactor))

        // The live path measures the roster once per change, and a change re-measures.
        let roster = MachineRoster(defaults: defaults)
        XCTAssertEqual(SessionPlacement.metrics(multiplier: 1, roster: roster), base)
        try roster.set(id: "studio", name: .set("Laptop Studio"), color: .keep)
        XCTAssertEqual(SessionPlacement.metrics(multiplier: 1, roster: roster), longer)
    }

    func testAWidthMeasuredAcrossARosterChangeIsNotCached() {
        let cache = MachineRosterWidthCache()
        // A reset (a roster change) lands while the old names are measured.
        let stale = cache.width(fontSize: 13) {
            cache.reset()
            return 10
        }
        XCTAssertEqual(stale, 10)
        XCTAssertEqual(cache.width(fontSize: 13) { 20 }, 20, "the stale width was not kept")
        XCTAssertEqual(cache.width(fontSize: 13) { 30 }, 20, "an undisturbed measurement is cached")
    }

    func testRowsListThisMacLinkedAndUnlinkedMachines() {
        let rows = MachineRosterRow.rows(
            roster: [
                MachineRosterEntry(id: "linuxbox", name: "Linuxbox", color: nil),
                MachineRosterEntry(id: "studio", name: nil, color: "#3FA7D6"),
            ],
            linked: ["studio": true, "prime": false],
            localHostName: "Laptop"
        )
        XCTAssertEqual(rows.map(\.id), ["local", "linuxbox", "prime", "studio"])
        XCTAssertEqual(rows[0].displayName, "Laptop")
        XCTAssertTrue(rows[0].isLocal)
        XCTAssertFalse(rows[1].linked, "a roster entry hc no longer reports is marked unlinked")
        XCTAssertNil(rows[1].connected)
        XCTAssertEqual(rows[1].jsonObject["configured"] as? Bool, true)
        XCTAssertEqual(rows[2].connected, false)
        XCTAssertNil(rows[2].entry)
        XCTAssertEqual(rows[3].displayName, "Studio")
        XCTAssertEqual(rows[3].connected, true)
    }

    func testWhatsDifferentSheetReadsTheRoster() throws {
        let id = "look-test-\(UUID().uuidString.prefix(8).lowercased())"
        defer { _ = try? MachineRoster.shared.remove(id: id) }
        let before = WhatsDifferentPlaces.defaultLook(id)
        XCTAssertEqual(before.name, HCMachineTarget.displayName(id))
        XCTAssertNil(before.colorHex)
        try MachineRoster.shared.set(id: id, name: .set("Look"), color: .set("#112233"))
        let after = WhatsDifferentPlaces.defaultLook(id)
        XCTAssertEqual(after.name, "Look")
        XCTAssertEqual(after.colorHex, "#112233")
    }

    // MARK: Socket

    @MainActor
    func testMachineSocketMethodsListSetClearAndRemove() throws {
        let controller = TerminalController.shared
        let id = "socket-test-\(UUID().uuidString.prefix(8).lowercased())"
        defer { _ = try? MachineRoster.shared.remove(id: id) }

        func send(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            let box = MachineRosterTestBox()
            let done = expectation(description: method)
            DispatchQueue.global(qos: .userInitiated).async {
                box.value = controller.socketWorkerV2Response(
                    TerminalController.V2SocketRequest(id: 1, method: method, params: params)
                )
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            let data = try XCTUnwrap(box.value?.data(using: .utf8))
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func code(_ response: [String: Any]) -> String? {
            (response["error"] as? [String: Any])?["code"] as? String
        }

        XCTAssertEqual(code(try send("machine.set", ["id": id])), "invalid_params", "a set must change something")
        XCTAssertEqual(code(try send("machine.set", ["id": id, "color": "blue"])), "invalid_params")
        XCTAssertEqual(code(try send("machine.set", ["id": id, "name": 7])), "invalid_params")
        XCTAssertNil(MachineRoster.shared.entry(id: id))

        let saved = try send("machine.set", ["id": id, "name": "Socket Box", "color": "#00aa55"])
        XCTAssertEqual(saved["ok"] as? Bool, true)
        let machine = try XCTUnwrap((saved["result"] as? [String: Any])?["machine"] as? [String: Any])
        XCTAssertEqual(machine["color"] as? String, "#00AA55")

        let listed = try send("machine.list", [:])
        let rows = try XCTUnwrap((listed["result"] as? [String: Any])?["machines"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["id"] as? String, "local")
        let row = try XCTUnwrap(rows.first { $0["id"] as? String == id })
        XCTAssertEqual(row["display_name"] as? String, "Socket Box")
        XCTAssertEqual(row["linked"] as? Bool, false)

        let cleared = try send("machine.set", ["id": id, "name": NSNull()])
        XCTAssertEqual(cleared["ok"] as? Bool, true)
        XCTAssertEqual(MachineRoster.shared.entry(id: id), MachineRosterEntry(id: id, name: nil, color: "#00AA55"))

        let removed = try send("machine.rm", ["id": id])
        XCTAssertEqual((removed["result"] as? [String: Any])?["removed"] as? Bool, true)
        XCTAssertNil(MachineRoster.shared.entry(id: id))
    }
}

private final class MachineRosterTestBox: @unchecked Sendable {
    var value: String?
}
