// Linux only: the os.Logger surface two shared HC files use (Logger, its levels, and `\(x, privacy: .public)`).
// The CLI has no unified log on Linux; these calls write nothing.
public enum OSLogPrivacy: Sendable { case auto, `public`, `private`, sensitive }

public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, privacy: OSLogPrivacy = .auto) {}
    }
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
}

public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    public init() {}
    public func log(_ message: OSLogMessage) {}
    public func debug(_ message: OSLogMessage) {}
    public func info(_ message: OSLogMessage) {}
    public func notice(_ message: OSLogMessage) {}
    public func warning(_ message: OSLogMessage) {}
    public func error(_ message: OSLogMessage) {}
    public func fault(_ message: OSLogMessage) {}
    public func critical(_ message: OSLogMessage) {}
    public func trace(_ message: OSLogMessage) {}
}
