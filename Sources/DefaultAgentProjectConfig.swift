import Foundation

/// Walks up from a starting directory looking for `.c11/agents.json`. The first
/// match wins (deepest directory first). When the file exists and parses, it
/// overrides the user-level `DefaultAgentConfigStore.shared.current` for any
/// terminal surface launched within that directory tree.
///
/// Matches the precedence/walk pattern used by `WorkspaceBlueprintStore`.
enum DefaultAgentProjectConfig {

    /// Search from `cwd` upward to the filesystem root for `.c11/agents.json`.
    /// Returns the parsed config, or nil if no file was found / parsing failed.
    /// Parse failures are silently swallowed so a malformed project file cannot
    /// brick the new-terminal flow; the caller falls back to the user default.
    static func find(
        from cwd: String?,
        fileManager: FileManager = .default
    ) -> DefaultAgentConfig? {
        guard let cwd, !cwd.isEmpty else { return nil }
        var url = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL

        // Bound the walk so a deep-but-bogus cwd can't spin forever.
        for _ in 0..<64 {
            let candidate = url.appendingPathComponent(".c11", isDirectory: true)
                .appendingPathComponent("agents.json", isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path),
               let data = try? Data(contentsOf: candidate),
               let cfg = try? JSONDecoder().decode(DefaultAgentConfig.self, from: data) {
                return cfg
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }
}
