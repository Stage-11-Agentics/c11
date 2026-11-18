import AVFoundation
import CryptoKit
import Foundation
import UserNotifications

// C11H-319: the operator tells notifications apart by ear. Three channels
// each have their own sound, a flag kind may have its own, and any of them
// may be an audio file the operator chose. Every notification resolves
// exactly one sound here; nothing plays a second one beside it.

/// Which notification a sound is for. The notify-level dial governs turn end
/// and needs you; a flag is never dialed.
enum NotificationSoundChannel: String, CaseIterable, Sendable {
    /// An agent finished its turn, and every other routine notice (terminal
    /// alerts, `c11 notify`, mail at Chatty, c11's own notices).
    case turnEnd = "turn_end"
    /// An agent stopped on the operator: a permission prompt, a question or
    /// plan dialog, an ask.
    case needsYou = "needs_you"
    /// Every flag, unless its kind has a sound of its own.
    case flag

    var defaultsKey: String {
        switch self {
        case .turnEnd: return "notificationSound"
        case .needsYou: return "notificationNeedsYouSound"
        case .flag: return "notificationFlagSound"
        }
    }

    var shippedDefault: NotificationSoundChoice {
        switch self {
        case .turnEnd: return .named("Bottle")
        case .needsYou: return .named("Glass")
        case .flag: return .named("Hero")
        }
    }

    /// A flag always sounds; the routine channels may be silenced.
    var allowsNone: Bool { self != .flag }

    /// `turn-end`, `needs-you`, `flag`: the CLI spelling.
    var cliName: String { rawValue.replacingOccurrences(of: "_", with: "-") }

    init?(cliName: String) {
        let normalized = cliName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        self.init(rawValue: normalized)
    }

    var displayLabel: String {
        switch self {
        case .turnEnd:
            return String(localized: "notificationSound.channel.turnEnd", defaultValue: "Turn End")
        case .needsYou:
            return String(localized: "notificationSound.channel.needsYou", defaultValue: "Needs You")
        case .flag:
            return String(localized: "notificationSound.channel.flag", defaultValue: "Flag")
        }
    }

    /// The stored choice, or the shipped default when nothing valid is stored.
    func choice(defaults: UserDefaults) -> NotificationSoundChoice {
        guard let raw = defaults.string(forKey: defaultsKey),
              let parsed = NotificationSoundChoice(rawValue: raw),
              accepts(parsed) else { return shippedDefault }
        return parsed
    }

    func accepts(_ choice: NotificationSoundChoice) -> Bool {
        choice != .none || allowsNone
    }

    /// The routine channel a notification from this origin uses.
    static func routine(for origin: TerminalNotificationOrigin) -> NotificationSoundChannel {
        origin == .needsYou ? .needsYou : .turnEnd
    }
}

/// One sound, as stored in defaults and spoken by the CLI: `default`, `none`,
/// a named system or bundled sound, or `file:<id>` for an imported file.
enum NotificationSoundChoice: Hashable, Sendable {
    /// The macOS alert sound.
    case systemDefault
    case none
    /// A macOS system sound (`Hero`).
    case named(String)
    /// An imported file in c11's sound store.
    case file(String)

    static let filePrefix = "file:"

    var rawValue: String {
        switch self {
        case .systemDefault: return "default"
        case .none: return "none"
        case .named(let name): return name
        case .file(let id): return Self.filePrefix + id
        }
    }

    /// Accepts any letter case for named sounds (`hero` is `Hero`).
    init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case "default":
            self = .systemDefault
        case "none":
            self = .none
        default:
            if value.hasPrefix(Self.filePrefix) {
                let id = String(value.dropFirst(Self.filePrefix.count))
                guard CustomNotificationSoundStore.isValidID(id) else { return nil }
                self = .file(id)
            } else if let name = NotificationSoundCatalog.canonicalName(value) {
                self = .named(name)
            } else {
                return nil
            }
        }
    }

    /// A CLI or socket value that names a file to import rather than a sound:
    /// an absolute or home-relative path, or anything with a slash.
    static func looksLikePath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".")
            || trimmed.contains("/")
    }
}

