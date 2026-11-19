import Foundation

extension HCJSONValue {
    subscript(_ key: String) -> HCJSONValue { object?[key] ?? .null }
    var object: [String: HCJSONValue]? { if case .object(let v) = self { return v }; return nil }
    var array: [HCJSONValue]? { if case .array(let v) = self { return v }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var integer: Int64? { if case .integer(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var uint: UInt64? { integer.flatMap(UInt64.init(exactly:)) }
    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> HCJSONValue { try JSONDecoder().decode(Self.self, from: data) }
}

struct HCWireFrame: Equatable, Sendable {
    enum Kind: UInt8, Sendable { case data = 0, credit, close, resize, focus, facts }
    let channel: UInt32
    let kind: Kind
    let payload: Data

    func encoded() throws -> Data {
        guard payload.count <= HCLimits.frameBytes else { throw HCUnavailableReason.bufferOverflow }
        var data = Data()
        data.appendLE(channel)
        data.append(kind.rawValue)
        data.appendLE(UInt32(payload.count))
        data.append(payload)
        return data
    }

    static func control(channel: UInt32, _ control: HCControl) throws -> Self {
        var payload = Data()
        let kind: Kind
        switch control {
        case .credit(let bytes): kind = .credit; payload.appendLE(bytes)
        case .close: kind = .close
        case .resize(let grid): kind = .resize; payload.appendLE(grid.columns); payload.appendLE(grid.rows)
        case .focus(let focused): kind = .focus; payload.append(focused ? 1 : 0)
        case .facts(let facts):
            kind = .facts
            var values: [String: HCJSONValue] = [:]
            func color(_ value: HCRGBColor?) -> HCJSONValue? {
                value.map { .string(String(format: "#%02x%02x%02x", $0.red, $0.green, $0.blue)) }
            }
            values["fg"] = color(facts.foreground)
            values["bg"] = color(facts.background)
            values["cursor"] = color(facts.cursor)
            if let width = facts.cellWidth, let height = facts.cellHeight {
                values["cell"] = .array([.integer(Int64(width)), .integer(Int64(height))])
            }
            payload = try HCJSONValue.object(values).encoded()
        }
        return Self(channel: channel, kind: kind, payload: payload)
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    func wireUInt32(at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << ($1 * 8) }
    }
}

/// Incremental frame decoder: only the current frame is retained, and a length
/// is checked before any payload storage is reserved. Delivery is synchronous
/// so callers cannot accidentally accumulate a second array of decoded frames.
struct HCWireDecoder {
    private var header = Data()
    private var payload = Data()
    private var expected: Int?

    mutating func feed(_ bytes: Data, receive: (HCWireFrame) throws -> Void) throws {
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            if expected == nil {
                let count = min(9 - header.count, bytes.endIndex - offset)
                header.append(bytes[offset..<(offset + count)])
                offset += count
                guard header.count == 9 else { continue }
                guard HCWireFrame.Kind(rawValue: header[4]) != nil else { throw HCUnavailableReason.malformedResponse }
                let length = Int(header.wireUInt32(at: 5))
                guard length <= HCLimits.frameBytes else { throw HCUnavailableReason.bufferOverflow }
                let kind = header[4]
                guard (kind != 1 && kind != 3 || length == 4), (kind != 4 || length == 1) else {
                    throw HCUnavailableReason.malformedResponse
                }
                expected = length
            }
            let count = min(expected! - payload.count, bytes.endIndex - offset)
            payload.append(bytes[offset..<(offset + count)])
            offset += count
            if payload.count == expected! {
                let frame = HCWireFrame(channel: header.wireUInt32(at: 0),
                                        kind: HCWireFrame.Kind(rawValue: header[4])!, payload: payload)
                header = Data(); payload = Data(); expected = nil
                try receive(frame)
            }
        }
    }

    func finish() throws {
        guard header.isEmpty && payload.isEmpty else { throw HCUnavailableReason.malformedResponse }
    }
}

/// Incomplete event lines share the inventory's finite byte budget.
struct HCEventLines {
    private(set) var pending = Data()
    mutating func feed(_ bytes: Data, receive: (HCJSONValue) throws -> Void) throws {
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
            guard pending.count + end - start <= HCLimits.eventBufferBytes else { throw HCUnavailableReason.bufferOverflow }
            pending.append(bytes[start..<end])
            if end == bytes.endIndex { break }
            guard !pending.isEmpty else { throw HCUnavailableReason.malformedResponse }
            let line = try HCJSONValue.decode(pending)
            pending = Data()
            try receive(line)
            start = end + 1
        }
    }
}

/// Shared by early-channel storage and retained event lines. A reservation is
/// conservative during handoff so the combined allocation never exceeds L7.
final class HCInboundBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    func reserve(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count >= 0, count <= HCLimits.eventBufferBytes - bytes else { return false }
        bytes += count; return true
    }
    func release(_ count: Int) { lock.lock(); bytes -= count; assert(bytes >= 0); lock.unlock() }
}

/// hc allocates monotonically increasing channel IDs. Compact retired runs so
/// a long-lived inventory channel does not retain one tombstone per closed panel.
struct HCChannelRetirements {
    private var ranges: [(lower: UInt32, upper: UInt32)] = []
    var rangeCount: Int { ranges.count }
    func contains(_ channel: UInt32) -> Bool {
        ranges.contains { $0.lower <= channel && channel <= $0.upper }
    }
    mutating func insert(_ channel: UInt32) {
        var lower = channel; var upper = channel
        var next: [(lower: UInt32, upper: UInt32)] = []
        var inserted = false
        for range in ranges {
            if UInt64(range.upper) + 1 < UInt64(lower) { next.append(range) }
            else if UInt64(upper) + 1 < UInt64(range.lower) {
                if !inserted { next.append((lower, upper)); inserted = true }
                next.append(range)
            } else { lower = min(lower, range.lower); upper = max(upper, range.upper) }
        }
        if !inserted { next.append((lower, upper)) }
        ranges = next
    }
}

extension HCUnavailableReason {
    static func transportReason(_ error: Error) -> HCUnavailableReason {
        if let reason = error as? HCUnavailableReason { return reason }
        if let failure = error as? HCRPCFailure { return failure.reason }
        if error is CancellationError { return .cancelled }
        return .malformedResponse
    }
}

/// Fixed tokens only; composition owns recording and never receives contents.
typealias HCTransportReport = @Sendable (String, UInt64, UInt64?) -> Void

/// A slow recorder cannot stall socket or inventory work. Retain the newest
/// 64 pending facts; diagnostic loss never changes canonical backend state.
final class HCTransportReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "c11.hc.diagnostics", qos: .utility)
    private let sink: HCTransportReport
    private var pending: [(String, UInt64, UInt64?)] = []
    private var scheduled = false
    init(_ sink: @escaping HCTransportReport) { self.sink = sink }
    func emit(_ event: String, generation: UInt64, elapsedNanoseconds: UInt64? = nil) {
        lock.lock()
        if pending.count == 64 { pending.removeFirst() }
        pending.append((event, generation, elapsedNanoseconds))
        guard !scheduled else { lock.unlock(); return }
        scheduled = true; lock.unlock()
        queue.async { self.drain() }
    }
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else { scheduled = false; lock.unlock(); return }
            let next = pending.removeFirst(); lock.unlock()
            autoreleasepool { sink(next.0, next.1, next.2) }
        }
    }
}
