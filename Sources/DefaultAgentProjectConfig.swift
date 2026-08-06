import Foundation

/// Walks up from a starting directory looking for `.c11/agents.json`. The first
/// match wins (deepest directory first). When the file exists and parses, it
/// overrides the user-level `DefaultAgentConfigStore.shared.current` for any
/// terminal surface launched within that directory tree.
///
/// Matches the precedence/walk pattern used by `WorkspaceBlueprintStore`.
enum DefaultAgentProjectConfig {

    struct Match {
        let config: DefaultAgentConfig
        let sourcePath: String
    }

    /// Launch-rail entry point. Keeping the C11-194 resolution intact here
    /// makes an arbitrary GUI process cwd unavailable as a config origin.
    /// `processFallback` is an intentionally unevaluated regression seam: the
    /// old behavior used that value when resolution was empty, and tests inject
    /// a valid decoy there to prove it can no longer win.
    static func find(
        for resolution: AgentLaunchWorkingDirectoryResolution,
        processFallback: @autoclosure () -> String = FileManager.default.currentDirectoryPath,
        fileManager: FileManager = .default
    ) -> Match? {
        findMatch(from: resolution.path, fileManager: fileManager)
    }

    /// Search from `cwd` upward to the filesystem root for `.c11/agents.json`.
    /// Returns the parsed config, or nil if no file was found / parsing failed.
    /// Parse failures are silently swallowed so a malformed project file cannot
    /// brick the new-terminal flow; the caller falls back to the user default.
    static func find(
        from cwd: String?,
        fileManager: FileManager = .default
    ) -> DefaultAgentConfig? {
        findMatch(from: cwd, fileManager: fileManager)?.config
    }

    /// The observable form used by launch responses and validation. Walk
    /// semantics remain deepest-first toward `/`; malformed files remain a
    /// silent miss so callers fall back to the user default.
    static func findMatch(
        from cwd: String?,
        fileManager: FileManager = .default
    ) -> Match? {
        guard let cwd, !cwd.isEmpty else { return nil }
        var url = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL

        // Bound the walk so a deep-but-bogus cwd can't spin forever.
        for _ in 0..<64 {
            let candidate = url.appendingPathComponent(".c11", isDirectory: true)
                .appendingPathComponent("agents.json", isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path),
               let data = try? Data(contentsOf: candidate),
               let cfg = try? JSONDecoder().decode(DefaultAgentConfig.self, from: data) {
                return Match(config: cfg, sourcePath: candidate.path)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }
}
