import AppKit
import Foundation
import SwiftUI

public final class ResolvedThemeSnapshot {
    private struct ResolvedColorKey: Hashable {
        let role: ThemeRole
        let context: ThemeContext
    }

    private struct ResolvedNumberKey: Hashable {
        let role: ThemeRole
        let context: ThemeContext
    }

    private struct ResolvedBoolKey: Hashable {
        let role: ThemeRole
        let context: ThemeContext
    }

    let theme: C11Theme

    private var colorCache: [ResolvedColorKey: NSColor?] = [:]
    private var numberCache: [ResolvedNumberKey: Double?] = [:]
    private var boolCache: [ResolvedBoolKey: Bool?] = [:]
    private var astCache: [String: ThemedValueAST] = [:]
    private let lock = NSLock()

    init(theme: C11Theme) {
        self.theme = theme
    }

    func resolveColor(role: ThemeRole, context: ThemeContext) -> NSColor? {
        guard role.definition.expectedType == .color else {
            return nil
        }

        let key = ResolvedColorKey(role: role, context: context)
        lock.lock()
        if let cached = colorCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let expression = theme.stringValue(for: role) ?? role.definition.defaultColorExpression
        guard let expression else {
            lock.lock()
            colorCache[key] = nil
            lock.unlock()
            return nil
        }

        var variableStack: [String] = []
        let resolved = evaluateColorExpression(
            expression,
            warningKey: role.rawValue,
            context: context,
            variableStack: &variableStack
        )

        lock.lock()
        colorCache[key] = resolved
        lock.unlock()
        return resolved
    }

    func resolveNumber(role: ThemeRole, context: ThemeContext) -> Double? {
        guard role.definition.expectedType == .number else {
            return nil
        }

        let key = ResolvedNumberKey(role: role, context: context)
        lock.lock()
        if let cached = numberCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let rawValue = theme.numberValue(for: role) ?? role.definition.defaultNumber
        guard let rawValue else {
            lock.lock()
            numberCache[key] = nil
            lock.unlock()
            return nil
        }

        let clamped = clampNumberIfNeeded(rawValue, role: role)
        lock.lock()
        numberCache[key] = clamped
        lock.unlock()
        return clamped
    }

    func resolveBoolean(role: ThemeRole, context: ThemeContext) -> Bool? {
        guard role.definition.expectedType == .boolean else {
            return nil
        }

        let key = ResolvedBoolKey(role: role, context: context)
        lock.lock()
        if let cached = boolCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = theme.boolValue(for: role) ?? role.definition.defaultBoolean
        lock.lock()
        boolCache[key] = resolved
        lock.unlock()
        return resolved
    }

    func invalidateCaches() {
        lock.lock()
        colorCache.removeAll()
        numberCache.removeAll()
        boolCache.removeAll()
        astCache.removeAll()
        lock.unlock()
    }

    private func evaluateColorExpression(
        _ expression: String,
        warningKey: String,
        context: ThemeContext,
        variableStack: inout [String]
    ) -> NSColor? {
        let ast = astForExpression(expression, warningKey: warningKey)
        guard let ast else {
            return nil
        }

        return evaluateAst(
            ast,
            warningKey: warningKey,
            context: context,
            variableStack: &variableStack
        )
    }

    private func evaluateAst(
        _ ast: ThemedValueAST,
        warningKey: String,
        context: ThemeContext,
        variableStack: inout [String]
    ) -> NSColor? {
        ThemedValueEvaluator.evaluate(
            ast,
            context: context,
            warningKey: "\(theme.identity.name).\(warningKey)",
            colorLookup: { path, lookupContext in
                self.resolveColorPath(
                    path,
                    warningKey: warningKey,
                    context: lookupContext,
                    variableStack: &variableStack
                )
            },
            warn: { message in
                ThemeDiagnostics.resolverWarnOnce(
                    themeName: theme.identity.name,
                    key: warningKey,
                    message: message
                )
            }
        )
    }

    private func resolveColorPath(
        _ path: [String],
        warningKey: String,
        context: ThemeContext,
        variableStack: inout [String]
    ) -> NSColor? {
        guard let head = path.first else { return nil }

        switch head {
        case "palette":
            guard path.count >= 2 else { return nil }
            let paletteKey = path[1]
            guard let hex = theme.palette[paletteKey] else { return nil }
            return colorFromHexString(hex, warningKey: "palette.\(paletteKey)")

        case "workspaceColor":
            return resolveWorkspaceColor(context: context, warningKey: warningKey)

        case "ghosttyBackground":
            return resolveGhosttyBackground()

        default:
            return resolveVariable(path, warningKey: warningKey, context: context, variableStack: &variableStack)
        }
    }

    private func resolveVariable(
        _ path: [String],
        warningKey: String,
        context: ThemeContext,
        variableStack: inout [String]
    ) -> NSColor? {
        guard !path.isEmpty else { return nil }

        let joined = path.joined(separator: ".")
        let variableName: String
        if theme.variables[joined] != nil {
            variableName = joined
        } else if let first = path.first, theme.variables[first] != nil {
            variableName = first
        } else {
            return nil
        }

        if variableName == "workspaceColor" {
            return resolveWorkspaceColor(context: context, warningKey: warningKey)
        }
        if variableName == "ghosttyBackground" {
            return resolveGhosttyBackground()
        }

        guard let expression = theme.variables[variableName] else {
            return nil
        }

        if variableStack.contains(variableName) {
            ThemeDiagnostics.resolverWarnOnce(
                themeName: theme.identity.name,
                key: variableName,
                message: "cycle detected while resolving variable '\(variableName)'"
            )
            return nil
        }

        variableStack.append(variableName)
        defer { _ = variableStack.popLast() }

        return evaluateColorExpression(
            expression,
            warningKey: "variable.\(variableName)",
            context: context,
            variableStack: &variableStack
        )
    }

