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

/// Add a Sentry breadcrumb for user-action context in hang/crash reports.
func sentryBreadcrumb(_ message: String, category: String = "ui", data: [String: Any]? = nil) {
    guard TelemetrySettings.enabledForCurrentLaunch else { return }
    let crumb = Breadcrumb(level: .info, category: category)
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
}

private func sentryCaptureMessage(
    _ message: String,
    level: SentryLevel,
    category: String,
    data: [String: Any]?,
    contextKey: String?
) {
    guard TelemetrySettings.enabledForCurrentLaunch else { return }
    _ = SentrySDK.capture(message: message) { scope in
        scope.setLevel(level)
        scope.setTag(value: category, key: "category")
        if let data {
            scope.setContext(value: data, key: contextKey ?? category)
        }
    }
}

func sentryCaptureWarning(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil
) {
    sentryCaptureMessage(message, level: .warning, category: category, data: data, contextKey: contextKey)
}

func sentryCaptureError(
    _ message: String,
    category: String = "ui",
    data: [String: Any]? = nil,
    contextKey: String? = nil
) {
    sentryCaptureMessage(message, level: .error, category: category, data: data, contextKey: contextKey)
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
