import Foundation
import os

/// This context is retained independently of the panel and survives native free.
/// The C callback never accesses an NSView or waits for a task/queue to finish.
final class HCNativeInputContext: @unchecked Sendable {
    let rendering: any HCRenderingAdapter
    let report: @Sendable (HCInputOutcome) -> Void
    /// A refusal with who made the refused bytes, judged by their shape (C11H-443); nil sends
    /// refusals to `report`.
    let reportRawAttributed: (@Sendable (HCInputOutcome, HCInputAttribution) -> Void)?
    let panelID: UUID
    private let lock = NSLock()
    private var input: (any HCInputPort)?
    private var generation: UInt64 = 0
    /// C11H-443: the first refused writes before a port is bound are logged by byte class.
    private var refusalsLogged = 0

    init(panelID: UUID = UUID(), rendering: any HCRenderingAdapter,
         report: @escaping @Sendable (HCInputOutcome) -> Void,
         reportRawAttributed: (@Sendable (HCInputOutcome, HCInputAttribution) -> Void)? = nil) {
        self.panelID = panelID
        self.rendering = rendering
        self.report = report
        self.reportRawAttributed = reportRawAttributed
    }

    func bind(input: any HCInputPort, generation: UInt64) {
        lock.lock()
        self.input = input
        self.generation = generation
        refusalsLogged = 0
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
        guard let port else {
            // Refusal path only: a bound port never comes here.
            let bytes = UnsafeRawBufferPointer(start: UnsafeRawPointer(ptr), count: count)
            if shouldLogRefusal() { HCRawInputClass.log(panelID: panelID, port: "none", bytes) }
            if let reportRawAttributed {
                reportRawAttributed(.refused(.unavailable), HCRawInputClass.attribution(bytes))
            } else {
                report(.refused(.unavailable))
            }
            return
        }
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

    private func shouldLogRefusal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard refusalsLogged < HCRawInputClass.logLimit else { return false }
        refusalsLogged += 1
        return true
    }

    static let write: ghostty_io_write_cb = { userdata, ptr, count in
        guard let userdata, let ptr, count > 0 else { return }
        Unmanaged<HCNativeInputContext>.fromOpaque(userdata).takeUnretainedValue().receive(ptr, count: Int(count))
    }
}

/// C11H-443: what a refused native write was, logged without its text. Ghostty writes its own
/// query replies and reports through the callback that carries the operator's keys, and the
/// class tells them apart in the log: `csi?c` a device-attributes reply, `osc11` a colour
/// reply, `csi48t` an in-band size report, `text` typed characters (counted, never shown).
enum HCRawInputClass {
    /// Refused writes logged per port: enough to show a launch burst, never a flood.
    static let logLimit = 8
    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.input")

    /// The length is logged for a terminal report only: a run of typed keys keeps even its count.
    static func log(panelID: UUID, port: String, _ bytes: UnsafeRawBufferPointer) {
        let kind = describe(bytes)
        let size = isTerminalReport(bytes) ? String(bytes.count) : "-"
        logger.notice("native input refused panel=\(panelID.uuidString, privacy: .public) port=\(port, privacy: .public) class=\(kind, privacy: .public) bytes=\(size, privacy: .public)")
    }

    /// Who made native bytes, by their shape: `.terminal` for a write made only of sequences
    /// Ghostty sends by itself (query replies, size, colour and focus reports), `.keystroke`
    /// for anything a key could send. A key binding can send report-shaped bytes, so the
    /// policy lets this lower a bar only when the operator pressed no key (C11H-443).
    static func attribution(_ bytes: UnsafeRawBufferPointer) -> HCInputAttribution {
        isTerminalReport(bytes) ? .terminal : .keystroke
    }

    /// True when every byte belongs to a complete report: an OSC, DCS or APC string ended by
    /// ST or BEL; a CSI with a `?` or `>` marker (device attributes, mode and colour-scheme
    /// reports, keyboard flags); a CSI ending in `t` (window and in-band size reports), `n`
    /// (status reports), `c` (device attributes), `$y` (mode reports) or `R` (cursor
    /// position, unless it is `CSI 1;<mods> R`, a modified F3); or a bare focus report. Any
    /// other byte, text after a report included, makes the write a keystroke.
    static func isTerminalReport(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var index = 0
        while index < bytes.count {
            guard let next = reportEnd(bytes, from: index) else { return false }
            index = next
        }
        return index > 0
    }

