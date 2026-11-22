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

    /// C11H-267, C11H-335: who sees the upgrade note, the adoption note, the
    /// standard sheet, or nothing.
    func testEachNoteGoesOnlyToItsOwnProfileAndOnlyOnce() {
        func decide(_ origin: C11UpgradeOrigin, noteShown: Bool = false, adoptShown: Bool = false,
                    shownVersion: Int = 0, qa: QALaunchPolicy = .off) -> WhatsDifferent.Presentation {
            WhatsDifferent.autoPresentation(qa: qa, origin: origin, upgradeNoteShown: noteShown,
                                            adoptNoteShown: adoptShown, shownVersion: shownVersion, current: 1)
        }
        XCTAssertEqual(decide(.c11v1), .upgradeFrom1x)
        XCTAssertEqual(decide(.c11v1, noteShown: true, shownVersion: 1), .nothing, "a relaunch never shows it again")
        XCTAssertEqual(decide(.fresh), .standard, "a fresh install gets the ordinary sheet, never a note")
        XCTAssertEqual(decide(.adopted, shownVersion: 1), .adopted, "an adopted profile reads what changed once")
        XCTAssertEqual(decide(.both, shownVersion: 1), .adopted, "both: 2.0 took the adopted world")
        XCTAssertEqual(decide(.adopted, adoptShown: true, shownVersion: 1), .nothing, "and never again")
        XCTAssertEqual(decide(.adopted, noteShown: true, shownVersion: 1), .adopted, "the upgrade note is not the adoption note")
        for origin in [C11UpgradeOrigin.fresh, .c11v1, .adopted, .both] {
            XCTAssertEqual(decide(origin, qa: .on(.fresh)), .nothing)
            XCTAssertEqual(decide(origin, qa: .on(.resume)), .nothing)
        }
        XCTAssertEqual(WhatsDifferent.autoPresentation(qa: .off, origin: .c11v1, upgradeNoteShown: true,
                                                       adoptNoteShown: false, shownVersion: 1, current: 2), .standard,
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
        // C11H-335: the migration records an adoption under the earlier app's
        // name; reading it as fresh hid the adoption note.
        let adopted = self.defaults()
        adopted.set(C11MigrationExecutor.adoptedOrigin, forKey: C11UpgradeOrigin.defaultsKey)
        XCTAssertEqual(C11UpgradeOrigin.current(defaults: adopted), .adopted)
        adopted.set(C11MigrationExecutor.adoptedBesideOneXOrigin, forKey: C11UpgradeOrigin.defaultsKey)
        XCTAssertEqual(C11UpgradeOrigin.current(defaults: adopted), .both)
        XCTAssertEqual(WhatsDifferent.audience(origin: .adopted), .adopted)
        XCTAssertEqual(WhatsDifferent.audience(origin: .both), .adopted)
        WhatsDifferent.markShown(.adopted, defaults: adopted)
        XCTAssertTrue(WhatsDifferent.adoptNoteShown(defaults: adopted))
        XCTAssertFalse(WhatsDifferent.upgradeNoteShown(defaults: adopted))
        XCTAssertEqual(WhatsDifferent.shownVersion(defaults: adopted), WhatsDifferent.contentVersion)

        WhatsDifferent.markShown(.upgradeFrom1x, defaults: defaults)
        XCTAssertTrue(WhatsDifferent.upgradeNoteShown(defaults: defaults))
        XCTAssertEqual(WhatsDifferent.autoPresentation(
            qa: .off, origin: .c11v1, upgradeNoteShown: WhatsDifferent.upgradeNoteShown(defaults: defaults),
            adoptNoteShown: false, shownVersion: WhatsDifferent.shownVersion(defaults: defaults)), .nothing)

        let fresh = self.defaults()
        WhatsDifferent.markShown(.standard, defaults: fresh)
        XCTAssertFalse(WhatsDifferent.upgradeNoteShown(defaults: fresh))
        XCTAssertFalse(WhatsDifferent.adoptNoteShown(defaults: fresh))
        XCTAssertEqual(WhatsDifferent.shownVersion(defaults: fresh), WhatsDifferent.contentVersion)
    }

    /// C11H-335: one page per concept, the one that can lose work first; an
    /// adopted profile reads only what changed. Commands render as code, and
    /// the earlier app's name reaches the copy that names it.
    func testPagesPerVariantAndTheirCopy() {
        XCTAssertEqual(WhatsDifferent.pages(for: .standard), [.terminals, .machines, .mail])
        XCTAssertEqual(WhatsDifferent.pages(for: .upgradeFrom1x), [.terminals, .machines, .mail])
        XCTAssertEqual(WhatsDifferent.pages(for: .adopted), [.adopted])
        XCTAssertNotEqual(WhatsDifferentSheet.title(.terminals, .upgradeFrom1x), WhatsDifferentSheet.title(.terminals, .standard))

        let adoptedTitle = WhatsDifferentSheet.title(.adopted, .adopted)
        XCTAssertTrue(adoptedTitle.contains(C11Identity.Legacy.appName), adoptedTitle)
        XCTAssertFalse(adoptedTitle.contains("%@"), adoptedTitle)
        for page in WhatsDifferentPage.allCases {
            let audience: WhatsDifferentAudience = page == .adopted ? .adopted : .standard
            for point in WhatsDifferentSheet.points(page, audience) {
                let text = String(point.detail.characters)
                XCTAssertFalse(text.contains("%@") || text.contains("%1$@") || text.contains("`"), "\(page): \(text)")
            }
        }

        let code = WhatsDifferentSheet.inline("Run `c11 machine link --host <ssh-target>` there.")
        XCTAssertEqual(String(code.characters), "Run c11 machine link --host <ssh-target> there.")
        XCTAssertTrue(code.runs.contains { $0.inlinePresentationIntent == .code
            && String(code[$0.range].characters) == "c11 machine link --host <ssh-target>" })
    }

    /// C11H-335: every label the pictures set in a box of fixed size fits that
    /// box in every language the app ships, laid out at the font and width the
    /// sheet draws it at. The strings are the built app's own tables, else the
    /// catalog they are built from.
    func testEveryBoxedLabelFitsInEveryLanguage() throws {
        let locales = ["en", "ja", "uk", "ko", "zh-Hans", "zh-Hant", "ru"]
        let table = try Self.translations(locales: locales)
        var misfits: [String] = []
        for label in WhatsDifferentFit.labels {
            for locale in locales {
                guard let text = table[locale]?[label.key], !text.isEmpty else {
                    misfits.append("\(label.key) [\(locale)]: no translation")
                    continue
                }
                let lines = WhatsDifferentFit.lines(text, as: label, locale: Locale(identifier: locale))
                if lines > label.lines {
                    misfits.append("\(label.key) [\(locale)]: \(lines) lines in \(Int(label.width)) pt where \(label.lines) fit: \(text)")
                }
            }
        }
        // Two labels sharing a row fit it together, on one line each.
        for pair in WhatsDifferentFit.pairs {
            for locale in locales {
                guard let first = table[locale]?[pair.first.key], let second = table[locale]?[pair.second.key] else {
                    misfits.append("\(pair.first.key) + \(pair.second.key) [\(locale)]: no translation")
                    continue
                }
                let used = WhatsDifferentFit.width(first, as: pair.first, locale: Locale(identifier: locale))
                    + WhatsDifferentFit.width(second, as: pair.second, locale: Locale(identifier: locale))
                if used > pair.width {
                    misfits.append("\(pair.first.key) + \(pair.second.key) [\(locale)]: \(Int(used.rounded(.up))) pt in \(Int(pair.width)) pt: \(first) / \(second)")
                }
            }
        }
        for (text, label) in WhatsDifferentFit.verbatim {
            let lines = WhatsDifferentFit.lines(text, as: label, locale: Locale(identifier: "en"))
            if lines > label.lines {
                misfits.append("\(label.key): \(lines) lines in \(Int(label.width)) pt where \(label.lines) fit: \(text)")
            }
        }
        XCTAssertEqual(misfits, [], misfits.joined(separator: "\n"))
        // The measures are not vacuous: a long line wraps, and a long pair overflows its row.
        XCTAssertGreaterThan(WhatsDifferentFit.lines(String(repeating: "terminal ", count: 40),
                                                     as: WhatsDifferentFit.labels[0], locale: Locale(identifier: "en")), 1)
        let pair = WhatsDifferentFit.pairs[0]
        XCTAssertGreaterThan(WhatsDifferentFit.width(String(repeating: "still running ", count: 3), as: pair.first, locale: Locale(identifier: "en"))
                                 + WhatsDifferentFit.width(String(repeating: "still running ", count: 3), as: pair.second, locale: Locale(identifier: "en")),
                             pair.width)
    }

    private static func translations(locales: [String]) throws -> [String: [String: String]] {
        let app = Bundle(for: WhatsDifferentModel.self)
        var built: [String: [String: String]] = [:]
        for locale in locales {
            guard let path = app.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: locale),
                  let table = NSDictionary(contentsOfFile: path) as? [String: String] else { break }
            built[locale] = table
        }
        if built.count == locales.count {
            print("WhatsDifferentTests fit: the built app's string tables at \(app.bundlePath)")
            return built
        }
        print("WhatsDifferentTests fit: the catalog")
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
        var out: [String: [String: String]] = [:]
        for (key, entry) in json?["strings"] as? [String: [String: Any]] ?? [:] {
            for (locale, unit) in entry["localizations"] as? [String: [String: Any]] ?? [:] {
                if let value = (unit["stringUnit"] as? [String: Any])?["value"] as? String { out[locale, default: [:]][key] = value }
            }
        }
        return out
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
