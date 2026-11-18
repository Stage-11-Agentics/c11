import Foundation

/// A delayed action carries this exact stamp, never a newly resolved panel.
struct HCInputStamp: Equatable, Sendable {
    let panelID: UUID
    let key: HCTerminalKey
    let attachmentGeneration: UInt64
    let epoch: UInt64
}

/// Synchronous invalidation is shared by native callbacks and main's delayed
/// Returns. No task hop can leave a stale Return temporarily authorized.
final class HCInputGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private let panelID: UUID
    private let key: HCTerminalKey
    private var generation: UInt64
    private var epoch: UInt64 = 0
    private var refusal: HCInputRefusal?

    init(panelID: UUID, key: HCTerminalKey, generation: UInt64) {
        self.panelID = panelID
        self.key = key
        self.generation = generation
    }

    func capture() -> HCInputStamp? {
        lock.lock()
        defer { lock.unlock() }
        guard refusal == nil else { return nil }
        return HCInputStamp(panelID: panelID, key: key, attachmentGeneration: generation, epoch: epoch)
    }

    func refusal(for stamp: HCInputStamp) -> HCInputRefusal? {
        lock.lock()
        defer { lock.unlock() }
        guard stamp.panelID == panelID, stamp.key == key,
              stamp.attachmentGeneration == generation, stamp.epoch == epoch else { return .staleIdentity }
        return refusal
    }

    func invalidate(generation expected: UInt64, reason: HCInputRefusal) {
        lock.lock()
        defer { lock.unlock() }
        guard expected == generation else { return }
        refusal = reason
        epoch &+= 1
    }

    /// Why the port is closed, if it is: the reason it was invalidated with.
    var currentRefusal: HCInputRefusal? {
        lock.lock(); defer { lock.unlock() }
        return refusal
    }

    var faultToken: UInt64? {
        lock.lock(); defer { lock.unlock() }
        return refusal == nil ? nil : epoch
    }

    func clearFault(receipt: HCScreenReceipt, expected: HCDisplayRevision,
                    interruptedGeneration: UInt64, faultToken: UInt64) -> Bool {
        clearFaultRefusal(receipt: receipt, expected: expected,
                          interruptedGeneration: interruptedGeneration, faultToken: faultToken) == nil
    }

    /// `clearFault`, naming the guard that refused (nil when the fault cleared).
    func clearFaultRefusal(receipt: HCScreenReceipt, expected: HCDisplayRevision,
                           interruptedGeneration: UInt64, faultToken: UInt64) -> HCRetryRefusal? {
        lock.lock()
        defer { lock.unlock() }
        guard refusal != nil else { return HCRetryRefusal(.stateMismatch, "gate.notFaulted", "port=\(generation)") }
        guard epoch == faultToken else {
            return HCRetryRefusal(.newInterruption, "gate.faultToken", "epoch=\(epoch) token=\(faultToken)")
        }
        guard expected.attachmentGeneration == generation else {
            return HCRetryRefusal(.connectionChanged, "gate.displayGeneration",
                                  "display=\(expected.attachmentGeneration) port=\(generation)")
        }
        guard generation > interruptedGeneration else {
            return HCRetryRefusal(.reconnecting, "gate.freshGeneration",
                                  "port=\(generation) interrupted=\(interruptedGeneration)")
        }
        guard receipt.revision == expected else {
            return HCRetryRefusal(.screenNotSettled, "gate.receiptRevision",
                                  "receipt=\(receipt.revision.logText) expected=\(expected.logText)")
        }
        guard receipt.columns > 0, receipt.rows > 0 else {
            return HCRetryRefusal(.screenNotSettled, "gate.receiptGrid", "grid=\(receipt.columns)x\(receipt.rows)")
        }
        epoch &+= 1
        refusal = nil
        return nil
    }

    /// Ticket 6 calls only for explicit Retry input with the newly parsed
    /// attachment. Reconnecting alone never clears a latched input fault.
    @discardableResult
    func retryInput(receipt: HCScreenReceipt, expected: HCDisplayRevision) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard refusal != nil, expected.attachmentGeneration > generation,
              receipt.revision == expected, receipt.columns > 0, receipt.rows > 0 else { return false }
        generation = expected.attachmentGeneration
        epoch &+= 1
        refusal = nil
        return true
    }
}

/// Why Retry input did not resume input (C11H-124): the guard that refused, the
/// values it compared, and the plain reason the bar and `c11 retry-input` show.
struct HCRetryRefusal: Equatable, Sendable {
    enum Reason: String, Sendable {
        case notPaused, retrying, reconnecting, inputInFlight, screenNotSettled, newInterruption, connectionChanged,
             stateMismatch
    }
    let reason: Reason
    /// The refusing guard, `layer.check` (e.g. `gate.freshGeneration`).
    let check: String
    /// The values the guard compared, `name=value` pairs.
    let values: String

    init(_ reason: Reason, _ check: String, _ values: String = "") {
        self.reason = reason
        self.check = check
        self.values = values
    }

    /// The reason in plain words, for "Retry failed: <reason>".
    var text: String {
        switch reason {
        case .notPaused:
            return String(localized: "hc.input.retryReason.notPaused", defaultValue: "input was not paused")
        case .retrying:
            return String(localized: "hc.input.retryReason.retrying", defaultValue: "a retry is already running")
        case .reconnecting:
            return String(localized: "hc.input.retryReason.reconnecting", defaultValue: "the terminal is still reconnecting")
        case .inputInFlight:
            return String(localized: "hc.input.retryReason.inputInFlight", defaultValue: "earlier input is still being sent")
        case .screenNotSettled:
            return String(localized: "hc.input.retryReason.screenNotSettled", defaultValue: "the screen did not settle")
        case .newInterruption:
            return String(localized: "hc.input.retryReason.newInterruption", defaultValue: "another interruption happened")
        case .connectionChanged:
            return String(localized: "hc.input.retryReason.connectionChanged", defaultValue: "the terminal connection changed")
        case .stateMismatch:
            return String(localized: "hc.input.retryReason.stateMismatch", defaultValue: "the terminal's input state did not match")
        }
    }

    /// The line the bar shows after a refused retry.
    var failureMessage: String {
        String(format: String(localized: "hc.input.retryFailed", defaultValue: "Retry failed: %@."), text)
    }

    /// One notice-level log line: panel, guard, reason and compared values.
    func logLine(panelID: UUID) -> String {
        "retry refused panel=\(panelID.uuidString) guard=\(check) reason=\(reason.rawValue)"
            + (values.isEmpty ? "" : " " + values)
    }
}

extension HCDisplayRevision {
    /// `attachment.display`, for logs.
    var logText: String { "\(attachmentGeneration).\(displayGeneration)" }
}
