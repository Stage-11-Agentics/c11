import AppKit
import Foundation
import PostHog

/// What `PostHogAnalytics` asks the SDK to set up. Kept SDK-free so tests can
/// observe a start without linking PostHog or creating a client.
struct PostHogSetupRequest {
    let apiKey: String
    let host: String
    let debug: Bool
    let superProperties: [String: Any]
}

final class PostHogAnalytics {
    static let shared = PostHogAnalytics()

    /// The only place the PostHog SDK is configured and its client created.
    static let setUpRealSDK: (PostHogSetupRequest) -> Void = { request in
        let config = PostHogConfig(apiKey: request.apiKey, host: request.host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.debug = request.debug
        PostHogSDK.shared.setup(config)

        // Tag every event so PostHog can distinguish desktop from web and
        // break events down by released app version/build.
        PostHogSDK.shared.register(request.superProperties)

        // The SDK automatically generates and persists an anonymous distinct ID.
    }

    // The PostHog project API key is intentionally embedded in the app (it's a public key).
    // Project: `stage11-c11` under the Stage 11 PostHog org (us.posthog.com).
    private let apiKey = "phc_DfsnweKfe5uHUDK2scRVddAjpX8xGkq5NZWANmZaKo97"

    // PostHog Cloud US default.
    private let host = "https://us.i.posthog.com"

    private let dailyActiveEvent = "c11_daily_active"
    private let hourlyActiveEvent = "c11_hourly_active"

    private let lastActiveDayUTCKey = "posthog.lastActiveDayUTC"
    private let lastActiveHourUTCKey = "posthog.lastActiveHourUTC"

    private let workQueue: DispatchQueue
    private let workQueueSpecificKey = DispatchSpecificKey<Void>()
    private let utcHourFormatter: DateFormatter
    private let utcDayFormatter: DateFormatter

    private var didStart = false
    private var activeCheckTimer: Timer?

    private let decision: TelemetryLaunchDecision
    private let environment: [String: String]
    private let setUpSDK: (PostHogSetupRequest) -> Void

    /// Tests pass a decision, an environment and a recording `setUpSDK`.
    init(
        decision: TelemetryLaunchDecision = TelemetrySettings.launchDecision,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        setUpSDK: @escaping (PostHogSetupRequest) -> Void = PostHogAnalytics.setUpRealSDK
    ) {
        self.decision = decision
        self.environment = environment
        self.setUpSDK = setUpSDK
        workQueue = DispatchQueue(label: "com.stage11.c11.posthog.analytics", qos: .utility)
        utcHourFormatter = Self.makeUTCFormatter("yyyy-MM-dd'T'HH")
        utcDayFormatter = Self.makeUTCFormatter("yyyy-MM-dd")
        workQueue.setSpecific(key: workQueueSpecificKey, value: ())
    }

    private var isEnabled: Bool {
        // C11-575: only a released identity with the user's consent.
        guard decision.isEnabled else { return false }
#if DEBUG
        // Avoid polluting production analytics while iterating locally.
        return environment["C11_POSTHOG_ENABLE"] == "1"
#else
        return !apiKey.isEmpty && apiKey != "REPLACE_WITH_POSTHOG_PUBLIC_KEY"
#endif
    }

    /// Whether the SDK was set up by this instance. Read on the work queue.
    var hasStarted: Bool {
        var started = false
        dispatchSyncOnWorkQueue { started = didStart }
        return started
    }

    func startIfNeeded() {
        dispatchAsyncOnWorkQueue { [weak self] in
            self?.startIfNeededOnWorkQueue()
        }
    }

    func trackActive(reason: String) {
        dispatchAsyncOnWorkQueue { [weak self] in
            guard let self else { return }

            let didCaptureDaily = self.trackDailyActiveOnWorkQueue(reason: reason, flush: false)
            let didCaptureHourly = self.trackHourlyActiveOnWorkQueue(reason: reason, flush: false)
            if didCaptureDaily || didCaptureHourly {
                // On app focus we can capture both events; flush once to reduce extra work.
                PostHogSDK.shared.flush()
            }
        }
    }

    func trackDailyActive(reason: String) {
        dispatchAsyncOnWorkQueue { [weak self] in
            self?.trackDailyActiveOnWorkQueue(reason: reason, flush: true)
        }
    }

    func trackHourlyActive(reason: String) {
        dispatchAsyncOnWorkQueue { [weak self] in
            self?.trackHourlyActiveOnWorkQueue(reason: reason, flush: true)
        }
    }

    func flush() {
        dispatchSyncOnWorkQueue {
            guard didStart else { return }
            PostHogSDK.shared.flush()
        }
    }

    /// Capture a main-thread hang detected by `MainThreadHangMonitor`. Self-gated
    /// on telemetry consent (`isEnabled`) and SDK start, like every other event.
    /// `cause` is the same signature label Sentry groups on, so the two surfaces
    /// can be read against each other — PostHog keeps the whole population
    /// (including the run-loop-idle episodes Sentry no longer hears about).
    func captureMainThreadHang(stalledMs: Double, recapture: Bool, topFrame: String, cause: String) {
        dispatchAsyncOnWorkQueue { [weak self] in
            guard let self, self.didStart, self.isEnabled else { return }
            PostHogSDK.shared.capture("c11_main_thread_hang", properties: [
                "stalled_ms": Int(stalledMs),
                "recapture": recapture,
                "top_frame": topFrame,
                "cause": cause,
            ])
        }
    }

    private func startIfNeededOnWorkQueue() {
        guard !didStart else { return }
        guard isEnabled, let channel = decision.channel else { return }

#if DEBUG
        let debug = environment["C11_POSTHOG_DEBUG"] == "1"
#else
        let debug = false
#endif
        var properties = Self.superProperties(infoDictionary: Bundle.main.infoDictionary ?? [:])
        properties.merge(channel.postHogSuperProperties) { _, new in new }
        setUpSDK(PostHogSetupRequest(apiKey: apiKey, host: host, debug: debug, superProperties: properties))

        didStart = true

        scheduleActiveCheckTimer()
    }

    private func scheduleActiveCheckTimer() {
        // If the app stays in the foreground across midnight, `applicationDidBecomeActive`
        // won't fire again, so a periodic check avoids undercounting those users.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeCheckTimer?.invalidate()
            self.activeCheckTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard NSApp.isActive else { return }
                self.trackActive(reason: "activeTimer")
            }
        }
    }

    @discardableResult
    private func trackDailyActiveOnWorkQueue(reason: String, flush: Bool) -> Bool {
        startIfNeededOnWorkQueue()
        guard didStart else { return false }

        let today = utcDayString(Date())
        let defaults = UserDefaults.standard
        if defaults.string(forKey: lastActiveDayUTCKey) == today {
            return false
        }

        defaults.set(today, forKey: lastActiveDayUTCKey)

        let event = dailyActiveEvent

        PostHogSDK.shared.capture(
            event,
            properties: Self.dailyActiveProperties(
                dayUTC: today,
                reason: reason,
                infoDictionary: Bundle.main.infoDictionary ?? [:]
            )
        )

        if flush && Self.shouldFlushAfterCapture(event: event) {
            // For active metrics we care more about delivery than batching.
            PostHogSDK.shared.flush()
        }

        return true
    }

    @discardableResult
    private func trackHourlyActiveOnWorkQueue(reason: String, flush: Bool) -> Bool {
        startIfNeededOnWorkQueue()
        guard didStart else { return false }

        let hour = utcHourString(Date())
        let defaults = UserDefaults.standard
        if defaults.string(forKey: lastActiveHourUTCKey) == hour {
            return false
        }

        defaults.set(hour, forKey: lastActiveHourUTCKey)

        let event = hourlyActiveEvent

        PostHogSDK.shared.capture(
            event,
            properties: Self.hourlyActiveProperties(
                hourUTC: hour,
                reason: reason,
                infoDictionary: Bundle.main.infoDictionary ?? [:]
            )
        )

        if flush && Self.shouldFlushAfterCapture(event: event) {
            // Keep hourly freshness and avoid losing a deduped hour on abrupt exits.
            PostHogSDK.shared.flush()
        }

        return true
    }

    private func dispatchAsyncOnWorkQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: workQueueSpecificKey) != nil {
            block()
            return
        }
        workQueue.async(execute: block)
    }

    private func dispatchSyncOnWorkQueue(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: workQueueSpecificKey) != nil {
            block()
            return
        }
        workQueue.sync(execute: block)
    }

    private func utcHourString(_ date: Date) -> String {
        utcHourFormatter.string(from: date)
    }

    private func utcDayString(_ date: Date) -> String {
        utcDayFormatter.string(from: date)
    }

    private static func makeUTCFormatter(_ dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = dateFormat
        return formatter
    }

    nonisolated static func superProperties(infoDictionary: [String: Any]) -> [String: Any] {
        var properties: [String: Any] = ["platform": "c11"]
        properties.merge(versionProperties(infoDictionary: infoDictionary)) { _, new in new }
        return properties
    }

    nonisolated static func dailyActiveProperties(
        dayUTC: String,
        reason: String,
        infoDictionary: [String: Any]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "day_utc": dayUTC,
            "reason": reason,
        ]
        properties.merge(versionProperties(infoDictionary: infoDictionary)) { _, new in new }
        return properties
    }

    nonisolated static func hourlyActiveProperties(
        hourUTC: String,
        reason: String,
        infoDictionary: [String: Any]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "hour_utc": hourUTC,
            "reason": reason,
        ]
        properties.merge(versionProperties(infoDictionary: infoDictionary)) { _, new in new }
        return properties
    }

    nonisolated static func shouldFlushAfterCapture(event: String) -> Bool {
        switch event {
        case "c11_daily_active", "c11_hourly_active":
            return true
        default:
            return false
        }
    }

    nonisolated private static func versionProperties(infoDictionary: [String: Any]) -> [String: Any] {
        var properties: [String: Any] = [:]
        if let value = infoDictionary["CFBundleShortVersionString"] as? String, !value.isEmpty {
            properties["app_version"] = value
        }
        if let value = infoDictionary["CFBundleVersion"] as? String, !value.isEmpty {
            properties["app_build"] = value
        }
        return properties
    }
}
