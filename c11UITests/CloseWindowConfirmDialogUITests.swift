import XCTest

final class CloseWindowConfirmDialogUITests: XCTestCase {
    private let launchTag = "ui-tests-close-window-confirm"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testCmdCtrlWShowsCloseWindowConfirmationText() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-window confirmation test. state=\(app.state.rawValue)"
        )

        app.typeKey("w", modifierFlags: [.command, .control])

        XCTAssertTrue(
            waitForCloseWindowAlert(app: app, timeout: 5.0),
            "Expected Cmd+Ctrl+W to show the close window confirmation alert"
        )

        clickCancelOnCloseWindowAlert(app: app)

        XCTAssertFalse(
            isCloseWindowAlertPresent(app: app),
            "Expected close window confirmation alert to dismiss after clicking Cancel"
        )
        XCTAssertTrue(app.windows.firstMatch.exists, "Expected the window to remain open after cancelling close")
    }

    func testReturnCancelsCloseWindowDialog() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-window confirmation test. state=\(app.state.rawValue)"
        )

        app.typeKey("w", modifierFlags: [.command, .control])

        XCTAssertTrue(
            waitForCloseWindowAlert(app: app, timeout: 5.0),
            "Expected Cmd+Ctrl+W to show the close window confirmation alert"
        )

        // Cancel is the default: a reflexive Return must keep the window.
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            waitForCloseWindowAlertToDismiss(app: app, timeout: 5.0),
            "Expected Return to dismiss the close window confirmation alert"
        )
        XCTAssertTrue(app.windows.firstMatch.exists, "Expected Return to cancel, keeping the window open")
    }

    func testClickingCloseConfirmsCloseWindowDialog() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        XCTAssertTrue(
            ensureForegroundAfterLaunch(app, timeout: 12.0),
            "Expected app to launch for close-window confirmation test. state=\(app.state.rawValue)"
        )

        app.typeKey("w", modifierFlags: [.command, .control])

        XCTAssertTrue(
            waitForCloseWindowAlert(app: app, timeout: 5.0),
            "Expected Cmd+Ctrl+W to show the close window confirmation alert"
        )

        clickButtonOnCloseWindowAlert(app: app, title: "Close")

        XCTAssertTrue(
            waitForMainWindowToClose(app: app, timeout: 5.0),
            "Expected clicking Close to close the window"
        )
    }

    private func isCloseWindowAlertPresent(app: XCUIApplication) -> Bool {
        if closeWindowSheet(app: app).exists { return true }
        if closeWindowDialog(app: app).exists { return true }
        if closeWindowAlert(app: app).exists { return true }
        return app.staticTexts["Close window?"].exists
    }

    private func waitForCloseWindowAlert(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.isCloseWindowAlertPresent(app: app)
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForCloseWindowAlertToDismiss(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !self.isCloseWindowAlertPresent(app: app)
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForMainWindowToClose(app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !app.windows.firstMatch.exists
            },
            object: NSObject()
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func clickCancelOnCloseWindowAlert(app: XCUIApplication) {
        clickButtonOnCloseWindowAlert(app: app, title: "Cancel")
    }

    private func clickButtonOnCloseWindowAlert(app: XCUIApplication, title: String) {
        for container in [closeWindowSheet(app: app), closeWindowDialog(app: app), closeWindowAlert(app: app)]
        where container.exists {
            container.buttons[title].firstMatch.click()
            return
        }
        let anyDialog = app.dialogs.firstMatch
        if anyDialog.exists, anyDialog.buttons[title].exists {
            anyDialog.buttons[title].firstMatch.click()
        }
    }

    private func closeWindowSheet(app: XCUIApplication) -> XCUIElement {
        app.sheets.containing(.staticText, identifier: "Close window?").firstMatch
    }

    private func closeWindowDialog(app: XCUIApplication) -> XCUIElement {
        app.dialogs.containing(.staticText, identifier: "Close window?").firstMatch
    }

    private func closeWindowAlert(app: XCUIApplication) -> XCUIElement {
        app.alerts.containing(.staticText, identifier: "Close window?").firstMatch
    }

    private func ensureForegroundAfterLaunch(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        if app.wait(for: .runningForeground, timeout: timeout) {
            return true
        }
        if app.state == .runningBackground {
            app.activate()
            return app.wait(for: .runningForeground, timeout: 6.0)
        }
        return false
    }
}