/// The named sounds every picker offers.
enum NotificationSoundCatalog {
    /// macOS's own alert sounds (`/System/Library/Sounds`).
    static let systemNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
        "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ]

    static var namedValues: [String] { systemNames }

    static func canonicalName(_ value: String) -> String? {
        let lowered = value.lowercased()
        return namedValues.first { $0.lowercased() == lowered }
    }

    static func label(for choice: NotificationSoundChoice, store: CustomNotificationSoundStore) -> String {
        switch choice {
        case .systemDefault:
            return String(localized: "notificationSound.choice.default", defaultValue: "Default")
        case .none:
            return String(localized: "notificationSound.choice.none", defaultValue: "None")
        case .named(let name):
            return name
        case .file(let id):
            return store.displayName(for: id) ?? id
        }
    }
}

/// Why a sound did not play as chosen.
enum NotificationSoundFallbackReason: String, Error, Sendable {
    /// The imported file is no longer in c11's store.
    case missingFile = "missing_file"
    /// The stored file no longer opens as audio.
    case unplayable
    /// The playback copy macOS reads could not be written.
    case copyFailed = "copy_failed"
}

/// The one sound a notification plays, and where it came from.
struct NotificationSoundResolution: Equatable {
    enum Source: String {
        /// The flag kind's own sound.
        case kind
        /// The flag sound setting.
        case flag
        /// The routine channel's setting.
        case channel
        /// The channel's shipped default, after the chosen sound failed.
        case fallback
        /// The notify-level dial is at Quiet: a banner with no sound.
        case level
    }

    let played: NotificationSoundChoice
    let source: Source
    /// What was chosen, when a fallback replaced it.
    var requested: NotificationSoundChoice? = nil
    var fallbackReason: NotificationSoundFallbackReason? = nil
    /// The name handed to `UNNotificationSound(named:)`; nil for `default` and `none`.
    var systemSoundName: String? = nil

    static let quiet = NotificationSoundResolution(played: .none, source: .level)

    var notificationSound: UNNotificationSound? {
        switch played {
        case .none: return nil
        case .systemDefault: return .default
        case .named, .file:
            return systemSoundName.map { UNNotificationSound(named: UNNotificationSoundName(rawValue: $0)) }
        }
    }

    /// The fields every notification record carries about its sound.
    func addFields(to payload: inout [String: Any]) {
        payload["sound"] = played.rawValue
        payload["sound_source"] = source.rawValue
        if let requested { payload["sound_requested"] = requested.rawValue }
        if let fallbackReason { payload["sound_fallback"] = fallbackReason.rawValue }
    }

    var logFields: String {
        var parts = ["sound=\(played.rawValue)", "sound_source=\(source.rawValue)"]
        if let requested { parts.append("sound_requested=\(requested.rawValue)") }
        if let fallbackReason { parts.append("sound_fallback=\(fallbackReason.rawValue)") }
        return parts.joined(separator: " ")
    }
}

enum NotificationSoundResolver {
    /// A routine notification's sound: its channel's choice, or the channel's
    /// shipped default when an imported file is missing or unplayable.
    static func routine(
        channel: NotificationSoundChannel,
        defaults: UserDefaults,
        store: CustomNotificationSoundStore
    ) -> NotificationSoundResolution {
        resolve(channel.choice(defaults: defaults), source: .channel, channel: channel, store: store)
    }

    /// A flag's sound: its kind's sound when it has one, else the flag sound.
    /// A kind's missing or unplayable file falls back to the flag sound, and
    /// the flag sound's to Hero; the result names what was asked for and why.
    static func flag(
        kindSound: NotificationSoundChoice?,
        defaults: UserDefaults,
        store: CustomNotificationSoundStore
    ) -> NotificationSoundResolution {
        // The flag sound is prepared only when it plays: no kind sound, or a
        // kind sound that failed.
        func flagResolution() -> NotificationSoundResolution {
            resolve(NotificationSoundChannel.flag.choice(defaults: defaults), source: .flag, channel: .flag, store: store)
        }
        guard let kindSound else { return flagResolution() }
        switch playbackName(for: kindSound, store: store) {
        case .success(let name):
            return NotificationSoundResolution(played: kindSound, source: .kind, systemSoundName: name)
        case .failure(let reason):
            let flagResolution = flagResolution()
            return NotificationSoundResolution(
                played: flagResolution.played,
                source: flagResolution.source,
                requested: kindSound,
                fallbackReason: reason,
                systemSoundName: flagResolution.systemSoundName
            )
        }
    }

