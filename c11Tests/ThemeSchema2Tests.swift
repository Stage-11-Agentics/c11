import AppKit
import Foundation
import XCTest
@testable import c11

/// Schema 2 (docs/c11-theme-schema-2.md): new optional sections, unset by default.
final class ThemeSchema2Tests: XCTestCase {
    private func theme(_ body: String, schema: Int = 2, name: String = "t") throws -> C11Theme {
        let source = """
        [identity]
        name = "\(name)"
        display_name = "T"
        author = "test"
        version = "0.01.001"
        schema = \(schema)

        [palette]
        ink = "#101010"
        hot = "#FF4F1F"

        [variables]
        background = "$palette.ink"
        accent = "$palette.hot"

        \(body)
        """
        let table = try TomlSubsetParser.parse(file: "\(name).toml", source: source)
        return try C11Theme.fromToml(table)
    }

    private func assertHex(_ color: NSColor?, _ hex: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let color = color?.usingColorSpace(.sRGB) else {
            return XCTFail("no colour, expected \(hex)", file: file, line: line)
        }
        let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
            .map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
        XCTAssertEqual("#" + rgb, hex, file: file, line: line)
    }

    private let dark = ThemeContext(workspaceColor: nil, colorScheme: .dark, ghosttyBackgroundGeneration: 0)

    func testSchema2SectionsParseIntoStyles() throws {
        let t = try theme("""
        [type]
        mono = "JetBrains Mono"

        [type.cardLabel]
        family   = "mono"
        case     = "upper"
        tracking = 0.1
        scale    = 1

        [geometry]
        cardRadius   = 0
        tabSelection = "invert"

        [chrome.card]
        fill  = "$background"
        sheen = false

        [chrome.tabBar]
        activeText = "$palette.ink"

        [states]
        waiting = "$accent"

        [ornaments]
        scanlines = 0.14
        """)

        XCTAssertEqual(t.styleValue(.typeMono)?.string, "JetBrains Mono")
        XCTAssertEqual(t.styleValue(.text(.cardLabel, .case))?.string, "upper")
        XCTAssertEqual(t.styleValue(.text(.cardLabel, .scale))?.number, 1)
        XCTAssertEqual(t.styleValue(.cardRadius)?.number, 0)
        XCTAssertEqual(t.styleValue(.tabSelection)?.string, "invert")
        XCTAssertEqual(t.styleValue(.cardSheen)?.bool, false)
        XCTAssertEqual(t.styleValue(.tabActiveText)?.string, "$palette.ink")
        XCTAssertEqual(t.styleValue(.ornamentScanlines)?.number, 0.14)

        let snapshot = ResolvedThemeSnapshot(theme: t)
        assertHex(snapshot.resolveStyleColor(.stateWaiting, context: dark), "#FF4F1F")
        assertHex(snapshot.resolveStyleColor(.cardFill, context: dark), "#101010")

        let label = snapshot.resolveTextStyle(.cardLabel)
        XCTAssertEqual(label.familyName, "JetBrains Mono")
        XCTAssertEqual(label.uppercase, true)
        XCTAssertEqual(label.tracking, 0.1)
        XCTAssertEqual(label.apply("Needs input"), "NEEDS INPUT")
    }

    func testUnsetRolesResolveToNil() throws {
        let snapshot = ResolvedThemeSnapshot(theme: try theme(""))
        for definition in ThemeStyleRoleRegistry.all {
            let role = ThemeStyleRole(definition.path)
            XCTAssertNil(snapshot.resolveStyleColor(role, context: dark), definition.path)
            XCTAssertNil(snapshot.resolveStyleGradient(role, context: dark), definition.path)
            XCTAssertNil(snapshot.resolveStyleNumber(role), definition.path)
            XCTAssertNil(snapshot.resolveStyleBool(role), definition.path)
            XCTAssertNil(snapshot.resolveStyleString(role), definition.path)
        }
        XCTAssertTrue(snapshot.resolveTextStyle(.tab).isUnset)
    }

    func testSchema1IgnoresSchema2Sections() throws {
        let t = try theme("""
        [geometry]
        cardRadius = 0
        """, schema: 1)
        XCTAssertNil(t.styles)
        XCTAssertNil(ResolvedThemeSnapshot(theme: t).resolveStyleNumber(.cardRadius))
    }

