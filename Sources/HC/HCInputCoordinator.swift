import Foundation
import os

/// Encoding is a capture operation, not transmission. The native implementation
/// must prove completion and attribute callbacks to this operation before it
/// returns bytes. The unavailable implementation refuses before native entry.
protocol HCInputEncoder: Sendable {
    /// Includes every 9-byte wire header as well as native encoding/Return.
    func maximumEncodedBytes(for request: HCInputRequest) -> Int?
    func encode(_ request: HCInputRequest) async -> Result<[HCOutboundFrame], HCInputRefusal>
}

struct HCUnavailableInputEncoder: HCInputEncoder {
    func maximumEncodedBytes(for request: HCInputRequest) -> Int? { nil }
    func encode(_ request: HCInputRequest) async -> Result<[HCOutboundFrame], HCInputRefusal> {
        .failure(.unavailable)
    }
}

/// Transaction policy above 2B's sole charged wire queue. All admission and
/// invalidation decisions are synchronous; only screen/encoding/writes suspend.
final class HCInputCoordinator: HCInputPort, @unchecked Sendable {
    private let panelID: UUID
    private let key: HCTerminalKey
    private let generation: UInt64
    private let displayRevision: @Sendable () -> HCDisplayRevision
    let gate: HCInputGeneration
    private let writer: any HCFrameWriter
    private let encoder: any HCInputEncoder
    private let screen: any HCScreenProvider
    private let report: @Sendable (HCInputOutcome) -> Void
    /// Where submitted outcomes in `reportedSources` go; nil sends them to `report`. Raw
    /// outcomes always go to `report` (C11H-443: the owner tells them apart).
    private let reportSubmitted: (@Sendable (HCInputOutcome) -> Void)?
    /// Raw outcomes with who made the bytes, by their shape (C11H-443): every closed-port
    /// refusal, and each successful write while `attributesWrites` is on. Nil sends them to
    /// `report`.
    private let reportRawAttributed: (@Sendable (HCInputOutcome, HCInputAttribution) -> Void)?
    private let claimInBandGrid: @Sendable (UInt16, UInt16) -> Bool
    /// Programmatic outcomes the owner records itself (it receives them from
    /// `submit`) are not also sent to `report`; raw outcomes always are.
    private let reportedSources: Set<HCInputSource>
    private let lock = NSLock()
    /// Admission is policy, not a fault: a closed port refuses visibly with
    /// `.unavailable` and neither latches, queues nor replays anything.
    private var admitted: Bool
    private var pending: [UUID: HCWriteReservation] = [:]
    private var invalid: HCInputRefusal?
    private var programmaticActive = false
    private var rawQueue: [([HCOutboundFrame], HCWriteReservation)?] = Array(repeating: nil, count: 256)
    private var rawHead = 0
    private var rawCount = 0
    private var rawDraining = false
    /// C11H-443: the first raw writes this port refuses while closed are logged by byte class.
    private var refusalsLogged = 0
    /// C11H-443: on only while the operator's reconnect notice is up. Each successful raw
    /// write is then classified, so the notice clears on the operator's own keystroke and on
    /// nothing else. Off, a successful write is reported exactly as before.
    private var attributesWrites = false

    init(panelID: UUID, key: HCTerminalKey, generation: UInt64,
         writer: any HCFrameWriter, encoder: any HCInputEncoder,
         screen: any HCScreenProvider,
         displayRevision: @escaping @Sendable () -> HCDisplayRevision,
         report: @escaping @Sendable (HCInputOutcome) -> Void,
         reportSubmitted: (@Sendable (HCInputOutcome) -> Void)? = nil,
         reportRawAttributed: (@Sendable (HCInputOutcome, HCInputAttribution) -> Void)? = nil,
         claimInBandGrid: @escaping @Sendable (UInt16, UInt16) -> Bool = { _, _ in true },
         admitted: Bool = true,
         reportedSources: Set<HCInputSource> = Set([.socket, .textBox, .filePaste, .feed, .mailbox,
                                                    .launchPrompt, .resume, .initial, .drop])) {
        self.panelID = panelID
        self.key = key
        self.generation = generation
        self.writer = writer
        self.encoder = encoder
        self.screen = screen
        self.displayRevision = displayRevision
        self.report = report
        self.reportSubmitted = reportSubmitted
        self.reportRawAttributed = reportRawAttributed
        self.claimInBandGrid = claimInBandGrid
        self.admitted = admitted
        self.reportedSources = reportedSources
        gate = HCInputGeneration(panelID: panelID, key: key, generation: generation)
    }

