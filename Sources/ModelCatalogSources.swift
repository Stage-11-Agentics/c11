import Foundation

// MARK: - Model catalog sources: CLI parsers, declarations, enumeration
// (C11-203 Part D)
//
// Five harnesses enumerate their own catalog and two do not. The parsers below
// are written against captured real output (committed under
// `c11Tests/Fixtures/model-catalog/`) so an upstream format change fails a test
// instead of silently emptying the picker.
//
// Every parser is total: it never throws, skips anything it does not recognize,
// and returns whatever it did recognize. Harness CLIs print login banners,
// warnings and (for grok) authentication notices on the same stream as their
// data, and a single unexpected line must not cost the whole catalog.
//
// Foundation-only; member of both the app and the CLI targets.

// MARK: - Shared parsing helpers

enum ModelCatalogParsing {

    /// Parse the abbreviated token sizes pi and omp print (`1M`, `1.0M`,
    /// `262.1K`, `8.2K`, `-`). These are the publishers' own rounding: the
    /// result is a magnitude, not an exact context window. Kimi publishes exact
    /// integers and wins the merge for its own models.
    static func tokenCount(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s != "-" else { return nil }
        if let plain = Int(s) { return plain }
        let unit = s.last.map(String.init)?.uppercased() ?? ""
        let multiplier: Double
        switch unit {
        case "K": multiplier = 1_000
        case "M": multiplier = 1_000_000
        case "B": multiplier = 1_000_000_000
        default:  return nil
        }
        guard let value = Double(s.dropLast()), value > 0 else { return nil }
        return Int((value * multiplier).rounded())
    }

    /// Parse a comma-separated thinking-level cell (`minimal,low,medium,high`,
    /// `-`). `-` is an explicit "this model has no levels here", not silence.
    static func effortCell(_ raw: String) -> ModelEffortSupport {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "-" { return .none }
        let levels = s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return levels.isEmpty ? .none : .values(levels)
    }

    /// Trim a CLI's leading banner so `JSONSerialization` sees only the object.
    /// Harness CLIs invoked through a login shell can emit profile output ahead
    /// of their payload.
    static func jsonObjectSlice(_ text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end]).data(using: .utf8)
    }
}

// MARK: - opencode

/// `opencode models` prints one `provider/model` per line and nothing else.
/// The OpenRouter tier is itself namespaced (`openrouter/<provider>/<model>`),
/// which is three segments and flattens to the real provider.
enum OpencodeModelsParser {
    static func parse(_ text: String) -> [RawCatalogRecord] {
        text.split(separator: "\n").compactMap { line in
            let id = line.trimmingCharacters(in: .whitespaces)
            // Data lines always carry a namespace; banners never do.
            guard id.contains("/"), !id.contains(" "), !id.hasPrefix("#") else { return nil }
            return RawCatalogRecord(harness: "opencode", rawID: id)
        }
    }
}

// MARK: - pi

/// `pi --list-models` prints a whitespace-aligned table with a header row:
///
///     provider    model                     context  max-out  thinking  images
///     google      gemini-3-pro-preview      1.0M     65.5K    yes       yes
///     openrouter  ~anthropic/claude-…       1M       128K     yes       yes
///
/// No cell contains a space, so column splitting is plain tokenization. The
/// `thinking` column is a yes/no capability flag, not a level set, so pi
/// contributes no effort declaration.
enum PiModelsParser {
    private static let providerCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_."))

    static func parse(_ text: String) -> [RawCatalogRecord] {
        var out: [RawCatalogRecord] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // provider, model, context, max-out, thinking, images.
            guard fields.count >= 5 else { continue }
            let provider = fields[0]
            let model = fields[1]
            guard provider != "provider", !model.isEmpty else { continue }
            guard provider.unicodeScalars.allSatisfy(providerCharacters.contains) else { continue }
            // A banner line can have six tokens too; a real row's third column
            // is always a size. This is the cheapest reliable row test.
            let context = ModelCatalogParsing.tokenCount(fields[2])
            guard context != nil || fields[2] == "-" else { continue }
            out.append(RawCatalogRecord(
                harness: "pi",
                rawID: "\(provider)/\(model)",
                contextWindow: context,
                providerHint: provider
            ))
        }
        return out
    }
}

// MARK: - omp

