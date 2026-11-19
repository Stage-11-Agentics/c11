import Foundation
import UserNotifications

/// C11H-246: a raised flag is the loudest notification c11 makes. Every
/// source (a local `raise-flag`, one relayed from another machine, a launch
/// watch, a launch-time flag) reaches the system through this one builder, so
/// content, sound, level and identifier rules cannot drift between hosts.
struct FlagNotificationSpec: Equatable {
    static let identifierPrefix = "com.stage11.c11.flag."
    static let threadIdentifier = "com.stage11.c11.flag"
    static let userInfoFlagKey = "flag"
    static let userInfoSoundKey = "flag_sound"
    static let userInfoSourceHostKey = "flag_source_host"
    static let userInfoKindKey = "flag_kind"

    let identifier: String
    let workspaceId: UUID
    let surfaceId: UUID
    let title: String
    let subtitle: String
    let body: String
    /// The sound's name as stored (`Hero`, `default`, `file:<id>`, ...), for the record.
    let soundValue: String
    /// C11H-319: the one sound this alert plays and where it came from.
    let sound: NotificationSoundResolution
    /// The flag kind's id, when the flag has one.
    let kindID: String?
    /// Where the raise came from (`local` or a machine). Not shown; carried in
    /// userInfo so a later launch can still attribute the alert it removes.
    let sourceHost: String

    static func make(
        workspaceId: UUID,
        surfaceId: UUID,
        flagRaisedAt: Date,
        title: String?,
        reason: String,
        kind: PanelFlagKind?,
        sourceHost: String = FlagNotificationAttribution.localSourceHost,
        defaults: UserDefaults = .standard,
        kindSound: NotificationSoundChoice? = nil,
        soundStore: CustomNotificationSoundStore = .shared
    ) -> FlagNotificationSpec {
        let fallback = String(
            localized: "notification.flaggedAgent.title",
            defaultValue: "Flagged agent"
        )
        let normalizedTitle: String? = {
            guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }()
        let sound = NotificationSoundResolver.flag(kindSound: kindSound, defaults: defaults, store: soundStore)
        return FlagNotificationSpec(
            identifier: identifier(workspaceId: workspaceId, surfaceId: surfaceId, flagRaisedAt: flagRaisedAt),
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            title: normalizedTitle ?? fallback,
            subtitle: kind?.displayLabel ?? "",
            body: reason,
            soundValue: sound.played.rawValue,
            sound: sound,
            kindID: kind?.id,
            sourceHost: sourceHost
        )
    }

    /// One identifier per flag epoch: a reason or kind change keeps the epoch
    /// and replaces the delivered alert; a lower and a fresh raise get a new one.
    static func identifier(workspaceId: UUID, surfaceId: UUID, flagRaisedAt: Date) -> String {
        let epochBits = flagRaisedAt.timeIntervalSince1970.bitPattern
        return identifierPrefix + [
            workspaceId.uuidString.lowercased(),
            surfaceId.uuidString.lowercased(),
            String(epochBits, radix: 16),
        ].joined(separator: ".")
    }

    static func isFlagIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }

    var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "tabId": workspaceId.uuidString,
            "notificationId": identifier,
            "panelId": surfaceId.uuidString,
            // C11-337: legacy spelling, still written and read forever.
            "surfaceId": surfaceId.uuidString,
            Self.userInfoFlagKey: true,
            Self.userInfoSoundKey: soundValue,
            Self.userInfoSourceHostKey: sourceHost,
        ]
        if let kindID { info[Self.userInfoKindKey] = kindID }
        return info
    }

    var attribution: FlagNotificationAttribution {
        FlagNotificationAttribution(
            workspaceId: workspaceId, surfaceId: surfaceId, sound: soundValue, sourceHost: sourceHost,
            kindID: kindID, soundDetail: sound
        )
    }

    /// The request every host's flag posts. `.timeSensitive` is requested in
    /// code; without the Time Sensitive entitlement (C11H-179) the system
    /// delivers it at `.active`, and a Focus mode lets it through only when
    /// c11 is in that Focus mode's Allowed Apps.
    func request(appName: String, categoryIdentifier: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? appName : title
        content.subtitle = subtitle
        content.body = body
        content.sound = sound.notificationSound
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 1
        content.threadIdentifier = Self.threadIdentifier
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}

