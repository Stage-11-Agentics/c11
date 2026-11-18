import Foundation

/// The sole outbound reservation and queue. Socket writes are nonblocking and
/// supplied by the connection. Lock protects bounded state only, never awaits.
final class HCControlWriter: @unchecked Sendable {
    // Mutable entry state is protected by the writer lock, including guard completion.
    private final class Entry: @unchecked Sendable {
        var bytes: Data
        var offset = 0
        let channel: UInt32
        let control: Bool
        var credit: UInt32?
        let reservation: HCWriteReservation?
        let ranges: [(Range<Int>, Bool)]
        let boundaries: Set<Int>
        var barriers: [(offset: Int, delay: UInt64)]
        var resumeAt: UInt64?
        let beforeReturn: (@Sendable () async -> Bool)?
        var returnChecks: [Int]
        var checkingReturn = false
        let completion: @Sendable (Int, Bool) -> Void
        /// Ticket 12: a `terminal.put` RPC, counted in its own lane.
        var fileTransfer = false
        init(bytes: Data, channel: UInt32, control: Bool = false, credit: UInt32? = nil,
             reservation: HCWriteReservation? = nil, ranges: [(Range<Int>, Bool)] = [],
             boundaries: Set<Int> = [], barriers: [(offset: Int, delay: UInt64)] = [],
             beforeReturn: (@Sendable () async -> Bool)? = nil, returnChecks: [Int] = [],
             completion: @escaping @Sendable (Int, Bool) -> Void) {
            self.bytes = bytes; self.channel = channel; self.control = control; self.credit = credit
            self.reservation = reservation; self.ranges = ranges; self.completion = completion
            self.boundaries = boundaries; self.barriers = barriers
            self.beforeReturn = beforeReturn; self.returnChecks = returnChecks
        }
    }
    private let lock = NSLock()
    let generation: UInt64
    private var reservations: [UUID: HCWriteReservation] = [:]
    private var reservationChannels: [UUID: UInt32] = [:]
    private var closedChannels = HCChannelRetirements()
    private var inputBytes = 0
    private var controlBytes = 0
    private var rpcBytes = 0
    private var fileRPCBytes = 0
    private var dataQueue: [Entry] = []
    private var controls: [Entry] = []
    private var credits: [UInt32: Entry] = [:]
    private var active: Entry?
    private var suspended: Entry?
    private var delayWake: DispatchWorkItem?
    private var stopped = false
    private let wake: @Sendable () -> Void
    private let invalidate: @Sendable (HCUnavailableReason) -> Void

    init(generation: UInt64, wake: @escaping @Sendable () -> Void,
         invalidate: @escaping @Sendable (HCUnavailableReason) -> Void) {
        self.generation = generation; self.wake = wake; self.invalidate = invalidate
    }

    func reserve(operationID: UUID, attachmentGeneration: UInt64, encodedByteCount: Int, channel: UInt32 = 0) -> HCReservationOutcome {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, !closedChannels.contains(channel) else { return .refused(.unavailable) }
        guard encodedByteCount > 0, encodedByteCount <= HCLimits.transactionBytes else { return .refused(.tooLarge) }
        guard reservations.count + dataQueue.count < 1024, inputBytes <= HCLimits.queuedInputBytes - encodedByteCount else { return .refused(.queueFull) }
        let token = HCWriteReservation(id: UUID(), operationID: operationID, attachmentGeneration: attachmentGeneration,
                                       connectionGeneration: generation, encodedByteCount: encodedByteCount)
        reservations[token.id] = token; reservationChannels[token.id] = channel; inputBytes += encodedByteCount
        return .reserved(token)
    }

    func cancel(_ reservation: HCWriteReservation) {
        lock.lock()
        if reservations[reservation.id] == reservation {
            reservations.removeValue(forKey: reservation.id); reservationChannels.removeValue(forKey: reservation.id)
            inputBytes -= reservation.encodedByteCount
        }
        var cancelled: Entry?
        var partialFrame = false
        if let index = dataQueue.firstIndex(where: { $0.reservation == reservation }) {
            cancelled = dataQueue.remove(at: index)
        } else if active?.reservation == reservation {
            cancelled = active; active = nil
            partialFrame = cancelled!.offset > 0 && !cancelled!.boundaries.contains(cancelled!.offset)
            // Refuse new writes synchronously before asynchronous socket retirement.
            if partialFrame { stopped = true }
        } else if suspended?.reservation == reservation {
            cancelled = suspended; suspended = nil; delayWake?.cancel(); delayWake = nil
        }
        if let cancelled { release(cancelled) }
        lock.unlock()
        if let cancelled { cancelled.completion(cancelled.offset, false) }
        if partialFrame { invalidate(.connectionLost) } else { wake() }
    }

