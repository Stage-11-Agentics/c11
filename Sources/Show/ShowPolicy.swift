import Foundation
import Darwin

/// What a remote caller's URL may name (C11H-228, design "Safety"). A URL an
/// agent on another machine shows must name something reachable from the
/// operator's Mac that is not the Mac itself: never `file:`, never a loopback
/// address in any spelling, never the Mac's own names or addresses.
enum ShowURLPolicy {
    struct Refusal: Error, Equatable {
        let reason: String
    }

    /// The operator-facing reasons, localized; the wire code stays `show_url_refused`.
    enum Reason {
        static var notURL: String { String(localized: "show.url.notURL", defaultValue: "not a URL") }
        static var fileURL: String {
            String(localized: "show.url.file", defaultValue: "file: names a file on the operator's Mac; show the path instead")
        }
        static var scheme: String { String(localized: "show.url.scheme", defaultValue: "only http and https URLs can be shown") }
        static var localScheme: String {
            String(localized: "show.url.localScheme", defaultValue: "only http, https and file URLs can be shown")
        }
        static var credentials: String {
            String(localized: "show.url.credentials", defaultValue: "a URL with credentials cannot be shown")
        }
        static var noHost: String { String(localized: "show.url.noHost", defaultValue: "the URL has no host") }
        static func ownMac(_ host: String) -> String {
            String(format: String(localized: "show.url.ownMac", defaultValue: "%@ is the operator's own Mac"), host)
        }
        static func resolvesToOwnMac(_ host: String) -> String {
            String(format: String(localized: "show.url.resolvesToOwnMac", defaultValue: "%@ resolves to the operator's own Mac"), host)
        }
        static func unresolved(_ host: String) -> String {
            String(format: String(localized: "show.url.unresolved", defaultValue: "%@ could not be resolved"), host)
        }
    }

    /// The operator's Mac's own names and addresses, lowercased.
    struct OwnAddresses: Equatable, Sendable {
        var names: Set<String>
        var addresses: Set<String>

        static let empty = OwnAddresses(names: [], addresses: [])