/// Who a flag alert belongs to and how it sounded: kept per identifier while
/// it is up, and read back from a delivered alert's userInfo at launch.
struct FlagNotificationAttribution: Equatable {
    static let localSourceHost = "local"
    /// Stated, not omitted, when an alert from an older build carries none.
    static let unknown = "unknown"

    let workspaceId: UUID?
    let surfaceId: UUID?
    let sound: String
    let sourceHost: String
    /// C11H-319: the flag kind's id, when known.
    var kindID: String? = nil
    /// C11H-319: how the sound was chosen, for alerts this run posted.
    var soundDetail: NotificationSoundResolution? = nil

    /// Workspace and panel from the identifier itself; sound and host unknown.
    static func fromIdentifier(_ identifier: String) -> FlagNotificationAttribution {
        let parts = identifier.dropFirst(FlagNotificationSpec.identifierPrefix.count).split(separator: ".")
        return FlagNotificationAttribution(
            workspaceId: parts.count > 0 ? UUID(uuidString: String(parts[0])) : nil,
            surfaceId: parts.count > 1 ? UUID(uuidString: String(parts[1])) : nil,
            sound: unknown,
            sourceHost: unknown
        )
    }

    static func from(identifier: String, userInfo: [AnyHashable: Any]) -> FlagNotificationAttribution {
        let parsed = fromIdentifier(identifier)
        return FlagNotificationAttribution(
            workspaceId: (userInfo["tabId"] as? String).flatMap(UUID.init(uuidString:)) ?? parsed.workspaceId,
            surfaceId: (userInfo["panelId"] as? String).flatMap(UUID.init(uuidString:)) ?? parsed.surfaceId,
            sound: userInfo[FlagNotificationSpec.userInfoSoundKey] as? String ?? unknown,
            sourceHost: userInfo[FlagNotificationSpec.userInfoSourceHostKey] as? String ?? unknown,
            kindID: userInfo[FlagNotificationSpec.userInfoKindKey] as? String
        )
    }
}

/// The flag's own sound, set apart from the routine channels. C11H-319: it
/// may be an imported file, never "None": a flag always sounds. A flag kind
/// may override it (`PanelFlagKindRegistry.sound(id:)`).
enum FlagSoundSettings {
    static let key = NotificationSoundChannel.flag.defaultsKey
    static let defaultValue = NotificationSoundChannel.flag.shippedDefault.rawValue

    static func value(defaults: UserDefaults = .standard) -> String {
        NotificationSoundChannel.flag.choice(defaults: defaults).rawValue
    }
}

/// C11H-246: the dial for routine notifications (turn ends, asks, mail). It
/// never reaches a flag. The operator owns it: Settings, or
/// `c11 notify-level <stop>` when the operator asks.
enum NotificationLevel: String, CaseIterable, Sendable {
    /// Feed and sidebar only.
    case silent
    /// A banner with no sound.
    case quiet
    /// Turn ends and asks with the routine sound.
    case normal
    /// Normal, plus mail and delegate completions.
    case chatty

    static let key = "notificationLevel"
    static let defaultLevel: NotificationLevel = .normal

    static func current(defaults: UserDefaults = .standard) -> NotificationLevel {
        defaults.string(forKey: key).flatMap(NotificationLevel.init(rawValue:)) ?? defaultLevel
    }

    var displayLabel: String {
        switch self {
        case .silent: return String(localized: "notificationLevel.silent", defaultValue: "Silent")
        case .quiet: return String(localized: "notificationLevel.quiet", defaultValue: "Quiet")
        case .normal: return String(localized: "notificationLevel.normal", defaultValue: "Normal")
        case .chatty: return String(localized: "notificationLevel.chatty", defaultValue: "Chatty")
        }
    }

    var summary: String {
        switch self {
        case .silent:
            return String(localized: "notificationLevel.silent.summary", defaultValue: "Feed and sidebar only. Flags still sound.")
        case .quiet:
            return String(localized: "notificationLevel.quiet.summary", defaultValue: "Banners with no sound. Flags still sound.")
        case .normal:
            return String(localized: "notificationLevel.normal.summary", defaultValue: "Banners and sound for turn ends and asks.")
        case .chatty:
            return String(localized: "notificationLevel.chatty.summary", defaultValue: "Also mail and delegate completions.")
        }
    }
}

/// What a routine notification does at the system level. The store record
/// (Feed, sidebar, waiting edges) is kept at every stop.
enum RoutineDelivery: Equatable {
    case none
    case banner(sound: Bool)
}

