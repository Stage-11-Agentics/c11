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

    static func bonsplitLayout(_ mode: Mode) -> BonsplitTabLayout {
        switch mode {
        case .tabs: return .tabs
        case .rail: return .rail
        }
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
