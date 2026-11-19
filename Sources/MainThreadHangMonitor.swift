import AppKit
import Bonsplit
import Darwin
import Combine
import Foundation
import os

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
    ///
    /// Only `swiftui-update` is narrowed by phase (see `describe`). Every other
    /// cause already names something more actionable than the host operation
    /// above it, and splitting them by phase would fragment the small buckets
    /// that matter most: applied to all causes on the same corpora, this splits
    /// `generic-metadata` three ways for no diagnostic gain.
    private static let phaseRules: [(phase: String, needle: String)] = [
        ("hosting-begin-transaction", "NSHostingViewC16beginTransaction"),
        ("hosting-layout", "NSHostingViewC6layout"),
        ("display-list-render", "ViewGraphRootValueUpdaterPAAE6render"),
        ("preferences", "updatePreferences"),
    ]

    /// How far down the stack the cause rules look. Blocking waits and metadata
    /// instantiation sit near the leaf; searching the whole 96-frame capture
    /// would let an unrelated deep frame decide the bucket.
    private static let causeWindow = 16
    /// How far down "which module is main working in" is decided.
    private static let moduleWindow = 8

    /// Main parked at the top of the app's **outermost** event loop. Named
    /// because the reporting path treats it differently from every other cause:
    /// short episodes are late heartbeats; long ones need investigation.
    ///
    /// The `-[NSApplication run]` requirement in `cause` is what makes that
    /// claim true. Without it the bucket also swallows every *nested* run loop
    /// the app enters on purpose (a modal alert, a menu track, a socket command
    /// spinning `CFRunLoopRun` on main), which are real blocks with our own
    /// frames on the stack. On 7,926 real captures the frame separates the two
    /// populations exactly: present on all 2,895 outermost-idle captures and on
    /// none of the 5,031 nested ones.
    static let runLoopIdleCause = "runloop-idle"

    /// The frame that proves the run loop being serviced is the app's own top
    /// level, not one nested inside a callback.
    private static let outermostEventLoopSymbol = "-[NSApplication run]"

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
        // Parked at the top of the app's own event loop waiting for work: main
        // is idle, and the watchdog's heartbeat should have been serviced. Its
        // own bucket so it can be judged separately from a thread wedged in
        // compute. A *nested* run loop reaches the same mach_msg leaf but is a
        // genuine block, so it must fall through to the module rules below.
        if leaf.symbol.contains("mach_msg2_trap"),
           window.contains(where: { $0.symbol.contains("CFRunLoopServiceMachPort") }),
           window.contains(where: { $0.symbol.contains(outermostEventLoopSymbol) }) {
            return runLoopIdleCause
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

    /// The frames worth carrying in the outbound payload.
    ///
    /// The capture is up to 96 frames deep; the report is not. A straight prefix
    /// loses exactly the frames that name the workload: SwiftUI's update spine is
    /// routinely deeper than the window, so 73% of one 1,231-event production
    /// sample arrived with *no* frame from our own binary — every frame a system
    /// frame, and the hang unattributable no matter how many of them there were.
    ///
    /// So: the top window verbatim, then the own-module frames from below it, up
    /// to `ownFrames`. Kept frames keep their true index and the gap is marked, so
    /// the two runs can never be misread as contiguous.
    static func reportedStack(
        _ stack: [String],
        ownModule: String,
        topFrames: Int = 24,
        ownFrames: Int = 8
    ) -> [String] {
        func line(_ index: Int) -> String { "\(index)\t\(stack[index])" }
        guard stack.count > topFrames, topFrames >= 0 else {
            return stack.indices.map(line)
        }

        var lines = (0..<topFrames).map(line)
        let below = topFrames..<stack.count
        let ownBelow = below.filter { parse(stack[$0])?.module == ownModule }.prefix(ownFrames)
        let elided = below.count - ownBelow.count
        if elided > 0 {
            lines.append("\u{2026}\t\(elided) frame\(elided == 1 ? "" : "s") elided")
        }
        lines.append(contentsOf: ownBelow.map(line))
        return lines
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
/// `evaluate(nowUptime:pingPostedUptime:lastAckUptime:)` is called once per watchdog tick and
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
    ///   - pingPostedUptime: when the outstanding ping was posted, or nil once
    ///     acknowledged. Time when the watchdog posted no ping is never a stall.
    ///   - lastAckUptime: used only to end an episode at main's actual reply,
    ///     even if the watchdog does not get CPU again until much later.
    mutating func evaluate(
        nowUptime: Double, pingPostedUptime: Double?, lastAckUptime: Double
    ) -> Decision {
        let gapMs = pingPostedUptime.map { max(0, (nowUptime - $0) * 1000.0) } ?? 0

        if gapMs >= stallThresholdMs {
            if !inEpisode {
                inEpisode = true
                episodeStartUptime = pingPostedUptime!
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
            let durationMs = max(0, (lastAckUptime - episodeStartUptime) * 1000.0)
            return .recovered(durationMs: durationMs)
        }
        return .none
    }

    /// Test-only introspection into episode state.
    var isInEpisode: Bool { inEpisode }
}

/// C11H-238: one ended main-thread stall, as the `main.stall` event carries it.
struct MainThreadStall: Equatable {
    let durationMs: Int
    let cause: String
    let appActive: Bool
    let visible: Bool
    let panelCount: Int
    /// hc inventory snapshots the app received in the ten seconds before the end.
    let hcSnapshots10s: Int
    /// The latest the watchdog itself woke during the stall (0: on time).
    let watchdogLateMs: Int

    var payload: [String: Any] {
        ["duration_ms": durationMs, "cause": cause, "active": appActive, "visible": visible,
         "panel_count": panelCount, "hc_events_10s": hcSnapshots10s, "watchdog_late_ms": watchdogLateMs,
         "watchdog_late": watchdogLateMs > Int(MainThreadWatchdogLateness.thresholdMs)]
    }
}

/// Watchdog-thread-only rate limiter. A starving watchdog can wake late on
/// every tick; preserve a count and maximum without writing a line per wakeup.
struct MainThreadWatchdogLateness {
    private var lastLogUptime: Double?
    private var count = 0
    private var maximumMs: Double = 0

    /// A wake this late is the watchdog's own starvation, reported on its own
    /// line (`watchdog.late`) and flagged on any capture it delays.
    static let thresholdMs: Double = 1000

    mutating func record(nowUptime: Double, lateMs: Double) -> String? {
        guard lateMs > Self.thresholdMs else { return nil }
        count += 1
        maximumMs = max(maximumMs, lateMs)
        if let lastLogUptime, nowUptime - lastLogUptime < 60 { return nil }
        let line = "watchdog.late lateMs=\(Int(lateMs)) count=\(count) maxLateMs=\(Int(maximumMs))"
        lastLogUptime = nowUptime
        count = 0
        maximumMs = 0
        return line
    }
}

/// Everything with main suspended runs at interactive QoS. The buffer borrow
/// and all closure construction happen before this call. No allocation, logging
/// or symbolication is permitted in `read`; the production reader is the C
/// unwinder. Operations are injectable so failure exits exercise this same scope.
enum MainThreadHangCapture {
    static func capture(
        thread: thread_t,
        buffer: UnsafeMutableBufferPointer<UInt>,
        setQoS: (qos_class_t, Int32) -> Int32 = pthread_set_qos_class_self_np,
        suspend: (thread_t) -> kern_return_t = thread_suspend,
        resume: (thread_t) -> kern_return_t = thread_resume,
        read: (thread_t, UnsafeMutablePointer<UInt>?, Int32) -> Int32 = c11_capture_thread_backtrace
    ) -> Int {
        // Failure to promote must never lead to suspending main at background QoS.
        guard setQoS(QOS_CLASS_USER_INTERACTIVE, 0) == 0 else { return -2 }
        // Back to the watchdog's own class (C11H-238), never below it.
        defer { _ = setQoS(MainThreadHangMonitor.watchdogQoS, 0) }
        guard suspend(thread) == KERN_SUCCESS else { return -1 }
        // LIFO: main resumes before the watchdog gives up its priority, even
        // when thread_get_state fails and the reader returns zero frames.
        defer { _ = resume(thread) }
        return Int(read(thread, buffer.baseAddress, Int32(buffer.count)))
    }
}

/// One report per episode. Idle stacks only qualify after 30 seconds; ordinary
/// hangs retain the existing five-second threshold. Recovery uses the same gate
/// so a 31-second episode ending between captures is not lost or sent twice.
struct MainThreadHangReportGate {
    private(set) var reported = false

    mutating func shouldReport(durationMs: Double, cause: String) -> Bool {
        guard !reported else { return false }
        let eligible = cause == MainThreadHangSignature.runLoopIdleCause
            ? durationMs > 30_000 : durationMs >= 5_000
        guard eligible else { return false }
        reported = true
        return true
    }
}

/// Whether a human was in a position to see a stall.
///
/// Sampled on the main thread from AppKit notifications and read by the watchdog
/// while main is wedged — AppKit is main-thread-only, and the value wanted is
/// precisely the last one main managed to publish before it stopped answering.
///
/// Rides along as the `hang.app_active` / `hang.window_visible` tags and in the
/// local log header: a stall behind an occluded window and one under the
/// operator's cursor are different bugs with identical stacks. It does not gate
/// reporting: which cause a capture is, not who was looking, decides that.
struct AppVisibility: Equatable {
    let appIsActive: Bool
    let hasVisibleWindow: Bool

    static let unwatched = AppVisibility(appIsActive: false, hasVisibleWindow: false)
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
    /// Watchdog-thread-only: has this episode already produced a Sentry event?
    private var reportGate = MainThreadHangReportGate()
    /// Retain an idle capture until recovery so the >30s rule also covers a
    /// recovery between recaptures. Allocated only after main has resumed.
    private var idleCapture: (stack: [String], signature: MainThreadHangDescriptor, visibility: AppVisibility)?
    private var lateness = MainThreadWatchdogLateness()
    /// Watchdog-thread-only: cross-episode memory, so a run of short stalls
    /// sharing one cause is reported before the wedge it predicts arrives.
    private var precursorTracker = HangPrecursorTracker()
    /// Watchdog-thread-only: how the current episode was classified at
    /// detection. Recovery needs the fingerprint, and only `handleHang` sees it.
    private var currentEpisodeSignature: MainThreadHangDescriptor?
    /// Watchdog-thread-only: the latest wake of this episode's watchdog, and
    /// the visibility at its first capture, for `main.stall`.
    private var episodeWatchdogLateMs: Double = 0
    private var episodeVisibility: AppVisibility = .unwatched
    /// Where `main.stall` goes. The default is the events stream; tests replace it.
    var stallSink: (MainThreadStall) -> Void = { stall in
        EventEmitter.shared.emitMainStall(stall)
    }

    private let lock = NSLock()
    private var lastAckUptime: TimeInterval = 0
    private var pingPostedUptime: TimeInterval?
    /// Written on main from AppKit notifications, read by the watchdog thread.
    private var visibility: AppVisibility = .unwatched

    private var mainThread: thread_t = mach_port_t(MACH_PORT_NULL)
    private var installed = false

    /// Reused address buffer for stack capture. Preallocated once so no heap
    /// allocation ever happens inside the `thread_suspend`/`thread_resume` window
    /// — a `malloc` there would deadlock if the suspended main thread holds the
    /// malloc lock. Only ever touched on the watchdog thread, which captures
    /// serially, so the single shared buffer is safe.
    private var frameBuffer: [UInt]

    /// Size-capped writer for the local hang log. A sustained stall emits a
    /// 96-frame symbolicated backtrace every 5 s (~23 MB/min measured), so the
    /// log needs a ceiling or a multi-hour wedge eats the operator's disk
    /// (C11-220: one wedge left a 238 MB file behind). Watchdog-thread-only.
    private var hangLog: HangLogRotator

    private init() {
        frameBuffer = [UInt](repeating: 0, count: maxFrames)
        hangLog = HangLogRotator(
            logURL: Self.resolveLogURL(),
            capBytes: Self.logCapBytes
        )
    }

    /// 32 MiB per file. With two archived generations the hang log's total
    /// on-disk footprint stays under ~96 MiB.
    static let logCapBytes = 32 * 1024 * 1024

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
        observeVisibility()

        let thread = Thread { [weak self] in self?.runLoop() }
        thread.name = "com.stage11.c11.hang-monitor"
        // C11H-238: at background QoS the watchdog was starved for 15-25 s
        // under load and recorded no stack for the stall it existed to see.
        thread.qualityOfService = Self.watchdogThreadQoS
        thread.stackSize = 512 * 1024
        thread.start()
        Self.scheduleForcedStall(ProcessInfo.processInfo.environment)
    }

    /// The watchdog's class: high enough to run while main and every core are
    /// busy, below the user-interactive class the capture borrows.
    static let watchdogQoS = QOS_CLASS_USER_INITIATED
    static let watchdogThreadQoS: QualityOfService = .userInitiated

    /// C11H-238 proof seam: `C11_FORCE_MAIN_STALL=<delay>:<stall>` blocks
    /// main once, `stall` seconds starting `delay` seconds after install (each
    /// 1-30). Read once; any other value does nothing.
    static func forcedStall(_ env: [String: String]) -> (delay: Double, stall: Double)? {
        guard let raw = env["C11_FORCE_MAIN_STALL"] else { return nil }
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts.allSatisfy({ $0.isFinite && (1...30).contains($0) }) else { return nil }
        return (parts[0], parts[1])
    }

    private static func scheduleForcedStall(_ env: [String: String]) {
        guard let plan = forcedStall(env) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.delay) {
            Thread.sleep(forTimeInterval: plan.stall)
        }
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

    // MARK: Visibility

    /// Track "is a human looking at this window" on the main thread. Occlusion
    /// covers the case AppKit activation misses: a frontmost app whose windows
    /// are all behind something else.
    private func observeVisibility() {
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            center.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in self?.refreshVisibility() }
        }
        refreshVisibility()
    }

    /// Main thread only.
    private func refreshVisibility() {
        let app = NSApplication.shared
        let snapshot = AppVisibility(
            appIsActive: app.isActive,
            hasVisibleWindow: app.windows.contains {
                $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
            }
        )
        lock.lock(); visibility = snapshot; lock.unlock()
    }

    // MARK: Watchdog loop (runs on the background thread)

    private func runLoop() {
        let tick = tickIntervalMs / 1000.0
        #if DEBUG
        // Explicit test launch only. A normal Debug launch and every Release
        // launch ignore this seam. Delay tick two so main first acks a real ping.
        let env = ProcessInfo.processInfo.environment
        var oversleep = env["C11_HANG_TEST_OVERSLEEP_SECONDS"].flatMap(Double.init) ?? 0
        if env["C11_HANG_TESTING"] != "1" || !oversleep.isFinite || !(1...300).contains(oversleep) {
            oversleep = 0
        }
        var ticks = 0
        #endif
        while true {
            let expectedWake = ProcessInfo.processInfo.systemUptime + tick
            Thread.sleep(forTimeInterval: tick)
            #if DEBUG
            ticks += 1
            if ticks == 2, oversleep > 0 { Thread.sleep(forTimeInterval: oversleep) }
            #endif
            // This thread never exits, so its root pool never drains; each hang
            // capture symbolicates and writes the log from here (C11-211).
            autoreleasepool {
                let wake = ProcessInfo.processInfo.systemUptime
                let lateMs = max(0, (wake - expectedWake) * 1000)
                if let line = lateness.record(nowUptime: wake, lateMs: lateMs) {
                    appendToLog("=== c11 \(line) \(Self.timestamp()) pid=\(getpid()) ===\n")
                }
                sendHeartbeat()

                let now = ProcessInfo.processInfo.systemUptime
                lock.lock()
                let ping = pingPostedUptime
                let ack = lastAckUptime
                lock.unlock()

                switch detector.evaluate(nowUptime: now, pingPostedUptime: ping, lastAckUptime: ack) {
                case .none:
                    if detector.isInEpisode { episodeWatchdogLateMs = max(episodeWatchdogLateMs, lateMs) }
                case .capture(let gapMs, let recapture):
                    handleHang(gapMs: gapMs, recapture: recapture, watchdogLateMs: lateMs)
                case .recovered(let durationMs):
                    // The recovery tick's own lateness belongs to the episode too.
                    episodeWatchdogLateMs = max(episodeWatchdogLateMs, lateMs)
                    handleRecovery(durationMs: durationMs)
                }
            }
        }
    }

    /// Post a heartbeat the main thread will acknowledge. While main is wedged the
    /// previous ping's posting time stays fixed. When the watchdog oversleeps
    /// after an ack, its next ping starts at age zero, not at the old ack time.
    private func sendHeartbeat() {
        lock.lock()
        if pingPostedUptime != nil { lock.unlock(); return }
        pingPostedUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.lock.lock()
            self.lastAckUptime = now
            self.pingPostedUptime = nil
            self.lock.unlock()
        }
    }

    // MARK: Hang handling

    private func handleHang(gapMs: Double, recapture: Bool, watchdogLateMs: Double) {
        if !recapture {
            reportGate = MainThreadHangReportGate()
            idleCapture = nil
            currentEpisodeSignature = nil
        }
        let stack = captureMainBacktrace()
        let kind = recapture ? "hang.persist" : "hang.begin"
        // `processName` is the "own binary" match for culprit extraction: it
        // equals the Mach-O image name `backtrace_symbols` reports for both the
        // shipped bundle (`c11`) and dev builds (`c11 DEV`). Best-effort anyway —
        // absent whenever the capture window never reaches our code — so a
        // mismatch degrades to no tag.
        let signature = MainThreadHangSignature.describe(
            stack: stack,
            ownModule: ProcessInfo.processInfo.processName
        )
        // The classification at detection is the episode's identity for
        // cross-episode matching: a recapture may land in a different frame of
        // the same wedge, and a run keyed on the moving classification would
        // never accumulate.
        if !recapture { currentEpisodeSignature = signature }
        lock.lock(); let visibility = self.visibility; lock.unlock()
        if !recapture { episodeVisibility = visibility; episodeWatchdogLateMs = 0 }
        episodeWatchdogLateMs = max(episodeWatchdogLateMs, watchdogLateMs)

        if signature.cause == MainThreadHangSignature.runLoopIdleCause {
            idleCapture = (stack, signature, visibility)
        }

        var lines: [String] = []
        // The header carries the classification so a forensic pass over months of
        // log does not have to re-derive it from the frames.
        lines.append(
            "=== c11 \(kind) \(Self.timestamp()) stalledMs=\(Int(gapMs)) pid=\(getpid()) "
                + "cause=\(signature.label) active=\(visibility.appIsActive ? 1 : 0) "
                + "visible=\(visibility.hasVisibleWindow ? 1 : 0) watchdogLateMs=\(Int(watchdogLateMs)) "
                + "watchdogLate=\(watchdogLateMs > MainThreadWatchdogLateness.thresholdMs ? 1 : 0) ==="
        )
        if stack.isEmpty {
            lines.append("  <no backtrace captured>")
        } else {
            for (i, frame) in stack.enumerated() {
                lines.append(String(format: "  %2d  %@", i, frame))
            }
        }
        lines.append("")
        appendToLog(lines.joined(separator: "\n") + "\n")

        reportTelemetry(
            gapMs: gapMs,
            recapture: recapture,
            stack: stack,
            signature: signature,
            visibility: visibility
        )
    }

    private func handleRecovery(durationMs: Double) {
        if let idleCapture {
            reportHangToSentry(
                gapMs: durationMs, recapture: false, stack: idleCapture.stack,
                signature: idleCapture.signature, visibility: idleCapture.visibility
            )
        }
        idleCapture = nil
        reportGate = MainThreadHangReportGate()
        let dropped = SentryEventBudgetGate.shared.dropped
        // `hang.end` closes an episode, so it is the cheapest place to rotate a
        // log that has grown past the soft cap without splitting a timeline.
        appendToLog(
            "=== c11 hang.end \(Self.timestamp()) totalMs=\(Int(durationMs)) pid=\(getpid()) "
                + "sentrySuppressed=\(dropped.hangs)/\(dropped.total) ===\n\n",
            episodeBoundary: true
        )

        let signature = currentEpisodeSignature
        currentEpisodeSignature = nil
        // C11H-238: every stall reaches the events stream, built here on the
        // watchdog thread from lock-protected counters; main is never asked.
        let now = ProcessInfo.processInfo.systemUptime
        stallSink(MainThreadStall(durationMs: Int(durationMs), cause: signature?.label ?? "unknown",
            appActive: episodeVisibility.appIsActive, visible: episodeVisibility.hasVisibleWindow,
            panelCount: HCLoadMeter.shared.panelCount,
            hcSnapshots10s: HCLoadMeter.shared.snapshotsLast10s(nowUptime: now),
            watchdogLateMs: Int(episodeWatchdogLateMs)))
        episodeWatchdogLateMs = 0
        guard let signature else { return }
        let precursor = precursorTracker.record(
            fingerprint: signature.fingerprint,
            cause: signature.cause,
            culprit: signature.culprit,
            durationMs: durationMs,
            nowUptime: ProcessInfo.processInfo.systemUptime
        )
        if let precursor { reportPrecursor(precursor) }
    }

    // MARK: Precursor

    /// Fan one precursor out to the three places a wedge warning has to reach:
    /// the local log (always, never leaves the machine), the events stream (so a
    /// watching agent or dashboard can react while the machine is still usable),
    /// and Sentry (so the population is visible across installs).
    ///
    /// Watchdog thread. Every sink here is non-blocking and off-main by
    /// construction: `appendToLog` writes a file, `EventEmitter` is
    /// any-thread fire-and-forget, and the Sentry capture is the same call the
    /// per-episode path already makes from this thread.
    private func reportPrecursor(_ precursor: HangPrecursorTracker.Precursor) {
        let durations = precursor.durationsMs.map(String.init).joined(separator: ",")
        appendToLog(
            "=== c11 hang.precursor \(Self.timestamp()) pid=\(getpid()) "
                + "cause=\(precursor.cause) count=\(precursor.count) "
                + "windowMs=\(precursor.windowMs) spanMs=\(precursor.spanMs) "
                + "durationsMs=[\(durations)] "
                + "fingerprint=\(precursor.fingerprint.joined(separator: "/")) "
                + "culprit=\(precursor.culprit ?? "-") ===\n\n"
        )

        EventEmitter.shared.emitHangPrecursor(
            cause: precursor.cause,
            culprit: precursor.culprit,
            count: precursor.count,
            windowMs: precursor.windowMs,
            spanMs: precursor.spanMs,
            durationsMs: precursor.durationsMs,
            fingerprint: precursor.fingerprint
        )

        // Same fingerprint as the per-episode reports, deliberately: the
        // precursor belongs in the issue for the cause it predicts, not in one
        // of its own. `hang.precursor` separates the two inside that issue.
        // Category `hang` routes it through the one budget gate in `beforeSend`;
        // charging it here as well would spend two slots on one event.
        var tags = [
            "hang.cause": precursor.cause,
            "hang.precursor": "true",
            "hang.precursor_count": String(precursor.count),
        ]
        tags["hang.culprit"] = precursor.culprit
        sentryCaptureWarning(
            "main thread hang precursor (\(precursor.cause) x\(precursor.count))",
            category: sentryHangCategory,
            data: [
                "count": precursor.count,
                "window_ms": precursor.windowMs,
                "span_ms": precursor.spanMs,
                "durations_ms": precursor.durationsMs,
            ],
            contextKey: "hang_precursor",
            fingerprint: precursor.fingerprint,
            tags: tags
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
        let frameCount = frameBuffer.withUnsafeMutableBufferPointer { buffer in
            MainThreadHangCapture.capture(thread: mainThread, buffer: buffer)
        }
        if frameCount == -2 { return ["<watchdog QoS promotion failed>"] }
        if frameCount == -1 { return ["<thread_suspend failed>"] }

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

    private func reportTelemetry(
        gapMs: Double,
        recapture: Bool,
        stack: [String],
        signature: MainThreadHangDescriptor,
        visibility: AppVisibility
    ) {
        reportHangToSentry(
            gapMs: gapMs, recapture: recapture, stack: stack, signature: signature, visibility: visibility
        )
        PostHogAnalytics.shared.captureMainThreadHang(
            stalledMs: gapMs,
            recapture: recapture,
            topFrame: stack.first ?? "",
            cause: signature.label
        )
    }

    private func reportHangToSentry(
        gapMs: Double, recapture: Bool, stack: [String],
        signature: MainThreadHangDescriptor, visibility: AppVisibility
    ) {
        if reportGate.shouldReport(durationMs: gapMs, cause: signature.cause) {
            let top = MainThreadHangSignature
                .reportedStack(stack, ownModule: ProcessInfo.processInfo.processName)
                .joined(separator: "\n")
            var tags = ["hang.cause": signature.cause, "hang.recapture": recapture ? "true" : "false"]
            tags["hang.phase"] = signature.phase
            tags["hang.culprit"] = signature.culprit
            tags["hang.top_symbol"] = signature.topSymbol
            // Was anyone in a position to see it? A stall behind an occluded
            // window and a stall under the operator's cursor are different bugs
            // with identical stacks.
            tags["hang.app_active"] = visibility.appIsActive ? "true" : "false"
            tags["hang.window_visible"] = visibility.hasVisibleWindow ? "true" : "false"
            // The duration is not the grouping key, so it does not belong in
            // the title: the message names the cause and `stalled_ms` stays in
            // the event context.
            sentryCaptureWarning(
                "main thread hang (\(signature.label))",
                category: sentryHangCategory,
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
    }

    /// Precursor eligibility is unchanged: repeated short idle heartbeats do
    /// not predict a wedge. Long idle episodes use MainThreadHangReportGate.
    static func isWorthReporting(cause: String) -> Bool {
        cause != MainThreadHangSignature.runLoopIdleCause
    }

    // MARK: Local log

    /// Watchdog-thread-only, like every other capture-path mutation here: both
    /// call sites (`handleHang`, `handleRecovery`) run inside `runLoop`, so the
    /// rotator needs no lock. Runs after `thread_resume`, never inside the
    /// suspend window.
    private func appendToLog(_ text: String, episodeBoundary: Bool = false) {
        hangLog.append(text, episodeBoundary: episodeBoundary)
    }

    private static func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    /// Mirrors the debug-log path conventions: an explicit override wins, then a
    /// tag-derived path in c11's per-user folder for tagged dev builds,
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
            return URL(fileURLWithPath: C11UserRuntime.logPath("c11-hang-\(slug).log"))
        }

        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(C11Identity.logsDirectoryName)", isDirectory: true)
        return logs.appendingPathComponent("hang.log")
    }
}

/// Append-only writer for the hang log that keeps the file, and the whole
/// on-disk set, under a fixed ceiling.
///
/// Sizing is tracked in memory: the file is measured **once**, lazily, on the
/// first append of the process, and thereafter kept current from the offset
/// `seekToEnd()` already returns. There is no `stat` per append — the writer
/// runs on the watchdog thread, which is also the thread that just walked a
/// wedged main thread, and a stall can drive it several times a second.
///
/// Rotation is deliberately two-tiered. `hang.begin` / `hang.persist` /
/// `hang.end` form an *episode*, and splitting one across two files makes a
/// forensic read harder, so a log that has merely crossed the soft cap waits
/// for the closing `hang.end` to rotate. A single episode that would push the
/// file past the hard cap on its own rotates immediately: bounding the disk
/// wins over keeping a timeline whole, which is the entire point of the cap.
///
/// Nothing here throws or traps. Every filesystem call is best-effort; if the
/// archive rename fails the current file is truncated in place instead, so a
/// read-only or full parent directory degrades to "log stops growing" rather
/// than "log grows forever".
struct HangLogRotator {

    /// Measures an existing file, in bytes. Zero when absent or unreadable.
    typealias SizeProbe = (URL) -> Int

    let logURL: URL
    /// Hard ceiling for one file. A nonpositive cap disables rotation entirely.
    let capBytes: Int
    /// How many archived generations to keep (`hang.log.1` … `hang.log.<n>`).
    let generations: Int

    private let timestamp: () -> String
    private let sizeProbe: SizeProbe

    /// `nil` until the one-shot probe runs.
    private var trackedSize: Int?

    init(
        logURL: URL,
        capBytes: Int,
        generations: Int = 2,
        timestamp: @escaping () -> String = HangLogRotator.defaultTimestamp,
        sizeProbe: @escaping SizeProbe = HangLogRotator.fileSize
    ) {
        self.logURL = logURL
        self.capBytes = capBytes
        self.generations = max(generations, 0)
        self.timestamp = timestamp
        self.sizeProbe = sizeProbe
    }

    /// Bytes currently accounted to the live log file. Exposed so a caller (and
    /// the tests) can observe the accounting without paying for a `stat`.
    var currentSize: Int { trackedSize ?? 0 }

    /// The point past which a closing record triggers rotation. Three quarters
    /// of the cap: low enough that most episodes end in the file they started
    /// in, high enough that the file is mostly full when it rotates.
    var softCapBytes: Int { capBytes - capBytes / 4 }

    /// Append `text`, rotating first (or afterwards) as the caps require.
    ///
    /// - Parameter episodeBoundary: true only for the record that closes a hang
    ///   episode (`hang.end`), the point where rotation costs no continuity.
    mutating func append(_ text: String, episodeBoundary: Bool = false) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }

        let size = ensureSize()

        guard capBytes > 0 else {
            write(data)
            return
        }

        if size > 0, size + data.count > capBytes {
            // Hard cap. Rotate before writing, even mid-episode.
            rotate()
            write(data)
            return
        }

        write(data)

        if episodeBoundary, currentSize >= softCapBytes {
            // Soft cap. The episode is complete, so the next one starts clean.
            rotate()
        }
    }

    // MARK: Internals

    private mutating func ensureSize() -> Int {
        if let trackedSize { return trackedSize }
        let measured = sizeProbe(logURL)
        trackedSize = measured
        return measured
    }

    private mutating func write(_ data: Data) {
        // Opened no-follow, owner and single-link checked, so a planted link
        // is never appended to or measured (C11H-364 L21).
        var descriptor = C11UserRuntime.openLogForAppend(logURL.path)
        if descriptor == nil {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            descriptor = C11UserRuntime.openLogForAppend(logURL.path)
        }
        guard let descriptor else { return }
        defer { Darwin.close(descriptor) }
        // `lseek` is not a stat, and it keeps the tracked size honest even if
        // something else appended to the file.
        let end = lseek(descriptor, 0, SEEK_END)
        guard end >= 0, C11UserRuntime.writeAll(descriptor, data) else { return }
        trackedSize = Int(clamping: end) + data.count
    }

    /// Shift the generations down, archive the live log, and open a fresh one
    /// carrying a header that records the rotation.
    private mutating func rotate() {
        let fm = FileManager.default
        let base = logURL.path
        // A log that predates the cap (or that some other writer inflated) is
        // discarded rather than archived, so an oversized file can never sit in
        // the generation set and blow the footprint bound.
        let archivable = generations >= 1 && !(capBytes > 0 && currentSize > capBytes)

        if archivable {
            try? fm.removeItem(atPath: "\(base).\(generations)")
            var index = generations - 1
            while index >= 1 {
                let from = "\(base).\(index)"
                let to = "\(base).\(index + 1)"
                if fm.fileExists(atPath: from) {
                    try? fm.removeItem(atPath: to)
                    try? fm.moveItem(atPath: from, toPath: to)
                }
                index -= 1
            }
        }

        var previous = "none"
        if fm.fileExists(atPath: base) {
            if archivable {
                let archive = "\(base).1"
                try? fm.removeItem(atPath: archive)
                if (try? fm.moveItem(atPath: base, toPath: archive)) != nil {
                    previous = URL(fileURLWithPath: archive).lastPathComponent
                } else {
                    previous = truncateInPlace() ? "truncated" : "rotation-failed"
                }
            } else {
                try? fm.removeItem(atPath: base)
                previous = fm.fileExists(atPath: base)
                    ? (truncateInPlace() ? "truncated" : "rotation-failed")
                    : "discarded"
            }
        }

        trackedSize = 0
        write(Data(
            ("=== c11 hang.rotated \(timestamp()) previous=\(previous) "
                + "capBytes=\(capBytes) ===\n\n").utf8
        ))
    }

    /// Last resort when the live log cannot be renamed away: zero it in place so
    /// it stops growing. Returns whether the truncate landed.
    private func truncateInPlace() -> Bool {
        guard let descriptor = C11UserRuntime.openLogForAppend(logURL.path) else { return false }
        defer { Darwin.close(descriptor) }
        return ftruncate(descriptor, 0) == 0
    }

    // MARK: Defaults

    /// The log's own size (`lstat`): a link is never measured as its target.
    static func fileSize(_ url: URL) -> Int {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return 0 }
        return max(Int(info.st_size), 0)
    }

    static func defaultTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

