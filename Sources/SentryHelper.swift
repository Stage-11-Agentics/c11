import Sentry
import MetricKit
import Foundation

/// Captures Apple's MXDiagnosticPayload (crashes, hangs, CPU exceptions, disk-write
/// exceptions) and persists each payload as JSON in ~/Library/Logs/c11/metrickit/.
/// Complements Sentry: surfaces OS-level terminations Sentry cannot see —
/// SIGKILL, jetsam, force-quit, watchdog kills, and clean exits where no
/// CrashReporter .ips file is written.
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnostics()

    private let logDir: URL = {
        let base = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/c11/metrickit", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    @MainActor
    func install() {
        MXMetricManager.shared.add(self)
    }

    // `MXMetricPayload` is marked unavailable on macOS in the macOS 15.5
    // SDK (Xcode 16.4 — what `macos-15-xlarge` GitHub runners default to).
    // Apple made it macOS-available in the macOS 26 SDK (Xcode 26.x), so
    // gate the override on the Swift toolchain version: 6.2 ships with
    // Xcode 26 alongside the new SDK, while Xcode 16.4 stays on 6.1. When
    // CI catches up to Xcode 26 the gate becomes a no-op and the override
    // re-engages automatically.
    #if compiler(>=6.2)
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            persist(payload.jsonRepresentation(), kind: "metric", timestamp: payload.timeStampEnd)
        }
    }
    #endif

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let label = payloadLabel(payload)
            persist(payload.jsonRepresentation(), kind: label, timestamp: payload.timeStampEnd)
            forwardBreadcrumb(payload, label: label)
        }
    }

    private nonisolated func payloadLabel(_ payload: MXDiagnosticPayload) -> String {
        var parts: [String] = []
        if let count = payload.crashDiagnostics?.count, count > 0 { parts.append("crash\(count)") }
        if let count = payload.hangDiagnostics?.count, count > 0 { parts.append("hang\(count)") }
        if let count = payload.cpuExceptionDiagnostics?.count, count > 0 { parts.append("cpu\(count)") }
        if let count = payload.diskWriteExceptionDiagnostics?.count, count > 0 { parts.append("disk\(count)") }
        return parts.isEmpty ? "diagnostic" : parts.joined(separator: "-")
    }

    private nonisolated func persist(_ data: Data, kind: String, timestamp: Date) {
        let stamp = Self.timestampFormatter.string(from: timestamp)
            .replacingOccurrences(of: ":", with: "-")
        let url = logDir.appendingPathComponent("\(stamp)-\(kind).json")
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated func forwardBreadcrumb(_ payload: MXDiagnosticPayload, label: String) {
        guard TelemetrySettings.enabledForCurrentLaunch else { return }
        let crumb = Breadcrumb(level: .warning, category: "metrickit")
        crumb.message = "MXDiagnosticPayload received: \(label)"
        crumb.data = [
            "timeStampBegin": Self.timestampFormatter.string(from: payload.timeStampBegin),
            "timeStampEnd": Self.timestampFormatter.string(from: payload.timeStampEnd),
        ]
        SentrySDK.addBreadcrumb(crumb)
    }
}

// MARK: - Outbound event budget

/// Pure sliding-window counter with an injected clock, so the budget policy can
/// be unit-tested without threads or a wall clock.
///
/// Timestamps are recorded monotonically (callers pass `systemUptime`), so the
/// window can be pruned from the front.
struct SlidingWindowCounter {
    let limit: Int
    let windowSeconds: Double

    private var stamps: [Double] = []

    init(limit: Int, windowSeconds: Double) {
        self.limit = limit
        self.windowSeconds = windowSeconds
    }

    /// True when another event fits in the window. Prunes expired stamps.
    mutating func hasCapacity(now: Double) -> Bool {
        let cutoff = now - windowSeconds
        if let first = stamps.firstIndex(where: { $0 > cutoff }) {
            if first > 0 { stamps.removeFirst(first) }
        } else {
            stamps.removeAll(keepingCapacity: true)
        }
        return stamps.count < limit
    }

    mutating func record(now: Double) { stamps.append(now) }

    /// Test-only introspection.
    var count: Int { stamps.count }
}

/// The `category` tag hang reports carry. `beforeSend` reads it to charge a hang
/// against the hang sub-budget rather than the general allowance.
let sentryHangCategory = "hang"

/// Client-side ceiling on what this process sends to Sentry.
///
/// The org's error quota is shared across every Stage 11 project and there are
/// no server-side per-key rate limits on this plan, so a single wedged install
/// looping on one issue can blind every other project. This budget is the only
/// fence. Crashes are exempt: they are rare, they are the reason the SDK is
/// here, and losing one to a noisy neighbour is the failure mode we are fixing.
struct SentryEventBudget {
    enum Kind {
        /// Fatal / unhandled. Never throttled.
        case crash
        /// Main-thread hang reports — historically ~98% of c11's event volume.
        case hang
        /// Everything else (captured warnings and handled errors).
        case other