    func testUnknownSchemaIsRejected() {
        XCTAssertThrowsError(try theme("", schema: 3)) { error in
            XCTAssertEqual(error as? ThemeLoadError, .schemaMismatch(3))
        }
    }

    func testUnknownChoiceIsALoadError() {
        XCTAssertThrowsError(try theme("""
        [geometry]
        tabSelection = "sideways"
        """))
        XCTAssertThrowsError(try theme("""
        [type.tab]
        case = "title"
        """))
    }

    func testWrongTypeIsALoadError() {
        XCTAssertThrowsError(try theme("""
        [geometry]
        cardRadius = "square"
        """))
        XCTAssertThrowsError(try theme("""
        [ornaments]
        bust = "yes"
        """))
    }

    func testUnknownKeysInSchema2SectionsAreIgnored() throws {
        let t = try theme("""
        [geometry]
        cardRadius = 2
        wobble     = 3
        """)
        XCTAssertEqual(t.styleValue(.cardRadius)?.number, 2)
        XCTAssertEqual(C11Theme.unknownSchema2Keys(root: try TomlSubsetParser.parse(file: "x", source: """
        [geometry]
        wobble = 3
        [chrome.tabBar]
        background = "#000000"
        sparkle = "#FFFFFF"
        """)), ["chrome.tabBar.sparkle", "geometry.wobble"])
    }

    func testGradientParsesAndResolves() throws {
        let t = try theme("""
        [backdrop]
        kind     = "gradient"
        gradient = "#2D1060 0%, $palette.hot.mix($background, 0.5) 42%, #C2307F 100%"

        [chrome.pill]
        fill = "$accent"
        """)
        let snapshot = ResolvedThemeSnapshot(theme: t)
        let gradient = try XCTUnwrap(snapshot.resolveStyleGradient(.backdropGradient, context: dark))
        XCTAssertEqual(gradient.stops.map(\.location), [0, 0.42, 1])
        assertHex(gradient.stops.first?.color, "#2D1060")

        let pill = try XCTUnwrap(snapshot.resolveStyleGradient(.pillFill, context: dark))
        XCTAssertEqual(pill.stops.count, 1)
        assertHex(pill.firstColor, "#FF4F1F")
    }

    func testMalformedGradientIsALoadError() {
        for bad in ["#000000 0%, #FFFFFF", "#000000 50%, #FFFFFF 10%", "#000000 140%", "#000000 0%,, #FFFFFF 100%",
                    "$accent.mix($background, 0.3 50%", "#000000 0%), #FFFFFF 100%", "50%", "$accent.mux($background, 0.3) 0%, #FFFFFF 100%"] {
            XCTAssertThrowsError(try theme("""
            [backdrop]
            gradient = "\(bad)"
            """), bad)
        }
    }

    func testSchema1WithBadSchema2ValuesStillLoads() throws {
        let t = try theme("""
        [geometry]
        cardRadius = "square"
        [chrome.tabBar]
        text = { enabled = false }
        """, schema: 1)
        XCTAssertNil(t.styles)
    }

    func testBadColourExpressionFailsAtLoad() {
        XCTAssertThrowsError(try theme("""
        [chrome.card]
        fill = "$background.lighten("
        """))
    }

    func testStyleWithoutFamilyUsesTypeUI() throws {
        let snapshot = ResolvedThemeSnapshot(theme: try theme("""
        [type]
        ui = "JetBrains Mono"
        [type.tab]
        case = "upper"
        """))
        XCTAssertEqual(snapshot.resolveTextStyle(.tab).familyName, "JetBrains Mono")
        XCTAssertEqual(snapshot.resolveTextStyle(.pill).familyName, "JetBrains Mono")
    }

    func testNumbersClampToTheirRange() throws {
        let snapshot = ResolvedThemeSnapshot(theme: try theme("""
        [geometry]
        cardRadius = -4
        progressHeightPt = 99
        [type.tab]
        scale = 0
        [ornaments]
        scanlines = 3
        """))
        XCTAssertEqual(snapshot.resolveStyleNumber(.cardRadius), 0)
        XCTAssertEqual(snapshot.resolveStyleNumber(.progressHeightPt), 12)
        XCTAssertEqual(snapshot.resolveStyleNumber(.text(.tab, .scale)), 0.5)
        XCTAssertEqual(snapshot.resolveStyleNumber(.ornamentScanlines), 1)
    }

