import AppKit
import Combine
import Foundation

// c11 (C11H-197): a window's own name and theme. Each main window can carry an
// operator-given name (shown in its title bar, `list-windows`, `tree` and
// `fleet`, and accepted as a `--window` ref) and a theme that overrides the app
// theme for that window's chrome. Both are keyed by window UUID, saved in the
// session snapshot with the window, and restored onto the window that receives
// that snapshot entry.

/// The live name and theme override of every main window, keyed by window UUID.
/// Views read it to label and paint their window; the socket and the Window menu
/// write it.
@MainActor
final class WindowAttributesStore: ObservableObject {
    static let shared = WindowAttributesStore()

    @Published private(set) var names: [UUID: String] = [:]
    @Published private(set) var themeNames: [UUID: String] = [:]

    init() {}

    func name(for windowId: UUID) -> String? { names[windowId] }

    /// The theme this window overrides the app theme with, or nil when it
    /// follows the app theme.
    func themeName(for windowId: UUID) -> String? { themeNames[windowId] }

    /// Sets or clears (nil or blank) the window's name. Callers validate first
    /// with `WindowNamePolicy`; this stores the trimmed value as given.
    func setName(_ name: String?, for windowId: UUID) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            guard names[windowId] != trimmed else { return }
            names[windowId] = trimmed
        } else {
            guard names[windowId] != nil else { return }
            names.removeValue(forKey: windowId)
        }
    }

    /// Sets or clears (nil or blank) the window's theme override.
    func setThemeName(_ themeName: String?, for windowId: UUID) {
        let trimmed = themeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            guard themeNames[windowId] != trimmed else { return }
            themeNames[windowId] = trimmed
        } else {
            guard themeNames[windowId] != nil else { return }
            themeNames.removeValue(forKey: windowId)
        }
    }

    /// Drops everything about a window that closed for good.
    func forget(windowId: UUID) {
        if names[windowId] != nil { names.removeValue(forKey: windowId) }
        if themeNames[windowId] != nil { themeNames.removeValue(forKey: windowId) }
    }

    /// The window whose name matches `name` ignoring case, if exactly one does.
    func windowId(named name: String) -> UUID? {
        let wanted = WindowNamePolicy.comparisonKey(name)
        let matches = names.filter { WindowNamePolicy.comparisonKey($0.value) == wanted }
        return matches.count == 1 ? matches.first?.key : nil
    }
}

/// The main window the operator last made active; the Window menu acts on it.
/// Kept apart from `WindowAttributesStore` so a window switch re-renders only
/// the menu, not every window that shows a name or theme.
@MainActor
final class WindowMenuState: ObservableObject {
    static let shared = WindowMenuState()
    @Published private(set) var activeWindowId: UUID?

    func noteActiveWindow(_ windowId: UUID) {
        guard activeWindowId != windowId else { return }
        activeWindowId = windowId
    }
}

/// Rules for a window name. A name doubles as a `--window` ref, so it must not
/// look like any other kind of ref and must be unique among open windows.
enum WindowNamePolicy {
    static let maxLength = 64

    enum Rejection: Equatable {
        case empty
        case tooLong
        case looksLikeRef
        case inUse(windowId: UUID)
    }

    /// The trimmed name, or why it is refused. `others` are the names of every
    /// other open window (the window being renamed is left out by the caller).
    static func validate(_ raw: String, others: [UUID: String]) -> Result<String, RejectionError> {
        let name = normalized(raw)
        if name.isEmpty { return .failure(RejectionError(.empty)) }
        if name.count > maxLength { return .failure(RejectionError(.tooLong)) }
        if looksLikeRef(name) { return .failure(RejectionError(.looksLikeRef)) }
        let key = comparisonKey(name)
        if let clash = others.first(where: { comparisonKey($0.value) == key }) {
            return .failure(RejectionError(.inUse(windowId: clash.key)))
        }
        return .success(name)
    }

    struct RejectionError: Error, Equatable {
        let rejection: Rejection
        init(_ rejection: Rejection) { self.rejection = rejection }
    }

    /// One line: control characters (newlines, tabs) become spaces, runs of
    /// spaces collapse, and the ends are trimmed.
    static func normalized(_ raw: String) -> String {
        let spaced = String(raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        return spaced.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// A bare integer (an index), a `kind:N` short ref, a UUID, or `self` would
    /// be read as that ref before any name, so those are not names.
    static func looksLikeRef(_ name: String) -> Bool {
        if Int(name) != nil { return true }
        if name.lowercased() == "self" { return true }
        if UUID(uuidString: name) != nil { return true }
        let parts = name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2,
           ["window", "workspace", "area", "panel", "pane", "surface", "tab", "display"].contains(parts[0].lowercased()),
           Int(parts[1]) != nil {
            return true
        }
        return false
    }

    static func comparisonKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
