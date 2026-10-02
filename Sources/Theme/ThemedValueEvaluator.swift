import AppKit
import Foundation

public enum ThemeWarnings {
    private static var emittedKeys: Set<String> = []
    private static let lock = NSLock()

    public static func emitOnce(key: String, message: String, sink: (String) -> Void) {
        lock.lock()
        let isNew = emittedKeys.insert(key).inserted
        lock.unlock()

        guard isNew else { return }
        sink(message)
    }

    public static func resetForTesting() {
        lock.lock()
        emittedKeys.removeAll()
        lock.unlock()
    }
}

public struct ThemedValueEvaluator {
    public typealias ColorLookup = (_ path: [String], _ context: ThemeContext) -> NSColor?

    public static func evaluate(
        _ ast: ThemedValueAST,
        context: ThemeContext,
        warningKey: String,
        colorLookup: ColorLookup,
        warn: (String) -> Void = { _ in }
    ) -> NSColor? {
        evaluateColor(
            ast,
            context: context,
            warningKey: warningKey,
            colorLookup: colorLookup,
            warn: warn
        )
    }

    private static func evaluateColor(
        _ ast: ThemedValueAST,
        context: ThemeContext,
        warningKey: String,
        colorLookup: ColorLookup,
        warn: (String) -> Void
    ) -> NSColor? {
        switch ast {
        case let .hex(value):
            return colorFromHex(value)

        case let .rgba(value):
            return colorFromHex(value, includesAlpha: true)

        case let .variableRef(path):
            guard let resolved = colorLookup(path, context) else { return nil }
            return resolved.usingColorSpace(.sRGB) ?? resolved

        case let .structured(value):
            switch value {
            case let .hexLiteral(hex):
                return colorFromHex(hex)
            default:
                return nil
            }

        case let .modifier(op, args):
            return applyModifier(
                op,
                args: args,
                context: context,
                warningKey: warningKey,
                colorLookup: colorLookup,
                warn: warn
            )
        }
    }

    private static func applyModifier(
        _ op: ThemedValueAST.ModifierOp,
        args: [ThemedValueAST],
        context: ThemeContext,
        warningKey: String,
        colorLookup: ColorLookup,
        warn: (String) -> Void
    ) -> NSColor? {
        guard let baseAst = args.first,
              let baseColor = evaluateColor(
                baseAst,
                context: context,
                warningKey: warningKey,
                colorLookup: colorLookup,
                warn: warn
              )
        else {
            return nil
        }

        switch op {
        case .opacity:
            guard let rawValue = numericValue(from: args[safe: 1]) else {
                return nil
            }
            let alpha = clamp01(rawValue, warningKey: "\(warningKey).opacity", warn: warn)
            return baseColor.withAlphaComponent(baseColor.alphaComponent * alpha)

        case .mix:
            guard let targetAst = args[safe: 1],
                  let targetColor = evaluateColor(
                    targetAst,
                    context: context,
                    warningKey: warningKey,
                    colorLookup: colorLookup,
                    warn: warn
                  ),
                  let rawAmount = numericValue(from: args[safe: 2])
            else {
                return nil
            }

            let amount = clamp01(rawAmount, warningKey: "\(warningKey).mix", warn: warn)
            return mix(baseColor, targetColor, fraction: amount)

        case .darken:
            guard let rawValue = numericValue(from: args[safe: 1]) else {
                return nil
            }
            let amount = clamp01(rawValue, warningKey: "\(warningKey).darken", warn: warn)
            return adjustHSB(baseColor) { hue, saturation, brightness, alpha in
                NSColor(
                    hue: hue,
                    saturation: saturation,
                    brightness: max(0, brightness * (1 - amount)),
                    alpha: alpha
                )
            }

        case .lighten:
            guard let rawValue = numericValue(from: args[safe: 1]) else {
                return nil
            }
            let amount = clamp01(rawValue, warningKey: "\(warningKey).lighten", warn: warn)
            return adjustHSB(baseColor) { hue, saturation, brightness, alpha in
                NSColor(
                    hue: hue,
                    saturation: saturation,
                    brightness: brightness + ((1 - brightness) * amount),
                    alpha: alpha
                )
            }

        case .saturate:
            guard let rawValue = numericValue(from: args[safe: 1]) else {
                return nil
            }
            let amount = clamp01(rawValue, warningKey: "\(warningKey).saturate", warn: warn)
            return adjustHSB(baseColor) { hue, saturation, brightness, alpha in
                NSColor(
                    hue: hue,
                    saturation: saturation + ((1 - saturation) * amount),
                    brightness: brightness,
                    alpha: alpha
                )
            }

        case .desaturate:
            guard let rawValue = numericValue(from: args[safe: 1]) else {
                return nil
            }
            let amount = clamp01(rawValue, warningKey: "\(warningKey).desaturate", warn: warn)
            return adjustHSB(baseColor) { hue, saturation, brightness, alpha in
                NSColor(
                    hue: hue,
                    saturation: max(0, saturation * (1 - amount)),
                    brightness: brightness,
                    alpha: alpha
                )
            }
        }
    }