        /// Classify an outbound event from the only two facts `beforeSend` has.
        ///
        /// The budget is consulted in exactly one place — `beforeSend` — because
        /// it is the single egress every event passes through. A second gate on
        /// the producing side would charge the same event twice against the
        /// global ceiling, which silently shrinks the allowance for everything
        /// else in proportion to how much the app is hanging.
        static func classify(isFatal: Bool, categoryTag: String?) -> Kind {
            if isFatal { return .crash }
            if categoryTag == sentryHangCategory { return .hang }
            return .other
        }
    }

    private var globalHourly: SlidingWindowCounter
    private var globalDaily: SlidingWindowCounter
    private var hangHourly: SlidingWindowCounter
    private var hangDaily: SlidingWindowCounter

    private(set) var droppedTotal = 0
    private(set) var droppedHangs = 0

    init(
        globalPerHour: Int = 20,
        globalPerDay: Int = 50,
        hangsPerHour: Int = 3,
        hangsPerDay: Int = 15
    ) {
        globalHourly = SlidingWindowCounter(limit: globalPerHour, windowSeconds: 3600)
        globalDaily = SlidingWindowCounter(limit: globalPerDay, windowSeconds: 86_400)
        hangHourly = SlidingWindowCounter(limit: hangsPerHour, windowSeconds: 3600)
        hangDaily = SlidingWindowCounter(limit: hangsPerDay, windowSeconds: 86_400)
    }

    /// Decide whether one event may be sent, consuming budget only when it may.
    mutating func allow(_ kind: Kind, now: Double) -> Bool {
        guard kind != .crash else { return true }

        if kind == .hang {
            guard hangHourly.hasCapacity(now: now), hangDaily.hasCapacity(now: now) else {
                droppedHangs += 1
                droppedTotal += 1
                return false
            }
        }

        guard globalHourly.hasCapacity(now: now), globalDaily.hasCapacity(now: now) else {
            droppedTotal += 1
            return false
        }

        if kind == .hang {
            hangHourly.record(now: now)
            hangDaily.record(now: now)
        }
        globalHourly.record(now: now)
        globalDaily.record(now: now)
        return true
    }
}

/// Process-wide, thread-safe holder for `SentryEventBudget`. Consulted from
/// `beforeSend` (any thread the SDK dispatches on) and from the hang watchdog
/// thread.
final class SentryEventBudgetGate: @unchecked Sendable {
    static let shared = SentryEventBudgetGate()

    private let lock = NSLock()
    private var budget = SentryEventBudget()

    func allow(_ kind: SentryEventBudget.Kind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return budget.allow(kind, now: ProcessInfo.processInfo.systemUptime)
    }

    /// Counts of events this process suppressed, for the local hang log.
    var dropped: (total: Int, hangs: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (budget.droppedTotal, budget.droppedHangs)
    }
}

/// Add a Sentry breadcrumb for user-action context in hang/crash reports.
func sentryBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {
    guard TelemetrySettings.enabledForCurrentLaunch else { return }
    let crumb = Breadcrumb(level: .info, category: category)
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
}

/// Sentry caps tag values; anything longer is rejected outright rather than
/// truncated, which would silently drop the tag we most want to facet on.
private let sentryTagValueLimit = 190

private func sentryCaptureMessage(
    _ message: String,
    level: SentryLevel,
    category: String,
    data: [String: Any]?,
    contextKey: String?,
    fingerprint: [String]?,
    tags: [String: String]?
) {
    guard TelemetrySettings.enabledForCurrentLaunch else { return }
    _ = SentrySDK.capture(message: message) { scope in
        scope.setLevel(level)
        scope.setTag(value: category, key: "category")
        if let data {
            scope.setContext(value: data, key: contextKey ?? category)
        }
        // Without an explicit fingerprint Sentry groups a message event by the
        // stack of the thread that captured it. For anything reported from a
        // dedicated worker (the hang watchdog) that stack is identical every
        // time, so unrelated events pile into one issue.
        if let fingerprint, !fingerprint.isEmpty {
            scope.setFingerprint(fingerprint)
        }
        for (key, value) in tags ?? [:] where !value.isEmpty {
            scope.setTag(value: String(value.prefix(sentryTagValueLimit)), key: key)
        }
    }
}

func sentryCaptureWarning(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil,
    fingerprint: [String]? = nil,
    tags: [String: String]? = nil
) {
    sentryCaptureMessage(
        message,
        level: .warning,
        category: category,
        data: data,
        contextKey: contextKey,
        fingerprint: fingerprint,
        tags: tags
    )
}

