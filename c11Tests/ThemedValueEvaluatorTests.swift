import AppKit
import XCTest
@testable import cmux

final class ThemedValueEvaluatorTests: XCTestCase {
    func testResolvesDirectVariableReference() throws {
        let ast = try ThemedValueParser.parse("$foreground")
        let expected = try XCTUnwrap(NSColor(hex: "#E9EAEB"))

        let resolved = ThemedValueEvaluator.evaluate(
            ast,
            context: defaultContext,
            warningKey: "foreground",
            colorLookup: { path, _ in
                guard path == ["foreground"] else { return nil }
                return expected
            }
        )

        assertColor(resolved, matches: expected)
    }

    func testResolvesWorkspaceOpacity() throws {
        let ast = try ThemedValueParser.parse("$workspaceColor.opacity(0.08)")
        let workspace = try XCTUnwrap(NSColor(hex: "#C0392B"))

        let context = ThemeContext(
            workspaceColor: "#C0392B",
            colorScheme: .dark,
            forceBright: false,
            ghosttyBackgroundGeneration: 0
        )

        let resolved = ThemedValueEvaluator.evaluate(
            ast,
            context: context,
            warningKey: "workspace.opacity",
            colorLookup: { path, _ in
                guard path == ["workspaceColor"] else { return nil }
                return workspace
            }
        )

        let expected = workspace.withAlphaComponent(0.08)
        assertColor(resolved, matches: expected)
    }

    func testResolvesMixModifier() throws {
        let ast = try ThemedValueParser.parse("$background.mix($accent, 0.5)")
        let background = try XCTUnwrap(NSColor(hex: "#0A0C0F"))
        let accent = try XCTUnwrap(NSColor(hex: "#C4A561"))

        let resolved = ThemedValueEvaluator.evaluate(
            ast,
            context: defaultContext,
            warningKey: "mix",
            colorLookup: { path, _ in
                switch path {
                case ["background"]:
                    return background
                case ["accent"]:
                    return accent
                default:
                    return nil
                }
            }
        )

        let expected = try XCTUnwrap(linearMix(background, accent, amount: 0.5))
        assertColor(resolved, matches: expected)
    }

    func testModifierEvaluationOrderIsLeftToRight() throws {
        let first = try ThemedValueParser.parse("$x.opacity(0.5).mix($y, 0.3)")
        let second = try ThemedValueParser.parse("$x.mix($y, 0.3).opacity(0.5)")

        let lookup: ThemedValueEvaluator.ColorLookup = { path, _ in
            switch path {
            case ["x"]:
                return NSColor(hex: "#FF0000")
            case ["y"]:
                return NSColor(hex: "#0000FF")
            default:
                return nil
            }
        }

        let firstResolved = ThemedValueEvaluator.evaluate(
            first,
            context: defaultContext,
            warningKey: "order.first",
            colorLookup: lookup
        )
        let secondResolved = ThemedValueEvaluator.evaluate(
            second,
            context: defaultContext,
            warningKey: "order.second",
            colorLookup: lookup
        )

        XCTAssertNotNil(firstResolved)
        XCTAssertNotNil(secondResolved)
        assertColorsNotEqual(firstResolved, secondResolved)
    }

    func testClampWarningEmitsOncePerKey() throws {
        let ast = try ThemedValueParser.parse("$x.opacity(1.5)")
        let x = try XCTUnwrap(NSColor(hex: "#112233"))
        var warnings: [String] = []

        ThemeWarnings.resetForTesting()

        let first = ThemedValueEvaluator.evaluate(
            ast,
            context: defaultContext,
            warningKey: "clamp.opacity",
            colorLookup: { path, _ in
                path == ["x"] ? x : nil
            },
            warn: { warnings.append($0) }
        )

        let second = ThemedValueEvaluator.evaluate(
            ast,
            context: defaultContext,
            warningKey: "clamp.opacity",
            colorLookup: { path, _ in
                path == ["x"] ? x : nil
            },
            warn: { warnings.append($0) }
        )

        XCTAssertEqual(warnings.count, 1)
        assertColor(first, matches: x)
        assertColor(second, matches: x)
    }

    private var defaultContext: ThemeContext {
        ThemeContext(colorScheme: .dark, ghosttyBackgroundGeneration: 0)
    }

    private func assertColor(
        _ actual: NSColor?,
        matches expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("expected color, got nil", file: file, line: line)
        }

        guard let lhs = actual.usingColorSpace(.sRGB),
              let rhs = expected.usingColorSpace(.sRGB)
        else {
            return XCTFail("failed to convert colors to sRGB", file: file, line: line)
        }

        var lr: CGFloat = 0
        var lg: CGFloat = 0
        var lb: CGFloat = 0
        var la: CGFloat = 0
        lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la)

        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        XCTAssertEqual(lr, rr, accuracy: 0.0005, file: file, line: line)
        XCTAssertEqual(lg, rg, accuracy: 0.0005, file: file, line: line)
        XCTAssertEqual(lb, rb, accuracy: 0.0005, file: file, line: line)
        XCTAssertEqual(la, ra, accuracy: 0.0005, file: file, line: line)
    }

    private func assertColorsNotEqual(
        _ lhs: NSColor?,
        _ rhs: NSColor?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let lhs = lhs?.usingColorSpace(.sRGB),
              let rhs = rhs?.usingColorSpace(.sRGB)
        else {
            return XCTFail("expected both colors", file: file, line: line)
        }

        var lr: CGFloat = 0
        var lg: CGFloat = 0
        var lb: CGFloat = 0
        var la: CGFloat = 0
        lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la)

        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        let same =
            abs(lr - rr) < 0.0005 &&
            abs(lg - rg) < 0.0005 &&
            abs(lb - rb) < 0.0005 &&
            abs(la - ra) < 0.0005
        XCTAssertFalse(same, file: file, line: line)
    }

    private func linearMix(_ lhs: NSColor, _ rhs: NSColor, amount: CGFloat) -> NSColor? {
        guard let l = lhs.usingColorSpace(.sRGB),
              let r = rhs.usingColorSpace(.sRGB)
        else {
            return nil
        }

        var lr: CGFloat = 0
        var lg: CGFloat = 0
        var lb: CGFloat = 0
        var la: CGFloat = 0
        l.getRed(&lr, green: &lg, blue: &lb, alpha: &la)

        var rr: CGFloat = 0
        var rg: CGFloat = 0
        var rb: CGFloat = 0
        var ra: CGFloat = 0
        r.getRed(&rr, green: &rg, blue: &rb, alpha: &ra)

        let mixedRed = linearToSrgb((1 - amount) * srgbToLinear(lr) + amount * srgbToLinear(rr))
        let mixedGreen = linearToSrgb((1 - amount) * srgbToLinear(lg) + amount * srgbToLinear(rg))
        let mixedBlue = linearToSrgb((1 - amount) * srgbToLinear(lb) + amount * srgbToLinear(rb))
        let mixedAlpha = (1 - amount) * la + amount * ra

        return NSColor(srgbRed: mixedRed, green: mixedGreen, blue: mixedBlue, alpha: mixedAlpha)
    }

    private func srgbToLinear(_ value: CGFloat) -> CGFloat {
        if value <= 0.04045 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    private func linearToSrgb(_ value: CGFloat) -> CGFloat {
        if value <= 0.0031308 {
            return value * 12.92
        }
        return 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}