        /// This Mac: its host names (`scutil`-free: `ProcessInfo.hostName`,
        /// `gethostname`, the `.local` form), and every interface address.
        static func current(includeNames: Bool = true) -> OwnAddresses {
            var names: Set<String> = []
            func addName(_ raw: String?) {
                guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return }
                let trimmed = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
                names.insert(trimmed)
                if let short = trimmed.split(separator: ".").first { names.insert(String(short)); names.insert(short + ".local") }
            }
            var buffer = [CChar](repeating: 0, count: 256)
            if gethostname(&buffer, buffer.count) == 0 { addName(String(cString: buffer)) }
            if includeNames { for name in ShowOwnAddresses.resolveNames() { addName(name) } }
            var addresses: Set<String> = []
            var list: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&list) == 0, let first = list {
                var cursor: UnsafeMutablePointer<ifaddrs>? = first
                while let entry = cursor {
                    if let sa = entry.pointee.ifa_addr, let text = numeric(sa) { addresses.insert(text.lowercased()) }
                    cursor = entry.pointee.ifa_next
                }
                freeifaddrs(first)
            }
            return OwnAddresses(names: names, addresses: addresses)
        }

        private static func numeric(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { return nil }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            let text = String(cString: host)
            // Drop a scope id (`fe80::1%en0`).
            return text.split(separator: "%").first.map(String.init)
        }
    }

    /// nil when `raw` may be shown by a caller on another machine.
    static func refusalForRemote(_ raw: String, own: OwnAddresses) -> Refusal? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else {
            return Refusal(reason: Reason.notURL)
        }
        guard scheme == "http" || scheme == "https" else {
            return Refusal(reason: scheme == "file" ? Reason.fileURL : Reason.scheme)
        }
        guard url.user == nil, url.password == nil else { return Refusal(reason: Reason.credentials) }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return Refusal(reason: Reason.noHost) }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host = String(host.dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if isLoopbackName(host) { return Refusal(reason: Reason.ownMac(host)) }
        if let v4 = ipv4(host) {
            return isForbidden(v4: v4, own: own) ? Refusal(reason: Reason.ownMac(host)) : nil
        }
        if let v6 = ipv6(host) {
            return isForbidden(v6: v6, own: own) ? Refusal(reason: Reason.ownMac(host)) : nil
        }
        let short = host.split(separator: ".").first.map(String.init) ?? host
        if own.names.contains(host) || own.names.contains(short) || own.names.contains(short + ".local") {
            return Refusal(reason: Reason.ownMac(host))
        }
        return nil
    }

    static func isLoopbackName(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "localhost.localdomain"
            || host == "ip6-localhost" || host == "ip6-loopback"
    }

    /// 127/8 and all of 0/8 (macOS connects 0.x.x.x to this Mac).
    static func isLoopbackOrUnspecified(_ v4: UInt32) -> Bool {
        (v4 >> 24) == 127 || (v4 >> 24) == 0
    }

    /// 169.254/16: devices on this Mac's own link, never the wider network.
    static func isLinkLocal(_ v4: UInt32) -> Bool { (v4 >> 16) == 0xA9FE }

    /// C11H-377: an address a linked machine's page may not reach, written
    /// any way (a literal in its URL, or what its host name resolved to):
    /// loopback, unspecified, link-local, or one of this Mac's own.
    static func isForbidden(v4: UInt32, own: OwnAddresses) -> Bool {
        isLoopbackOrUnspecified(v4) || isLinkLocal(v4) || own.addresses.contains(dotted(v4))
    }

    static func isForbidden(v6: [UInt8], own: OwnAddresses) -> Bool {
        guard v6.count == 16 else { return true }
        if v6 == [UInt8](repeating: 0, count: 15) + [1] || v6 == [UInt8](repeating: 0, count: 16) { return true }
        // fe80::/10, link-local.
        if v6[0] == 0xfe && (v6[1] & 0xc0) == 0x80 { return true }
        // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d) forms.
        let mapped = Array(v6[0..<10]) == [UInt8](repeating: 0, count: 10) && (v6[10...11] == [0xff, 0xff] || v6[10...11] == [0, 0])
        if mapped {
            let v4 = UInt32(v6[12]) << 24 | UInt32(v6[13]) << 16 | UInt32(v6[14]) << 8 | UInt32(v6[15])
            if isForbidden(v4: v4, own: own) { return true }
        }
        return own.addresses.contains(canonicalIPv6(v6))
    }

    /// Whether a numeric address (as `getaddrinfo` gives it, or a SOCKS
    /// request names it) is forbidden. Text that is no address is.
    static func isForbiddenAddress(_ text: String, own: OwnAddresses) -> Bool {
        var host = text.lowercased()
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        if host.contains(":") { return ipv6(host).map { isForbidden(v6: $0, own: own) } ?? true }
        var parts = [UInt32]()
        for part in host.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = UInt32(part), value <= 255, part.count <= 3 else { return true }
            parts.append(value)
        }
        guard parts.count == 4 else { return true }
        return isForbidden(v4: parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3], own: own)
    }

    /// Whether `host` is written as an address (no lookup needed).
    static func isAddressLiteral(_ host: String) -> Bool {
        var bare = host.lowercased()
        if bare.hasPrefix("[") && bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        if let zone = bare.firstIndex(of: "%") { bare = String(bare[..<zone]) }
        return ipv4(bare) != nil || ipv6(bare) != nil
    }

    /// C11H-377: the rule for a name's answers. `addresses` nil means the
    /// name did not resolve in time, which is refused too.
    static func refusalForResolved(host: String, addresses: [String]?, own: OwnAddresses) -> Refusal? {
        guard let addresses, !addresses.isEmpty else { return Refusal(reason: Reason.unresolved(host)) }
        return addresses.contains { isForbiddenAddress($0, own: own) } ? Refusal(reason: Reason.resolvesToOwnMac(host)) : nil
    }

    /// The host of an http(s) URL a guarded check must resolve, or nil
    /// when it is an address literal or no host at all.
    static func nameToResolve(in url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host = String(host.dropLast()) }
        return isAddressLiteral(host) ? nil : host
    }

    static func dotted(_ v4: UInt32) -> String {
        "\(v4 >> 24).\((v4 >> 16) & 0xff).\((v4 >> 8) & 0xff).\(v4 & 0xff)"
    }

    /// An IPv4 address in any spelling `inet_aton` accepts: dotted with one to
    /// four parts, each decimal, octal (leading 0) or hex (0x), so `127.1`,
    /// `2130706433`, `0x7f000001` and `0177.0.0.1` all read as 127.0.0.1.
    static func ipv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [UInt64] = []
        for part in parts {
            guard !part.isEmpty else { return nil }
            let lower = part.lowercased()
            let value: UInt64?
            if lower.hasPrefix("0x") { value = lower.count == 2 ? 0 : UInt64(lower.dropFirst(2), radix: 16) }
            else if lower.count > 1, lower.hasPrefix("0") { value = UInt64(lower.dropFirst(), radix: 8) }
            else { value = UInt64(lower, radix: 10) }
            guard let value else { return nil }
            values.append(value)
        }
        let last = values.removeLast()
        guard values.allSatisfy({ $0 <= 0xff }) else { return nil }
        let lastBits = 8 * (4 - values.count)
        guard last < (UInt64(1) << UInt64(lastBits)) else { return nil }
        var result: UInt64 = 0
        for (index, value) in values.enumerated() { result |= value << UInt64(24 - 8 * index) }
        result |= last
        return UInt32(result)
    }

    static func ipv6(_ host: String) -> [UInt8]? {
        guard host.contains(":") else { return nil }
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    static func canonicalIPv6(_ bytes: [UInt8]) -> String {
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { raw in for (index, byte) in bytes.enumerated() { raw[index] = byte } }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "" }
        return String(cString: buffer).lowercased()
    }
}