    /// The index after the report starting at `start`, or nil when none starts there.
    private static func reportEnd(_ bytes: UnsafeRawBufferPointer, from start: Int) -> Int? {
        guard start + 2 < bytes.count, bytes[start] == 0x1b else { return nil }
        switch bytes[start + 1] {
        case 0x5d, 0x50, 0x5f:
            // A string runs to ST (ESC \) or BEL. Alt with `]`, `P` or `_` sends no terminator.
            var index = start + 2
            while index < bytes.count {
                if bytes[index] == 0x07 { return index + 1 }
                if bytes[index] == 0x1b { return index + 1 < bytes.count && bytes[index + 1] == 0x5c ? index + 2 : nil }
                index += 1
            }
            return nil
        case 0x5b:
            break
        default:
            return nil
        }
        var index = start + 2
        var marker: UInt8 = 0
        if index < bytes.count, (0x3c...0x3f).contains(bytes[index]) { marker = bytes[index]; index += 1 }
        let parametersStart = index
        var separators = 0
        while index < bytes.count, (0x30...0x3b).contains(bytes[index]) {
            if bytes[index] == 0x3b { separators += 1 }
            index += 1
        }
        let parameters = index - parametersStart
        var intermediates = 0, dollar = false
        while index < bytes.count, (0x20...0x2f).contains(bytes[index]) {
            intermediates += 1
            if bytes[index] == 0x24 { dollar = true }
            index += 1
        }
        guard index < bytes.count, isFinal(bytes[index]) else { return nil }
        let end = index + 1
        if marker == 0x3f || marker == 0x3e { return end }
        guard marker == 0 else { return nil }
        switch bytes[index] {
        case 0x74, 0x6e, 0x63: return end // t, n, c
        case 0x79: return dollar && intermediates == 1 ? end : nil // $y
        case 0x49, 0x4f: return parameters == 0 && intermediates == 0 ? end : nil // focus in, out
        case 0x52: // R: a cursor-position report, unless it is CSI 1;<mods> R
            guard separators == 1, parameters >= 3, bytes[parametersStart] == 0x31,
                  bytes[parametersStart + 1] == 0x3b else { return end }
            var modifiers = 0, digit = parametersStart + 2
            while digit < index, (0x30...0x39).contains(bytes[digit]), modifiers <= 16 {
                modifiers = modifiers * 10 + Int(bytes[digit] - 0x30)
                digit += 1
            }
            return (2...16).contains(modifiers) ? nil : end
        default: return nil
        }
    }