enum RoutineDeliveryPolicy {
    /// - focusSuppressed: the operator is looking at that panel now.
    /// - attentionSuppressed: the panel is a delegate; its routine stops go to
    ///   its owner, except at Chatty.
    static func decide(
        level: NotificationLevel,
        focusSuppressed: Bool,
        attentionSuppressed: Bool
    ) -> RoutineDelivery {
        if focusSuppressed { return .none }
        if attentionSuppressed, level != .chatty { return .none }
        switch level {
        case .silent: return .none
        case .quiet: return .banner(sound: false)
        case .normal, .chatty: return .banner(sound: true)
        }
    }

    /// Mail banners exist only at Chatty.
    static func deliversMail(level: NotificationLevel) -> Bool {
        level == .chatty
    }
}

/// The one exception to a flag's system post: its own panel is the focused
/// panel of the key window and the operator is looking at it.
enum FlagPresentationPolicy {
    static func operatorIsLooking(
        isAppFocused: Bool,
        selectedWorkspaceId: UUID?,
        focusedSurfaceId: UUID?,
        workspaceId: UUID,
        surfaceId: UUID
    ) -> Bool {
        isAppFocused && selectedWorkspaceId == workspaceId && focusedSurfaceId == surfaceId
    }
}

/// C11H-246 #10: one agent-readable record per flag notification, as a
/// `notification.flag` event and one `notification.flag` log line.
struct FlagNotificationRecord: Equatable {
    enum Action: String {
        case posted
        case replaced
        case skippedOperatorLooking = "skipped_operator_looking"
        case removed
        case failed
    }

    enum Cause: String {
        case raised
        case revised
        case lowered
        /// C11H-330: the operator looked at the panel long enough.
        case evaporated
        case opened
        case closed
        case staleAtLaunch = "stale_at_launch"
    }

    let action: Action
    let cause: Cause
    let workspaceId: UUID?
    let surfaceId: UUID?
    let identifier: String
    /// The flag sound, or `unknown` for an alert an older build left.
    let sound: String
    /// The machine the raise came from, `local` for this Mac, or `unknown`.
    let sourceHost: String
    /// C11H-319: the flag kind's id, when known.
    let kindID: String?
    /// C11H-319: where the sound came from, and any fallback.
    let soundDetail: NotificationSoundResolution?

    init(action: Action, cause: Cause, identifier: String, attribution: FlagNotificationAttribution) {
        self.action = action
        self.cause = cause
        self.workspaceId = attribution.workspaceId
        self.surfaceId = attribution.surfaceId
        self.identifier = identifier
        self.sound = attribution.sound
        self.sourceHost = attribution.sourceHost
        self.kindID = attribution.kindID
        self.soundDetail = attribution.soundDetail
    }

    static let level = "time_sensitive"

    var payload: [String: Any] {
        var payload: [String: Any] = [
            "action": action.rawValue,
            "cause": cause.rawValue,
            "identifier": identifier,
            "level": Self.level,
            "sound": sound,
            "source_host": sourceHost,
        ]
        if let surfaceId { payload["panel"] = surfaceId.uuidString.lowercased() }
        if let kindID { payload["kind"] = kindID }
        soundDetail?.addFields(to: &payload)
        return payload
    }

    var logLine: String {
        var parts = [
            "notification.flag",
            "action=\(action.rawValue)",
            "cause=\(cause.rawValue)",
            "panel=\(surfaceId?.uuidString.lowercased() ?? "-")",
            "workspace=\(workspaceId?.uuidString.lowercased() ?? "-")",
            "level=\(Self.level)",
            soundDetail?.logFields ?? "sound=\(sound)",
            "source_host=\(sourceHost)",
        ]
        if let kindID { parts.append("kind=\(kindID)") }
        parts.append("identifier=\(identifier)")
        return parts.joined(separator: " ")
    }
}

/// C11H-246 #3: which delivered flag alerts survive a launch. A flag still
/// raised keeps its alert (and is never posted again); every other flag alert
/// is one a previous run could no longer clear, and goes.
struct FlagNotificationReconcilePlan: Equatable {
    let keep: [String]
    let remove: [String]

    static func make(delivered: [String], raised: Set<String>) -> FlagNotificationReconcilePlan {
        let flags = delivered.filter(FlagNotificationSpec.isFlagIdentifier)
        return FlagNotificationReconcilePlan(
            keep: flags.filter { raised.contains($0) },
            remove: flags.filter { !raised.contains($0) }
        )
    }
}