    private static func resolve(
        _ choice: NotificationSoundChoice,
        source: NotificationSoundResolution.Source,
        channel: NotificationSoundChannel,
        store: CustomNotificationSoundStore
    ) -> NotificationSoundResolution {
        switch playbackName(for: choice, store: store) {
        case .success(let name):
            return NotificationSoundResolution(played: choice, source: source, systemSoundName: name)
        case .failure(let reason):
            let fallback = channel.shippedDefault
            return NotificationSoundResolution(
                played: fallback,
                source: .fallback,
                requested: choice,
                fallbackReason: reason,
                systemSoundName: (try? playbackName(for: fallback, store: store).get()) ?? nil
            )
        }
    }

    /// The name macOS plays for a choice, nil for `default` and `none`. An
    /// imported file is checked and its playback copy put in place.
    static func playbackName(
        for choice: NotificationSoundChoice,
        store: CustomNotificationSoundStore
    ) -> Result<String?, NotificationSoundFallbackReason> {
        switch choice {
        case .systemDefault, .none:
            return .success(nil)
        case .named(let name):
            return .success(name)
        case .file(let id):
            return store.prepareForPlayback(id: id).map { Optional($0) }
        }
    }
}

/// C11H-319: imported sound files. Each import is copied into c11's own
/// Application Support (`c11/sounds/<sha256 prefix>.<ext>`), so moving or
/// deleting the original never breaks it, and one file imported twice is one
/// copy. macOS plays a notification's own sound only from the app bundle or a
/// `Library/Sounds` folder, so an imported sound a channel or kind uses now
/// also has a playback copy, `~/Library/Sounds/c11-<id>`, kept by
/// `NotificationSoundPlayback`. The system then plays it under Focus and the
/// operator's sound settings, which c11 playing the file itself would bypass.
struct CustomNotificationSoundStore: Sendable {
    let storeDirectory: URL
    let playbackDirectory: URL

    static let playbackPrefix = "c11-"
    /// macOS plays its default sound instead of a longer notification sound.
    static let maxDuration: TimeInterval = 30
    /// Containers macOS notifications play as they are, when their codec is
    /// one of `notificationCodecs`; anything else is converted to PCM CAF.
    static let keptExtensions: Set<String> = ["aiff", "aif", "wav", "caf"]
    static let notificationCodecs: Set<AudioFormatID> = [
        kAudioFormatLinearPCM, kAudioFormatAppleIMA4, kAudioFormatULaw, kAudioFormatALaw,
    ]

    static func hasNotificationCodec(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return notificationCodecs.contains(file.fileFormat.streamDescription.pointee.mFormatID)
    }
    private static let nameSuffix = ".name"

#if DEBUG
    /// Tests point every caller of `shared` at a scratch store.
    nonisolated(unsafe) static var sharedOverrideForTesting: CustomNotificationSoundStore?
#endif

    /// Posted on main after a file is imported, so open pickers list it.
    static let didImportNotification = Notification.Name("c11.notificationSoundImported")

    static var shared: CustomNotificationSoundStore {
#if DEBUG
        if let sharedOverrideForTesting { return sharedOverrideForTesting }
#endif
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return CustomNotificationSoundStore(
            storeDirectory: support
                .appendingPathComponent(C11Identity.stateDirectoryName, isDirectory: true)
                .appendingPathComponent("sounds", isDirectory: true),
            playbackDirectory: home.appendingPathComponent("Library/Sounds", isDirectory: true)
        )
    }

    enum ImportError: Error, Equatable {
        case missingFile(path: String)
        case notAudio(path: String)
        case tooLong(path: String, seconds: Int)
        case conversionFailed(path: String, details: String)
        case writeFailed(details: String)

