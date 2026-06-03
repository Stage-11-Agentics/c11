import Foundation

// Thin CLI entry for `c11 doctor`. Wired from CLI/c11.swift.
// All collection/rendering lives in Sources/CLIResolutionSnapshot.swift so
// the main `c11` target (and c11Tests) can exercise the same code paths.

func runDoctor(commandArgs: [String], jsonOutput: Bool) throws {
    let opts: DoctorCLIOptions
    do {
        opts = try parseDoctorCLIArgs(commandArgs)
    } catch let error as DoctorCLIError {
        throw CLIError(message: "c11 doctor: \(error.description)")
    }

    let wantsJSON = jsonOutput || opts.json

    let env = ProcessInfo.processInfo.environment
    let inputs = CLIResolutionInputs(
        environment: env,
        commandLookup: { name in defaultCommandLookup(name, environment: env) },
        executableExists: { path in FileManager.default.isExecutableFile(atPath: path) },
        versionLookup: { path in defaultVersionLookup(path) }
    )
    let snapshot = CLIResolutionSnapshot.collect(inputs: inputs)

    if wantsJSON {
        let dict = snapshot.toJSONDictionary()
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys, .prettyPrinted]
        )
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }

    print(snapshot.renderText(), terminator: "")
}