    func submit(_ request: HCInputRequest) async -> HCInputOutcome {
        let outcome = await perform(request)
        if reportedSources.contains(request.source) { (reportSubmitted ?? report)(outcome) }
        return outcome
    }

    private func perform(_ request: HCInputRequest) async -> HCInputOutcome {
        guard request.panelID == panelID, request.key == key,
              request.attachmentGeneration == generation else { return .refused(.staleIdentity) }
        guard request.payload.count <= HCLimits.transactionBytes else { return .refused(.tooLarge) }
        // A closed port reports why it is closed. A connection loss or a detach
        // closes it as `.unavailable` or `.staleIdentity`; naming that an input
        // fault latched a "Input interrupted" fault on the panel for a send that
        // wrote nothing, and every replacement port was then born closed (C11H-82).
        guard let stamp = gate.capture() else { return .refused(gate.currentRefusal ?? .inputFault) }
        guard let capacity = encoder.maximumEncodedBytes(for: request) else { return .refused(.unavailable) }
        guard capacity > 0, capacity <= HCLimits.transactionBytes else { return .refused(.tooLarge) }
        let reservation: HCWriteReservation
        // Backend-owned initial input is submitted before the owner adopts and
        // opens the port; it is sent once per creation and is never replayed.
        switch reserve(id: request.operationID, count: capacity, programmatic: true,
                       admissionExempt: request.source == .initial) {
        case .reserved(let value): reservation = value
        case .refused(let reason): return .refused(reason)
        }
        defer { finish(reservation, programmatic: true) }

        if let reason = gate.refusal(for: stamp) { return .refused(reason) }
        let frames: [HCOutboundFrame]
        switch await encoder.encode(request) {
        case .success(let encoded): frames = encoded
        case .failure(let reason): return .refused(reason)
        }
        if let reason = gate.refusal(for: stamp) { return .refused(reason) }
        guard !Task.isCancelled else { return .refused(.cancelled) }
        // Defensive admission verification is about executable output, not a
        // native text call's return. No bytes have left during encoding.
        var count = 0
        var returnCount = 0
        for frame in frames {
            let size: Int
            switch frame {
            case .data(let bytes):
                guard returnCount == 0 else { return .refused(.unavailable) }
                size = bytes.count
            case .submitReturn(let bytes), .submitReturnAfter(let bytes, delayNanoseconds: _):
                guard !bytes.isEmpty else { return .refused(.unavailable) }
                returnCount += 1
                size = bytes.count
            default: return .refused(.unavailable)
            }
            guard capacity - count >= 9, size <= capacity - count - 9 else { return .refused(.tooLarge) }
            count += size + 9
        }
        guard returnCount == (request.submitReturn ? 1 : 0),
              !frames.isEmpty else { return .refused(.unavailable) }
        if let guardScreen = request.screenGuard {
            let revision = displayRevision()
            guard revision.attachmentGeneration == generation,
                  let receipt = await screen.screenCurrent(after: revision),
                  receipt.revision == revision, displayRevision() == revision else {
                return .refused(.screenUnavailable)
            }
            guard await guardScreen(receipt) else { return .refused(.guardRefused) }
            guard displayRevision() == revision else { return .refused(.screenUnavailable) }
        }
        // C11H-167: the screen-independent check, after encoding and before any byte is written.
        if let eligible = request.eligibility, !(await eligible()) { return .refused(.guardRefused) }
        if let reason = gate.refusal(for: stamp) { return .refused(reason) }
        guard !Task.isCancelled else { return .refused(.cancelled) }
        let beforeReturn: (@Sendable () async -> Bool)?
        if request.returnGuard == nil, let eligible = request.eligibility {
            // No screen to judge: ask the same check again before the Return; a no cuts the write (paused).
            beforeReturn = { [self] in
                guard !Task.isCancelled, gate.refusal(for: stamp) == nil else {
                    Self.logReturnCheck(generation: generation, attempt: 0, outcome: "gate")
                    return false
                }
                guard await eligible() else {
                    Self.logReturnCheck(generation: generation, attempt: 0, outcome: "not_eligible")
                    return false
                }
                return !Task.isCancelled && gate.refusal(for: stamp) == nil
            }
        } else if let predicate = request.returnGuard {
            beforeReturn = { [self] in
                // The check runs after the body is out, so a no also costs the
                // pause (C11H-124). The display revision moves for reasons that
                // say nothing about the prompt: a panel opening or closing
                // re-lays-out the splits and resizes the terminal. Judge the
                // new screen once more before giving up; a second move, a
                // reattach, a closed gate or a prompt that changed is a no.
                for attempt in 0..<2 {
                    guard !Task.isCancelled, gate.refusal(for: stamp) == nil else {
                        Self.logReturnCheck(generation: generation, attempt: attempt, outcome: "gate")
                        return false
                    }
                    let revision = displayRevision()
                    guard revision.attachmentGeneration == generation else {
                        Self.logReturnCheck(generation: generation, attempt: attempt, outcome: "reattached")
                        return false
                    }
                    guard let receipt = await screen.screenCurrent(after: revision) else {
                        if displayRevision() != revision { continue }
                        Self.logReturnCheck(generation: generation, attempt: attempt, outcome: "screen_unavailable")
                        return false
                    }
                    guard receipt.revision == revision, displayRevision() == revision else {
                        continue
                    }
                    let allowed = await predicate(receipt)
                    // A verdict about an obsolete screen cannot authorize or
                    // reject the current composer. Re-read it within the same bound.
                    guard displayRevision() == revision else { continue }
                    guard allowed else {
                        Self.logReturnCheck(generation: generation, attempt: attempt, outcome: "prompt_changed")
                        return false
                    }
                    let open = !Task.isCancelled && gate.refusal(for: stamp) == nil
                    if !open { Self.logReturnCheck(generation: generation, attempt: attempt, outcome: "gate") }
                    return open
                }
                Self.logReturnCheck(generation: generation, attempt: 1, outcome: "screen_moved")
                return false
            }
        } else {
            beforeReturn = nil
        }
        let writer = writer
        let outcome = await withTaskCancellationHandler {
            await writer.write(HCWriteBatch(operationID: request.operationID,
                attachmentGeneration: generation, frames: frames, beforeReturn: beforeReturn), reservation: reservation)
        } onCancel: {
            // Cancellation revokes the remainder and delayed Return; the writer
            // still reports bytes already handed to the socket accurately.
            writer.cancel(reservation)
        }
        if case .uncertain = outcome { invalidate(generation: generation, reason: .inputFault) }
        return outcome
    }