    /// The first sequence's shape: its introducer, private marker, intermediates and final
    /// byte. Parameters and text are left out (a kitty-encoded key names its character in
    /// them); only a window report (`t`) keeps its first parameter, which names the report.
    static func describe(_ bytes: UnsafeRawBufferPointer) -> String {
        guard let first = bytes.first else { return "empty" }
        guard first == 0x1b else {
            if bytes.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) { return "text" }
            return bytes.count == 1 ? "ctl" : "mixed"
        }
        guard bytes.count > 1 else { return "esc" }
        switch bytes[1] {
        case 0x5b: return "csi" + shape(bytes, from: 2, keepsWindowReport: true)
        case 0x50: return "dcs" + shape(bytes, from: 2, keepsWindowReport: false)
        case 0x5d:
            var number = ""
            for byte in bytes.dropFirst(2).prefix(4) {
                guard (0x30...0x39).contains(byte) else { break }
                number.append(Character(UnicodeScalar(byte)))
            }
            return "osc" + number
        case 0x5f: return "apc" + (bytes.count > 2 && isFinal(bytes[2]) ? String(UnicodeScalar(bytes[2])) : "")
        case 0x4f: return "ss3" + (bytes.count > 2 && isFinal(bytes[2]) ? String(UnicodeScalar(bytes[2])) : "")
        default: return "esc+" // Alt with a key: the key is not logged.
        }
    }

    private static func isFinal(_ byte: UInt8) -> Bool { (0x40...0x7e).contains(byte) }

    private static func shape(_ bytes: UnsafeRawBufferPointer, from start: Int, keepsWindowReport: Bool) -> String {
        var index = start
        var marker = "", firstParameter = "", intermediates = ""
        var firstEnded = false
        if index < bytes.count, (0x3c...0x3f).contains(bytes[index]) {
            marker = String(UnicodeScalar(bytes[index])); index += 1
        }
        while index < bytes.count, (0x30...0x3b).contains(bytes[index]) {
            let byte = bytes[index]
            if byte > 0x39 { firstEnded = true }
            else if !firstEnded, firstParameter.count < 4 { firstParameter.append(Character(UnicodeScalar(byte))) }
            index += 1
        }
        while index < bytes.count, (0x20...0x2f).contains(bytes[index]) {
            intermediates.append(Character(UnicodeScalar(bytes[index]))); index += 1
        }
        guard index < bytes.count, isFinal(bytes[index]) else { return marker + intermediates + "~partial" }
        let final = String(UnicodeScalar(bytes[index]))
        if keepsWindowReport, final == "t" { return marker + firstParameter + intermediates + final }
        return marker + intermediates + final
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
    /// Raw input outcomes: the native write callback and the port's raw writes.
    let report: @Sendable (HCInputOutcome) -> Void
    /// Outcomes of input submitted with a source (initial input); nil sends them to `report`.
    let reportSubmitted: (@Sendable (HCInputOutcome) -> Void)?
    /// Refused raw bytes with who made them, by their shape; nil sends them to `report`.
    let reportRawAttributed: (@Sendable (HCInputOutcome, HCInputAttribution) -> Void)?
    private let lock = NSLock()
    private var lease: HCOutputLease?
    private var retired = false
    private var bound = false
    private var attachmentGeneration: UInt64?
    private var process: HCOutputLease.Process?
    private var destroy: (@MainActor @Sendable () -> Void)?
    private var removeFromUse: (@MainActor @Sendable () -> Void)?
    /// C11H-434: asked on main when the stream retires the bridge (hc ended the
    /// terminal and closed its channel, or its attachment detached). True keeps
    /// the native surface on screen with its last frame; nil or false frees it.
    private var keepsSurface: (@MainActor @Sendable () -> Bool)?
    /// C11H-434: true once a retire kept the surface; `release` frees it.
    private var keepingSurface = false
    /// The kept surface's free, handed over by the lease once output has drained.
    private var keptFree: (@MainActor @Sendable () -> Void)?
    private let retirement = DispatchGroup()
    private var pending: [(HCOutputChunk, CheckedContinuation<HCOutputConsumption, Never>)] = []
    private var pendingBytes = 0
    private var draining = false

    init(panelID: UUID, rendering: any HCRenderingAdapter, encoder: any HCInputEncoder,
         report: @escaping @Sendable (HCInputOutcome) -> Void,
         reportSubmitted: (@Sendable (HCInputOutcome) -> Void)? = nil,
         reportRawAttributed: (@Sendable (HCInputOutcome, HCInputAttribution) -> Void)? = nil,
         displayChanged: @escaping @Sendable (HCDisplayState) -> Void = { _ in }) {
        self.panelID = panelID
        self.rendering = rendering
        self.encoder = encoder
        self.displayChanged = displayChanged
        self.report = report
        self.reportSubmitted = reportSubmitted
        self.reportRawAttributed = reportRawAttributed
        context = HCNativeInputContext(panelID: panelID, rendering: rendering, report: report,
                                       reportRawAttributed: reportRawAttributed)
        retirement.enter()
    }

    /// Called immediately after native creation, before any hc create/attach.
    @MainActor
    func installSurface(_ surface: ghostty_surface_t,
                        removeFromUse: @escaping @MainActor @Sendable () -> Void,
                        keepsSurface: (@MainActor @Sendable () -> Bool)? = nil,
                        releaseCallbackContext: @escaping @MainActor @Sendable () -> Void) {
        let context = context
        installProcessor(process: { chunk in
            chunk.bytes.withUnsafeBytes { bytes in
                guard let ptr = bytes.baseAddress else { return }
                ghostty_surface_process_output(surface, ptr.assumingMemoryBound(to: CChar.self), UInt(bytes.count))
            }
        }, removeFromUse: removeFromUse, keepsSurface: keepsSurface, destroy: {
            ghostty_surface_free(surface)
            withExtendedLifetime(context) { releaseCallbackContext() }
        })
    }

    /// The native processor is injected here so lifecycle/IO ordering is
    /// executable in logic tests without constructing a WindowServer surface.
    @MainActor
    func installProcessor(process: @escaping HCOutputLease.Process,
                          removeFromUse: @escaping @MainActor @Sendable () -> Void,
                          keepsSurface: (@MainActor @Sendable () -> Bool)? = nil,
                          destroy: @escaping @MainActor @Sendable () -> Void) {
        let rendering = rendering
        lock.lock()
        self.removeFromUse = removeFromUse
        self.keepsSurface = keepsSurface
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
        // The lease frees through the bridge, so a surface kept on screen
        // (C11H-434) passes its free to `release` instead of running it.
        lease = HCOutputLease(generation: generation, process: process, destroy: { [weak self] in
            if let self, self.holdFree(destroy) { return }
            destroy()
        })
        return true
    }

    /// On main, from the lease once output has drained: a kept surface's free
    /// waits for `release`. False runs it now.
    @MainActor
    private func holdFree(_ free: @escaping @MainActor @Sendable () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard keepingSurface else { return false }
        keptFree = free
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

    /// The stream's retire: hc ended the terminal and closed its channel, the
    /// attachment detached, or the connection failed. Output and input stop.
    /// C11H-434: when the owner's `keepsSurface` answers true (the terminal
    /// ended on purpose, or has ended), the surface stays on screen with its
    /// last frame until the owner's `release`; otherwise it is freed.
    func retire(completion: @escaping @Sendable () -> Void) {
        retire(.stream, completion: completion)
    }

    /// The owner's retire (replacement, reattach, teardown): always frees the
    /// surface, a kept one included.
    func release(completion: @escaping @Sendable () -> Void) {
        retire(.owner, completion: completion)
    }

    private enum Retirer { case stream, owner, deinitializer }

    private func retire(_ retirer: Retirer, completion: @escaping @Sendable () -> Void) {
        context.invalidate()
        lock.lock()
        guard !retired else {
            lock.unlock()
            // deinit frees a kept surface itself, without reaching self.
            if retirer == .owner { freeKeptSurface() }
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
        let keepsSurface = retirer == .stream && lease != nil ? self.keepsSurface : nil
        self.destroy = nil
        lock.unlock()
        for (_, continuation) in waiting { continuation.resume(returning: .stale) }
        retirement.notify(queue: .global(qos: .userInitiated), execute: completion)
        // An attachment may detach off-main while a view still exists. Remove
        // the pointer from UI use on main BEFORE output retirement can free it.
        let retirement = retirement
        guard let keepsSurface, let lease else {
            DispatchQueue.main.async {
                removeFromUse?()
                if let lease { lease.retire { retirement.leave() } }
                else { destroy?(); retirement.leave() }
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            // Decided here, before the lease can reach its free on main.
            if keepsSurface(), let self, self.startKeeping() {
                lease.retire { retirement.leave() }
                return
            }
            removeFromUse?()
            lease.retire { retirement.leave() }
        }
    }

    @MainActor
    private func startKeeping() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A release that arrived first wins: nothing is kept.
        guard !releaseRequested else { return false }
        keepingSurface = true
        return true
    }

    private var releaseRequested = false

    /// Frees a kept surface: out of UI use first, then the free the lease
    /// handed over. A release before the lease has drained frees it there.
    private func freeKeptSurface() {
        let work: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.releaseRequested = true
            let wasKeeping = self.keepingSurface
            self.keepingSurface = false
            let free = self.keptFree
            self.keptFree = nil
            let removeFromUse = self.removeFromUse
            self.lock.unlock()
            guard wasKeeping else { return }
            removeFromUse?()
            free?()
        }
        if Thread.isMainThread { MainActor.assumeIsolated { work() } }
        else { DispatchQueue.main.async { MainActor.assumeIsolated { work() } } }
    }

    deinit {
        // Kept or not, nothing outlives the bridge: free a kept surface on main.
        lock.lock()
        let free = keepingSurface ? keptFree : nil
        let removeFromUse = keepingSurface ? self.removeFromUse : nil
        keptFree = nil
        keepingSurface = false
        lock.unlock()
        if let free {
            DispatchQueue.main.async { MainActor.assumeIsolated { removeFromUse?(); free() } }
        }
        retire(.deinitializer) {}
    }
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
