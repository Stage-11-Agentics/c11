import Foundation

// Core for `c11 health`. Pure, testable: no UI, no socket, no Sentry SDK calls.
// The CLI shim at CLI/HealthCommand.swift wires this into the `c11 health` dispatch.

struct HealthEvent {
    enum Rail: String, CaseIterable {
        case ips
        case sentry
        case metrickit
        case sentinel
    }

    enum Severity: String {
        case crash
        case queued
        case hang
        case resource
        case mixed
        case diagnostic
        case unclean_exit
    }

    let timestamp: Date
    let rail: Rail
    let severity: Severity
    let summary: String
    let path: String
}

/// Single source of truth for the ISO-8601 formatter c11 health uses to
/// stamp / parse timestamps. Hoisted to avoid the per-call allocation
/// previously duplicated across `parseFilenameSafeISO`,
/// `mostRecentSentinelMarker`, and `renderHealthJSON`.
@inline(__always)
private func makeFractionalISOFormatter() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}

struct HealthCollectionWindow {
    enum Mode: String {
        case sinceDuration = "since"
        case sinceBoot = "since-boot"
        case defaultLast24h = "default-24h"
    }

    let mode: Mode
    let since: Date
    let until: Date
}

/// Collect events across requested rails. Missing files or empty directories
/// must not produce an error: this command is read-only and has to be useful
/// on a machine where the producer code (sentinel, MetricKit subscription,
/// Sentry SDK) has never run.
///
/// `home` defaults to `NSHomeDirectory()` so the runtime test can pass a tmp dir.
func collectHealthEvents(
    window: HealthCollectionWindow,
    rails: Set<HealthEvent.Rail>,
    home: String = NSHomeDirectory()
) -> [HealthEvent] {
    var events: [HealthEvent] = []
    if rails.contains(.ips) {
        events.append(contentsOf: scanIPS(home: home, since: window.since))
    }
    if rails.contains(.sentry) {
        events.append(contentsOf: scanSentryQueued(home: home, since: window.since))
    }
    if rails.contains(.metrickit) {
        events.append(contentsOf: scanMetricKit(home: home, since: window.since))
    }
    if rails.contains(.sentinel) {
        events.append(contentsOf: scanLaunchSentinel(home: home, since: window.since))
    }
    // Stable secondary/tertiary keys keep `--json` output deterministic
    // when two events share a timestamp (sub-millisecond batches across
    // rails are common).
    return events.sorted { lhs, rhs in
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
        if lhs.rail.rawValue != rhs.rail.rawValue { return lhs.rail.rawValue < rhs.rail.rawValue }
        return lhs.path < rhs.path
    }
}

// MARK: - IPS rail

/// Apple's CrashReporter ".ips" files start with a single-line JSON header,
/// then a newline, then a JSON payload. We parse only that first line.
struct IPSHeader {
    let incidentID: String?
    let bundleID: String?
    let bugType: String?
    /// OS-reported crash time from the first-line JSON `timestamp` field
    /// (e.g. `"2026-05-03 15:19:00.000 -0400"`). Used in preference to file
    /// mtime so `--since` filters reflect when the crash actually happened
    /// rather than when CrashReporter finished writing the file.
    let timestamp: Date?
}

func parseIPSFirstLine(_ line: String) -> IPSHeader? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return IPSHeader(
        incidentID: obj["incident_id"] as? String,
        bundleID: obj["bundleID"] as? String,
        bugType: obj["bug_type"] as? String,
        timestamp: (obj["timestamp"] as? String).flatMap(parseIPSTimestamp)
    )
}

/// Parses an Apple CrashReporter timestamp string. Format example:
/// `"2026-05-03 15:19:00.000 -0400"` (space-separated date/time, fractional
/// seconds, RFC 822 timezone offset). Returns nil for missing or malformed
/// values; callers must fall back to file mtime.
func parseIPSTimestamp(_ raw: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
    return f.date(from: raw)
}