    private static let logger = Logger(subsystem: "com.stage11.c11", category: "hc.input")

    /// Why a delayed Return was not sent. Notice level so it is kept: the
    /// debug trace is not persisted, and a cut write leaves only this record.
    static func logReturnCheck(generation: UInt64, attempt: Int, outcome: String) {
        logger.notice("return check refused generation=\(generation) attempt=\(attempt) cause=\(outcome, privacy: .public)")
    }

    private func reserve(id: UUID, count: Int, programmatic: Bool,
                         admissionExempt: Bool = false) -> HCReservationOutcome {
        lock.lock()
        defer { lock.unlock() }
        if let invalid { return .refused(invalid) }
        if programmatic, !admitted, !admissionExempt { return .refused(.unavailable) }
        // Bounds task overhead for tiny key/query writes independently of bytes.
        guard pending.count < 256, pending[id] == nil,
              !programmatic || !programmaticActive else { return .refused(.queueFull) }
        let result = writer.reserve(operationID: id, attachmentGeneration: generation, encodedByteCount: count)
        if case .reserved(let reservation) = result {
            pending[id] = reservation
            if programmatic { programmaticActive = true }
        }
        return result
    }

    private func finish(_ reservation: HCWriteReservation, programmatic: Bool) {
        lock.lock()
        pending.removeValue(forKey: reservation.operationID)
        if programmatic { programmaticActive = false }
        lock.unlock()
        writer.cancel(reservation) // Idempotent release, including encode/guard refusal.
    }

