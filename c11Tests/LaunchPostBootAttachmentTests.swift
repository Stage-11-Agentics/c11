import AppKit
import CryptoKit
import Darwin
import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Host-required regression: prompt delivery must wait for the launch command's
/// actual Ghostty submission, including a tab that attaches after the old timer.
@MainActor
final class LaunchPostBootAttachmentTests: XCTestCase {
    func testKimiPostBootPromptWaitsForActualAttachment() async throws {
        try await exerciseDelayedAttachment(kind: "kimi")
    }

    func testCopilotPostBootPromptWaitsForActualAttachment() async throws {
        try await exerciseDelayedAttachment(kind: "github-copilot")
    }

    private func exerciseDelayedAttachment(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c11-postboot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let prefix = "  Synthetic \(kind) quotes ' \" $HOME `echo literal` $(echo literal); 日本語 🦉\n"
        let suffix = "\n trailing whitespace  \t\n"
        let body = prefix + String(repeating: "x", count: 32 * 1024 - (prefix + suffix).utf8.count) + suffix
        XCTAssertEqual(body.utf8.count, 32 * 1024)
        let expectedDigest = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        let store = LaunchPromptStore(rootDirectory: root.appendingPathComponent("owned space ' $ prompts"))
        let staged = try await Task.detached(priority: .userInitiated) { try store.stage(prompt: body) }.value
        let launcherReceipt = root.appendingPathComponent("launcher.json")
        let fileReceipt = root.appendingPathComponent("file.json")
        let fake = root.appendingPathComponent("fake postboot agent.py")
        try #"""
import hashlib, json, pathlib, sys, time
launch_receipt, file_receipt = map(pathlib.Path, sys.argv[1:])
launch_receipt.write_text(json.dumps({'started_at': time.time()}))
try:
    instruction = sys.stdin.readline().rstrip('\r\n')
    prefix, suffix = 'Read the file at ', ' and follow it exactly.'
    assert instruction.startswith(prefix) and instruction.endswith(suffix), repr(instruction)
    path = instruction[len(prefix):-len(suffix)]
    data = pathlib.Path(path).read_bytes()
    result = {'instruction': instruction, 'path': path, 'file_bytes': len(data),
              'file_sha256': hashlib.sha256(data).hexdigest(), 'read_at': time.time()}
except Exception as error:
    result = {'error': repr(error), 'read_at': time.time()}
file_receipt.write_text(json.dumps(result))
"""#.write(to: fake, atomically: true, encoding: .utf8)

        // initialCommand would eagerly make a headless window. A retained
        // config command selects isolated zsh while preserving the unattached
        // surface state that this regression deliberately exercises.
        let shellCommand = try XCTUnwrap(strdup("/bin/zsh -f -i"))
        defer { free(shellCommand) }
        var template = ghostty_surface_config_new()
        template.command = UnsafePointer(shellCommand)
        let panel = TerminalTab(
            workspaceId: UUID(), configTemplate: template,
            workingDirectory: root.path,
            initialEnvironmentOverrides: ["HOME": root.path, "ZDOTDIR": root.path, "SHELL": "/bin/zsh"]
        )
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        var live = true
        defer {
            live = false
            panel.close()
            store.release(owner: panel.launchPromptOwner)
            panel.hostedView.removeFromSuperview()
            window.orderOut(nil)
            window.close()
        }
        try store.retain(staged, owner: panel.launchPromptOwner)
        let command = "/usr/bin/python3 -B " + [fake.path, launcherReceipt.path, fileReceipt.path]
            .map(DefaultAgentResolver.shellQuote).joined(separator: " ")
        let plan = LaunchPromptDelivery.compose(command: command, delivery: .postBoot, promptFilePath: staged.url.path)
        XCTAssertEqual(plan.launchLine, command)
        XCTAssertEqual(plan.delayedPrompt, LaunchPromptDelivery.instruction(path: staged.url.path))
        XCTAssertFalse(plan.launchLine.contains(body))
        XCTAssertNil(panel.surface.surface)
        XCTAssertNil(panel.hostedView.window)

        let requestedAt = Date()
        let deadline = requestedAt.addingTimeInterval(15)
        panel.submitLaunchPlan(plan, isLive: { live }, requestBackgroundStart: false)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertNil(panel.surface.surface, "fixture must remain genuinely unattached past the old 2.5 s timer")
        XCTAssertNil(panel.hostedView.window)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launcherReceipt.path), "launcher ran before attachment")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileReceipt.path), "prompt was read before attachment")

        let attachedAt = Date()
        let contentView = try XCTUnwrap(window.contentView)
        panel.hostedView.frame = contentView.bounds
        panel.hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(panel.hostedView)
        contentView.layoutSubtreeIfNeeded()
        let terminalView = try XCTUnwrap(findTerminalView(in: panel.hostedView))
        panel.surface.attachToView(terminalView)
        _ = try XCTUnwrap(panel.surface.surface, "host must create a real Ghostty PTY after attachment")
        XCTAssertFalse(window.isVisible, "fixture must never show or activate its window")

        let launcher = try await waitForReceipt(at: launcherReceipt, deadline: deadline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileReceipt.path), "post-boot instruction arrived with the queued launcher")
        let received = try await waitForReceipt(at: fileReceipt, deadline: deadline)
        let diagnostic = String(describing: received)
        XCTAssertNil(received["error"], diagnostic)
        XCTAssertEqual(received["instruction"] as? String, plan.delayedPrompt, diagnostic)
        XCTAssertEqual(received["path"] as? String, staged.url.path, diagnostic)
        XCTAssertEqual(received["file_bytes"] as? Int, body.utf8.count, diagnostic)
        XCTAssertEqual(received["file_sha256"] as? String, expectedDigest, diagnostic)
        let startedAt = try XCTUnwrap(launcher["started_at"] as? Double)
        let readAt = try XCTUnwrap(received["read_at"] as? Double)
        XCTAssertGreaterThanOrEqual(readAt - attachedAt.timeIntervalSince1970, 2.25,
                                    "the 2.5 s timer must start after actual submission, not the unattached request")
        XCTAssertGreaterThan(readAt, startedAt, "file read must follow launcher execution")
        print("POSTBOOT \(kind): unattached=\(attachedAt.timeIntervalSince(requestedAt))s "
              + "attach-to-launch=\(startedAt - attachedAt.timeIntervalSince1970)s "
              + "launch-to-read=\(readAt - startedAt)s bytes=\(body.utf8.count) sha256=\(expectedDigest)")
    }

    private func findTerminalView(in view: NSView) -> GhosttyNSView? {
        if let terminal = view as? GhosttyNSView { return terminal }
        for child in view.subviews {
            if let terminal = findTerminalView(in: child) { return terminal }
        }
        return nil
    }

    private func waitForReceipt(at url: URL, deadline: Date) async throws -> [String: Any] {
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return receipt
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("timed out waiting for real Ghostty fixture receipt: \(url.lastPathComponent)")
        throw NSError(domain: "LaunchPostBootAttachmentTests", code: 1)
    }
}