        var message: String {
            switch self {
            case .missingFile(let path):
                return "no file at \(path)"
            case .notAudio(let path):
                return "\(path) is not an audio file c11 can read"
            case .tooLong(let path, let seconds):
                return "\(path) runs \(seconds) s; a notification sound must be 30 s or shorter"
            case .conversionFailed(let path, let details):
                return "could not convert \(path) for notifications: \(details)"
            case .writeFailed(let details):
                return "could not save the sound in c11's sound store: \(details)"
            }
        }
    }

    /// `<16 hex>.<aiff|aif|wav|caf>`.
    static func isValidID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 16,
              parts[0].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              keptExtensions.contains(String(parts[1])) else { return false }
        return true
    }

    func url(for id: String) -> URL {
        storeDirectory.appendingPathComponent(id, isDirectory: false)
    }

    func playbackURL(for id: String) -> URL {
        playbackDirectory.appendingPathComponent(Self.playbackPrefix + id, isDirectory: false)
    }

    /// The original file's name, kept beside the stored copy for pickers.
    func displayName(for id: String) -> String? {
        let url = storeDirectory.appendingPathComponent(id + Self.nameSuffix, isDirectory: false)
        guard let data = try? Data(contentsOf: url), data.count <= 1024,
              let name = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// Every stored sound, by name.
    func importedIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)) ?? []
        return names.filter(Self.isValidID).sorted {
            (displayName(for: $0) ?? $0).localizedStandardCompare(displayName(for: $1) ?? $1) == .orderedAscending
        }
    }

    /// Copies (or converts) a file into the store and returns its id. Files
    /// macOS plays as they are (`.aiff`, `.aif`, `.wav`, `.caf`) are kept as
    /// they are; anything else Core Audio reads (`.m4a`, `.mp3`, `.aac`, ...)
    /// is converted once to 16-bit PCM `.caf`. Filesystem and subprocess
    /// work: call off main.
    func importSound(from source: URL) -> Result<String, ImportError> {
        let fileManager = FileManager.default
        let path = source.path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return .failure(.missingFile(path: path))
        }
        guard let duration = Self.audioDuration(of: source) else {
            return .failure(.notAudio(path: path))
        }
        guard duration <= Self.maxDuration else {
            return .failure(.tooLong(path: path, seconds: Int(duration.rounded(.up))))
        }
        do {
            try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        } catch {
            return .failure(.writeFailed(details: error.localizedDescription))
        }

        let sourceExtension = source.pathExtension.lowercased()
        let data: Data
        let storedExtension: String
        if Self.keptExtensions.contains(sourceExtension), Self.hasNotificationCodec(source) {
            guard let read = try? Data(contentsOf: source) else { return .failure(.notAudio(path: path)) }
            data = read
            storedExtension = sourceExtension
        } else {
            let converted = storeDirectory.appendingPathComponent(".import-\(UUID().uuidString).caf")
            defer { try? fileManager.removeItem(at: converted) }
            if let failure = Self.convertToCAF(from: source, to: converted) {
                return .failure(.conversionFailed(path: path, details: failure))
            }
            guard let read = try? Data(contentsOf: converted) else {
                return .failure(.conversionFailed(path: path, details: "no output"))
            }
            data = read
            storedExtension = "caf"
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let id = "\(digest.prefix(16)).\(storedExtension)"
        let target = url(for: id)
        do {
            if !fileManager.fileExists(atPath: target.path) {
                try data.write(to: target, options: .atomic)
            }
            try Data(source.lastPathComponent.utf8).write(
                to: storeDirectory.appendingPathComponent(id + Self.nameSuffix), options: .atomic
            )
        } catch {
            return .failure(.writeFailed(details: error.localizedDescription))
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didImportNotification, object: nil)
        }
        return .success(id)
    }

    /// Checks the stored copy and keeps the playback copy macOS reads in
    /// place; returns the name to hand `UNNotificationSound(named:)`.
    func prepareForPlayback(id: String) -> Result<String, NotificationSoundFallbackReason> {
        let fileManager = FileManager.default
        let stored = url(for: id)
        let playback = playbackURL(for: id)
        guard let storedSize = Self.fileSize(stored) else { return .failure(.missingFile) }
        // Content-addressed: a playback copy of the same size is this sound,
        // checked when it was made.
        if storedSize == Self.fileSize(playback) { return .success(playback.lastPathComponent) }
        guard Self.audioDuration(of: stored) != nil else { return .failure(.unplayable) }
        do {
            try fileManager.createDirectory(at: playbackDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: playback.path) {
                try fileManager.removeItem(at: playback)
            }
            try fileManager.copyItem(at: stored, to: playback)
        } catch {
            return .failure(.copyFailed)
        }
        return .success(playback.lastPathComponent)
    }

    /// Removes every `c11-<id>` playback copy whose id is not kept. Nothing
    /// else in that folder is touched. Returns the ids removed.
    @discardableResult
    func removePlaybackCopies(keeping kept: Set<String>) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: playbackDirectory.path)) ?? []
        var removed: [String] = []
        for name in names where name.hasPrefix(Self.playbackPrefix) {
            let id = String(name.dropFirst(Self.playbackPrefix.count))
            guard Self.isValidID(id), !kept.contains(id) else { continue }
            if (try? FileManager.default.removeItem(at: playbackURL(for: id))) != nil {
                removed.append(id)
            }
        }
        return removed.sorted()
    }

    static func audioDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    /// Returns nil on success, else what went wrong.
    private static func convertToCAF(from source: URL, to destination: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "caff", "-d", "LEI16", source.path, destination.path]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "afconvert exited \(process.terminationStatus)" : text
        }
        return nil
    }
}

