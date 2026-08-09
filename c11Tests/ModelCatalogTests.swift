import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

// MARK: - Model catalog (C11-203 Part D)
//
// The parser cases run against output captured from the live CLIs and
// committed under `Fixtures/model-catalog/`. That is the point: when a harness
// changes its output format, these fail loudly instead of the picker quietly
// emptying out. Regenerate the fixtures and the snapshot together with
// `scripts/generate-model-catalog-snapshot.sh`.

final class ModelCatalogTests: XCTestCase {

    // MARK: Fixtures

    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("model-catalog", isDirectory: true)
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: fixturesURL.appendingPathComponent(name), encoding: .utf8)
    }

    /// The full catalog as built from the committed captures.
    private func fixtureIndex() throws -> ModelCatalogIndex {
        let live: [String: [RawCatalogRecord]] = [
            "opencode": OpencodeModelsParser.parse(try fixture("opencode-models.txt")),
            "pi": PiModelsParser.parse(try fixture("pi-list-models.txt")),
            "omp": OmpModelsParser.parse(try fixture("omp-models.txt")),
            "kimi": KimiProviderListParser.parse(try fixture("kimi-provider-list.json")),
            "grok": GrokModelsParser.parse(try fixture("grok-models.txt")),
        ]
        return ModelCatalogBuilder.build(
            records: ModelCatalogEnumerator.merged(live: live, previous: []),
            source: .snapshot
        )
    }

    // MARK: - Parsers against captured real output

    func testOpencodeParserReadsEveryLineOfRealOutput() throws {
        let text = try fixture("opencode-models.txt")
        let expected = text.split(separator: "\n").filter { $0.contains("/") }.count
        let records = OpencodeModelsParser.parse(text)
        XCTAssertEqual(records.count, expected)
        XCTAssertTrue(records.allSatisfy { $0.harness == "opencode" })
        XCTAssertTrue(records.contains { $0.rawID == "openai/gpt-5.6-sol" })
        XCTAssertTrue(records.contains { $0.rawID == "openrouter/~anthropic/claude-opus-latest" })
    }

    func testOpencodeParserIgnoresBannerLines() {
        let records = OpencodeModelsParser.parse("""
        Updating opencode...
        openai/gpt-5.6-sol
        google/gemini-3-pro

        """)
        XCTAssertEqual(records.map(\.rawID), ["openai/gpt-5.6-sol", "google/gemini-3-pro"])
    }

    func testPiParserSkipsHeaderAndKeepsProviderPrefix() throws {
        let records = PiModelsParser.parse(try fixture("pi-list-models.txt"))
        XCTAssertFalse(records.contains { $0.rawID.hasPrefix("provider/") })
        XCTAssertTrue(records.allSatisfy { $0.harness == "pi" })
        let k3 = try XCTUnwrap(records.first { $0.rawID == "kimi/k3" })
        XCTAssertEqual(k3.providerHint, "kimi")
        // pi prints an abbreviated size; the parser keeps it as a magnitude.
        XCTAssertEqual(k3.contextWindow, 1_000_000)
        XCTAssertTrue(records.contains { $0.rawID == "openrouter/~anthropic/claude-fable-latest" })
    }

    func testPiParserRejectsProseLines() {
        let records = PiModelsParser.parse("""
        provider    model         context  max-out  thinking  images
        You are not authenticated with this provider yet
        google      gemini-3-pro  1.0M     65.5K    yes       yes
        """)
        XCTAssertEqual(records.map(\.rawID), ["google/gemini-3-pro"])
    }

    func testOmpParserReadsSectionProviderAndThinkingLevels() throws {
        let records = OmpModelsParser.parse(try fixture("omp-models.txt"))
        XCTAssertTrue(records.allSatisfy { $0.harness == "omp" })
        XCTAssertFalse(records.contains { $0.rawID.hasSuffix("/model") })

        // Section header supplies the provider for unprefixed cells.
        let k3 = try XCTUnwrap(records.first { $0.rawID == "kimi/k3" })
        XCTAssertEqual(k3.efforts, .values(["minimal", "low", "medium", "high", "xhigh"]))
        XCTAssertEqual(k3.contextWindow, 1_000_000)

        // OpenRouter section cells carry their own provider prefix.
        XCTAssertTrue(records.contains { $0.rawID == "openrouter/z-ai/glm-5.2" })

        // A `-` thinking cell is an explicit "no levels", not silence.
        let sol = try XCTUnwrap(records.first { $0.rawID == "openai/gpt-5.6-sol" })
        XCTAssertEqual(sol.efforts, .none)
        XCTAssertNil(sol.contextWindow)
    }

    func testKimiParserReadsPerModelEffortDeclarations() throws {
        let records = KimiProviderListParser.parse(try fixture("kimi-provider-list.json"))
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(Set(records.map(\.rawID)), ["k3", "k3-256k", "kimi-for-coding", "kimi-for-coding-highspeed"])

        let k3 = try XCTUnwrap(records.first { $0.rawID == "k3" })
        XCTAssertEqual(k3.displayName, "K3")
        XCTAssertEqual(k3.contextWindow, 1_048_576)
        XCTAssertEqual(k3.efforts, .values(["low", "high", "max"]))

        // The two K2.7 aliases are `always_thinking` and publish no
        // supportEfforts: an explicit "no effort control", not "unknown".
        let k27 = try XCTUnwrap(records.first { $0.rawID == "kimi-for-coding" })
        XCTAssertEqual(k27.displayName, "K2.7 Coding")
        XCTAssertEqual(k27.contextWindow, 262_144)
        XCTAssertEqual(k27.efforts, .none)
    }

    func testKimiParserToleratesLeadingShellNoise() throws {
        let noisy = "nvm: using node 22\n" + (try fixture("kimi-provider-list.json"))
        XCTAssertEqual(KimiProviderListParser.parse(noisy).count, 4)
    }

    func testGrokParserReadsBulletList() throws {
        let records = GrokModelsParser.parse(try fixture("grok-models.txt"))
        XCTAssertEqual(records.map(\.rawID), ["grok-4.5"])
        XCTAssertEqual(records.first?.providerHint, "xai")
    }

    func testGrokParserSurvivesUnauthenticatedBannerAndMissingList() {
        let unauthenticated = GrokModelsParser.parse("""
        You are not authenticated. Run `grok login`.

        Default model: grok-4.5

        Available models:
          * grok-4.5 (default)
        """)
        XCTAssertEqual(unauthenticated.map(\.rawID), ["grok-4.5"])

        let listOnlyMissing = GrokModelsParser.parse("Default model: grok-4.5\n")
        XCTAssertEqual(listOnlyMissing.map(\.rawID), ["grok-4.5"])

        XCTAssertTrue(GrokModelsParser.parse("command not found: grok").isEmpty)
    }

    // MARK: - Provider canonicalization and id splitting

    func testProviderCanonicalizationFoldsVendorSpellings() {
        XCTAssertEqual(ModelCatalogProviders.canonical("x-ai"), "xai")
        XCTAssertEqual(ModelCatalogProviders.canonical("moonshotai"), "moonshot")
        XCTAssertEqual(ModelCatalogProviders.canonical("kimi"), "moonshot")
        XCTAssertEqual(ModelCatalogProviders.canonical("~anthropic"), "anthropic")
        XCTAssertEqual(ModelCatalogProviders.canonical("Z-AI"), "zai")
        XCTAssertEqual(ModelCatalogProviders.canonical("meta-llama"), "meta")
        // An unknown vendor keeps its own key rather than being swept into
        // "other": a new provider must still be selectable.
        XCTAssertEqual(ModelCatalogProviders.canonical("perceptron"), "perceptron")
    }

    func testOpenRouterThreeSegmentIdsFlattenToTheRealProvider() {
        XCTAssertEqual(
            ModelCatalogIdentity.split(rawID: "openrouter/anthropic/claude-fable-5", providerHint: "openrouter").provider,
            "anthropic"
        )
        XCTAssertEqual(
            ModelCatalogIdentity.split(rawID: "openrouter/~anthropic/claude-opus-latest", providerHint: "").id,
            "claude-opus-latest"
        )
        // Two segments means OpenRouter really is the vendor.
        let auto = ModelCatalogIdentity.split(rawID: "openrouter/auto", providerHint: "")
        XCTAssertEqual(auto.provider, "openrouter")
        XCTAssertEqual(auto.id, "auto")
        // An unnamespaced id takes the hint.
        let k3 = ModelCatalogIdentity.split(rawID: "k3", providerHint: "moonshot")
        XCTAssertEqual(k3.provider, "moonshot")
        XCTAssertEqual(k3.id, "k3")
    }

    func testProviderDisplayOrderLeadsWithThePartCProviders() throws {
        let providers = try fixtureIndex().providers
        XCTAssertEqual(Array(providers.prefix(5)), ["openai", "anthropic", "google", "moonshot", "xai"])
        // Everything past the lead block is alphabetical, so a new provider
        // lands somewhere deterministic.
        let tail = Array(providers.drop(while: { ModelCatalogProviders.leadingOrder.contains($0) }))
        XCTAssertEqual(tail, tail.sorted())
    }

    // MARK: - Dedup across harnesses

    func testTheSameModelSeenByFourHarnessesCollapsesToOneRow() throws {
        let index = try fixtureIndex()
        let openai = index.models(forProvider: "openai")
        XCTAssertEqual(openai.count, Set(openai.map(\.id)).count, "openai has duplicate ids")

        let sol = try XCTUnwrap(index.model(provider: "openai", id: "gpt-5.6-sol"))
        XCTAssertEqual(index.harnesses(forModel: sol), ["codex", "opencode", "pi", "omp"])
        // Each harness keeps its own model-flag spelling.
        XCTAssertEqual(index.modelFlagValue(for: sol, harness: "codex"), "gpt-5.6-sol")
        XCTAssertEqual(index.modelFlagValue(for: sol, harness: "opencode"), "openai/gpt-5.6-sol")
        XCTAssertEqual(index.modelFlagValue(for: sol, harness: "pi"), "openai/gpt-5.6-sol")
    }

    func testDirectRouteBeatsGatewayRouteForTheSameHarness() throws {
        let index = try fixtureIndex()
        // opencode lists both `openai/gpt-5.6-sol` and
        // `openrouter/openai/gpt-5.6-sol`; the direct one is the flag value.
        let sol = try XCTUnwrap(index.model(provider: "openai", id: "gpt-5.6-sol"))
        XCTAssertEqual(index.modelFlagValue(for: sol, harness: "opencode"), "openai/gpt-5.6-sol")
        // …and the vendor's own context number wins over OpenRouter's larger claim.
        XCTAssertEqual(sol.contextWindow, 272_000)
    }

    func testGatewayRouteDetection() {
        XCTAssertTrue(ModelCatalogBuilder.isGatewayRoute("openrouter/openai/gpt-5.6-sol"))
        XCTAssertTrue(ModelCatalogBuilder.isGatewayRoute("openrouter/~google/gemini-pro-latest"))
        XCTAssertFalse(ModelCatalogBuilder.isGatewayRoute("openrouter/auto"))
        XCTAssertFalse(ModelCatalogBuilder.isGatewayRoute("openai/gpt-5.6-sol"))
    }

    // MARK: - Harness ordering (ticket Part C)

    func testPartCDefaultHarnessPerProvider() {
        XCTAssertEqual(ModelCatalogHarnesses.partCDefault(forProvider: "openai"), "codex")
        XCTAssertEqual(ModelCatalogHarnesses.partCDefault(forProvider: "anthropic"), "claude-code")
        XCTAssertEqual(ModelCatalogHarnesses.partCDefault(forProvider: "moonshot"), "kimi")
        XCTAssertEqual(ModelCatalogHarnesses.partCDefault(forProvider: "xai"), "grok")
        XCTAssertEqual(ModelCatalogHarnesses.partCDefault(forProvider: "google"), "pi")
        XCTAssertEqual(ModelCatalogHarnesses.partCDefault(forProvider: "deepseek"), "pi")
    }

    func testHarnessListPutsThePartCDefaultOnTop() {
        XCTAssertEqual(
            ModelCatalogBuilder.orderedHarnesses(evidence: ["opencode", "pi", "kimi", "omp"], provider: "moonshot"),
            ["kimi", "opencode", "pi", "omp"]
        )
        XCTAssertEqual(
            ModelCatalogBuilder.orderedHarnesses(evidence: ["opencode", "pi", "omp"], provider: "google"),
            ["pi", "opencode", "omp"]
        )
    }

    func testHarnessListFallsToTheFirstAvailableWhenTheDefaultCannotServeTheModel() {
        // An OpenRouter-only Anthropic model: claude-code cannot take that id,
        // so it must not be offered, and the cross-product harnesses are.
        XCTAssertEqual(
            ModelCatalogBuilder.orderedHarnesses(evidence: ["opencode", "pi", "omp"], provider: "anthropic"),
            ["opencode", "pi", "omp"]
        )
    }

    func testClaudeFamiliesResolveToExactlyOneHarness() throws {
        let index = try fixtureIndex()
        for family in ["opus", "sonnet", "haiku", "fable"] {
            let model = try XCTUnwrap(index.model(provider: "anthropic", id: family))
            XCTAssertEqual(index.harnesses(forModel: model), ["claude-code"], family)
            XCTAssertEqual(model.harness, "claude-code", family)
        }
    }

    func testMoonshotModelsTopLineIsKimiAndGoogleModelsTopLineIsPi() throws {
        let index = try fixtureIndex()
        let k3 = try XCTUnwrap(index.model(provider: "moonshot", id: "k3"))
        XCTAssertEqual(k3.harness, "kimi")
        let gemini = try XCTUnwrap(index.model(provider: "google", id: "gemini-3-pro-preview"))
        XCTAssertEqual(gemini.harness, "pi")
        let grok = try XCTUnwrap(index.model(provider: "xai", id: "grok-4.5"))
        XCTAssertEqual(grok.harness, "grok")
    }

    // MARK: - Effort declarations are per (model, harness)

    func testKimiEffortsSurviveTheMergeAgainstOmpsCompetingClaim() throws {
        let index = try fixtureIndex()

        let k3 = try XCTUnwrap(index.model(provider: "moonshot", id: "k3"))
        XCTAssertEqual(k3.supportedEfforts, ["low", "high", "max"])
        XCTAssertEqual(index.effortSupport(for: k3, harness: "kimi"), .values(["low", "high", "max"]))

        // omp publishes its own `--thinking` levels for the same model. Both are
        // true for their own harness; the top-line value must be kimi's.
        XCTAssertEqual(
            index.effortSupport(for: k3, harness: "omp"),
            .values(["minimal", "low", "medium", "high", "xhigh"])
        )

        for legacy in ["kimi-for-coding", "kimi-for-coding-highspeed"] {
            let model = try XCTUnwrap(index.model(provider: "moonshot", id: legacy))
            XCTAssertEqual(model.supportedEfforts, [], legacy)
            XCTAssertEqual(index.effortSupport(for: model, harness: "kimi"), ModelEffortSupport.none, legacy)
        }
    }

    func testUnspecifiedEffortIsDistinctFromExplicitlyNone() throws {
        let index = try fixtureIndex()
        let sol = try XCTUnwrap(index.model(provider: "openai", id: "gpt-5.6-sol"))
        // codex publishes nothing per model: fall back to the manifest's values.
        XCTAssertEqual(index.effortSupport(for: sol, harness: "codex"), .unspecified)
        // omp publishes `-` for it: no levels on that route.
        XCTAssertEqual(index.effortSupport(for: sol, harness: "omp"), ModelEffortSupport.none)
        // A harness that never saw the model reports nothing rather than lying.
        XCTAssertEqual(index.effortSupport(for: sol, harness: "grok"), .unspecified)
        XCTAssertEqual(ModelEffortSupport.none.levels, [])
        XCTAssertEqual(ModelEffortSupport.unspecified.levels, [])
    }

    // MARK: - Declared catalogs

    func testCodexDeclaresNineGPT56VariantsPlusComingSoonAstra() throws {
        let index = try fixtureIndex()
        let expected = ["sol", "luna", "terra"].flatMap { v in
            ["", "-fast", "-pro"].map { "gpt-5.6-\(v)\($0)" }
        }
        for id in expected {
            let model = try XCTUnwrap(index.model(provider: "openai", id: id), id)
            XCTAssertFalse(model.isComingSoon, id)
            XCTAssertTrue(index.harnesses(forModel: model).contains("codex"), id)
        }
        let astra = try XCTUnwrap(index.model(provider: "openai", id: "gpt-5.6-astra"))
        XCTAssertTrue(astra.isComingSoon)
        XCTAssertEqual(index.allModels.filter(\.isComingSoon).map(\.id), ["gpt-5.6-astra"])
    }

    func testDeclaredHarnessesAreAlwaysPresentEvenWhenNothingEnumerates() {
        let records = ModelCatalogEnumerator.merged(live: [:], previous: [])
        XCTAssertEqual(Set(records.map(\.harness)), ["claude-code", "codex"])
        let index = ModelCatalogBuilder.build(records: records, source: .live)
        XCTAssertEqual(index.providers, ["openai", "anthropic"])
        XCTAssertNotNil(index.model(provider: "anthropic", id: "opus"))
    }

    // MARK: - Degradation

    func testARefreshThatLosesOneHarnessKeepsThatHarnessRows() {
        let previous: [RawCatalogRecord] = [
            RawCatalogRecord(harness: "grok", rawID: "grok-4.5", providerHint: "xai"),
            RawCatalogRecord(harness: "kimi", rawID: "k3", providerHint: "moonshot"),
        ]
        // grok timed out this pass; kimi answered.
        let merged = ModelCatalogEnumerator.merged(
            live: ["kimi": [RawCatalogRecord(harness: "kimi", rawID: "k3-256k", providerHint: "moonshot")]],
            previous: previous
        )
        XCTAssertTrue(merged.contains { $0.harness == "grok" && $0.rawID == "grok-4.5" })
        // The harness that did answer is replaced wholesale, not unioned, so a
        // model the vendor retired actually disappears.
        XCTAssertEqual(merged.filter { $0.harness == "kimi" }.map(\.rawID), ["k3-256k"])
    }

    func testEnumeratorTreatsMissingBinaryTimeoutAndGarbageAsNoData() {
        let runner = StubRunner(responses: [:])
        let enumerator = ModelCatalogEnumerator(runner: runner, timeout: 0.1)
        XCTAssertTrue(enumerator.enumerateAll().isEmpty)

        let garbage = StubRunner(responses: ModelCatalogEnumerator.commands.reduce(into: [:]) {
            $0[$1.tool] = "zsh: command not found\n"
        })
        XCTAssertTrue(ModelCatalogEnumerator(runner: garbage).enumerateAll().isEmpty)
    }

    func testStoreFallsBackToTheSnapshotWhenNoCLIAnswers() throws {
        let dir = try makeTempDirectory()
        let snapshot = [RawCatalogRecord(harness: "kimi", rawID: "k3", displayName: "K3", providerHint: "moonshot")]
        let store = ModelCatalogStore(
            directory: dir,
            runner: StubRunner(responses: [:]),
            snapshot: snapshot,
            snapshotGeneratedAt: nil,
            loadCacheAsynchronously: false
        )
        XCTAssertEqual(store.index.source, .snapshot)
        XCTAssertFalse(store.refreshSynchronously())
        XCTAssertEqual(store.models(forProvider: "moonshot").map(\.id), ["k3"])
    }

    func testStoreDegradesToTheSnapshotWhenTheCacheIsCorrupt() throws {
        let dir = try makeTempDirectory()
        try "\u{FFFD}not a catalog\n\n\n".write(
            to: dir.appendingPathComponent(ModelCatalogStore.fileName), atomically: true, encoding: .utf8
        )
        let store = ModelCatalogStore(
            directory: dir,
            runner: nil,
            snapshot: [RawCatalogRecord(harness: "grok", rawID: "grok-4.5", providerHint: "xai")],
            snapshotGeneratedAt: nil,
            loadCacheAsynchronously: false
        )
        XCTAssertEqual(store.index.source, .snapshot)
        XCTAssertNotNil(store.model(provider: "xai", id: "grok-4.5"))
    }

    // MARK: - Store: refresh, cache, search

    func testRefreshEnumeratesParsesCachesAndRebuilds() throws {
        let dir = try makeTempDirectory()
        let runner = StubRunner(responses: [
            "kimi": try fixture("kimi-provider-list.json"),
            "grok": try fixture("grok-models.txt"),
        ])
        let store = ModelCatalogStore(
            directory: dir, runner: runner, snapshot: [], snapshotGeneratedAt: nil,
            loadCacheAsynchronously: false
        )
        XCTAssertTrue(store.index.isEmpty)
        XCTAssertTrue(store.refreshSynchronously())
        XCTAssertEqual(store.index.source, .live)
        XCTAssertNotNil(store.index.generatedAt)
        XCTAssertEqual(store.models(forProvider: "moonshot").count, 4)
        XCTAssertNotNil(store.model(provider: "xai", id: "grok-4.5"))

        // A second store over the same directory picks the cache up.
        let cached = ModelCatalogStore(
            directory: dir, runner: nil, snapshot: [], snapshotGeneratedAt: nil,
            loadCacheAsynchronously: false
        )
        XCTAssertEqual(cached.index.source, .cache)
        XCTAssertEqual(cached.models(forProvider: "moonshot").count, 4)
        XCTAssertNotNil(cached.index.generatedAt)
    }

    func testNewerProvenanceWinsBetweenSnapshotAndCache() throws {
        let cacheURL = ModelCatalogStore.fileName
        let snapshot = ModelCatalogRecordCodec.decode("grok\tgrok-4.5\t\t\t-\t\txai")

        // A cache older than the shipped snapshot is ignored: an app update
        // must not be dragged back to whatever the machine last enumerated.
        let staleDir = try makeTempDirectory()
        try "# generated_at: 2020-01-01T00:00:00Z\nkimi\tk3\tK3\t\t-\t\tmoonshot\n"
            .write(to: staleDir.appendingPathComponent(cacheURL), atomically: true, encoding: .utf8)
        let withStaleCache = ModelCatalogStore(
            directory: staleDir, runner: nil, snapshot: snapshot,
            snapshotGeneratedAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"),
            loadCacheAsynchronously: false
        )
        XCTAssertEqual(withStaleCache.index.source, .snapshot)
        XCTAssertNil(withStaleCache.model(provider: "moonshot", id: "k3"))

        // A cache newer than the snapshot is adopted.
        let freshDir = try makeTempDirectory()
        try "# generated_at: 2026-06-01T00:00:00Z\nkimi\tk3\tK3\t\t-\t\tmoonshot\n"
            .write(to: freshDir.appendingPathComponent(cacheURL), atomically: true, encoding: .utf8)
        let withFreshCache = ModelCatalogStore(
            directory: freshDir, runner: nil, snapshot: snapshot,
            snapshotGeneratedAt: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"),
            loadCacheAsynchronously: false
        )
        XCTAssertEqual(withFreshCache.index.source, .cache)
        XCTAssertNotNil(withFreshCache.model(provider: "moonshot", id: "k3"))
    }

    func testRefreshCompletionRunsOnTheMainQueue() throws {
        let dir = try makeTempDirectory()
        let store = ModelCatalogStore(
            directory: dir,
            runner: StubRunner(responses: ["grok": try fixture("grok-models.txt")]),
            snapshot: [],
            snapshotGeneratedAt: nil,
            loadCacheAsynchronously: false
        )
        let done = expectation(description: "refresh completes")
        store.refresh {
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(store.model(provider: "xai", id: "grok-4.5"))
    }

    func testSearchPrefersPrefixMatches() throws {
        let dir = try makeTempDirectory()
        let store = ModelCatalogStore(
            directory: dir,
            runner: nil,
            snapshot: ModelCatalogRecordCodec.decode("""
            opencode\topenai/gpt-5.6-sol\t\t\t-\t\t
            opencode\topenai/my-gpt-clone\t\t\t-\t\t
            opencode\tgoogle/gemini-3-pro\t\t\t-\t\t
            """),
            snapshotGeneratedAt: nil,
            loadCacheAsynchronously: false
        )
        let hits = store.search("gpt")
        XCTAssertEqual(hits.first?.id, "gpt-5.6-sol")
        XCTAssertEqual(hits.map(\.id), ["gpt-5.6-sol", "my-gpt-clone"])
        XCTAssertEqual(store.search("gemini", provider: "openai"), [])
        XCTAssertEqual(store.search("gemini", provider: "google").map(\.id), ["gemini-3-pro"])
    }

    func testModelFlagValueFallsBackToTheBareIdForAnUnknownHarness() throws {
        let index = try fixtureIndex()
        let k3 = try XCTUnwrap(index.model(provider: "moonshot", id: "k3"))
        XCTAssertNil(index.modelFlagValue(for: k3, harness: "claude-code"))
        let store = ModelCatalogStore(
            directory: try makeTempDirectory(), runner: nil, snapshot: [],
            snapshotGeneratedAt: nil, loadCacheAsynchronously: false
        )
        XCTAssertEqual(store.modelFlagValue(for: k3, harness: "claude-code"), "k3")
    }

    // MARK: - Codec

    func testRecordCodecRoundTripsEveryFieldIncludingEffortDistinctions() {
        let records = [
            RawCatalogRecord(harness: "kimi", rawID: "k3", displayName: "K3",
                             contextWindow: 1_048_576, efforts: .values(["low", "high", "max"]),
                             providerHint: "moonshot"),
            RawCatalogRecord(harness: "kimi", rawID: "kimi-for-coding", displayName: "K2.7 Coding",
                             contextWindow: 262_144, efforts: .none, providerHint: "moonshot"),
            RawCatalogRecord(harness: "codex", rawID: "gpt-5.6-astra", displayName: "GPT-5.6 Astra",
                             efforts: .unspecified, isComingSoon: true, providerHint: "openai"),
        ]
        XCTAssertEqual(ModelCatalogRecordCodec.decode(ModelCatalogRecordCodec.encode(records)), records)
    }

    func testRecordCodecSkipsCommentsBlanksAndTruncatedRows() {
        let decoded = ModelCatalogRecordCodec.decode("""
        # generated_at: 2026-08-09T00:00:00Z

        grok\tgrok-4.5
        \tno-harness
        opencode
        """)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.rawID, "grok-4.5")
        XCTAssertEqual(decoded.first?.efforts, .unspecified)
    }

    func testCommittedSnapshotMatchesTheCommittedFixtures() throws {
        // The snapshot is generated from these captures by
        // `scripts/generate-model-catalog-snapshot.sh --from c11Tests/Fixtures/model-catalog`.
        // If it ever stops matching, the snapshot was hand-edited or the
        // fixtures were refreshed without regenerating it.
        let expected = ModelCatalogEnumerator.merged(
            live: [
                "opencode": OpencodeModelsParser.parse(try fixture("opencode-models.txt")),
                "pi": PiModelsParser.parse(try fixture("pi-list-models.txt")),
                "omp": OmpModelsParser.parse(try fixture("omp-models.txt")),
                "kimi": KimiProviderListParser.parse(try fixture("kimi-provider-list.json")),
                "grok": GrokModelsParser.parse(try fixture("grok-models.txt")),
            ],
            previous: []
        )
        XCTAssertEqual(ModelCatalogSnapshot.records, expected)
        XCTAssertNotNil(ModelCatalogSnapshot.generatedAt)
    }

    func testTokenCountParsesPublisherAbbreviations() {
        XCTAssertEqual(ModelCatalogParsing.tokenCount("1M"), 1_000_000)
        XCTAssertEqual(ModelCatalogParsing.tokenCount("1.0M"), 1_000_000)
        XCTAssertEqual(ModelCatalogParsing.tokenCount("262.1K"), 262_100)
        XCTAssertEqual(ModelCatalogParsing.tokenCount("8.2K"), 8_200)
        XCTAssertEqual(ModelCatalogParsing.tokenCount("131072"), 131_072)
        XCTAssertNil(ModelCatalogParsing.tokenCount("-"))
        XCTAssertNil(ModelCatalogParsing.tokenCount(""))
        XCTAssertNil(ModelCatalogParsing.tokenCount("yes"))
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11-model-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Deterministic stand-in for the harness CLIs, keyed by tool name. A tool
    /// with no entry behaves exactly like a missing binary or a timeout: `nil`.
    private struct StubRunner: ModelCatalogCommandRunning {
        let responses: [String: String]
        func run(tool: String, arguments: [String], timeout: TimeInterval) -> String? {
            responses[tool]
        }
    }
}
