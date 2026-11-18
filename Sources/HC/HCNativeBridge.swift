import Foundation

/// This context is retained independently of the panel and survives native free.
/// The C callback never accesses an NSView or waits for a task/queue to finish.
final class HCNativeInputContext: @unchecked Sendable {
    let rendering: any HCRenderingAdapter
    let report: @Sendable (HCInputOutcome) -> Void
    private let lock = NSLock()
    private var input: (any HCInputPort)?
    private var generation: UInt64 = 0

    init(rendering: any HCRenderingAdapter, report: @escaping @Sendable (HCInputOutcome) -> Void) {
        self.rendering = rendering
        self.report = report
    }

    func bind(input: any HCInputPort, generation: UInt64) {
        lock.lock()
        self.input = input
        self.generation = generation
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        let port = input, oldGeneration = generation
        input = nil
        lock.unlock()
        port?.invalidate(generation: oldGeneration, reason: .staleIdentity)
    }

    func receive(_ ptr: UnsafePointer<CChar>, count: Int) {
        rendering.noteRawInput(UnsafeRawPointer(ptr), count)
        lock.lock()
        let port = input, current = generation
        lock.unlock()
        guard let port else { report(.refused(.unavailable)); return }
        guard count <= HCLimits.transactionBytes else {
            port.invalidate(generation: current, reason: .inputFault)
            report(.refused(.tooLarge))
            report(.refused(.inputFault))
            return
        }
        // Programmatic paste never enters this unattributed callback. Until
        // native capture is proved it is rejected before calling native text.
        port.receiveRaw(Data(bytes: ptr, count: count), kind: .key, generation: current)
    }

    static let write: ghostty_io_write_cb = { userdata, ptr, count in
        guard let userdata, let ptr, count > 0 else { return }
        Unmanaged<HCNativeInputContext>.fromOpaque(userdata).takeUnretainedValue().receive(ptr, count: Int(count))
    }
}

/// The complete native IO tuple of a new surface. Splits inherit the native
/// config, callback pointers included, so every creation sets all of it.
/// C11H-363: an hc surface's output comes through hc, from this Mac or from
/// another machine, so its Kitty graphics accept only images sent inline:
/// never a path on this Mac (file, temporary-file or shared-memory media).
enum HCSurfaceNativeIO {
    static func apply(to config: inout ghostty_surface_config_s, hcInput userdata: UnsafeMutableRawPointer?) {
        if let userdata {
            config.io_mode = GHOSTTY_SURFACE_IO_MANUAL
            config.io_write_cb = HCNativeInputContext.write
            config.io_write_userdata = userdata
            config.kitty_graphics_direct_only = true
        } else {
            config.io_mode = GHOSTTY_SURFACE_IO_EXEC
            config.io_write_cb = nil
            config.io_write_userdata = nil
            config.kitty_graphics_direct_only = false
        }
    }
}

/// The output sink exists before attach. The first channel chunk can arrive
/// before the attach factory binds a generation; retain it within stream credit
/// and withhold consumption/credit until binding. No guessed generation.
final class HCNativeBridge: HCOutputSink, @unchecked Sendable {
    let panelID: UUID
    let context: HCNativeInputContext
    let rendering: any HCRenderingAdapter
    let encoder: any HCInputEncoder
    let displayChanged: @Sendable (HCDisplayState) -> Void
    let report: @Sendable (HCInputOutcome) -> Void
    private let lock = NSLock()
    private var lease: HCOutputLease?
    private var retired = false
    private var bound = false
    private var attachmentGeneration: UInt64?
    private var process: HCOutputLease.Process?
    private var destroy: (@MainActor @Sendable () -> Void)?
    private var removeFromUse: (@MainActor @Sendable () -> Void)?
    private let retirement = DispatchGroup()
    private var pending: [(HCOutputChunk, CheckedContinuation<HCOutputConsumption, Never>)] = []
    private var pendingBytes = 0
    private var draining = false

