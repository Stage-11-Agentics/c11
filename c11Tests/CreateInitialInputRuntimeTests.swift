import AppKit
import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Host-required real Ghostty proof. The standalone surface/window belongs only
/// to this fixture; HOME and startup scripts never reference operator rc files.
@MainActor
final class CreateInitialInputRuntimeTests: XCTestCase {
    func testSlowShellStartupConsumesInputOnceAndReconstructionDoesNotReplayIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c11-input-runtime-\(UUID().uuidString)")
        let receipt = root.appendingPathComponent("events.txt")
        let quotedReceipt = DefaultAgentResolver.shellQuote(receipt.path)
        try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let rc = """
            zmodload zsh/datetime
            printf 'rc-start:%.6f:%s\\n' "$EPOCHREALTIME" "$$" >> \(quotedReceipt)
            printf 'rc-start\\n'
            /bin/sleep 2.1
            printf 'rc-ready:%.6f:%s\\n' "$EPOCHREALTIME" "$$" >> \(quotedReceipt)
            printf 'rc-ready\\n'
            """
            try rc.write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        }.value
        defer { try? FileManager.default.removeItem(at: root) }

        let command = "printf 'initial:%s\\n' \"$$\" >> \(quotedReceipt); printf 'initial-done\\n'"
        // Set rc isolation in the shell launcher itself: c11 correctly protects
        // its integration ZDOTDIR from environment overrides.
        let quotedRoot = DefaultAgentResolver.shellQuote(root.path)
        let shellCommand = try XCTUnwrap(strdup("/usr/bin/env HOME=\(quotedRoot) ZDOTDIR=\(quotedRoot) /bin/zsh -i"))
        defer { free(shellCommand) }
        var template = ghostty_surface_config_new()
        template.command = UnsafePointer(shellCommand)
        let workspaceId = UUID()
        let panel = TerminalPanel(
            workspaceId: workspaceId, configTemplate: template,
            workingDirectory: root.path, initialInput: command + "\r",
            initialEnvironmentOverrides: ["HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/zsh"]
        )
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        defer {
            panel.close()
            panel.hostedView.removeFromSuperview()
            for window in [firstWindow, secondWindow] {
                window.orderOut(nil)
                window.close()
            }
        }
        mount(panel.hostedView, in: firstWindow)
        let terminalView = try XCTUnwrap(findTerminalView(in: panel.hostedView))
        panel.surface.attachToView(terminalView)
        _ = try XCTUnwrap(panel.surface.surface, "requires an unlocked Atlas GUI session and current Ghostty ABI header")

        let deadline = Date().addingTimeInterval(18)
        let firstEvents = try await waitForEvents(receipt, deadline: deadline) { $0.contains(where: { $0.hasPrefix("initial:") }) }
        XCTAssertEqual(firstEvents.map(eventName), ["rc-start", "rc-ready", "initial"], firstEvents.description)
        let rcStartedAt = try XCTUnwrap(firstEvents.first?.split(separator: ":").dropFirst().first.flatMap { Double($0) })
        let rcReadyAt = try XCTUnwrap(firstEvents.dropFirst().first?.split(separator: ":").dropFirst().first.flatMap { Double($0) })
        XCTAssertGreaterThanOrEqual(rcReadyAt - rcStartedAt, 2, "fixture must exercise a slow rc")
        let firstPID = try XCTUnwrap(firstEvents.last?.split(separator: ":").last.map(String.init))
        XCTAssertTrue(firstEvents.allSatisfy { $0.hasSuffix(":" + firstPID) }, "rc and initial input must share one shell")

        panel.surface.sendSubmitFormText("printf 'followup:%s\\n' \"$$\" >> \(quotedReceipt)")
        let followed = try await waitForEvents(receipt, deadline: deadline) { $0.contains("followup:" + firstPID) }
        XCTAssertEqual(followed.filter { eventName($0) == "initial" }.count, 1)

        // Real AppKit reparenting reuses the existing PTY. It must not replay
        // the creation input or lose the surviving interactive shell.
        let firstNativeSurface = panel.surface.surface
        panel.hostedView.removeFromSuperview()
        mount(panel.hostedView, in: secondWindow)
        panel.surface.attachToView(terminalView)
        XCTAssertEqual(panel.surface.surface, firstNativeSurface)
        panel.surface.sendSubmitFormText("printf 'reparent:%s\\n' \"$$\" >> \(quotedReceipt)")
        _ = try await waitForEvents(receipt, deadline: deadline) { $0.contains("reparent:" + firstPID) }

        // Closing seals the old surface permanently. Reconstruct the
        // standalone terminal with a fresh object and no consumed input;
        // reparenting above remains the proof that a live PTY is reused.
        panel.close()
        panel.hostedView.removeFromSuperview()
        XCTAssertNil(panel.surface.surface)
        let rebuiltPanel = TerminalPanel(
            workspaceId: workspaceId, configTemplate: template,
            workingDirectory: root.path, initialInput: nil,
            initialEnvironmentOverrides: ["HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/zsh"]
        )
        defer {
            rebuiltPanel.close()
            rebuiltPanel.hostedView.removeFromSuperview()
        }
        mount(rebuiltPanel.hostedView, in: secondWindow)
        let rebuiltView = try XCTUnwrap(findTerminalView(in: rebuiltPanel.hostedView))
        rebuiltPanel.surface.attachToView(rebuiltView)
        _ = try XCTUnwrap(rebuiltPanel.surface.surface, "native reconstruction must create another real PTY")
        let reconstructed = try await waitForEvents(receipt, deadline: deadline) {
            $0.filter { eventName($0) == "rc-ready" }.count == 2
        }
        XCTAssertEqual(reconstructed.filter { eventName($0) == "initial" }.count, 1,
                       "native reconstruction replayed the creation input")
        let secondPID = try XCTUnwrap(reconstructed.last?.split(separator: ":").last.map(String.init))
        XCTAssertNotEqual(secondPID, firstPID, "reconstruction must prove a genuinely new shell")
        rebuiltPanel.surface.sendSubmitFormText("printf 'reconstructed-followup:%s\\n' \"$$\" >> \(quotedReceipt)")
        let completed = try await waitForEvents(receipt, deadline: deadline) { $0.contains("reconstructed-followup:" + secondPID) }
        XCTAssertEqual(completed.filter { eventName($0) == "initial" }.count, 1)
        XCTAssertFalse(firstWindow.isVisible)
        XCTAssertFalse(secondWindow.isVisible)
        print("INITIAL_INPUT_RUNTIME slow-rc=2.1s initial-count=1 original-pid=\(firstPID) reconstructed-pid=\(secondPID) events=\(completed)")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        return window
    }

    private func mount(_ view: NSView, in window: NSWindow) {
        guard let content = window.contentView else { return XCTFail("missing fixture content view") }
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        content.layoutSubtreeIfNeeded()
    }

    private func findTerminalView(in view: NSView) -> GhosttyNSView? {
        if let terminal = view as? GhosttyNSView { return terminal }
        return view.subviews.lazy.compactMap { self.findTerminalView(in: $0) }.first
    }

    private func eventName(_ line: String) -> String {
        String(line.split(separator: ":", maxSplits: 1).first ?? "")
    }

    private func waitForEvents(_ url: URL, deadline: Date,
                               until predicate: ([String]) -> Bool) async throws -> [String] {
        while Date() < deadline {
            let events = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            if predicate(events) { return events }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("real Ghostty initial-input fixture timed out")
        throw NSError(domain: "CreateInitialInputRuntimeTests", code: 1)
    }
}
