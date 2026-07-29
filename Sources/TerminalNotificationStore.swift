import AppKit
import Foundation
import UserNotifications
import Bonsplit

// UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:) and
// removePendingNotificationRequests(withIdentifiers:) perform synchronous XPC to
// usernoted under the hood. When usernoted is slow, this blocks the calling thread
// indefinitely. These helpers dispatch the calls off the main thread so they never
// freeze the UI.
extension UNUserNotificationCenter {
    private static let removalQueue = DispatchQueue(
        label: "com.stage11.c11.notification-removal",
        qos: .utility
    )

    func removeDeliveredNotificationsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func removePendingNotificationRequestsOffMain(withIdentifiers ids: [String]) {
        guard !ids.isEmpty else { return }
        Self.removalQueue.async {
            self.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Serialize remove-before-add for one replacement identifier. The removal
    /// calls are synchronous XPC, so returning to main only after both calls
    /// guarantees the newly-added request cannot race ahead and be deleted.
    func replaceNotificationOffMain(
        withIdentifier identifier: String,
        add: @escaping @MainActor () -> Void
    ) {
        Self.removalQueue.async {
            self.removeDeliveredNotifications(withIdentifiers: [identifier])
            self.removePendingNotificationRequests(withIdentifiers: [identifier])
            DispatchQueue.main.async {
                MainActor.assumeIsolated { add() }
            }
        }
    }
}

enum NotificationSoundSettings {
    static let key = "notificationSound"
    static let defaultValue = "Bottle"
    static let customFileValue = "custom_file"
    static let customFilePathKey = "notificationSoundCustomFilePath"
    static let defaultCustomFilePath = ""
    private static let stagedCustomSoundBaseName = "cmux-custom-notification-sound"
    private static let customSoundPreparationQueue = DispatchQueue(
        label: "com.stage11.c11.notification-sound-preparation",
        qos: .utility
    )
    private static let pendingCustomSoundPreparationLock = NSLock()
    private static var pendingCustomSoundPreparationPaths: Set<String> = []
    private static let notificationSoundSupportedExtensions: Set<String> = [
        "aif",
        "aiff",
        "caf",
        "wav",
    ]

    private struct CustomSoundSourceMetadata: Codable, Equatable {
        let sourcePath: String
        let sourceSize: UInt64
        let sourceModificationTime: Double
        let sourceFileIdentifier: UInt64?
    }

    enum CustomSoundPreparationIssue: Error {
        case emptyPath
        case missingFile(path: String)
        case missingFileExtension(path: String)
        case stagingFailed(path: String, details: String)

        var logMessage: String {
            switch self {
            case .emptyPath:
                return "Notification custom sound path is empty"
            case .missingFile(let path):
                return "Notification custom sound file does not exist: \(path)"
            case .missingFileExtension(let path):
                return "Notification custom sound requires a file extension: \(path)"
            case .stagingFailed(let path, let details):
                return "Failed to stage custom notification sound from \(path): \(details)"
            }
        }
    }
    static let customCommandKey = "notificationCustomCommand"
    static let defaultCustomCommand = ""

    static let systemSounds: [(label: String, value: String)] = [
        ("Default", "default"),
        ("Basso", "Basso"),
        ("Blow", "Blow"),
        ("Bottle", "Bottle"),
        ("Frog", "Frog"),
        ("Funk", "Funk"),
        ("Glass", "Glass"),
        ("Hero", "Hero"),
        ("Morse", "Morse"),
        ("Ping", "Ping"),
        ("Pop", "Pop"),
        ("Purr", "Purr"),
        ("Sosumi", "Sosumi"),
        ("Submarine", "Submarine"),
        ("Tink", "Tink"),
        ("Custom File...", customFileValue),
        ("None", "none"),
    ]

    static func sound(defaults: UserDefaults = .standard) -> UNNotificationSound? {
        let value = defaults.string(forKey: key) ?? defaultValue
        switch value {
        case "default":
            return .default
        case "none":
            return nil
        case customFileValue:
            guard let customSoundName = stagedCustomSoundName(defaults: defaults) else {
                return nil
            }
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: customSoundName))
        default:
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: value))
        }
    }

    static func usesSystemSound(defaults: UserDefaults = .standard) -> Bool {
        let value = defaults.string(forKey: key) ?? defaultValue
        switch value {
        case "none":
            return false
        case customFileValue:
            return customFileURL(defaults: defaults) != nil
        default:
            return true
        }
    }

    static func isSilent(defaults: UserDefaults = .standard) -> Bool {
        return (defaults.string(forKey: key) ?? defaultValue) == "none"
    }

    static func isCustomFileSelected(defaults: UserDefaults = .standard) -> Bool {
        (defaults.string(forKey: key) ?? defaultValue) == customFileValue
    }

    static func stagedCustomSoundName(defaults: UserDefaults = .standard) -> String? {
        let rawPath = defaults.string(forKey: customFilePathKey) ?? defaultCustomFilePath
        guard let normalizedPath = normalizedCustomFilePath(rawPath) else {
            NSLog("Notification custom sound unavailable: \(CustomSoundPreparationIssue.emptyPath.logMessage)")
            return nil
        }

        let sourceURL = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        let sourceExtension = sourceURL.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !sourceExtension.isEmpty else {
            NSLog("Notification custom sound unavailable: \(CustomSoundPreparationIssue.missingFileExtension(path: sourceURL.path).logMessage)")
            return nil
        }

        let destinationExtension = stagedCustomSoundFileExtension(forSourceExtension: sourceExtension)
        let stagedFileName = stagedCustomSoundFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let stagedURL = stagedSoundDirectoryURL().appendingPathComponent(stagedFileName, isDirectory: false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            NSLog("Notification custom sound unavailable: \(CustomSoundPreparationIssue.missingFile(path: sourceURL.path).logMessage)")
            return nil
        }

        if fileManager.fileExists(atPath: stagedURL.path) {
            if let sourceMetadata = currentSourceMetadata(for: sourceURL, fileManager: fileManager),
               let stagedMetadata = loadStagedSourceMetadata(for: stagedURL),
               stagedMetadata == sourceMetadata {
                return stagedFileName
            }
        }

        if destinationExtension == sourceExtension {
            switch prepareCustomFileForNotifications(path: normalizedPath) {
            case .success(let preparedName):
                return preparedName
            case .failure(let issue):
                NSLog("Notification custom sound unavailable: \(issue.logMessage)")
                return nil
            }
        }

        queueCustomSoundPreparation(path: normalizedPath)
        NSLog("Notification custom sound not ready yet, staging in background: \(sourceURL.path)")
        return nil
    }

    static func prepareCustomFileForNotifications(path: String) -> Result<String, CustomSoundPreparationIssue> {
        guard let normalizedPath = normalizedCustomFilePath(path) else {
            return .failure(.emptyPath)
        }
        let sourceURL = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        return prepareCustomSound(from: sourceURL)
    }

    private static func prepareCustomSound(from sourceURL: URL) -> Result<String, CustomSoundPreparationIssue> {
        let sourcePath = sourceURL.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourcePath) else {
            return .failure(.missingFile(path: sourcePath))
        }
        let sourceExtension = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceExtension.isEmpty else {
            return .failure(.missingFileExtension(path: sourcePath))
        }
        let destinationExtension = stagedCustomSoundFileExtension(forSourceExtension: sourceExtension)

        let destinationDirectory = stagedSoundDirectoryURL()
        let destinationFileName = stagedCustomSoundFileName(
            forSourceURL: sourceURL,
            destinationExtension: destinationExtension
        )
        let destinationURL = destinationDirectory.appendingPathComponent(destinationFileName, isDirectory: false)
        let sourceMetadata = currentSourceMetadata(for: sourceURL, fileManager: fileManager)

        do {
            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                let stagedMetadata = loadStagedSourceMetadata(for: destinationURL)
                if stagedMetadata != sourceMetadata {
                    try? fileManager.removeItem(at: destinationURL)
                }
            }
            if destinationExtension == sourceExtension.lowercased() {
                try copyStagedSoundIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            } else {
                try transcodeStagedSoundIfNeeded(from: sourceURL, to: destinationURL, fileManager: fileManager)
            }
            if let sourceMetadata {
                try saveStagedSourceMetadata(sourceMetadata, for: destinationURL)
            }
            try cleanupStaleStagedSoundFiles(
                in: destinationDirectory,
                keeping: destinationFileName,
                preservingSourceURL: sourceURL,
                fileManager: fileManager
            )
            return .success(destinationFileName)
        } catch {
            return .failure(.stagingFailed(path: sourcePath, details: error.localizedDescription))
        }
    }

    static func customFileURL(defaults: UserDefaults = .standard) -> URL? {
        guard let path = normalizedCustomFilePath(defaults.string(forKey: customFilePathKey) ?? defaultCustomFilePath) else {
            return nil
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func playCustomFileSound(defaults: UserDefaults = .standard) {
        guard let url = customFileURL(defaults: defaults) else { return }
        playSoundFile(at: url)
    }

    static func playCustomFileSound(path: String) {
        guard let normalizedPath = normalizedCustomFilePath(path) else { return }
        let url = URL(fileURLWithPath: (normalizedPath as NSString).expandingTildeInPath)
        playSoundFile(at: url)
    }

    static func previewSound(value: String, defaults: UserDefaults = .standard) {
        switch value {
        case "default":
            NSSound.beep()
        case "none":
            break
        case customFileValue:
            playCustomFileSound(defaults: defaults)
        default:
            NSSound(named: NSSound.Name(value))?.play()
        }
    }

    static func stagedCustomSoundFileExtension(forSourceExtension sourceExtension: String) -> String {
        let normalized = sourceExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return "caf" }
        if notificationSoundSupportedExtensions.contains(normalized) {
            return normalized
        }
        return "caf"
    }

    static func stagedCustomSoundFileName(forSourceURL sourceURL: URL, destinationExtension: String) -> String {
        let normalizedExtension = destinationExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let ext = normalizedExtension.isEmpty ? "caf" : normalizedExtension
        let signature = stagedCustomSoundSourceSignature(for: sourceURL)
        return "\(stagedCustomSoundBaseName)-\(signature).\(ext)"
    }

    private static func normalizedCustomFilePath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func stagedSoundDirectoryURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
    }

    private static func queueCustomSoundPreparation(path: String) {
        let expandedPath = (path as NSString).expandingTildeInPath
        pendingCustomSoundPreparationLock.lock()
        if pendingCustomSoundPreparationPaths.contains(expandedPath) {
            pendingCustomSoundPreparationLock.unlock()
            return
        }
        pendingCustomSoundPreparationPaths.insert(expandedPath)
        pendingCustomSoundPreparationLock.unlock()

        customSoundPreparationQueue.async {
            defer {
                pendingCustomSoundPreparationLock.lock()
                pendingCustomSoundPreparationPaths.remove(expandedPath)
                pendingCustomSoundPreparationLock.unlock()
            }
            _ = prepareCustomFileForNotifications(path: expandedPath)
        }
    }

    private static func playSoundFile(at url: URL) {
        DispatchQueue.main.async {
            guard let sound = NSSound(contentsOf: url, byReference: false) else {
                NSLog("Notification custom sound failed to load from path: \(url.path)")
                return
            }
            sound.play()
        }
    }

    private static func cleanupStaleStagedSoundFiles(
        in directoryURL: URL,
        keeping fileName: String,
        preservingSourceURL: URL,
        fileManager: FileManager
    ) throws {
        let legacyPrefix = "\(stagedCustomSoundBaseName)."
        let hashedPrefix = "\(stagedCustomSoundBaseName)-"
        let normalizedSource = preservingSourceURL.standardizedFileURL
        let keptStagedURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let keptMetadataFileName = stagedSourceMetadataURL(for: keptStagedURL).lastPathComponent
        for fileNameCandidate in try fileManager.contentsOfDirectory(atPath: directoryURL.path) {
            let isManagedName = fileNameCandidate.hasPrefix(legacyPrefix) || fileNameCandidate.hasPrefix(hashedPrefix)
            let isKeptManagedFile = fileNameCandidate == fileName || fileNameCandidate == keptMetadataFileName
            guard isManagedName, !isKeptManagedFile else { continue }
            let staleURL = directoryURL.appendingPathComponent(fileNameCandidate, isDirectory: false)
            if staleURL.standardizedFileURL == normalizedSource {
                continue
            }
            try? fileManager.removeItem(at: staleURL)
            try? fileManager.removeItem(at: stagedSourceMetadataURL(for: staleURL))
        }
    }

    private static func copyStagedSoundIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let normalizedSource = sourceURL.standardizedFileURL
        let normalizedDestination = destinationURL.standardizedFileURL
        guard normalizedSource != normalizedDestination else { return }

        if fileManager.fileExists(atPath: normalizedDestination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: normalizedSource.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: normalizedDestination.path)
            let sourceSize = sourceAttributes[.size] as? NSNumber
            let destinationSize = destinationAttributes[.size] as? NSNumber
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if sourceSize == destinationSize && sourceDate == destinationDate {
                return
            }
            try fileManager.removeItem(at: normalizedDestination)
        }

        try fileManager.copyItem(at: normalizedSource, to: normalizedDestination)
    }

    private static func transcodeStagedSoundIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let normalizedSource = sourceURL.standardizedFileURL
        let normalizedDestination = destinationURL.standardizedFileURL
        guard normalizedSource != normalizedDestination else { return }

        if fileManager.fileExists(atPath: normalizedDestination.path) {
            let sourceAttributes = try fileManager.attributesOfItem(atPath: normalizedSource.path)
            let destinationAttributes = try fileManager.attributesOfItem(atPath: normalizedDestination.path)
            let sourceDate = sourceAttributes[.modificationDate] as? Date
            let destinationDate = destinationAttributes[.modificationDate] as? Date
            if let sourceDate, let destinationDate, destinationDate >= sourceDate {
                return
            }
            try fileManager.removeItem(at: normalizedDestination)
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "caff",
            "-d", "LEI16",
            normalizedSource.path,
            normalizedDestination.path,
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fileManager.fileExists(atPath: normalizedDestination.path) {
                try? fileManager.removeItem(at: normalizedDestination)
            }
            let description: String
            if let errorOutput, !errorOutput.isEmpty {
                description = errorOutput
            } else {
                description = "afconvert failed with exit code \(process.terminationStatus)"
            }
            throw NSError(
                domain: "NotificationSoundSettings",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: description,
                ]
            )
        }
    }

    private static func stagedCustomSoundSourceSignature(for sourceURL: URL) -> String {
        let normalizedPath = sourceURL.standardizedFileURL.path
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in normalizedPath.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func stagedSourceMetadataURL(for stagedURL: URL) -> URL {
        stagedURL.appendingPathExtension("source-metadata")
    }

    private static func currentSourceMetadata(for sourceURL: URL, fileManager: FileManager) -> CustomSoundSourceMetadata? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourceURL.path) else {
            return nil
        }
        guard let sourceSizeNumber = attributes[.size] as? NSNumber else {
            return nil
        }
        let sourceDate = (attributes[.modificationDate] as? Date) ?? .distantPast
        let fileIdentifier = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return CustomSoundSourceMetadata(
            sourcePath: sourceURL.standardizedFileURL.path,
            sourceSize: sourceSizeNumber.uint64Value,
            sourceModificationTime: sourceDate.timeIntervalSinceReferenceDate,
            sourceFileIdentifier: fileIdentifier
        )
    }

    private static func loadStagedSourceMetadata(for stagedURL: URL) -> CustomSoundSourceMetadata? {
        let metadataURL = stagedSourceMetadataURL(for: stagedURL)
        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }
        return try? JSONDecoder().decode(CustomSoundSourceMetadata.self, from: data)
    }

    private static func saveStagedSourceMetadata(_ metadata: CustomSoundSourceMetadata, for stagedURL: URL) throws {
        let metadataURL = stagedSourceMetadataURL(for: stagedURL)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private static let customCommandQueue = DispatchQueue(
        label: "com.stage11.c11.notification-custom-command",
        qos: .utility
    )

    static func runCustomCommand(title: String, subtitle: String, body: String, defaults: UserDefaults = .standard) {
        let command = (defaults.string(forKey: customCommandKey) ?? defaultCustomCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        customCommandQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["CMUX_NOTIFICATION_TITLE"] = title
            env["CMUX_NOTIFICATION_SUBTITLE"] = subtitle
            env["CMUX_NOTIFICATION_BODY"] = body
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                NSLog("Notification command failed to launch: \(error)")
            }
        }
    }
}

