import AppKit
import CryptoKit

/// Renders Mermaid diagram code to images via the `mmdc` CLI tool.
/// Falls back gracefully when mmdc is not installed.
final class MermaidRenderer {
    static let shared = MermaidRenderer()

    /// Maximum input size (50 KB) to prevent runaway rendering.
    private static let maxInputBytes = 50 * 1024
    /// Timeout for each mmdc invocation.
    private static let renderTimeout: TimeInterval = 15

    private let cacheDirectory: URL
    private var mmdcPath: String?
    private var mmdcChecked = false
    private let queue = DispatchQueue(label: "com.cmux.mermaid-renderer", qos: .userInitiated)

    var isAvailable: Bool {
        resolveMmdc() != nil
    }

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("com.cmux.mermaid", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    /// Resolve the mmdc binary path, caching the result.
    private func resolveMmdc() -> String? {
        if mmdcChecked { return mmdcPath }
        mmdcChecked = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["mmdc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, !path.isEmpty {
                    mmdcPath = path
                }
            }
        } catch {}
        return mmdcPath
    }

    /// Cache key from content hash and theme.
    private func cacheKey(code: String, isDark: Bool) -> String {
        let input = code + (isDark ? ":dark" : ":light")
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Render mermaid code to an NSImage. Returns nil if mmdc is unavailable or rendering fails.
    func render(code: String, isDark: Bool, completion: @escaping (NSImage?) -> Void) {
        queue.async { [self] in
            guard let mmdc = resolveMmdc() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Reject oversized input
            guard code.utf8.count <= Self.maxInputBytes else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let key = cacheKey(code: code, isDark: isDark)
            let cachedPng = cacheDirectory.appendingPathComponent("\(key).png")

            // Check cache
            if FileManager.default.fileExists(atPath: cachedPng.path),
               let image = NSImage(contentsOf: cachedPng) {
                DispatchQueue.main.async { completion(image) }
                return
            }

            // Write temp input file
            let inputFile = cacheDirectory.appendingPathComponent("\(key).mmd")
            let outputFile = cacheDirectory.appendingPathComponent("\(key)-out.png")
            do {
                try code.write(to: inputFile, atomically: true, encoding: .utf8)
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            defer {
                try? FileManager.default.removeItem(at: inputFile)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: mmdc)
            process.arguments = [
                "-i", inputFile.path,
                "-o", outputFile.path,
                "-t", isDark ? "dark" : "default",
                "-b", "transparent",
                "-s", "2"
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            // Set up PATH to include common node/npm locations
            var env = ProcessInfo.processInfo.environment
            let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "\(NSHomeDirectory())/.nvm/versions/node"]
            if let existingPath = env["PATH"] {
                env["PATH"] = extraPaths.joined(separator: ":") + ":" + existingPath
            }
            process.environment = env

            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Timeout handling
            let deadline = DispatchTime.now() + Self.renderTimeout
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                process.waitUntilExit()
                group.leave()
            }

            if group.wait(timeout: deadline) == .timedOut {
                process.terminate()
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard process.terminationStatus == 0 else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // mmdc may produce output with -1 suffix (e.g. key-out-1.png)
            let altOutputFile = cacheDirectory.appendingPathComponent("\(key)-out-1.png")
            let actualOutput: URL
            if FileManager.default.fileExists(atPath: outputFile.path) {
                actualOutput = outputFile
            } else if FileManager.default.fileExists(atPath: altOutputFile.path) {
                actualOutput = altOutputFile
            } else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Move to cache location
            try? FileManager.default.removeItem(at: cachedPng)
            try? FileManager.default.moveItem(at: actualOutput, to: cachedPng)
            // Clean up alternate if it exists
            try? FileManager.default.removeItem(at: altOutputFile)

            guard let image = NSImage(contentsOf: cachedPng) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            DispatchQueue.main.async { completion(image) }
        }
    }
}
