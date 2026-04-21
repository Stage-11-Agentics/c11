import Foundation
import OSLog

public enum ThemeDiagnostics {
    private static let subsystem = "com.stage11.c11"

    private static let engineLogger = Logger(subsystem: subsystem, category: "theme.engine")
    private static let loaderLogger = Logger(subsystem: subsystem, category: "theme.loader")
    private static let resolverLogger = Logger(subsystem: subsystem, category: "theme.resolver")

    private static var dedupedWarnings: Set<String> = []
    private static let lock = NSLock()

    public static func engine(_ message: String) {
        engineLogger.log("\(message, privacy: .public)")
    }

    public static func loader(_ message: String) {
        loaderLogger.log("\(message, privacy: .public)")
    }

    public static func resolver(_ message: String) {
        resolverLogger.log("\(message, privacy: .public)")
    }

    public static func loaderWarnOnce(themeName: String, key: String, message: String) {
        warnOnce(channel: .loader, dedupeKey: "loader|\(themeName)|\(key)", message: message)
    }

    public static func resolverWarnOnce(themeName: String, key: String, message: String) {
        warnOnce(channel: .resolver, dedupeKey: "resolver|\(themeName)|\(key)", message: message)
    }

    public static func resetForTesting() {
        lock.lock()
        dedupedWarnings.removeAll()
        lock.unlock()
    }

    private enum Channel {
        case loader
        case resolver
    }

    private static func warnOnce(channel: Channel, dedupeKey: String, message: String) {
        lock.lock()
        let inserted = dedupedWarnings.insert(dedupeKey).inserted
        lock.unlock()

        guard inserted else { return }
        switch channel {
        case .loader:
            loader("warning: \(message)")
        case .resolver:
            resolver("warning: \(message)")
        }
    }
}