/// The rule for an asset a shown page asks for (`--dir`): the request path is
/// decoded once and must name a file strictly under the folder, with no
/// traversal, backslash, NUL or empty segment, and an allowed type. Symlinks
/// are resolved where the file lives (`ShowFetcher`), never trusted here.
enum ShowAssetPath {
    enum Refusal: Error, Equatable { case traversal, notAllowedType, outsideRoot }

    /// Allowed extensions and their MIME types. `svg` is excluded on purpose
    /// (script in an image); so is everything executable or unknown.
    static let mime: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "json": "application/json", "map": "application/json",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "avif": "image/avif", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "txt": "text/plain; charset=utf-8", "md": "text/plain; charset=utf-8", "csv": "text/csv; charset=utf-8",
        "mp4": "video/mp4", "webm": "video/webm", "mp3": "audio/mpeg", "wav": "audio/wav",
    ]

    static func mimeType(forPath path: String) -> String? {
        mime[(path as NSString).pathExtension.lowercased()]
    }

    /// The absolute path a request names under `root` (already absolute and
    /// resolved), or a refusal. `rawPath` is the URL's percent-encoded path.
    static func resolve(rawPath: String, urlBase: String, root: String) -> Result<String, Refusal> {
        // Decode exactly once; a second layer of encoding stays literal and
        // then fails the segment checks below.
        guard rawPath.hasPrefix(urlBase) else { return .failure(.outsideRoot) }
        let encodedRest = String(rawPath.dropFirst(urlBase.count))
        guard !encodedRest.isEmpty, let rest = encodedRest.removingPercentEncoding else { return .failure(.traversal) }
        guard !rest.contains("\\"), !rest.contains("\0"), !rest.hasPrefix("/"), !rest.contains("//") else {
            return .failure(.traversal)
        }
        let segments = rest.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }) else { return .failure(.traversal) }
        // A literal `%` left after one decode is a double-encoded request.
        guard !rest.contains("%2e"), !rest.contains("%2E"), !rest.contains("%2f"), !rest.contains("%2F"),
              !rest.contains("%5c"), !rest.contains("%5C") else { return .failure(.traversal) }
        guard mimeType(forPath: rest) != nil else { return .failure(.notAllowedType) }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return .success(base + "/" + rest)
    }

    /// Whether a resolved absolute path lies strictly inside `root`.
    static func isInside(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) && path.count > prefix.count
    }
}