/// Report a main-thread hang as a structured event carrying the **wedged main
/// thread** as its stacktrace.
///
/// The watchdog reports from its own thread, so an ordinary `capture(message:)`
/// hands Sentry the watchdog's loop as the thread of interest: the stack panel
/// shows the reporter rather than the wedge, and the captured stack survives
/// only as a text blob in context. Synthesizing the threads payload puts the
/// real stack where Sentry expects one — rendered, symbolicated server-side
/// against the uploaded dSYMs, and reachable by server-side fingerprint rules.
///
/// Grouping stays on the explicit `fingerprint`. Handing Sentry's own grouper
/// these stacks would shatter one cause across hundreds of issues, because each
/// capture is a single sample of a moving thread — measured on 875 real reports:
/// 645 groups, 607 of them singletons.
func sentryCaptureMainThreadHang(
    _ message: String,
    data: [String: Any],
    fingerprint: [String],
    tags: [String: String],
    frames: [MainThreadBacktrace.Frame],
    threadId: UInt64
) {
    guard TelemetrySettings.enabledForCurrentLaunch else { return }

    let event = Event(level: .warning)
    event.message = SentryMessage(formatted: message)
    event.fingerprint = fingerprint
    event.context = ["hang": data]

    var allTags = tags
    // `beforeSend` reads this tag to charge the event against the hang
    // sub-budget rather than the general allowance. Losing it would let a
    // wedged install spend the whole org's quota.
    allTags["category"] = sentryHangCategory
    event.tags = allTags.compactMapValues { value in
        value.isEmpty ? nil : String(value.prefix(sentryTagValueLimit))
    }

    if !frames.isEmpty {
        let thread = SentryThread(threadId: NSNumber(value: threadId))
        thread.isMain = true
        // `current` is what Sentry renders as the thread of interest. Nothing
        // crashed, so `crashed` stays false — this is a live, recovered process.
        thread.current = true
        thread.crashed = false
        thread.name = "main"
        // Sentry orders frames caller-to-callee (oldest first); the unwinder
        // produces them leaf-first. Reversing is not cosmetic — get it wrong and
        // every stack renders upside down.
        thread.stacktrace = SentryStacktrace(
            frames: frames.reversed().map { frame in
                let out = Frame()
                out.instructionAddress = String(format: "0x%016llx", UInt64(frame.instructionAddress))
                if let imageAddress = frame.imageAddress {
                    out.imageAddress = String(format: "0x%016llx", UInt64(imageAddress))
                }
                return out
            },
            registers: [:]
        )
        event.threads = [thread]
    }

    // The SDK leaves a caller-supplied `threads` alone and derives `debugMeta`
    // from it, so the frames above are what gets symbolicated. That is also why
    // every frame carries `imageAddress`: the debug-image list is built purely
    // from those values.
    SentrySDK.capture(event: event)
}

func sentryCaptureError(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil,
    fingerprint: [String]? = nil,
    tags: [String: String]? = nil
) {
    sentryCaptureMessage(
        message,
        level: .error,
        category: category,
        data: data,
        contextKey: contextKey,
        fingerprint: fingerprint,
        tags: tags
    )
}

/// Telemetry-independent launch sentinel. Catches Force Quit, SIGKILL, jetsam,
/// and other signal-bypass terminations that Sentry's in-process crash handler
/// can't see and that don't always produce an Apple `.ips` file. Persists a JSON
/// record of every launch under `~/Library/Caches/<bundle-id>/sessions/` and
/// archives the previous launch's marker as `unclean-exit-<ts>.json` if
/// `applicationWillTerminate` did not run. Runs regardless of telemetry consent
/// because the file never leaves the machine.
enum LaunchSentinel {
    static func recordLaunchAndArchivePrevious() {
        let fm = FileManager.default
        let dir = sessionsDirectory()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let active = dir.appendingPathComponent("active.json")
        if fm.fileExists(atPath: active.path) {
            let archive = dir.appendingPathComponent("unclean-exit-\(filenameSafeISO(Date())).json")
            try? fm.moveItem(at: active, to: archive)
        }

        let info = Bundle.main.infoDictionary ?? [:]
        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle_id": Bundle.main.bundleIdentifier ?? "",
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
            "commit": info["C11Commit"] as? String ?? "",
            "launched_at": isoNow(),
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: active, options: .atomic)
        }
    }

    static func clearActive() {
        let active = sessionsDirectory().appendingPathComponent("active.json")
        try? FileManager.default.removeItem(at: active)
    }

    private static func sessionsDirectory() -> URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "com.stage11.c11"
        return cache
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    private static func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static func isoNow() -> String { isoFormatter().string(from: Date()) }

    private static func filenameSafeISO(_ date: Date) -> String {
        isoFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}