    init(panelID: UUID, rendering: any HCRenderingAdapter, encoder: any HCInputEncoder,
         report: @escaping @Sendable (HCInputOutcome) -> Void,
         displayChanged: @escaping @Sendable (HCDisplayState) -> Void = { _ in }) {
        self.panelID = panelID
        self.rendering = rendering
        self.encoder = encoder
        self.displayChanged = displayChanged
        self.report = report
        context = HCNativeInputContext(rendering: rendering, report: report)
        retirement.enter()
    }

    /// Called immediately after native creation, before any hc create/attach.
    @MainActor
    func installSurface(_ surface: ghostty_surface_t,
                        removeFromUse: @escaping @MainActor @Sendable () -> Void,
                        releaseCallbackContext: @escaping @MainActor @Sendable () -> Void) {
        let context = context
        installProcessor(process: { chunk in
            chunk.bytes.withUnsafeBytes { bytes in
                guard let ptr = bytes.baseAddress else { return }
                ghostty_surface_process_output(surface, ptr.assumingMemoryBound(to: CChar.self), UInt(bytes.count))
            }
        }, removeFromUse: removeFromUse, destroy: {
            ghostty_surface_free(surface)
            withExtendedLifetime(context) { releaseCallbackContext() }
        })
    }

    /// The native processor is injected here so lifecycle/IO ordering is
    /// executable in logic tests without constructing a WindowServer surface.
    @MainActor
    func installProcessor(process: @escaping HCOutputLease.Process,
                          removeFromUse: @escaping @MainActor @Sendable () -> Void,
                          destroy: @escaping @MainActor @Sendable () -> Void) {
        let rendering = rendering
        lock.lock()
        self.removeFromUse = removeFromUse
        self.process = { chunk in
            rendering.noteOutput(chunk)
            process(chunk)
            rendering.didParse(chunk)
        }
        self.destroy = destroy
        lock.unlock()
    }

    func prepare(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !retired, lease == nil, let process, let destroy else { return false }
        attachmentGeneration = generation
        lease = HCOutputLease(generation: generation, process: process, destroy: destroy)
        return true
    }

    func bind(generation: UInt64, input: any HCInputPort) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !retired, !bound, lease != nil, attachmentGeneration == generation else { return false }
        bound = true
        context.bind(input: input, generation: generation)
        startDrainLocked()
        return true
    }

    func consume(_ chunk: HCOutputChunk) async -> HCOutputConsumption {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !retired else { lock.unlock(); continuation.resume(returning: .stale); return }
            guard chunk.bytes.count <= HCLimits.initialCreditBytes - pendingBytes else {
                lock.unlock(); continuation.resume(returning: .failed(.bufferOverflow)); return
            }
            pending.append((chunk, continuation))
            pendingBytes += chunk.bytes.count
            startDrainLocked()
            lock.unlock()
        }
    }

    private func startDrainLocked() {
        guard bound, lease != nil, !pending.isEmpty, !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func takeNext() -> (HCOutputChunk, CheckedContinuation<HCOutputConsumption, Never>, HCOutputLease)? {
        lock.lock()
        defer { lock.unlock() }
        guard !retired, bound, let lease, let attachmentGeneration, !pending.isEmpty else { draining = false; return nil }
        let (chunk, continuation) = pending.removeFirst()
        pendingBytes -= chunk.bytes.count
        // The dormant transport channel is registered with the actual
        // attachment generation; no connection-generation restamping.
        guard chunk.attachmentGeneration == attachmentGeneration else {
            continuation.resume(returning: .stale)
            return takeNextAfterStaleLocked()
        }
        return (chunk, continuation, lease)
    }

    private func takeNextAfterStaleLocked() -> (HCOutputChunk, CheckedContinuation<HCOutputConsumption, Never>, HCOutputLease)? {
        // A fresh drain task handles any next chunk without recursively taking
        // the state lock. A normal channel delivers only one outstanding call.
        draining = false
        startDrainLocked()
        return nil
    }

    private func drain() async {
        while let (chunk, continuation, lease) = takeNext() {
            let outcome = await lease.consume(chunk)
            continuation.resume(returning: outcome)
        }
    }

    func retire(completion: @escaping @Sendable () -> Void) {
        context.invalidate()
        lock.lock()
        guard !retired else {
            lock.unlock()
            retirement.notify(queue: .global(qos: .userInitiated), execute: completion)
            return
        }
        retired = true
        let waiting = pending
        pending.removeAll()
        pendingBytes = 0
        let lease = lease
        let destroy = lease == nil ? self.destroy : nil
        let removeFromUse = self.removeFromUse
        self.destroy = nil
        lock.unlock()
        for (_, continuation) in waiting { continuation.resume(returning: .stale) }
        retirement.notify(queue: .global(qos: .userInitiated), execute: completion)
        // An attachment may detach off-main while a view still exists. Remove
        // the pointer from UI use on main BEFORE output retirement can free it.
        let retirement = retirement
        DispatchQueue.main.async {
            removeFromUse?()
            if let lease { lease.retire { retirement.leave() } }
            else { destroy?(); retirement.leave() }
        }
    }

    deinit { retire {} }
}


