import Combine
import Foundation
import SwiftUI

@MainActor
final class AIUsageColorSettings: ObservableObject {
    static let shared = AIUsageColorSettings()

    static let defaultLowColorHex = "#46B46E"
    static let defaultMidColorHex = "#D2AA3C"
    static let defaultHighColorHex = "#DC5050"
    static let defaultLowMidThreshold = 85
    static let defaultMidHighThreshold = 95
    static let defaultInterpolate = true

    static let lowColorKey = "c11.aiusage.color.low"
    static let midColorKey = "c11.aiusage.color.mid"
    static let highColorKey = "c11.aiusage.color.high"
    static let lowMidThresholdKey = "c11.aiusage.color.lowMidThreshold"
    static let midHighThresholdKey = "c11.aiusage.color.midHighThreshold"
    static let interpolateKey = "c11.aiusage.color.interpolate"

    @Published var lowColorHex: String {
        didSet { defaults.set(lowColorHex, forKey: Self.lowColorKey) }
    }
    @Published var midColorHex: String {
        didSet { defaults.set(midColorHex, forKey: Self.midColorKey) }
    }
    @Published var highColorHex: String {
        didSet { defaults.set(highColorHex, forKey: Self.highColorKey) }
    }
    @Published private(set) var lowMidThreshold: Int
    @Published private(set) var midHighThreshold: Int
    @Published var interpolate: Bool {
        didSet { defaults.set(interpolate, forKey: Self.interpolateKey) }
    }

    private let defaults: UserDefaults

    private convenience init() {
        self.init(userDefaults: .standard)
    }

    init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
        self.lowColorHex = userDefaults.string(forKey: Self.lowColorKey) ?? Self.defaultLowColorHex
        self.midColorHex = userDefaults.string(forKey: Self.midColorKey) ?? Self.defaultMidColorHex
        self.highColorHex = userDefaults.string(forKey: Self.highColorKey) ?? Self.defaultHighColorHex

        let storedLow = userDefaults.object(forKey: Self.lowMidThresholdKey) as? Int
            ?? Self.defaultLowMidThreshold
        let storedHigh = userDefaults.object(forKey: Self.midHighThresholdKey) as? Int
            ?? Self.defaultMidHighThreshold
        let (low, high) = Self.normalizeThresholds(low: storedLow, high: storedHigh)
        self.lowMidThreshold = low
        self.midHighThreshold = high

        if let stored = userDefaults.object(forKey: Self.interpolateKey) as? Bool {
            self.interpolate = stored
        } else {
            self.interpolate = Self.defaultInterpolate
        }
    }

    func setThresholds(low: Int, high: Int) {
        let (clampedLow, clampedHigh) = Self.normalizeThresholds(low: low, high: high)
        lowMidThreshold = clampedLow
        midHighThreshold = clampedHigh
        defaults.set(clampedLow, forKey: Self.lowMidThresholdKey)
        defaults.set(clampedHigh, forKey: Self.midHighThresholdKey)
    }

    func resetToDefaults() {
        lowColorHex = Self.defaultLowColorHex
        midColorHex = Self.defaultMidColorHex
        highColorHex = Self.defaultHighColorHex
        setThresholds(low: Self.defaultLowMidThreshold, high: Self.defaultMidHighThreshold)
        interpolate = Self.defaultInterpolate
    }

    func color(for percent: Int) -> Color {
        let clamped = max(0, min(100, percent))
        let low = Color(usageHex: lowColorHex) ?? .green
        let mid = Color(usageHex: midColorHex) ?? .yellow
        let high = Color(usageHex: highColorHex) ?? .red

        if !interpolate {
            if clamped < lowMidThreshold { return low }
            if clamped < midHighThreshold { return mid }
            return high
        }

        if clamped <= 0 { return low }
        if clamped >= 100 { return high }
        if clamped <= lowMidThreshold {
            let span = max(1, lowMidThreshold)
            let t = Double(clamped) / Double(span)
            return Color.usageInterpolate(low, mid, t: t)
        }
        if clamped <= midHighThreshold {
            let span = max(1, midHighThreshold - lowMidThreshold)
            let t = Double(clamped - lowMidThreshold) / Double(span)
            return Color.usageInterpolate(mid, high, t: t)
        }
        let span = max(1, 100 - midHighThreshold)
        let t = Double(clamped - midHighThreshold) / Double(span)
        return Color.usageInterpolate(high, high, t: t)
    }

    private static func normalizeThresholds(low: Int, high: Int) -> (Int, Int) {
        var clampedLow = max(1, min(98, low))
        var clampedHigh = max(2, min(99, high))
        if clampedLow >= clampedHigh {
            clampedLow = max(1, clampedHigh - 1)
        }
        if clampedHigh <= clampedLow {
            clampedHigh = min(99, clampedLow + 1)
        }
        return (clampedLow, clampedHigh)
    }
}

extension Color {
    init?(usageHex: String) {
        var trimmed = usageHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            trimmed.removeFirst()
        }
        guard trimmed.count == 6 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&value) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    var usageHexString: String {
        let (r, g, b) = rgbComponents
        let ri = Int((r * 255.0).rounded())
        let gi = Int((g * 255.0).rounded())
        let bi = Int((b * 255.0).rounded())
        return String(format: "#%02X%02X%02X", ri, gi, bi)
    }

    var rgbComponents: (red: Double, green: Double, blue: Double) {
        #if canImport(AppKit)
        let nsColor = NSColor(self).usingColorSpace(.sRGB)
            ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return (Double(nsColor.redComponent),
                Double(nsColor.greenComponent),
                Double(nsColor.blueComponent))
        #else
        return (0, 0, 0)
        #endif
    }

    static func usageInterpolate(_ a: Color, _ b: Color, t: Double) -> Color {
        let clamped = max(0.0, min(1.0, t))
        let lhs = a.rgbComponents
        let rhs = b.rgbComponents
        return Color(
            .sRGB,
            red: lhs.red + (rhs.red - lhs.red) * clamped,
            green: lhs.green + (rhs.green - lhs.green) * clamped,
            blue: lhs.blue + (rhs.blue - lhs.blue) * clamped,
            opacity: 1
        )
    }
}
