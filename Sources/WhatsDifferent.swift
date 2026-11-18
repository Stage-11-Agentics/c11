import AppKit
import Foundation

/// C11H-127: the "What's different in c11" sheet. It teaches a new user that
/// their terminals run in places other than the window: they outlive the app,
/// closing a panel ends one, and some run on another machine.
///
/// This file is the sheet's logic: when it shows, and the places its picture
/// draws. The view is `WhatsDifferentView.swift`; AppDelegate presents it.
enum WhatsDifferent {
    /// Bump when the sheet's content changes, so it shows once more after the
    /// update that carries the change. Never lower it.
    static let contentVersion = 1

    /// The highest content version this profile has shown, in c11's own
    /// defaults domain.
    static let shownVersionKey = "c11.whatsDifferent.shownVersion"

    /// Shows on its own once per content version, never under a QA launch.
    /// The Help menu reopens it regardless. The c11 2.0 upgrade note is
    /// decided by `autoPresentation`.
    static func shouldAutoPresent(qa: QALaunchPolicy, shownVersion: Int,
                                  current: Int = contentVersion) -> Bool {
        !qa.isActive && shownVersion < current
    }

    static func shownVersion(defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: shownVersionKey)
    }

    /// Recorded when the sheet appears, so a quit with it open does not bring
    /// it back on every launch.
    static func markShown(defaults: UserDefaults = .standard, version: Int = contentVersion) {
        if defaults.integer(forKey: shownVersionKey) < version {
            defaults.set(version, forKey: shownVersionKey)
        }
    }

    // MARK: c11 2.0 upgrade note (C11H-267)

    /// Set once when the upgrade variant appears, so it shows once per profile.
    static let upgradeNoteShownKey = "c11.upgradeNote.shown"

    /// What this launch shows on its own. The upgrade note goes only to a
    /// profile that came from c11 1.x; everyone else keeps the sheet's
    /// ordinary once-per-content-version rule (a fresh install sees it beside
    /// the welcome workspace; a c11 profile has already seen it).
    enum Presentation: Equatable {
        case nothing
        case standard
        case upgradeFrom1x
    }

    static func autoPresentation(qa: QALaunchPolicy, origin: C11UpgradeOrigin, upgradeNoteShown: Bool,
                                 shownVersion: Int, current: Int = contentVersion) -> Presentation {
        guard !qa.isActive else { return .nothing }
        // An upgrader sees the upgrade note once. Showing it records the
        // standard sheet's version too, so afterwards only a later content
        // change brings the sheet back, as for everyone.
        if origin == .c11v1, !upgradeNoteShown { return .upgradeFrom1x }
        return shownVersion < current ? .standard : .nothing
    }

    /// The variant this profile reads, for Help ▸ and for the first launch.
    static func audience(origin: C11UpgradeOrigin) -> WhatsDifferentAudience {
        origin == .c11v1 ? .upgradeFrom1x : .standard
    }

    static func upgradeNoteShown(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: upgradeNoteShownKey)
    }

    /// Records whichever variant appeared. The upgrade note also counts as
    /// the standard sheet's current version: it carries the same teaching.
    static func markShown(_ audience: WhatsDifferentAudience, defaults: UserDefaults = .standard) {
        markShown(defaults: defaults)
        if audience == .upgradeFrom1x { defaults.set(true, forKey: upgradeNoteShownKey) }
    }
}

/// Which copy the What's Different window carries.
enum WhatsDifferentAudience: Equatable {
    /// How c11 terminals work, for anyone.
    case standard
    /// The first 2.0 launch after c11 1.x: what changed, and how to stop it.
    case upgradeFrom1x
}

/// Where this profile came from, as the c11 2.0 first-launch migration
/// (C11H-266) recorded it. That migration is the one source of truth and
/// writes the key once, before any window; this only reads it. A missing or
/// unknown value is `fresh`, so a build that never migrated shows no
/// upgrade note.
enum C11UpgradeOrigin: String, Equatable {
    case fresh
    case c11v1 = "c11-1x"
    case c11
    /// c11 1.x and c11 both present: 2.0 takes c11's world.
    case both

    static let defaultsKey = "c11.migration.origin"

    static func current(defaults: UserDefaults = .standard) -> C11UpgradeOrigin {
        defaults.string(forKey: defaultsKey).flatMap(C11UpgradeOrigin.init(rawValue:)) ?? .fresh
    }
}