/// Main-thread synchronous capture; the returned buffers are owned by Swift.
/// Holding the complete queue reservation is HCInputCoordinator's responsibility.
final class HCNativePasteEncoder: HCInputEncoder, @unchecked Sendable {
    /// Native captures, injectable so the routing is testable without a surface.
    typealias PasteCapture = @MainActor (ghostty_surface_t, Data, Bool, Int) -> (body: Data, submit: Data)?
    typealias KeyCapture = @MainActor (ghostty_surface_t, HCKeyEventSpec, Int) -> Data?

    private let surface: @MainActor @Sendable () -> ghostty_surface_t?
    private let returnDelayNanoseconds: @MainActor @Sendable (HCInputSource) -> UInt64
    private let pasteCapture: PasteCapture
    private let keyCapture: KeyCapture
    init(surface: @escaping @MainActor @Sendable () -> ghostty_surface_t?,
         returnDelayNanoseconds: @escaping @MainActor @Sendable (HCInputSource) -> UInt64 = { _ in 0 },
         pasteCapture: @escaping PasteCapture = HCNativePasteEncoder.nativePaste,
         keyCapture: @escaping KeyCapture = HCNativePasteEncoder.nativeKey) {
        self.surface = surface
        self.returnDelayNanoseconds = returnDelayNanoseconds
        self.pasteCapture = pasteCapture
        self.keyCapture = keyCapture
    }

    private enum Plan {
        case paste
        case keys([HCKeyEventSpec])
    }

    /// An operator paste or drop is always pasted (C11H-362): Ghostty's paste
    /// encoder fences it when the program enabled bracketed paste and replaces
    /// its control bytes, as a native paste does. For programmatic sends, prose
    /// and multi-line text are pasted and keystroke-shaped text (control bytes)
    /// is encoded as keys. Nil when the text cannot be sent faithfully.
    private func plan(for request: HCInputRequest) -> Plan? {
        if request.source.isOperatorPaste { return .paste }
        let text = String(decoding: request.payload, as: UTF8.self)
        guard HCControlText.usesKeyEncoding(text) else { return .paste }
        return HCControlText.bodyEvents(for: text).map(Plan.keys)
    }

    func maximumEncodedBytes(for request: HCInputRequest) -> Int? {
        guard request.payload.count <= HCLimits.transactionBytes, let plan = plan(for: request) else { return nil }
        switch plan {
        case .paste:
            return request.payload.count * 2 + 280 + 18
        case .keys(let events):
            // Each wire frame carries a 9-byte header; the Return is a frame too.
            var total = events.reduce(0) { $0 + 9 + HCControlText.byteLimit(for: $1) }
            if request.submitReturn { total += 9 + HCControlText.byteLimit(for: HCControlText.returnEvent) }
            return total
        }
    }

