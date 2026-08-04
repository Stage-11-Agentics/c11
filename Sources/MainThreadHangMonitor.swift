import AppKit
import Darwin
import Foundation

/// What a captured main-thread backtrace says the wedge actually is.
///
/// `cause` answers "what is main blocked on" and `phase` narrows the largest
/// cause (SwiftUI graph work) to the host operation driving it. Together they
/// form the Sentry fingerprint. `culprit` and `topSymbol` are per-report detail
/// that rides along as tags — searchable inside an issue without splitting it.
struct MainThreadHangDescriptor: Equatable {
    let cause: String
    let phase: String?
    /// Deepest frame belonging to this app's own binary, if the captured window
    /// reached one. Mangled — run it through `swift demangle`.
    let culprit: String?
    let topSymbol: String?

    /// Human-readable signature, used as the Sentry message so an issue's title
    /// names its cause instead of whichever stall duration happened to be first.
    var label: String {
        guard let phase else { return cause }
        return "\(cause)/\(phase)"
    }

    var fingerprint: [String] {
        var parts = ["main-thread-hang", cause]
        if let phase { parts.append(phase) }
        return parts
    }
}

/// Reduces a captured main-thread backtrace to a stable grouping signature.
///
/// Sentry groups message events by the stack of the thread that *reported*
/// them. For hang reports that is always the watchdog's own loop, byte-identical
/// every time, so every main-thread hang — whatever wedged main — collapses into
/// one issue. Fingerprinting on the wedged stack instead is what makes causes
/// separable at all.
///
/// Deliberately coarse. The capture is a single sample of a moving thread, so
/// fingerprinting on leaf frames splits one cause across hundreds of issues:
/// over 875 real reports, a top-5-frame fingerprint produced 645 groups, 607 of
/// them singletons. Classifying *what main is blocked on* produced a handful of
/// durable buckets instead.
enum MainThreadHangSignature {

    /// One parsed `backtrace_symbols` line: `"12  AppKit  0x1854  -[NSView layout] + 96"`.
    struct Frame: Equatable {
        let module: String
        let symbol: String
    }

    // Ordered: the first match wins, so a blocking wait outranks whatever
    // library asked for it. A thread parked in a semaphore is a lock problem
    // no matter how pretty the frames above it look.
    private static let causeRules: [(cause: String, needles: [String])] = [
        ("xpc-sync-wait", [
            "_dispatch_mach_send_and_wait_for_reply",
            "xpc_connection_send_message_with_reply_sync",
            "CFXPCSendMessageWithReply",
        ]),
        ("lock-wait", [
            "psynch_mutexwait", "psynch_cvwait", "semaphore_wait",
            "semaphore_timedwait", "ulock_wait", "_pthread_cond_wait",
        ]),
        ("generic-metadata", [
            "swift_getTypeByMangledName", "_gatherGenericParameters",
            "swift_getOpaqueTypeMetadata", "instantiateGenericMetadata",
            "_swift_getGenericMetadata", "MetadataCacheKey",
        ]),
    ]

    private static let swiftUIModules: Set<String> = [
        "SwiftUI", "SwiftUICore", "AttributeGraph",
    ]

    private static let renderingModules: Set<String> = [
        "AppKit", "QuartzCore", "CoreGraphics", "CoreText", "HIToolbox",
    ]

    /// SwiftUI host operations, most specific first — these say *which* graph
    /// pass is running, which is the difference between a layout bug and a
    /// transaction-flush bug.
    private static let phaseRules: [(phase: String, needle: String)] = [
        ("hosting-begin-transaction", "NSHostingViewC16beginTransaction"),
        ("hosting-layout", "NSHostingViewC6layout"),
        ("display-list-render", "ViewGraphRootValueUpdaterPAAE6render"),
        ("preferences", "updatePreferences"),
        ("nsview-layout", "_layoutSubtreeWithOldSize"),
        ("menu", "NSMenu"),
    ]