    private static func numericValue(from ast: ThemedValueAST?) -> Double? {
        guard let ast else { return nil }

        switch ast {
        case let .structured(value):
            switch value {
            case let .number(number):
                return number
            case let .opacityValue(number):
                return number
            default:
                return nil
            }

        case let .hex(value), let .rgba(value):
            return Double(value)

        case .variableRef, .modifier:
            return nil
        }
    }

    private static func clamp01(_ value: Double, warningKey: String, warn: (String) -> Void) -> Double {
        let clamped = min(1.0, max(0.0, value))
        if abs(clamped - value) > 0.000_000_1 {
            ThemeWarnings.emitOnce(
                key: warningKey,
                message: "Theme value clamped to [0, 1] for \(warningKey)",
                sink: warn
            )
        }
        return clamped
    }

    private static func colorFromHex(_ value: UInt32, includesAlpha: Bool = false) -> NSColor {
        if !includesAlpha && value <= 0x00FF_FFFF {
            let red = CGFloat((value >> 16) & 0xFF) / 255.0
            let green = CGFloat((value >> 8) & 0xFF) / 255.0
            let blue = CGFloat(value & 0xFF) / 255.0
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1.0)
        }

        let red = CGFloat((value >> 24) & 0xFF) / 255.0
        let green = CGFloat((value >> 16) & 0xFF) / 255.0
        let blue = CGFloat((value >> 8) & 0xFF) / 255.0
        let alpha = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func adjustHSB(
        _ color: NSColor,
        transform: (_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat, _ alpha: CGFloat) -> NSColor
    ) -> NSColor? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return transform(hue, saturation, brightness, alpha)
    }

    private static func mix(_ lhs: NSColor, _ rhs: NSColor, fraction: Double) -> NSColor? {
        guard let left = lhs.usingColorSpace(.sRGB),
              let right = rhs.usingColorSpace(.sRGB)
        else {
            return nil
        }

        var lRed: CGFloat = 0
        var lGreen: CGFloat = 0
        var lBlue: CGFloat = 0
        var lAlpha: CGFloat = 0
        left.getRed(&lRed, green: &lGreen, blue: &lBlue, alpha: &lAlpha)

        var rRed: CGFloat = 0
        var rGreen: CGFloat = 0
        var rBlue: CGFloat = 0
        var rAlpha: CGFloat = 0
        right.getRed(&rRed, green: &rGreen, blue: &rBlue, alpha: &rAlpha)

        let t = CGFloat(fraction)

        let mixedRed = linearToSrgb((1 - t) * srgbToLinear(lRed) + t * srgbToLinear(rRed))
        let mixedGreen = linearToSrgb((1 - t) * srgbToLinear(lGreen) + t * srgbToLinear(rGreen))
        let mixedBlue = linearToSrgb((1 - t) * srgbToLinear(lBlue) + t * srgbToLinear(rBlue))
        let mixedAlpha = ((1 - t) * lAlpha) + (t * rAlpha)

        return NSColor(
            srgbRed: mixedRed,
            green: mixedGreen,
            blue: mixedBlue,
            alpha: mixedAlpha
        )
    }

    private static func srgbToLinear(_ value: CGFloat) -> CGFloat {
        if value <= 0.04045 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ value: CGFloat) -> CGFloat {
        if value <= 0.0031308 {
            return value * 12.92
        }
        return (1.055 * pow(value, 1 / 2.4)) - 0.055
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