enum NotificationPaneRingSettings {
    static let enabledKey = "notificationPaneRingEnabled"
    static let defaultEnabled = true
}

enum NotificationPaneFlashSettings {
    static let enabledKey = "notificationPaneFlashEnabled"
    static let defaultEnabled = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }
}

/// CMUX-10: configurable Flash Duration. Scales both the pane and sidebar
/// envelopes — the sidebar inherits the same temporal pattern and just applies
/// its `peakScale` (commit 3), so a single duration tunes the whole signal.
/// Persisted in UserDefaults under `notificationFlashDurationMs`.
enum NotificationFlashDurationSettings {
    static let storageKey = "notificationFlashDurationMs"
    static let defaultMs: Int = 1500
    static let minMs: Int = 500
    static let maxMs: Int = 4000

    static func currentMs(defaults: UserDefaults = .standard) -> Int {
        if defaults.object(forKey: storageKey) == nil {
            return defaultMs
        }
        let raw = defaults.integer(forKey: storageKey)
        return clamp(raw)
    }

    static func setMs(_ ms: Int, defaults: UserDefaults = .standard) {
        defaults.set(clamp(ms), forKey: storageKey)
    }

    private static func clamp(_ ms: Int) -> Int {
        return min(maxMs, max(minMs, ms))
    }
}

