import Foundation
import os

/// In-app typing-latency probe, kept for the Validator (plan ticket 5;
/// matrix G.5, T5.11 to T5.13). Replaces the spike's
/// `C11_SPIKE_HC_LATENCY_LOG`; no spike switch remains.
///
/// `C11_LATENCY_LOG=<file>` in the app's environment arms it. For each
/// one-byte printable key that enters the native input callback it remembers
/// the byte and the monotonic time; when that byte next comes back on the
/// panel's output lane, just before `ghostty_surface_process_output`, it
/// records the delta. One line per sample, `mode=hc us=<float>`, appended in
/// batches of 100 (the spike's format, so `lat0b.sh` and the Pathfinder's
/// summaries read it unchanged). Off, each hook costs one load of a static.
enum HCLatencyProbe {
    static let environmentKey = "C11_LATENCY_LOG"
    static let logPath: String? = {
        guard let value = ProcessInfo.processInfo.environment[environmentKey], !value.isEmpty else { return nil }
        return value
    }()
    static let enabled: Bool = logPath != nil

    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    @inline(__always) static func now() -> UInt64 { mach_absolute_time() }

    static func microseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end &- start) * Double(timebase.numer) / Double(timebase.denom) / 1000
    }

    static let sink = HCLatencySink(path: logPath)
}

/// Per-panel probe state. `noteRawInput` runs on Ghostty's IO thread inside
/// the native callback: one unfair lock, no allocation. `noteOutput` runs on
/// the panel's output lane.
final class HCLatencyProbeState: @unchecked Sendable {
    private struct Armed { var byte: UInt8 = 0; var start: UInt64 = 0 }
    private let lock = OSAllocatedUnfairLock(initialState: Armed())
    private let enabled: Bool
    private let clock: @Sendable () -> UInt64
    private let record: @Sendable (_ start: UInt64, _ end: UInt64) -> Void

    init(
        enabled: Bool = HCLatencyProbe.enabled,
        clock: @escaping @Sendable () -> UInt64 = { HCLatencyProbe.now() },
        record: @escaping @Sendable (_ start: UInt64, _ end: UInt64) -> Void = { start, end in
            HCLatencyProbe.sink.record(microseconds: HCLatencyProbe.microseconds(from: start, to: end))
        }
    ) {
        self.enabled = enabled
        self.clock = clock
        self.record = record
    }

    /// Native input callback. Arms on a single printable byte only.
    @inline(__always)
    func noteRawInput(_ ptr: UnsafeRawPointer, _ len: Int) {
        guard enabled, len == 1 else { return }
        let byte = ptr.load(as: UInt8.self)
        guard byte >= 0x21, byte < 0x7f else { return }
        let start = clock()
        lock.withLock { $0 = Armed(byte: byte, start: start) }
    }

    /// Output lane, before the bytes reach Ghostty.
    func noteOutput(_ bytes: Data) {
        guard enabled, !bytes.isEmpty else { return }
        let arrival = clock()
        let armed = lock.withLock { state -> Armed? in
            guard state.start != 0, bytes.contains(state.byte) else { return nil }
            let hit = state
            state = Armed()
            return hit
        }
        if let armed { record(armed.start, arrival) }
    }
}

/// Batches sample lines to the log file off every hot lane. No sample cap:
/// the Validator runs long measurements (Pathfinder: the spike's probe lost
/// samples past its batches). A batch is written at 100 lines, or 1 s after
/// its first line, so a run's tail reaches the file without an app quit.
final class HCLatencySink: @unchecked Sendable {
    private let path: String?
    private let queue = DispatchQueue(label: "c11.latency-probe", qos: .utility)
    private var batch: [String] = []
    private var flushScheduled = false
    static let batchSize = 100
    let flushDelay: TimeInterval

    init(path: String?, flushDelay: TimeInterval = 1) {
        self.path = path
        self.flushDelay = flushDelay
    }

    func record(microseconds: Double) {
        guard path != nil else { return }
        let line = "mode=hc us=\(String(format: "%.1f", microseconds))"
        queue.async { [self] in
            batch.append(line)
            if batch.count >= Self.batchSize {
                flushOnQueue()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + flushDelay) { [self] in
                    flushScheduled = false
                    flushOnQueue()
                }
            }
        }
    }

    /// Writes any partial batch (app termination, tests).
    func flush() {
        queue.sync { flushOnQueue() }
    }

    private func flushOnQueue() {
        guard let path, !batch.isEmpty else { return }
        let text = batch.joined(separator: "\n") + "\n"
        batch.removeAll(keepingCapacity: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
