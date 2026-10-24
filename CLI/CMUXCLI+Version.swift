// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

extension CMUXCLI {

    func bundledCLIIdentity() -> C11BuildIdentity {
        C11BuildIdentity(bundleURL: resolvedExecutableURL().flatMap { BundledSkill.containingBundle(executableURL: $0) })
    }

    func runGuide(commandArgs: [String], jsonOutput: Bool) throws {
        if commandArgs.contains("--help") || commandArgs.contains("-h") {
            print(subcommandUsage("guide") ?? "Usage: c11 guide [page] [--json]")
            return
        }
        let (asJSON, remaining) = parseBoolFlag(commandArgs, name: "--json")
        guard remaining.count <= 1 else {
            throw CLIError(message: "Usage: c11 guide [page] [--json]")
        }
        guard let executable = resolvedExecutableURL(),
              let bundle = BundledSkill.containingBundle(executableURL: executable) else {
            throw CLIError(message: String(localized: "cli.guide.missing", defaultValue: "This build has no bundled c11 skill."))
        }
        let page: BundledSkill.Page
        do {
            page = try BundledSkill(root: bundle.appendingPathComponent("Contents/Resources/skills/c11")).load(page: remaining.first)
        } catch BundledSkill.LoadError.unknownPage(let name) {
            throw CLIError(message: String(localized: "cli.guide.unknown_page", defaultValue: "No bundled skill page '\(name)'."))
        } catch {
            throw CLIError(message: String(localized: "cli.guide.missing", defaultValue: "This build has no bundled c11 skill."))
        }
        let identity = C11BuildIdentity(bundleURL: bundle)
        if jsonOutput || asJSON {
            print(jsonString([
                "cli": identity.payload, "skill": "c11", "skill_version": page.version as Any? ?? NSNull(),
                "source": "bundle", "page": page.name, "body": page.body
            ]))
        } else {
            print(identity.summary + "\nskill: c11\nskill_version: \(page.version ?? "unknown")\nsource: bundle\n\n" + page.body, terminator: "")
        }
    }

    func versionSummary() -> String {
        let info = resolvedVersionInfo()
        let commit = info["CMUXCommit"].flatMap { normalizedCommitHash($0) }
        let baseSummary: String
        if let version = info["CFBundleShortVersionString"], let build = info["CFBundleVersion"] {
            baseSummary = "c11 \(version) (\(build))"
        } else if let version = info["CFBundleShortVersionString"] {
            baseSummary = "c11 \(version)"
        } else if let build = info["CFBundleVersion"] {
            baseSummary = "c11 build \(build)"
        } else {
            baseSummary = "c11 version unknown"
        }
        guard let commit else { return baseSummary }
        return "\(baseSummary) [\(commit)]"
    }

