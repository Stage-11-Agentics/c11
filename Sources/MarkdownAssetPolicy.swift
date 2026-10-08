import Foundation
import Darwin
import ImageIO

/// A pinned directory capability. Document content cannot widen it to another
/// file, execute a sibling script, or follow a symlink outside the directory.
final class MarkdownAssetRoot: @unchecked Sendable {
    let directory: URL
    private let descriptor: Int32

    init?(directory: URL) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        descriptor = open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
    }

    deinit { Darwin.close(descriptor) }

    func read(path: String, maximumBytes: Int) throws -> Data {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { throw CocoaError(.fileReadNoPermission) }
        let target = directory.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard target.path.hasPrefix(prefix) else { throw CocoaError(.fileReadNoPermission) }
        let parts = target.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard !parts.isEmpty else { throw CocoaError(.fileReadNoPermission) }
        var current = dup(descriptor)
        guard current >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(current) }
        for (index, part) in parts.enumerated() {
            // Re-open relative to the pinned root without following symlinks.
            // A replacement between realpath and openat cannot escape scope.
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | (index == parts.count - 1 ? 0 : O_DIRECTORY)
            let next = openat(current, part, flags)
            guard next >= 0 else { throw CocoaError(.fileReadNoPermission) }
            Darwin.close(current)
            current = next
        }
        var info = stat()
        guard fstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(current, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            guard result.count + count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

enum MarkdownDocumentRoot {
    static func corpusRoot(for fileURL: URL) -> URL {
        let source = fileURL.resolvingSymlinksInPath().standardizedFileURL
        var directory = source.deletingLastPathComponent()
        let fallback = directory
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git", isDirectory: true).path) {
                return directory.resolvingSymlinksInPath().standardizedFileURL
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return fallback.resolvingSymlinksInPath().standardizedFileURL
    }
}

struct MarkdownAssetPolicy: Sendable {
    static let viewerScheme = "c11md"
    static let imageScheme = "c11md-asset"
    static let entryURL = URL(string: "c11md://bundle/index.html")!
    static let csp = "default-src 'none'; script-src c11md:; style-src c11md: 'unsafe-inline'; font-src c11md:; img-src c11md-asset:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    let bundle: MarkdownAssetRoot?
    let document: MarkdownAssetRoot?

    static func imageMIME(for path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "bmp": return "image/bmp"
        case "ico": return "image/x-icon"
        default: return nil // SVG/HTML can contain active content; never serve it.
        }
    }

    func resource(for url: URL) throws -> (data: Data, mime: String) {
        // The bridge encodes each path component once. Decode once here;
        // remaining percent sequences name literal files, never traversal.
        guard url.user == nil, url.password == nil, url.port == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let decoded = components.percentEncodedPath.removingPercentEncoding,
              decoded.hasPrefix("/"), !decoded.hasPrefix("//") else { throw CocoaError(.fileReadNoPermission) }
        let path = String(decoded.dropFirst())
        guard !path.contains("\\"), !path.split(separator: "/").contains("..") else { throw CocoaError(.fileReadNoPermission) }
        if url.scheme == Self.imageScheme, url.host == "doc", let document,
           let mime = Self.imageMIME(for: path) {
            let data = try document.read(path: path, maximumBytes: 20 * 1024 * 1024)
            guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(image) > 0, let type = CGImageSourceGetType(image),
                  ["public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp",
                   "public.avif", "com.microsoft.bmp", "com.microsoft.ico"].contains(type as String) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (data, mime)
        }
        guard url.scheme == Self.viewerScheme, url.host == "bundle", let bundle else { throw CocoaError(.fileReadNoPermission) }
        let mime: String
        switch (path as NSString).pathExtension.lowercased() {
        case "html":
            guard path == "index.html" else { throw CocoaError(.fileReadNoPermission) }
            mime = "text/html"
        case "js", "mjs": mime = "text/javascript"
        case "css": mime = "text/css"
        case "woff2": mime = "font/woff2"
        case "woff": mime = "font/woff"
        case "ttf": mime = "font/ttf"
        default: throw CocoaError(.fileReadNoPermission)
        }
        var data = try bundle.read(path: path, maximumBytes: 32 * 1024 * 1024)
        if path == "index.html" {
            guard let html = String(data: data, encoding: .utf8), let head = html.range(of: "<head>", options: .caseInsensitive) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var secured = html
            secured.insert(contentsOf: "<meta http-equiv=\"Content-Security-Policy\" content=\"\(Self.csp)\">", at: head.upperBound)
            data = Data(secured.utf8)
        }
        return (data, mime)
    }
}

