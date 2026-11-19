import AppKit
import Combine
import Foundation

/// C11H-126: one roster entry. `id` is hc's machine name, lower-cased
/// (as `hc machine ls` names it), or `local` for this Mac. Both fields are optional: an unset name
/// keeps the name the chip shows today, an unset color keeps today's plain chip.
struct MachineRosterEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    var name: String?
    var color: String?

    static let maxNameLength = 48

    var isValid: Bool {
        guard MachineRoster.isValidID(id) else { return false }
        if let name, !Self.isValidName(name) { return false }
        if let color, MachineRosterColor.normalized(color) != color { return false }
        return true
    }

    /// Nothing set: the entry carries no information and is not stored.
    var isEmpty: Bool { name == nil && color == nil }

    static func isValidName(_ value: String) -> Bool {
        let forbidden = CharacterSet.newlines.union(.controlCharacters)
        return !value.isEmpty
            && value.count <= maxNameLength
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { forbidden.contains($0) })
    }

    var jsonObject: [String: Any] {
        [
            "id": id,
            "name": name as Any? ?? NSNull(),
            "color": color as Any? ?? NSNull(),
        ]
    }
}

enum MachineRosterError: Error, Equatable {
    case invalidID
    case invalidName
    case invalidColor
    case tooManyMachines
    case encodingFailed

    var message: String {
        switch self {
        case .invalidID:
            return "id must be 'local' (this Mac) or an hc machine name: letters, digits, '.', '_' or '-', at most 64 characters"
        case .invalidName:
            return "name must be 1 to \(MachineRosterEntry.maxNameLength) characters on one line"
        case .invalidColor:
            return "color must be a hex value, #RRGGBB or #RRGGBBAA"
        case .tooManyMachines:
            return "at most \(MachineRoster.maxEntries) machines may be in the roster"
        case .encodingFailed:
            return "failed to save the machine roster"
        }
    }
}

/// One field of a `set`: leave it as it is, give it a value, or clear it.
enum MachineRosterFieldChange: Equatable, Sendable {
    case keep
    case set(String)
    case clear
}

/// Hex colors for the roster. Any value is accepted; it is stored normalized
/// (`#RRGGBB` or `#RRGGBBAA`, upper case) so equal colors compare equal.
enum MachineRosterColor {
    static func normalized(_ raw: String) -> String? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8,
              hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) })
        else { return nil }
        return "#" + hex.uppercased()
    }

    /// sRGB components 0...1 with alpha, or nil for an invalid value.
    static func components(_ raw: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let hex = normalized(raw) else { return nil }
        let digits = Array(hex.dropFirst())
        func byte(_ index: Int) -> Double {
            Double(UInt8(String(digits[index..<(index + 2)]), radix: 16) ?? 0) / 255
        }
        let alpha = digits.count == 8 ? byte(6) : 1
        return (byte(0), byte(2), byte(4), alpha)
    }

    static func nsColor(_ raw: String) -> NSColor? {
        guard let c = components(raw) else { return nil }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    /// The hex string for a picked color, alpha kept only when it is not opaque.
    static func hex(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> String {
            String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded()))
        }
        let base = "#" + byte(rgb.redComponent) + byte(rgb.greenComponent) + byte(rgb.blueComponent)
        let alpha = Int((min(max(rgb.alphaComponent, 0), 1) * 255).rounded())
        return alpha >= 255 ? base : base + String(format: "%02X", alpha)
    }

    /// WCAG relative luminance of an opaque sRGB color.
    static func luminance(r: Double, g: Double, b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The text color for a chip filled with `fill`, drawn over `background`
    /// (the bar's color in the current appearance, opaque). The fill is
    /// composited over the background first, so a translucent tint picks its
    /// text per light and dark mode. True means white text, false black.
    static func prefersWhiteText(fill: String, background: (r: Double, g: Double, b: Double)) -> Bool {
        guard let c = components(fill) else { return false }
        let r = c.r * c.a + background.r * (1 - c.a)
        let g = c.g * c.a + background.g * (1 - c.a)
        let b = c.b * c.a + background.b * (1 - c.a)
        let lum = luminance(r: r, g: g, b: b)
        return contrastRatio(lum, 1) >= contrastRatio(lum, 0)
    }
}