/// `omp models` prints one boxed table per provider:
///
///     google (60)
///     ┌──────────┬─────────┬─────────┬──────────┬────────┐
///     │ model    │ context │ max-out │ thinking │ images │
///     ├──────────┼─────────┼─────────┼──────────┼────────┤
///     │ gemini-… │      1M │    8.2K │ -        │ yes    │
///     └──────────┴─────────┴─────────┴──────────┴────────┘
///
/// The section header supplies the provider (cells in the per-provider sections
/// are unprefixed); the OpenRouter section's cells carry their own
/// `<provider>/<model>` prefix. Unlike pi, omp publishes real thinking levels
/// per model, which is where non-Kimi effort declarations come from.
enum OmpModelsParser {
    static func parse(_ text: String) -> [RawCatalogRecord] {
        var out: [RawCatalogRecord] = []
        var section = ""
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            if let header = sectionProvider(line) {
                section = header
                continue
            }
            guard line.contains("│") else { continue }
            // Keep empty interior cells so column indices stay stable; only the
            // pieces outside the leading and trailing pipes are dropped.
            var cells = line.split(separator: "│", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first?.isEmpty == true { cells.removeFirst() }
            if cells.last?.isEmpty == true { cells.removeLast() }
            guard cells.count >= 4, !section.isEmpty else { continue }
            let model = cells[0]
            guard model != "model", !model.isEmpty else { continue }
            out.append(RawCatalogRecord(
                harness: "omp",
                rawID: "\(section)/\(model)",
                contextWindow: ModelCatalogParsing.tokenCount(cells[1]),
                efforts: ModelCatalogParsing.effortCell(cells[3]),
                providerHint: section
            ))
        }
        return out
    }

    /// `google (60)` → `google`. Anything else → nil.
    private static func sectionProvider(_ line: String) -> String? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasSuffix(")"), let open = s.lastIndex(of: "(") else { return nil }
        let name = s[s.startIndex..<open].trimmingCharacters(in: .whitespaces)
        let count = s[s.index(after: open)..<s.index(before: s.endIndex)]
        guard !name.isEmpty, !name.contains(" "), Int(count) != nil else { return nil }
        return name
    }
}

// MARK: - kimi

/// `kimi provider list --json` prints `{ providers: …, models: { "<provider>/<alias>":
/// { model, maxContextSize, capabilities, displayName, supportEfforts?, defaultEffort? } } }`.
///
/// `supportEfforts` (with `defaultEffort`) is present on the K3 aliases and absent on the K2.7 ones,
/// which are `always_thinking` — absence is Kimi declaring "no effort control",
/// so it maps to `.none`, not `.unspecified`. (`~/.kimi-code/config.toml`
/// carries the same `support_efforts` / `default_effort` values; the CLI is the
/// source used here because it is queryable and does not read tenant config.)
enum KimiProviderListParser {
    static func parse(_ text: String) -> [RawCatalogRecord] {
        guard let data = ModelCatalogParsing.jsonObjectSlice(text),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [String: Any] else { return [] }

        var out: [RawCatalogRecord] = []
        for (key, value) in models {
            guard let entry = value as? [String: Any] else { continue }
            // The alias is the model-flag value (`kimi -m k3`); the map key is
            // namespaced by the provider that serves it.
            let alias = (entry["model"] as? String) ?? key.split(separator: "/").last.map(String.init) ?? key
            guard !alias.isEmpty else { continue }
            let efforts: ModelEffortSupport
            if let declared = entry["supportEfforts"] as? [String], !declared.isEmpty {
                efforts = .values(declared)
            } else {
                efforts = .none
            }
            out.append(RawCatalogRecord(
                harness: "kimi",
                rawID: alias,
                displayName: (entry["displayName"] as? String) ?? "",
                contextWindow: entry["maxContextSize"] as? Int,
                efforts: efforts,
                defaultEffort: (entry["defaultEffort"] as? String) ?? "",
                providerHint: "moonshot"
            ))
        }
        return out.sorted { $0.rawID < $1.rawID }
    }
}

// MARK: - grok

/// `grok models` prints a short human report:
///
///     You are logged in with grok.com.
///
///     Default model: grok-4.5
///
///     Available models:
///       * grok-4.5 (default)
///
/// It prints the same list when unauthenticated, with a different banner, so
/// the parser ignores every line it does not recognize and falls back to the
/// `Default model:` line if the bullet list is missing.
enum GrokModelsParser {
    static func parse(_ text: String) -> [RawCatalogRecord] {
        var ids: [String] = []
        var fallback: String?
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*") || line.hasPrefix("-") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                let id = body.split(separator: " ").first.map(String.init) ?? ""
                if !id.isEmpty, !ids.contains(id) { ids.append(id) }
            } else if fallback == nil, let range = line.range(of: "Default model:") {
                let id = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !id.isEmpty, !id.contains(" ") { fallback = id }
            }
        }
        if ids.isEmpty, let fallback { ids = [fallback] }
        return ids.map { RawCatalogRecord(harness: "grok", rawID: $0, providerHint: "xai") }
    }
}

