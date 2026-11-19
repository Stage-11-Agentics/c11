import XCTest
import SwiftUI
import Combine
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Session chip mapping, fixed width, and title-bar layout. Constructs
/// `HCLifecycle` values directly. Does not start a core or build a `Workspace`.
final class SessionPlacementTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // ThemeManager reads NSApp while the bar is created. The logic runner
        // has no application until something here creates one.
        _ = NSApplication.shared
    }

    func testLivePersistentReadsTheRecordMachineAndNoMark() {
        let placed = SessionPlacement.make(
            lifecycle: .live(record("  Laptop  ")),
            persistence: .persistent,
            machineName: "Studio"
        )
        XCTAssertEqual(placed, SessionPlacement(machineName: "Laptop", mark: .none, machineKey: "laptop"))
        assertSpoken(placed, label: "Runs on Laptop", value: "")
        XCTAssertNil(placed?.help)
    }

    func testLiveNonpersistentMarksNotKept() {
        let placed = SessionPlacement.make(
            lifecycle: .live(record("Studio")),
            persistence: .nonpersistent,
            machineName: "Laptop"
        )
        XCTAssertEqual(placed, SessionPlacement(machineName: "Studio", mark: .notKept, machineKey: "studio"))
        assertSpoken(placed, label: "Runs on Studio", value: "not kept")
        XCTAssertEqual(
            placed?.help,
            "This session will not survive a restart. Plain-shell fallback."
        )
    }

    func testLivePersistentWithNoRecordMachineUsesTheRetainedName() {
        let placed = SessionPlacement.make(
            lifecycle: .live(record("   ")),
            persistence: .persistent,
            machineName: "Laptop"
        )
        XCTAssertEqual(placed, SessionPlacement(machineName: "Laptop", mark: .none, machineKey: "laptop"))
        assertSpoken(placed, label: "Runs on Laptop", value: "")
        XCTAssertNil(placed?.help)
    }

    func testLivePersistentWithNoNameAtAllDrawsNothing() {
        XCTAssertNil(SessionPlacement.make(
            lifecycle: .live(record(nil)),
            persistence: .persistent,
            machineName: "   "
        ))
    }

    func testLiveNonpersistentWithNoRecordMachineKeepsTheRetainedNameAndNotKept() {
        let placed = SessionPlacement.make(
            lifecycle: .live(record(nil)),
            persistence: .nonpersistent,
            machineName: "Laptop"
        )
        XCTAssertEqual(placed, SessionPlacement(machineName: "Laptop", mark: .notKept, machineKey: "laptop"))
        assertSpoken(placed, label: "Runs on Laptop", value: "not kept")
    }

    func testLiveNonpersistentWithNoNameStillMarksNotKept() {
        let placed = SessionPlacement.make(
            lifecycle: .live(record(nil)),
            persistence: .nonpersistent,
            machineName: nil
        )
        XCTAssertEqual(placed, SessionPlacement(machineName: "", mark: .notKept))
        assertSpoken(placed, label: "Where this terminal runs", value: "not kept")
    }

    func testNewPersistentDrawsNothing() {
        XCTAssertNil(SessionPlacement.make(
            lifecycle: .new,
            persistence: .persistent,
            machineName: "Laptop"
        ))
    }

    func testNewNonpersistentMarksNotKept() {
        let placed = SessionPlacement.make(
            lifecycle: .new,
            persistence: .nonpersistent,
            machineName: "  Laptop "
        )
        XCTAssertEqual(placed, SessionPlacement(machineName: "Laptop", mark: .notKept, machineKey: "laptop"))
    }

    func testEndedDrawsNothingAndIgnoresTheSideMachine() {
        XCTAssertNil(SessionPlacement.make(
            lifecycle: ended(),
            persistence: .nonpersistent,
            machineName: "Laptop"
        ))
    }

    func testUnresolvedReconnectsAndPreservesPersistence() {
        for persistence in [HCPersistence.persistent, .nonpersistent] {
            let placed = SessionPlacement.make(
                lifecycle: unresolved(persistence: persistence),
                persistence: persistence,
                machineName: "  Laptop "
            )
            XCTAssertEqual(placed?.mark, .reconnecting, "\(persistence)")
            XCTAssertNotEqual(placed?.mark, .notKept, "\(persistence)")
            XCTAssertEqual(placed?.machineName, "Laptop", "\(persistence)")
            assertSpoken(placed, label: "Runs on Laptop", value: "Reconnecting", "\(persistence)")
            XCTAssertEqual(
                placed?.help,
                "This session is unchanged. c11 is waiting to reach it again.",
                "\(persistence)"
            )
        }
    }

    /// C11H-205: a brand-new terminal publishes `creationPending` before it
    /// has any session; "Reconnecting, this session is unchanged" was false.
    func testANewTerminalStartingIsNotReconnecting() {
        let starting = HCLifecycle.unresolved(
            HCPanelIdentity(panelID: UUID(), creationID: UUID(), origin: .fresh), .creationPending)
        let placed = SessionPlacement.make(lifecycle: starting, persistence: .persistent, machineName: "Laptop")
        XCTAssertEqual(placed?.mark, SessionMark.none)
        XCTAssertEqual(placed?.machineName, "Laptop")
        let restored = HCLifecycle.unresolved(
            HCPanelIdentity(panelID: UUID(), creationID: UUID(), origin: .restored), .creationPending)
        XCTAssertEqual(SessionPlacement.make(lifecycle: restored, persistence: .persistent, machineName: "Laptop")?.mark,
                       .reconnecting, "a restored terminal is being found again")
        let bound = HCLifecycle.unresolved(HCPanelIdentity(panelID: UUID(),
            key: HCTerminalKey(owningCoreID: "c", localAddress: "t1"), origin: .fresh), .connectionLost)
        XCTAssertEqual(SessionPlacement.make(lifecycle: bound, persistence: .persistent, machineName: "Laptop")?.mark,
                       .reconnecting, "a terminal that had a session is reconnecting")
    }

    func testUnresolvedWithNoMachineReadsReconnecting() {
        let placed = SessionPlacement.make(
            lifecycle: unresolved(persistence: .persistent),
            persistence: .persistent,
            machineName: "  "
        )
        XCTAssertEqual(placed, SessionPlacement(machineName: "", mark: .reconnecting))
        assertSpoken(placed, label: "Where this terminal runs", value: "Reconnecting")
    }

    func testChipStaysOffBrowsersAndMarkdown() {
        let stored = SessionPlacement(machineName: "Laptop", mark: .none)
        XCTAssertEqual(SessionPlacement.shown(on: .terminal, stored: stored), stored)
        XCTAssertNil(SessionPlacement.shown(on: .browser, stored: stored))
        XCTAssertNil(SessionPlacement.shown(on: .markdown, stored: stored))
        XCTAssertNil(SessionPlacement.shown(on: nil, stored: stored))
        XCTAssertNil(SessionPlacement.shown(on: .terminal, stored: nil))
    }

    func testPlacementRendersTheBarWithoutADescription() {
        let placement = SessionPlacement(machineName: "Laptop", mark: .none)
        XCTAssertTrue(PanelTitleBarState(placement: placement).rendersBar)
        XCTAssertFalse(PanelTitleBarState().rendersBar)
        XCTAssertFalse(PanelTitleBarState(visible: false, placement: placement).rendersBar)
        XCTAssertTrue(PanelTitleBarState(description: "Working.", placement: nil).rendersBar)
    }

    // MARK: - Wiring gap 6: the local producer

    func testLocalTerminalFeedsItsLifecycleAndThisComputersNameToTheChip() {
        // Local inventory records carry no machine name (address `tN`).
        let lifecycle = CurrentValueSubject<HCLifecycle, Never>(.live(record(nil)))
        var persistence = HCPersistence.persistent
        var noted: [(HCLifecycle, HCPersistence, String?)] = []
        let sink = LocalSessionPlacementFeed.follow(
            lifecycle: lifecycle, persistence: { persistence }, isRemote: false, hostName: "Laptop"
        ) { noted.append(($0, $1, $2)) }
        XCTAssertNotNil(sink)
        func chip(_ index: Int) -> SessionPlacement? {
            SessionPlacement.make(lifecycle: noted[index].0, persistence: noted[index].1,
                                  machineName: noted[index].2)
        }
        // The current value reaches the chip as soon as the panel subscribes.
        XCTAssertEqual(noted.count, 1)
        XCTAssertEqual(noted[0].2, "Laptop")
        XCTAssertEqual(chip(0), SessionPlacement(machineName: "Laptop", mark: .none, machineKey: "laptop"))
        // An exec fallback is marked not kept; persistence is read at each emission.
        persistence = .nonpersistent
        lifecycle.send(.live(record(nil)))
        XCTAssertEqual(chip(1), SessionPlacement(machineName: "Laptop", mark: .notKept, machineKey: "laptop"))
        // A downed core is Reconnecting, never ended, and still names the host.
        let identity = HCPanelIdentity(panelID: UUID(), key: HCTerminalKey(owningCoreID: "core", localAddress: "t1"))
        lifecycle.send(.unresolved(identity, .coreUnreachable))
        XCTAssertEqual(chip(2), SessionPlacement(machineName: "Laptop", mark: .reconnecting, machineKey: "laptop"))
        assertSpoken(chip(2), label: "Runs on Laptop", value: "Reconnecting")
        // A fallback panel that never bound (`.new`) names the host too.
        lifecycle.send(.new)
        XCTAssertEqual(chip(3), SessionPlacement(machineName: "Laptop", mark: .notKept, machineKey: "laptop"))
        withExtendedLifetime(sink) {}
    }

    func testARecordMachineNameIsRetainedForLaterStatesWithNoRecord() {
        let lifecycle = CurrentValueSubject<HCLifecycle, Never>(.live(record("Studio")))
        var noted: [String?] = []
        let sink = LocalSessionPlacementFeed.follow(
            lifecycle: lifecycle, persistence: { .persistent }, isRemote: false, hostName: "Laptop"
        ) { noted.append($2) }
        let identity = HCPanelIdentity(panelID: UUID(), key: HCTerminalKey(owningCoreID: "core", localAddress: "t1"))
        lifecycle.send(.unresolved(identity, .coreUnreachable))
        XCTAssertEqual(noted, ["Studio", "Studio"])
        withExtendedLifetime(sink) {}
    }

    func testRemoteTerminalIsLeftToItsRemoteStatusBinding() {
        let lifecycle = CurrentValueSubject<HCLifecycle, Never>(.live(record("Studio")))
        var calls = 0
        let sink = LocalSessionPlacementFeed.follow(
            lifecycle: lifecycle, persistence: { .persistent }, isRemote: true
        ) { _, _, _ in calls += 1 }
        XCTAssertNil(sink)
        lifecycle.send(.live(record("Studio")))
        XCTAssertEqual(calls, 0)
    }

    func testChipWidthUsesTheHostSampleAndTheWiderMarkNotTheLiveName() {
        let metrics = SessionPlacement.metrics(multiplier: 1)
        let hostFont = NSFont.systemFont(ofSize: metrics.hostFontSize, weight: .semibold)
        let markFont = NSFont.systemFont(ofSize: metrics.markFontSize, weight: .semibold)
        let sample = ceil(width("Notebook", font: hostFont))
        let studio = ceil(width("Studio", font: hostFont))
        let notKept = width("not kept", font: markFont)
        let reconnecting = width("Reconnecting", font: markFont)
        XCTAssertEqual(metrics.hostFontSize, 13, accuracy: 0.001)
        XCTAssertEqual(metrics.markFontSize, 11, accuracy: 0.001)
        XCTAssertEqual(metrics.hostSlot, sample)
        XCTAssertGreaterThan(metrics.hostSlot, studio)
        XCTAssertGreaterThan(reconnecting, notKept)
        XCTAssertEqual(metrics.markSlot, ceil(max(notKept, reconnecting)))
        XCTAssertEqual(metrics.pad, 6)
        XCTAssertEqual(metrics.gap, 6)
        XCTAssertEqual(metrics.width, metrics.pad + metrics.hostSlot + metrics.gap + metrics.markSlot + metrics.pad)
        // The prototype's mark slot was 58pt for "not kept". Reconnecting is wider,
        // so the slot grows instead of clipping back to that width.
        XCTAssertGreaterThan(metrics.markSlot, 58)
        XCTAssertEqual(SessionPlacement.chipWidth(multiplier: 1), metrics.width)

        let large = SessionPlacement.metrics(multiplier: 1.25)
        XCTAssertGreaterThan(large.width, metrics.width)
        XCTAssertGreaterThan(large.rowHeight, metrics.rowHeight)
        XCTAssertEqual(large.pad, ceil(6 * 1.25))
        XCTAssertEqual(SessionPlacement.chipRowHeight(multiplier: 1), metrics.rowHeight)
        XCTAssertEqual(SessionPlacement.chipRowHeight(multiplier: 1.25), large.rowHeight)
    }

    func testCollapsedHeightIsStableAcrossMarks() {
        let marks: [SessionMark] = [.none, .notKept, .reconnecting]
        let described = marks.map { mark in
            measure(PanelTitleBarState(
                description: "Working on the chip.",
                placement: SessionPlacement(machineName: "Studio", mark: mark)
            ))
        }
        XCTAssertEqual(described[0], described[1], accuracy: 0.5)
        XCTAssertEqual(described[1], described[2], accuracy: 0.5)
        let chipOnly = measure(PanelTitleBarState(
            placement: SessionPlacement(machineName: "Laptop", mark: .reconnecting)
        ))
        XCTAssertGreaterThan(chipOnly, 0)
        XCTAssertEqual(chipOnly, described[0], accuracy: 0.5)
        let long = measure(PanelTitleBarState(
            description: String(repeating: "long description ", count: 30),
            placement: SessionPlacement(machineName: "A", mark: .notKept)
        ))
        XCTAssertEqual(long, chipOnly, accuracy: 0.5)
        XCTAssertEqual(measure(PanelTitleBarState()), 0, accuracy: 0.5)
        XCTAssertEqual(
            measure(PanelTitleBarState(
                visible: false,
                placement: SessionPlacement(machineName: "Laptop", mark: .notKept)
            )),
            0,
            accuracy: 0.5
        )
    }

    func testLongDescriptionDoesNotMoveTheChip() throws {
        let placement = SessionPlacement(machineName: "Studio", mark: .none)
        let reconnecting = SessionPlacement(machineName: "Laptop", mark: .reconnecting)
        let notKept = SessionPlacement(machineName: String(repeating: "M", count: 40), mark: .notKept)
        let short = frames(
            PanelTitleBarState(description: "Working.", placement: placement),
            width: 440
        )
        let long = frames(
            PanelTitleBarState(
                description: String(repeating: "long description ", count: 40),
                placement: placement
            ),
            width: 440
        )
        let wide = frames(
            PanelTitleBarState(description: "Working.", placement: placement),
            width: 1100
        )
        let marked = frames(
            PanelTitleBarState(description: "Working.", placement: reconnecting),
            width: 1100
        )
        let stretched = frames(
            PanelTitleBarState(description: "Working.", placement: notKept),
            width: 1100
        )
        let large = frames(
            PanelTitleBarState(description: "Working.", placement: placement),
            width: 1100,
            multiplier: 1.55
        )
        let chipOnly = frames(
            PanelTitleBarState(placement: placement),
            width: 440
        )
        let mailFlag = frames(
            PanelTitleBarState(description: "Working.", showsMailbox: true, placement: placement),
            width: 440
        )

        let chip = try XCTUnwrap(short["chip"])
        let longChip = try XCTUnwrap(long["chip"])
        let wideChip = try XCTUnwrap(wide["chip"])
        let markedChip = try XCTUnwrap(marked["chip"])
        let stretchedChip = try XCTUnwrap(stretched["chip"])
        let largeChip = try XCTUnwrap(large["chip"])
        let shortDescription = try XCTUnwrap(short["description"])
        let longDescription = try XCTUnwrap(long["description"])
        let chipOnlyChip = try XCTUnwrap(chipOnly["chip"])
        let mailChip = try XCTUnwrap(mailFlag["chip"])
        let mailDescription = try XCTUnwrap(mailFlag["description"])

        XCTAssertEqual(longChip.minX, chip.minX, accuracy: 0.5)
        XCTAssertEqual(wideChip.minX, chip.minX, accuracy: 0.5)
        XCTAssertEqual(markedChip.width, chip.width, accuracy: 0.5)
        XCTAssertEqual(stretchedChip.width, chip.width, accuracy: 0.5)
        // The top bar draws at no less than 1.30x (#216), and the chip also
        // reserves the roster's color square when any machine has a color.
        let barScale = ChromeScaleSettings.topBarMultiplier(for: 1)
        let largeScale = ChromeScaleSettings.topBarMultiplier(for: 1.55)
        XCTAssertGreaterThan(largeScale, barScale)
        XCTAssertEqual(
            chip.width,
            SessionPlacement.chipWidth(multiplier: barScale) + SessionChipView.colorSlot(multiplier: barScale, roster: .shared),
            accuracy: 1
        )
        XCTAssertGreaterThan(largeChip.width, chip.width)
        XCTAssertEqual(
            largeChip.width,
            SessionPlacement.chipWidth(multiplier: largeScale) + SessionChipView.colorSlot(multiplier: largeScale, roster: .shared),
            accuracy: 1.5
        )
        XCTAssertGreaterThan(shortDescription.minX, chip.maxX - 1)
        XCTAssertEqual(longDescription.minX, shortDescription.minX, accuracy: 0.5)
        XCTAssertEqual(chipOnlyChip.minX, chip.minX, accuracy: 0.5)
        XCTAssertEqual(mailChip.minX, chip.minX, accuracy: 0.5)
        XCTAssertEqual(mailChip.width, chip.width, accuracy: 0.5)
        XCTAssertEqual(mailDescription.width, shortDescription.width, accuracy: 0.5)
    }

    private func record(_ machineName: String?) -> HCTerminalRecord {
        HCTerminalRecord(
            key: HCTerminalKey(owningCoreID: "core", localAddress: "t1"),
            state: .running,
            machineName: machineName
        )
    }

    private func ended() -> HCLifecycle {
        .ended(HCEndEvidence(
            id: UUID(),
            revision: HCRevision(connectionGeneration: 1, sequence: 1),
            kind: .finished
        ))
    }

    private func unresolved(persistence: HCPersistence) -> HCLifecycle {
        .unresolved(
            HCPanelIdentity(panelID: UUID(), persistence: persistence, origin: .fresh),
            .connectionLost
        )
    }

    private func width(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func measure(_ state: PanelTitleBarState, multiplier: CGFloat = 1) -> CGFloat {
        let host = NSHostingView(rootView: PanelTitleBarView(state: state)
            .environment(\.chromeScaleTokens, ChromeScaleTokens(multiplier: multiplier)))
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 10_000)
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: 440, height: fit.height)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func assertSpoken(
        _ placement: SessionPlacement?,
        label: String,
        value: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(placement?.accessibilityLabel, label, message, file: file, line: line)
        XCTAssertEqual(placement?.accessibilityValue, value, message, file: file, line: line)
        // C11H-166: VoiceOver reads one line, the machine then the mark.
        XCTAssertEqual(placement?.spokenLabel, value.isEmpty ? label : "\(label), \(value)", message, file: file, line: line)
    }

    private func frames(
        _ state: PanelTitleBarState,
        width: CGFloat,
        multiplier: CGFloat = 1
    ) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        let host = NSHostingView(rootView: PanelTitleBarView(state: state, onLayout: { frames[$0] = $1 })
            .environment(\.chromeScaleTokens, ChromeScaleTokens(multiplier: multiplier)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        return frames
    }
}

