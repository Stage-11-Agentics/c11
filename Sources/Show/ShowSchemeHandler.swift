import Foundation
import UniformTypeIdentifiers
import WebKit

/// What one viewer may serve under `c11-show://`: its entry file, and, with
/// `--dir`, files strictly inside that folder. Nothing else, whatever the URL
/// says: the address is mapped back only through this scope.
struct ShowServeScope: Equatable, Sendable {
    /// Absolute path of the shown file on its machine, and its URL path.
    var entryPath: String
    var entryURLPath: String
    /// The `--dir` folder (absolute) and its URL path with a trailing slash.
    var root: String?
    var rootURLBase: String?

    init(source: ShowSourceSpec) {
        entryPath = source.target
        entryURLPath = ShowAddress.urlPath(forAbsolute: source.target, home: source.home)
        if let dir = source.dir {
            let trimmed = dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
            root = trimmed
            let base = ShowAddress.urlPath(forAbsolute: trimmed, home: source.home)
            rootURLBase = base.hasSuffix("/") ? base : base + "/"
        }
    }

    enum Target: Equatable {
        case entry
        case asset(path: String)
        case refused(ShowAssetPath.Refusal)
    }

    /// `percentEncodedPath` is the request URL's path exactly as WebKit sent it.
    func target(percentEncodedPath: String) -> Target {
        let decodedEntry = entryURLPath
        if percentEncodedPath.removingPercentEncoding == decodedEntry { return .entry }
        guard let root, let base = rootURLBase else { return .refused(.outsideRoot) }
        let encodedBase = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? base
        let raw = percentEncodedPath.hasPrefix(encodedBase) ? String(percentEncodedPath.dropFirst(encodedBase.count))
            : percentEncodedPath.hasPrefix(base) ? String(percentEncodedPath.dropFirst(base.count)) : nil
        guard let raw else { return .refused(.outsideRoot) }
        switch ShowAssetPath.resolve(rawPath: "/" + raw, urlBase: "/", root: root) {
        case .success(let path): return .asset(path: path)
        case .failure(let refusal): return .refused(refusal)
        }
    }

    /// C11H-395: the path this scope serves at a page address, and the root it
    /// must stay inside, exactly as `target(percentEncodedPath:)` maps it; nil
    /// when the handler refuses that address. No disk access: `localFile`
    /// checks the file before anything hands it out.
    func servedPath(percentEncodedPath: String) -> (path: String, root: String?)? {
        switch target(percentEncodedPath: percentEncodedPath) {
        case .entry: return (entryPath, nil)
        case .asset(let path): return (path, root)
        case .refused: return nil
        }
    }

    /// Document types a shown file may be handed to macOS as (C11H-395):
    /// macOS opens a file with its type's app, so only types it shows in a
    /// viewer. Markdown, CSV and logs conform to plain text. The type is what
    /// macOS treats the file as, not what its bytes are: a regular file's
    /// comes from its extension (with none, from its execute bit), a Finder
    /// alias is `com.apple.alias-file` whatever its name, and a folder, FIFO
    /// or app bundle has its kind's. So
    /// a location file (`.webloc`), an app or an executable with no extension
    /// conforms to none of these. A location file or an executable renamed
    /// `.html` is HTML, and macOS opens it in the browser as a document; a
    /// folder renamed `.html` is still a folder. Scripts (shell, Python,
    /// JavaScript) conform to plain text, so `public.script` is refused on
    /// its own: their default app may run them.
    static let handOffTypes: [UTType] = [.html, .plainText, .image, .pdf]

    static func handsOff(_ type: UTType) -> Bool {
        guard handOffTypes.contains(where: { type.conforms(to: $0) }) else { return false }
        return !type.conforms(to: .script)
    }

    /// The hand-off rule by name alone, with no disk access: what the
    /// toolbar's enabled state can know while drawing.
    static func handsOff(name path: String) -> Bool {
        UTType(filenameExtension: (path as NSString).pathExtension).map(handsOff) ?? false
    }