/// Native validation never trusts a renderer-provided resolved URL or kind.
enum MarkdownLinkTarget: Equatable {
    case anchor
    case markdown(URL)
    case web(URL)
    case mailto(URL)
    case blocked

    static func resolve(_ href: String, documentPath: String) -> Self {
        guard !href.isEmpty, !href.contains("\0"),
              href.rangeOfCharacter(from: .controlCharacters) == nil else { return .blocked }
        if href.hasPrefix("#") { return .anchor }
        if let components = URLComponents(string: href), components.scheme?.lowercased() == "mailto" {
            return validatedMailto(components)
        }
        guard let url = URL(string: href, relativeTo: URL(fileURLWithPath: documentPath))?.absoluteURL else { return .blocked }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host, !host.isEmpty, url.user == nil, url.password == nil { return .web(url) }
        // Only relative markdown links. Never delegate arbitrary files to Launch Services.
        guard URLComponents(string: href)?.scheme == nil, !href.hasPrefix("/"),
              URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath.removingPercentEncoding?.rangeOfCharacter(from: .controlCharacters) == nil,
              url.isFileURL, ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) else { return .blocked }
        return .markdown(url)
    }

    private static func validatedMailto(_ source: URLComponents) -> Self {
        guard source.host == nil, source.user == nil, source.password == nil, source.port == nil,
              source.fragment == nil,
              let encodedRecipients = source.percentEncodedPath.removingPercentEncoding,
              !encodedRecipients.isEmpty, encodedRecipients.rangeOfCharacter(from: .controlCharacters) == nil,
              validMailboxes(encodedRecipients) else { return .blocked }

        for item in source.queryItems ?? [] {
            guard let value = item.value, value.rangeOfCharacter(from: .controlCharacters) == nil else { return .blocked }
            switch item.name.lowercased() {
            case "subject", "body": break
            case "cc", "bcc":
                guard validMailboxes(value) else { return .blocked }
            default: return .blocked
            }
        }
        guard let sourceURL = source.url,
              var normalized = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else { return .blocked }
        normalized.scheme = "mailto"
        guard let url = normalized.url else { return .blocked }
        return .mailto(url)
    }

    private static func validMailboxes(_ value: String) -> Bool {
        let mailboxes = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !mailboxes.isEmpty else { return false }
        return mailboxes.allSatisfy { mailbox in
            let parts = mailbox.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            let local = String(parts[0]), domain = String(parts[1])
            let localCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-")
            guard !local.isEmpty, local.utf8.count <= 64, local.unicodeScalars.allSatisfy(localCharacters.contains),
                  local.first != ".", local.last != ".", !local.contains(".."),
                  !domain.isEmpty, domain.utf8.count <= 253 else { return false }
            let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
            let labelCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
            let alphanumeric = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            return labels.allSatisfy { label in
                let scalars = Array(label.unicodeScalars)
                return !label.isEmpty && label.utf8.count <= 63 &&
                    scalars.first.map(alphanumeric.contains) == true && scalars.last.map(alphanumeric.contains) == true &&
                    label.unicodeScalars.allSatisfy(labelCharacters.contains)
            }
        }
    }
}

enum MarkdownNavigationPreparation: Sendable {
    case ready(filePath: String, content: String?, modificationDate: Date?, scopeRootPath: String?)
    case rejected(MarkdownNavigationOutcome)
}