    func write(channel: UInt32, batch: HCWriteBatch, reservation: HCWriteReservation) async -> HCInputOutcome {
        let encoded: Data
        var ranges: [(Range<Int>, Bool)] = []
        var boundaries: Set<Int> = [0]
        var barriers: [(offset: Int, delay: UInt64)] = []
        var returnChecks: [Int] = []
        do {
            var bytes = Data()
            for item in batch.frames {
                let frame: HCWireFrame
                var isReturn = false
                var isData = false
                switch item {
                case .data(let payload): frame = HCWireFrame(channel: channel, kind: .data, payload: payload); isData = true
                case .submitReturn(let payload):
                    frame = HCWireFrame(channel: channel, kind: .data, payload: payload); isData = true; isReturn = true
                case .submitReturnAfter(let payload, let delay):
                    barriers.append((bytes.count, delay))
                    frame = HCWireFrame(channel: channel, kind: .data, payload: payload); isData = true; isReturn = true
                case .resize(let grid): frame = try .control(channel: channel, .resize(grid))
                case .focus(let focused): frame = try .control(channel: channel, .focus(focused))
                case .facts(let facts): frame = try .control(channel: channel, .facts(facts))
                }
                if isReturn && batch.beforeReturn != nil { returnChecks.append(bytes.count) }
                if isReturn && frame.payload.isEmpty { cancel(reservation); return .refused(.inputFault) }
                if isData { ranges.append(((bytes.count + 9)..<(bytes.count + 9 + frame.payload.count), isReturn)) }
                bytes.append(try frame.encoded())
                boundaries.insert(bytes.count)
                guard bytes.count <= reservation.encodedByteCount else { cancel(reservation); return .refused(.tooLarge) }
            }
            guard !bytes.isEmpty else { cancel(reservation); return .refused(.tooLarge) }
            encoded = bytes
        } catch { cancel(reservation); return .refused(.tooLarge) }
        let payloadRanges = ranges
        let frameBoundaries = boundaries
        let returnBarriers = barriers
        let guardedReturns = returnChecks
        return await withCheckedContinuation { continuation in
            lock.lock()
            guard !stopped, !closedChannels.contains(channel), reservation.connectionGeneration == generation,
                  reservationChannels[reservation.id] == channel,
                  reservation.operationID == batch.operationID,
                  reservation.attachmentGeneration == batch.attachmentGeneration,
                  reservations[reservation.id] == reservation else {
                lock.unlock(); cancel(reservation); continuation.resume(returning: .refused(.staleIdentity)); return
            }
            reservations.removeValue(forKey: reservation.id)
            reservationChannels.removeValue(forKey: reservation.id)
            let entry = Entry(bytes: encoded, channel: channel, reservation: reservation, ranges: payloadRanges,
                              boundaries: frameBoundaries, barriers: returnBarriers,
                              beforeReturn: batch.beforeReturn, returnChecks: guardedReturns) { offset, success in
                let body = payloadRanges.filter { !$0.1 }.reduce(0) { $0 + max(0, min(offset, $1.0.upperBound) - $1.0.lowerBound) }
                let returns = payloadRanges.filter(\.1)
                let returnWritten = !returns.isEmpty && returns.allSatisfy { offset >= $0.0.upperBound }
                let receipt = HCWriteReceipt(operationID: batch.operationID, attachmentGeneration: batch.attachmentGeneration,
                                             bodyBytesWritten: body, returnWritten: returnWritten)
                continuation.resume(returning: success ? .written(receipt) : (offset == 0 ? .refused(.unavailable) : .uncertain(receipt)))
            }
            dataQueue.append(entry)
            lock.unlock(); wake()
        }
    }