/// How one machine reads in the picture: its name and, when one is set, its color.
struct WhatsDifferentMachineLook: Equatable {
    let name: String
    /// `#RRGGBB` or `#RRGGBBAA`; nil uses the picture's own color for that row.
    let colorHex: String?
}

/// One place terminals run, as the picture draws it.
struct WhatsDifferentPlace: Equatable, Identifiable {
    enum Link: Equatable {
        /// This Mac: terminals here are held outside the window, by hc.
        case local
        case connected
        case reconnecting
    }

    /// `local` for this Mac, else hc's machine name.
    let id: String
    let name: String
    let colorHex: String?
    let link: Link
    /// Terminal panels open on this machine, across every c11 window.
    let terminals: Int

    var isLocal: Bool { link == .local }
}

enum WhatsDifferentPlaces {
    /// The key this Mac uses in a machine roster.
    static let localID = "local"
    /// At most this many machines are drawn; the rest are summed into one
    /// "more" row, so the picture never grows past five rows.
    static let maximumDrawnMachines = 4

    /// Names and colors for the picture, from the machine roster (C11H-126),
    /// the same as each terminal's chip: the roster's name and color when set,
    /// else this Mac's Computer Name or hc's name with its first letter raised.
    nonisolated(unsafe) static var look: (_ id: String) -> WhatsDifferentMachineLook = defaultLook

    static func defaultLook(_ id: String) -> WhatsDifferentMachineLook {
        let entry = MachineRoster.shared.entry(id: id)
        let fallback = id == localID ? LocalSessionPlacementFeed.localHostName : HCMachineTarget.displayName(id)
        return WhatsDifferentMachineLook(name: entry?.name ?? fallback, colorHex: entry?.color)
    }

    /// This Mac first, then every machine hc has added, by name. A machine
    /// with terminals open but no longer listed by hc still appears, marked
    /// reconnecting, so every open terminal is counted somewhere.
    /// - machines: hc's machines and whether each line is up.
    /// - terminalMachines: one entry per open terminal panel; nil is this Mac.
    static func build(machines: [String: Bool],
                      terminalMachines: [String?],
                      look: (String) -> WhatsDifferentMachineLook = WhatsDifferentPlaces.look) -> [WhatsDifferentPlace] {
        var counts: [String: Int] = [:]
        var localCount = 0
        for machine in terminalMachines {
            if let machine { counts[machine, default: 0] += 1 } else { localCount += 1 }
        }
        let local = look(localID)
        var places = [WhatsDifferentPlace(id: localID, name: local.name, colorHex: local.colorHex,
                                          link: .local, terminals: localCount)]
        let names = Set(machines.keys).union(counts.keys).sorted()
        for name in names {
            let entry = look(name)
            let link: WhatsDifferentPlace.Link = machines[name] == true ? .connected : .reconnecting
            places.append(WhatsDifferentPlace(id: name, name: entry.name, colorHex: entry.colorHex,
                                              link: link, terminals: counts[name] ?? 0))
        }
        return places
    }
}

#if DEBUG
extension WhatsDifferentPlaces {
    /// `name:count[:down],...` into machines and terminal entries, for guest
    /// screenshots of a picture with machines a guest cannot link.
    static func sample(_ raw: String) -> (machines: [String: Bool], terminalMachines: [String?]) {
        var machines: [String: Bool] = [:]
        var terminals: [String?] = []
        for item in raw.split(separator: ",") {
            let parts = item.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { continue }
            machines[name] = !(parts.count > 2 && parts[2] == "down")
            let count = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            terminals += Array(repeating: name, count: max(0, min(count, 999)))
        }
        return (machines, terminals)
    }
}
#endif

/// Live state for an open sheet: the places, refreshed while it is visible so
/// the counts stay true as terminals open and close.
@MainActor
final class WhatsDifferentModel: ObservableObject {
    @Published private(set) var places: [WhatsDifferentPlace]
    private let source: () -> [WhatsDifferentPlace]
    private var timer: Timer?

    init(source: @escaping () -> [WhatsDifferentPlace]) {
        self.source = source
        self.places = source()
    }

    func start(interval: TimeInterval = 2) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let next = source()
        if next != places { places = next }
    }
}