func scanIPS(home: String, since: Date) -> [HealthEvent] {
    let baseDir = "\(home)/Library/Logs/DiagnosticReports"
    let baseURL = URL(fileURLWithPath: baseDir)
    let fm = FileManager.default

    guard let topLevel = try? fm.contentsOfDirectory(
        at: baseURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var events: [HealthEvent] = []

    for entry in topLevel {
        let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let name = entry.lastPathComponent

        if isDir {
            guard name.hasPrefix("com.stage11.c11") else { continue }
            if let inside = try? fm.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for url in inside where url.pathExtension == "ips" {
                    if let ev = ipsEventIfRecent(at: url, since: since) {
                        events.append(ev)
                    }
                }
            }
            continue
        }

        guard entry.pathExtension == "ips" else { continue }
        let stem = entry.deletingPathExtension().lastPathComponent
        guard stem.lowercased().contains("c11") else { continue }
        if let ev = ipsEventIfRecent(at: entry, since: since) {
            events.append(ev)
        }
    }

    return events
}

private func ipsEventIfRecent(at url: URL, since: Date) -> HealthEvent? {
    let fm = FileManager.default
    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
          let mtime = attrs[.modificationDate] as? Date
    else { return nil }

    let summary: String
    let timestamp: Date
    if let line = readFirstLine(of: url), let header = parseIPSFirstLine(line) {
        let bundle = header.bundleID ?? "?"
        let bug = header.bugType ?? "?"
        let inc = header.incidentID.map { String($0.prefix(8)) } ?? "?"
        summary = "\(bundle) bug_type=\(bug) (\(inc))"
        // Prefer the OS-reported crash time. CrashReporter can lag the
        // actual crash by seconds-to-minutes, so file mtime is a strictly
        // worse proxy when the header carries a timestamp.
        timestamp = header.timestamp ?? mtime
    } else {
        summary = url.lastPathComponent
        timestamp = mtime
    }

    guard timestamp >= since else { return nil }

    return HealthEvent(
        timestamp: timestamp,
        rail: .ips,
        severity: .crash,
        summary: summary,
        path: url.path
    )
}

private func readFirstLine(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: 8192)) ?? Data()
    // Lossy UTF-8: tolerate a multi-byte sequence sitting astride the
    // 8192-byte read boundary by inserting U+FFFD instead of returning
    // nil. The caller only cares about the first line; the trailing
    // replacement char is harmless because we cut at the first `\n`.
    let text = String(decoding: data, as: UTF8.self)
    if let nl = text.firstIndex(of: "\n") {
        return String(text[..<nl])
    }
    return text
}

// MARK: - Sentry queued rail

