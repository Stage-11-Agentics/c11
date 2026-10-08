import Foundation
import Bonsplit

/// "Panel layout": how every area shows its panels. `strip` (default) is the
/// browser-style horizontal strip, with the count cell opening the panel sheet.
/// `rail` docks a vertical panel list on each area's left edge, toggled by the
/// count cell. Change it in one command:
/// `defaults write com.stage11.c11 panelLayoutMode -string rail`
/// (`com.stage11.c11.debug.<tag>` for a tagged dev build).
///
/// The setting used to live under `tabLayoutMode`, with `tabs` as the strip's
/// spelling. Reads prefer `panelLayoutMode` and fall back to the old key, and
/// `tabs` still reads as `strip` from either key. Writes go to the new key
/// only; the old key is never deleted.
enum PanelLayoutSettings {
    static let modeKey = "panelLayoutMode"
    /// The pre-rename key. Read as a fallback and copied forward; never written or deleted.
    static let legacyModeKey = "tabLayoutMode"

    enum Mode: String, CaseIterable {
        case strip
        case rail
    }

    static let defaultMode: Mode = .strip

    /// `tabs` is the old spelling of `strip`.
    private static func parse(_ rawValue: String?) -> Mode? {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if value == "tabs" { return .strip }
        return Mode(rawValue: value)
    }

    static func mode(for rawValue: String?) -> Mode {
        parse(rawValue) ?? defaultMode
    }

    /// The new key if it is set, else the old key, else the default.
    static func mode(defaults: UserDefaults = .standard) -> Mode {
        if let current = defaults.string(forKey: modeKey) {
            return mode(for: current)
        }
        return mode(for: defaults.string(forKey: legacyModeKey))
    }

    /// Copies the old key's value to the new key when the new key is absent,
    /// mapping `tabs` to `strip`. Idempotent; leaves the old key in place and
    /// skips values it cannot read. Run once early at launch so the Settings
    /// picker, which reads the new key directly, shows the carried-over value.
    static func migrateLegacyKeys(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: modeKey) == nil,
              let legacy = parse(defaults.string(forKey: legacyModeKey)) else { return }
        defaults.set(legacy.rawValue, forKey: modeKey)
    }

    /// Writes the new key, the one the Settings picker and `defaults write` use.
    /// The per-workspace observer applies it. This does not touch the rail tip
    /// or the old key.
    static func setMode(_ mode: Mode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    static func bonsplitLayout(_ mode: Mode) -> BonsplitTabLayout {
        switch mode {
        case .strip: return .tabs
        case .rail: return .rail
        }
    }

    /// The Tabs | Rail switch in each area's panel sheet and rail. It writes this
    /// same setting, so it and the Settings picker never disagree; bonsplit has
    /// already opened or closed the area's rail. `applied` runs right after the
    /// write, so the switching workspace changes layout in the same pass as its
    /// rail (the observer reaches the rest a moment later). Labels match the picker.
    static func layoutSwitch(
        defaults: UserDefaults = .standard,
        applied: @escaping () -> Void = {}
    ) -> BonsplitController.TabLayoutSwitch {
        BonsplitController.TabLayoutSwitch(
            tabsLabel: String(localized: "settings.app.tabLayout.tabs", defaultValue: "Strip"),
            railLabel: String(localized: "settings.app.tabLayout.rail", defaultValue: "Rail"),
            accessibilityLabel: String(localized: "settings.app.tabLayout", defaultValue: "Panel Layout"),
            help: String(localized: "tabBar.layoutSwitch.help", defaultValue: "Switch Panel Layout for every area. Also in Settings > General > Areas & Panels."),
            apply: { layout, _ in
                setMode(layout == .rail ? .rail : .strip, defaults: defaults)
                applied()
            }
        )
    }
}

/// KVO bridge so each `Workspace` can react to the panel layout setting live.
/// Mirrors `TabOrdinalDisplayObserver`. It watches the old key too, so a write
/// to it still applies while the new key is unset.
final class PanelLayoutObserver: NSObject {
    private static let observedKeys = [PanelLayoutSettings.modeKey, PanelLayoutSettings.legacyModeKey]
    private let onChange: () -> Void
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
        // A runtime write to the old key while the new one is unset: carry it
        // forward so the Settings picker (which reads the new key) agrees with
        // the live layout.
        if keyPath == PanelLayoutSettings.legacyModeKey {
            PanelLayoutSettings.migrateLegacyKeys(defaults: defaults)
        }
        let onChange = self.onChange
        Task { @MainActor in onChange() }
    }
}