enum AppFocusState {
    static var overrideIsFocused: Bool?

    static func isAppActive() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        return NSApp.isActive
    }

    static func isAppFocused() -> Bool {
        if let overrideIsFocused {
            return overrideIsFocused
        }
        guard NSApp.isActive else { return false }
        guard let keyWindow = NSApp.keyWindow, keyWindow.isKeyWindow else { return false }
        // Only treat the app as "focused" for notification suppression when a main terminal window
        // is key. If Settings/About/debug panels are key, we still want notifications to show.
        if let raw = keyWindow.identifier?.rawValue {
            return raw == "cmux.main" || raw.hasPrefix("cmux.main.")
        }
        return false
    }
}

enum NotificationAuthorizationState: Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral

    var statusLabel: String {
        switch self {
        case .unknown, .notDetermined:
            return "Not Requested"
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .provisional:
            return "Deliver Quietly"
        case .ephemeral:
            return "Temporary"
        }
    }

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .unknown, .notDetermined, .denied:
            return false
        }
    }
}

struct TerminalNotification: Identifiable, Hashable {
    let id: UUID
    /// Stable external-delivery identity. Routine notification-store records
    /// use their UUID; direct flag alerts use workspace/surface/flag-epoch so
    /// an active reason revision replaces the existing delivered alert.
    let systemIdentifier: String?
    let tabId: UUID
    let surfaceId: UUID?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    var isRead: Bool