// MARK: - codex

/// The codex CLI has no model-listing command, but it caches the authoritative
/// list it fetched from the service at `~/.codex/models_cache.json`:
///
///     { "fetched_at": …, "etag": …, "client_version": …,
///       "models": [ { "slug", "display_name", "description", "visibility",
///                     "context_window", "supported_reasoning_levels": [{effort, …}],
///                     "default_reasoning_level", "upgrade": {model, …}, … } ] }
///
/// Reading it is inside the CLAUDE.md rule, which forbids *writes* to tenant
/// config, not reads. c11 never writes this file and degrades silently when it
/// is absent.
///
/// This replaces a declared GPT-5.6 list that was wrong: the `-fast` and `-pro`
/// variants exist in OpenAI's *API* catalog (which is what opencode enumerates)
/// but the codex CLI does not offer them, so declaring them would have put
/// unlaunchable rows under the harness the operator uses most.
enum CodexModelsCacheParser {

    /// Default path. Honors `CODEX_HOME` the way the codex CLI does.
    static var defaultPath: String {
        let env = ProcessInfo.processInfo.environment
        if let home = env["CODEX_HOME"], !home.isEmpty {
            return (home as NSString).appendingPathComponent("models_cache.json")
        }
        return NSString(string: "~/.codex/models_cache.json").expandingTildeInPath
    }

    /// Slugs that are routing/internal models rather than operator choices.
    /// `codex-auto-review` is the automatic approval-review model codex runs on
    /// its own behalf. It is also `visibility: "hide"` — but so is
    /// `gpt-5.6-sol-wm`, which *is* an operator choice, so the slug list is the
    /// filter and visibility is deliberately not.
    static let internalSlugs: Set<String> = ["codex-auto-review"]

    static func parse(_ text: String) -> [RawCatalogRecord] {
        guard let data = ModelCatalogParsing.jsonObjectSlice(text),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }

        var out: [RawCatalogRecord] = []
        for entry in models {
            guard let slug = entry["slug"] as? String, !slug.isEmpty,
                  !internalSlugs.contains(slug) else { continue }

            // Per-model effort ladders, and they genuinely differ: Sol and
            // Terra reach `ultra`, Luna stops at `max`, the 5.x line at `xhigh`.
            let levels = (entry["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                .compactMap { $0["effort"] as? String }
                .filter { !$0.isEmpty }

            out.append(RawCatalogRecord(
                harness: "codex",
                rawID: slug,
                displayName: (entry["display_name"] as? String) ?? "",
                contextWindow: entry["context_window"] as? Int,
                efforts: levels.isEmpty ? .none : .values(levels),
                defaultEffort: (entry["default_reasoning_level"] as? String) ?? "",
                upgradeTo: ((entry["upgrade"] as? [String: Any])?["model"] as? String) ?? "",
                providerHint: "openai"
            ))
        }
        return out
    }
}

// MARK: - Declared catalogs (nothing to enumerate)

/// What no catalog can answer for us.
///
/// Claude Code takes family aliases rather than model ids and publishes no list
/// anywhere, so its four families are declared outright. Codex's Astra is
/// declared because it does not exist yet. Everything else, including the rest
/// of the Codex line, is read from a publisher.
enum ModelCatalogDeclarations {

    /// Claude Code's four families (ticket D1 — confirmed correct as-is).
    /// No per-model effort declaration: claude-code's `--effort` values are a
    /// harness-level set and come from its manifest.
    static let claudeCode: [RawCatalogRecord] = [
        RawCatalogRecord(harness: "claude-code", rawID: "opus", displayName: "Opus", providerHint: "anthropic"),
        RawCatalogRecord(harness: "claude-code", rawID: "sonnet", displayName: "Sonnet", providerHint: "anthropic"),
        RawCatalogRecord(harness: "claude-code", rawID: "haiku", displayName: "Haiku", providerHint: "anthropic"),
        RawCatalogRecord(harness: "claude-code", rawID: "fable", displayName: "Fable", providerHint: "anthropic"),
    ]

