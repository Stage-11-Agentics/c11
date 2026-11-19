import Bonsplit
import Foundation
import Network
import SystemConfiguration
import WebKit

/// C11H-386: a guarded show viewer must reach nothing on the operator's own Mac. WebKit routes a load
/// to any of this Mac's own addresses — loopback, link-local, and every interface address (utun and
/// Tailscale included) — directly, around the pinned guard proxy, and a non-navigation subresource
/// (image, stylesheet, `@font-face`, media, object, preload, preconnect) also skips the navigation
/// policy. The guest proof in C11H-386 showed `<img src="http://127.0.0.1:…">`, the same for `::1`,
/// `127.0.0.2`, `[::ffff:127.0.0.1]`, `localhost`, and this Mac's own LAN and link-local addresses,
/// all reaching this Mac from a guarded viewer.
///
/// A `WKContentRuleList` is the only WebKit layer that blocks every load — document and subresource —
/// by URL, before any connection, regardless of the proxy. Loopback and link-local are fixed; this
/// Mac's interface addresses are read when a viewer is set up and read again, off main, whenever an
/// interface or its addresses change (a VPN or Tailscale coming up, a VM's bridge, a lo0 alias). Each
/// newer list is swapped onto every open guarded viewer. If no addresses can be read or the list
/// cannot be built, the viewer does not load. The pin still stands for host names (which WebKit hands
/// it to resolve) and for addresses that are not this Mac's.
@MainActor
final class ShowViewerLoopbackBlocker {
    static let shared = ShowViewerLoopbackBlocker(seams: .live)

    /// One fixed identifier. Each compile overwrites the store's single entry, so the store never
    /// keeps a list per address set it has seen; and a controller holds one list per identifier, so
    /// `add` of a newer list replaces the one it holds in place, with no moment where the viewer holds
    /// none (WebKit keys a controller's lists by identifier). Nothing here ever removes a list.
    nonisolated static let identifier = "c11-show-viewer-own-address-block"

    /// What the blocker reads and compiles with. `live` is this Mac and WebKit's default store; tests
    /// pass a scripted address source and a temporary store.
    struct Seams {
        /// This Mac's own numeric interface addresses, lowercased, scope id dropped. It runs off main
        /// and never touches the network (`getifaddrs` only). An empty set means the read failed: a
        /// Mac always has lo0's addresses.
        var readAddresses: @Sendable () -> Set<String>
        /// Compiles an encoded rule list under `identifier` and calls back on main (nil: not built).
        var compile: @MainActor (_ encodedRuleList: String, _ completion: @escaping (WKContentRuleList?) -> Void) -> Void
        /// How long to wait before reading again after a failed read or compile.
        var retryDelay: TimeInterval
        /// Whether to watch this Mac's interfaces. Tests call `refresh()` themselves.
        var watchesInterfaces: Bool

        static let live = Seams(
            readAddresses: { ShowURLPolicy.OwnAddresses.current(includeNames: false).addresses },
            compile: { encoded, completion in
                ShowViewerLoopbackBlocker.compile(encoded, in: WKContentRuleListStore.default(), completion: completion)
            },
            retryDelay: 2,
            watchesInterfaces: true
        )
    }

