import AppKit
import Darwin
import Foundation

/// Pure decision core for main-thread hang detection.
///
/// Split out from `MainThreadHangMonitor` so the stall/recovery state machine
/// can be unit-tested with injected timestamps — no real threads, no wall clock.
/// `evaluate(nowUptime:lastAckUptime:)` is called once per watchdog tick and
/// returns what the live monitor should do.
struct MainThreadHangDetector {
    /// A stall must persist at least this long before it counts as a hang worth
    /// snapshotting. Kept above any normal main-thread turn to avoid noise.
    let stallThresholdMs: Double
    /// While a single hang persists, re-snapshot no more often than this — the
    /// wedge may move (or deepen) and a second stack is often more informative.
    let recaptureIntervalMs: Double

    private var inEpisode = false
    private var episodeStartUptime: Double = 0
    private var lastCaptureUptime: Double = 0

    init(stallThresholdMs: Double = 2000, recaptureIntervalMs: Double = 5000) {
        self.stallThresholdMs = stallThresholdMs
        self.recaptureIntervalMs = recaptureIntervalMs
    }

    enum Decision: Equatable {
        case none
        /// Main has been unresponsive for `gapMs`. `recapture` is false for the
        /// first detection of an episode, true for subsequent snapshots of the
        /// same ongoing hang.
        case capture(gapMs: Double, recapture: Bool)
        /// Main answered again; the episode that lasted `durationMs` is over.
        case recovered(durationMs: Double)
    }

    /// Drive the state machine one tick.
    /// - Parameters:
    ///   - nowUptime: current `ProcessInfo.processInfo.systemUptime`.
    ///   - lastAckUptime: uptime at which the main thread last acknowledged a
    ///     heartbeat. While main is wedged this stops advancing, so the gap grows.
    mutating func evaluate(nowUptime: Double, lastAckUptime: Double) -> Decision {
        let gapMs = max(0, (nowUptime - lastAckUptime) * 1000.0)

        if gapMs >= stallThresholdMs {
            if !inEpisode {
                inEpisode = true
                episodeStartUptime = lastAckUptime
                lastCaptureUptime = nowUptime
                return .capture(gapMs: gapMs, recapture: false)
            }
            if (nowUptime - lastCaptureUptime) * 1000.0 >= recaptureIntervalMs {
                lastCaptureUptime = nowUptime
                return .capture(gapMs: gapMs, recapture: true)
            }
            return .none
        }

        if inEpisode {
            inEpisode = false
            let durationMs = max(0, (nowUptime - episodeStartUptime) * 1000.0)
            return .recovered(durationMs: durationMs)
        }
        return .none
    }

    /// Test-only introspection into episode state.
    var isInEpisode: Bool { inEpisode }
}

/// Real-time main-thread watchdog.
///
/// A dedicated background thread pings the main thread on a fixed heartbeat. When
/// main stops answering for `stallThresholdMs`, the watchdog **suspends the main
/// thread and walks its stack right then** — the artifact a `CFRunLoopObserver`
/// cannot produce, because the observer can't run while main is wedged inside a
/// single callback (the classic beachball).
///
/// Ships enabled in Release (opt out with `C11_HANG_MONITOR=0`). Every record is
/// written to a local hang log unconditionally — it never leaves the machine —
/// and, when telemetry consent is granted, forwarded to Sentry + PostHog.
final class MainThreadHangMonitor: @unchecked Sendable {
    static let shared = MainThreadHangMonitor()

    private let tickIntervalMs: Double = 250
    private let maxFrames = 96
    private var detector = MainThreadHangDetector()

    private let lock = NSLock()
    private var lastAckUptime: TimeInterval = 0
    private var pingOutstanding = false

    private var mainThread: thread_t = mach_port_t(MACH_PORT_NULL)
    private var installed = false

    private let logURL: URL

    private init() {
        logURL = Self.resolveLogURL()
    }

    // MARK: Install

    /// Install the watchdog. Must be called on the main thread — it captures the
    /// main thread's mach port, which is the thread the watchdog later suspends.
    func installIfNeeded() {
        guard Thread.isMainThread else { return }
        guard !installed else { return }
        guard Self.isEnabled else { return }
        installed = true

        mainThread = pthread_mach_thread_np(pthread_self())
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock(); lastAckUptime = now; lock.unlock()

        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "com.stage11.c11.hang-monitor"
        thread.qualityOfService = .background
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// On by default; opt out via env. Never runs under the XCTest host, where
    /// suspending the main thread would fight the harness's own timing.
    static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["C11_HANG_MONITOR"] == "0" || env["CMUX_HANG_MONITOR"] == "0" { return false }
        if env["XCTestConfigurationFilePath"] != nil { return false }
        if NSClassFromString("XCTestCase") != nil { return false }
        return true
    }

    // MARK: Watchdog loop (runs on the background thread)

    private func runLoop() {
        let tick = tickIntervalMs / 1000.0
        while true {
            Thread.sleep(forTimeInterval: tick)
            sendHeartbeat()

            let now = ProcessInfo.processInfo.systemUptime
            lock.lock(); let ack = lastAckUptime; lock.unlock()

            switch detector.evaluate(nowUptime: now, lastAckUptime: ack) {
            case .none:
                break
            case .capture(let gapMs, let recapture):
                handleHang(gapMs: gapMs, recapture: recapture)
            case .recovered(let durationMs):
                handleRecovery(durationMs: durationMs)
            }
        }
    }