    init(
        id: UUID,
        systemIdentifier: String? = nil,
        tabId: UUID,
        surfaceId: UUID?,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        isRead: Bool
    ) {
        self.id = id
        self.systemIdentifier = systemIdentifier
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
    }
}

@MainActor
final class TerminalNotificationStore: ObservableObject {
    struct TabSurfaceKey: Hashable {
        let tabId: UUID
        let surfaceId: UUID?
    }

    struct NotificationIndexes {
        var rawUnreadCount = 0
        var rawUnreadCountByTabId: [UUID: Int] = [:]
        var rawUnreadByTabSurface = Set<TabSurfaceKey>()
        var unreadCount = 0
        var unreadCountByTabId: [UUID: Int] = [:]
        var unreadByTabSurface = Set<TabSurfaceKey>()
        var latestUnreadByTabId: [UUID: TerminalNotification] = [:]
        var latestByTabId: [UUID: TerminalNotification] = [:]
    }

    static let shared = TerminalNotificationStore(
        systemNotificationsEnabled: defaultSystemNotificationsEnabled()
    )

    private struct DirectFlagDeliveryToken: Equatable {
        let identifier: String
        let generation: UUID
    }

    static let categoryIdentifier = "com.stage11.c11.userNotification"
    static let actionShowIdentifier = "com.stage11.c11.userNotification.show"
    private enum AuthorizationRequestOrigin: String {
        case notificationDelivery = "notification_delivery"
        case settingsButton = "settings_button"
        case settingsTest = "settings_test"
    }

    @Published private(set) var notifications: [TerminalNotification] = [] {
        didSet {
            // C11-163: capture the prior per-tab unread counts before the
            // rebuild so waiting-agent edges can be detected (amendment H).
            let previousUnreadByTab = indexes.unreadCountByTabId
            indexes = Self.buildIndexes(
                for: notifications,
                signalEligible: Self.isSignalEligible
            )
            emitWaitingEdges(previous: previousUnreadByTab, current: indexes.unreadCountByTabId)
        }
    }
    @Published private(set) var authorizationState: NotificationAuthorizationState = .unknown

    /// `UNUserNotificationCenter.current()` requires an application bundle.
    /// Bare c11LogicTests run under `xctest` without `NSApplication`, where
    /// calling it traps inside UserNotifications. Keep the real center lazy and
    /// unavailable only for that process shape; hosted tests and the app retain
    /// the production transport.
    private let systemNotificationsEnabled: Bool
    private lazy var center: UNUserNotificationCenter? = {
        guard systemNotificationsEnabled else { return nil }
        return UNUserNotificationCenter.current()
    }()
    private var hasRequestedAutomaticAuthorization = false
    private var hasDeferredAuthorizationRequest = false
    private var hasPromptedForSettings = false
    private let settingsPromptWindowRetryDelay: TimeInterval = 0.5
    private let settingsPromptWindowRetryLimit = 20
    private var notificationSettingsWindowProvider: () -> NSWindow? = {
        NSApp.keyWindow ?? NSApp.mainWindow
    }
    private var notificationSettingsAlertFactory: () -> NSAlert = {
        NSAlert()
    }
    private var notificationSettingsScheduler: (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void = {
        delay,
        block in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            block()
        }
    }
    private var notificationSettingsURLOpener: (URL) -> Void = { url in
        NSWorkspace.shared.open(url)
    }
    private var notificationDeliveryHandler: (TerminalNotificationStore, TerminalNotification) -> Void = {
        store,
        notification in
        store.scheduleUserNotification(notification)
    }
    /// Current direct-delivery generation per active flag epoch. Reason
    /// revisions keep the deterministic identifier but replace its generation;
    /// lower/close/prune remove the generation before cancellation.
    private var directFlagDeliveryTokens: [String: DirectFlagDeliveryToken] = [:]
#if DEBUG
    private var waitingEdgeHandlerForTesting: ((Bool, UUID) -> Void)?
    private var flagNotificationReplacementHandlerForTesting:
        ((_ identifier: String, _ add: @escaping @MainActor () -> Void) -> Void)?
    private var directFlagAuthorizationHandlerForTesting:
        ((_ completion: @escaping (Bool) -> Void) -> Void)?
    private var directFlagAddHandlerForTesting:
        ((_ notification: TerminalNotification, _ completion: @escaping (Error?) -> Void) -> Void)?
    private var directFlagCustomCommandHandlerForTesting:
        ((_ notification: TerminalNotification) -> Void)?
#endif
    private var indexes = NotificationIndexes()

    /// C11-163: emit waiting.entered / waiting.left on the per-tab unread
    /// 0↔1 edge. "Agent is waiting" == the tab has an unread notification;
    /// this fires through the single `notifications` didSet, covering every
    /// caller (addNotification / markRead* / markUnread / markAllRead). The
    /// waiting signal is a TEL-6 seam — if the waiting-agent cluster plan
    /// redefines "attention demand", rewire the source here.
    private func emitWaitingEdges(previous: [UUID: Int], current: [UUID: Int]) {
        let tabs = Set(previous.keys).union(current.keys)
        for tab in tabs {
            let before = previous[tab] ?? 0
            let after = current[tab] ?? 0
            if before == 0, after > 0 {
                EventEmitter.shared.emitWaiting(entered: true, workspace: tab, surface: nil)
#if DEBUG
                waitingEdgeHandlerForTesting?(true, tab)
#endif
            } else if before > 0, after == 0 {
                EventEmitter.shared.emitWaiting(entered: false, workspace: tab, surface: nil)
#if DEBUG
                waitingEdgeHandlerForTesting?(false, tab)
#endif
            }
        }
    }