/// Resolves and reads navigation targets away from the UI thread. Relative
/// document links and corpus selections remain inside the source document's
/// repository (or its containing directory when there is no repository).
enum MarkdownNavigationPolicy {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]
    static let maximumNavigationContentBytes = 20 * 1024 * 1024
    static let maximumPeekContentBytes = 256 * 1024
    static let maximumLinkTargetBytes = 256 * 1024
    static let maximumLinkInspectionDocuments = 16
    static let maximumLinkInspectionBytes = maximumLinkInspectionDocuments * maximumLinkTargetBytes
    static let maximumIndexedLinks = 128
    static let maximumIndexedHrefBytes = 4 * 1024
    static let maximumLinksResponseBytes = 512 * 1024

    static func prepare(
        _ target: MarkdownNavigationTarget,
        currentFilePath: String?,
        origin: MarkdownNavigationOrigin,
        scopeRootPath: String? = nil,
        allowOutsideScope: Bool = false,
        readContent: Bool = true,
        maximumContentBytes: Int = maximumNavigationContentBytes
    ) -> MarkdownNavigationPreparation {
        let fileURL = target.fileURL.standardizedFileURL
        let filePath = fileURL.path
        guard fileURL.isFileURL, filePath.hasPrefix("/"),
              filePath.rangeOfCharacter(from: .controlCharacters) == nil,
              (target.fragment?.utf8.count ?? 0) <= 4096,
              target.fragment?.rangeOfCharacter(from: .controlCharacters) == nil else {
            return .rejected(.invalidTarget)
        }

        let requiresMarkdown = origin != .agentCLI && !allowOutsideScope
        if requiresMarkdown, !markdownExtensions.contains(fileURL.pathExtension.lowercased()) {
            return .rejected(.invalidTarget)
        }

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: filePath, isDirectory: &isDirectory) else {
            return .rejected(.notFound)
        }
        guard !isDirectory.boolValue, manager.isReadableFile(atPath: filePath) else {
            return .rejected(.notReadable)
        }

        let resolvedTargetURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isRegularFile(at: resolvedTargetURL) else {
            return .rejected(.notReadable)
        }
        if requiresMarkdown, !markdownExtensions.contains(resolvedTargetURL.pathExtension.lowercased()) {
            return .rejected(.invalidTarget)
        }

        let scoped = origin != .agentCLI && !allowOutsideScope
        var rootURL: URL?
        if scoped {
            let root: URL
            if let scopeRootPath {
                root = URL(fileURLWithPath: scopeRootPath, isDirectory: true).standardizedFileURL
            } else if let currentFilePath, let discovered = documentRoot(for: currentFilePath) {
                root = discovered
            } else { return .rejected(.outsideScope) }
            rootURL = root
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
            guard resolvedTargetURL.path.hasPrefix(prefix) else {
                return .rejected(.outsideScope)
            }
        }

        let isSameDocument = currentFilePath.map { current in
            URL(fileURLWithPath: current).resolvingSymlinksInPath().standardizedFileURL == resolvedTargetURL
        } ?? false
        let attributes = try? manager.attributesOfItem(atPath: filePath)
        let modificationDate = attributes?[.modificationDate] as? Date
        let scopeRootPath = rootURL?.resolvingSymlinksInPath().standardizedFileURL.path
        if isSameDocument {
            return .ready(
                filePath: resolvedTargetURL.path,
                content: nil,
                modificationDate: modificationDate,
                scopeRootPath: scopeRootPath
            )
        }
        guard readContent else {
            return .ready(
                filePath: resolvedTargetURL.path,
                content: nil,
                modificationDate: modificationDate,
                scopeRootPath: scopeRootPath
            )
        }

        let data: Data
        if let rootURL {
            let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
            let prefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
            let relativePath = String(resolvedTargetURL.path.dropFirst(prefix.count))
            guard let root = MarkdownAssetRoot(directory: resolvedRoot) else {
                return .rejected(.notReadable)
            }
            do {
                data = try root.read(path: relativePath, maximumBytes: max(0, maximumContentBytes))
            } catch {
                return .rejected(.notReadable)
            }
        } else {
            do {
                data = try Self.readRegularFile(at: resolvedTargetURL, maximumBytes: max(0, maximumContentBytes))
            } catch {
                return .rejected(.notReadable)
            }
        }
        guard let content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            return .rejected(.notReadable)
        }
        return .ready(
            filePath: resolvedTargetURL.path,
            content: content,
            modificationDate: modificationDate,
            scopeRootPath: scopeRootPath
        )
    }

    private static func isRegularFile(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func readRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw CocoaError(.fileReadTooLarge)
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            guard result.count + count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func documentRoot(for filePath: String) -> URL? {
        let manager = FileManager.default
        let source = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().standardizedFileURL
        var directory = source.deletingLastPathComponent()
        let documentDirectory = directory
        while true {
            if manager.fileExists(atPath: directory.appendingPathComponent(".git", isDirectory: true).path) {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { break }
            directory = parent
        }
        return documentDirectory
    }
}