/// Walks `<home>/Library/Caches/com.stage11.c11*/io.sentry/` recursively and
/// emits one event per file. Sentry-Cocoa typically writes envelopes under
/// `io.sentry/envelopes/`, but we don't make that assumption: any regular file
/// inside `io.sentry/` is treated as a queued event. Envelope contents are
/// never parsed.
func scanSentryQueued(home: String, since: Date) -> [HealthEvent] {
    let cacheURL = URL(fileURLWithPath: "\(home)/Library/Caches")
    let fm = FileManager.default

    guard let bundleDirs = try? fm.contentsOfDirectory(
        at: cacheURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var events: [HealthEvent] = []

    for bundleDir in bundleDirs {
        let bundleName = bundleDir.lastPathComponent
        guard bundleName.hasPrefix("com.stage11.c11") else { continue }
        let isDir = (try? bundleDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { continue }

        let sentryRoot = bundleDir.appendingPathComponent("io.sentry", isDirectory: true)
        guard fm.fileExists(atPath: sentryRoot.path) else { continue }
        events.append(contentsOf: walkSentryDir(sentryRoot, bundleName: bundleName, since: since))
    }

    return events
}

private func walkSentryDir(_ dir: URL, bundleName: String, since: Date) -> [HealthEvent] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: dir,
        includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var events: [HealthEvent] = []
    for case let url as URL in enumerator {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
              values.isRegularFile == true,
              let mtime = values.contentModificationDate,
              mtime >= since
        else { continue }

        events.append(HealthEvent(
            timestamp: mtime,
            rail: .sentry,
            severity: .queued,
            summary: "\(bundleName)/\(url.lastPathComponent)",
            path: url.path
        ))
    }
    return events
}

// MARK: - MetricKit rail

/// Filename grammar for files written by `CrashDiagnostics.persist` in
/// `Sources/SentryHelper.swift`:
///
///     <stamp>-<kind>.json
///
/// where `<stamp>` is `YYYY-MM-DDTHH-MM-SS.fffZ` (ISO 8601 with `:` replaced
/// by `-`, always UTC, fixed 24 chars) and `<kind>` is one of:
///   - `metric` (MXMetricPayload telemetry baseline; skipped in v1)
///   - `diagnostic` (MXDiagnosticPayload with no per-category counts)
///   - one or more of `crash<n>` / `hang<n>` / `cpu<n>` / `disk<n>` joined by
///     `-` in the fixed order crash, hang, cpu, disk.
struct MetricKitFilename {
    let timestamp: Date
    let kind: String
}

/// Returns nil for `metric` rows (per plan: skip telemetry baselines), nil
/// for unparseable stamps, and nil for malformed kind tokens.
func parseMetricKitFilename(_ name: String) -> MetricKitFilename? {
    guard name.hasSuffix(".json") else { return nil }
    let stem = String(name.dropLast(".json".count))

    // The stamp is exactly 24 characters: YYYY-MM-DDTHH-MM-SS.fffZ.
    let stampLength = 24
    guard stem.count > stampLength + 1 else { return nil }
    let stampEnd = stem.index(stem.startIndex, offsetBy: stampLength)
    let stampStr = String(stem[..<stampEnd])

    let afterStamp = stem[stampEnd...]
    guard afterStamp.first == "-" else { return nil }
    let kind = String(afterStamp.dropFirst())

    guard let date = parseFilenameSafeISO(stampStr) else { return nil }
    guard isValidMetricKitKind(kind) else { return nil }

    // Skip MXMetricPayload baselines: they aren't diagnostic events.
    if kind == "metric" { return nil }

    return MetricKitFilename(timestamp: date, kind: kind)
}

private func parseFilenameSafeISO(_ stamp: String) -> Date? {
    guard stamp.count == 24, stamp.last == "Z" else { return nil }
    var chars = Array(stamp)
    guard chars[10] == "T",
          chars[13] == "-",
          chars[16] == "-",
          chars[19] == "."
    else { return nil }
    chars[13] = ":"
    chars[16] = ":"
    let normalized = String(chars)
    return makeFractionalISOFormatter().date(from: normalized)
}

private func isValidMetricKitKind(_ kind: String) -> Bool {
    if kind == "metric" || kind == "diagnostic" { return true }
    let tokens = kind.split(separator: "-").map(String.init)
    guard !tokens.isEmpty else { return false }
    return tokens.allSatisfy(isValidCategoryToken)
}

private func isValidCategoryToken(_ token: String) -> Bool {
    let prefixes = ["crash", "hang", "cpu", "disk"]
    for prefix in prefixes where token.hasPrefix(prefix) {
        let suffix = token.dropFirst(prefix.count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
    }
    return false
}

private func metricKitSeverity(forKind kind: String) -> HealthEvent.Severity {
    if kind == "diagnostic" { return .diagnostic }
    let tokens = kind.split(separator: "-").map(String.init)
    let hasCrash = tokens.contains { $0.hasPrefix("crash") }
    let hasHang = tokens.contains { $0.hasPrefix("hang") }
    let hasResource = tokens.contains { $0.hasPrefix("cpu") || $0.hasPrefix("disk") }
    let categoryCount = [hasCrash, hasHang, hasResource].filter { $0 }.count
    if categoryCount > 1 { return .mixed }
    if hasCrash { return .crash }
    if hasHang { return .hang }
    if hasResource { return .resource }
    return .diagnostic
}

func scanMetricKit(home: String, since: Date) -> [HealthEvent] {
    let dir = URL(fileURLWithPath: "\(home)/Library/Logs/c11/metrickit")
    let fm = FileManager.default

    guard let files = try? fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var events: [HealthEvent] = []
    for url in files where url.pathExtension == "json" {
        guard let parsed = parseMetricKitFilename(url.lastPathComponent),
              parsed.timestamp >= since
        else { continue }
        events.append(HealthEvent(
            timestamp: parsed.timestamp,
            rail: .metrickit,
            severity: metricKitSeverity(forKind: parsed.kind),
            summary: parsed.kind,
            path: url.path
        ))
    }
    return events
}

// MARK: - Flags + boot time

enum HealthCLIError: Error, CustomStringConvertible {
    case mutuallyExclusiveSinceFlags
    case missingValue(flag: String)
    case invalidSinceValue(String)
    case unknownRail(String)
    case unknownFlag(String)
    case duplicateFlag(String)

    var description: String {
        switch self {
        case .mutuallyExclusiveSinceFlags:
            return "--since and --since-boot are mutually exclusive"
        case .missingValue(let flag):
            return "\(flag) requires a value"
        case .invalidSinceValue(let v):
            return "invalid --since value '\(v)' (expected like 30m, 2h, 24h, 3d)"
        case .unknownRail(let r):
            return "unknown --rail '\(r)' (expected one of ips, sentry, metrickit, sentinel)"
        case .unknownFlag(let f):
            return "unknown flag '\(f)'"
        case .duplicateFlag(let f):
            return "\(f) may only be specified once"
        }
    }
}

struct HealthCLIOptions {
    let mode: HealthCollectionWindow.Mode
    /// Used only when `mode == .sinceDuration`; ignored for boot/default modes.
    let windowDuration: TimeInterval
    let railFilter: HealthEvent.Rail?
    let json: Bool
}

/// Accepts compact-suffix duration strings: 30m, 2h, 24h, 3d. Returns the
/// corresponding `TimeInterval`, or nil for malformed input.
func parseSinceFlag(_ value: String) -> TimeInterval? {
    guard let last = value.last else { return nil }
    let head = value.dropLast()
    guard !head.isEmpty, let n = Double(head), n > 0 else { return nil }
    switch last {
    case "m": return n * 60
    case "h": return n * 3600
    case "d": return n * 86400
    default: return nil
    }
}

/// Reads `kern.boottime` via `sysctlbyname`. Falls back to 24h ago on
/// failure so callers do not have to handle nil for a value the kernel
/// always exposes on macOS. On failure, writes a single diagnostic line
/// via `onFallback` (defaults to stderr) so the operator is told that
/// `--since-boot` silently became a 24h window.
func bootTime(onFallback: (String) -> Void = { msg in
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}) -> Date {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    let result = sysctlbyname("kern.boottime", &tv, &size, nil, 0)
    if result == 0 {
        let seconds = TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }
    onFallback("c11 health: kern.boottime unavailable (errno=\(errno)), falling back to 24h window")
    return Date(timeIntervalSinceNow: -24 * 3600)
}

func parseHealthCLIArgs(_ args: [String]) throws -> HealthCLIOptions {
    var since: TimeInterval? = nil
    var sinceBoot = false
    var rail: HealthEvent.Rail? = nil
    var json = false

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--json":
            json = true
            i += 1
        case "--since":
            guard i + 1 < args.count else { throw HealthCLIError.missingValue(flag: "--since") }
            let v = args[i + 1]
            guard let interval = parseSinceFlag(v) else {
                throw HealthCLIError.invalidSinceValue(v)
            }
            since = interval
            i += 2
        case "--since-boot":
            sinceBoot = true
            i += 1
        case "--rail":
            guard i + 1 < args.count else { throw HealthCLIError.missingValue(flag: "--rail") }
            let v = args[i + 1]
            guard let r = HealthEvent.Rail(rawValue: v) else {
                throw HealthCLIError.unknownRail(v)
            }
            guard rail == nil else { throw HealthCLIError.duplicateFlag("--rail") }
            rail = r
            i += 2
        case "-h", "--help":
            // Help is dispatched upstream via dispatchSubcommandHelp; tolerate here.
            i += 1
        default:
            throw HealthCLIError.unknownFlag(arg)
        }
    }

    if since != nil && sinceBoot {
        throw HealthCLIError.mutuallyExclusiveSinceFlags
    }

    let mode: HealthCollectionWindow.Mode
    let duration: TimeInterval
    if let since {
        mode = .sinceDuration
        duration = since
    } else if sinceBoot {
        mode = .sinceBoot
        duration = 0
    } else {
        mode = .defaultLast24h
        duration = 24 * 3600
    }

    return HealthCLIOptions(
        mode: mode,
        windowDuration: duration,
        railFilter: rail,
        json: json
    )
}