    func testBundledJetBrainsMonoRegistersAndDraws() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts/JetBrainsMono-Variable.ttf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        ThemeFontFamily.registerFonts(at: [url])
        XCTAssertTrue(ThemeFontFamily.isAvailable("JetBrains Mono"))
        let font = ThemeFontFamily.nsFont(named: "JetBrains Mono", size: 11, weight: .semibold, monospaced: false)
        XCTAssertEqual(font.familyName, "JetBrains Mono")
        XCTAssertTrue(font.isFixedPitch)
    }

    func testMissingFontFamilyFallsBackWithoutCrashing() {
        defer { ThemeFontFamily.resetAvailabilityCache() }
        XCTAssertFalse(ThemeFontFamily.isAvailable("No Such Family 7f3a"))
        XCTAssertTrue(ThemeFontFamily.isAvailable("system-mono"))
        let font = ThemeFontFamily.nsFont(named: "No Such Mono 7f3a", size: 11, weight: .regular, monospaced: false)
        XCTAssertTrue(font.isFixedPitch)
    }

    func testRegistryPathsAreUniqueAndCoverEveryTextStyle() {
        let paths = ThemeStyleRoleRegistry.all.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count)
        for style in ThemeTextStyleName.allCases {
            for attribute in ThemeTextStyleAttribute.allCases {
                XCTAssertNotNil(ThemeStyleRole.text(style, attribute).definition, "\(style).\(attribute)")
            }
        }
        // No schema-2 path collides with a schema-1 role.
        let schema1 = Set(ThemeRole.allCases.map(\.definition.path))
        XCTAssertTrue(schema1.isDisjoint(with: paths))
    }

    func testEveryBundledThemeLoads() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/c11-themes")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "toml" }
        XCTAssertFalse(files.isEmpty)
        for url in files {
            let table = try TomlSubsetParser.parse(file: url.path, source: try String(contentsOf: url, encoding: .utf8))
            let loaded = try C11Theme.fromToml(table)
            XCTAssertEqual(loaded.identity.name, url.deletingPathExtension().lastPathComponent)
            if loaded.identity.schema == 1 {
                XCTAssertNil(loaded.styles, url.lastPathComponent)
            }
            // Every colour and gradient a theme sets must resolve, and so must every schema-1 colour role.
            // `$ghosttyBackground` and `$workspaceColor` need a live app, so expressions that reach them
            // (directly or through a variable) are skipped here.
            var tainted: Set<String> = ["ghosttyBackground", "workspaceColor"]
            var grew = true
            while grew {
                grew = false
                for (name, expr) in loaded.variables where !tainted.contains(name) {
                    if tainted.contains(where: { expr.contains("$\($0)") }) { tainted.insert(name); grew = true }
                }
            }
            func needsApp(_ expr: String) -> Bool { tainted.contains { expr.contains("$\($0)") } }
            let snapshot = ResolvedThemeSnapshot(theme: loaded)
            for (path, value) in loaded.styles ?? [:] where !needsApp(value.string ?? "") {
                let role = ThemeStyleRole(path)
                switch role.definition?.kind {
                case .color?:
                    XCTAssertNotNil(snapshot.resolveStyleColor(role, context: dark), "\(url.lastPathComponent) \(path) = \(value.string ?? "")")
                case .gradient?:
                    XCTAssertNotNil(snapshot.resolveStyleGradient(role, context: dark), "\(url.lastPathComponent) \(path) = \(value.string ?? "")")
                default:
                    break
                }
            }
            for role in ThemeRole.allCases where role.definition.expectedType == .color && loaded.stringValue(for: role) != nil {
                if needsApp(loaded.stringValue(for: role) ?? "") { continue }
                XCTAssertNotNil(snapshot.resolveColor(role: role, context: dark), "\(url.lastPathComponent) \(role.definition.path)")
            }
        }
    }
}