    /// How far down the stack the cause rules look. Blocking waits and metadata
    /// instantiation sit near the leaf; searching the whole 96-frame capture
    /// would let an unrelated deep frame decide the bucket.
    private static let causeWindow = 16
    /// How far down "which module is main working in" is decided.
    private static let moduleWindow = 8

    /// `backtrace_symbols` emits `"%-4d%-35s 0x%016lx %s + %lu"`. The load
    /// address is the only reliable delimiter: image names may contain spaces
    /// (`c11 DEV`), so splitting on whitespace alone mis-parses dev builds.
    static func parse(_ line: String) -> Frame? {
        var tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let first = tokens.first, Int(first) != nil { tokens.removeFirst() }
        guard let addressIndex = tokens.firstIndex(where: { $0.hasPrefix("0x") }) else { return nil }

        let module = tokens[tokens.startIndex..<addressIndex].joined(separator: " ")
        var rest = Array(tokens[tokens.index(after: addressIndex)...])
        // Trailing "+ <offset>" moves with every build; it is noise for grouping.
        if rest.count >= 2, rest[rest.count - 2] == "+", Int(rest[rest.count - 1]) != nil {
            rest.removeLast(2)
        }
        let symbol = rest.joined(separator: " ")
        guard !module.isEmpty, !symbol.isEmpty else { return nil }
        return Frame(module: module, symbol: symbol)
    }

    static func describe(stack: [String], ownModule: String) -> MainThreadHangDescriptor {
        let frames = stack.compactMap(parse)
        guard !frames.isEmpty else {
            return MainThreadHangDescriptor(
                cause: "unknown", phase: nil, culprit: nil, topSymbol: nil
            )
        }

        let cause = self.cause(frames)
        return MainThreadHangDescriptor(
            cause: cause,
            phase: cause == "swiftui-update" ? phase(frames) : nil,
            culprit: culprit(frames, ownModule: ownModule),
            topSymbol: frames[0].symbol
        )
    }

    static func cause(_ frames: [Frame]) -> String {
        guard let leaf = frames.first else { return "unknown" }
        let window = frames.prefix(causeWindow)
        for rule in causeRules where window.contains(where: { frame in
            rule.needles.contains { frame.symbol.contains($0) }
        }) {
            return rule.cause
        }
        // Parked at the top of the run loop waiting for work: main is idle, and
        // the watchdog's heartbeat should have been serviced. Its own bucket so
        // it can be judged separately from a thread wedged in compute.
        if leaf.symbol.contains("mach_msg2_trap"),
           window.contains(where: { $0.symbol.contains("CFRunLoopServiceMachPort") }) {
            return "runloop-idle"
        }
        let modules = frames.prefix(moduleWindow).map(\.module)
        if modules.contains(where: swiftUIModules.contains) { return "swiftui-update" }
        if modules.contains(where: renderingModules.contains) { return "appkit" }
        return "other"
    }

    static func phase(_ frames: [Frame]) -> String? {
        for rule in phaseRules where frames.contains(where: { $0.symbol.contains(rule.needle) }) {
            return rule.phase
        }
        return nil
    }