    func printWelcome() {
        let reset = "\u{001B}[0m"
        let bold = "\u{001B}[1m"
        func trueColor(_ red: Int, _ green: Int, _ blue: Int) -> String {
            "\u{001B}[38;2;\(red);\(green);\(blue)m"
        }

        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        // Stage 11 gold ramp: single accent color, faded at the tips. Brand rule is
        // "gold is the only color" — the diamond glows gold, everything else stays
        // quiet. Values centered on --gold (#c9a84c = 201,168,76).
        let g1 = trueColor(104, 87, 39)
        let g2 = trueColor(149, 124, 56)
        let g3 = trueColor(183, 153, 69)
        let g4 = trueColor(201, 168, 76)
        let g5 = trueColor(183, 153, 69)
        let g6 = trueColor(149, 124, 56)
        let g7 = trueColor(104, 87, 39)
        let goldBold = bold + trueColor(201, 168, 76)

        let tagline: String
        let subdued: String

        if isDark {
            tagline = trueColor(130, 130, 140)
            subdued = "\u{001B}[2m"
        } else {
            tagline = trueColor(90, 90, 98)
            subdued = trueColor(100, 100, 108)
        }

        let logo = """
        \(g1)  ::\(reset)
        \(g2)    ::::\(reset)              \(goldBold)c11\(reset)
        \(g3)      ::::::\(reset)
        \(g4)        ::::::\(reset)        \(tagline)terminal multiplexing for the 10,000x hyperengineer\(reset)
        \(g5)      ::::::\(reset)
        \(g6)    ::::\(reset)
        \(g7)  ::\(reset)
        """

        let shortcuts = """
          \(bold)Shortcuts\(reset)

          \(bold)\u{2318}N\(reset)\(subdued)                  New workspace\(reset)
          \(bold)\u{2318}T\(reset)\(subdued)                  New panel\(reset)
          \(bold)\u{2318}P\(reset)\(subdued)                  Go to workspace\(reset)
          \(bold)\u{2318}D\(reset)\(subdued)                  Split right\(reset)
          \(bold)\u{2318}\u{21E7}D\(reset)\(subdued)                 Split down\(reset)
          \(bold)\u{2318}\u{21E7}P\(reset)\(subdued)                 Command palette\(reset)
          \(bold)\u{2318}\u{21E7}R\(reset)\(subdued)                 Rename workspace\(reset)
          \(bold)\u{2318}\u{21E7}L\(reset)\(subdued)                 New browser\(reset)
          \(bold)\u{2318}\u{21E7}U\(reset)\(subdued)                 Jump to latest unread\(reset)
        """

        print()
        print(logo)
        print()
        print(shortcuts)
        print()
        print("  \(bold)Stage 11\(reset)\(subdued)            https://stage11.ai\(reset)")
        print("  \(bold)The Spike\(reset)\(subdued)           https://stage11.ai/spike\(reset)")
        print("  \(bold)Repo\(reset)\(subdued)                https://github.com/Stage-11-Agentics/c11\(reset)")
        print()
        print("  \(subdued)Run \(reset)\(bold)c11 --help\(reset)\(subdued) for all commands.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)c11 shortcuts\(reset)\(subdued) to edit shortcuts.\(reset)")
        print("  \(subdued)Run \(reset)\(bold)c11 feedback\(reset)\(subdued) to report a bug.\(reset)")
        print()
    }

    func resolvedVersionInfo() -> [String: String] {
        var info: [String: String] = [:]
        if let main = versionInfo(from: Bundle.main.infoDictionary) {
            info.merge(main, uniquingKeysWith: { current, _ in current })
        }

        let needsPlistFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["CMUXCommit"] == nil
        if needsPlistFallback {
            for plistURL in candidateInfoPlistURLs() {
                guard let data = try? Data(contentsOf: plistURL),
                      let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                      let dictionary = raw as? [String: Any],
                      let parsed = versionInfo(from: dictionary)
                else {
                    continue
                }
                info.merge(parsed, uniquingKeysWith: { current, _ in current })
                if info["CFBundleShortVersionString"] != nil,
                   info["CFBundleVersion"] != nil,
                   info["CMUXCommit"] != nil {
                    break
                }
            }
        }

        let needsProjectFallback =
            info["CFBundleShortVersionString"] == nil ||
            info["CFBundleVersion"] == nil ||
            info["CMUXCommit"] == nil
        if needsProjectFallback, let fromProject = versionInfoFromProjectFile() {
            info.merge(fromProject, uniquingKeysWith: { current, _ in current })
        }

        if info["CMUXCommit"] == nil,
           let commit = normalizedCommitHash(ProcessInfo.processInfo.environment["CMUX_COMMIT"]) {
            info["CMUXCommit"] = commit
        }

        return info
    }