/// The one check every way of opening a show passes through (C11H-228):
/// a live `show.open`, a Feed row from a show recorded while c11 was away,
/// and a restored viewer. A URL from a linked machine must not name the
/// operator's Mac; a path must be a regular file within the size cap.
enum ShowPreflight {
    struct Refused: Error, Equatable {
        let code: String
        let message: String
    }

    /// Nil when `raw` may be shown for `origin`. Reads this Mac's addresses
    /// fresh, so a network change takes effect at once.
    /// `resolvingNames: false` never resolves host names (it uses the names
    /// cached by an earlier off-main check, plus `gethostname`), so it is
    /// safe on the main thread; off main, pass true.
    static func urlRefusal(_ raw: String, origin: ShowOrigin, resolvingNames: Bool = true) -> String? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return ShowURLPolicy.Reason.notURL }
        if origin.isRemote {
            let own = resolvingNames ? ShowOwnAddresses.current() : ShowOwnAddresses.currentWithoutResolving()
            if let refusal = ShowURLPolicy.refusalForRemote(raw, own: own) { return refusal.reason }
            // C11H-377: a name is judged by what it resolves to (a public name
            // can answer 127.0.0.1). The viewer's guard checks again at every
            // hop and its proxy at every connection.
            guard resolvingNames, let name = ShowURLPolicy.nameToResolve(in: url) else { return nil }
            return ShowURLPolicy.refusalForResolved(host: name, addresses: ShowHostResolver.resolve(name), own: own)?.reason
        }
        return ["http", "https", "file"].contains(scheme) ? nil : ShowURLPolicy.Reason.localScheme
    }

    /// The file's stat for a path source (nil for a URL), or why it cannot be
    /// shown. Off main: a remote stat is an hc round trip.
    static func check(_ source: ShowSourceSpec, origin: ShowOrigin, fetcher: (any ShowFetcher)?) async -> Result<ShowFileStat?, Refused> {
        switch source.kind {
        case .url:
            if let reason = urlRefusal(source.target, origin: origin) {
                return .failure(Refused(code: ShowSpec.Code.refusedURL, message: reason))
            }
            return .success(nil)
        case .path:
            guard let fetcher else {
                return .failure(Refused(code: ShowSpec.Code.unreachable, message: ShowFetchError.unreachable("").message))
            }
            do {
                let stat = try await fetcher.stat(source.target)
                guard stat.size <= Int64(ShowSpec.maxBytes) else { throw ShowFetchError.tooLarge(stat.size) }
                return .success(stat)
            } catch let error as ShowFetchError {
                return .failure(Refused(code: error.code, message: "\(source.target): \(error.message)"))
            } catch {
                return .failure(Refused(code: ShowSpec.Code.unreachable, message: ShowFetchError.unreachable("\(error)").message))
            }
        }
    }
}