    func encode(_ request: HCInputRequest) async -> Result<[HCOutboundFrame], HCInputRefusal> {
        await MainActor.run {
            guard !Task.isCancelled, let native = surface(),
                  let capacity = maximumEncodedBytes(for: request), capacity <= HCLimits.transactionBytes,
                  let plan = plan(for: request) else {
                return .failure(.unavailable)
            }
            switch plan {
            case .paste:
                guard let capture = pasteCapture(native, request.payload, request.submitReturn, capacity - 18) else {
                    return .failure(.unavailable)
                }
                var frames: [HCOutboundFrame] = [.data(capture.body)]
                if request.submitReturn {
                    guard !capture.submit.isEmpty else { return .failure(.unavailable) }
                    frames.append(.submitReturnAfter(capture.submit,
                        delayNanoseconds: returnDelayNanoseconds(request.source)))
                }
                return .success(frames)
            case .keys(let events):
                var body = Data()
                for event in events {
                    guard !Task.isCancelled,
                          let bytes = keyCapture(native, event, HCControlText.byteLimit(for: event)) else {
                        return .failure(.unavailable)
                    }
                    body.append(bytes)
                }
                var frames: [HCOutboundFrame] = [.data(body)]
                if request.submitReturn {
                    guard let submit = keyCapture(native, HCControlText.returnEvent,
                                                  HCControlText.byteLimit(for: HCControlText.returnEvent)),
                          !submit.isEmpty else { return .failure(.unavailable) }
                    frames.append(.submitReturnAfter(submit, delayNanoseconds: returnDelayNanoseconds(request.source)))
                }
                return .success(frames)
            }
        }
    }

    @MainActor
    static func nativePaste(_ native: ghostty_surface_t, _ payload: Data, _ submit: Bool,
                            _ limit: Int) -> (body: Data, submit: Data)? {
        let capture = PasteResult()
        let userdata = Unmanaged.passUnretained(capture).toOpaque()
        // An empty transaction still passes a valid non-null pointer.
        let encoded = payload.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                return ghostty_surface_encode_paste(native, base.assumingMemoryBound(to: CChar.self),
                    UInt(bytes.count), submit, UInt(limit), pasteComplete, userdata)
            }
            return "".withCString {
                ghostty_surface_encode_paste(native, $0, 0, submit, UInt(limit), pasteComplete, userdata)
            }
        }
        guard encoded, capture.calls == 1 else { return nil }
        return (capture.body, capture.submit)
    }

    @MainActor
    static func nativeKey(_ native: ghostty_surface_t, _ spec: HCKeyEventSpec, _ limit: Int) -> Data? {
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = spec.keycode
        event.mods = GHOSTTY_MODS_NONE
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.unshifted_codepoint = 0
        event.composing = false
        let capture = KeyResult()
        let userdata = Unmanaged.passUnretained(capture).toOpaque()
        let encoded: Bool
        if let text = spec.text {
            encoded = text.withCString {
                event.text = $0
                return ghostty_surface_encode_key(native, event, spec.releaseAfterPress, UInt(limit), keyComplete, userdata)
            }
        } else {
            event.text = nil
            encoded = ghostty_surface_encode_key(native, event, spec.releaseAfterPress, UInt(limit), keyComplete, userdata)
        }
        guard encoded, capture.calls == 1 else { return nil }
        return capture.bytes
    }

    private final class PasteResult {
        var calls = 0
        var body = Data()
        var submit = Data()
    }
    private final class KeyResult {
        var calls = 0
        var bytes = Data()
    }
    private static let pasteComplete: ghostty_encoded_paste_cb = { userdata, body, bodyCount, submit, submitCount in
        guard let userdata else { return }
        let capture = Unmanaged<PasteResult>.fromOpaque(userdata).takeUnretainedValue()
        capture.calls += 1
        if let body, bodyCount > 0 { capture.body = Data(bytes: body, count: Int(bodyCount)) }
        if let submit, submitCount > 0 { capture.submit = Data(bytes: submit, count: Int(submitCount)) }
    }
    private static let keyComplete: ghostty_encoded_key_cb = { userdata, bytes, count in
        guard let userdata else { return }
        let capture = Unmanaged<KeyResult>.fromOpaque(userdata).takeUnretainedValue()
        capture.calls += 1
        if let bytes, count > 0 { capture.bytes = Data(bytes: bytes, count: Int(count)) }
    }
}