// MARK: - Graph churn meter (C11H-238)

/// C11H-238 diagnostic seam: counts what dirties the window's SwiftUI graph.
///
/// Off unless the app is launched with `C11_GRAPH_CHURN=<seconds>` (1-600),
/// read once. Off, every `note` is one load of a static `Bool` and nothing is
/// observed. On, it counts named sources (call sites that publish to objects the
/// root and sidebar observe), every `objectWillChange` of each live workspace,
/// the notification store and the workspace managers, root hosting-view layout
/// passes and their main-thread time, and portal full syncs. Main only bumps
/// counters under a lock; every period a utility queue formats one line of
/// per-second rates, with the window's visibility, and appends it to
/// `C11_GRAPH_CHURN_LOG`, default `~/Library/Logs/c11/graph-churn.log`.
@MainActor
enum GraphChurnMeter {
    enum Source: String, CaseIterable {
        case journalSnapshot = "journal_snapshot"
        case portScanWrite = "port_scan_write"
        case statusWrite = "status_write"
        case progressWrite = "progress_write"
        case logWrite = "log_write"
        case metadataSend = "metadata_send"
        case attentionWrite = "attention_write"
        case sidebarMarkTick = "sidebar_mark_tick"
        case hiddenWrapperUpdate = "hidden_wrapper_update"
        case portalFullSync = "portal_full_sync"
        case rootLayout = "root_layout"
        case workspaceWillChange = "workspace_will_change"
        case notificationsWillChange = "notifications_will_change"
        case managerWillChange = "manager_will_change"
        case focusHistoryWillChange = "focus_history_will_change"
        case themeWillChange = "theme_will_change"
        case attentionIndexWillChange = "attention_index_will_change"
        case windowAttributesWillChange = "window_attributes_will_change"
        case sidebarStateWillChange = "sidebar_state_will_change"
        case sidebarSelectionWillChange = "sidebar_selection_will_change"
        case defaultsDidChange = "defaults_did_change"
        case appBody = "app_body"
        case appManagerWillChange = "app_manager_will_change"
        case appSidebarWillChange = "app_sidebar_will_change"
        case appSelectionWillChange = "app_selection_will_change"
        case appNotificationsWillChange = "app_notifications_will_change"
        case appFocusHistoryWillChange = "app_focus_history_will_change"
        case contentViewBody = "content_view_body"
        case updateModelWillChange = "update_model_will_change"
        /// C11H-278: one description age label's body evaluation.
        case descriptionAgeBody = "description_age_body"
        /// C11H-296: one evaluation of the sidebar's workspace list body, which
        /// rebuilds every card's agent rows.
        case sidebarListBody = "sidebar_list_body"
    }