/// C11H-319: the `c11-<id>` playback copies in `~/Library/Sounds` exist only
/// for imported sounds a channel or a flag kind uses now. After any sound
/// setting changes (Settings, CLI, a kind's removal, the launch migration),
/// `sync` puts each in-use copy in place and removes every other `c11-<id>`
/// copy. It never touches any other file in that folder.
enum NotificationSoundPlayback {
    private static let queue = DispatchQueue(label: "com.stage11.c11.notification-sound-playback", qos: .utility)

    static func fileIDsInUse(defaults: UserDefaults, registry: PanelFlagKindRegistry) -> Set<String> {
        var ids = Set<String>()
        let choices = NotificationSoundChannel.allCases.map { $0.choice(defaults: defaults) }
            + registry.all().compactMap { registry.sound(id: $0.id) }
        for case .file(let id) in choices { ids.insert(id) }
        return ids
    }

    /// Filesystem work: call off main (never from the sync queue). Every sync
    /// runs on one serial queue, so two never interleave. Returns the ids
    /// kept and removed.
    @discardableResult
    static func sync(
        defaults: UserDefaults = .standard,
        registry: PanelFlagKindRegistry = .shared,
        store: CustomNotificationSoundStore = .shared
    ) -> (kept: [String], removed: [String]) {
        queue.sync { syncNow(defaults: defaults, registry: registry, store: store) }
    }

    /// For main-thread callers (Settings): queues a sync.
    static func syncInBackground() {
        let store = CustomNotificationSoundStore.shared
        queue.async { syncNow(defaults: .standard, registry: .shared, store: store) }
    }

    private static func syncNow(
        defaults: UserDefaults,
        registry: PanelFlagKindRegistry,
        store: CustomNotificationSoundStore
    ) -> (kept: [String], removed: [String]) {
        let inUse = fileIDsInUse(defaults: defaults, registry: registry)
        for id in inUse { _ = store.prepareForPlayback(id: id) }
        return (inUse.sorted(), store.removePlaybackCopies(keeping: inUse))
    }
}

/// C11H-319: turns a CLI, socket or Settings value into a stored choice,
/// importing a file when the value is a path. Off main: an import may run
/// `afconvert`.
enum NotificationSoundInput {
    enum Failure: Error, Equatable {
        case unknownSound(String)
        case noneNotAllowed
        case importFailed(CustomNotificationSoundStore.ImportError)

        var message: String {
            switch self {
            case .unknownSound(let value):
                return "unknown sound '\(value)': use default, none, one of \(NotificationSoundCatalog.namedValues.joined(separator: ", ")), or a path to an audio file"
            case .noneNotAllowed:
                return "the flag sound cannot be none: a flag always sounds (a flag kind may be none)"
            case .importFailed(let error):
                return error.message
            }
        }
    }