    /// C11H-395: the file on this Mac that `ShowLocalFetcher` would read for
    /// `path`, symlinks resolved, and that is safe to hand to macOS; nil where
    /// the handler would refuse it (missing, or under `root` resolving outside
    /// `--dir`) or where macOS would run or follow it: its content type, read
    /// from the file's metadata, must pass `handsOff`. A missing file has no
    /// type, and a folder, FIFO or device has one no hand-off type includes,
    /// so this is also the regular-file check. The size cap does not apply:
    /// it guards the viewer's memory. The file is checked, then opened by
    /// path; the two steps are not atomic.
    static func localFile(_ path: String, root: String?) -> URL? {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        if let root {
            guard let pinned = MarkdownAssetRoot(directory: URL(fileURLWithPath: root)),
                  ShowAssetPath.isInside(real.path, root: pinned.directory.path) else { return nil }
        }
        guard let type = (try? URL(fileURLWithPath: real.path).resourceValues(forKeys: [.contentTypeKey]))?.contentType,
              handsOff(type) else { return nil }
        return real
    }
}

/// Serves one viewer's `c11-show://` requests from its fetcher, off main.
/// WebKit's task callbacks run on main; every read runs in a detached task.
@MainActor
final class ShowSchemeHandler: NSObject, WKURLSchemeHandler {
    let scope: ShowServeScope
    private let fetcher: any ShowFetcher
    /// C11H-353: sent with every response when the viewer shows a linked
    /// machine's page (`ShowPageGuard`); nil for a show from this Mac.
    let contentSecurityPolicy: String?
    /// Called on main for each request: (served, status).
    var onRequest: ((_ isEntry: Bool, _ status: Int) -> Void)?
    private var active: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(scope: ShowServeScope, fetcher: any ShowFetcher, contentSecurityPolicy: String? = nil) {
        self.scope = scope
        self.fetcher = fetcher
        self.contentSecurityPolicy = contentSecurityPolicy
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) { start(task) }

    /// Serves one request; the WebKit callback's body, reachable without a web view.
    func start(_ task: WKURLSchemeTask) {
        let policy = contentSecurityPolicy
        guard let url = task.request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            Self.respond(task, url: task.request.url, status: 400, mime: "text/plain", body: Data(), policy: policy)
            return
        }
        let target = scope.target(percentEncodedPath: components.percentEncodedPath)
        let key = ObjectIdentifier(task)
        let fetcher = self.fetcher
        let scope = self.scope
        let job = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: (status: Int, mime: String, body: Data)
            switch target {
            case .refused(let refusal):
                outcome = (refusal == .notAllowedType ? 415 : 404, "text/plain; charset=utf-8", Data())
            case .entry:
                outcome = await Self.fetch(fetcher, path: scope.entryPath, root: nil,
                                           mime: ShowAssetPath.mimeType(forPath: scope.entryPath) ?? "text/plain; charset=utf-8")
            case .asset(let path):
                outcome = await Self.fetch(fetcher, path: path, root: scope.root,
                                           mime: ShowAssetPath.mimeType(forPath: path) ?? "application/octet-stream")
            }
            await MainActor.run {
                guard let self, self.active.removeValue(forKey: key) != nil else { return }
                Self.respond(task, url: url, status: outcome.status, mime: outcome.mime, body: outcome.body, policy: policy)
                if case .entry = target { self.onRequest?(true, outcome.status) } else { self.onRequest?(false, outcome.status) }
            }
        }
        active[key] = job
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    nonisolated private static func fetch(_ fetcher: any ShowFetcher, path: String, root: String?, mime: String) async
        -> (status: Int, mime: String, body: Data) {
        do {
            let data = try await fetcher.read(path, root: root, maxBytes: ShowSpec.maxBytes)
            return (200, mime, data)
        } catch let error as ShowFetchError {
            switch error {
            case .notFound: return (404, "text/plain; charset=utf-8", Data())
            case .notFile, .outsideRoot: return (403, "text/plain; charset=utf-8", Data())
            case .tooLarge: return (413, "text/plain; charset=utf-8", Data(ShowSpec.tooLargeMessage().utf8))
            case .unreachable: return (502, "text/plain; charset=utf-8", Data())
            }
        } catch {
            return (502, "text/plain; charset=utf-8", Data())
        }
    }

    private static func respond(_ task: WKURLSchemeTask, url: URL?, status: Int, mime: String, body: Data, policy: String?) {
        var headers = [
            "Content-Type": mime,
            "Content-Length": "\(body.count)",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
        ]
        if let policy { headers["Content-Security-Policy"] = policy }
        let response = HTTPURLResponse(url: url ?? URL(string: "\(ShowSpec.scheme)://invalid/")!,
                                       statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        if !body.isEmpty { task.didReceive(body) }
        task.didFinish()
    }
}