// MARK: - c11: herder cores popover

extension SessionPlacementTests {
    func testHerderCoresListThisMacFirstWithStateVersionAndTerminalCounts() {
        let rows = MachineRosterRow.rows(
            roster: [MachineRosterEntry(id: "studio", name: "Workbench", color: nil)],
            linked: ["studio": true, "linuxbox": false],
            localHostName: "Laptop"
        )
        let cores = HerderCoresPopover.cores(
            rows: rows,
            versions: ["local": "0.9.1", "studio": "0.9.0"],
            terminalsByMachine: ["studio": 3],
            localTerminals: 12,
            currentMachineKey: "studio"
        )
        XCTAssertEqual(cores.map(\.name), ["Laptop", "Linuxbox", "Workbench"])
        XCTAssertEqual(cores.map(\.isCurrent), [false, false, true])
        XCTAssertEqual(HerderCoresPopover.detail(cores[0]), "This Mac · hc 0.9.1 · 12 terminals")
        XCTAssertEqual(HerderCoresPopover.detail(cores[1]), "Unreachable · 0 terminals")
        XCTAssertEqual(HerderCoresPopover.detail(cores[2]), "Connected · hc 0.9.0 · 3 terminals")
    }

    func testHerderCoresMarkThisMacCurrentForALocalPanel() {
        let rows = MachineRosterRow.rows(roster: [], linked: [:], localHostName: "Laptop")
        let cores = HerderCoresPopover.cores(rows: rows, versions: [:], terminalsByMachine: [:], localTerminals: 1, currentMachineKey: "")
        XCTAssertEqual(cores.count, 1)
        XCTAssertTrue(cores[0].isCurrent)
        XCTAssertEqual(HerderCoresPopover.detail(cores[0]), "This Mac · 1 terminal")
    }
}

