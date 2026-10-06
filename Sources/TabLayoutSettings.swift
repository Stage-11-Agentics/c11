import Foundation
import Bonsplit

/// "Tab layout": how every area shows its tabs. `tabs` (default) is the
/// browser-style horizontal strip, with the count cell opening the tab sheet.
/// `rail` docks a vertical tab list on each area's left edge, toggled by the
/// count cell. Change it in one command:
/// `defaults write com.stage11.c11 tabLayoutMode -string rail`
/// (`com.stage11.c11.debug.<tag>` for a tagged dev build).
enum TabLayoutSettings {
    static let modeKey = "tabLayoutMode"

    enum Mode: String, CaseIterable {
        case tabs
        case rail
    }

    static let defaultMode: Mode = .tabs

    static func mode(for rawValue: String?) -> Mode {
        Mode(rawValue: rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "") ?? defaultMode
    }

    static func mode(defaults: UserDefaults = .standard) -> Mode {
        mode(for: defaults.string(forKey: modeKey))
    }

    /// Writes the same key the Settings picker and `defaults write` use.
    /// The per-workspace observer applies it. This does not touch the rail tip.
    static func setMode(_ mode: Mode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    static func bonsplitLayout(_ mode: Mode) -> BonsplitTabLayout {
        switch mode {
        case .tabs: return .tabs
        case .rail: return .rail
        }
    }

    /// The Tabs | Rail switch in each area's tab sheet and rail. It writes this
    /// same setting, so it and the Settings picker never disagree; bonsplit has
    /// already opened or closed the area's rail. `applied` runs right after the
    /// write, so the switching workspace changes layout in the same pass as its
    /// rail (the observer reaches the rest a moment later). Labels match the picker.
    static func layoutSwitch(
        defaults: UserDefaults = .standard,
        applied: @escaping () -> Void = {}
    ) -> BonsplitController.TabLayoutSwitch {
        BonsplitController.TabLayoutSwitch(
            tabsLabel: String(localized: "settings.app.tabLayout.tabs", defaultValue: "Tabs"),
            railLabel: String(localized: "settings.app.tabLayout.rail", defaultValue: "Rail"),
            accessibilityLabel: String(localized: "settings.app.tabLayout", defaultValue: "Tab Layout"),
            help: String(localized: "tabBar.layoutSwitch.help", defaultValue: "Switch Tab Layout for every area. Also in Settings > General > Tabs & Areas."),
            apply: { layout, _ in
                setMode(layout == .rail ? .rail : .tabs, defaults: defaults)
                applied()
            }
        )
    }
}

/// KVO bridge so each `Workspace` can react to the tab layout setting live.
/// Mirrors `TabOrdinalDisplayObserver`.
final class TabLayoutObserver: NSObject {
    private let onChange: () -> Void
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, onChange: @escaping () -> Void) {
        self.defaults = defaults
        self.onChange = onChange
        super.init()
        defaults.addObserver(self, forKeyPath: TabLayoutSettings.modeKey, options: [.new], context: nil)
    }

    deinit {
        defaults.removeObserver(self, forKeyPath: TabLayoutSettings.modeKey)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard keyPath == TabLayoutSettings.modeKey else { return }
        let onChange = self.onChange
        Task { @MainActor in onChange() }
    }
}
