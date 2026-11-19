import CoreServices
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11H-127: when the "What's different" sheet shows itself, and the places
/// its picture draws.
final class WhatsDifferentTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "WhatsDifferentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func look(_ id: String) -> WhatsDifferentMachineLook {
        id == WhatsDifferentPlaces.localID
            ? WhatsDifferentMachineLook(name: "Laptop", colorHex: nil)
            : WhatsDifferentMachineLook(name: id.uppercased(), colorHex: id == "studio" ? "#3FA7D6" : nil)
    }

    func testShowsOncePerContentVersionAndNeverUnderQA() {
        XCTAssertTrue(WhatsDifferent.shouldAutoPresent(qa: .off, shownVersion: 0, current: 1))
        XCTAssertFalse(WhatsDifferent.shouldAutoPresent(qa: .off, shownVersion: 1, current: 1))
        XCTAssertTrue(WhatsDifferent.shouldAutoPresent(qa: .off, shownVersion: 1, current: 2),
                      "an update that changes the content shows it once more")
        XCTAssertFalse(WhatsDifferent.shouldAutoPresent(qa: .on(.fresh), shownVersion: 0, current: 1))
        XCTAssertFalse(WhatsDifferent.shouldAutoPresent(qa: .on(.resume), shownVersion: 0, current: 1))
        XCTAssertFalse(WhatsDifferent.shouldAutoPresent(qa: QALaunchPolicy.current(environment: ["C11_QA_LAUNCH": "fresh"]),
                                                        shownVersion: 0))
    }

    func testMarkShownRecordsTheVersionAndNeverLowersIt() {
        let defaults = defaults()
        XCTAssertEqual(WhatsDifferent.shownVersion(defaults: defaults), 0)
        WhatsDifferent.markShown(defaults: defaults, version: 2)
        XCTAssertEqual(WhatsDifferent.shownVersion(defaults: defaults), 2)
        WhatsDifferent.markShown(defaults: defaults, version: 1)
        XCTAssertEqual(WhatsDifferent.shownVersion(defaults: defaults), 2)
        XCTAssertFalse(WhatsDifferent.shouldAutoPresent(qa: .off, shownVersion: WhatsDifferent.shownVersion(defaults: defaults),
                                                        current: 2))
    }

    /// C11H-267: who sees the c11 2.0 upgrade note, the standard sheet, or nothing.
    func testUpgradeNoteGoesOnlyToAC11V1ProfileAndOnlyOnce() {
        func decide(_ origin: C11UpgradeOrigin, noteShown: Bool = false, shownVersion: Int = 0,
                    qa: QALaunchPolicy = .off) -> WhatsDifferent.Presentation {
            WhatsDifferent.autoPresentation(qa: qa, origin: origin, upgradeNoteShown: noteShown,
                                            shownVersion: shownVersion, current: 1)
        }
        XCTAssertEqual(decide(.c11v1), .upgradeFrom1x)
        XCTAssertEqual(decide(.c11v1, noteShown: true, shownVersion: 1), .nothing, "a relaunch never shows it again")
        XCTAssertEqual(decide(.fresh), .standard, "a fresh install gets the ordinary sheet, never the upgrade note")
        XCTAssertEqual(decide(.c11, shownVersion: 1), .nothing, "a c11 profile has seen hc's sheet")
        XCTAssertEqual(decide(.both, shownVersion: 1), .nothing, "both: 2.0 takes c11's world")
        for origin in [C11UpgradeOrigin.fresh, .c11v1, .c11, .both] {
            XCTAssertEqual(decide(origin, qa: .on(.fresh)), .nothing)
            XCTAssertEqual(decide(origin, qa: .on(.resume)), .nothing)
        }
        XCTAssertEqual(WhatsDifferent.autoPresentation(qa: .off, origin: .c11v1, upgradeNoteShown: true,
                                                       shownVersion: 1, current: 2), .standard,
                       "a later content change reaches upgraders like everyone")
    }

    func testOriginIsReadFromTheMigrationKeyAndShowingTheNoteIsRecorded() {
        let defaults = defaults()
        XCTAssertEqual(C11UpgradeOrigin.current(defaults: defaults), .fresh, "no migration record reads as fresh")
        defaults.set("something-else", forKey: C11UpgradeOrigin.defaultsKey)
        XCTAssertEqual(C11UpgradeOrigin.current(defaults: defaults), .fresh)
        defaults.set("c11-1x", forKey: C11UpgradeOrigin.defaultsKey)
        XCTAssertEqual(C11UpgradeOrigin.current(defaults: defaults), .c11v1)
        XCTAssertEqual(WhatsDifferent.audience(origin: .c11v1), .upgradeFrom1x)
        XCTAssertEqual(WhatsDifferent.audience(origin: .fresh), .standard)

        WhatsDifferent.markShown(.upgradeFrom1x, defaults: defaults)
        XCTAssertTrue(WhatsDifferent.upgradeNoteShown(defaults: defaults))
        XCTAssertEqual(WhatsDifferent.autoPresentation(
            qa: .off, origin: .c11v1, upgradeNoteShown: WhatsDifferent.upgradeNoteShown(defaults: defaults),
            shownVersion: WhatsDifferent.shownVersion(defaults: defaults)), .nothing)

        let fresh = self.defaults()
        WhatsDifferent.markShown(.standard, defaults: fresh)
        XCTAssertFalse(WhatsDifferent.upgradeNoteShown(defaults: fresh))
        XCTAssertEqual(WhatsDifferent.shownVersion(defaults: fresh), WhatsDifferent.contentVersion)
    }

    /// C11H-267: Keep Terminals After Quit off ends terminals only on an
    /// operator's quit; on, nothing changes.
    func testOnlyAnOperatorQuitWithTheSwitchOffEndsTerminals() {
        func ends(keep: Bool, bypass: Bool = false, reason: OSType? = nil, signal: Bool = false) -> Bool {
            QuitTerminalsSettings.endsTerminals(keepTerminals: keep, relaunchBypass: bypass,
                                                quitReason: reason, terminationSignal: signal)
        }
        XCTAssertFalse(ends(keep: true), "on: quitting keeps terminals")
        XCTAssertTrue(ends(keep: false), "off: an operator quit ends them")
        XCTAssertFalse(ends(keep: false, bypass: true), "an update or settings relaunch keeps them")
        XCTAssertFalse(ends(keep: false, signal: true), "TERM (the installer's update) keeps them")
        XCTAssertFalse(ends(keep: false, reason: OSType(kAELogOut)), "logout and shutdown are not this switch's")
        XCTAssertTrue(ends(keep: false, reason: OSType(kAEQuitApplication)))

        let defaults = defaults()
        XCTAssertTrue(QuitTerminalsSettings.keepsTerminals(defaults: defaults), "on by default")
        defaults.set(false, forKey: QuitTerminalsSettings.keepTerminalsKey)
        XCTAssertFalse(QuitTerminalsSettings.keepsTerminals(defaults: defaults))
    }

    func testThisMacAloneWhenNoMachineIsLinked() {
        let places = WhatsDifferentPlaces.build(machines: [:], terminalMachines: [nil, nil, nil], look: look)
        XCTAssertEqual(places, [WhatsDifferentPlace(id: "local", name: "Laptop", colorHex: nil, link: .local, terminals: 3)])
    }

    func testCountsTerminalsPerMachineAndKeepsLinkState() {
        let places = WhatsDifferentPlaces.build(
            machines: ["linuxbox": false, "studio": true],
            terminalMachines: [nil, "studio", "studio", nil, "studio"],
            look: look
        )
        XCTAssertEqual(places.map(\.id), ["local", "linuxbox", "studio"], "this Mac first, then machines by name")
        XCTAssertEqual(places.map(\.terminals), [2, 0, 3])
        XCTAssertEqual(places.map(\.link), [.local, .reconnecting, .connected])
        XCTAssertEqual(places[2].name, "STUDIO", "names come from the look seam")
        XCTAssertEqual(places[2].colorHex, "#3FA7D6")
    }

    func testATerminalOnAMachineHcNoLongerListsIsStillCounted() {
        let places = WhatsDifferentPlaces.build(machines: [:], terminalMachines: ["studio"], look: look)
        XCTAssertEqual(places.last, WhatsDifferentPlace(id: "studio", name: "STUDIO", colorHex: "#3FA7D6",
                                                        link: .reconnecting, terminals: 1))
        XCTAssertEqual(places.first?.terminals, 0)
    }

    func testDefaultLookMatchesTodaysChip() {
        XCTAssertEqual(WhatsDifferentPlaces.defaultLook("studio"), WhatsDifferentMachineLook(name: "Studio", colorHex: nil))
        XCTAssertEqual(WhatsDifferentPlaces.defaultLook("local").name, LocalSessionPlacementFeed.localHostName)
    }

    func testPaletteReadsRosterHex() {
        XCTAssertNotNil(WhatsDifferentPalette.nsColor(hex: "#3FA7D6"))
        XCTAssertNotNil(WhatsDifferentPalette.nsColor(hex: "3fa7d680"))
        XCTAssertNil(WhatsDifferentPalette.nsColor(hex: "#3FA7"))
        XCTAssertNil(WhatsDifferentPalette.nsColor(hex: "not a color"))
    }
}