    static func choice(
        from value: String,
        allowsNone: Bool,
        store: CustomNotificationSoundStore
    ) -> Result<NotificationSoundChoice, Failure> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if NotificationSoundChoice.looksLikePath(trimmed), !trimmed.hasPrefix(NotificationSoundChoice.filePrefix) {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return store.importSound(from: URL(fileURLWithPath: expanded))
                .map { NotificationSoundChoice.file($0) }
                .mapError { Failure.importFailed($0) }
        }
        guard let choice = NotificationSoundChoice(rawValue: trimmed) else {
            return .failure(.unknownSound(trimmed))
        }
        if choice == .none, !allowsNone { return .failure(.noneNotAllowed) }
        return .success(choice)
    }
}

/// C11H-319: the inherited "Custom File..." turn-end sound stored a path,
/// which went silent when the file moved. Once, at launch, that path is
/// imported into the store and the setting becomes `file:<id>`.
enum NotificationSoundLegacyMigration {
    static let legacyCustomFileValue = "custom_file"
    static let legacyCustomFilePathKey = "notificationSoundCustomFilePath"

    /// The path to import, when the turn-end setting is the legacy custom file.
    static func pendingPath(defaults: UserDefaults) -> String? {
        guard defaults.string(forKey: NotificationSoundChannel.turnEnd.defaultsKey) == legacyCustomFileValue,
              let path = defaults.string(forKey: legacyCustomFilePathKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return (path as NSString).expandingTildeInPath
    }

    /// Imports off main and writes the setting on main (AGENTS.md: write
    /// UserDefaults on main only). A file that is gone leaves the turn-end
    /// sound on its shipped default.
    static func run(defaults: UserDefaults = .standard, store: CustomNotificationSoundStore = .shared) {
        guard let path = pendingPath(defaults: defaults) else { return }
        DispatchQueue.global(qos: .utility).async {
            let result = store.importSound(from: URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                apply(result, path: path, defaults: defaults)
                NotificationSoundPlayback.syncInBackground()
            }
        }
    }

    static func apply(
        _ result: Result<String, CustomNotificationSoundStore.ImportError>,
        path: String,
        defaults: UserDefaults
    ) {
        guard defaults.string(forKey: NotificationSoundChannel.turnEnd.defaultsKey) == legacyCustomFileValue else { return }
        switch result {
        case .success(let id):
            defaults.set(NotificationSoundChoice.file(id).rawValue, forKey: NotificationSoundChannel.turnEnd.defaultsKey)
            NSLog("notification.sound migrated legacy custom file to file:%@", id)
        case .failure(let error):
            defaults.removeObject(forKey: NotificationSoundChannel.turnEnd.defaultsKey)
            NSLog("notification.sound legacy custom file not migrated: %@", error.message)
        }
        defaults.removeObject(forKey: legacyCustomFilePathKey)
    }
}

/// C11H-319: one agent-readable record per routine system notification (a
/// turn end or a needs-you), as a `notification.routine` event and one log
/// line. It names the channel and the sound, never the text.
struct RoutineNotificationRecord: Equatable {
    enum Action: String {
        case posted
        case failed
    }

    let action: Action
    let channel: NotificationSoundChannel
    let identifier: String
    let workspaceId: UUID?
    let surfaceId: UUID?
    let sound: NotificationSoundResolution

    var payload: [String: Any] {
        var payload: [String: Any] = [
            "action": action.rawValue,
            "channel": channel.rawValue,
            "identifier": identifier,
        ]
        if let surfaceId { payload["panel"] = surfaceId.uuidString.lowercased() }
        sound.addFields(to: &payload)
        return payload
    }

    var logLine: String {
        [
            "notification.routine",
            "action=\(action.rawValue)",
            "channel=\(channel.rawValue)",
            "panel=\(surfaceId?.uuidString.lowercased() ?? "-")",
            "workspace=\(workspaceId?.uuidString.lowercased() ?? "-")",
            sound.logFields,
            "identifier=\(identifier)",
        ].joined(separator: " ")
    }
}