/// What a page in a viewer from a linked machine may do (C11H-353). A viewer
/// is display only: nothing a linked machine shows may reach the operator's
/// Mac. Script runs only in a page c11 serves itself (the show scheme), and
/// that page's Content-Security-Policy keeps every load and connection
/// inside the shown file and folder. Any other document (a URL shown from
/// there, or a page the viewer reaches) runs no script: c11 cannot fence a
/// page it does not serve, and a host name can resolve to this Mac. Every
/// navigation passes the same rule as a shown URL. A show from this Mac has
/// no guard: its agent can already run anything here.
struct ShowPageGuard: Sendable {
    /// This Mac's names and addresses, read at each check. Main-safe: names
    /// come from the cache an off-main preflight filled, never resolved here.
    var ownAddresses: @Sendable () -> ShowURLPolicy.OwnAddresses = { ShowOwnAddresses.currentWithoutResolving() }
    /// Whether a served page may run script at all. A CSP does not govern
    /// WebRTC, whose ICE traffic reaches any address, loopback included, so
    /// served script needs peer connections off; where this WebKit cannot
    /// turn them off, no page in the viewer runs script.
    var allowsServedScript = true

    /// Sent with every response a guarded viewer's scheme handler serves.
    /// Script, styles, images, fonts, media and connections come only from
    /// the show scheme (which serves only the shown file and `--dir`), plus
    /// inline and `data:`/`blob:` content that loads nothing. No frames,
    /// workers, plugins, forms or base override.
    /// The only sandbox allowances a served page keeps.
    static let sandboxAllowances = ["allow-scripts", "allow-same-origin"]

    static let contentSecurityPolicy: String = {
        let own = ShowSpec.acceptedSchemes.map { $0 + ":" }.joined(separator: " ")
        return [
            "default-src 'none'",
            "script-src \(own) 'unsafe-inline' 'unsafe-eval'",
            "style-src \(own) 'unsafe-inline'",
            "img-src \(own) data: blob:",
            "font-src \(own) data:",
            "media-src \(own) data: blob:",
            "connect-src \(own)",
            "frame-src 'none'",
            "worker-src 'none'",
            "object-src 'none'",
            "manifest-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            // C11H-377: no dialogs, popups, downloads, forms or navigation of
            // other contexts. Same-origin stays, so module scripts and
            // same-scheme fetches need no CORS.
            "sandbox \(sandboxAllowances.joined(separator: " "))",
        ].joined(separator: "; ")
    }()

    /// Whether the guard applies to a viewer of `origin`: every show from a
    /// linked machine.
    static func applies(to origin: ShowOrigin, guardLocalForProof: Bool = debugGuardsLocalShows) -> Bool {
        origin.isRemote || guardLocalForProof
    }

    /// A debug build may also guard a show from this Mac (the defaults key
    /// `c11.debug.showGuardLocal`), so a sandbox guest with no linked machine
    /// can prove the guard in WebKit. A release build never reads it.
    static var debugGuardsLocalShows: Bool {
#if DEBUG
        UserDefaults.standard.bool(forKey: "c11.debug.showGuardLocal")
#else
        false
#endif
    }

    static func isShowScheme(_ url: URL) -> Bool {
        url.scheme.map { ShowSpec.acceptedSchemes.contains($0.lowercased()) } ?? false
    }

    /// Nil when a guarded viewer may load `url` in any frame; else why not.
    func refusal(for url: URL) -> String? {
        if Self.isShowScheme(url) { return nil }
        switch url.scheme?.lowercased() {
        case "about":
            let document = url.absoluteString.lowercased().split(separator: "#", maxSplits: 1).first.map(String.init)
            return document == "about:blank" || document == "about:srcdoc" ? nil : ShowURLPolicy.Reason.scheme
        case "http", "https":
            return ShowURLPolicy.refusalForRemote(url.absoluteString, own: ownAddresses())?.reason
        default:
            return ShowURLPolicy.Reason.scheme
        }
    }

    /// Whether a main-frame document at `url` may run its own script.
    func allowsScript(for url: URL) -> Bool { allowsServedScript && Self.isShowScheme(url) }

    /// C11H-377: how a host name is resolved for the guard, off main.
    var resolve: @Sendable (String) -> [String]? = { ShowHostResolver.resolve($0) }

