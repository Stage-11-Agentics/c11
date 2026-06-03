import Foundation
import SwiftUI

// MARK: - ChromeScaleSettings

/// Persisted "App Chrome UI Scale" preset (C11-6). Scales c11-owned chrome —
/// sidebar workspace card text and the surface tab strip — without changing
/// Ghostty terminal cells or web/markdown content.
///
/// Mirrors the `WorkspacePresentationModeSettings` shape (key + Mode enum +
/// `mode(for:)` + `mode(defaults:)`) so the codebase looks coherent and the
/// resolver stays parameter-pure for non-SwiftUI consumers.
enum ChromeScaleSettings {
    static let presetKey = "chromeScalePreset"
    static let customMultiplierKey = "chromeScaleCustomMultiplier"

    /// Bounds for the Custom slider. Outside this range layout starts to
    /// distort (subpixel hairlines below ~0.5; tabs overflow above ~3.0), so
    /// we clamp on read regardless of what UserDefaults contains.
    static let customMultiplierRange: ClosedRange<CGFloat> = 0.50...3.00
    static let defaultCustomMultiplier: CGFloat = 1.00

    enum Preset: String, CaseIterable, Identifiable {
        case compact, standard, large, extraLarge, custom
        var id: String { rawValue }

        /// Localized display name for the Settings picker.
        var displayName: String {
            switch self {
            case .compact:
                return String(
                    localized: "settings.chromeScale.preset.compact",
                    defaultValue: "Compact"
                )
            case .standard:
                return String(
                    localized: "settings.chromeScale.preset.standard",
                    defaultValue: "Default"
                )
            case .large:
                return String(
                    localized: "settings.chromeScale.preset.large",
                    defaultValue: "Large"
                )
            case .extraLarge:
                return String(
                    localized: "settings.chromeScale.preset.extraLarge",
                    defaultValue: "Extra Large"
                )
            case .custom:
                return String(
                    localized: "settings.chromeScale.preset.custom",
                    defaultValue: "Custom"
                )
            }
        }
    }

    static let defaultPreset: Preset = .standard

    static func preset(for rawValue: String?) -> Preset {
        Preset(rawValue: rawValue ?? "") ?? defaultPreset
    }

    /// Parameter-seam overload for non-SwiftUI consumers (e.g. `Workspace.bonsplitAppearance(...)`).
    static func preset(defaults: UserDefaults) -> Preset {
        preset(for: defaults.string(forKey: presetKey))
    }

    /// Built-in multiplier for the four fixed presets. `.custom` returns
    /// `defaultCustomMultiplier` here — call `multiplier(preset:defaults:)`
    /// when you need to honor the persisted custom slider value.
    static func multiplier(for preset: Preset) -> CGFloat {
        switch preset {
        case .compact:    return 0.85
        case .standard:   return 1.00
        case .large:      return 1.25
        case .extraLarge: return 1.55
        case .custom:     return defaultCustomMultiplier
        }
    }

    /// Resolves the live multiplier including the Custom slider value when
    /// preset == `.custom`. Reads `customMultiplierKey` from `defaults` and
    /// clamps to `customMultiplierRange`.
    static func multiplier(preset: Preset, defaults: UserDefaults) -> CGFloat {
        guard preset == .custom else { return multiplier(for: preset) }
        return clampedCustomMultiplier(from: defaults)
    }

    /// Reads + clamps the persisted Custom multiplier. If the key is absent or
    /// stored as 0 (UserDefaults' default for missing Double keys), falls back
    /// to `defaultCustomMultiplier` rather than collapsing to zero.
    static func clampedCustomMultiplier(from defaults: UserDefaults) -> CGFloat {
        let raw = defaults.object(forKey: customMultiplierKey) as? Double
        return clampCustomMultiplier(raw ?? Double(defaultCustomMultiplier))
    }

    /// Clamp a raw Double into the custom-multiplier range. Treats 0 as "no
    /// value persisted yet" and substitutes the default.
    static func clampCustomMultiplier(_ raw: Double) -> CGFloat {
        let value = CGFloat(raw == 0 ? Double(defaultCustomMultiplier) : raw)
        return min(customMultiplierRange.upperBound,
                   max(customMultiplierRange.lowerBound, value))
    }

    /// SwiftUI helper. Resolves the live multiplier from raw `@AppStorage`
    /// values, so reading both bindings in `body` establishes the dependency
    /// without touching `UserDefaults` directly inside the view.
    static func multiplier(presetRaw: String, customMultiplier: Double) -> CGFloat {
        let preset = preset(for: presetRaw)
        guard preset == .custom else { return multiplier(for: preset) }
        return clampCustomMultiplier(customMultiplier)
    }

    /// Belt-and-suspenders notification for any future non-Workspace listener.
    /// Workspace observes UserDefaults via KVO (`ChromeScaleObserver`), so this
    /// notification is NOT load-bearing for the live-update path.
    static let didChangeNotification = Notification.Name("com.stage11.c11.chromeScaleDidChange")
}

// MARK: - ChromeScaleTokens