    private func astForExpression(_ expression: String, warningKey: String) -> ThemedValueAST? {
        lock.lock()
        if let cached = astCache[expression] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        do {
            let parsed = try ThemedValueParser.parse(expression)
            lock.lock()
            astCache[expression] = parsed
            lock.unlock()
            return parsed
        } catch {
            ThemeDiagnostics.resolverWarnOnce(
                themeName: theme.identity.name,
                key: warningKey,
                message: "failed to parse expression '\(expression)': \(error)"
            )
            return nil
        }
    }

    private func resolveWorkspaceColor(context: ThemeContext, warningKey: String) -> NSColor? {
        if let workspaceHex = context.workspaceColor {
            let workspaceColor = WorkspaceTabColorSettings.displayNSColor(
                hex: workspaceHex,
                colorScheme: context.colorScheme.swiftUIColorScheme,
                forceBright: context.forceBright
            ) ?? NSColor(hex: workspaceHex)

            guard let workspaceColor else {
                ThemeDiagnostics.resolverWarnOnce(
                    themeName: theme.identity.name,
                    key: warningKey,
                    message: "unable to resolve workspace color '\(workspaceHex)'"
                )
                return nil
            }

            return workspaceColor.usingColorSpace(.sRGB) ?? workspaceColor
        }

        // C11-35: when no workspace color is set, fall back to the theme's
        // `accent` variable. Without a fallback, formulas like
        // `$workspaceColor.mix($background, 0.65)` (chrome.dividers.color)
        // collapse to nil and chrome surfaces drop to caller-side defaults
        // (or vanish entirely) for any workspace that hasn't picked a color.
        // Callsites that explicitly want "did the user pick a color" gate
        // on `workspace.customColor` directly (see ContentView.swift's
        // `*Fallback` role switch) — this fallback only fills the gap for
        // chrome that should always render.
        guard let accentExpression = theme.variables["accent"] else {
            return nil
        }
        var fallbackStack: [String] = []
        return evaluateColorExpression(
            accentExpression,
            warningKey: "variable.accent",
            context: context,
            variableStack: &fallbackStack
        )
    }

    private func resolveGhosttyBackground() -> NSColor {
        let current = GhosttyBackgroundTheme.currentColor()
        return current.usingColorSpace(.sRGB) ?? current
    }

    private func colorFromHexString(_ value: String, warningKey: String) -> NSColor? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else {
            ThemeDiagnostics.loaderWarnOnce(
                themeName: theme.identity.name,
                key: warningKey,
                message: "invalid hex literal '\(value)'"
            )
            return nil
        }

        let body = String(trimmed.dropFirst())
        guard body.count == 6 || body.count == 8,
              let raw = UInt64(body, radix: 16)
        else {
            ThemeDiagnostics.loaderWarnOnce(
                themeName: theme.identity.name,
                key: warningKey,
                message: "invalid hex literal '\(value)'"
            )
            return nil
        }

        if body.count == 6 {
            let red = CGFloat((raw >> 16) & 0xFF) / 255.0
            let green = CGFloat((raw >> 8) & 0xFF) / 255.0
            let blue = CGFloat(raw & 0xFF) / 255.0
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1.0)
        }

        let red = CGFloat((raw >> 24) & 0xFF) / 255.0
        let green = CGFloat((raw >> 16) & 0xFF) / 255.0
        let blue = CGFloat((raw >> 8) & 0xFF) / 255.0
        let alpha = CGFloat(raw & 0xFF) / 255.0
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private func clampNumberIfNeeded(_ rawValue: Double, role: ThemeRole) -> Double {
        switch role {
        case .windowFrame_inactiveOpacity,
             .windowFrame_unfocusedOpacity,
             .sidebar_tintBaseOpacity,
             .sidebar_activeTabRailOpacity,
             .sidebar_inactiveTabCustomOpacity,
             .sidebar_inactiveTabMultiSelectOpacity,
             .titleBar_backgroundOpacity:
            return clamp(value: rawValue, min: 0.0, max: 1.0, warningKey: role.rawValue)

        case .windowFrame_thicknessPt,
             .dividers_thicknessPt:
            return clamp(value: rawValue, min: 0.0, max: 8.0, warningKey: role.rawValue)

        default:
            return rawValue
        }
    }

    private func clamp(value: Double, min lower: Double, max upper: Double, warningKey: String) -> Double {
        let clamped = Swift.min(upper, Swift.max(lower, value))
        if abs(clamped - value) > 0.000_000_1 {
            ThemeDiagnostics.resolverWarnOnce(
                themeName: theme.identity.name,
                key: warningKey,
                message: "clamped '\(warningKey)' from \(value) to \(clamped)"
            )
        }
        return clamped
    }
}

private extension ThemeContext.ColorScheme {
    var swiftUIColorScheme: ColorScheme {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