    func receiveRaw(_ bytes: Data, kind: HCRawInputKind, generation expected: UInt64) {
        guard expected == generation else { report(.refused(.staleIdentity)); return }
        guard !bytes.isEmpty else { return }
        // hc emits the program's mode-1004 sequence for each FOCUS control.
        // The rendering adapter owns those controls even when mode 1004 is off;
        // forwarding native focus callbacks as DATA or FOCUS duplicates them.
        if bytes == Data([0x1b, 0x5b, 0x49]) || bytes == Data([0x1b, 0x5b, 0x4f]) { return }
        // Operator paste needs the separately proven pre-native reservation;
        // an unattributed callback can never retroactively reserve a paste.
        lock.lock()
        let closed = !admitted && invalid == nil
        let closedReason = invalid
        lock.unlock()
        // A reconnecting port refuses raw bytes visibly and drops them; unlike a
        // queue overflow this is an expected state and does not latch a fault.
        if closed { refuseClosed(bytes, .unavailable); return }
        // A port closed by a connection loss or a detach is the same expected
        // state, not a fault: nothing was written and nothing is half-sent.
        if let reason = closedReason, reason != .inputFault { refuseClosed(bytes, reason); return }
        guard kind != .paste else { fault(.unavailable); return }
        guard bytes.count <= HCLimits.transactionBytes - 9 else { fault(.tooLarge); return }
        let grid = Self.inBandGrid(bytes)
        // Reserve the optional RESIZE before mutating the renderer's sent grid.
        let capacity = bytes.count + 9 + (grid == nil ? 0 : 13)
        guard capacity <= HCLimits.transactionBytes else { fault(.tooLarge); return }
        let id = UUID()
        let reservation: HCWriteReservation
        switch reserve(id: id, count: capacity, programmatic: false) {
        case .reserved(let value): reservation = value
        case .refused(let reason): fault(reason); return
        }
        let frames: [HCOutboundFrame]
        if let grid, claimInBandGrid(grid.columns, grid.rows) {
            frames = [.resize(grid), .data(bytes)]
        } else { frames = [.data(bytes)] }
        enqueueRaw(frames, reservation: reservation)
    }

    /// Refusal path only: an open port never comes here. The refusal says who made the bytes
    /// (C11H-443): Ghostty's own reports raise no bar.
    private func refuseClosed(_ bytes: Data, _ reason: HCInputRefusal) {
        lock.lock()
        let logs = refusalsLogged < HCRawInputClass.logLimit
        if logs { refusalsLogged += 1 }
        lock.unlock()
        bytes.withUnsafeBytes { raw in
            if logs { HCRawInputClass.log(panelID: panelID, port: String(generation), raw) }
            if let reportRawAttributed {
                reportRawAttributed(.refused(reason), HCRawInputClass.attribution(raw))
            } else {
                report(.refused(reason))
            }
        }
    }

    private func enqueueRaw(_ frames: [HCOutboundFrame], reservation: HCWriteReservation) {
        lock.lock()
        // Every retained byte has an existing wire reservation. One task drains
        // the callbacks in arrival order; independent Tasks can reorder keys.
        // pending is capped at this ring's capacity before enqueue; draining
        // removes a slot before releasing its reservation. No grow/shift here.
        rawQueue[(rawHead + rawCount) % rawQueue.count] = (frames, reservation)
        rawCount += 1
        if !rawDraining {
            rawDraining = true
            Task { await self.drainRaw() }
        }
        lock.unlock()
    }

    private func takeRaw() -> ([HCOutboundFrame], HCWriteReservation, attributes: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        guard rawCount > 0 else { rawDraining = false; return nil }
        let result = rawQueue[rawHead]
        rawQueue[rawHead] = nil
        rawHead = (rawHead + 1) % rawQueue.count
        rawCount -= 1
        return result.map { ($0.0, $0.1, attributesWrites) }
    }

