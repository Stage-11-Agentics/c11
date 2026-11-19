import Foundation

/// Owns the native surface through the last output call and native destruction.
/// The state lock only orders admission/retirement; it NEVER spans native work.
final class HCOutputLease: HCOutputSink, @unchecked Sendable {
    typealias Process = @Sendable (HCOutputChunk) -> Void
    private let generation: UInt64
    private let lane: DispatchQueue
    private let lock = NSLock()
    private var accepting = true
    private var outstandingBytes = 0
    private var retirementStarted = false
    private let destroyed = DispatchGroup()
    private let process: Process
    private let destroy: @MainActor @Sendable () -> Void

    init(generation: UInt64, process: @escaping Process,
         destroy: @escaping @MainActor @Sendable () -> Void) {
        self.generation = generation
        self.process = process
        self.destroy = destroy
        lane = DispatchQueue(label: "c11.output.\(generation)", qos: .userInteractive)
        destroyed.enter()
    }

    func consume(_ chunk: HCOutputChunk) async -> HCOutputConsumption {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard accepting, chunk.attachmentGeneration == generation else {
                lock.unlock()
                continuation.resume(returning: .stale)
                return
            }
            // Credit bounds retained output even if a peer/adapter violates its
            // contract. No dispatch closure can retain an uncharged chunk.
            guard chunk.bytes.count <= HCLimits.initialCreditBytes - outstandingBytes else {
                accepting = false
                lock.unlock()
                continuation.resume(returning: .failed(.bufferOverflow))
                return
            }
            outstandingBytes += chunk.bytes.count
            lane.async { [self] in
                autoreleasepool {
                    // Retirement rejects queued deliveries. A call already in
                    // native code finishes with main free to drain its mailbox.
                    if isAccepting {
                        var offset = 0
                        while offset < chunk.bytes.count {
                            let end = min(offset + HCLimits.outputChunkBytes, chunk.bytes.count)
                            process(HCOutputChunk(attachmentGeneration: generation,
                                watermark: chunk.watermark, bytes: chunk.bytes.subdata(in: offset..<end)))
                            offset = end
                        }
                        releaseBytes(chunk.bytes.count)
                        continuation.resume(returning: .consumed)
                    } else {
                        releaseBytes(chunk.bytes.count)
                        continuation.resume(returning: .stale)
                    }
                }
            }
            lock.unlock()
        }
    }

    private var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    private func releaseBytes(_ count: Int) {
        lock.lock()
        outstandingBytes -= count
        lock.unlock()
    }

    func retire(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        accepting = false
        if !retirementStarted {
            retirementStarted = true
            // Enqueued under the admission lock, behind every accepted chunk.
            // No sync, semaphore wait or native call on the retiring caller.
            lane.async { [self] in
                DispatchQueue.main.async { [self] in
                    destroy()
                    destroyed.leave()
                }
            }
        }
        destroyed.notify(queue: lane, execute: completion)
        lock.unlock()
    }
}