extension SessionPlacementTests {
    func testSubtitleStartsRightAfterTheChipAndUsesTheBarsWidth() {
        var state = PanelTitleBarState(title: "x", description: "Auditing the relay handshake; next, the build-host guest run, then the review.", collapsed: true)
        state.placement = SessionPlacement(machineName: "Laptop", mark: .none, machineKey: "local")
        let measured = frames(state, width: 600)
        let chip = measured["chip"] ?? .zero, description = measured["description"] ?? .zero
        let age = measured["descriptionAge"] ?? .zero
        XCTAssertLessThan(description.minX - chip.maxX, 20, "the subtitle starts right after the chip")
        // C11H-278: the bar's rest is the subtitle plus its age's fixed slot.
        XCTAssertGreaterThan(age.width, 0, "the age slot is reserved")
        XCTAssertLessThanOrEqual(description.maxX, age.minX + 0.5, "the age follows the subtitle")
        XCTAssertGreaterThan(description.width, 600 - chip.maxX - 80 - age.width, "the subtitle takes the rest of the bar")
    }

    /// C11H-278: a narrow bar shows the compact age so its subtitle keeps
    /// room; a wide bar shows the full text. (A 460 pt guest panel left the
    /// subtitle about 10 pt beside the full slot.)
    func testANarrowBarUsesTheCompactAgeAndKeepsItsSubtitle() {
        var state = PanelTitleBarState(title: "x", description: "Auditing the relay handshake.", collapsed: true)
        state.placement = SessionPlacement(machineName: "Laptop", mark: .none, machineKey: "local")
        state.descriptionUpdatedAt = Date()
        let size = ChromeScaleTokens(multiplier: 1).surfaceTitleBarTitle
        let compact = DescriptionAgeMetrics.slotWidth(style: .compact, fontSize: size)
        let full = DescriptionAgeMetrics.slotWidth(style: .full, fontSize: size)

        let narrow = frames(state, width: 460)
        XCTAssertEqual(narrow["descriptionAge"]?.width ?? 0, compact, accuracy: 0.5, "a narrow bar shows the compact age")
        XCTAssertGreaterThan(narrow["description"]?.width ?? 0, 60, "the subtitle keeps room beside it")

        let wide = frames(state, width: 1100)
        XCTAssertEqual(wide["descriptionAge"]?.width ?? 0, full, accuracy: 0.5, "a wide bar shows the full age")
        XCTAssertGreaterThanOrEqual(wide["description"]?.width ?? 0, PanelTitleBarView.minimumSubtitleWidth)
    }