    private func drainRaw() async {
        while let (frames, reservation, attributes) = takeRaw() {
            let outcome = await writer.write(HCWriteBatch(operationID: reservation.operationID,
                attachmentGeneration: generation, frames: frames), reservation: reservation)
            finish(reservation, programmatic: false)
            if case .uncertain = outcome { invalidate(generation: generation, reason: .inputFault) }
            // The flag was read under the lock takeRaw already holds: off, nothing more runs.
            if attributes, case .written = outcome, let reportRawAttributed {
                reportRawAttributed(outcome, Self.attribution(of: frames))
            } else {
                report(outcome)
            }
        }
    }

    /// Who made a raw write that went through: a claimed in-band RESIZE is Ghostty's size
    /// report; otherwise the bytes' shape says.
    private static func attribution(of frames: [HCOutboundFrame]) -> HCInputAttribution {
        for frame in frames {
            switch frame {
            case .resize: return .terminal
            case .data(let bytes): return bytes.withUnsafeBytes { HCRawInputClass.attribution($0) }
            default: continue
            }
        }
        return .native
    }

    /// Turns attribution of successful raw writes on or off (C11H-443). The owner turns it on
    /// only while the operator's reconnect notice is up.
    func attributeWrites(_ on: Bool) {
        lock.lock()
        attributesWrites = on
        lock.unlock()
    }

    /// Only a complete native mode-2048 report is translated. Every other byte
    /// sequence (including malformed/partial reports) stays unchanged as DATA.
    private static func inBandGrid(_ bytes: Data) -> HCGridSize? {
        guard bytes.count <= 64, bytes.starts(with: [0x1b, 0x5b, 0x34, 0x38, 0x3b]),
              bytes.last == 0x74 else { return nil }
        let fields = bytes.dropFirst(5).dropLast().split(separator: 0x3b, omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        var numbers: [UInt32] = []
        for field in fields {
            guard !field.isEmpty, field.count <= 10 else { return nil }
            var value: UInt32 = 0
            for byte in field {
                guard byte >= 48, byte <= 57 else { return nil }
                let (scaled, overflow) = value.multipliedReportingOverflow(by: 10)
                let (sum, overflow2) = scaled.addingReportingOverflow(UInt32(byte - 48))
                guard !overflow, !overflow2 else { return nil }
                value = sum
            }
            numbers.append(value)
        }
        guard let rows = UInt16(exactly: numbers[0]), rows > 0,
              let columns = UInt16(exactly: numbers[1]), columns > 0 else { return nil }
        return HCGridSize(columns: columns, rows: rows)
    }

    private func fault(_ reason: HCInputRefusal) {
        invalidate(generation: generation, reason: .inputFault)
        report(.refused(reason))
        // Raw input may already have been split by native IO. Unlike a refused
        // programmatic transaction, this requires an explicit input-fault latch.
        if reason != .inputFault { report(.refused(.inputFault)) }
    }

    /// Composition calls this only after checking a fresh parsed receipt.
    /// No queued input is retained/replayed when reopening the port.
    /// Returns the refusing guard, or nil once the port is open to new input.
    func clearInputFault(receipt: HCScreenReceipt, interruptedGeneration: UInt64, faultToken: UInt64) -> HCRetryRefusal? {
        lock.lock()
        defer { lock.unlock() }
        guard invalid != nil else { return HCRetryRefusal(.stateMismatch, "port.notFaulted", "port=\(generation)") }
        guard pending.isEmpty else { return HCRetryRefusal(.inputInFlight, "port.pendingWrites", "pending=\(pending.count)") }
        if let refusal = gate.clearFaultRefusal(receipt: receipt, expected: displayRevision(),
                                                interruptedGeneration: interruptedGeneration, faultToken: faultToken) {
            return refusal
        }
        invalid = nil
        return nil
    }

    /// Opens or closes admission. Never clears a fault, cancels reserved writes
    /// or retains refused input; the owner decides when a port may accept bytes.
    func setAdmission(_ open: Bool) {
        lock.lock()
        admitted = open
        lock.unlock()
    }

    func invalidate(generation expected: UInt64, reason: HCInputRefusal) {
        guard expected == generation else { return }
        gate.invalidate(generation: generation, reason: reason)
        lock.lock()
        invalid = reason
        let reservations = Array(pending.values)
        lock.unlock()
        // 2B cancels remaining frames and returns the bytes already written.
        for reservation in reservations { writer.cancel(reservation) }
    }
}
