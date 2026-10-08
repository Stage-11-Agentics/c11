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
    case blocked

    static func resolve(_ href: String, documentPath: String) -> Self {
        guard !href.isEmpty, !href.contains("\0"),
              href.rangeOfCharacter(from: .controlCharacters) == nil else { return .blocked }
        if href.hasPrefix("#") { return .anchor }
        guard let url = URL(string: href, relativeTo: URL(fileURLWithPath: documentPath))?.absoluteURL else { return .blocked }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host, !host.isEmpty, url.user == nil, url.password == nil { return .web(url) }
        // Only relative markdown links. Never delegate arbitrary files to Launch Services.
        guard URLComponents(string: href)?.scheme == nil, !href.hasPrefix("/"),
              url.isFileURL, ["md", "markdown", "mdown"].contains(url.pathExtension.lowercased()) else { return .blocked }
        return .markdown(url)
    }
}
