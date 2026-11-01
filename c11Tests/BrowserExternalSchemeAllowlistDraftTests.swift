import XCTest
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// C11-562: the Settings editor for sites allowed to open apps writes only on
/// Save, and reports a line that could never match instead of dropping it.
@MainActor
final class BrowserExternalSchemeAllowlistDraftTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "c11.tests.external-allowlist-draft.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private var stored: String? { defaults.string(forKey: BrowserExternalSchemeSettings.allowlistKey) }

    func testEditingWritesNothingUntilSave() {
        defaults.set("https://zoom.us zoommtg", forKey: BrowserExternalSchemeSettings.allowlistKey)
        var draft = BrowserExternalSchemeAllowlistDraft(saved: stored ?? "")
        draft.text = "https://zoom.us zoommtg\nhttps://example.com:8443 vnc:"
        XCTAssertTrue(draft.hasUnsavedChanges)
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(stored, "https://zoom.us zoommtg")
        XCTAssertTrue(draft.save(to: defaults))
        XCTAssertEqual(stored, "https://zoom.us zoommtg\nhttps://example.com:8443 vnc:")
        XCTAssertFalse(draft.hasUnsavedChanges)
        XCTAssertTrue(BrowserExternalSchemeSettings.isAllowed(originKey: "https://example.com:8443", scheme: "vnc", defaults: defaults))
    }

    func testInvalidLineIsReportedAndBlocksSave() {
        let cases: [(String, Int, String)] = [
            ("https://zoom.us zoommtg\nzoom.us zoommtg", 2, "zoom.us zoommtg"),
            ("https://zoom.us/ zoommtg", 1, "https://zoom.us/"),
            ("https://zoom.us:443 zoommtg", 1, "https://zoom.us:443"),
            ("\n\nhttps://zoom.us", 3, "https://zoom.us"),
            ("https://zoom.us zoommtg extra", 1, "https://zoom.us zoommtg extra"),
            ("https://zoom.us 1bad", 1, "https://zoom.us 1bad"),
        ]
        for (text, number, prefix) in cases {
            defaults.removeObject(forKey: BrowserExternalSchemeSettings.allowlistKey)
            var draft = BrowserExternalSchemeAllowlistDraft(saved: "")
            draft.text = text
            let invalid = draft.invalidLine
            XCTAssertEqual(invalid?.number, number, text)
            XCTAssertTrue(invalid?.text.hasPrefix(prefix) == true, text)
            XCTAssertFalse(draft.canSave, text)
            XCTAssertFalse(draft.save(to: defaults), text)
            XCTAssertNil(stored, text)
            XCTAssertTrue(draft.hasUnsavedChanges, text)
        }
    }

    func testBlankLinesAndCaseAreAccepted() {
        var draft = BrowserExternalSchemeAllowlistDraft(saved: "")
        draft.text = "\nHTTPS://Zoom.US ZoomMtg\n\n  http://localhost:8080 smb  \n"
        XCTAssertNil(draft.invalidLine)
        XCTAssertTrue(draft.save(to: defaults))
        XCTAssertTrue(BrowserExternalSchemeSettings.isAllowed(originKey: "https://zoom.us", scheme: "zoommtg", defaults: defaults))
    }

    /// C11-562 review: the Settings window outlives a close, so an abandoned
    /// edit must not come back on reopen and ride along with the next Save.
    func testClosingSettingsDiscardsUnsavedEditsWithoutWriting() {
        defaults.set("https://zoom.us zoommtg", forKey: BrowserExternalSchemeSettings.allowlistKey)
        var draft = BrowserExternalSchemeAllowlistDraft(saved: stored ?? "")
        draft.text = ""
        XCTAssertTrue(draft.canSave)

        let other = NSView()
        other.identifier = NSUserInterfaceItemIdentifier("cmux.main")
        draft.settingsWindowWillClose(Notification(name: NSWindow.willCloseNotification, object: other), stored: stored ?? "")
        XCTAssertEqual(draft.text, "", "another window closing keeps the edit")

        let settings = NSView()
        settings.identifier = NSUserInterfaceItemIdentifier("cmux.settings")
        draft.settingsWindowWillClose(Notification(name: NSWindow.willCloseNotification, object: settings), stored: stored ?? "")
        XCTAssertEqual(draft.text, "https://zoom.us zoommtg")
        XCTAssertFalse(draft.hasUnsavedChanges)
        XCTAssertFalse(draft.canSave)
        XCTAssertEqual(stored, "https://zoom.us zoommtg")
    }

    func testOutsideChangeFollowsUnlessDraftIsDirty() {
        var draft = BrowserExternalSchemeAllowlistDraft(saved: "")
        draft.storedValueChanged(to: "https://zoom.us zoommtg")
        XCTAssertEqual(draft.text, "https://zoom.us zoommtg")
        XCTAssertFalse(draft.hasUnsavedChanges)
        draft.text = "https://example.com vnc"
        draft.storedValueChanged(to: "https://zoom.us zoommtg\nhttps://a.example smb")
        XCTAssertEqual(draft.text, "https://example.com vnc")
        XCTAssertTrue(draft.hasUnsavedChanges)
    }
}