    /// The style follows the width the subtitle and age share, which the
    /// style itself does not change, so it settles in one step.
    func testTheAgeStyleSettlesInOneStep() {
        let size: CGFloat = 12
        let delta = DescriptionAgeMetrics.slotWidth(style: .full, fontSize: size)
            - DescriptionAgeMetrics.slotWidth(style: .compact, fontSize: size)
        for subtitle in stride(from: delta, through: 800, by: 7) {
            let fromCompact = PanelTitleBarView.nextAgeStyle(current: .compact, descriptionWidth: subtitle, fontSize: size)
            let fromFull = PanelTitleBarView.nextAgeStyle(current: .full, descriptionWidth: subtitle - delta, fontSize: size)
            XCTAssertEqual(fromCompact, fromFull, "the same bar must pick one style at \(subtitle) pt")
        }
        XCTAssertEqual(PanelTitleBarView.nextAgeStyle(current: .full, descriptionWidth: 0, fontSize: size), .compact,
                       "a bar squeezed to nothing falls back to compact")
        XCTAssertEqual(PanelTitleBarView.nextAgeStyle(current: .compact, descriptionWidth: 0, fontSize: size), .compact,
                       "an unmeasured bar starts compact")
    }

    /// C11H-278: the age label changes text every minute or hour; neither the
    /// subtitle nor the label moves, from no age through days.
    func testTheDescriptionAgeNeverMovesTheSubtitle() {
        var state = PanelTitleBarState(title: "x", description: "Auditing the relay handshake.", collapsed: true)
        state.isTerminal = true
        let now = Date()
        let ages: [Date?] = [nil, now, now.addingTimeInterval(-90), now.addingTimeInterval(-3 * 3600 - 60),
                             now.addingTimeInterval(-40 * 86_400)]
        let measured = ages.map { updatedAt -> [String: CGRect] in
            state.descriptionUpdatedAt = updatedAt
            return frames(state, width: 600)
        }
        let first = measured[0]
        XCTAssertGreaterThan(first["descriptionAge"]?.width ?? 0, 0)
        for (index, frames) in measured.enumerated() {
            for key in ["description", "descriptionAge"] {
                let a = first[key] ?? .zero, b = frames[key] ?? .zero
                XCTAssertEqual(a.minX, b.minX, accuracy: 0.5, "\(key) moved at age \(index)")
                XCTAssertEqual(a.width, b.width, accuracy: 0.5, "\(key) resized at age \(index)")
            }
        }
    }
}

extension SessionPlacementTests {
    func testATerminalsSubtitleDoesNotMoveWhenItsPlacementArrivesOrEnds() {
        var waiting = PanelTitleBarState(title: "x", description: "Building the relay.", collapsed: true)
        waiting.isTerminal = true
        var placed = waiting
        placed.placement = SessionPlacement(machineName: "Laptop", mark: .none, machineKey: "local")
        let before = frames(waiting, width: 600)["description"] ?? .zero
        let after = frames(placed, width: 600)["description"] ?? .zero
        XCTAssertGreaterThan(before.minX, 0)
        XCTAssertEqual(before.minX, after.minX, accuracy: 0.5, "the chip's slot is reserved before the placement arrives")
        XCTAssertEqual(before.width, after.width, accuracy: 0.5)
    }
}