/// Single-stored-property + computed-tokens design. The synthesized `Equatable`
/// reduces to a `multiplier` compare so this type can sit inside `TabItemView`'s
/// `==` (typing-latency hot path) without growing the comparison surface. If you
/// add stored properties, audit that hot path before merging.
struct ChromeScaleTokens: Equatable {
    let multiplier: CGFloat

    // MARK: Sidebar tokens

    var sidebarWorkspaceTitle: CGFloat         { 12.5 * multiplier }
    var sidebarWorkspaceDetail: CGFloat        { 10.0 * multiplier }
    var sidebarWorkspaceMetadata: CGFloat      { 10.0 * multiplier }
    var sidebarWorkspaceAccessory: CGFloat     {  9.0 * multiplier }
    var sidebarWorkspaceProgressLabel: CGFloat {  9.0 * multiplier }
    var sidebarWorkspaceLogIcon: CGFloat       {  8.0 * multiplier }
    var sidebarWorkspaceBranchDot: CGFloat     {  3.0 * multiplier }

    // MARK: Surface tab strip tokens (Bonsplit Appearance values)

    var surfaceTabTitle: CGFloat                  { 11.0 * multiplier }
    /// Bumped from 14 → 15 base so tab icons are easier to press at every preset.
    var surfaceTabIcon: CGFloat                   { 15.0 * multiplier }
    var surfaceTabBarHeight: CGFloat              { 30.0 * multiplier }
    var surfaceTabItemHeight: CGFloat             { 30.0 * multiplier }
    var surfaceTabHorizontalPadding: CGFloat      {  6.0 * multiplier }
    var surfaceTabMinWidth: CGFloat               { 112.0 * multiplier }
    var surfaceTabMaxWidth: CGFloat               { 220.0 * multiplier }
    var surfaceTabCloseIconSize: CGFloat          {  9.0 * multiplier }
    var surfaceTabContentSpacing: CGFloat         {  6.0 * multiplier }
    var surfaceTabDirtyIndicatorSize: CGFloat     {  8.0 * multiplier }
    var surfaceTabNotificationBadgeSize: CGFloat  {  6.0 * multiplier }
    /// Floor at 2pt so the selected-tab underbar stays visible at very small
    /// Custom multipliers. At ship presets (0.85×–1.55×) the floor is inert.
    var surfaceTabActiveIndicatorHeight: CGFloat  { max(2.0, 3.0 * multiplier) }

    // MARK: Split toolbar tokens (Bonsplit Appearance)

    /// SF Symbol point size inside each trailing-edge split-toolbar button
    /// (agent A, terminal, browser globe, markdown doc, splits, plus, close).
    var splitToolbarButtonIcon: CGFloat   { 12.0 * multiplier }
    /// Square frame side length for each split-toolbar button (hover + click target).
    var splitToolbarButtonFrame: CGFloat  { 22.0 * multiplier }
    /// Vertical separator height between toolbar groups.
    var splitToolbarSeparatorHeight: CGFloat { 18.0 * multiplier }

    // MARK: Surface title bar tokens

    var surfaceTitleBarTitle: CGFloat     { 12.0 * multiplier }
    var surfaceTitleBarAccessory: CGFloat { 10.0 * multiplier }

    static let standard = ChromeScaleTokens(multiplier: 1.0)

    static func resolved(from defaults: UserDefaults = .standard) -> ChromeScaleTokens {
        let preset = ChromeScaleSettings.preset(defaults: defaults)
        return ChromeScaleTokens(
            multiplier: ChromeScaleSettings.multiplier(preset: preset, defaults: defaults)
        )
    }
}

// MARK: - Environment

extension EnvironmentValues {
    private struct ChromeScaleTokensKey: EnvironmentKey {
        static let defaultValue = ChromeScaleTokens.standard
    }

    var chromeScaleTokens: ChromeScaleTokens {
        get { self[ChromeScaleTokensKey.self] }
        set { self[ChromeScaleTokensKey.self] = newValue }
    }
}

// MARK: - ChromeScaleObserver

/// `Workspace` is `@MainActor final class … : ObservableObject` — not an
/// `NSObject` subclass — so it can't host `UserDefaults.addObserver(...)`
/// directly. `ChromeScaleObserver` is the small `NSObject` helper each
/// `Workspace` holds; lifetime is tied to the Workspace via composition.
///
/// KVO callbacks fire on the writer's thread; the observer hops to the main
/// actor before invoking the callback so the callback can mutate
/// `BonsplitController.configuration` and other main-actor state safely.
///
/// Observes both `presetKey` and `customMultiplierKey` so the live-update path
/// fires whether the user picks a preset or drags the Custom slider.
final class ChromeScaleObserver: NSObject {
    private let onChange: () -> Void
    private static let observedKeys = [
        ChromeScaleSettings.presetKey,
        ChromeScaleSettings.customMultiplierKey,
    ]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        super.init()
        for key in Self.observedKeys {
            defaults.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
    }

    deinit {
        for key in Self.observedKeys {
            defaults.removeObserver(self, forKeyPath: key)
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard let keyPath, Self.observedKeys.contains(keyPath) else { return }
        let onChange = self.onChange
        Task { @MainActor in onChange() }
    }
}