    /// Astra: a dimmed, non-selectable "coming soon" row the operator asked
    /// for. It is absent from `models_cache.json` and from every live catalog,
    /// so **the id is unconfirmed** — it follows the family's convention and is
    /// a guess. That is safe only because the row cannot be selected; if Astra
    /// ships, replace this with whatever slug the cache then carries.
    static let codexComingSoon: [RawCatalogRecord] = [
        RawCatalogRecord(
            harness: "codex",
            rawID: "gpt-5.6-astra",
            displayName: "GPT-5.6 Astra",
            isComingSoon: true,
            providerHint: "openai"
        ),
    ]

    /// Last resort for codex, used only when `models_cache.json` is unreadable
    /// *and* neither the disk cache nor the compiled snapshot has any codex
    /// rows — a fresh machine whose codex has never talked to the service. It
    /// is deliberately just the current frontier slugs: a fallback should offer
    /// what the operator would actually launch, not a museum.
    static let codexFallback: [RawCatalogRecord] = [
        RawCatalogRecord(harness: "codex", rawID: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", providerHint: "openai"),
        RawCatalogRecord(harness: "codex", rawID: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", providerHint: "openai"),
        RawCatalogRecord(harness: "codex", rawID: "gpt-5.6-luna", displayName: "GPT-5.6-Luna", providerHint: "openai"),
    ]

    static var all: [RawCatalogRecord] { claudeCode + codexComingSoon }
}

// MARK: - Command runner seam

/// Subprocess seam so the catalog can be enumerated in tests without spawning
/// anything. Implementations must be timeout-bounded and must return `nil` —
/// never throw, never block indefinitely — for a missing binary, a non-zero
/// exit, or a timeout.
protocol ModelCatalogCommandRunning {
    func run(tool: String, arguments: [String], timeout: TimeInterval) -> String?
}

/// Read seam for catalogs a harness caches on disk instead of printing
/// (codex). Read-only by construction: there is no write method.
protocol ModelCatalogFileReading {
    func contents(atPath path: String) -> String?
}

struct FileManagerCatalogReader: ModelCatalogFileReading {
    func contents(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}

/// Production runner.
///
/// Harness CLIs live wherever the operator installed them (`~/.bun/bin`,
/// `~/.kimi-code/bin`, Homebrew, c11's own bundled `Resources/bin`), and a GUI
/// app's `PATH` contains almost none of those. So the tool is resolved once
/// through the operator's login shell (`$SHELL -lc 'command -v <tool>'`) and
/// then executed directly by absolute path, which keeps any shell-profile
/// chatter out of the parsed output.
final class ProcessModelCatalogCommandRunner: ModelCatalogCommandRunning, @unchecked Sendable {
    private let shell: String
    private let lock = NSLock()
    private var resolved: [String: String?] = [:]

    init(shell: String? = nil) {
        self.shell = shell
            ?? ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 }
            ?? "/bin/zsh"
    }

    func run(tool: String, arguments: [String], timeout: TimeInterval) -> String? {
        guard let path = resolve(tool: tool, timeout: min(timeout, 10)) else { return nil }
        return Self.capture(executable: path, arguments: arguments, timeout: timeout)
    }

    /// Absolute path for `tool`, memoized for the process lifetime (including
    /// the negative result: a machine without `grok` should not pay a login
    /// shell on every refresh).
    private func resolve(tool: String, timeout: TimeInterval) -> String? {
        lock.lock()
        if let cached = resolved[tool] { lock.unlock(); return cached }
        lock.unlock()

        let output = Self.capture(
            executable: shell,
            arguments: ["-lc", "command -v \(tool) 2>/dev/null"],
            timeout: timeout
        )
        // A login shell may print profile output first; the path is the last
        // line that looks like one.
        let path = output?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }

        lock.lock()
        resolved[tool] = path
        lock.unlock()
        return path
    }

    /// Run to completion under a soft timeout, draining stdout concurrently so
    /// a catalog larger than the pipe buffer (omp prints ~80 KB) cannot
    /// deadlock the child against its own output.
    static func capture(executable: String, arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do { try process.run() } catch { return nil }
        stdin.fileHandleForWriting.closeFile()

        let drained = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        // stderr is drained and discarded for the same reason.
        DispatchQueue.global(qos: .utility).async {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
        }

        let deadline = DispatchTime.now() + timeout
        if finished.wait(timeout: deadline) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.5)
            }
            _ = drained.wait(timeout: .now() + 0.5)
            return nil
        }
        guard drained.wait(timeout: .now() + 2.0) != .timedOut else { return nil }
        guard process.terminationStatus == 0 else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.isEmpty ? nil : text
    }
}

// MARK: - Enumeration