/// Loaded config only: copy borrowed values on the owning thread, never parse
/// tenant configuration a second time or persist the caller's environment.
struct HCNativeLaunchSnapshot: Sendable {
    enum Command: Equatable, Sendable { case shell(String), direct([String]) }
    let command: Command?
    let environment: [String: String]
    /// Explicit config env entries. Ghostty applies them after shell
    /// integration, so they stay separate until the launch tuple is built.
    let overrides: [String: String]
    let workingDirectory: String?

    @MainActor
    static func capture(_ config: ghostty_config_t, initial: Bool) -> HCNativeLaunchSnapshot? {
        let capture = ConfigCapture()
        let userdata = Unmanaged.passUnretained(capture).toOpaque()
        guard ghostty_config_visit_launch(config, initial, commandCallback, envCallback, userdata),
              ghostty_config_visit_launch_fields(config, fieldCallback, userdata),
              !capture.invalid, let configuredTerm = capture.fields["term"] else { return nil }
        let inherited = ProcessInfo.processInfo.environment
        // XDG_* and c11's own launch settings (C11_DEBUG_LOG, C11_QA_LAUNCH, ...):
        // a native terminal inherits these from the app; the hc core's
        // environment is scrubbed of them. See HCLaunchPolicy.inheritedAppEnvironment.
        var environment = HCLaunchPolicy.inheritedAppEnvironment(inherited)
        let resources = inherited["GHOSTTY_RESOURCES_DIR"]
        environment["TERM"] = resources == nil ? "xterm-256color" : configuredTerm
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "ghostty"
        let info = ghostty_info()
        if let version = info.version { environment["TERM_PROGRAM_VERSION"] = String(cString: version) }
        if let bin = Bundle.main.executableURL?.deletingLastPathComponent().path {
            environment["GHOSTTY_BIN_DIR"] = bin
        }
        if let resources {
            environment["GHOSTTY_RESOURCES_DIR"] = resources
            environment["TERMINFO"] = URL(fileURLWithPath: resources).deletingLastPathComponent().appendingPathComponent("terminfo").path
            let data = resources + "/.."
            let paths = inherited["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            environment["XDG_DATA_DIRS"] = paths.split(separator: ":").contains(Substring(data)) ? paths : paths + ":" + data
            let man = resources + "/../man"
            let manpath = inherited["MANPATH"] ?? ""
            environment["MANPATH"] = manpath.split(separator: ":").contains(Substring(man)) ? manpath : manpath + ":" + man
        }
        var flags: UInt32 = 0
        let featuresKey = "shell-integration-features"
        if ghostty_config_get(config, &flags, featuresKey, UInt(featuresKey.utf8.count)) {
            var blink = true
            let blinkKey = "cursor-style-blink"
            _ = ghostty_config_get(config, &blink, blinkKey, UInt(blinkKey.utf8.count))
            let features: [(UInt32, String)] = [(1, blink ? "cursor:blink" : "cursor:steady"),
                (32, "path"), (8, "ssh-env"), (16, "ssh-terminfo"), (2, "sudo"), (4, "title")]
            let enabled = features.filter { flags & $0.0 != 0 }.map { $0.1 }
            if !enabled.isEmpty { environment["GHOSTTY_SHELL_FEATURES"] = enabled.joined(separator: ",") }
        }
        return HCNativeLaunchSnapshot(command: capture.command, environment: environment,
            overrides: capture.environment, workingDirectory: capture.fields["working-directory"])
    }

    func argv(override: String?) -> [String]? {
        argv(command: effectiveCommand(override: override))
    }

    /// The command Ghostty would launch before shell integration rewrites it.
    func effectiveCommand(override: String?) -> Command? {
        override.flatMap { $0.isEmpty ? nil : Command.shell($0) } ?? command
    }

    /// The terminal root's argv. Ghostty's login-shell form without its
    /// `/usr/bin/login -flp <user>` prefix (c11: C11H-232): bash execs the
    /// shell at once as a login shell (`exec -l` makes argv[0] `-/bin/zsh`), so
    /// the long-lived root is the interactive shell itself. Its argv carries no
    /// option string for a stray `pkill -f <x> -n` to match (login's
    /// `--noprofile` did, 2026-11-06), it ignores SIGTERM, SIGINT and SIGQUIT
    /// as every interactive shell does while its jobs keep default signals,
    /// and hc's own SIGHUP still ends it. login added only the "Last login"
    /// line, a utmpx entry and a wrong `__CF_USER_TEXT_ENCODING` (uid 0).
    /// A direct command runs as given.
    func argv(command selected: Command?) -> [String]? {
        switch selected {
        case nil: return nil
        case .shell(let command): return ["/bin/bash", "--noprofile", "--norc", "-c", "exec -l " + command]
        case .direct(let args): return args.isEmpty ? nil : args
        }
    }

    private final class ConfigCapture {
        var command: Command?
        var environment: [String: String] = [:]
        var fields: [String: String] = [:]
        var invalid = false
        var arguments: [String] = []
    }
    private static let commandCallback: ghostty_config_command_cb = { userdata, kind, index, count, ptr, length in
        guard let userdata, let ptr else { return }
        let capture = Unmanaged<ConfigCapture>.fromOpaque(userdata).takeUnretainedValue()
        guard let text = String(bytes: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
                                                          count: Int(length)), encoding: .utf8) else {
            capture.invalid = true; return
        }
        switch kind {
        case GHOSTTY_CONFIG_COMMAND_NONE: capture.command = nil
        case GHOSTTY_CONFIG_COMMAND_SHELL: capture.command = .shell(text)
        case GHOSTTY_CONFIG_COMMAND_DIRECT:
            if count == 0 { capture.command = .direct([]); return }
            guard index == capture.arguments.count else { capture.invalid = true; return }
            capture.arguments.append(text)
            if index + 1 == count { capture.command = .direct(capture.arguments) }
        default: capture.invalid = true
        }
    }
    private static let envCallback: ghostty_config_env_cb = { userdata, key, keyLength, value, valueLength in
        guard let userdata, let key, let value else { return }
        let capture = Unmanaged<ConfigCapture>.fromOpaque(userdata).takeUnretainedValue()
        guard let name = String(bytes: UnsafeBufferPointer(start: UnsafeRawPointer(key).assumingMemoryBound(to: UInt8.self), count: Int(keyLength)), encoding: .utf8),
              let text = String(bytes: UnsafeBufferPointer(start: UnsafeRawPointer(value).assumingMemoryBound(to: UInt8.self), count: Int(valueLength)), encoding: .utf8) else {
            capture.invalid = true; return
        }
        capture.environment[name] = text
    }
    private static let fieldCallback: ghostty_config_launch_field_cb = { userdata, key, keyLength, value, valueLength in
        guard let userdata, let key, let value else { return }
        let capture = Unmanaged<ConfigCapture>.fromOpaque(userdata).takeUnretainedValue()
        guard let name = String(bytes: UnsafeBufferPointer(start: UnsafeRawPointer(key).assumingMemoryBound(to: UInt8.self), count: Int(keyLength)), encoding: .utf8),
              let text = String(bytes: UnsafeBufferPointer(start: UnsafeRawPointer(value).assumingMemoryBound(to: UInt8.self), count: Int(valueLength)), encoding: .utf8),
              name == "working-directory" || name == "term" else {
            capture.invalid = true; return
        }
        capture.fields[name] = text
    }
}
