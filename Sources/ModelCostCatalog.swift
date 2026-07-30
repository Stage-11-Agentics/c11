import Foundation

// MARK: - Model token-cost catalog (picker cost column, agent-maintained)
//
// The launch picker's `$in/$out` per-Mtok column reads from one JSON file at
// the c11 state root, `model-costs.json`. There is no bundled price table and
// no network fetch: the catalog is filled and refreshed by agents over
// `c11 model-costs` (file-first, app-down capable, same rail as `c11 config`),
// so prices carry their own `source` + `observed_at` provenance instead of
// silently rotting inside a release binary. Values are API list prices — on
// subscription plans the marginal cost differs; the column is a relative
// magnitude signal, not billing truth.
//
// Schema (keys are model ids as c11 knows them — short forms like `opus`,
// full ids like `claude-opus-5`, router forms like `deepseek/deepseek-chat`):
//
//   { "<model-id>": { "in_usd": 15, "out_usd": 75,
//                     "source": "<url>", "observed_at": "2026-07-30",
//                     "notes": "<optional caveat>" } }

/// One model's USD-per-million-token pricing plus provenance.
struct ModelCostEntry: Codable, Equatable {
    var inUSD: Double
    var outUSD: Double
    var source: String?
    var observedAt: String?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case inUSD = "in_usd"
        case outUSD = "out_usd"
        case source
        case observedAt = "observed_at"
        case notes
    }
}

/// Queue-confined file store for the catalog. Reads are fresh from disk (the
/// picker rebuilds per open; agents may have updated the file since), writes
/// are atomic whole-file replaces.
final class ModelCostCatalogStore: @unchecked Sendable {
    static let fileName = "model-costs.json"

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.stage11.c11.model-costs")

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// Process-wide store at the c11 state root; `nil` only when the state
    /// directory is unresolvable (sandboxed test hosts) — callers degrade to
    /// "no cost column".
    static let shared: ModelCostCatalogStore? = {
        guard let root = try? EventLogLayout.defaultStateURL() else { return nil }
        return ModelCostCatalogStore(directory: root)
    }()

    // MARK: Reads

    func catalog() -> [String: ModelCostEntry] {
        queue.sync { loadLocked() }
    }