/// `[terminal] pairedTheme` and `c11 themes set --with-terminal` (C11H-170). The bundled
/// themes and their Ghostty files are checked in the built app by `CLIThemesWithTerminalTests`.
final class TerminalThemePairingTests: XCTestCase {
    private func theme(name: String = "t", schema: Int = 2, _ body: String) throws -> C11Theme {
        let source = """
        [identity]
        name = "\(name)"
        display_name = "T"
        author = "test"
        version = "0.01.001"
        schema = \(schema)

        [palette]
        ink = "#101010"

        [variables]
        background = "$palette.ink"

        \(body)
        """
        return try C11Theme.fromToml(try TomlSubsetParser.parse(file: "\(name).toml", source: source))
    }

    func testPairParsesTrimmed() throws {
        let t = try theme("[terminal]\npairedTheme = \"  c11-nocturne \"")
        XCTAssertEqual(t.pairedTerminalTheme, "c11-nocturne")
    }

    func testEmptyOrAbsentPairIsNoPair() throws {
        XCTAssertNil(try theme("[terminal]\npairedTheme = \"  \"").pairedTerminalTheme)
        XCTAssertNil(try theme("").pairedTerminalTheme)
    }

    func testSchema1IgnoresThePair() throws {
        XCTAssertNil(try theme(schema: 1, "[terminal]\npairedTheme = \"c11-nocturne\"").pairedTerminalTheme)
    }

    func testPairThatIsNotAStringIsALoadError() {
        XCTAssertThrowsError(try theme("[terminal]\npairedTheme = 3"))
    }

    /// The app's `theme.list` reply, sent over the wire, gives the CLI each theme's pair;
    /// a reply from an app that predates pairing reads as unsupported, not as unpaired.
    func testListReplyCarriesPairsTheCLIReads() throws {
        let themes = [
            try theme(name: "paired", "[terminal]\npairedTheme = \"c11-nocturne\""),
            try theme(name: "plain", ""),
        ]
        let descriptors = themes.map { ThemeManager.ThemeDescriptor(identity: $0.identity, source: .builtin, sourcePath: nil) }
        var pairs: [String: String] = [:]
        for theme in themes { pairs[theme.identity.name] = theme.pairedTerminalTheme }
        let reply = ThemeSocketMethods.listPayload(descriptors: descriptors, active: "paired", pairs: pairs)
        let wire = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: reply)) as? [String: Any]
        let items = try XCTUnwrap(wire?["themes"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0["name"] as? String ?? "", $0) })
        XCTAssertEqual(wire?["active"] as? String, "paired")
        XCTAssertEqual(byName["paired"]?["is_active"] as? Bool, true)
        XCTAssertEqual(byName["plain"]?["is_active"] as? Bool, false)

        XCTAssertEqual(TerminalThemePairing.lookup(in: try XCTUnwrap(byName["paired"])), .paired("c11-nocturne"))
        XCTAssertEqual(TerminalThemePairing.lookup(in: try XCTUnwrap(byName["plain"])), .unpaired)
        var older = try XCTUnwrap(byName["paired"])
        older.removeValue(forKey: TerminalThemePairing.pairKey)
        XCTAssertEqual(TerminalThemePairing.lookup(in: older), .unsupported)
    }

    func testGetReplyNamesTheThemeAndItsPair() {
        let paired = ThemeSocketMethods.getPayload(active: "nocturne", pair: "c11-nocturne")
        XCTAssertEqual(paired["name"] as? String, "nocturne")
        XCTAssertEqual(paired[TerminalThemePairing.pairKey] as? String, "c11-nocturne")
        XCTAssertTrue(ThemeSocketMethods.getPayload(active: "stage11", pair: nil)[TerminalThemePairing.pairKey] is NSNull)
    }
}

