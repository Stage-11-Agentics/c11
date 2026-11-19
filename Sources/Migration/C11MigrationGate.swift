import AppKit
import Foundation

/// The migration gate (C11H-266): this app started again with
/// `--c11-migration-gate`, before any of its state exists. One plain window,
/// never modal. Normal app state consumers never start in this process. Its
/// `reconcile` worker owns only the migration transaction while the UI runs.
///
/// - `reconcile`: run the migration under its lock, then reopen the normal app.
/// - `wait <pid>…`: c11h is still quitting. The window says so; once every pid  c11-2.0:legacy
///   has exited, c11 opens again by itself (no click) and the gate leaves.
/// - `error <message>`: the migration stopped. The window says what happened,
///   that c11h's own files are untouched, and how to go back.  c11-2.0:legacy
enum C11MigrationGate {
    static let legacyQuitBudget: TimeInterval = 300

    static func run(arguments: [String]) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate()
        app.delegate = delegate
        let mode = arguments.first ?? "error"
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 14)
        label.preferredMaxLayoutWidth = 460
        let goBack = String(localized: "migration.gate.goBack",
                            defaultValue: "c11h's own files are untouched. To go back, quit c11 and open c11h. Details are in ~/Library/Logs/c11/migration.log.")  // c11-2.0:legacy
        switch mode {
        case "reconcile":
            label.stringValue = String(localized: "migration.gate.moving",
                                       defaultValue: "c11 is preparing your workspaces. It opens by itself when they are ready. Your terminals keep running.")
            // Enqueue after the window is created; no migration work can block
            // its initial display or the main run loop that services defaults.
            DispatchQueue.main.async {
                runWorker({ try C11MigrationLaunch.reconcileInGate() }) { outcome in
                    do {
                        try outcome.get()
                        try relaunchAfterExit()
                        NSApp.terminate(nil)
                    } catch {
                        label.stringValue = String(localized: "migration.gate.stopped",
                                                   defaultValue: "c11 stopped before opening, so nothing it found is lost.")
                            + "\n\n" + String(describing: error) + "\n\n" + goBack
                    }
                }
            }
        case "wait":
            label.stringValue = String(localized: "migration.gate.waiting",
                                       defaultValue: "c11h is still quitting. Its terminals keep running. c11 opens by itself as soon as c11h has quit.")  // c11-2.0:legacy
            let pids = arguments.dropFirst().compactMap { pid_t($0) }
            Thread.detachNewThread {
                let deadline = Date().addingTimeInterval(legacyQuitBudget)
                var alive = pids
                while Date() < deadline, !alive.isEmpty {
                    autoreleasepool {
                        usleep(200_000)
                        alive = alive.filter { kill($0, 0) == 0 || errno == EPERM }
                    }
                }
                DispatchQueue.main.async {
                    if alive.isEmpty {
                        do {
                            try relaunchAfterExit()
                            NSApp.terminate(nil)
                        } catch {
                            label.stringValue = String(localized: "migration.gate.stopped",
                                                       defaultValue: "c11 stopped before opening, so nothing it found is lost.")
                                + "\n\n" + String(describing: error) + "\n\n" + goBack
                        }
                    } else {
                        label.stringValue = String(localized: "migration.gate.legacyStillRunning",
                                                   defaultValue: "c11h has not quit, so nothing has moved. Quit c11h, then open c11 again.")  // c11-2.0:legacy
                            + "\n\n" + goBack
                    }
                }
            }
        default:
            let message = arguments.dropFirst().first ?? ""
            label.stringValue = String(localized: "migration.gate.stopped",
                                       defaultValue: "c11 stopped before opening, so nothing it found is lost.")
                + (message.isEmpty ? "" : "\n\n" + message) + "\n\n" + goBack
        }
        let quit = NSButton(title: String(localized: "migration.gate.quit", defaultValue: "Quit"),
                            target: NSApp, action: #selector(NSApplication.terminate(_:)))
        let stack = NSStackView(views: [label, quit])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "c11"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) { app.run() }
        exit(0)
    }

    /// The only execution boundary used by the visible gate. Completion is on
    /// main, so UI updates and UserDefaults never wait on a blocked main thread.
    static func runWorker(_ operation: @escaping () throws -> Void,
                          completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try operation() }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    /// Opens c11 again once this gate process has exited, carrying the launch's
    /// c11 settings (QA launches set some), so the duplicate-instance check never
    /// sees the gate.
    private static func relaunchAfterExit() throws {
        let bundle = Bundle.main.bundleURL.path
        var openArgs = ["-n"]
        for (key, value) in ProcessInfo.processInfo.environment
        where key.hasPrefix("C11_") || key.hasPrefix("CMUX_") {
            openArgs += ["--env", "\(key)=\(value)"]
        }
        openArgs.append(bundle)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; shift; exec /usr/bin/open \"$@\"",
                          "gate", String(getpid())] + openArgs
        try task.run()
    }

    private final class Delegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }
}