    /// Picker lookup. Tries the exact id, the lowercased id, then the
    /// provider-stripped form (`deepseek/deepseek-chat` → `deepseek-chat`).
    /// `nil` model (inherit) or no entry → no cost shown; deliberately no
    /// fuzzy matching beyond that, so a wrong price can't attach to a
    /// look-alike model.
    func cost(forModel model: String?) -> (inUSD: Double, outUSD: Double)? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return nil }
        let entries = catalog()
        let lowered = model.lowercased()
        var candidates = [model, lowered]
        if let slash = lowered.firstIndex(of: "/") {
            candidates.append(String(lowered[lowered.index(after: slash)...]))
        }
        for key in candidates {
            if let e = entries[key] { return (e.inUSD, e.outUSD) }
        }
        return nil
    }

    // MARK: Writes

    func set(model: String, entry: ModelCostEntry) throws {
        try queue.sync {
            var entries = loadLocked()
            entries[model] = entry
            try writeLocked(entries)
        }
    }

    @discardableResult
    func remove(model: String) throws -> Bool {
        try queue.sync {
            var entries = loadLocked()
            guard entries.removeValue(forKey: model) != nil else { return false }
            try writeLocked(entries)
            return true
        }
    }

    /// Bulk import. `replace: false` merges (incoming keys win); `true` swaps
    /// the whole catalog for the incoming one.
    func importCatalog(_ incoming: [String: ModelCostEntry], replace: Bool) throws {
        try queue.sync {
            var entries = replace ? [:] : loadLocked()
            for (k, v) in incoming { entries[k] = v }
            try writeLocked(entries)
        }
    }

    // MARK: Locked internals

    private func loadLocked() -> [String: ModelCostEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: ModelCostEntry].self, from: data)) ?? [:]
    }

    private func writeLocked(_ entries: [String: ModelCostEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - CLI core (`c11 model-costs …`, file-first)

/// Shared logic for the `model-costs` CLI family. Lives beside the store so
/// the app target and the CLI target compile one implementation, mirroring
/// `ConfigCommandCore` (C11-180). All subcommands are file-first: they work
/// with the app down and never touch the socket.
struct ModelCostsCommandCore {
    struct Failure: Error { let message: String }

    static let usage = """
    Usage: c11 model-costs <subcommand>

      list [--json]                     Print the catalog (model → $in/$out per Mtok)
      get <model> [--json]              Print one model's entry
      set <model> --in <usd> --out <usd> [--source <url>] [--notes <text>]
                                        Add or update a model (stamps observed_at)
      rm <model>                        Remove a model
      import <path|-> [--replace]       Bulk import a catalog JSON (merge by default)

    The catalog is model-costs.json at the c11 state root — agent-maintained
    API list prices feeding the launch picker's cost column.
    """

    /// Run a subcommand against `store`. `now` is injectable for tests.
    static func run(
        args: [String],
        store: ModelCostCatalogStore,
        now: Date = Date()
    ) throws -> String {
        guard let sub = args.first?.lowercased() else { throw Failure(message: usage) }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":
            return try list(store: store, json: rest.contains("--json"))
        case "get":
            guard let model = firstPositional(rest) else {
                throw Failure(message: "model-costs get: missing <model>")
            }
            return try get(model: model, store: store, json: rest.contains("--json"))
        case "set":
            return try set(args: rest, store: store, now: now)
        case "rm":
            guard let model = firstPositional(rest) else {
                throw Failure(message: "model-costs rm: missing <model>")
            }
            guard try store.remove(model: model) else {
                throw Failure(message: "model-costs rm: no entry for '\(model)'")
            }
            return "OK removed \(model)"
        case "import":
            return try importCatalog(args: rest, store: store)
        case "help", "--help", "-h":
            return usage
        default:
            throw Failure(message: "model-costs: unknown subcommand '\(sub)'\n\n\(usage)")
        }
    }

    // MARK: Subcommands

    private static func list(store: ModelCostCatalogStore, json: Bool) throws -> String {
        let entries = store.catalog()
        if json {
            return try encodeJSON(entries)
        }
        guard !entries.isEmpty else {
            return "model-costs: catalog is empty (state root model-costs.json)"
        }
        let width = entries.keys.map(\.count).max() ?? 0
        return entries.sorted { $0.key < $1.key }.map { key, e in
            let padded = key.padding(toLength: max(width, key.count), withPad: " ", startingAt: 0)
            var line = "\(padded)  $\(trim(e.inUSD))/$\(trim(e.outUSD))"
            if let observed = e.observedAt { line += "  (\(observed))" }
            return line
        }.joined(separator: "\n")
    }

    private static func get(model: String, store: ModelCostCatalogStore, json: Bool) throws -> String {
        guard let entry = store.catalog()[model] else {
            throw Failure(message: "model-costs get: no entry for '\(model)'")
        }
        if json { return try encodeJSON([model: entry]) }
        var out = "\(model)  $\(trim(entry.inUSD))/$\(trim(entry.outUSD)) per Mtok"
        if let s = entry.source { out += "\n  source: \(s)" }
        if let o = entry.observedAt { out += "\n  observed: \(o)" }
        if let n = entry.notes { out += "\n  notes: \(n)" }
        return out
    }

    private static func set(args: [String], store: ModelCostCatalogStore, now: Date) throws -> String {
        guard let model = firstPositional(args) else {
            throw Failure(message: "model-costs set: missing <model>")
        }
        guard let inRaw = option(args, "--in"), let inUSD = Double(inRaw), inUSD >= 0 else {
            throw Failure(message: "model-costs set: --in <usd-per-Mtok> is required and must be a non-negative number")
        }
        guard let outRaw = option(args, "--out"), let outUSD = Double(outRaw), outUSD >= 0 else {
            throw Failure(message: "model-costs set: --out <usd-per-Mtok> is required and must be a non-negative number")
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let entry = ModelCostEntry(
            inUSD: inUSD,
            outUSD: outUSD,
            source: option(args, "--source"),
            observedAt: formatter.string(from: now),
            notes: option(args, "--notes")
        )
        try store.set(model: model, entry: entry)
        return "OK \(model) = $\(trim(inUSD))/$\(trim(outUSD)) per Mtok"
    }

    private static func importCatalog(args: [String], store: ModelCostCatalogStore) throws -> String {
        guard let path = firstPositional(args) else {
            throw Failure(message: "model-costs import: missing <path|->")
        }
        let data: Data
        if path == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            guard let fileData = FileManager.default.contents(atPath: path) else {
                throw Failure(message: "model-costs import: cannot read \(path)")
            }
            data = fileData
        }
        let incoming: [String: ModelCostEntry]
        do {
            incoming = try JSONDecoder().decode([String: ModelCostEntry].self, from: data)
        } catch {
            throw Failure(message: "model-costs import: invalid catalog JSON — expected {\"<model>\": {\"in_usd\": n, \"out_usd\": n, ...}} (\(error.localizedDescription))")
        }
        try store.importCatalog(incoming, replace: args.contains("--replace"))
        return "OK imported \(incoming.count) entr\(incoming.count == 1 ? "y" : "ies")\(args.contains("--replace") ? " (replaced catalog)" : "")"
    }

    // MARK: Helpers

    private static func encodeJSON(_ entries: [String: ModelCostEntry]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try encoder.encode(entries), encoding: .utf8) ?? "{}"
    }

    /// Prototype-matching money format: whole dollars drop decimals, sub-dollar
    /// keeps two places (`15` / `0.25` / `3.5`).
    static func trim(_ n: Double) -> String {
        if n >= 1, n.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(n)) }
        let two = String(format: "%.2f", n)
        return two.hasSuffix("0") && n >= 1 ? String(two.dropLast()) : two
    }

    private static func option(_ args: [String], _ name: String) -> String? {
        var i = 0
        while i < args.count {
            if args[i] == name, i + 1 < args.count { return args[i + 1] }
            if args[i].hasPrefix(name + "=") { return String(args[i].dropFirst(name.count + 1)) }
            i += 1
        }
        return nil
    }

    private static func firstPositional(_ args: [String]) -> String? {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                if !a.contains("="), i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    i += 2; continue
                }
                i += 1; continue
            }
            return a
        }
        return nil
    }
}