/// C11H-126: c11's machine roster. A display name and a color per machine,
/// shown on each terminal's where-it-runs chip. It lives in c11's own
/// defaults (Settings, `c11 machine`), not in any external directory, because
/// not every operator has one. Editing it repaints open chips live.
final class MachineRoster: ObservableObject, @unchecked Sendable {
    static let shared = MachineRoster()
    static let storageKey = "machines.roster.v1"
    static let didChangeNotification = Notification.Name("c11.machineRosterDidChange")
    /// The roster key for this Mac. `--on local` already means this Mac, so hc
    /// cannot usefully name a machine `local`.
    static let localID = "local"
    static let maxEntries = 64
    static let maxIDLength = 64

    /// Bumped on main after every change so SwiftUI chips redraw.
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cache: [String: MachineRosterEntry]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func isValidID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= maxIDLength, value == value.lowercased() else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The roster id for a raw machine name: trimmed and lower-cased; `here`
    /// reads as `local`. Nil when it is not a valid id.
    static func normalizedID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapped = HCMachineTarget.localWords.contains(id) ? localID : id
        return isValidID(mapped) ? mapped : nil
    }

    func all() -> [MachineRosterEntry] {
        lock.lock()
        defer { lock.unlock() }
        return read().values.sorted { $0.id < $1.id }
    }

    func entry(id: String) -> MachineRosterEntry? {
        guard let key = Self.normalizedID(id) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return read()[key]
    }

    /// Change one machine's fields. A change that leaves both fields unset
    /// removes the entry. Returns the stored entry, or nil when none remains.
    @discardableResult
    func set(id rawID: String, name: MachineRosterFieldChange, color: MachineRosterFieldChange) throws -> MachineRosterEntry? {
        guard let id = Self.normalizedID(rawID) else { throw MachineRosterError.invalidID }
        var nameValue: String??
        switch name {
        case .keep: nameValue = nil
        case .clear: nameValue = .some(nil)
        case .set(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                nameValue = .some(nil)
            } else {
                guard MachineRosterEntry.isValidName(trimmed) else { throw MachineRosterError.invalidName }
                nameValue = .some(trimmed)
            }
        }
        var colorValue: String??
        switch color {
        case .keep: colorValue = nil
        case .clear: colorValue = .some(nil)
        case .set(let raw):
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                colorValue = .some(nil)
            } else {
                guard let hex = MachineRosterColor.normalized(raw) else { throw MachineRosterError.invalidColor }
                colorValue = .some(hex)
            }
        }

        lock.lock()
        var changed = false
        defer {
            lock.unlock()
            if changed { announce() }
        }
        var entries = read()
        var entry = entries[id] ?? MachineRosterEntry(id: id, name: nil, color: nil)
        if let nameValue { entry.name = nameValue }
        if let colorValue { entry.color = colorValue }
        let previous = entries[id]
        if entry.isEmpty {
            entries.removeValue(forKey: id)
        } else {
            entries[id] = entry
        }
        guard entries.count <= Self.maxEntries else { throw MachineRosterError.tooManyMachines }
        if previous != (entry.isEmpty ? nil : entry) {
            try write(entries)
            changed = true
        }
        return entry.isEmpty ? nil : entry
    }

    /// Remove a machine's entry. False when it had none.
    @discardableResult
    func remove(id rawID: String) throws -> Bool {
        guard let id = Self.normalizedID(rawID) else { throw MachineRosterError.invalidID }
        lock.lock()
        var changed = false
        defer {
            lock.unlock()
            if changed { announce() }
        }
        var entries = read()
        guard entries.removeValue(forKey: id) != nil else { return false }
        try write(entries)
        changed = true
        return true
    }

    /// The configured names, for the chip's width.
    func configuredNames() -> [String] {
        all().compactMap(\.name)
    }

    private func announce() {
        widthCache.reset()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        if Thread.isMainThread {
            revision &+= 1
        } else {
            DispatchQueue.main.async { [weak self] in self?.revision &+= 1 }
        }
    }

    // Caller holds `lock`.
    private func read() -> [String: MachineRosterEntry] {
        if let cache { return cache }
        var result: [String: MachineRosterEntry] = [:]
        if let data = defaults.data(forKey: Self.storageKey), data.count <= 32_768,
           let decoded = try? JSONDecoder().decode([MachineRosterEntry].self, from: data) {
            for entry in decoded where entry.isValid && !entry.isEmpty {
                result[entry.id] = entry
            }
        }
        cache = result
        return result
    }

    // Caller holds `lock`. The cache is the source of truth for reads; the
    // defaults write goes to main (C11H-300). UserDefaults posts
    // `didChangeNotification` inside `set`, and a `queue: .main` observer holds
    // the writing thread until main runs it, so a write made here, under the
    // lock, deadlocked any main-thread roster read (a chip redraw) against
    // `c11 machine set|rm`. Enqueued while the lock is held, writes land on
    // main in lock order and the last change wins.
    private func write(_ entries: [String: MachineRosterEntry]) throws {
        let ordered = entries.values.sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(ordered), data.count <= 32_768 else {
            throw MachineRosterError.encodingFailed
        }
        cache = entries
        let defaults = defaults
        DispatchQueue.main.async { defaults.set(data, forKey: Self.storageKey) }
    }

    /// Widest configured name per font size, cleared on every change, so a
    /// title bar redraw does not measure the roster again.
    let widthCache = MachineRosterWidthCache()
}