    func versionInfo(from dictionary: [String: Any]?) -> [String: String]? {
        guard let dictionary else { return nil }

        var info: [String: String] = [:]
        if let version = dictionary["CFBundleShortVersionString"] as? String {
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleShortVersionString"] = trimmed
            }
        }
        if let build = dictionary["CFBundleVersion"] as? String {
            let trimmed = build.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains("$(") {
                info["CFBundleVersion"] = trimmed
            }
        }
        if let commit = dictionary["CMUXCommit"] as? String,
           let normalizedCommit = normalizedCommitHash(commit) {
            info["CMUXCommit"] = normalizedCommit
        }
        return info.isEmpty ? nil : info
    }

    func versionInfoFromProjectFile() -> [String: String]? {
        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        let fileManager = FileManager.default
        var current = executableURL.deletingLastPathComponent().standardizedFileURL

        while true {
            let projectFile = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            if fileManager.fileExists(atPath: projectFile.path),
               let contents = try? String(contentsOf: projectFile, encoding: .utf8) {
                var info: [String: String] = [:]
                if let version = firstProjectSetting("MARKETING_VERSION", in: contents) {
                    info["CFBundleShortVersionString"] = version
                }
                if let build = firstProjectSetting("CURRENT_PROJECT_VERSION", in: contents) {
                    info["CFBundleVersion"] = build
                }
                if let commit = gitCommitHash(at: current) {
                    info["CMUXCommit"] = commit
                }
                if !info.isEmpty {
                    return info
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
    }

    func firstProjectSetting(_ key: String, in source: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: key) + "\\s*=\\s*([^;]+);"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let searchRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: searchRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: source)
        else {
            return nil
        }
        let value = source[valueRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }

    func gitCommitHash(at directory: URL) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", directory.path, "rev-parse", "--short=9", "HEAD"]
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        return normalizedCommitHash(output)
    }

    func normalizedCommitHash(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else {
            return nil
        }
        let normalized = trimmed.lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return String(normalized.prefix(12))
    }

    // Foundation can walk past "/" into "/.." when repeatedly deleting path
    // components, so stop once the canonical root is reached.
    func parentSearchURL(for url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        guard !path.isEmpty, path != "/" else {
            return nil
        }

        let parent = standardized.deletingLastPathComponent().standardizedFileURL
        guard parent.path != path else {
            return nil
        }
        return parent
    }

    func candidateInfoPlistURLs() -> [URL] {
        guard let executableURL = resolvedExecutableURL() else {
            return []
        }

        let fileManager = FileManager.default

        var candidates: [URL] = []
        var seen: Set<String> = []
        func appendIfExisting(_ url: URL) {
            let path = url.path
            guard !path.isEmpty else { return }
            guard seen.insert(path).inserted else { return }
            guard fileManager.fileExists(atPath: path) else { return }
            candidates.append(url)
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app" {
                appendIfExisting(current.appendingPathComponent("Contents/Info.plist"))
            }
            if current.lastPathComponent == "Contents" {
                appendIfExisting(current.appendingPathComponent("Info.plist"))
            }

            let projectMarker = current.appendingPathComponent("GhosttyTabs.xcodeproj/project.pbxproj")
            let repoInfo = current.appendingPathComponent("Resources/Info.plist")
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoInfo.path) {
                appendIfExisting(repoInfo)
                break
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        // If we already found an ancestor bundle or repo Info.plist, avoid scanning
        // sibling app bundles. Large Resources directories can otherwise balloon RSS.
        guard candidates.isEmpty else {
            return candidates
        }

        let searchRoots = [
            executableURL.deletingLastPathComponent().standardizedFileURL,
            executableURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        ]
        for root in searchRoots {
            guard let entries = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }
            for case let entry as URL in entries where entry.pathExtension == "app" {
                appendIfExisting(entry.appendingPathComponent("Contents/Info.plist"))
            }
        }

        return candidates
    }

    func currentExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        if size > 0 {
            var buffer = Array<CChar>(repeating: 0, count: Int(size))
            if _NSGetExecutablePath(&buffer, &size) == 0 {
                let path = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    return path
                }
            }
        }
        return Bundle.main.executableURL?.path ?? args.first
    }

    func resolvedExecutableURL() -> URL? {
        guard let executable = currentExecutablePath(), !executable.isEmpty else {
            return nil
        }

        let expanded = (executable as NSString).expandingTildeInPath
        if let resolvedPath = realpath(expanded, nil) {
            defer { free(resolvedPath) }
            return URL(fileURLWithPath: String(cString: resolvedPath)).standardizedFileURL
        }

        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}
