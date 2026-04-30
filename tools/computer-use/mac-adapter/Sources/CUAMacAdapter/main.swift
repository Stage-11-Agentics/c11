import AppKit
import Foundation

struct Envelope<T: Codable>: Codable {
    let ok: Bool
    let value: T?
    let error: String?
}

struct DoctorReport: Codable {
    let ok: Bool
    let macOSVersion: String
    let permissions: PermissionStatus
    let targetBundleID: String
    let targetAppPath: String?
    let targetAppExists: Bool?
    let running: Bool
    let frontmostBundleID: String?
    let visibleWindow: WindowInfo?
    let windows: [WindowInfo]
}

struct LaunchReport: Codable {
    let ok: Bool
    let window: WindowInfo
}

let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

func printJSON<T: Encodable>(_ value: T) {
    do {
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fputs("{\"ok\":false,\"error\":\"failed to encode JSON\"}\n", stderr)
        exit(2)
    }
}

func fail(_ error: Error, code: Int32 = 1) -> Never {
    printJSON(Envelope<String>(ok: false, value: nil, error: String(describing: error)))
    exit(code)
}

func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func has(_ flag: String, in args: [String]) -> Bool {
    args.contains(flag)
}

func targetOptions(args: [String]) -> TargetOptions {
    let bundle = value(after: "--bundle-id", in: args) ?? "com.stage11.c11.debug.openai.cua"
    let appPath = value(after: "--app-path", in: args)
    return TargetOptions(bundleID: bundle, appPath: appPath)
}

func readAction(args: [String]) throws -> ComputerAction {
    let data: Data
    if let raw = value(after: "--json", in: args) {
        data = Data(raw.utf8)
    } else if let file = value(after: "--json-file", in: args) {
        data = try Data(contentsOf: URL(fileURLWithPath: NSString(string: file).expandingTildeInPath))
    } else {
        data = FileHandle.standardInput.readDataToEndOfFile()
    }
    return try JSONDecoder().decode(ComputerAction.self, from: data)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, ["doctor", "window-list", "launch", "observe", "act", "quit", "help", "--help", "-h"].contains(command) else {
    print("""
    Usage: cua-mac-adapter <command> [options]

    Commands:
      doctor       Report permissions, target app/window, and display state as JSON.
      window-list  List visible windows as JSON.
      launch       Launch or activate the target app.
      observe      Capture the target window screenshot.
      act          Execute one computer action from --json, --json-file, or stdin.
      quit         No-op placeholder for JSON command parity.

    Options:
      --bundle-id <id>       Target bundle id. Default: com.stage11.c11.debug.openai.cua
      --app-path <path>      Tagged app path for launch fallback.
      --out <path>           Screenshot PNG output path for observe/act.
      --include-base64       Include screenshot base64 in observe output.
      --wait <seconds>       Launch wait. Default: 10.
    """)
    exit(args.first == nil ? 1 : 0)
}

let target = WindowTarget(options: targetOptions(args: args))

do {
    switch command {
    case "doctor":
        let path = target.options.appPath.map { NSString(string: $0).expandingTildeInPath }
        let appExists = path.map { FileManager.default.fileExists(atPath: $0) }
        let visibleWindow = try? target.bestVisibleWindow()
        let windows = target.windows()
        let report = DoctorReport(
            ok: PermissionStatus.current().screenRecording && PermissionStatus.current().accessibility,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            permissions: PermissionStatus.current(),
            targetBundleID: target.options.bundleID,
            targetAppPath: path,
            targetAppExists: appExists,
            running: NSRunningApplication.runningApplications(withBundleIdentifier: target.options.bundleID).isEmpty == false,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            visibleWindow: visibleWindow,
            windows: windows.filter { $0.bundleID == target.options.bundleID }
        )
        printJSON(report)
    case "window-list":
        printJSON(Envelope(ok: true, value: target.windows(), error: nil))
    case "launch":
        let wait = Double(value(after: "--wait", in: args) ?? "10") ?? 10
        let window = try target.launchOrActivate(waitSeconds: wait)
        printJSON(LaunchReport(ok: true, window: window))
    case "observe":
        let window = has("--no-frontmost-required", in: args) ? try target.bestVisibleWindow() : try target.requireFrontmostTarget()
        let observation = try ScreenshotCapture.observe(window: window, outPath: value(after: "--out", in: args), includeBase64: has("--include-base64", in: args))
        printJSON(observation)
    case "act":
        guard PermissionStatus.current().accessibility else {
            throw InputEventError.unsupportedAction("missing Accessibility permission; grant it in System Settings > Privacy & Security > Accessibility")
        }
        let action = try readAction(args: args)
        let window = try target.requireFrontmostTarget()
        let observation = try ScreenshotCapture.observe(window: window, outPath: nil, includeBase64: false)
        let result = try InputEvents.perform(action, observation: observation)
        printJSON(result)
    case "quit":
        printJSON(Envelope(ok: true, value: "quit", error: nil))
    default:
        print("unknown command \(command)")
        exit(1)
    }
} catch {
    fail(error)
}