    private init(systemNotificationsEnabled: Bool) {
        self.systemNotificationsEnabled = systemNotificationsEnabled
        indexes = Self.buildIndexes(for: notifications, signalEligible: Self.isSignalEligible)
        if systemNotificationsEnabled {
            refreshAuthorizationStatus()
        }
    }

    private static func defaultSystemNotificationsEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hasApplication: Bool = NSApp != nil
    ) -> Bool {
        !(environment["XCTestConfigurationFilePath"] != nil && !hasApplication)
    }

    var unreadCount: Int {
        indexes.unreadCount
    }

    var rawUnreadCount: Int {
        indexes.rawUnreadCount
    }

    private func logAuthorization(_ message: String) {
#if DEBUG
        dlog("notification.auth \(message)")
#endif
        NSLog("notification.auth %@", message)
    }

    private static func authorizationStatusLabel(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    func refreshAuthorizationStatus() {
        guard let center else {
            authorizationState = .unknown
            return
        }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "refresh status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel)"
                )
            }
        }
    }

    func requestAuthorizationFromSettings() {
        logAuthorization("settings request tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsButton) { _ in }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        logAuthorization("open settings url=\(url.absoluteString)")
        notificationSettingsURLOpener(url)
    }

    func sendSettingsTestNotification() {
        logAuthorization("settings test tapped state=\(authorizationState.statusLabel)")
        ensureAuthorization(origin: .settingsTest) { [weak self] authorized in
            guard let self, authorized, let center = self.center else { return }

            let content = UNMutableNotificationContent()
            content.title = "cmux test notification"
            content.body = "Desktop notifications are enabled."
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier

            let request = UNNotificationRequest(
                identifier: "cmux.settings.test.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule test notification: \(error)")
                    self.logAuthorization("settings test schedule failed error=\(error.localizedDescription)")
                } else {
                    self.logAuthorization("settings test schedule succeeded")
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    func handleApplicationDidBecomeActive() {
        logAuthorization("app became active deferred=\(hasDeferredAuthorizationRequest)")
        if hasDeferredAuthorizationRequest {
            hasDeferredAuthorizationRequest = false
            ensureAuthorization(origin: .settingsButton) { _ in }
            return
        }
        refreshAuthorizationStatus()
    }

    func unreadCount(forTabId tabId: UUID) -> Int {
        indexes.unreadCountByTabId[tabId] ?? 0
    }

    func hasUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        indexes.unreadByTabSurface.contains(TabSurfaceKey(tabId: tabId, surfaceId: surfaceId))
    }

    func hasRawUnreadNotification(forTabId tabId: UUID, surfaceId: UUID?) -> Bool {
        indexes.rawUnreadByTabSurface.contains(TabSurfaceKey(tabId: tabId, surfaceId: surfaceId))
    }

    func isSignalEligible(_ notification: TerminalNotification) -> Bool {
        Self.isSignalEligible(notification)
    }

    func refreshSignalEligibility() {
        let previous = indexes.unreadCountByTabId
        let next = Self.buildIndexes(
            for: notifications,
            signalEligible: Self.isSignalEligible
        )
        guard previous != next.unreadCountByTabId
                || indexes.unreadByTabSurface != next.unreadByTabSurface else {
            indexes = next
            return
        }
        objectWillChange.send()
        indexes = next
        emitWaitingEdges(previous: previous, current: indexes.unreadCountByTabId)
        for workspaceId in Set(previous.keys).union(indexes.unreadCountByTabId.keys) {
            AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?
                .tabs.first(where: { $0.id == workspaceId })?
                .syncSurfaceTabActivityStates()
        }
    }

    func latestNotification(forTabId tabId: UUID) -> TerminalNotification? {
        indexes.latestUnreadByTabId[tabId] ?? indexes.latestByTabId[tabId]
    }

    func addNotification(tabId: UUID, surfaceId: UUID?, title: String, subtitle: String, body: String) {
        var updated = notifications
        var idsToClear: [String] = []
        updated.removeAll { existing in
            guard existing.tabId == tabId, existing.surfaceId == surfaceId else { return false }
            idsToClear.append(existing.id.uuidString)
            return true
        }

        let isActiveTab = AppDelegate.shared?.tabManager?.selectedTabId == tabId
        let focusedSurfaceId = AppDelegate.shared?.tabManager?.focusedSurfaceId(for: tabId)
        let isFocusedSurface = surfaceId == nil || focusedSurfaceId == surfaceId
        let isFocusedPanel = isActiveTab && isFocusedSurface
        let isAppFocused = AppFocusState.isAppFocused()
        let attentionSuppressed = surfaceId.map {
            SurfaceAttentionIndex.shared.snapshot(workspaceId: tabId, surfaceId: $0).suppressed
        } ?? false
        let shouldSuppressExternalDelivery = (isAppFocused && isFocusedPanel) || attentionSuppressed

        // An agent notification is a lifecycle boundary: the turn either
        // completed or paused for operator input. Waiting still dominates the
        // card while unread; once the operator opens it, the underlying state
        // must settle to idle instead of snapping back to the outer shell's
        // misleading long-running-TUI "working" state.
        if let surfaceId {
            SurfaceLivenessDeriver.onAgentLifecycleChanged(
                surfaceId: surfaceId,
                workspaceId: tabId,
                activity: .idle
            )
        }

        if WorkspaceAutoReorderSettings.isEnabled() {
            AppDelegate.shared?.tabManager?.moveTabToTopForNotification(tabId)
        }

        let notification = TerminalNotification(
            id: UUID(),
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(),
            isRead: false
        )
        updated.insert(notification, at: 0)
        notifications = updated
        if !idsToClear.isEmpty {
            center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
        if !shouldSuppressExternalDelivery {
            notificationDeliveryHandler(self, notification)
        }
    }

    /// Direct flag delivery intentionally does not append to `notifications`.
    /// Operator decision: this path pierces suppression; routine delivery above
    /// remains barred for every suppressed surface.
    func deliverFlagNotification(
        workspaceId: UUID,
        surfaceId: UUID,
        flagRaisedAt: Date,
        title: String?,
        reason: String
    ) {
        let fallback = String(
            localized: "notification.flaggedAgent.title",
            defaultValue: "Flagged agent"
        )
        let normalizedTitle: String? = {
            guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }()
        let identifier = Self.flagNotificationIdentifier(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flagRaisedAt: flagRaisedAt
        )
        let token = DirectFlagDeliveryToken(identifier: identifier, generation: UUID())
        directFlagDeliveryTokens[identifier] = token
        let notification = TerminalNotification(
            id: UUID(),
            systemIdentifier: identifier,
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: normalizedTitle ?? fallback,
            subtitle: "",
            body: reason,
            createdAt: Date(),
            isRead: true
        )
        let add = { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            self.scheduleDirectFlagNotification(notification, token: token)
        }
#if DEBUG
        if let replacement = flagNotificationReplacementHandlerForTesting {
            replacement(identifier, add)
            return
        }
#endif
        // `UNUserNotificationCenter.add` replaces pending requests sharing an
        // identifier, but an already-delivered alert is not a pending request.
        // Serialize removal before scheduling the revised active epoch.
        center?.replaceNotificationOffMain(
            withIdentifier: identifier,
            add: add
        )
    }

    static func flagNotificationIdentifier(
        workspaceId: UUID,
        surfaceId: UUID,
        flagRaisedAt: Date
    ) -> String {
        let epochBits = flagRaisedAt.timeIntervalSince1970.bitPattern
        return [
            "com.stage11.c11.flag",
            workspaceId.uuidString.lowercased(),
            surfaceId.uuidString.lowercased(),
            String(epochBits, radix: 16),
        ].joined(separator: ".")
    }

    func cancelFlagNotification(
        workspaceId: UUID,
        surfaceId: UUID,
        flagRaisedAt: Date
    ) {
        let identifier = Self.flagNotificationIdentifier(
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            flagRaisedAt: flagRaisedAt
        )
        // Invalidate before cancellation so a delayed authorization or add
        // completion cannot resurrect delivery after lower/close/prune.
        directFlagDeliveryTokens.removeValue(forKey: identifier)
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: [identifier])
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: [identifier])
    }

    func cancelRoutineExternalNotifications(workspaceId: UUID, surfaceId: UUID) {
        let identifiers = notifications.compactMap { notification in
            notification.tabId == workspaceId && notification.surfaceId == surfaceId
                ? notification.id.uuidString
                : nil
        }
        guard !identifiers.isEmpty else { return }
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: identifiers)
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: identifiers)
    }

    func markRead(id: UUID) {
        var updated = notifications
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        guard !updated[index].isRead else { return }
        updated[index].isRead = true
        notifications = updated
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
    }

    func markRead(forTabId tabId: UUID) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId && !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markRead(forTabId tabId: UUID, surfaceId: UUID?) {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if updated[index].tabId == tabId,
               updated[index].surfaceId == surfaceId,
               !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func markUnread(forTabId tabId: UUID) {
        var updated = notifications
        var didChange = false
        for index in updated.indices {
            if updated[index].tabId == tabId, updated[index].isRead {
                updated[index].isRead = false
                didChange = true
            }
        }
        if didChange {
            notifications = updated
        }
    }

    func markAllRead() {
        var updated = notifications
        var idsToClear: [String] = []
        for index in updated.indices {
            if !updated[index].isRead {
                updated[index].isRead = true
                idsToClear.append(updated[index].id.uuidString)
            }
        }
        if !idsToClear.isEmpty {
            notifications = updated
            center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
            center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
        }
    }

    func remove(id: UUID) {
        var updated = notifications
        let originalCount = updated.count
        updated.removeAll { $0.id == id }
        guard updated.count != originalCount else { return }
        notifications = updated
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: [id.uuidString])
    }

    func clearAll() {
        guard !notifications.isEmpty else { return }
        let ids = notifications.map { $0.id.uuidString }
        notifications.removeAll()
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: ids)
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: ids)
    }

    func clearNotifications(forTabId tabId: UUID, surfaceId: UUID?) {
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId, notification.surfaceId == surfaceId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    func clearNotifications(forTabId tabId: UUID) {
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId {
                idsToClear.append(notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    /// Remove raw history for surfaces no longer present in a workspace.
    /// Surface-less workspace notifications remain valid and are retained.
    func clearNotifications(forTabId tabId: UUID, excludingSurfaceIds validSurfaceIds: Set<UUID>) {
        var updated: [TerminalNotification] = []
        updated.reserveCapacity(notifications.count)
        var idsToClear: [String] = []
        for notification in notifications {
            if notification.tabId == tabId,
               let surfaceId = notification.surfaceId,
               !validSurfaceIds.contains(surfaceId) {
                idsToClear.append(notification.systemIdentifier ?? notification.id.uuidString)
            } else {
                updated.append(notification)
            }
        }
        guard !idsToClear.isEmpty else { return }
        notifications = updated
        center?.removeDeliveredNotificationsOffMain(withIdentifiers: idsToClear)
        center?.removePendingNotificationRequestsOffMain(withIdentifiers: idsToClear)
    }

    private func scheduleUserNotification(_ notification: TerminalNotification) {
        ensureAuthorization(origin: .notificationDelivery) { [weak self] authorized in
            guard let self, authorized, let center = self.center else { return }

            let content = UNMutableNotificationContent()
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "cmux"
            content.title = notification.title.isEmpty ? appName : notification.title
            content.subtitle = notification.subtitle
            content.body = notification.body
            content.sound = NotificationSoundSettings.sound()
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = [
                "tabId": notification.tabId.uuidString,
                "notificationId": notification.id.uuidString,
            ]
            if let surfaceId = notification.surfaceId {
                content.userInfo["surfaceId"] = surfaceId.uuidString
            }

            let request = UNNotificationRequest(
                identifier: notification.systemIdentifier ?? notification.id.uuidString,
                content: content,
                trigger: nil
            )

            center.add(request) { error in
                if let error {
                    NSLog("Failed to schedule notification: \(error)")
                } else {
                    NotificationSoundSettings.runCustomCommand(
                        title: content.title,
                        subtitle: content.subtitle,
                        body: content.body
                    )
                }
            }
        }
    }

    /// Direct flag delivery has a separate generation guard from routine
    /// notifications. Authorization can resume long after the flag changed;
    /// both that boundary and the add completion must observe the same current
    /// generation before producing an external side effect.
    private func scheduleDirectFlagNotification(
        _ notification: TerminalNotification,
        token: DirectFlagDeliveryToken
    ) {
        guard isCurrent(token) else { return }
        requestDirectFlagAuthorization { [weak self] authorized in
            guard let self, authorized, self.isCurrent(token) else { return }
            self.addDirectFlagNotification(notification) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        NSLog("Failed to schedule direct flag notification: \(error)")
                        return
                    }
                    // Never remove here: an old same-identifier completion may
                    // arrive after a newer revision has already been added.
                    guard self.isCurrent(token) else { return }
                    self.runDirectFlagCustomCommand(notification)
                }
            }
        }
    }

    private func isCurrent(_ token: DirectFlagDeliveryToken) -> Bool {
        directFlagDeliveryTokens[token.identifier] == token
    }

    private func requestDirectFlagAuthorization(
        _ completion: @escaping (Bool) -> Void
    ) {
#if DEBUG
        if let handler = directFlagAuthorizationHandlerForTesting {
            handler(completion)
            return
        }
#endif
        ensureAuthorization(origin: .notificationDelivery, completion)
    }

    private func addDirectFlagNotification(
        _ notification: TerminalNotification,
        completion: @escaping (Error?) -> Void
    ) {
#if DEBUG
        if let handler = directFlagAddHandlerForTesting {
            handler(notification, completion)
            return
        }
#endif
        guard let center else {
            completion(
                NSError(
                    domain: "com.stage11.c11.notifications",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "System notification center unavailable"]
                )
            )
            return
        }
        let content = UNMutableNotificationContent()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "cmux"
        content.title = notification.title.isEmpty ? appName : notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = NotificationSoundSettings.sound()
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [
            "tabId": notification.tabId.uuidString,
            "notificationId": notification.id.uuidString,
        ]
        if let surfaceId = notification.surfaceId {
            content.userInfo["surfaceId"] = surfaceId.uuidString
        }
        let request = UNNotificationRequest(
            identifier: notification.systemIdentifier ?? notification.id.uuidString,
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: completion)
    }

    private func runDirectFlagCustomCommand(_ notification: TerminalNotification) {
#if DEBUG
        if let handler = directFlagCustomCommandHandlerForTesting {
            handler(notification)
            return
        }
#endif
        NotificationSoundSettings.runCustomCommand(
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body
        )
    }

    private func ensureAuthorization(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        logAuthorization("ensure start origin=\(origin.rawValue)")
        guard let center else {
            completion(false)
            return
        }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                self.authorizationState = Self.authorizationState(from: settings.authorizationStatus)
                self.logAuthorization(
                    "ensure status origin=\(origin.rawValue) status=\(Self.authorizationStatusLabel(settings.authorizationStatus)) mapped=\(self.authorizationState.statusLabel) appActive=\(AppFocusState.isAppActive())"
                )
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    completion(true)
                case .denied:
                    self.logAuthorization("ensure denied origin=\(origin.rawValue) prompting_settings")
                    self.promptToEnableNotifications()
                    completion(false)
                case .notDetermined:
                    if Self.shouldDeferAutomaticAuthorizationRequest(
                        origin: origin,
                        status: settings.authorizationStatus,
                        isAppActive: AppFocusState.isAppActive()
                    ) {
                        self.logAuthorization("ensure deferred origin=\(origin.rawValue)")
                        self.hasDeferredAuthorizationRequest = true
                        completion(false)
                    } else {
                        self.requestAuthorizationIfNeeded(origin: origin, completion)
                    }
                @unknown default:
                    self.logAuthorization("ensure unknown status origin=\(origin.rawValue)")
                    completion(false)
                }
            }
        }
    }

    private func requestAuthorizationIfNeeded(
        origin: AuthorizationRequestOrigin,
        _ completion: @escaping (Bool) -> Void
    ) {
        guard let center else {
            completion(false)
            return
        }
        let isAutomaticRequest = origin == .notificationDelivery
        guard Self.shouldRequestAuthorization(
            isAutomaticRequest: isAutomaticRequest,
            hasRequestedAutomaticAuthorization: hasRequestedAutomaticAuthorization
        ) else {
            logAuthorization(
                "request blocked origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
            )
            completion(false)
            return
        }
        if isAutomaticRequest {
            hasRequestedAutomaticAuthorization = true
        }
        hasDeferredAuthorizationRequest = false
        logAuthorization(
            "request starting origin=\(origin.rawValue) automatic=\(isAutomaticRequest) hasRequestedAutomatic=\(hasRequestedAutomaticAuthorization)"
        )
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if granted {
                    self.authorizationState = .authorized
                } else {
                    self.refreshAuthorizationStatus()
                }
                self.logAuthorization(
                    "request callback origin=\(origin.rawValue) granted=\(granted) error=\(error?.localizedDescription ?? "nil") mapped=\(self.authorizationState.statusLabel)"
                )
                completion(granted)
            }
        }
    }

    private func promptToEnableNotifications() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasPromptedForSettings else { return }
            self.logAuthorization("prompt settings shown")
            self.hasPromptedForSettings = true
            self.presentNotificationSettingsPrompt(attempt: 0)
        }
    }

    private func presentNotificationSettingsPrompt(attempt: Int) {
        guard let window = notificationSettingsWindowProvider() else {
            guard attempt < settingsPromptWindowRetryLimit else {
                // If no window is available after retries, allow a future denied callback
                // to prompt again when the app has a key/main window.
                hasPromptedForSettings = false
                return
            }
            notificationSettingsScheduler(settingsPromptWindowRetryDelay) { [weak self] in
                self?.presentNotificationSettingsPrompt(attempt: attempt + 1)
            }
            return
        }

        let alert = notificationSettingsAlertFactory()
        alert.messageText = String(localized: "dialog.enableNotifications.title", defaultValue: "Enable Notifications for c11")
        alert.informativeText = String(localized: "dialog.enableNotifications.message", defaultValue: "Notifications are off for c11. Enable them in System Settings so c11 can ring you when a pane needs attention.")
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.openSettings", defaultValue: "Open Settings"))
        alert.addButton(withTitle: String(localized: "dialog.enableNotifications.notNow", defaultValue: "Not Now"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            self?.openNotificationSettings()
        }
    }

    static func authorizationState(from status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    static func shouldDeferAutomaticAuthorizationRequest(
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        status == .notDetermined && !isAppActive
    }

    static func shouldRequestAuthorization(
        isAutomaticRequest: Bool,
        hasRequestedAutomaticAuthorization: Bool
    ) -> Bool {
        guard isAutomaticRequest else { return true }
        return !hasRequestedAutomaticAuthorization
    }

    private static func shouldDeferAutomaticAuthorizationRequest(
        origin: AuthorizationRequestOrigin,
        status: UNAuthorizationStatus,
        isAppActive: Bool
    ) -> Bool {
        guard origin == .notificationDelivery else { return false }
        return shouldDeferAutomaticAuthorizationRequest(status: status, isAppActive: isAppActive)
    }

    private static func isSignalEligible(_ notification: TerminalNotification) -> Bool {
        guard let surfaceId = notification.surfaceId else { return true }
        return SurfaceAttentionIndex.shared.snapshot(
            workspaceId: notification.tabId,
            surfaceId: surfaceId
        ).isSignalEligible
    }

    static func buildIndexes(
        for notifications: [TerminalNotification],
        signalEligible: (TerminalNotification) -> Bool
    ) -> NotificationIndexes {
        var indexes = NotificationIndexes()
        for notification in notifications {
            if indexes.latestByTabId[notification.tabId] == nil {
                indexes.latestByTabId[notification.tabId] = notification
            }
            guard !notification.isRead else { continue }
            indexes.rawUnreadCount += 1
            indexes.rawUnreadCountByTabId[notification.tabId, default: 0] += 1
            indexes.rawUnreadByTabSurface.insert(
                TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            )
            guard signalEligible(notification) else { continue }
            indexes.unreadCount += 1
            indexes.unreadCountByTabId[notification.tabId, default: 0] += 1
            indexes.unreadByTabSurface.insert(
                TabSurfaceKey(tabId: notification.tabId, surfaceId: notification.surfaceId)
            )
            if indexes.latestUnreadByTabId[notification.tabId] == nil {
                indexes.latestUnreadByTabId[notification.tabId] = notification
            }
        }
        return indexes
    }

#if DEBUG
    func configureNotificationSettingsPromptHooksForTesting(
        windowProvider: @escaping () -> NSWindow?,
        alertFactory: @escaping () -> NSAlert,
        scheduler: @escaping (_ delay: TimeInterval, _ block: @escaping () -> Void) -> Void,
        urlOpener: @escaping (URL) -> Void
    ) {
        notificationSettingsWindowProvider = windowProvider
        notificationSettingsAlertFactory = alertFactory
        notificationSettingsScheduler = scheduler
        notificationSettingsURLOpener = urlOpener
        hasPromptedForSettings = false
    }

    func resetNotificationSettingsPromptHooksForTesting() {
        notificationSettingsWindowProvider = { NSApp.keyWindow ?? NSApp.mainWindow }
        notificationSettingsAlertFactory = { NSAlert() }
        notificationSettingsScheduler = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                block()
            }
        }
        notificationSettingsURLOpener = { url in
            NSWorkspace.shared.open(url)
        }
        hasPromptedForSettings = false
    }

    func configureNotificationDeliveryHandlerForTesting(
        _ handler: @escaping (TerminalNotificationStore, TerminalNotification) -> Void
    ) {
        notificationDeliveryHandler = handler
    }

    func resetNotificationDeliveryHandlerForTesting() {
        notificationDeliveryHandler = { store, notification in
            store.scheduleUserNotification(notification)
        }
    }

    func configureWaitingEdgeHandlerForTesting(_ handler: @escaping (Bool, UUID) -> Void) {
        waitingEdgeHandlerForTesting = handler
    }

    func resetWaitingEdgeHandlerForTesting() {
        waitingEdgeHandlerForTesting = nil
    }

    func configureFlagNotificationReplacementHandlerForTesting(
        _ handler: @escaping (
            _ identifier: String,
            _ add: @escaping @MainActor () -> Void
        ) -> Void
    ) {
        flagNotificationReplacementHandlerForTesting = handler
    }

    func resetFlagNotificationReplacementHandlerForTesting() {
        flagNotificationReplacementHandlerForTesting = nil
    }

    func configureDirectFlagAuthorizationHandlerForTesting(
        _ handler: @escaping (_ completion: @escaping (Bool) -> Void) -> Void
    ) {
        directFlagAuthorizationHandlerForTesting = handler
    }

    func configureDirectFlagAddHandlerForTesting(
        _ handler: @escaping (
            _ notification: TerminalNotification,
            _ completion: @escaping (Error?) -> Void
        ) -> Void
    ) {
        directFlagAddHandlerForTesting = handler
    }

    func configureDirectFlagCustomCommandHandlerForTesting(
        _ handler: @escaping (_ notification: TerminalNotification) -> Void
    ) {
        directFlagCustomCommandHandlerForTesting = handler
    }

    func resetDirectFlagDeliveryHandlersForTesting() {
        directFlagAuthorizationHandlerForTesting = nil
        directFlagAddHandlerForTesting = nil
        directFlagCustomCommandHandlerForTesting = nil
    }

    func promptToEnableNotificationsForTesting() {
        promptToEnableNotifications()
    }

    func replaceNotificationsForTesting(_ notifications: [TerminalNotification]) {
        self.notifications = notifications
    }
#endif

}