    nonisolated static let period: TimeInterval? = {
        guard let raw = ProcessInfo.processInfo.environment["C11_GRAPH_CHURN"],
              let seconds = Double(raw), seconds.isFinite, (1...600).contains(seconds) else { return nil }
        return seconds
    }()

    nonisolated static let isEnabled: Bool = period != nil

    /// Counters are noted from main-thread call sites that are not all
    /// actor-isolated (socket `v2MainSync` closures), so they sit behind a lock.
    private struct Tally {
        var counts: [Source: Int] = [:]
        var rootLayoutSeconds: TimeInterval = 0
    }
    nonisolated private static let tally = OSAllocatedUnfairLock(initialState: Tally())
    private static var observed: Set<ObjectIdentifier> = []
    private static var cancellables: [ObjectIdentifier: AnyCancellable] = [:]
    /// Aggregation, formatting and file output run here, never on main.
    nonisolated private static let queue = DispatchQueue(label: "c11.graph-churn", qos: .utility)
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    /// Touched only on `queue`.
    nonisolated(unsafe) private static var windowStart = ProcessInfo.processInfo.systemUptime
    /// Window state, noted on main by `WindowVisibilityGate`; read on `queue`.
    private struct Visibility {
        var active = true; var visible = true; var workspaces = 0
        /// The activity-mark clock, any renderer (sidebar and tab strips):
        /// subscribers and whether its timer runs, read on main each period.
        var clockSubscribers = 0; var clockTicking = false
    }
    nonisolated private static let visibility = OSAllocatedUnfairLock(initialState: Visibility())

