import XCTest
import Foundation
import UserNotifications

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class NotificationCommandEnvironmentTests: XCTestCase {
    /// AC4: exercise the configured command as a real child process. NUL
    /// separators preserve multiline text and an explicitly empty tab ID.
    private final class CommandCapture {
        let suiteName: String
        let defaults: UserDefaults
        let directory: URL
        let output: URL
        static let keys = [
            "C11_NOTIFICATION_WORKSPACE_ID", "C11_NOTIFICATION_PANEL_ID", "C11_NOTIFICATION_TAB_ID",
            "C11_NOTIFICATION_KIND",
            "CMUX_NOTIFICATION_WORKSPACE_ID", "CMUX_NOTIFICATION_PANEL_ID", "CMUX_NOTIFICATION_TAB_ID",
            "CMUX_NOTIFICATION_KIND",
            "CMUX_NOTIFICATION_TITLE", "CMUX_NOTIFICATION_SUBTITLE", "CMUX_NOTIFICATION_BODY",
        ]

        init() throws {
            suiteName = "NotificationCommandEnvironmentTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("c11-notification-command-\(UUID().uuidString)", isDirectory: true)
            output = directory.appendingPathComponent("environment")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent("capture")
            let arguments = Self.keys.map { "\"$\($0)\"" }.joined(separator: " ")
            let script = """
            #!/bin/sh
            printf '%s\\0' \(arguments) > \(Self.shellQuote(output.path + ".pending"))
            /bin/mv \(Self.shellQuote(output.path + ".pending")) \(Self.shellQuote(output.path))
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            defaults.set(Self.shellQuote(executable.path), forKey: NotificationSoundSettings.customCommandKey)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        func read() throws -> [String: String] {
            let data = try Data(contentsOf: output)
            var fields = data.split(separator: 0, omittingEmptySubsequences: false)
            XCTAssertTrue(fields.last?.isEmpty == true, "capture terminates every field with NUL")
            fields.removeLast()
            XCTAssertEqual(fields.count, Self.keys.count)
            guard fields.count == Self.keys.count else { return [:] }
            return Dictionary(uniqueKeysWithValues: zip(Self.keys, fields.map { String(decoding: $0, as: UTF8.self) }))
        }

        private static func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    private func waitForCapture(_ capture: CommandCapture) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: capture.output.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture.output.path), "real custom command must finish")
        return try capture.read()
    }

    private func assertAttribution(
        _ environment: [String: String],
        workspace: UUID,
        panel: UUID?,
        kind: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for prefix in ["C11", "CMUX"] {
            XCTAssertEqual(environment["\(prefix)_NOTIFICATION_WORKSPACE_ID"], workspace.uuidString, file: file, line: line)
            XCTAssertEqual(environment["\(prefix)_NOTIFICATION_PANEL_ID"], panel?.uuidString ?? "", file: file, line: line)
            XCTAssertEqual(environment["\(prefix)_NOTIFICATION_TAB_ID"], panel?.uuidString ?? "", file: file, line: line)
            XCTAssertEqual(environment["\(prefix)_NOTIFICATION_KIND"], kind, file: file, line: line)
        }
    }

    private func notification(workspace: UUID, panel: UUID?) -> TerminalNotification {
        TerminalNotification(
            id: UUID(), workspaceId: workspace, surfaceId: panel,
            title: "Synthetic completion", subtitle: "Capture test",
            body: "First line\nSecond line '$()'", createdAt: Date(), isRead: false
        )
    }

    private func routineStore(capture: CommandCapture) -> TerminalNotificationStore {
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        store.configureNotificationCustomCommandDefaultsForTesting(capture.defaults)
        store.configureRoutineNotificationDeliveryHooksForTesting(
            authorization: { $0(true) },
            add: { _, completion in completion(nil) }
        )
        return store
    }

    func testRoutineDeliveryExportsOriginAndPreservesTextFields() throws {
        let capture = try CommandCapture()
        defer { capture.cleanUp() }
        let store = routineStore(capture: capture)
        let notice = notification(workspace: UUID(), panel: UUID())

        store.scheduleUserNotificationForTesting(notice)

        let environment = try waitForCapture(capture)
        assertAttribution(environment, workspace: notice.workspaceId, panel: notice.surfaceId, kind: "routine")
        XCTAssertEqual(environment["CMUX_NOTIFICATION_TITLE"], notice.title)
        XCTAssertEqual(environment["CMUX_NOTIFICATION_SUBTITLE"], notice.subtitle)
        XCTAssertEqual(environment["CMUX_NOTIFICATION_BODY"], notice.body)
    }

    func testWorkspaceOnlyDeliveryExportsEmptyTab() throws {
        let capture = try CommandCapture()
        defer { capture.cleanUp() }
        let store = routineStore(capture: capture)
        let notice = notification(workspace: UUID(), panel: nil)

        store.scheduleUserNotificationForTesting(notice)

        assertAttribution(try waitForCapture(capture), workspace: notice.workspaceId, panel: nil, kind: "routine")
    }

    func testAbsentTabOverwritesInheritedAttributionInRealCommand() throws {
        let capture = try CommandCapture()
        defer { capture.cleanUp() }
        let workspace = UUID()
        var inherited = ProcessInfo.processInfo.environment
        for prefix in ["C11", "CMUX"] {
            inherited["\(prefix)_NOTIFICATION_WORKSPACE_ID"] = "inherited-workspace"
            inherited["\(prefix)_NOTIFICATION_PANEL_ID"] = "inherited-panel"
            inherited["\(prefix)_NOTIFICATION_TAB_ID"] = "inherited-tab"
            inherited["\(prefix)_NOTIFICATION_KIND"] = "inherited-kind"
        }

        NotificationSoundSettings.runCustomCommand(
            title: "Workspace notice", subtitle: "", body: "Synthetic body",
            workspaceId: workspace, surfaceId: nil, kind: .routine,
            defaults: capture.defaults, environment: inherited
        )

        assertAttribution(try waitForCapture(capture), workspace: workspace, panel: nil, kind: "routine")
    }

    func testDirectFlagDeliveryExportsFlagOrigin() throws {
        let capture = try CommandCapture()
        defer { capture.cleanUp() }
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        store.configureNotificationCustomCommandDefaultsForTesting(capture.defaults)
        store.configureFlagNotificationReplacementHandlerForTesting { _, add in add() }
        store.configureDirectFlagAuthorizationHandlerForTesting { $0(true) }
        store.configureDirectFlagAddHandlerForTesting { _, completion in completion(nil) }
        let workspace = UUID()
        let panel = UUID()

        store.deliverFlagNotification(workspaceId: workspace, surfaceId: panel, flagRaisedAt: Date(), title: "Flag test", reason: "Synthetic decision")

        let environment = try waitForCapture(capture)
        assertAttribution(environment, workspace: workspace, panel: panel, kind: "flag")
        XCTAssertEqual(environment["CMUX_NOTIFICATION_TITLE"], "Flag test")
        XCTAssertEqual(environment["CMUX_NOTIFICATION_SUBTITLE"], "")
        XCTAssertEqual(environment["CMUX_NOTIFICATION_BODY"], "Synthetic decision")
        XCTAssertTrue(store.notifications.isEmpty, "direct flags must remain separate from routine history")
    }

    func testDeniedFlagAuthorizationDoesNotAddOrRunCommand() {
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        var adds = 0
        var commands = 0
        store.configureFlagNotificationReplacementHandlerForTesting { _, add in add() }
        store.configureDirectFlagAuthorizationHandlerForTesting { $0(false) }
        store.configureDirectFlagAddHandlerForTesting { _, _ in adds += 1 }
        store.configureDirectFlagCustomCommandHandlerForTesting { _ in commands += 1 }

        store.deliverFlagNotification(workspaceId: UUID(), surfaceId: UUID(), flagRaisedAt: Date(), title: "Denied", reason: "Synthetic decision")

        XCTAssertEqual(adds, 0)
        XCTAssertEqual(commands, 0)
    }

    func testCanceledFlagDoesNotResumeDelayedAuthorization() throws {
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        var authorization: ((Bool) -> Void)?
        var adds = 0
        var commands = 0
        store.configureFlagNotificationReplacementHandlerForTesting { _, add in add() }
        store.configureDirectFlagAuthorizationHandlerForTesting { authorization = $0 }
        store.configureDirectFlagAddHandlerForTesting { _, _ in adds += 1 }
        store.configureDirectFlagCustomCommandHandlerForTesting { _ in commands += 1 }
        let workspace = UUID()
        let panel = UUID()
        let epoch = Date()

        store.deliverFlagNotification(workspaceId: workspace, surfaceId: panel, flagRaisedAt: epoch, title: "Canceled", reason: "Synthetic decision")
        store.cancelFlagNotification(workspaceId: workspace, surfaceId: panel, flagRaisedAt: epoch)
        try XCTUnwrap(authorization)(true)

        XCTAssertEqual(adds, 0)
        XCTAssertEqual(commands, 0)
    }

    func testFailedFlagBannerDoesNotRunCommand() {
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        var commands = 0
        store.configureFlagNotificationReplacementHandlerForTesting { _, add in add() }
        store.configureDirectFlagAuthorizationHandlerForTesting { $0(true) }
        store.configureDirectFlagAddHandlerForTesting { _, completion in
            completion(NSError(domain: "NotificationCommandEnvironmentTests", code: 1))
        }
        store.configureDirectFlagCustomCommandHandlerForTesting { _ in commands += 1 }

        store.deliverFlagNotification(workspaceId: UUID(), surfaceId: UUID(), flagRaisedAt: Date(), title: "Banner failure", reason: "Synthetic decision")
        let drained = expectation(description: "failed flag add processed")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertEqual(commands, 0)
    }

    func testRevisedFlagSkipsObsoleteBannerCompletion() {
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        var completions: [(Error?) -> Void] = []
        var commands: [String] = []
        store.configureFlagNotificationReplacementHandlerForTesting { _, add in add() }
        store.configureDirectFlagAuthorizationHandlerForTesting { $0(true) }
        store.configureDirectFlagAddHandlerForTesting { _, completion in completions.append(completion) }
        store.configureDirectFlagCustomCommandHandlerForTesting { commands.append($0.body) }
        let workspace = UUID()
        let panel = UUID()
        let epoch = Date()

        store.deliverFlagNotification(workspaceId: workspace, surfaceId: panel, flagRaisedAt: epoch, title: "Revision", reason: "Old reason")
        store.deliverFlagNotification(workspaceId: workspace, surfaceId: panel, flagRaisedAt: epoch, title: "Revision", reason: "Current reason")
        XCTAssertEqual(completions.count, 2)
        guard completions.count == 2 else { return }
        completions[0](nil)
        completions[1](nil)
        let drained = expectation(description: "flag add completions processed")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertEqual(commands, ["Current reason"])
    }

    // MARK: - C11-337 notification userInfo

    func testRoutineRequestUserInfoCarriesPanelIdBesideSurfaceId() throws {
        let store = TerminalNotificationStore.makeForNotificationCommandTesting()
        var captured: UNNotificationRequest?
        store.configureRoutineNotificationDeliveryHooksForTesting(
            authorization: { $0(true) },
            add: { request, _ in captured = request }
        )
        let notice = notification(workspace: UUID(), panel: UUID())

        store.scheduleUserNotificationForTesting(notice)

        let userInfo = try XCTUnwrap(captured).content.userInfo
        let panel = try XCTUnwrap(notice.surfaceId).uuidString
        XCTAssertEqual(userInfo["panelId"] as? String, panel)
        XCTAssertEqual(userInfo["surfaceId"] as? String, panel)
        // `tabId` holds the workspace id.
        XCTAssertEqual(userInfo["tabId"] as? String, notice.workspaceId.uuidString)
        XCTAssertEqual(TerminalNotificationStore.panelIdString(fromUserInfo: userInfo), panel)
    }

    func testWorkspaceOnlyUserInfoHasNoPanel() {
        let userInfo = TerminalNotificationStore.userInfo(for: notification(workspace: UUID(), panel: nil))
        XCTAssertNil(userInfo["panelId"])
        XCTAssertNil(userInfo["surfaceId"])
        XCTAssertNil(TerminalNotificationStore.panelIdString(fromUserInfo: userInfo))
    }

    func testPanelIdReaderFallsBackToLegacySurfaceId() {
        let panel = UUID().uuidString
        let legacy = UUID().uuidString
        XCTAssertEqual(TerminalNotificationStore.panelIdString(fromUserInfo: ["tabId": UUID().uuidString, "surfaceId": legacy]), legacy)
        XCTAssertEqual(TerminalNotificationStore.panelIdString(fromUserInfo: ["panelId": panel, "surfaceId": legacy]), panel)
        XCTAssertNil(TerminalNotificationStore.panelIdString(fromUserInfo: ["tabId": UUID().uuidString]))
    }
}