    func closeChannel(_ channel: UInt32) {
        lock.lock()
        closedChannels.insert(channel)
        let tokens = reservations.values.filter { reservationChannels[$0.id] == channel }
            + dataQueue.filter { $0.channel == channel }.compactMap(\.reservation)
            + [active, suspended].compactMap { $0?.channel == channel ? $0?.reservation : nil }
        lock.unlock()
        for token in tokens { cancel(token) }
    }

    func control(channel: UInt32, value: HCControl) async -> HCControlOutcome {
        await withCheckedContinuation { continuation in
            enqueueControl(channel: channel, value: value) { continuation.resume(returning: $0) }
        }
    }

    func enqueueControl(channel: UInt32, value: HCControl,
                        completion: @escaping @Sendable (HCControlOutcome) -> Void = { _ in }) {
        do {
            let bytes = try HCWireFrame.control(channel: channel, value).encoded()
            lock.lock()
            guard !stopped else { lock.unlock(); completion(.unavailable(.connectionLost)); return }
            var credit: UInt32?
            if case .credit(let count) = value {
                credit = count
                if let existing = credits[channel] {
                    let (sum, overflow) = existing.credit!.addingReportingOverflow(count)
                    if overflow {
                        lock.unlock(); completion(.unavailable(.bufferOverflow)); invalidate(.bufferOverflow); return
                    }
                    existing.credit = sum
                    existing.bytes = try HCWireFrame.control(channel: channel, .credit(sum)).encoded()
                    lock.unlock(); completion(.coalesced); return
                }
            }
            guard bytes.count <= HCLimits.controlBytes - controlBytes else {
                lock.unlock(); completion(.unavailable(.bufferOverflow)); invalidate(.bufferOverflow); return
            }
            controlBytes += bytes.count
            let entry = Entry(bytes: bytes, channel: channel, control: true, credit: credit) { _, success in
                completion(success ? .written : .unavailable(.connectionLost))
            }
            controls.append(entry)
            if credit != nil { credits[channel] = entry }
            lock.unlock(); wake()
        } catch { completion(.unavailable(.malformedResponse)); invalidate(.malformedResponse) }
    }

    /// RPCs use bounded storage separate from terminal reservations and the
    /// control lane. They never steal credit/CLOSE capacity.
    /// Ticket 12: a file transfer (`terminal.put`) has its own lane bounded
    /// by `fileTransferRPCBytes`, so a large put never fills the ordinary
    /// 4 MiB lane small RPCs (`machine.list` before each key) depend on.
    func enqueueRPC(_ bytes: Data, fileTransfer: Bool = false,
                    completion: @escaping @Sendable (Int, Bool) -> Void) -> Bool {
        lock.lock()
        let used = fileTransfer ? fileRPCBytes : rpcBytes
        let capacity = fileTransfer ? HCLimits.fileTransferRPCBytes : HCLimits.queuedInputBytes
        guard !stopped, bytes.count <= capacity - used else { lock.unlock(); return false }
        if fileTransfer { fileRPCBytes += bytes.count } else { rpcBytes += bytes.count }
        let entry = Entry(bytes: bytes, channel: 0, completion: completion)
        entry.fileTransfer = fileTransfer
        dataQueue.append(entry)
        lock.unlock(); wake(); return true
    }