/// C11H-187: c11 shows one theme, day and night. A pick shows at once and is kept; the
/// upgrade from day and night themes keeps the day theme.
@MainActor
final class OneThemeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var themesDir: URL!

    override func setUp() async throws {
        suiteName = "c11-one-theme-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        themesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)
        for name in ["dayt", "nightt", "othert"] {
            let source = """
            [identity]
            name = "\(name)"
            display_name = "\(name)"
            author = "test"
            version = "0.01.001"
            schema = 1

            [palette]
            ink = "#101010"
            hot = "#FF4F1F"

            [variables]
            background = "$palette.ink"
            accent = "$palette.hot"
            """
            let table = try TomlSubsetParser.parse(file: "\(name).toml", source: source)
            XCTAssertEqual(try C11Theme.fromToml(table).identity.name, name)
            try source.write(to: themesDir.appendingPathComponent("\(name).toml"), atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: themesDir)
    }

    private func makeManager() -> ThemeManager {
        ThemeManager(
            notificationCenter: NotificationCenter(),
            pathsOverride: .init(userThemesDirectory: themesDir, builtinDirectory: themesDir),
            selectionDefaults: defaults
        )
    }

    func testAPickShowsAtOnceAndIsKept() {
        let manager = makeManager()
        let before = manager.version
        XCTAssertTrue(manager.setActiveTheme(name: "othert"))
        XCTAssertEqual(manager.active.identity.name, "othert")
        XCTAssertGreaterThan(manager.version, before)
        XCTAssertEqual(makeManager().active.identity.name, "othert", "a new launch shows the same theme")
    }

    func testAnUnknownThemeChangesNothing() {
        let manager = makeManager()
        XCTAssertTrue(manager.setActiveTheme(name: "dayt"))
        XCTAssertFalse(manager.setActiveTheme(name: "phosphor"))
        XCTAssertEqual(manager.active.identity.name, "dayt")
        XCTAssertEqual(manager.activeThemeName, "dayt")
    }

    func testTheUpgradeKeepsTheDayTheme() {
        defaults.set("dayt", forKey: "theme.active.light")
        defaults.set("nightt", forKey: "theme.active.dark")
        let manager = makeManager()
        XCTAssertEqual(manager.active.identity.name, "dayt")
        XCTAssertNil(defaults.string(forKey: "theme.active.dark"), "the night theme is gone after the upgrade")
    }

    func testTheUpgradeFromARetiredDayThemeKeepsTheNightTheme() {
        defaults.set("phosphor", forKey: "theme.active.light")
        defaults.set("nightt", forKey: "theme.active.dark")
        let manager = makeManager()
        XCTAssertEqual(manager.active.identity.name, "nightt")
        XCTAssertEqual(manager.activeThemeName, "nightt")
    }

    func testTheUpgradeWithOnlyANightThemeKeepsIt() {
        defaults.set("nightt", forKey: "theme.active.dark")
        let manager = makeManager()
        XCTAssertEqual(manager.active.identity.name, "nightt")
        XCTAssertNil(defaults.string(forKey: "theme.active.dark"))
    }
}

/// C11H-187: the app ships the seven c11 themes and no others.
@MainActor
final class BundledThemeSetTests: XCTestCase {
    func testTheBundleHoldsExactlyTheSevenC11hThemes() throws {
        let bundled = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/c11-themes", isDirectory: true)
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("c11-no-user-themes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let suite = "c11-bundled-set-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let manager = ThemeManager(
            notificationCenter: NotificationCenter(),
            pathsOverride: .init(userThemesDirectory: empty, builtinDirectory: bundled),
            selectionDefaults: defaults
        )
        let builtin = manager.availableThemes.filter { $0.source == .builtin }
        XCTAssertEqual(
            Set(builtin.map(\.identity.name)),
            ["stage11", "c11", "nocturne", "bigboard", "datasheet-mono", "terminal-grid", "outrun-horizon"]
        )
        XCTAssertTrue(builtin.allSatisfy { $0.warning == nil }, "every bundled theme loads cleanly")
    }
}

/// C11H-187: Settings and the CLI write the same managed terminal block, and keep the rest
/// of c11's `config.ghostty` as written.
final class TerminalThemeOverrideTests: XCTestCase {
    func testWritingThePairKeepsTheRestOfTheFile() {
        let existing = "font-size = 13\n\n# cmux themes start\ntheme = light:Old,dark:Old\n# cmux themes end\n"
        let next = TerminalThemeOverride.contents(
            settingTheme: TerminalThemeOverride.value(pairing: "c11-nocturne"), in: existing
        )
        XCTAssertEqual(next, "font-size = 13\n\n# cmux themes start\ntheme = light:c11-nocturne,dark:c11-nocturne\n# cmux themes end\n")
        XCTAssertEqual(TerminalThemeOverride.removingBlock(from: next).trimmingCharacters(in: .whitespacesAndNewlines), "font-size = 13")
    }

