import Foundation
import CoreFoundation

/// Durable reading preferences. A nil outline choice lets the renderer choose
/// its initial visibility from the effective width of the panel.
struct MarkdownPresentation: Codable, Equatable, Sendable {
    var fontScale: Double
    var theme: String
    var typeface: String
    var outlineOpen: Bool?

    static let fontScaleRange: ClosedRange<Double> = 0.5...3.0
    static let fontScaleStep: Double = 0.1
    static let themeNames = ["system", "light", "dark"]
    static let typefaceNames = ["theme", "serif", "sans", "mono"]
    static let `default` = MarkdownPresentation()

    enum Field: String, CaseIterable, Sendable {
        case fontScale, theme, typeface, outlineOpen

        var defaultsKey: String { "markdown.\(rawValue).lastUsed" }
    }

    init(
        fontScale: Double = 1.0,
        theme: String = "system",
        typeface: String = "theme",
        outlineOpen: Bool? = nil
    ) {
        self.fontScale = Self.normalizedFontScale(fontScale)
        self.theme = Self.normalizedTheme(theme)
        self.typeface = Self.normalizedTypeface(typeface)
        self.outlineOpen = outlineOpen
    }

    /// Persisted values outside the supported range fall back to the reading
    /// default. Interactive zoom clamps at its endpoints before reaching here.
    static func normalizedFontScale(_ value: Double) -> Double {
        guard value.isFinite, fontScaleRange.contains(value) else { return 1.0 }
        return (value * 10).rounded() / 10
    }

    static func normalizedTheme(_ value: String) -> String {
        themeNames.contains(value) ? value : "system"
    }

    static func normalizedTypeface(_ value: String) -> String {
        typefaceNames.contains(value) ? value : "theme"
    }

    private enum CodingKeys: String, CodingKey {
        case fontScale, theme, typeface, outlineOpen
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fontScale: (try? values.decode(Double.self, forKey: .fontScale)) ?? 1.0,
            theme: (try? values.decode(String.self, forKey: .theme)) ?? "system",
            typeface: (try? values.decode(String.self, forKey: .typeface)) ?? "theme",
            outlineOpen: try? values.decode(Bool.self, forKey: .outlineOpen)
        )
    }

    static func lastUsed(in defaults: UserDefaults = .standard) -> Self {
        // UserDefaults' typed getters coerce strings and numbers. Reject those
        // mismatches so a damaged setting cannot become a different valid one.
        let scaleNumber = defaults.object(forKey: Field.fontScale.defaultsKey) as? NSNumber
        let scale = scaleNumber.flatMap {
            CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue
        }
        let outlineNumber = defaults.object(forKey: Field.outlineOpen.defaultsKey) as? NSNumber
        let outline = outlineNumber.flatMap {
            CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil
        }
        return Self(
            fontScale: scale ?? 1.0,
            theme: (defaults.object(forKey: Field.theme.defaultsKey) as? String) ?? "system",
            typeface: (defaults.object(forKey: Field.typeface.defaultsKey) as? String) ?? "theme",
            outlineOpen: outline
        )
    }

    /// Save only settings the reader changed. Session restore must not save
    /// anything, and changing one setting must not publish other restored ones
    /// as the defaults for future panels.
    func saveLastUsed(
        in defaults: UserDefaults = .standard,
        fields: Set<Field> = Set(Field.allCases)
    ) {
        for field in fields {
            switch field {
            case .fontScale:
                defaults.set(Self.normalizedFontScale(fontScale), forKey: field.defaultsKey)
            case .theme:
                defaults.set(Self.normalizedTheme(theme), forKey: field.defaultsKey)
            case .typeface:
                defaults.set(Self.normalizedTypeface(typeface), forKey: field.defaultsKey)
            case .outlineOpen:
                if let outlineOpen {
                    defaults.set(outlineOpen, forKey: field.defaultsKey)
                } else {
                    defaults.removeObject(forKey: field.defaultsKey)
                }
            }
        }
    }
}
