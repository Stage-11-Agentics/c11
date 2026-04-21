import XCTest
@testable import cmux

final class ThemeCycleAndInvalidValueTests: XCTestCase {
    func testVariableCycleFailsAtLoadTime() throws {
        let source = """
        [identity]
        name = "cycle"
        display_name = "Cycle"
        author = "tests"
        version = "0.0.1"
        schema = 1

        [palette]
        base = "#000000"

        [variables]
        a = "$b"
        b = "$a"

        [chrome.titleBar]
        background = "$a"
        """

        let table = try TomlSubsetParser.parse(file: "cycle.toml", source: source)
        XCTAssertThrowsError(try C11muxTheme.fromToml(table)) { error in
            guard case ThemeLoadError.variableCycle = error else {
                return XCTFail("expected variableCycle, got \(error)")
            }
        }
    }

    func testInvalidPaletteHexFailsAtLoadTime() throws {
        let source = """
        [identity]
        name = "invalid-hex"
        display_name = "Invalid Hex"
        author = "tests"
        version = "0.0.1"
        schema = 1

        [palette]
        base = "#GGGGGG"

        [variables]
        background = "$palette.base"

        [chrome.titleBar]
        background = "$background"
        """

        let table = try TomlSubsetParser.parse(file: "invalid.toml", source: source)
        XCTAssertThrowsError(try C11muxTheme.fromToml(table)) { error in
            guard case ThemeLoadError.invalidHex = error else {
                return XCTFail("expected invalidHex, got \(error)")
            }
        }
    }

    func testUnknownModifierFailsAtLoadTime() throws {
        let source = """
        [identity]
        name = "unknown-mod"
        display_name = "Unknown Modifier"
        author = "tests"
        version = "0.0.1"
        schema = 1

        [palette]
        base = "#101010"

        [variables]
        background = "$palette.base.unknown(0.5)"

        [chrome.titleBar]
        background = "$background"
        """

        let table = try TomlSubsetParser.parse(file: "unknown-mod.toml", source: source)
        XCTAssertThrowsError(try C11muxTheme.fromToml(table)) { error in
            guard case ThemeLoadError.variableExpression = error else {
                return XCTFail("expected variableExpression, got \(error)")
            }
        }
    }

    func testOpacityValuesClampIntoUnitInterval() throws {
        var theme = C11muxTheme.fallbackStage11
        theme.chrome.sidebar.tintBaseOpacity = 1.5

        let snapshot = ResolvedThemeSnapshot(theme: theme)
        let context = ThemeContext(
            workspaceColor: "#C0392B",
            colorScheme: .dark,
            forceBright: false,
            ghosttyBackgroundGeneration: 0,
            isWindowFocused: true,
            workspaceState: nil
        )

        let clamped = try XCTUnwrap(snapshot.resolveNumber(role: .sidebar_tintBaseOpacity, context: context))
        XCTAssertEqual(clamped, 1.0, accuracy: 0.0001)
    }

    func testThicknessValuesClampToRange() throws {
        var theme = C11muxTheme.fallbackStage11
        theme.chrome.dividers.thicknessPt = -4
        theme.chrome.windowFrame.thicknessPt = 99

        let snapshot = ResolvedThemeSnapshot(theme: theme)
        let context = ThemeContext(
            workspaceColor: "#C0392B",
            colorScheme: .dark,
            forceBright: false,
            ghosttyBackgroundGeneration: 0,
            isWindowFocused: true,
            workspaceState: nil
        )

        let divider = try XCTUnwrap(snapshot.resolveNumber(role: .dividers_thicknessPt, context: context))
        let frame = try XCTUnwrap(snapshot.resolveNumber(role: .windowFrame_thicknessPt, context: context))

        XCTAssertEqual(divider, 0.0, accuracy: 0.0001)
        XCTAssertEqual(frame, 8.0, accuracy: 0.0001)
    }
}