    func testAFileWithNoBlockGetsOne() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c11-override-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(TerminalThemeOverride.appConfigURL(bundleIdentifier: "com.stage11.c11.test", applicationSupport: dir))
        XCTAssertEqual(url.path, dir.appendingPathComponent("com.stage11.c11.test/config.ghostty").path)
        try TerminalThemeOverride.write(settingTheme: TerminalThemeOverride.value(pairing: "p"), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# cmux themes start\ntheme = light:p,dark:p\n# cmux themes end\n")
    }

    func testThePreviewReadsAGhosttyThemesColours() throws {
        let colors = try XCTUnwrap(GhosttyThemeColors.parse("palette = 0=#000000\nbackground = #07080A\nforeground = #E4E6EA\n"))
        XCTAssertEqual(colors.background, GhosttyThemeColors.hexColor("#07080A"))
        XCTAssertEqual(colors.foreground, GhosttyThemeColors.hexColor("E4E6EA"))
        XCTAssertNil(GhosttyThemeColors.parse("background = #07080A\n"))
    }
}

/// C11H-187: a Settings pick sets the one theme, and a paired theme sets the terminal in this
/// app's own config.ghostty. Without a bundle id nothing is written, never the installed
/// app's file.
@MainActor
final class ThemePickingTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var root: URL!
    private var manager: ThemeManager!
    private var reloads = 0

    override func setUp() async throws {
        suiteName = "c11-theme-picking-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        let themes = root.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        for (name, schema, extra) in [("plaint", 1, ""), ("pairedt", 2, "[terminal]\npairedTheme = \"c11-nocturne\"\n")] {
            let source = """
            [identity]
            name = "\(name)"
            display_name = "\(name)"
            author = "test"
            version = "0.01.001"
            schema = \(schema)

            [palette]
            ink = "#101010"
            hot = "#FF4F1F"

            [variables]
            background = "$palette.ink"
            accent = "$palette.hot"

            \(extra)
            """
            try source.write(to: themes.appendingPathComponent("\(name).toml"), atomically: true, encoding: .utf8)
        }
        manager = ThemeManager(
            notificationCenter: NotificationCenter(),
            pathsOverride: .init(userThemesDirectory: themes, builtinDirectory: themes),
            selectionDefaults: defaults
        )
        XCTAssertNotNil(manager.theme(named: "pairedt")?.pairedTerminalTheme, "fixture parses with its pair")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func pick(_ name: String, bundleIdentifier: String? = "com.stage11.c11.test") -> URL? {
        ThemePicking.pick(name, themes: manager, bundleIdentifier: bundleIdentifier, applicationSupport: root) { [unowned self] in
            self.reloads += 1
        }
    }

    func testAPairedThemeSetsTheTerminalInThisAppsOwnConfig() throws {
        let url = try XCTUnwrap(pick("pairedt"))
        XCTAssertEqual(url.path, root.appendingPathComponent("com.stage11.c11.test/config.ghostty").path)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("theme = light:c11-nocturne,dark:c11-nocturne"))
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(manager.active.identity.name, "pairedt")
    }

    func testAThemeWithoutAPairLeavesTheTerminalAlone() {
        XCTAssertNil(pick("plaint"))
        XCTAssertEqual(manager.active.identity.name, "plaint")
        XCTAssertEqual(reloads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("com.stage11.c11.test").path))
    }

    func testWithoutABundleIdNothingIsWritten() throws {
        XCTAssertNil(pick("pairedt", bundleIdentifier: nil))
        let written = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0 != "themes" }
        XCTAssertEqual(written, [], "no config.ghostty anywhere, least of all the installed app's")
        XCTAssertEqual(reloads, 0)
    }

    func testAnUnknownThemeChangesNothing() {
        XCTAssertNotNil(pick("pairedt"))
        XCTAssertNil(pick("phosphor"))
        XCTAssertEqual(manager.active.identity.name, "pairedt")
        XCTAssertEqual(reloads, 1)
    }
}
