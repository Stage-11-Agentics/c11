import Foundation
import Darwin

// Thin CLI entry for `c11 health`. Wired from CLI/c11.swift.
// All parsing, scanning, and rendering lives in Sources/HealthCommandCore.swift
// so the main `c11` target (and c11Tests) can exercise the same code paths.

/// The c11-cli target ships without an Info.plist, so `Bundle.main` is empty
/// when this binary runs standalone. To get the running c11 app's version
/// (needed by `metricKitBaselineWarning`), walk up from the executable's
/// path until an `.app` bundle is found. Mirrors `CLISocketSentryTelemetry`.
private func runningC11AppVersion() -> String? {
    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
       !v.isEmpty {
        return v
    }

    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    guard size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }

    var current = URL(fileURLWithPath: String(cString: buffer))
        .deletingLastPathComponent()
        .standardizedFileURL
    while current.path != "/" {
        if current.pathExtension == "app",
           let bundle = Bundle(url: current),
           let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.isEmpty {
            return v
        }
        current = current.deletingLastPathComponent().standardizedFileURL
    }
    return nil
}

func runHealth(commandArgs: [String], jsonOutput: Bool) throws {
    let opts: HealthCLIOptions
    do {
        opts = try parseHealthCLIArgs(commandArgs)
    } catch let error as HealthCLIError {
        throw CLIError(message: "c11 health: \(error.description)")
    }

    let wantsJSON = jsonOutput || opts.json
    let now = Date()
    let since: Date
    switch opts.mode {
    case .sinceDuration:
        since = now.addingTimeInterval(-opts.windowDuration)
    case .sinceBoot:
        since = bootTime()
    case .defaultLast24h:
        since = now.addingTimeInterval(-24 * 3600)
    }
    let window = HealthCollectionWindow(mode: opts.mode, since: since, until: now)

    let allRails: Set<HealthEvent.Rail> = Set(HealthEvent.Rail.allCases)
    let rails: Set<HealthEvent.Rail> = opts.railFilter.map { [$0] } ?? allRails

    let home = NSHomeDirectory()
    let events = collectHealthEvents(window: window, rails: rails, home: home)

    let metrickitCount = events.filter { $0.rail == .metrickit }.count
    let sentryCount = events.filter { $0.rail == .sentry }.count
    let bundleVersion = runningC11AppVersion()

    var warnings: [String] = []
    if rails.contains(.metrickit),
       let w = metricKitBaselineWarning(
        home: home,
        bundleVersion: bundleVersion,
        metricKitCount: metrickitCount
       ) {
        warnings.append(w)
    }
    if rails.contains(.sentry),
       let w = telemetryAmbiguityFooter(home: home, sentryCount: sentryCount) {
        warnings.append(w)
    }

    if wantsJSON {
        let data = try renderHealthJSON(
            events: events,
            window: window,
            rails: rails,
            warnings: warnings,
            home: home
        )
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }

    let railList = HealthEvent.Rail.allCases.filter { rails.contains($0) }
    print(renderHealthTable(events, warnings: warnings, rails: railList, window: window), terminator: "")
}