    static func culprit(_ frames: [Frame], ownModule: String) -> String? {
        // `main` is in every capture and names nothing; skip it so the tag
        // stays empty rather than useless when nothing else of ours is on the
        // stack.
        frames.first { $0.module == ownModule && $0.symbol != "main" }?.symbol
    }
}

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
    /// A stall must reach this before it is worth an outbound Sentry event.
    /// Detection (and the local log) still start at the detector's 2s threshold.
    private let sentryReportThresholdMs: Double = 5000
    private var detector = MainThreadHangDetector()
    /// Watchdog-thread-only: has this episode already produced a Sentry event?
    private var reportedCurrentEpisode = false

    private let lock = NSLock()
    private var lastAckUptime: TimeInterval = 0
    private var pingOutstanding = false

    private var mainThread: thread_t = mach_port_t(MACH_PORT_NULL)
    private var installed = false

    /// Reused address buffer for stack capture. Preallocated once so no heap
    /// allocation ever happens inside the `thread_suspend`/`thread_resume` window
    /// — a `malloc` there would deadlock if the suspended main thread holds the
    /// malloc lock. Only ever touched on the watchdog thread, which captures
    /// serially, so the single shared buffer is safe.
    private var frameBuffer: [UInt]

    private let logURL: URL

    private init() {
        frameBuffer = [UInt](repeating: 0, count: maxFrames)
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
        if !recapture { reportedCurrentEpisode = false }
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
        reportedCurrentEpisode = false
        let dropped = SentryEventBudgetGate.shared.dropped
        appendToLog(
            "=== c11 hang.end \(Self.timestamp()) totalMs=\(Int(durationMs)) pid=\(getpid()) "
                + "sentrySuppressed=\(dropped.hangs)/\(dropped.total) ===\n\n"
        )
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

        // Nothing inside the suspend window may allocate or take an app-level
        // lock: if main is suspended while holding (e.g.) the malloc lock, any
        // allocation here would block forever and wedge the process. The buffer
        // is preallocated; the C unwinder only reads memory via mach_vm calls.
        guard thread_suspend(mainThread) == KERN_SUCCESS else {
            return ["<thread_suspend failed>"]
        }
        let frameCount = frameBuffer.withUnsafeMutableBufferPointer { buffer -> Int in
            Int(c11_capture_thread_backtrace(mainThread, buffer.baseAddress!, Int32(maxFrames)))
        }
        thread_resume(mainThread)

        guard frameCount > 0 else { return ["<no frames captured>"] }
        // Symbolication (which allocates and can take locks the suspended thread
        // may have held) happens only after resume.
        return symbolicate((0..<frameCount).map { UnsafeMutableRawPointer(bitPattern: frameBuffer[$0]) })
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
        if shouldReportHangToSentry(gapMs: gapMs) {
            let signature = MainThreadHangSignature.describe(
                stack: stack,
                ownModule: ProcessInfo.processInfo.processName
            )
            var tags = ["hang.cause": signature.cause, "hang.recapture": recapture ? "true" : "false"]
            tags["hang.phase"] = signature.phase
            tags["hang.culprit"] = signature.culprit
            tags["hang.top_symbol"] = signature.topSymbol
            // The stall duration belongs in the message only if it is not the
            // grouping key — it isn't, so the title names the cause and the
            // duration stays a searchable tag/context value.
            sentryCaptureWarning(
                "main thread hang (\(signature.label))",
                category: "hang",
                data: [
                    "stalled_ms": Int(gapMs),
                    "recapture": recapture,
                    "stack": top,
                ],
                contextKey: "hang",
                fingerprint: signature.fingerprint,
                tags: tags
            )
        }
        PostHogAnalytics.shared.captureMainThreadHang(
            stalledMs: gapMs,
            recapture: recapture,
            topFrame: stack.first ?? ""
        )
    }

    /// At most one Sentry event per hang episode, and only for episodes that
    /// actually reach `sentryReportThresholdMs`.
    ///
    /// The local hang log still records every capture — it never leaves the
    /// machine and it is where a full episode timeline is read. Sentry only
    /// needs to know the episode happened, to whom, and with what stack:
    /// re-sending the same wedge every 5s for the length of a beachball was
    /// ~98% of c11's entire event volume and bought nothing, because Sentry
    /// groups them into a single issue anyway.
    ///
    /// Called only from the watchdog thread, which captures serially.
    private func shouldReportHangToSentry(gapMs: Double) -> Bool {
        guard gapMs >= sentryReportThresholdMs else { return false }
        guard !reportedCurrentEpisode else { return false }
        guard SentryEventBudgetGate.shared.allow(.hang) else { return false }
        reportedCurrentEpisode = true
        return true
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

        if let debugLog = c11Env("C11_DEBUG_LOG", in: env)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !debugLog.isEmpty {
            let base = URL(fileURLWithPath: debugLog)
            let name = base.lastPathComponent
            let stem = name.lastIndex(of: ".").map { String(name[..<$0]) } ?? name
            return base.deletingLastPathComponent().appendingPathComponent("\(stem)-hang.log")
        }

        if let tag = c11Env("C11_TAG", in: env)?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
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
