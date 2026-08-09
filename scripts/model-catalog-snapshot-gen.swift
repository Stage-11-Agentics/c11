import Foundation

// Snapshot generator for the model catalog (C11-203 Part D).
//
// Compiled together with `Sources/ModelCatalog.swift` and
// `Sources/ModelCatalogSources.swift` by
// `scripts/generate-model-catalog-snapshot.sh`, so the offline snapshot is
// produced by the *same* parsers the app runs. There is no second
// implementation to drift.
//
//   usage: model-catalog-snapshot-gen <capture-dir>
//
// `<capture-dir>` holds raw CLI output under the same names the committed
// fixtures use, so the snapshot can be regenerated from live CLIs or replayed
// from `c11Tests/Fixtures/model-catalog/`.

@main
struct ModelCatalogSnapshotGen {

    static let captures: [(harness: String, file: String, parse: (String) -> [RawCatalogRecord])] = [
        ("opencode", "opencode-models.txt", OpencodeModelsParser.parse),
        ("pi", "pi-list-models.txt", PiModelsParser.parse),
        ("omp", "omp-models.txt", OmpModelsParser.parse),
        ("kimi", "kimi-provider-list.json", KimiProviderListParser.parse),
        ("grok", "grok-models.txt", GrokModelsParser.parse),
    ]

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: model-catalog-snapshot-gen <capture-dir>\n".utf8))
            exit(2)
        }
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)

        var live: [String: [RawCatalogRecord]] = [:]
        for capture in captures {
            let url = dir.appendingPathComponent(capture.file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                warn("no capture for \(capture.harness) at \(url.path) — skipping")
                continue
            }
            let records = capture.parse(text)
            guard !records.isEmpty else {
                warn("\(capture.harness): capture parsed to zero records — skipping")
                continue
            }
            live[capture.harness] = records
            warn("\(capture.harness): \(records.count) records")
        }
        guard !live.isEmpty else {
            warn("no harness produced records; refusing to write an empty snapshot")
            exit(1)
        }

        let records = ModelCatalogEnumerator.merged(live: live, previous: [])
        let index = ModelCatalogBuilder.build(records: records, source: .snapshot)
        let stamp = ISO8601DateFormatter().string(from: Date())

        var summary: [String] = []
        for provider in index.providers {
            summary.append("//   \(provider): \(index.models(forProvider: provider).count)")
        }
        warn("merged \(records.count) records into \(index.allModels.count) models across \(index.providers.count) providers")

        print("""
        import Foundation

        // GENERATED FILE — do not edit by hand.
        //
        // Regenerate with:
        //     scripts/generate-model-catalog-snapshot.sh                       # live CLIs
        //     scripts/generate-model-catalog-snapshot.sh --from c11Tests/Fixtures/model-catalog
        //
        // The offline tier of the model catalog (C11-203 Part D): the rows the
        // harness CLIs published when this file was generated, in the same raw
        // form live enumeration produces, so the merge has one code path.
        //
        // \(records.count) raw records → \(index.allModels.count) models across \(index.providers.count) providers:
        \(summary.joined(separator: "\n"))

        enum ModelCatalogSnapshot {
            /// When the capture behind this snapshot was taken.
            static let generatedAtISO8601 = "\(stamp)"
            static let generatedAt: Date? = ISO8601DateFormatter().date(from: generatedAtISO8601)

            /// Raw rows, decoded once.
            static let records: [RawCatalogRecord] = ModelCatalogRecordCodec.decode(tsv)

            /// harness, rawID, displayName, context, efforts, flags, providerHint.
            static let tsv = #\"\"\"
        \(ModelCatalogRecordCodec.encode(records))
        \"\"\"#
        }
        """)
    }

    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("model-catalog-snapshot-gen: \(message)\n".utf8))
    }
}