    /// `refusal(for:)`, plus what a host name resolves to. Calls back on
    /// main; resolves off main, so it never blocks a WebKit callback. Each
    /// server-redirect hop asks again. A name that answers differently at
    /// the load is stopped by the viewer's proxy (`ShowGuardProxy`).
    func resolvedRefusal(for url: URL, completion: @escaping @MainActor (String?) -> Void) {
        if let refusal = refusal(for: url) {
            MainActor.assumeIsolated { completion(refusal) }
            return
        }
        guard let name = ShowURLPolicy.nameToResolve(in: url) else {
            MainActor.assumeIsolated { completion(nil) }
            return
        }
        let resolve = self.resolve, own = self.ownAddresses
        DispatchQueue.global(qos: .userInitiated).async {
            let refusal = ShowURLPolicy.refusalForResolved(host: name, addresses: resolve(name), own: own())?.reason
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(refusal) } }
        }
    }
}

/// C11H-377: a host name's numeric addresses from the system resolver, or nil
/// when it does not resolve within the limit. Never on main.
enum ShowHostResolver {
    static let defaultTimeout: TimeInterval = 2
    /// Tests replace it; it must not touch the network there.
    nonisolated(unsafe) static var lookup: @Sendable (String) -> [String]? = { systemLookup($0) }

    static func resolve(_ host: String, timeout: TimeInterval = defaultTimeout) -> [String]? {
        let box = ShowResolveBox()
        let semaphore = DispatchSemaphore(value: 0)
        let lookup = self.lookup
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(lookup(host))
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    static func systemLookup(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return nil }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let sa = entry.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(cString: buffer)
                    if !out.contains(text) { out.append(text) }
                }
            }
            cursor = entry.pointee.ai_next
        }
        return out.isEmpty ? nil : out
    }
}

private final class ShowResolveBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String]?
    func set(_ value: [String]?) { lock.lock(); stored = value; lock.unlock() }
    var value: [String]? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// This Mac's own names and addresses. Interface addresses are read on every
/// call (a network change must count at once); host names are kept a minute,
/// since resolving them can be slow. Tests replace `provider`.
enum ShowOwnAddresses {
    nonisolated(unsafe) static var provider: (() -> ShowURLPolicy.OwnAddresses)?
    /// The slow part: this Mac's host names from the resolver. Never on main.
    nonisolated(unsafe) static var resolveNames: () -> [String] = {
        var names = [ProcessInfo.processInfo.hostName]
        if let local = Host.current().localizedName { names.append(local.replacingOccurrences(of: " ", with: "-")) }
        names.append(contentsOf: Host.current().names)
        return names
    }
    nonisolated(unsafe) private static var names: (value: Set<String>, at: Date)?
    private static let lock = NSLock()

    /// Addresses fresh, names only from the cache (never resolved here).
    static func currentWithoutResolving() -> ShowURLPolicy.OwnAddresses {
        if let provider { return provider() }
        lock.lock()
        let cachedNames = names?.value ?? []
        lock.unlock()
        let fresh = ShowURLPolicy.OwnAddresses.current(includeNames: false)
        return ShowURLPolicy.OwnAddresses(names: cachedNames.union(fresh.names), addresses: fresh.addresses)
    }

    static func current() -> ShowURLPolicy.OwnAddresses {
        if let provider { return provider() }
        lock.lock()
        let cachedNames = names.flatMap { Date().timeIntervalSince($0.at) < 60 ? $0.value : nil }
        lock.unlock()
        let fresh = ShowURLPolicy.OwnAddresses.current(includeNames: cachedNames == nil)
        if cachedNames == nil {
            lock.lock(); names = (fresh.names, Date()); lock.unlock()
            return fresh
        }
        return ShowURLPolicy.OwnAddresses(names: cachedNames!, addresses: fresh.addresses)
    }
}