// MARK: - Diagnostic warnings

private struct UncleanExitMarker {
    let timestamp: Date
    let version: String
}

private func mostRecentSentinelMarker(home: String) -> UncleanExitMarker? {
    let cacheURL = URL(fileURLWithPath: "\(home)/Library/Caches")
    let fm = FileManager.default

    guard let bundleDirs = try? fm.contentsOfDirectory(
        at: cacheURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else { return nil }

    var best: UncleanExitMarker? = nil

    for bundleDir in bundleDirs {
        guard bundleDir.lastPathComponent.hasPrefix("com.stage11.c11") else { continue }
        let sessionsDir = bundleDir.appendingPathComponent("sessions", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { continue }

        for url in files {
            let name = url.lastPathComponent
            // active.json is the *current* session; including it means
            // the post-bump warning compares the current version against
            // itself and silently returns nil. Only prior unclean-exit
            // archives are valid baselines.
            guard name.hasPrefix("unclean-exit-"), name.hasSuffix(".json") else { continue }

            let stamp = String(name.dropFirst("unclean-exit-".count).dropLast(".json".count))
            var ts: Date? = parseFilenameSafeISO(stamp)

            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if ts == nil, let str = obj["launched_at"] as? String {
                ts = makeFractionalISOFormatter().date(from: str)
            }
            if ts == nil, let attrs = try? fm.attributesOfItem(atPath: url.path) {
                ts = attrs[.modificationDate] as? Date
            }

            guard let timestamp = ts,
                  let version = obj["version"] as? String,
                  !version.isEmpty
            else { continue }

            if best == nil || best!.timestamp < timestamp {
                best = UncleanExitMarker(timestamp: timestamp, version: version)
            }
        }
    }

    return best
}

/// Fires when MetricKit count is 0 AND the running c11 was version-bumped
/// within the last 24h. Compares `bundleVersion` against the most-recent
/// prior session marker's `version`; if the marker is missing, returns nil
/// (we have no baseline to compare against).
func metricKitBaselineWarning(
    home: String,
    bundleVersion: String?,
    metricKitCount: Int,
    now: Date = Date()
) -> String? {
    guard metricKitCount == 0,
          let curr = bundleVersion, !curr.isEmpty,
          let marker = mostRecentSentinelMarker(home: home)
    else { return nil }

    guard marker.version != curr else { return nil }
    let age = now.timeIntervalSince(marker.timestamp)
    guard age >= 0, age <= 24 * 3600 else { return nil }

    return "MetricKit baseline still establishing after version bump (\(marker.version) to \(curr)); diagnostic payloads may not deliver for ~24h."
}

/// Fires when zero queued events overall AND at least one `io.sentry/`
/// directory exists across the `com.stage11.c11*` bundle family but every
/// such directory is empty. Mirrors `scanSentryQueued`'s family iteration
/// so the footer fires on machines that only ran a debug build (no
/// production-bundle cache present), not just on production-only machines.
func telemetryAmbiguityFooter(home: String, sentryCount: Int) -> String? {
    guard sentryCount == 0 else { return nil }
    let cacheURL = URL(fileURLWithPath: "\(home)/Library/Caches")
    let fm = FileManager.default

    guard let bundleDirs = try? fm.contentsOfDirectory(
        at: cacheURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }

    var sawAnySentryDir = false
    for bundleDir in bundleDirs {
        guard bundleDir.lastPathComponent.hasPrefix("com.stage11.c11") else { continue }
        let isDir = (try? bundleDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { continue }

        let sentryRoot = bundleDir.appendingPathComponent("io.sentry", isDirectory: true)
        var sentryIsDir: ObjCBool = false
        guard fm.fileExists(atPath: sentryRoot.path, isDirectory: &sentryIsDir),
              sentryIsDir.boolValue
        else { continue }
        sawAnySentryDir = true

        guard let enumerator = fm.enumerator(
            at: sentryRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { continue }
        for case let f as URL in enumerator {
            if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return nil
            }
        }
    }

    guard sawAnySentryDir else { return nil }
    return "Sentry cache empty across c11 bundles: telemetry may be off, or events shipped on last launch and cleared the cache."
}

// MARK: - Launch sentinel rail

/// One row per `unclean-exit-*.json` archive written by
/// `LaunchSentinel.recordLaunchAndArchivePrevious()` in
/// `Sources/SentryHelper.swift`. Catches Force-Quit / SIGKILL terminations
/// where neither Sentry nor `.ips` files survive.
func scanLaunchSentinel(home: String, since: Date) -> [HealthEvent] {
    let cacheURL = URL(fileURLWithPath: "\(home)/Library/Caches")
    let fm = FileManager.default

    guard let bundleDirs = try? fm.contentsOfDirectory(
        at: cacheURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var events: [HealthEvent] = []

    for bundleDir in bundleDirs {
        let bundleName = bundleDir.lastPathComponent
        guard bundleName.hasPrefix("com.stage11.c11") else { continue }
        let isDir = (try? bundleDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { continue }

        let sessionsDir = bundleDir.appendingPathComponent("sessions", isDirectory: true)
        guard let sessionFiles = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { continue }

        for url in sessionFiles {
            let name = url.lastPathComponent
            guard name.hasPrefix("unclean-exit-"),
                  name.hasSuffix(".json")
            else { continue }
            guard let event = parseUncleanExitFile(at: url, since: since) else { continue }
            events.append(event)
        }
    }

    return events
}

/// Returns nil when the file's stamp predates `since`, or when the file
/// cannot be read or parsed. Filename is the source of truth for the
/// timestamp; the JSON body is best-effort metadata.
///
/// Filename ISO timestamp is the source of truth for the row's TIME column;
/// the JSON body is informational metadata. When the body is corrupt or missing
/// keys, render "unknown" rather than dropping the row, so the operator still
/// sees evidence that an unclean exit happened. Do NOT skip these rows: the
/// presence of the file is the signal.
func parseUncleanExitFile(at url: URL, since: Date) -> HealthEvent? {
    let name = url.lastPathComponent
    let prefix = "unclean-exit-"
    let suffix = ".json"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
    let stamp = String(name.dropFirst(prefix.count).dropLast(suffix.count))
    guard let date = parseFilenameSafeISO(stamp), date >= since else { return nil }

    var version = "unknown"
    var build = "unknown"
    var commit = "unknown"

    if let data = try? Data(contentsOf: url),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let v = obj["version"] as? String, !v.isEmpty { version = v }
        if let b = obj["build"] as? String, !b.isEmpty { build = b }
        if let c = obj["commit"] as? String, !c.isEmpty {
            commit = String(c.prefix(8))
        }
    }

    let summary = "\(version) (\(build)) \(commit)"
    return HealthEvent(
        timestamp: date,
        rail: .sentinel,
        severity: .unclean_exit,
        summary: summary,
        path: url.path
    )
}

/// Default rail set used to build the empty-result line when no `rails`
/// argument is supplied (e.g., callers that have not been migrated yet).
private let healthAllRails: [HealthEvent.Rail] = [.ips, .sentry, .metrickit, .sentinel]

/// Renders the empty-result line dynamically so it reflects the actual
/// rails queried and the actual time window (rather than always claiming
/// "the last 24h across ips, sentry, metrickit, sentinel").
func healthEmptyResultLine(
    rails: [HealthEvent.Rail] = healthAllRails,
    window: HealthCollectionWindow? = nil
) -> String {
    let railList = rails.isEmpty
        ? healthAllRails.map(\.rawValue).joined(separator: ", ")
        : rails.map(\.rawValue).joined(separator: ", ")
    let windowPhrase: String
    if let window {
        switch window.mode {
        case .defaultLast24h:
            windowPhrase = "in the last 24h"
        case .sinceBoot:
            windowPhrase = "since boot"
        case .sinceDuration:
            let elapsed = window.until.timeIntervalSince(window.since)
            windowPhrase = "in the last \(formatDurationPhrase(elapsed))"
        }
    } else {
        windowPhrase = "in the last 24h"
    }
    return "c11 health: nothing \(windowPhrase) across \(railList)."
}

private func formatDurationPhrase(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s % 86400 == 0 { return "\(s / 86400)d" }
    if s % 3600 == 0 { return "\(s / 3600)h" }
    if s % 60 == 0 { return "\(s / 60)m" }
    return "\(s)s"
}

/// `timeZone` is exposed for golden-file tests; production callers leave it
/// nil to use the operator's local time. `rails` and `window` are used
/// only to build the empty-result line; they default so existing callers
/// keep their previous behavior.
func renderHealthTable(
    _ events: [HealthEvent],
    warnings: [String] = [],
    timeZone: TimeZone? = nil,
    rails: [HealthEvent.Rail] = healthAllRails,
    window: HealthCollectionWindow? = nil
) -> String {
    var lines: [String] = []
    if events.isEmpty {
        lines.append(healthEmptyResultLine(rails: rails, window: window))
    } else {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        if let timeZone {
            f.timeZone = timeZone
        }
        lines.append("TIME             | RAIL      | SEVERITY     | SUMMARY")
        lines.append("(TIME reflects the OS-reported event time when available, file mtime otherwise)")
        for ev in events {
            let time = f.string(from: ev.timestamp)
            let rail = ev.rail.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            let sev = ev.severity.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
            lines.append("\(time) | \(rail) | \(sev) | \(ev.summary)")
        }
    }
    if !warnings.isEmpty {
        lines.append("")
        lines.append("Warnings:")
        for w in warnings {
            lines.append("  - \(w)")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Wire-format version for `c11 health --json`. Bump on any breaking
/// shape change so downstream consumers can branch on it.
public let healthJSONSchemaVersion = 1

/// Replaces a leading `home` prefix with literal `~` so JSON output the
/// operator pastes into tickets / chat / agent transcripts does not leak
/// the macOS username.
func redactHomePath(_ path: String, home: String) -> String {
    guard !home.isEmpty else { return path }
    let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
    if path == trimmed { return "~" }
    if path.hasPrefix(trimmed + "/") {
        return "~" + path.dropFirst(trimmed.count)
    }
    return path
}

func renderHealthJSON(
    events: [HealthEvent],
    window: HealthCollectionWindow,
    rails: Set<HealthEvent.Rail>,
    warnings: [String],
    home: String = NSHomeDirectory()
) throws -> Data {
    let iso = makeFractionalISOFormatter()

    var railCounts: [String: [String: Int]] = [:]
    for rail in HealthEvent.Rail.allCases where rails.contains(rail) {
        railCounts[rail.rawValue] = ["count": events.filter { $0.rail == rail }.count]
    }

    let eventsArray: [[String: Any]] = events.map { ev in
        [
            "timestamp": iso.string(from: ev.timestamp),
            "rail": ev.rail.rawValue,
            "severity": ev.severity.rawValue,
            "summary": ev.summary,
            "path": redactHomePath(ev.path, home: home),
        ]
    }

    let payload: [String: Any] = [
        "schema_version": healthJSONSchemaVersion,
        "window": [
            "since": iso.string(from: window.since),
            "until": iso.string(from: window.until),
            "mode": window.mode.rawValue,
        ],
        "rails": railCounts,
        "events": eventsArray,
        "warnings": warnings,
    ]

    return try JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
    )
}
