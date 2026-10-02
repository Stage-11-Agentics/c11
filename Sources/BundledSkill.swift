import Foundation

/// Identity comes only from a built bundle. Never infer it from cwd, git or env.
struct C11BuildIdentity {
    let shortVersion: String?
    let build: String?
    let commit: String?
    let bundleIdentifier: String?

    init(info: [String: Any]) {
        shortVersion = Self.string(info["CFBundleShortVersionString"])
        build = Self.string(info["CFBundleVersion"])
        commit = Self.normalizeCommit(Self.string(info["C11Commit"]))
            ?? Self.normalizeCommit(Self.string(info["CMUXCommit"]))
        bundleIdentifier = Self.string(info["CFBundleIdentifier"])
    }

    init(bundleURL: URL?) {
        let info: [String: Any]
        if let bundleURL,
           let data = try? Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")),
           let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dictionary = raw as? [String: Any] {
            info = dictionary
        } else {
            info = [:]
        }
        self.init(info: info)
    }

    var payload: [String: Any] {
        ["short_version": shortVersion as Any? ?? NSNull(),
         "build": build as Any? ?? NSNull(),
         "commit": commit as Any? ?? NSNull(),
         "bundle_identifier": bundleIdentifier as Any? ?? NSNull()]
    }

    var summary: String {
        var text = "c11 " + (shortVersion ?? "version unknown")
        if let build { text += " (\(build))" }
        if let commit { text += " [\(commit)]" }
        return text
    }

    static func commitsMatch(_ cli: String?, _ server: String?) -> Bool? {
        guard let cli = normalizeCommit(cli), let server = normalizeCommit(server) else { return nil }
        return cli.hasPrefix(server) || server.hasPrefix(cli)
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeCommit(_ value: String?) -> String? {
        guard let value = string(value)?.lowercased(), value.count >= 7,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) })
        else { return nil }
        return value
    }
}

struct BundledSkill {
    enum LoadError: Error {
        case missing
        case unknownPage(String)
    }

    struct Page {
        let body: String
        let version: String?
        let name: String
    }

    let root: URL

    /// Resolve symlinks before ancestry traversal so a PATH symlink identifies
    /// its own app, never a nearby checkout or another installed app.
    static func containingBundle(executableURL: URL) -> URL? {
        var current = executableURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
        while current.path != "/" {
            if current.pathExtension == "app" { return current }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent != current else { break }
            current = parent
        }
        return nil
    }

    func load(page: String? = nil) throws -> Page {
        let mainURL = root.appendingPathComponent("SKILL.md")
        guard let main = try? String(contentsOf: mainURL, encoding: .utf8) else { throw LoadError.missing }
        let version = Self.frontmatterVersion(main)
        guard let page else { return Page(body: main, version: version, name: "SKILL") }
        guard !page.isEmpty, page != ".", !page.contains(".."),
              !page.contains("/"), !page.contains("\\"), !page.contains("\0") else {
            throw LoadError.unknownPage(page)
        }
        for directory in [root, root.appendingPathComponent("references")] {
            let url = directory.appendingPathComponent(page + ".md").resolvingSymlinksInPath()
            let resolvedRoot = root.resolvingSymlinksInPath().path + "/"
            guard url.path.hasPrefix(resolvedRoot) else { continue }
            if let body = try? String(contentsOf: url, encoding: .utf8) {
                return Page(body: body, version: version, name: page)
            }
        }
        throw LoadError.unknownPage(page)
    }

    private static func frontmatterVersion(_ body: String) -> String? {
        let lines = body.components(separatedBy: .newlines)
        guard lines.first == "---" else { return nil }
        for line in lines.dropFirst() {
            if line == "---" { break }
            if line.hasPrefix("version:") {
                let value = line.dropFirst("version:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