    /// Returns true when the socket needs a writable wakeup. A transaction is
    /// indivisible even when the socket makes only a short write.
    func drain(send: (Data, Int) throws -> Int) {
        var iterations = 0
        while iterations < 64 {
            iterations += 1
            lock.lock()
            guard !stopped else { lock.unlock(); return }
            if active == nil {
                if !controls.isEmpty {
                    active = controls.removeFirst()
                    if let active, active.credit != nil { credits.removeValue(forKey: active.channel) }
                }
                else if let waiting = suspended {
                    if !waiting.checkingReturn, DispatchTime.now().uptimeNanoseconds >= (waiting.resumeAt ?? 0) {
                        active = waiting; suspended = nil; waiting.resumeAt = nil
                    } else if let index = bypassIndex(around: waiting) {
                        active = dataQueue.remove(at: index)
                    }
                } else if !dataQueue.isEmpty { active = dataQueue.removeFirst() }
            }
            guard let entry = active else { lock.unlock(); return }
            if let barrier = entry.barriers.first, barrier.offset == entry.offset {
                entry.barriers.removeFirst()
                let now = DispatchTime.now().uptimeNanoseconds
                // Finite paste-settle delay; reject overflow, never wrap into an immediate Return.
                let (deadline, overflow) = now.addingReportingOverflow(barrier.delay)
                if overflow { lock.unlock(); invalidate(.malformedResponse); return }
                entry.resumeAt = deadline; suspended = entry; active = nil
                let item = DispatchWorkItem { [weak self] in self?.wake() }
                delayWake?.cancel(); delayWake = item
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline), execute: item)
                lock.unlock(); continue
            }
            if entry.returnChecks.first == entry.offset, let predicate = entry.beforeReturn {
                entry.returnChecks.removeFirst()
                entry.checkingReturn = true; suspended = entry; active = nil
                lock.unlock()
                // The predicate is pure and may be uncooperative. Its result has
                // no authority after cancel/close; neither the entry nor writer
                // is retained across its wait, and cancellation never awaits it.
                Task { [weak self, weak entry] in
                    let accepted = await predicate()
                    guard let entry else { return }
                    self?.completeReturnCheck(entry, accepted: accepted)
                }
                continue
            }
            // send is a nonblocking syscall; no client callback runs under lock.
            let count: Int
            let end = min(entry.barriers.first?.offset ?? entry.bytes.count, entry.returnChecks.first ?? entry.bytes.count)
            do { count = try send(entry.bytes.prefix(end), entry.offset) }
            catch { lock.unlock(); invalidate(.connectionLost); return }
            guard count >= 0, count <= entry.bytes.count - entry.offset else {
                lock.unlock(); invalidate(.connectionLost); return
            }
            entry.offset += count
            if entry.offset == entry.bytes.count {
                release(entry); active = nil
                lock.unlock(); entry.completion(entry.offset, true)
            } else { lock.unlock(); if count == 0 { return } }
        }
        wake()
    }

    private func completeReturnCheck(_ entry: Entry, accepted: Bool) {
        lock.lock()
        guard !stopped, suspended === entry, entry.checkingReturn else { lock.unlock(); return }
        entry.checkingReturn = false
        if accepted { entry.resumeAt = 0 }
        else { suspended = nil; release(entry) }
        lock.unlock()
        if !accepted { entry.completion(entry.offset, false) }
        wake()
    }

    var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        if active != nil || !controls.isEmpty { return true }
        guard let waiting = suspended else { return !dataQueue.isEmpty }
        return bypassIndex(around: waiting) != nil
    }

    /// C11H-298: while one terminal's Return waits out its paste settle (or its check), the next queued input
    /// for another terminal goes ahead, so a send to one panel never stalls typing in the others. The waiting
    /// terminal's own input stays behind it and each terminal keeps its order. RPCs are never taken here, so
    /// they keep their order behind the waiting Return; ordinary RPCs (inventory reads, timestamps) carry no
    /// order against another terminal's keys, so input passes them. A file transfer is the exception: input
    /// typed after it may name the file it puts, so nothing queued after it goes ahead. An entry that would
    /// itself wait (a delayed or checked Return) is not taken, since one entry waits at a time. Call under `lock`.
    private func bypassIndex(around waiting: Entry) -> Int? {
        var held: Set<UInt32> = [waiting.channel]
        for (index, entry) in dataQueue.enumerated() {
            guard entry.reservation != nil else {
                if entry.fileTransfer { return nil }
                continue
            }
            if held.contains(entry.channel) { continue }
            if !entry.barriers.isEmpty || !entry.returnChecks.isEmpty { held.insert(entry.channel); continue }
            return index
        }
        return nil
    }

    func stop() {
        lock.lock()
        stopped = true
        let entries = (active.map { [$0] } ?? []) + (suspended.map { [$0] } ?? []) + controls + dataQueue
        active = nil; suspended = nil; delayWake?.cancel(); delayWake = nil
        controls = []; credits = [:]; dataQueue = []; reservations = [:]; reservationChannels = [:]
        inputBytes = 0; controlBytes = 0; rpcBytes = 0; fileRPCBytes = 0
        lock.unlock()
        for entry in entries { entry.completion(entry.offset, false) }
    }

    private func release(_ entry: Entry) {
        if entry.control { controlBytes -= entry.bytes.count }
        else if let reservation = entry.reservation { inputBytes -= reservation.encodedByteCount }
        else if entry.fileTransfer { fileRPCBytes -= entry.bytes.count }
        else { rpcBytes -= entry.bytes.count }
    }
}
