import Foundation

/// One caller deadline covers queueing, capture, and worker encoding. The main
/// callback may outlive the caller, but cannot start abandoned work or publish
/// a late result. A capture already running must finish its own native cleanup.
final class SelectionReadOperation<Value>: @unchecked Sendable {
    private enum State { case queued, capturing, completed(Value), abandoned }
    private let lock = NSLock()
    private let wake = DispatchSemaphore(value: 0)
    private var state: State = .queued
    let deadline: DispatchTime

    init(timeout: TimeInterval = 5) {
        deadline = .now() + timeout
    }

    func beginCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard DispatchTime.now() < deadline else {
            state = .abandoned
            return false
        }
        guard case .queued = state else { return false }
        state = .capturing
        return true
    }

    @discardableResult func complete(_ value: Value) -> Bool {
        lock.lock()
        guard DispatchTime.now() < deadline else {
            state = .abandoned
            lock.unlock()
            wake.signal()
            return false
        }
        guard case .capturing = state else { lock.unlock(); return false }
        state = .completed(value)
        lock.unlock()
        wake.signal()
        return true
    }

    func wait() -> Value? {
        _ = wake.wait(timeout: deadline)
        lock.lock()
        defer { lock.unlock() }
        guard DispatchTime.now() < deadline, case .completed(let value) = state else {
            state = .abandoned
            return nil
        }
        return value
    }

    var canPublish: Bool { DispatchTime.now() < deadline }
}

enum SelectionRead {
    static let byteLimit = 1_048_576

    /// Native capture copies a prefix on main. Drop only an incomplete final
    /// UTF-8 scalar on the worker, without changing the selected bytes otherwise.
    static func utf8Prefix(_ bytes: Data, originalCount: Int) -> (data: Data, truncated: Bool) {
        var count = min(bytes.count, byteLimit)
        if originalCount > count, count > 0 {
            var start = count - 1
            while start > 0, bytes[start] & 0xC0 == 0x80 { start -= 1 }
            let first = bytes[start]
            let width = first < 0x80 ? 1 : first & 0xE0 == 0xC0 ? 2
                : first & 0xF0 == 0xE0 ? 3 : first & 0xF8 == 0xF0 ? 4 : 1
            if start + width > count { count = start }
        }
        return (Data(bytes.prefix(count)), originalCount > count)
    }
}
