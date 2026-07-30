import Foundation

// Thin CLI shim for the `c11 model-costs` family. All logic lives in
// `Sources/ModelCostCatalog.swift` (`ModelCostsCommandCore`, linked into both
// the app and this CLI target). Every subcommand operates directly on the
// state-root `model-costs.json` — app-down capable, no socket — and is
// dispatched from CLI/c11.swift before the socket connect, mirroring
// `c11 config` (C11-180).

func runModelCostsCommand(commandArgs: [String]) throws {
    guard let store = ModelCostCatalogStore.shared else {
        throw CLIError(message: "model-costs: c11 state directory is unavailable")
    }
    do {
        print(try ModelCostsCommandCore.run(args: commandArgs, store: store))
    } catch let failure as ModelCostsCommandCore.Failure {
        throw CLIError(message: failure.message)
    }
}