/// Runs each harness's catalog command and parses the result. Per-harness and
/// non-fatal by construction: a missing binary, an unauthenticated CLI, or a
/// slow call yields `nil` for that harness only, and the caller keeps whatever
/// it already had for it.
struct ModelCatalogEnumerator {

    struct Command {
        let harness: String
        let tool: String
        let arguments: [String]
        let parse: (String) -> [RawCatalogRecord]
    }

    static let commands: [Command] = [
        Command(harness: "opencode", tool: "opencode", arguments: ["models"], parse: OpencodeModelsParser.parse),
        Command(harness: "pi", tool: "pi", arguments: ["--list-models"], parse: PiModelsParser.parse),
        Command(harness: "omp", tool: "omp", arguments: ["models"], parse: OmpModelsParser.parse),
        Command(harness: "kimi", tool: "kimi", arguments: ["provider", "list", "--json"], parse: KimiProviderListParser.parse),
        Command(harness: "grok", tool: "grok", arguments: ["models"], parse: GrokModelsParser.parse),
    ]

    /// Catalogs a harness caches on disk rather than printing.
    struct FileSource {
        let harness: String
        let path: String
        let parse: (String) -> [RawCatalogRecord]
    }

    static var fileSources: [FileSource] {
        [FileSource(harness: "codex", path: CodexModelsCacheParser.defaultPath, parse: CodexModelsCacheParser.parse)]
    }

    let runner: ModelCatalogCommandRunning
    let reader: ModelCatalogFileReading
    /// Per-command budget. Generous because these CLIs cold-start a JS runtime;
    /// still bounded, and never on a UI path.
    let timeout: TimeInterval

    init(
        runner: ModelCatalogCommandRunning,
        reader: ModelCatalogFileReading = FileManagerCatalogReader(),
        timeout: TimeInterval = 20
    ) {
        self.runner = runner
        self.reader = reader
        self.timeout = timeout
    }

    /// Records for one harness, or `nil` when the harness could not be
    /// enumerated (binary missing, timeout, unparseable output).
    func enumerate(_ command: Command) -> [RawCatalogRecord]? {
        guard let output = runner.run(tool: command.tool, arguments: command.arguments, timeout: timeout) else {
            return nil
        }
        let records = command.parse(output)
        return records.isEmpty ? nil : records
    }

    /// Records for one file-backed harness, or `nil` when the file is missing
    /// or unparseable.
    func enumerate(_ source: FileSource) -> [RawCatalogRecord]? {
        guard let text = reader.contents(atPath: source.path) else { return nil }
        let records = source.parse(text)
        return records.isEmpty ? nil : records
    }

    /// Every enumerable harness, keyed by harness. Missing keys are failures.
    func enumerateAll() -> [String: [RawCatalogRecord]] {
        var out: [String: [RawCatalogRecord]] = [:]
        for command in Self.commands {
            if let records = enumerate(command) { out[command.harness] = records }
        }
        for source in Self.fileSources {
            if let records = enumerate(source) { out[source.harness] = records }
        }
        return out
    }

    /// Merge freshly enumerated harnesses over a previous record set, keeping
    /// the previous rows for any harness that failed this pass, and re-adding
    /// the declared rows. This is the degradation rule: a refresh can only
    /// improve the catalog, never shrink it because a CLI was slow once.
    ///
    /// The codex fallback is the one exception to "declared rows are always
    /// added": it applies only when no codex rows survive from either side, so
    /// a machine whose codex has never cached a catalog still offers something,
    /// while every machine that has one uses the real list.
    static func merged(
        live: [String: [RawCatalogRecord]],
        previous: [RawCatalogRecord]
    ) -> [RawCatalogRecord] {
        var byHarness: [String: [RawCatalogRecord]] = [:]
        for record in previous where !isDeclared(record) {
            byHarness[record.harness, default: []].append(record)
        }
        for (harness, records) in live { byHarness[harness] = records }
        if (byHarness["codex"] ?? []).isEmpty {
            byHarness["codex"] = ModelCatalogDeclarations.codexFallback
        }
        // Stable order so the cache and the committed snapshot are diffable.
        let enumerated = byHarness.keys.sorted().flatMap {
            (byHarness[$0] ?? []).sorted { $0.rawID < $1.rawID }
        }
        return ModelCatalogDeclarations.all + enumerated
    }

    /// A row that comes from `ModelCatalogDeclarations.all` rather than from a
    /// publisher, and so is re-added on every merge instead of carried over.
    static func isDeclared(_ record: RawCatalogRecord) -> Bool {
        record.harness == "claude-code" || record.isComingSoon
    }
}