    /// Compiles `encoded` into `store` under the fixed identifier and calls back on main.
    nonisolated static func compile(
        _ encoded: String,
        in store: WKContentRuleListStore?,
        completion: @escaping (WKContentRuleList?) -> Void
    ) {
        guard let store else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded) { list, error in
            DispatchQueue.main.async {
#if DEBUG
                if list == nil { dlog("show.viewerOwnAddressBlock.compileFailed error=\(String(describing: error))") }
#endif
                completion(list)
            }
        }
    }

    // MARK: - The rules

    // scheme × host × end, as BrowserRemoteLoopbackBlocker builds them: WebKit's url-filter has no
    // alternation and no counted repetition, so one filter per scheme family and host form.
    nonisolated private static let schemes = [#"^https?://"#, #"^wss?://"#]
    nonisolated private static let userinfo = #"([^/?#@]*@)?"#
    nonisolated private static let end = #"[:/?#]"#

    /// Loopback, unspecified and link-local: fixed, always blocked. Each host form is written as
    /// WebKit's URL parser writes the host it matches: IPv4 dotted decimal (every other spelling of
    /// an IPv4 address is normalised to it first), IPv6 in lowercase hex with no leading zeros.
    nonisolated static let staticHostPatterns: [String] = [
        // `localhost` and its forms, which WebKit resolves itself and sends around the proxy.
        #"localhost[.]?"#,
        #"[^/?#@:]*[.]localhost[.]?"#,
        #"localhost[.]localdomain[.]?"#,
        #"ip6-localhost"#,
        #"ip6-loopback"#,
        // 127/8.
        #"127[.][0-9]+[.][0-9]+[.][0-9]+"#,
        // 0.0.0.0, which macOS connects to this Mac. (Other 0/8 addresses do not connect here.)
        #"0[.]0[.]0[.]0"#,
        // 169.254/16.
        #"169[.]254[.][0-9]+[.][0-9]+"#,
        // ::1 and ::.
        #"\[::1?\]"#,
        // Every IPv4-mapped literal. WebKit writes `[::ffff:192.168.64.6]` as `[::ffff:c0a8:4006]` and
        // dials it as 192.168.64.6, so a mapped form of any of this Mac's addresses (loopback, link-local,
        // LAN, VPN) would reach it. No page needs one: it can write the IPv4 plainly, which this list
        // or the pin then judges.
        #"\[::ffff:[0-9a-f:]*\]"#,
        // fe80::/10: a first piece from fe80 to febf.
        #"\[fe[89ab][0-9a-f]:[0-9a-f:]*\]"#,
    ]

    /// A url-filter host fragment for one of this Mac's own interface addresses, written as WebKit
    /// writes that host. nil for text that is no address.
    nonisolated static func ownAddressPattern(_ address: String) -> String? {
        var bare = address.lowercased()
        if let zone = bare.firstIndex(of: "%") { bare = String(bare[..<zone]) }
        if bare.hasPrefix("[") && bare.hasSuffix("]") { bare = String(bare.dropFirst().dropLast()) }
        guard !bare.isEmpty else { return nil }
        if bare.contains(":") {
            guard let bytes = ShowURLPolicy.ipv6(bare) else { return nil }
            return #"\["# + urlHostIPv6(bytes) + #"\]"#
        }
        guard bare.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        return bare.replacingOccurrences(of: ".", with: #"[.]"#)
    }

    /// An IPv6 address as WebKit's URL parser serialises a host (the WHATWG URL serializer): eight
    /// lowercase hex pieces without leading zeros, the first longest run of two or more zero pieces
    /// written `::`.
    nonisolated static func urlHostIPv6(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "" }
        let pieces = (0..<8).map { UInt16(bytes[2 * $0]) << 8 | UInt16(bytes[2 * $0 + 1]) }
        var compress: Int?
        var longest = 1
        var index = 0
        while index < 8 {
            guard pieces[index] == 0 else { index += 1; continue }
            var run = index
            while run < 8 && pieces[run] == 0 { run += 1 }
            if run - index > longest { longest = run - index; compress = index }
            index = run
        }
        var output = ""
        var ignoreZero = false
        for (position, piece) in pieces.enumerated() {
            if ignoreZero && piece == 0 { continue }
            ignoreZero = false
            if position == compress {
                output += position == 0 ? "::" : ":"
                ignoreZero = true
                continue
            }
            output += String(piece, radix: 16)
            if position != 7 { output += ":" }
        }
        return output
    }

    /// Every url-filter the list carries for `ownAddresses`.
    nonisolated static func hostFilters(ownAddresses: Set<String>) -> [String] {
        let hosts = staticHostPatterns + Set(ownAddresses.compactMap(ownAddressPattern)).sorted()
        return schemes.flatMap { scheme in hosts.map { scheme + userinfo + $0 + end } }
    }

    nonisolated static func ruleListJSON(ownAddresses: Set<String>) -> String {
        let rules: [[String: Any]] = hostFilters(ownAddresses: ownAddresses).map { filter in
            ["trigger": ["url-filter": filter], "action": ["type": "block"]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A WebKit-free seam: whether the serialised list `ruleListJSON` blocks every load of
    /// `canonicalURL`, a URL written as WebKit's URL parser writes it (dotted IPv4, IPv6 in lowercase
    /// hex, a path of at least "/"). It reads the rules in order as WebKit applies them: a matching
    /// `block` blocks, a later matching `ignore-previous-rules` undoes it, and a rule whose trigger
    /// carries any condition beyond its url-filter is not one that blocks every load.
    nonisolated static func blocks(canonicalURL: String, ruleListJSON: String) -> Bool {
        guard let rules = (try? JSONSerialization.jsonObject(with: Data(ruleListJSON.utf8))) as? [[String: Any]] else {
            return false
        }
        let unconditional: Set<String> = ["url-filter", "url-filter-is-case-sensitive"]
        let range = NSRange(canonicalURL.startIndex..., in: canonicalURL)
        var blocked = false
        for rule in rules {
            guard let trigger = rule["trigger"] as? [String: Any],
                  Set(trigger.keys).isSubset(of: unconditional),
                  let filter = trigger["url-filter"] as? String,
                  let type = (rule["action"] as? [String: Any])?["type"] as? String else { continue }
            let caseSensitive = trigger["url-filter-is-case-sensitive"] as? Bool ?? false
            guard let regex = try? NSRegularExpression(pattern: filter, options: caseSensitive ? [] : [.caseInsensitive]),
                  regex.firstMatch(in: canonicalURL, range: range) != nil else { continue }
            if type == "block" { blocked = true }
            if type == "ignore-previous-rules" { blocked = false }
        }
        return blocked
    }

    // MARK: - Install and refresh

    private struct Observed {
        var addresses: Set<String>
        var generation: UInt64
    }

    private struct Compiled {
        var addresses: Set<String>
        var generation: UInt64
        var list: WKContentRuleList
    }

    /// A viewer's content controller that holds the list, and the generation it holds.
    private struct Record {
        weak var controller: WKUserContentController?
        var generation: UInt64
        var addresses: Set<String>
    }

    /// An install waiting for a list of the latest set. A viewer that closes meanwhile is answered
    /// `false` and never registered.
    private struct Waiter {
        weak var controller: WKUserContentController?
        let completion: (Bool) -> Void
    }

    private let seams: Seams
    private let queue = DispatchQueue(label: "com.stage11.c11.show-viewer-own-address-block")
    /// The latest address set read, with a generation that rises each time the set changes.
    private var latest: Observed?
    private var generation: UInt64 = 0
    /// The newest list compiled.
    private var current: Compiled?
    private var compiling = false
    private var records: [ObjectIdentifier: Record] = [:]
    private var waiters: [Waiter] = []
    private var retryScheduled = false
    private var pathMonitor: NWPathMonitor?
    private var dynamicStore: SCDynamicStore?

    init(seams: Seams) {
        self.seams = seams
    }

    /// Install the block on a guarded viewer's content controller, from a fresh read of this Mac's
    /// addresses. `completion(true)` comes only once the controller holds the list for the latest set
    /// read; `completion(false)` (no addresses read, or the list not built) means the caller must
    /// not load the viewer.
    func install(into controller: WKUserContentController, completion: @escaping (Bool) -> Void) {
        watchInterfacesIfNeeded()
        prune()
        read { [weak self] addresses in
            guard let self, !addresses.isEmpty else {
#if DEBUG
                dlog("show.viewerOwnAddressBlock.readFailed at=install")
#endif
                completion(false)
                return
            }
            self.waiters.append(Waiter(controller: controller, completion: completion))
            self.observe(addresses)
        }
    }

    /// Read this Mac's addresses again and, if they changed, build the new list and swap it onto every
    /// open viewer. The interface watchers call it, and so does the retry after a failed read or
    /// compile. A failed read or compile never replaces a list: every open viewer keeps the one it has.
    func refresh() {
        prune()
        // With no viewer open or waiting, the next install reads the fresh set itself.
        guard !records.isEmpty || !waiters.isEmpty else { return }
        read { [weak self] addresses in
            guard let self else { return }
            guard !addresses.isEmpty else {
#if DEBUG
                dlog("show.viewerOwnAddressBlock.readFailed at=refresh")
#endif
                self.scheduleRetry()
                return
            }
            self.observe(addresses)
        }
    }

    /// Reads off main on one serial queue, so reads land on main in the order they were made.
    private func read(_ completion: @escaping (Set<String>) -> Void) {
        let readAddresses = seams.readAddresses
        queue.async {
            let addresses = readAddresses()
            DispatchQueue.main.async { completion(addresses) }
        }
    }

    private func observe(_ addresses: Set<String>) {
        if latest?.addresses != addresses {
            generation &+= 1
            latest = Observed(addresses: addresses, generation: generation)
#if DEBUG
            dlog("show.viewerOwnAddressBlock.observed generation=\(generation) addresses=\(addresses.count)")
#endif
        }
        advance()
    }

    /// Brings every open viewer, and every waiting install, to a list of the latest set read. One
    /// compile runs at a time; a set read while it runs compiles next. Every list that compiles is
    /// swapped onto every open viewer here, whether an install or a refresh asked for it, and a
    /// waiting install completes only with the list of the latest set.
    private func advance() {
        guard let latest else { return }
        if let current, current.generation == latest.generation {
            publish(current)
            finishWaiters(with: current)
            return
        }
        guard !compiling else { return }
        compiling = true
        let target = latest
        seams.compile(Self.ruleListJSON(ownAddresses: target.addresses)) { [weak self] list in
            guard let self else { return }
            self.compiling = false
            guard let list else {
                if target.generation == self.latest?.generation {
                    // Open viewers keep their list; a viewer waiting for this set cannot load.
                    self.failWaiters()
                    self.scheduleRetry()
                } else {
                    self.advance()
                }
                return
            }
            let compiled = Compiled(addresses: target.addresses, generation: target.generation, list: list)
            self.current = compiled
            self.publish(compiled)
            self.advance()
        }
    }

    private func publish(_ compiled: Compiled) {
        var swapped = 0
        for (key, record) in records {
            guard let controller = record.controller else {
                records[key] = nil
                continue
            }
            guard record.generation != compiled.generation else { continue }
            controller.add(compiled.list)
            records[key] = Record(controller: controller, generation: compiled.generation, addresses: compiled.addresses)
            swapped += 1
        }
#if DEBUG
        if swapped > 0 { dlog("show.viewerOwnAddressBlock.swapped generation=\(compiled.generation) viewers=\(swapped)") }
#endif
    }

    private func finishWaiters(with compiled: Compiled) {
        let ready = waiters
        waiters = []
        for waiter in ready {
            guard let controller = waiter.controller else {
                waiter.completion(false)
                continue
            }
            let key = ObjectIdentifier(controller)
            if let record = records[key], record.controller === controller, record.generation == compiled.generation {
                // Already holds this list.
            } else {
                controller.add(compiled.list)
            }
            records[key] = Record(controller: controller, generation: compiled.generation, addresses: compiled.addresses)
#if DEBUG
            dlog("show.viewerOwnAddressBlock.installed generation=\(compiled.generation)")
#endif
            waiter.completion(true)
        }
    }

    private func failWaiters() {
        let failed = waiters
        waiters = []
        for waiter in failed { waiter.completion(false) }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seams.retryDelay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.refresh()
        }
    }

    private func prune() {
        records = records.filter { $0.value.controller != nil }
    }

    // MARK: - Interface watchers

    /// Two triggers, one refresh. NWPathMonitor reports a change of network path; the dynamic store
    /// publishes every interface's addresses (`State:/Network/Interface/<name>/IPv4` and `IPv6`), so
    /// an address change that leaves the path as it was (a lo0 alias, a VM's bridge, a new IPv6
    /// temporary address) also refreshes the list. A refresh that reads an unchanged set does nothing.
    private func watchInterfacesIfNeeded() {
        guard seams.watchesInterfaces, pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
#if DEBUG
                dlog("show.viewerOwnAddressBlock.trigger source=path")
#endif
                self?.refresh()
            }
        }
        pathMonitor = monitor
        monitor.start(queue: queue)

        // The callback finds this blocker through `info`, unretained: only the shared blocker, which
        // lives as long as the app, watches interfaces.
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            nil, "c11.show-viewer-own-address-block" as CFString, showViewerInterfaceAddressesChanged, &context
        ) else {
#if DEBUG
            dlog("show.viewerOwnAddressBlock.dynamicStoreUnavailable")
#endif
            return
        }
        let patterns = [#"State:/Network/Interface/[^/]+/IPv[46]"#] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns), SCDynamicStoreSetDispatchQueue(store, queue) else {
#if DEBUG
            dlog("show.viewerOwnAddressBlock.dynamicStoreWatchFailed")
#endif
            return
        }
        dynamicStore = store
    }

    // MARK: - For tests

    /// The address set whose list `controller` holds, or nil when it holds none from this blocker.
    func installedAddresses(on controller: WKUserContentController) -> Set<String>? {
        guard let record = records[ObjectIdentifier(controller)], record.controller === controller else { return nil }
        return record.addresses
    }

    /// How many open viewers hold the list.
    var registeredCount: Int { records.values.filter { $0.controller != nil }.count }

    /// The generation of the latest set read (it rises each time the set changes).
    var latestGeneration: UInt64 { latest?.generation ?? 0 }
}

/// The dynamic store's callback (a C function, so it captures nothing): refresh the blocker `info`
/// names, on main.
private func showViewerInterfaceAddressesChanged(_ store: SCDynamicStore, _ keys: CFArray, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    let blocker = Unmanaged<ShowViewerLoopbackBlocker>.fromOpaque(info).takeUnretainedValue()
    DispatchQueue.main.async {
#if DEBUG
        dlog("show.viewerOwnAddressBlock.trigger source=dynamicStore")
#endif
        blocker.refresh()
    }
}