final class MachineRosterWidthCache: @unchecked Sendable {
    private let lock = NSLock()
    private var widths: [CGFloat: CGFloat] = [:]
    /// Bumped by every reset. A measurement that started before a reset is
    /// returned but not stored, so a roster change racing a redraw cannot
    /// pin the old width.
    private var generation: UInt64 = 0

    func width(fontSize: CGFloat, compute: () -> CGFloat) -> CGFloat {
        lock.lock()
        if let cached = widths[fontSize] {
            lock.unlock()
            return cached
        }
        let started = generation
        lock.unlock()
        let value = compute()
        lock.lock()
        if generation == started { widths[fontSize] = value }
        lock.unlock()
        return value
    }

    func reset() {
        lock.lock()
        widths.removeAll()
        generation &+= 1
        lock.unlock()
    }
}

/// C11H-126: one row of the roster as Settings and `c11 machine list` show
/// it: this Mac first, then every machine hc has linked or the roster names.
struct MachineRosterRow: Equatable, Identifiable {
    let id: String
    let entry: MachineRosterEntry?
    let isLocal: Bool
    /// hc reports this machine (`hc machine ls`). This Mac is always linked.
    let linked: Bool
    /// hc's line to it is up. Nil for this Mac and for unlinked machines.
    let connected: Bool?
    /// The name the chip shows when the roster sets none.
    let defaultName: String

    var displayName: String { entry?.name ?? defaultName }

    var jsonObject: [String: Any] {
        [
            "id": id,
            "name": entry?.name as Any? ?? NSNull(),
            "color": entry?.color as Any? ?? NSNull(),
            "display_name": displayName,
            "default_name": defaultName,
            "local": isLocal,
            "linked": linked,
            "connected": connected as Any? ?? NSNull(),
            "configured": entry != nil,
        ]
    }

    static func rows(
        roster: [MachineRosterEntry],
        linked: [String: Bool]?,
        localHostName: String
    ) -> [MachineRosterRow] {
        let entries = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, $0) })
        var linkedByID: [String: Bool] = [:]
        for (name, connected) in linked ?? [:] {
            guard let id = MachineRoster.normalizedID(name), id != MachineRoster.localID else { continue }
            linkedByID[id] = connected
        }
        let local = MachineRosterRow(
            id: MachineRoster.localID,
            entry: entries[MachineRoster.localID],
            isLocal: true,
            linked: true,
            connected: nil,
            defaultName: localHostName
        )
        let others = Set(linkedByID.keys).union(entries.keys).subtracting([MachineRoster.localID]).sorted()
        return [local] + others.map { id in
            MachineRosterRow(
                id: id,
                entry: entries[id],
                isLocal: false,
                linked: linkedByID[id] != nil,
                connected: linkedByID[id],
                defaultName: HCMachineTarget.displayName(id)
            )
        }
    }
}