    /// Post a heartbeat the main thread will acknowledge. While main is wedged the
    /// previous ping stays queued (`pingOutstanding`), so we stop posting new ones
    /// and `lastAckUptime` simply stops advancing — exactly the signal we want.
    private func sendHeartbeat() {
        lock.lock()
        if pingOutstanding { lock.unlock(); return }
        pingOutstanding = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lock.lock()
            self.lastAckUptime = now
            self.pingOutstanding = false
            self.lock.unlock()
        }
    }

    // MARK: Hang handling

    private func handleHang(gapMs: Double, recapture: Bool) {
        let stack = captureMainBacktrace()
        let kind = recapture ? "hang.persist" : "hang.begin"

        var lines: [String] = []
        lines.append("=== c11 \(kind) \(Self.timestamp()) stalledMs=\(Int(gapMs)) pid=\(getpid()) ===")
        if stack.isEmpty {
            lines.append("  <no backtrace captured>")
        } else {
            for (i, frame) in stack.enumerated() {
                lines.append(String(format: "  %2d  %@", i, frame))
            }
        }
        lines.append("")
        appendToLog(lines.joined(separator: "\n") + "\n")

        reportTelemetry(gapMs: gapMs, recapture: recapture, stack: stack)
    }

    private func handleRecovery(durationMs: Double) {
        appendToLog("=== c11 hang.end \(Self.timestamp()) totalMs=\(Int(durationMs)) pid=\(getpid()) ===\n\n")
    }

    // MARK: Backtrace capture

    /// Suspend the main thread, capture its stack via the C unwinder, then resume
    /// — symbolicating only *after* resume, since symbolication can take locks the
    /// suspended thread may hold (a deadlock if done first).
    ///
    /// The unwind lives in C (`c11_capture_thread_backtrace`) because cross-thread
    /// stack walking needs `pthread_stack_frame_decode_np` for pointer-auth
    /// stripping, which isn't exposed to Swift; `backtrace_from_fp` is unusable
    /// here because it validates the FP against the *calling* thread's stack and so
    /// can't read another thread's frames.
    private func captureMainBacktrace() -> [String] {
        guard mainThread != mach_port_t(MACH_PORT_NULL) else { return [] }
        guard thread_suspend(mainThread) == KERN_SUCCESS else {
            return ["<thread_suspend failed>"]
        }

        var raw = [UInt](repeating: 0, count: maxFrames)
        let frameCount = raw.withUnsafeMutableBufferPointer { buffer -> Int in
            Int(c11_capture_thread_backtrace(mainThread, buffer.baseAddress!, Int32(maxFrames)))
        }

        // Resume as soon as the raw addresses are copied out — keep the suspend
        // window to register read + memory walk only.
        thread_resume(mainThread)

        guard frameCount > 0 else { return ["<no frames captured>"] }
        return symbolicate((0..<frameCount).map { UnsafeMutableRawPointer(bitPattern: raw[$0]) })
    }

    private func symbolicate(_ addrs: [UnsafeMutableRawPointer?]) -> [String] {
        guard !addrs.isEmpty else { return [] }
        var mutable = addrs
        guard let symbols = backtrace_symbols(&mutable, Int32(addrs.count)) else {
            return addrs.map { ptr in
                ptr.map { String(format: "0x%016lx", UInt(bitPattern: $0)) } ?? "0x0"
            }
        }
        defer { free(symbols) }
        var out: [String] = []
        out.reserveCapacity(addrs.count)
        for i in 0..<addrs.count {
            if let c = symbols[i] { out.append(String(cString: c)) }
        }
        return out
    }

    // MARK: Telemetry

    private func reportTelemetry(gapMs: Double, recapture: Bool, stack: [String]) {
        let top = stack.prefix(24).enumerated()
            .map { "\($0.offset)\t\($0.element)" }
            .joined(separator: "\n")
        sentryCaptureWarning(
            "main thread hang \(Int(gapMs))ms\(recapture ? " (persist)" : "")",
            category: "hang",
            data: [
                "stalled_ms": Int(gapMs),
                "recapture": recapture,
                "stack": top,
            ],
            contextKey: "hang"
        )
        PostHogAnalytics.shared.captureMainThreadHang(
            stalledMs: gapMs,
            recapture: recapture,
            topFrame: stack.first ?? ""
        )
    }

    // MARK: Local log

    private func appendToLog(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// Mirrors the debug-log path conventions: an explicit override wins, then a
    /// tag-derived `/tmp` path next to the other debug logs for tagged dev builds,
    /// and finally a durable per-user log under `~/Library/Logs/c11/` for the
    /// production app (where `/tmp` would be wiped on reboot).
    private static func resolveLogURL() -> URL {
        let env = ProcessInfo.processInfo.environment

        if let explicit = env["C11_HANG_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return URL(fileURLWithPath: explicit)
        }

        if let debugLog = env["CMUX_DEBUG_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !debugLog.isEmpty {
            let base = URL(fileURLWithPath: debugLog)
            let name = base.lastPathComponent
            let stem = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
            return base.deletingLastPathComponent().appendingPathComponent("\(stem)-hang.log")
        }

        if let tag = env["CMUX_TAG"]?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            let slug = String(tag.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            return URL(fileURLWithPath: "/tmp/c11-hang-\(slug).log")
        }

        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/c11", isDirectory: true)
        return logs.appendingPathComponent("hang.log")
    }
}