    /// `_printChanges` on the root, sidebar and workspace bodies writes
    /// synchronously; only `C11_GRAPH_CHURN_PRINT=1` turns it on, never in a
    /// measured run.
    nonisolated static let printsChanges: Bool =
        isEnabled && ProcessInfo.processInfo.environment["C11_GRAPH_CHURN_PRINT"] == "1"

    nonisolated static func noteVisibility(active: Bool, visible: Bool) {
        guard isEnabled else { return }
        visibility.withLock { $0.active = active; $0.visible = visible }
    }

    @inline(__always)
    nonisolated static func note(_ source: Source, _ count: Int = 1) {
        guard isEnabled else { return }
        tally.withLock { $0.counts[source, default: 0] += count }
    }

    @inline(__always)
    nonisolated static func noteRootLayout(seconds: TimeInterval) {
        guard isEnabled else { return }
        tally.withLock {
            $0.counts[.rootLayout, default: 0] += 1
            $0.rootLayoutSeconds += seconds
        }
    }

    /// Starts the period timer. Called once at launch; a no-op when off.
    static func startIfEnabled() {
        guard let period, timer == nil else { return }
        if printsChanges {
            // `_printChanges` writes with `print`; a file-backed stdout would
            // hold it in a block buffer until exit.
            setvbuf(stdout, nil, _IOLBF, 0)
        }
        attachObservers()
        queue.async {
            windowStart = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + period, repeating: period)
            timer.setEventHandler { flush() }
            timer.resume()
            self.timer = timer
        }
    }

    private static var observedPairs: Set<String> = []
    private static var pairCancellables: [String: AnyCancellable] = [:]

    private static func observe<P: Publisher>(_ id: ObjectIdentifier, _ publisher: P, as source: Source)
        where P.Failure == Never {
        guard observed.insert(id).inserted else { return }
        cancellables[id] = publisher.sink { _ in note(source) }
    }

    /// The app struct's own state objects, counted under their own names even
    /// when they are the same instances the window contexts hold.
    static func observeAppObjects(manager: WorkspaceManager, sidebar: SidebarState, selection: SidebarSelectionState,
                                  notifications: TerminalNotificationStore, focusHistory: FocusHistoryStore) {
        guard isEnabled else { return }
        func pair<P: Publisher>(_ object: AnyObject, _ publisher: P, _ source: Source) where P.Failure == Never {
            let key = "\(ObjectIdentifier(object).hashValue)-\(source.rawValue)"
            guard observedPairs.insert(key).inserted else { return }
            pairCancellables[key] = publisher.sink { _ in note(source) }
        }
        pair(manager, manager.objectWillChange, .appManagerWillChange)
        pair(sidebar, sidebar.objectWillChange, .appSidebarWillChange)
        pair(selection, selection.objectWillChange, .appSelectionWillChange)
        pair(notifications, notifications.objectWillChange, .appNotificationsWillChange)
        pair(focusHistory, focusHistory.objectWillChange, .appFocusHistoryWillChange)
    }

    /// Picks up workspaces created since the last period.
    private static func attachObservers() {
        guard let app = AppDelegate.shared else { return }
        if let store = app.notificationStore {
            observe(ObjectIdentifier(store), store.objectWillChange, as: .notificationsWillChange)
        }
        for manager in app.liveWorkspaceManagersForDiagnostics() {
            observe(ObjectIdentifier(manager), manager.objectWillChange, as: .managerWillChange)
        }
        observe(ObjectIdentifier(FocusHistoryStore.shared), FocusHistoryStore.shared.objectWillChange,
                as: .focusHistoryWillChange)
        observe(ObjectIdentifier(ThemeManager.shared), ThemeManager.shared.objectWillChange, as: .themeWillChange)
        observe(ObjectIdentifier(PanelAttentionIndex.shared), PanelAttentionIndex.shared.objectWillChange,
                as: .attentionIndexWillChange)
        observe(ObjectIdentifier(WindowAttributesStore.shared), WindowAttributesStore.shared.objectWillChange,
                as: .windowAttributesWillChange)
        for (sidebar, selection) in app.sidebarStatesForDiagnostics() {
            observe(ObjectIdentifier(sidebar), sidebar.objectWillChange, as: .sidebarStateWillChange)
            observe(ObjectIdentifier(selection), selection.objectWillChange, as: .sidebarSelectionWillChange)
        }
        if let update = app.updateViewModelForDiagnostics() {
            observe(ObjectIdentifier(update), update.objectWillChange, as: .updateModelWillChange)
        }
        // Any instance: `@AppStorage` with a suite store writes through its own.
        observe(ObjectIdentifier(UserDefaults.self),
                NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification),
                as: .defaultsDidChange)
        for workspace in app.liveWorkspacesForDiagnostics() {
            observe(ObjectIdentifier(workspace), workspace.objectWillChange, as: .workspaceWillChange)
        }
        let count = observed.count
        let clock = BonsplitActivityAnimationClock.shared
        let subscribers = clock.subscriberCount, ticking = clock.isTicking
        visibility.withLock {
            $0.workspaces = count; $0.clockSubscribers = subscribers; $0.clockTicking = ticking
        }
    }

    /// On `queue`: snapshot the counters, format one line, append it.
    nonisolated private static func flush() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(0.001, now - windowStart)
        windowStart = now
        let taken = tally.withLock { current -> Tally in
            let snapshot = current
            current = Tally()
            return snapshot
        }
        let state = visibility.withLock { $0 }
        var fields = [
            "ts=\(ISO8601DateFormatter().string(from: Date()))",
            "seconds=\(String(format: "%.1f", elapsed))",
            "active=\(state.active ? 1 : 0)",
            "visible=\(state.visible ? 1 : 0)",
            "workspaces=\(state.workspaces)",
            "mark_clock_subscribers=\(state.clockSubscribers)",
            "mark_clock_ticking=\(state.clockTicking ? 1 : 0)",
            "root_layout_ms_per_s=\(String(format: "%.1f", taken.rootLayoutSeconds * 1000 / elapsed))",
        ]
        for source in Source.allCases {
            fields.append("\(source.rawValue)=\(String(format: "%.2f", Double(taken.counts[source] ?? 0) / elapsed))")
        }
        append(fields.joined(separator: " ") + "\n")
        // New workspaces since the last period: one short main hop to subscribe.
        DispatchQueue.main.async { MainActor.assumeIsolated { attachObservers() } }
    }

    nonisolated private static let logURL: URL = {
        if let path = ProcessInfo.processInfo.environment["C11_GRAPH_CHURN_LOG"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/\(C11Identity.logsDirectoryName)/graph-churn.log")
    }()

    nonisolated private static func append(_ line: String) {
        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
