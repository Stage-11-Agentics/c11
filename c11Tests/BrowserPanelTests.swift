import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

private func drainBrowserPanelMainQueue() {
    let expectation = XCTestExpectation(description: "drain main queue")
    DispatchQueue.main.async {
        expectation.fulfill()
    }
    XCTWaiter().wait(for: [expectation], timeout: 5.0)
}

@MainActor
private func waitForBrowserProfileReservationRelease(_ profileID: UUID) async {
    let deadline = Date().addingTimeInterval(2)
    while BrowserProfileStore.shared.isReserved(profileID), Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

@MainActor
private func makeTemporaryBrowserPanelProfile(named prefix: String) throws -> BrowserProfileDefinition {
    try XCTUnwrap(
        BrowserProfileStore.shared.createProfile(
            named: "\(prefix)-\(UUID().uuidString)"
        )
    )
}

final class BrowserPanelChromeBackgroundColorTests: XCTestCase {
    func testLightModeUsesThemeBackgroundColor() {
        assertResolvedColorMatchesTheme(for: .light)
    }

    func testDarkModeUsesThemeBackgroundColor() {
        assertResolvedColorMatchesTheme(for: .dark)
    }

    private func assertResolvedColorMatchesTheme(
        for colorScheme: ColorScheme,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.13, green: 0.29, blue: 0.47, alpha: 1.0)

        guard
            let actual = resolvedBrowserChromeBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground
            ).usingColorSpace(.sRGB),
            let expected = themeBackground.usingColorSpace(.sRGB)
        else {
            XCTFail("Expected sRGB-convertible colors", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001, file: file, line: line)
    }
}


final class BrowserPanelOmnibarPillBackgroundColorTests: XCTestCase {
    func testLightModeSlightlyDarkensThemeBackground() {
        assertResolvedColorMatchesExpectedBlend(for: .light, darkenMix: 0.04)
    }

    func testDarkModeSlightlyDarkensThemeBackground() {
        assertResolvedColorMatchesExpectedBlend(for: .dark, darkenMix: 0.05)
    }

    private func assertResolvedColorMatchesExpectedBlend(
        for colorScheme: ColorScheme,
        darkenMix: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let themeBackground = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1.0)
        let expected = themeBackground.blended(withFraction: darkenMix, of: .black) ?? themeBackground

        guard
            let actual = resolvedBrowserOmnibarPillBackgroundColor(
                for: colorScheme,
                themeBackgroundColor: themeBackground
            ).usingColorSpace(.sRGB),
            let expectedSRGB = expected.usingColorSpace(.sRGB),
            let themeSRGB = themeBackground.usingColorSpace(.sRGB)
        else {
            XCTFail("Expected sRGB-convertible colors", file: file, line: line)
            return
        }

        XCTAssertEqual(actual.redComponent, expectedSRGB.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expectedSRGB.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expectedSRGB.blueComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, expectedSRGB.alphaComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertNotEqual(actual.redComponent, themeSRGB.redComponent, file: file, line: line)
    }
}


@MainActor
final class BrowserPanelProfileIsolationTests: XCTestCase {
    func testStaleDidFinishDoesNotRecordVisitIntoSwitchedProfileHistory() throws {
        let alternateProfile = try makeTemporaryBrowserPanelProfile(named: "Switched")
        let defaultStore = BrowserHistoryStore.shared
        let alternateStore = BrowserProfileStore.shared.historyStore(for: alternateProfile.id)
        defaultStore.clearHistory()
        alternateStore.clearHistory()
        defer {
            defaultStore.clearHistory()
            alternateStore.clearHistory()
        }

        let panel = BrowserPanel(
            workspaceId: UUID(),
            profileID: BrowserProfileStore.shared.builtInDefaultProfileID
        )
        let staleWebView = panel.webView
        let staleDelegate = try XCTUnwrap(staleWebView.navigationDelegate)
        let staleURL = try XCTUnwrap(URL(string: "https://example.com/stale-finish"))
        staleWebView.loadHTMLString(
            "<html><head><title>Stale</title></head><body>stale</body></html>",
            baseURL: staleURL
        )

        XCTAssertTrue(
            panel.switchToProfile(alternateProfile.id),
            "Expected profile switch to succeed, current=\(panel.profileID) requested=\(alternateProfile.id) exists=\(BrowserProfileStore.shared.profileDefinition(id: alternateProfile.id) != nil)"
        )
        defaultStore.clearHistory()
        alternateStore.clearHistory()

        staleDelegate.webView?(staleWebView, didFinish: nil)
        drainBrowserPanelMainQueue()

        XCTAssertTrue(
            defaultStore.entries.isEmpty,
            "Expected stale completion callbacks to avoid writing into the old profile history store, found \(defaultStore.entries.map { $0.url })"
        )
        XCTAssertTrue(
            alternateStore.entries.isEmpty,
            "Expected stale completion callbacks to avoid writing into the newly selected profile history store, found \(alternateStore.entries.map { $0.url })"
        )
    }
}

@MainActor
final class BrowserProfileStoreLifecycleTests: XCTestCase {
    func testDelayedClearRejectsAdmissionAndCompletesAfterWorkerTimeout() async throws {
        try await exerciseDelayedRemoval(deleteProfile: false)
    }

    func testDelayedDeleteRejectsAdmissionAndCompletesAfterWorkerTimeout() async throws {
        try await exerciseDelayedRemoval(deleteProfile: true)
    }

    private func exerciseDelayedRemoval(deleteProfile: Bool) async throws {
        let store = BrowserProfileStore.shared
        let profile = try makeTemporaryBrowserPanelProfile(named: deleteProfile ? "Delayed-delete" : "Delayed-clear")
        let otherProfile = try XCTUnwrap(
            store.createProfile(named: "Still-usable-\(UUID().uuidString)", recordsLastUsed: false)
        )
        let method = deleteProfile ? "browser.profiles.delete" : "browser.profiles.clear"
        var pendingCompletion: ((Error?) -> Void)?
        store.websiteDataRemovalHandler = { _, _, completion in
            pendingCompletion = completion
        }
        defer {
            store.websiteDataRemovalHandler = nil
            store.release(profile.id)
            _ = store.removeProfileDefinition(id: profile.id)
            _ = store.removeProfileDefinition(id: otherProfile.id)
        }

        let controller = TerminalController.shared
        let workspace = try XCTUnwrap(controller.workspaceManager?.selectedWorkspace)
        let workspaceID = workspace.id
        let profileID = profile.id
        let profileIDString = profileID.uuidString
        let otherProfileID = otherProfile.id
        let existingPanelIDs = Set(workspace.panels.keys)
        let response = await Task.detached(priority: .utility) {
            controller.v2BrowserProfileCommand(
                method: method,
                params: ["profile": profileIDString, "confirm": true]
            )
        }.value
        guard case .err(let pendingCode, _, _) = response else {
            return XCTFail("Expected bounded pending response before WebKit completion: \(response)")
        }
        XCTAssertEqual(pendingCode, "operation_pending")
        XCTAssertTrue(store.isReserved(profile.id))
        XCTAssertNotNil(pendingCompletion)

        let duplicate = await Task.detached(priority: .utility) {
            controller.v2BrowserProfileCommand(
                method: method,
                params: ["profile": profileIDString, "confirm": true]
            )
        }.value
        guard case .err(let busyCode, _, _) = duplicate else {
            return XCTFail("Expected duplicate destructive request to refuse a reserved profile: \(duplicate)")
        }
        XCTAssertEqual(busyCode, "busy")

        let open = controller.v2BrowserOpenSplit(params: [
            "workspace_id": workspaceID.uuidString,
            "url": "https://example.com",
            "profile": profileIDString
        ])
        guard case .err(let openCode, _, _) = open else {
            return XCTFail("Expected browser open to refuse a reserved profile: \(open)")
        }
        XCTAssertEqual(openCode, "busy")
        XCTAssertEqual(Set(workspace.panels.keys), existingPanelIDs, "A reserved profile open must not create a tab")

        let switchPanel = BrowserPanel(
            workspaceId: workspace.id,
            profileID: store.builtInDefaultProfileID,
            sticksAsPreferred: false
        )
        XCTAssertFalse(switchPanel.switchToProfile(profile.id), "A tab must not switch into a reserved profile")
        XCTAssertEqual(switchPanel.profileID, store.builtInDefaultProfileID)
        XCTAssertTrue(switchPanel.switchToProfile(otherProfileID), "A separate profile should remain usable")
        XCTAssertTrue(store.isReserved(profileID), "The second profile must not release the held target reservation")

        // The worker has already returned operation_pending. Completing the
        // held WebKit callback afterward must still finish cleanup and release
        // the reservation.
        pendingCompletion?(nil)
        await waitForBrowserProfileReservationRelease(profileID)
        XCTAssertFalse(store.isReserved(profileID))
        if deleteProfile {
            XCTAssertNil(store.profileDefinition(id: profileID), "Late delete completion must remove the definition")
        } else {
            XCTAssertNotNil(store.profileDefinition(id: profileID), "Clear must preserve the profile definition")
            XCTAssertTrue(switchPanel.switchToProfile(profileID), "Clear completion must release profile admission")
        }
    }

    func testDelayedRemovalReservesProfileUntilCompletion() throws {
        let store = BrowserProfileStore.shared
        let profile = try makeTemporaryBrowserPanelProfile(named: "Delayed-clear")
        var pendingCompletion: ((Error?) -> Void)?
        var operationResult: Result<Void, BrowserProfileOperationError>?
        store.websiteDataRemovalHandler = { _, _, completion in
            pendingCompletion = completion
        }
        defer {
            store.websiteDataRemovalHandler = nil
            store.release(profile.id)
            _ = store.removeProfileDefinition(id: profile.id)
        }

        let start = store.beginClear(id: profile.id, inUse: false) { result in
            operationResult = result
        }
        guard case .started = start else {
            return XCTFail("Expected clear to start")
        }
        XCTAssertTrue(store.isReserved(profile.id))
        guard case .failed(.busy) = store.beginClear(id: profile.id, inUse: false, completion: { _ in }) else {
            return XCTFail("Expected a second clear to refuse a reserved profile")
        }

        pendingCompletion?(nil)
        drainBrowserPanelMainQueue()
        XCTAssertFalse(store.isReserved(profile.id))
        guard case .success = operationResult else {
            return XCTFail("Expected delayed completion to finish successfully: \(String(describing: operationResult))")
        }
    }

    func testNeverCompletingRemovalLeavesWorkerPendingAndProfileResponsive() async throws {
        let store = BrowserProfileStore.shared
        let profile = try makeTemporaryBrowserPanelProfile(named: "Never-completes")
        store.websiteDataRemovalHandler = { _, _, _ in }
        defer {
            store.websiteDataRemovalHandler = nil
            store.release(profile.id)
            _ = store.removeProfileDefinition(id: profile.id)
        }

        let controller = TerminalController.shared
        let response = await Task.detached(priority: .utility) {
            controller.v2BrowserProfileCommand(
                method: "browser.profiles.clear",
                params: ["profile": profile.id.uuidString, "confirm": true]
            )
        }.value
        guard case .err(let code, _, _) = response else {
            return XCTFail("Expected a pending response, got (response)")
        }
        XCTAssertEqual(code, "operation_pending")
        XCTAssertTrue(store.isReserved(profile.id))
        XCTAssertNotNil(store.profileDefinition(id: profile.id))

        let listResponse = await Task.detached(priority: .utility) {
            controller.v2BrowserProfileCommand(
                method: "browser.profiles.list",
                params: [:]
            )
        }.value
        guard case .ok(let payload) = listResponse,
              let object = payload as? [String: Any],
              let profiles = object["profiles"] as? [[String: Any]] else {
            return XCTFail("Profile list did not remain responsive: (listResponse)")
        }
        XCTAssertEqual(profiles.filter { ($0["id"] as? String) == profile.id.uuidString }.count, 1)
    }
}


@MainActor
final class BrowserPanelAddressBarFocusRequestTests: XCTestCase {
    func testRequestPersistsUntilAcknowledged() {
        let panel = BrowserPanel(workspaceId: UUID())
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)

        let requestId = panel.requestAddressBarFocus()
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, requestId)
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())

        panel.acknowledgeAddressBarFocusRequest(requestId)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)

        // Acknowledgement only clears the durable request; focus suppression follows
        // explicit blur state transitions.
        XCTAssertTrue(panel.shouldSuppressWebViewFocus())
        panel.endSuppressWebViewFocusForAddressBar()
        XCTAssertFalse(panel.shouldSuppressWebViewFocus())
    }

    func testRequestCoalescesWhilePending() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus()
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, firstRequest)
    }

    func testStaleAcknowledgementDoesNotClearNewestRequest() {
        let panel = BrowserPanel(workspaceId: UUID())
        let firstRequest = panel.requestAddressBarFocus()
        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        let secondRequest = panel.requestAddressBarFocus()

        XCTAssertNotEqual(firstRequest, secondRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(firstRequest)
        XCTAssertEqual(panel.pendingAddressBarFocusRequestId, secondRequest)

        panel.acknowledgeAddressBarFocusRequest(secondRequest)
        XCTAssertNil(panel.pendingAddressBarFocusRequestId)
    }
}


@MainActor
final class WindowBrowserHostViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class PrimaryPageProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class WKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class EdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x <= 12 ? nil : self
        }
    }

    private final class TrailingEdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x >= bounds.maxX - 12 ? nil : self
        }
    }

    private final class BonsplitMockSplitDelegate: NSObject, NSSplitViewDelegate {}

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    private func isInspectorOwnedHit(_ hit: NSView?, inspectorView: NSView, pageView: NSView) -> Bool {
        guard let hit else { return false }
        if hit === pageView || hit.isDescendant(of: pageView) {
            return false
        }
        if hit === inspectorView || hit.isDescendant(of: inspectorView) {
            return true
        }
        return inspectorView.isDescendant(of: hit) && !(pageView === hit || pageView.isDescendant(of: hit))
    }


    func testHostViewPassesThroughDividerWhenAdjacentPaneIsCollapsed() async throws {
        let window = C11PointerProbeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let splitDelegate = BonsplitMockSplitDelegate()
        splitView.delegate = splitDelegate
        let first = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height))
        let second = NSView(frame: NSRect(x: 121, y: 0, width: 179, height: contentView.bounds.height))
        splitView.addSubview(first)
        splitView.addSubview(second)
        contentView.addSubview(splitView)
        splitView.setPosition(1, ofDividerAt: 0)
        splitView.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        let child = CapturingView(frame: host.bounds)
        child.autoresizingMask = [.width, .height]
        host.addSubview(child)
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let dividerPointInSplit = NSPoint(
            x: splitView.arrangedSubviews[0].frame.maxX + (splitView.dividerThickness * 0.5),
            y: splitView.bounds.midY
        )
        let dividerPointInWindow = splitView.convert(dividerPointInSplit, to: nil)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        XCTAssertLessThanOrEqual(splitView.arrangedSubviews[0].frame.width, 1.5)
        let dividerHit = try await dispatchedC11PointerHit(in: window, at: dividerPointInWindow, host: host)
        XCTAssertNil(
            dividerHit,
            "Browser host must pass through divider hits even when one pane is nearly collapsed"
        )

        let contentPointInSplit = NSPoint(x: dividerPointInSplit.x + 40, y: splitView.bounds.midY)
        let contentPointInWindow = splitView.convert(contentPointInSplit, to: nil)
        let contentHit = try await dispatchedC11PointerHit(in: window, at: contentPointInWindow, host: host)
        XCTAssertTrue(contentHit === child, "Ordinary portal content must remain interactive under the same pointer dispatch")
    }

    func testWindowBrowserPortalIgnoresHostedInspectorSplitResizeNotifications() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let appSplit = NSSplitView(frame: contentView.bounds)
        appSplit.autoresizingMask = [.width, .height]
        appSplit.isVertical = true
        appSplit.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: contentView.bounds.height)))
        appSplit.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 299, height: contentView.bounds.height)))
        contentView.addSubview(appSplit)

        let inspectorSplit = NSSplitView(frame: host.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = true
        inspectorSplit.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 120, height: host.bounds.height)))
        inspectorSplit.addSubview(NSView(frame: NSRect(x: 121, y: 0, width: 299, height: host.bounds.height)))
        host.addSubview(inspectorSplit)

        XCTAssertTrue(
            WindowBrowserPortal.shouldTreatSplitResizeAsExternalGeometry(
                appSplit,
                window: window,
                hostView: host
            ),
            "App layout splits should still trigger browser portal geometry sync"
        )
        XCTAssertFalse(
            WindowBrowserPortal.shouldTreatSplitResizeAsExternalGeometry(
                inspectorSplit,
                window: window,
                hostView: host
            ),
            "Hosted DevTools/internal splits should not trigger browser portal geometry sync"
        )
    }

    func testDragHoverEventsPassThroughForTabTransferOnBrowserHoverEvents() {
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .cursorUpdate
            )
        )
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .mouseEntered
            )
        )
    }

    func testDragHoverEventsPassThroughForSidebarReorderWithoutMouseButtonState() {
        XCTAssertTrue(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [DragOverlayRoutingPolicy.sidebarWorkspaceReorderType],
                eventType: .cursorUpdate
            )
        )
    }

    func testDragHoverEventsDoNotPassThroughForUnrelatedPasteboardTypes() {
        XCTAssertFalse(
            WindowBrowserHostView.shouldPassThroughToDragTargets(
                pasteboardTypes: [.fileURL],
                eventType: .cursorUpdate
            )
        )
    }


    func testHostViewKeepsHostedVerticalInspectorDividerInteractiveAtSlotLeadingEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let inspectorSplit = NSSplitView(frame: slot.bounds)
        inspectorSplit.autoresizingMask = [.width, .height]
        inspectorSplit.isVertical = true
        inspectorSplit.dividerStyle = .thin
        let inspectorDelegate = BonsplitMockSplitDelegate()
        inspectorSplit.delegate = inspectorDelegate
        let pageView = CapturingView(frame: NSRect(x: 0, y: 0, width: 1, height: slot.bounds.height))
        let inspectorView = CapturingView(
            frame: NSRect(x: 2, y: 0, width: slot.bounds.width - 2, height: slot.bounds.height)
        )
        inspectorSplit.addSubview(pageView)
        inspectorSplit.addSubview(inspectorView)
        slot.addSubview(inspectorSplit)
        inspectorSplit.setPosition(1, ofDividerAt: 0)
        inspectorSplit.adjustSubviews()
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSplit = NSPoint(
            x: inspectorSplit.arrangedSubviews[0].frame.maxX + (inspectorSplit.dividerThickness * 0.5),
            y: inspectorSplit.bounds.midY
        )
        let dividerPointInWindow = inspectorSplit.convert(dividerPointInSplit, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertLessThanOrEqual(inspectorSplit.arrangedSubviews[0].frame.width, 1.5)
        XCTAssertTrue(
            abs(dividerPointInHost.x - slot.frame.minX) <= SidebarResizeInteraction.hitWidthPerSide,
            "Expected collapsed hosted divider to overlap the browser slot leading-edge resizer zone"
        )

        let hit = host.hitTest(dividerPointInHost)
        XCTAssertNotNil(
            hit,
            "Hosted vertical inspector divider should stay interactive even when collapsed onto the slot edge"
        )
        XCTAssertFalse(hit === host)
        if let hit {
            XCTAssertTrue(
                hit === inspectorSplit || hit.isDescendant(of: inspectorSplit),
                "Expected hit to remain inside hosted inspector split subtree at the slot edge"
            )
        }
    }

    func testHostViewPrefersNativeHostedInspectorSiblingDividerHit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: slot.bounds.height))
        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: slot.bounds.width - 92, height: slot.bounds.height)
        )
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let bodyPointInSlot = NSPoint(x: inspectorView.frame.minX + 18, y: slot.bounds.midY)
        let bodyPointInWindow = slot.convert(bodyPointInSlot, to: nil)
        let bodyPointInHost = host.convert(bodyPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Hosted right-docked inspector divider should stay on the native WebKit hit path when WebKit exposes a hittable inspector-side view. actual=\(String(describing: dividerHit))"
        )
        let interiorHit = host.hitTest(bodyPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(interiorHit, inspectorView: inspectorView, pageView: pageView),
            "Only the divider edge should be claimed; interior inspector hits should still reach WebKit content. actual=\(String(describing: interiorHit))"
        )
    }

    func testHostViewPrefersNativeNestedHostedInspectorSiblingDividerHit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let wrapper = NSView(frame: slot.bounds)
        wrapper.autoresizingMask = [.width, .height]
        slot.addSubview(wrapper)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: wrapper.bounds.height))
        let inspectorContainer = NSView(
            frame: NSRect(x: 92, y: 0, width: wrapper.bounds.width - 92, height: wrapper.bounds.height)
        )
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        wrapper.addSubview(pageView)
        wrapper.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorContainer.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)
        let bodyPointInSlot = NSPoint(x: inspectorContainer.frame.minX + 18, y: slot.bounds.midY)
        let bodyPointInWindow = slot.convert(bodyPointInSlot, to: nil)
        let bodyPointInHost = host.convert(bodyPointInWindow, from: nil)

        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Portal host should prefer the native nested WebKit hit target on the right-docked divider when available. actual=\(String(describing: dividerHit))"
        )
        let interiorHit = host.hitTest(bodyPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(interiorHit, inspectorView: inspectorView, pageView: pageView),
            "Only the divider edge should be claimed; interior nested inspector hits should still reach WebKit content. actual=\(String(describing: interiorHit))"
        )
    }

    func testHostViewReappliesStoredHostedInspectorWidthAfterSlotLayoutReset() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let wrapper = NSView(frame: slot.bounds)
        wrapper.autoresizingMask = [.width, .height]
        slot.addSubview(wrapper)

        let originalPageFrame = NSRect(x: 0, y: 0, width: 92, height: wrapper.bounds.height)
        let originalInspectorFrame = NSRect(
            x: 92,
            y: 0,
            width: wrapper.bounds.width - 92,
            height: wrapper.bounds.height
        )
        let pageView = PrimaryPageProbeView(frame: originalPageFrame)
        let inspectorContainer = NSView(frame: originalInspectorFrame)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        wrapper.addSubview(pageView)
        wrapper.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorContainer.frame.minX, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 48, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        let draggedPageWidth = pageView.frame.width
        let draggedInspectorMinX = inspectorContainer.frame.minX
        XCTAssertGreaterThan(draggedPageWidth, originalPageFrame.width)
        XCTAssertGreaterThan(draggedInspectorMinX, originalInspectorFrame.minX)

        pageView.frame = originalPageFrame
        inspectorContainer.frame = originalInspectorFrame
        slot.needsLayout = true
        slot.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageView.frame.width, draggedPageWidth, accuracy: 0.5)
        XCTAssertEqual(inspectorContainer.frame.minX, draggedInspectorMinX, accuracy: 0.5)
    }



    func testHostViewClaimsCollapsedHostedInspectorSiblingDividerAtSlotLeadingEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        guard let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        let hostFrame = container.convert(contentView.bounds, from: contentView)
        let host = WindowBrowserHostView(frame: hostFrame)
        host.autoresizingMask = [.width, .height]
        container.addSubview(host, positioned: .above, relativeTo: contentView)

        let slot = WindowBrowserSlotView(frame: NSRect(x: 180, y: 0, width: 240, height: host.bounds.height))
        slot.autoresizingMask = [.minXMargin, .height]
        host.addSubview(slot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 0, height: slot.bounds.height))
        let inspectorView = WKInspectorProbeView(frame: slot.bounds)
        slot.addSubview(pageView)
        slot.addSubview(inspectorView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInSlot = NSPoint(x: inspectorView.frame.minX + 2, y: slot.bounds.midY)
        let dividerPointInWindow = slot.convert(dividerPointInSlot, to: nil)
        let dividerPointInHost = host.convert(dividerPointInWindow, from: nil)

        XCTAssertLessThanOrEqual(dividerPointInHost.x - slot.frame.minX, SidebarResizeInteraction.hitWidthPerSide)
        let dividerHit = host.hitTest(dividerPointInHost)
        XCTAssertTrue(
            isInspectorOwnedHit(dividerHit, inspectorView: inspectorView, pageView: pageView),
            "Collapsed right-docked hosted inspector divider should stay on the native WebKit hit path while still beating the sidebar-resizer overlap zone. actual=\(String(describing: dividerHit))"
        )
    }
}


@MainActor
final class BrowserPanelHostContainerViewTests: XCTestCase {
    private final class PrimaryPageProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class TrackingInspectorFrontendWebView: WKWebView {
        private(set) var evaluatedJavaScript: [String] = []

        @MainActor override func evaluateJavaScript(
            _ javaScriptString: String,
            completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
        ) {
            evaluatedJavaScript.append(javaScriptString)
            completionHandler?(nil, nil)
        }
    }

    private final class WKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private final class EdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x <= 12 ? nil : self
        }
    }

    private final class TrailingEdgeTransparentWKInspectorProbeView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            let localPoint = convert(point, from: superview)
            guard bounds.contains(localPoint) else { return nil }
            return localPoint.x >= bounds.maxX - 12 ? nil : self
        }
    }

    private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) else {
            fatalError("Failed to create \(type) mouse event")
        }
        return event
    }

    func testBrowserPanelHostPrefersNativeHostedInspectorSiblingDividerHit() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = NSView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let bodyPointInHost = NSPoint(x: inspectorContainer.frame.minX + 18, y: host.bounds.midY)
        let interiorHit = host.hitTest(bodyPointInHost)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should claim the right-docked divider edge for the manual resize path"
        )
        XCTAssertTrue(
            interiorHit == nil || interiorHit !== host,
            "Only the divider edge should be claimed; interior inspector hits should not be stolen by the host. actual=\(String(describing: interiorHit))"
        )
    }

    func testBrowserPanelHostClaimsCollapsedHostedInspectorSiblingDividerAtLeadingEdge() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 0, height: webViewRoot.bounds.height))
        let inspectorContainer = NSView(frame: webViewRoot.bounds)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Collapsed right-docked divider should stay on the manual browser-panel resize path while beating the sidebar-resizer overlap"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 36, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(pageView.frame.width, 0)
        XCTAssertGreaterThan(inspectorContainer.frame.minX, 0)
    }

    func testBrowserPanelHostClaimsHostedInspectorDividerAcrossFullHeight() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 20, width: 92, height: webViewRoot.bounds.height - 40))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 20, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height - 40)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: 4)) === host,
            "The custom DevTools divider should remain draggable at the top edge of the browser pane"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.maxY - 4)) === host,
            "The custom DevTools divider should remain draggable at the bottom edge of the browser pane"
        )
    }

    func testBrowserPanelHostFallsBackToManualHostedInspectorDragWhenNativeDividerHitIsUnavailable() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should only take the manual fallback path when the divider edge is not natively hittable"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(pageView.frame.width, 92)
        XCTAssertGreaterThan(inspectorContainer.frame.minX, 92)
    }

    func testBrowserPanelHostKeepsInspectorResizableAfterShrinkingToMinimumWidth() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let pageView = PrimaryPageProbeView(frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height))
        let inspectorContainer = EdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 220, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThanOrEqual(
            inspectorContainer.frame.width,
            120,
            "Shrinking the DevTools pane should clamp to a recoverable minimum width"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: 4)) === host,
            "After clamping, the DevTools divider should still be draggable near the top edge"
        )
        XCTAssertTrue(
            host.hitTest(NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.maxY - 4)) === host,
            "After clamping, the DevTools divider should still be draggable near the bottom edge"
        )
    }

    func testBrowserPanelHostPromotesVisibleRightDockedInspectorIntoManagedSideDock() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height + 180))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded(),
            "A visible right-docked inspector should not wait on async dock-configuration JS before entering the managed side-dock path"
        )
        XCTAssertTrue(
            pageView.superview === inspectorView.superview && pageView.superview !== slotView,
            "Promotion should move both hosted inspector siblings into the managed side-dock container"
        )
        XCTAssertEqual(
            pageView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Promotion should normalize stale page heights to the host height so the page layer stops covering the divider"
        )
        XCTAssertEqual(
            inspectorView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Promotion should normalize the inspector height to the host height"
        )
    }

    func testBrowserPanelHostAllowsRightDockedInspectorToExpandLeftAfterPromotion() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded(),
            "The managed side-dock path should be active before drag assertions run"
        )

        let initialPageWidth = pageView.frame.width
        let initialInspectorWidth = inspectorView.frame.width
        let dividerPointInHost = NSPoint(x: inspectorView.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x - 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(
            inspectorView.frame.width,
            initialInspectorWidth,
            "Right-docked DevTools should expand when the divider is dragged left"
        )
        XCTAssertLessThan(
            pageView.frame.width,
            initialPageWidth,
            "Expanding right-docked DevTools should shrink the page width"
        )
    }

    func testBrowserPanelHostKeepsAutomaticRightDockedWidthAboveMinimumWhileShrinking() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 140, y: 0, width: 280, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 132, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 132, y: 0, width: slotView.bounds.width - 132, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        host.setPreferredHostedInspectorWidth(width: 80, widthFraction: nil)
        host.setFrameSize(NSSize(width: 210, height: host.frame.height))
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            inspectorView.frame.width,
            120,
            "Automatic pane resize should honor the same minimum hosted inspector width as manual dragging"
        )
        XCTAssertEqual(
            inspectorView.frame.height,
            host.bounds.height,
            accuracy: 0.5,
            "Automatic shrink should keep the inspector vertically normalized to the host height"
        )
    }

    func testBrowserPanelHostRequestsBottomDockWhenSideDockLeavesTooLittlePageWidth() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 280, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 120, height: host.bounds.height))
        let inspectorView = TrackingInspectorFrontendWebView(
            frame: NSRect(x: 120, y: 0, width: slotView.bounds.width - 120, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        host.setFrameSize(NSSize(width: 210, height: host.frame.height))
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            inspectorView.evaluatedJavaScript.contains(where: { $0.contains("WI._dockBottom()") }),
            "Narrow pane widths should request bottom-docked DevTools instead of leaving the side-docked inspector in an unstable layout"
        )
        XCTAssertTrue(
            inspectorView.evaluatedJavaScript.contains(where: { $0.contains("const allowSideDock = false;") }),
            "Once a narrow pane proves it cannot safely side-dock DevTools, the inspector frontend should hide and disable left/right dock controls"
        )
    }

    func testBrowserPanelManagedSideDockDoesNotAutoresizeDraggedFrames() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let slotView = host.ensureLocalInlineSlotView()
        let pageView = WKWebView(frame: NSRect(x: 0, y: 0, width: 92, height: host.bounds.height))
        let inspectorView = WKWebView(
            frame: NSRect(x: 92, y: 0, width: slotView.bounds.width - 92, height: host.bounds.height)
        )
        slotView.addSubview(pageView)
        slotView.addSubview(inspectorView)
        host.pinHostedWebView(pageView, in: slotView)
        host.setHostedInspectorFrontendWebView(inspectorView)
        contentView.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.promoteHostedInspectorSideDockFromCurrentLayoutIfNeeded())

        let dividerPointInHost = NSPoint(x: inspectorView.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)
        host.mouseDown(with: makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window))
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x - 30, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        guard let managedContainer = pageView.superview else {
            XCTFail("Expected managed side-dock container")
            return
        }
        let draggedPageFrame = pageView.frame
        let draggedInspectorFrame = inspectorView.frame

        managedContainer.setFrameSize(
            NSSize(width: managedContainer.frame.width, height: managedContainer.frame.height + 24)
        )

        XCTAssertEqual(
            pageView.frame.origin.x,
            draggedPageFrame.origin.x,
            accuracy: 0.5,
            "Managed side-dock container should not autoresize the page back to a stale divider position"
        )
        XCTAssertEqual(
            pageView.frame.width,
            draggedPageFrame.width,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged page width until the host explicitly reapplies layout"
        )
        XCTAssertEqual(
            inspectorView.frame.origin.x,
            draggedInspectorFrame.origin.x,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged inspector origin"
        )
        XCTAssertEqual(
            inspectorView.frame.width,
            draggedInspectorFrame.width,
            accuracy: 0.5,
            "Managed side-dock container should preserve the dragged inspector width"
        )
    }

    func testBrowserPanelHostFallsBackToManualHostedInspectorDragForLeftDockedInspector() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height))
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let inspectorContainer = TrailingEdgeTransparentWKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height)
        )
        let pageView = PrimaryPageProbeView(
            frame: NSRect(x: 92, y: 0, width: webViewRoot.bounds.width - 92, height: webViewRoot.bounds.height)
        )
        webViewRoot.addSubview(inspectorContainer)
        webViewRoot.addSubview(pageView)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.maxX - 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        XCTAssertTrue(
            host.hitTest(dividerPointInHost) === host,
            "Browser panel host should take the manual fallback path for a left-docked divider when the native edge is not hittable"
        )

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 40, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        XCTAssertGreaterThan(inspectorContainer.frame.width, 92)
        XCTAssertGreaterThan(pageView.frame.minX, 92)
    }

    func testBrowserPanelHostReappliesStoredHostedInspectorWidthAfterLayoutReset() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let host = WebViewRepresentable.HostContainerView(
            frame: NSRect(x: 180, y: 0, width: 240, height: contentView.bounds.height)
        )
        host.autoresizingMask = [.minXMargin, .height]
        contentView.addSubview(host)

        let webViewRoot = NSView(frame: host.bounds)
        webViewRoot.autoresizingMask = [.width, .height]
        host.addSubview(webViewRoot)

        let originalPageFrame = NSRect(x: 0, y: 0, width: 92, height: webViewRoot.bounds.height)
        let originalInspectorFrame = NSRect(
            x: 92,
            y: 0,
            width: webViewRoot.bounds.width - 92,
            height: webViewRoot.bounds.height
        )
        let pageView = PrimaryPageProbeView(frame: originalPageFrame)
        let inspectorContainer = NSView(frame: originalInspectorFrame)
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        webViewRoot.addSubview(pageView)
        webViewRoot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        let dividerPointInHost = NSPoint(x: inspectorContainer.frame.minX + 2, y: host.bounds.midY)
        let dividerPointInWindow = host.convert(dividerPointInHost, to: nil)

        let down = makeMouseEvent(type: .leftMouseDown, location: dividerPointInWindow, window: window)
        host.mouseDown(with: down)
        let drag = makeMouseEvent(
            type: .leftMouseDragged,
            location: NSPoint(x: dividerPointInWindow.x + 48, y: dividerPointInWindow.y),
            window: window
        )
        host.mouseDragged(with: drag)
        host.mouseUp(with: makeMouseEvent(type: .leftMouseUp, location: drag.locationInWindow, window: window))

        let draggedPageWidth = pageView.frame.width
        let draggedInspectorMinX = inspectorContainer.frame.minX
        XCTAssertGreaterThan(draggedPageWidth, originalPageFrame.width)
        XCTAssertGreaterThan(draggedInspectorMinX, originalInspectorFrame.minX)

        pageView.frame = originalPageFrame
        inspectorContainer.frame = originalInspectorFrame
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(pageView.frame.width, draggedPageWidth, accuracy: 0.5)
        XCTAssertEqual(inspectorContainer.frame.minX, draggedInspectorMinX, accuracy: 0.5)
    }

    func testWindowBrowserSlotPinsHostedWebViewWithAutoresizingForAttachedInspector() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let webView = WKWebView(frame: .zero)
        slot.addSubview(webView)

        slot.pinHostedWebView(webView)
        slot.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        slot.layoutSubtreeIfNeeded()

        XCTAssertTrue(webView.translatesAutoresizingMaskIntoConstraints)
        XCTAssertEqual(webView.autoresizingMask, [.width, .height])
        XCTAssertEqual(webView.frame, slot.bounds)
    }

    func testWindowBrowserSlotReattachesPlainWebViewAtFullBoundsAfterHiddenHostResize() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        let webView = WKWebView(frame: .zero)
        slot.addSubview(webView)
        slot.pinHostedWebView(webView)
        XCTAssertEqual(webView.frame, slot.bounds)

        let externalHost = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        webView.removeFromSuperview()
        externalHost.addSubview(webView)
        webView.frame = externalHost.bounds
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.autoresizingMask = [.width, .height]

        slot.addSubview(webView)
        slot.pinHostedWebView(webView)

        slot.frame = NSRect(x: 0, y: 0, width: 300, height: 180)
        slot.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            webView.frame,
            slot.bounds,
            "Reattaching a plain web view should restore full-bounds hosting instead of preserving a stale inset frame from a hidden host"
        )
    }
}


@MainActor
final class BrowserAreaDropRoutingTests: XCTestCase {
    func testVerticalZonesFollowAppKitCoordinates() {
        let size = CGSize(width: 240, height: 180)

        XCTAssertEqual(
            BrowserAreaDropRouting.zone(for: CGPoint(x: size.width * 0.5, y: size.height - 8), in: size),
            .top
        )
        XCTAssertEqual(
            BrowserAreaDropRouting.zone(for: CGPoint(x: size.width * 0.5, y: 8), in: size),
            .bottom
        )
    }

    func testTopChromeHeightPushesTopSplitThresholdIntoWebView() {
        let size = CGSize(width: 240, height: 180)

        XCTAssertEqual(
            BrowserAreaDropRouting.zone(
                for: CGPoint(x: size.width * 0.5, y: 110),
                in: size,
                topChromeHeight: 36
            ),
            .center
        )
        XCTAssertEqual(
            BrowserAreaDropRouting.zone(
                for: CGPoint(x: size.width * 0.5, y: 150),
                in: size,
                topChromeHeight: 36
            ),
            .top
        )
    }

    func testHitTestingCapturesOnlyForRelevantDragEvents() {
        XCTAssertTrue(
            BrowserAreaDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .cursorUpdate
            )
        )
        XCTAssertFalse(
            BrowserAreaDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [DragOverlayRoutingPolicy.bonsplitTabTransferType],
                eventType: .leftMouseDown
            )
        )
        XCTAssertFalse(
            BrowserAreaDropTargetView.shouldCaptureHitTesting(
                pasteboardTypes: [.fileURL],
                eventType: .cursorUpdate
            )
        )
    }

    func testCenterDropOnSamePaneIsNoOp() {
        let paneId = PaneID(id: UUID())
        let target = BrowserAreaDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: paneId
        )
        let transfer = BrowserAreaDragTransfer(
            bonsplitTabId: UUID(),
            sourcePaneId: paneId.id,
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        XCTAssertEqual(
            BrowserAreaDropRouting.action(for: transfer, target: target, zone: .center),
            .noOp
        )
    }

    func testRightEdgeDropBuildsSplitMoveAction() {
        let paneId = PaneID(id: UUID())
        let target = BrowserAreaDropContext(
            workspaceId: UUID(),
            panelId: UUID(),
            paneId: paneId
        )
        let bonsplitTabId = UUID()
        let transfer = BrowserAreaDragTransfer(
            bonsplitTabId: bonsplitTabId,
            sourcePaneId: UUID(),
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )

        XCTAssertEqual(
            BrowserAreaDropRouting.action(for: transfer, target: target, zone: .right),
            .move(
                bonsplitTabId: bonsplitTabId,
                targetWorkspaceId: target.workspaceId,
                targetPane: paneId,
                splitTarget: BrowserAreaSplitTarget(orientation: .horizontal, insertFirst: false)
            )
        )
    }

    func testDecodeTransferPayloadReadsTabAndSourceArea() {
        let bonsplitTabId = UUID()
        let sourcePaneId = UUID()
        let payload = try! JSONSerialization.data(
            withJSONObject: [
                "tab": ["id": bonsplitTabId.uuidString],
                "sourcePaneId": sourcePaneId.uuidString,
                "sourceProcessId": ProcessInfo.processInfo.processIdentifier,
            ]
        )

        let transfer = BrowserAreaDragTransfer.decode(from: payload)

        XCTAssertEqual(transfer?.bonsplitTabId, bonsplitTabId)
        XCTAssertEqual(transfer?.sourcePaneId, sourcePaneId)
        XCTAssertTrue(transfer?.isFromCurrentProcess == true)
    }
}


@MainActor
final class WindowBrowserSlotViewTests: XCTestCase {
    private final class CapturingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    func testDropZoneOverlayStaysAboveContentWithoutBlockingHits() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let slot = WindowBrowserSlotView(frame: container.bounds)
        container.addSubview(slot)
        let child = CapturingView(frame: slot.bounds)
        child.autoresizingMask = [.width, .height]
        slot.addSubview(child)

        slot.setDropZoneOverlay(zone: .right)
        container.layoutSubtreeIfNeeded()

        guard let overlay = container.subviews.first(where: {
            $0 !== slot && String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        }) else {
            XCTFail("Expected browser slot drop-zone overlay")
            return
        }

        XCTAssertTrue(container.subviews.last === overlay, "Overlay should stay above the hosted web view")
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.frame.origin.x, 100, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 96, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 92, accuracy: 0.5)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 120, y: 50)), "Overlay should never intercept pointer hits")
        XCTAssertTrue(slot.hitTest(NSPoint(x: 120, y: 50)) === child)

        slot.setDropZoneOverlay(zone: nil)
        advanceAnimations()
        XCTAssertTrue(overlay.isHidden, "Clearing the drop zone should hide the overlay")
    }

    func testTopDropZoneOverlayUsesFullBrowserContentHeight() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let slot = WindowBrowserSlotView(frame: container.bounds)
        container.addSubview(slot)

        slot.setPaneTopChromeHeight(20)
        slot.setDropZoneOverlay(zone: .top)
        container.layoutSubtreeIfNeeded()

        guard let overlay = container.subviews.first(where: {
            String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        }) else {
            XCTFail("Expected browser slot drop-zone overlay")
            return
        }

        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.frame.origin.x, 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, 60, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 192, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 56, accuracy: 0.5)
        XCTAssertGreaterThan(overlay.frame.maxY, slot.frame.maxY)
        XCTAssertEqual(slot.layer?.masksToBounds, true)

        slot.setDropZoneOverlay(zone: nil)
        advanceAnimations()
        XCTAssertEqual(slot.layer?.masksToBounds, true)
    }
}


@MainActor
final class BrowserWindowPortalLifecycleTests: XCTestCase {
    private final class TrackingPortalWebView: WKWebView {
        private(set) var displayIfNeededCount = 0
        private(set) var displayInvalidationCount = 0
        private(set) var reattachRenderingStateCount = 0

        override func setNeedsDisplay(_ invalidRect: NSRect) {
            displayInvalidationCount += 1
            super.setNeedsDisplay(invalidRect)
        }

        override func displayIfNeeded() {
            displayIfNeededCount += 1
            super.displayIfNeeded()
        }

        @objc(_enterInWindow)
        func cmuxUnitTestEnterInWindow() {
            reattachRenderingStateCount += 1
        }

        @objc(_endDeferringViewInWindowChangesSync)
        func cmuxUnitTestEndDeferringViewInWindowChangesSync() {
            reattachRenderingStateCount += 1
        }
    }

    private final class WKInspectorProbeView: NSView {}

    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    private func dropZoneOverlay(in slot: WindowBrowserSlotView, excluding webView: WKWebView) -> NSView? {
        let candidates = slot.subviews + (slot.superview?.subviews ?? [])
        return candidates.first(where: {
            $0 !== slot &&
            $0 !== webView &&
            String(describing: type(of: $0)).contains("BrowserDropZoneOverlayView")
        })
    }

    func testPortalHostInstallsAboveContentViewForVisibility() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let portal = WindowBrowserPortal(window: window)
        _ = portal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        guard let hostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }),
              let contentIndex = container.subviews.firstIndex(where: { $0 === contentView }) else {
            XCTFail("Expected host/content views in same container")
            return
        }

        XCTAssertGreaterThan(
            hostIndex,
            contentIndex,
            "Browser portal host must remain above content view so portal-hosted web views stay visible"
        )
    }

    func testBrowserPortalHostStaysAboveTerminalPortalHostDuringPortalChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)

        let browserPortal = WindowBrowserPortal(window: window)
        let terminalPortal = WindowTerminalPortal(window: window)
        _ = browserPortal.webViewAtWindowPoint(NSPoint(x: 1, y: 1))
        _ = terminalPortal.viewAtWindowPoint(NSPoint(x: 1, y: 1))

        guard let contentView = window.contentView,
              let container = contentView.superview else {
            XCTFail("Expected content container")
            return
        }

        func assertHostOrder(_ message: String) {
            guard let browserHostIndex = container.subviews.firstIndex(where: { $0 is WindowBrowserHostView }),
                  let terminalHostIndex = container.subviews.firstIndex(where: { $0 is WindowTerminalHostView }) else {
                XCTFail("Expected both portal hosts in same container")
                return
            }

            XCTAssertGreaterThan(
                browserHostIndex,
                terminalHostIndex,
                message
            )
        }

        assertHostOrder("Browser portal host should start above terminal portal host")

        let terminalAnchor = NSView(frame: NSRect(x: 20, y: 20, width: 200, height: 140))
        contentView.addSubview(terminalAnchor)
        let terminalHostedView = GhosttySurfaceScrollView(
            surfaceView: GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        )
        terminalPortal.bind(hostedView: terminalHostedView, to: terminalAnchor, visibleInUI: true)
        terminalPortal.synchronizeHostedViewForAnchor(terminalAnchor)
        assertHostOrder("Terminal portal sync should not rise above the browser portal host")

        let browserAnchor = NSView(frame: NSRect(x: 240, y: 20, width: 220, height: 140))
        contentView.addSubview(browserAnchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        browserPortal.bind(webView: webView, to: browserAnchor, visibleInUI: true)
        browserPortal.synchronizeWebViewForAnchor(browserAnchor)
        assertHostOrder("Browser portal sync should keep browser panes above portal-hosted terminals")
    }

    func testAnchorRebindKeepsWebViewInStablePortalSuperview() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor1 = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        let anchor2 = NSView(frame: NSRect(x: 240, y: 40, width: 180, height: 120))
        contentView.addSubview(anchor1)
        contentView.addSubview(anchor2)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor1, visibleInUI: true)
        let firstSuperview = webView.superview

        XCTAssertNotNil(firstSuperview)
        XCTAssertTrue(firstSuperview is WindowBrowserSlotView)

        portal.bind(webView: webView, to: anchor2, visibleInUI: true)
        XCTAssertTrue(webView.superview === firstSuperview, "Anchor moves should not reparent the web view")

        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor2)
        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected browser slot + host views")
            return
        }
        let expectedFrame = host.convert(anchor2.bounds, from: anchor2)
        XCTAssertEqual(slot.frame.origin.x, expectedFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, expectedFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, expectedFrame.size.width, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, expectedFrame.size.height, accuracy: 0.5)
    }

    func testPortalClampsWebViewFrameToHostBoundsWhenAnchorOverflowsSidebar() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        // Simulate a transient oversized anchor rect during split churn.
        let anchor = NSView(frame: NSRect(x: 120, y: 20, width: 260, height: 150))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected web view slot")
            return
        }

        XCTAssertFalse(slot.isHidden, "Partially visible browser anchor should stay visible")
        XCTAssertEqual(slot.frame.origin.x, 120, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 20, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 150, accuracy: 0.5)
    }

    func testPortalClipsAnchorFrameThroughAncestorBounds() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let clipView = NSView(frame: NSRect(x: 60, y: 40, width: 150, height: 120))
        contentView.addSubview(clipView)

        // Simulate SwiftUI/AppKit reporting an anchor wider than the actual visible pane.
        let anchor = NSView(frame: NSRect(x: -30, y: 0, width: 220, height: 120))
        clipView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        clipView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        XCTAssertFalse(slot.isHidden, "Ancestor clipping should keep the browser visible in the real pane")
        XCTAssertEqual(slot.frame.origin.x, 60, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 40, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 150, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 120, accuracy: 0.5)
    }

    func testPortalSyncNormalizesOutOfBoundsWebFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 20, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        // Reproduce observed drift from logs where WebKit shifts/expands frame beyond slot bounds.
        webView.frame = NSRect(x: 0, y: 250, width: slot.bounds.width, height: slot.bounds.height)
        XCTAssertGreaterThan(webView.frame.maxY, slot.bounds.maxY)

        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertEqual(webView.frame.origin.x, slot.bounds.origin.x, accuracy: 0.5)
        XCTAssertEqual(webView.frame.origin.y, slot.bounds.origin.y, accuracy: 0.5)
        XCTAssertEqual(webView.frame.size.width, slot.bounds.size.width, accuracy: 0.5)
        XCTAssertEqual(webView.frame.size.height, slot.bounds.size.height, accuracy: 0.5)
    }

    func testPortalSlotPinPreservesSideDockedInspectorManagedWebViewFrameOnRehost() {
        let slot = WindowBrowserSlotView(frame: NSRect(x: 0, y: 0, width: 240, height: 160))
        let webView = CmuxWebView(frame: NSRect(x: 0, y: 0, width: 132, height: 160), configuration: WKWebViewConfiguration())
        let inspectorContainer = NSView(frame: NSRect(x: 132, y: 0, width: 108, height: 160))
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(webView)
        slot.addSubview(inspectorContainer)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.autoresizingMask = []
        slot.pinHostedWebView(webView)

        XCTAssertEqual(
            webView.frame.maxX,
            inspectorContainer.frame.minX,
            accuracy: 0.5,
            "Rehosting a portal-managed browser should preserve the WebKit-owned side inspector split"
        )
        XCTAssertLessThan(
            webView.frame.width,
            slot.bounds.width,
            "The page frame should stay narrower than the full slot while a side-docked inspector is present"
        )
    }

    func testPortalResizePreservesSideDockedInspectorManagedWebViewFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialInspectorWidth: CGFloat = 110
        let inspectorContainer = NSView(
            frame: NSRect(
                x: slot.bounds.width - initialInspectorWidth,
                y: 0,
                width: initialInspectorWidth,
                height: slot.bounds.height
            )
        )
        inspectorContainer.autoresizingMask = [.minXMargin, .height]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)

        webView.frame = NSRect(
            x: 0,
            y: 0,
            width: slot.bounds.width - initialInspectorWidth,
            height: slot.bounds.height
        )
        webView.autoresizingMask = [.width, .height]
        slot.layoutSubtreeIfNeeded()

        anchor.frame = NSRect(x: 40, y: 24, width: 220, height: 180)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertFalse(slot.isHidden, "Resizing the browser pane should keep the hosted browser visible")
        XCTAssertEqual(
            webView.frame.maxX,
            inspectorContainer.frame.minX,
            accuracy: 0.5,
            "Portal sync should preserve the side-docked inspector split instead of stretching the page back over the inspector"
        )
        XCTAssertLessThan(
            webView.frame.width,
            slot.bounds.width,
            "Side-docked inspector should still own part of the slot after pane resize"
        )
    }

    func testPortalAnchorResizeDoesNotForceHostedWebViewPresentationRefresh() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialDisplayCount = webView.displayInvalidationCount
        let initialReattachCount = webView.reattachRenderingStateCount
        anchor.frame = NSRect(x: 52, y: 30, width: 248, height: 178)
        contentView.layoutSubtreeIfNeeded()
        let forcedDisplayCount = webView.displayIfNeededCount
        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertEqual(webView.displayIfNeededCount, forcedDisplayCount,
                       "Portal synchronization must request repaint without forcing display")
        advanceAnimations()

        XCTAssertFalse(slot.isHidden, "Anchor resize should keep the portal-hosted browser visible")
        XCTAssertEqual(slot.frame.origin.x, 52, accuracy: 0.5)
        XCTAssertEqual(slot.frame.origin.y, 30, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.width, 248, accuracy: 0.5)
        XCTAssertEqual(slot.frame.size.height, 178, accuracy: 0.5)
        XCTAssertGreaterThan(
            webView.displayInvalidationCount,
            initialDisplayCount,
            "Pure anchor geometry updates should request repaint of the hosted browser"
        )
        XCTAssertEqual(
            webView.reattachRenderingStateCount,
            initialReattachCount,
            "Pure anchor geometry updates should not trigger the WebKit reattach path"
        )
    }

    func testExternalSplitResizeDoesNotForceHostedWebViewPresentationRefresh() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let splitView = NSSplitView(frame: contentView.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.isVertical = true

        let leadingPane = NSView(
            frame: NSRect(x: 0, y: 0, width: 220, height: contentView.bounds.height)
        )
        leadingPane.autoresizingMask = [.height]
        let trailingPane = NSView(
            frame: NSRect(
                x: 221,
                y: 0,
                width: contentView.bounds.width - 221,
                height: contentView.bounds.height
            )
        )
        trailingPane.autoresizingMask = [.width, .height]
        splitView.addSubview(leadingPane)
        splitView.addSubview(trailingPane)
        contentView.addSubview(splitView)
        splitView.adjustSubviews()

        let anchor = NSView(frame: trailingPane.bounds.insetBy(dx: 12, dy: 12))
        anchor.autoresizingMask = [.width, .height]
        trailingPane.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        let forcedDisplayCount = webView.displayIfNeededCount
        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertEqual(webView.displayIfNeededCount, forcedDisplayCount,
                       "Portal synchronization must request repaint without forcing display")
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let initialDisplayCount = webView.displayInvalidationCount
        let initialReattachCount = webView.reattachRenderingStateCount
        let initialWidth = slot.frame.width

        splitView.setPosition(280, ofDividerAt: 0)
        contentView.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        advanceAnimations()

        XCTAssertFalse(slot.isHidden, "App split resize should keep the browser slot visible")
        XCTAssertLessThan(
            slot.frame.width,
            initialWidth,
            "Moving the app split divider should shrink the hosted browser slot"
        )
        XCTAssertGreaterThan(
            webView.displayInvalidationCount,
            initialDisplayCount,
            "External split resize should request repaint of the hosted browser"
        )
        XCTAssertEqual(
            webView.reattachRenderingStateCount,
            initialReattachCount,
            "External split resize should not trigger the WebKit reattach path"
        )
    }

    func testPortalSyncRepairsBottomDockedInspectorOverflowedPageFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let inspectorHeight: CGFloat = 84
        let inspectorContainer = NSView(
            frame: NSRect(x: 0, y: 0, width: slot.bounds.width, height: inspectorHeight)
        )
        inspectorContainer.autoresizingMask = [.width]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)

        webView.frame = NSRect(
            x: 0,
            y: inspectorHeight,
            width: slot.bounds.width,
            height: slot.bounds.height
        )
        webView.autoresizingMask = [.width, .height]
        slot.layoutSubtreeIfNeeded()

        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertFalse(slot.isHidden, "Portal sync should keep the hosted browser visible")
        XCTAssertEqual(
            webView.frame.minY,
            inspectorHeight,
            accuracy: 0.5,
            "Portal sync should keep the page viewport below a bottom-docked inspector instead of shifting the page upward"
        )
        XCTAssertEqual(
            webView.frame.height,
            slot.bounds.height - inspectorHeight,
            accuracy: 0.5,
            "Portal sync should shrink the page viewport to the space above a bottom-docked inspector"
        )
        XCTAssertEqual(
            webView.frame.maxY,
            slot.bounds.maxY,
            accuracy: 0.5,
            "The repaired page viewport should stay flush with the top edge of the slot"
        )
    }

    func testHidingBrowserSlotYieldsOwnedInspectorFirstResponder() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let slot = WindowBrowserSlotView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(slot)

        let inspectorContainer = NSView(frame: slot.bounds)
        inspectorContainer.autoresizingMask = [.width, .height]
        let inspectorView = WKInspectorProbeView(frame: inspectorContainer.bounds)
        inspectorView.autoresizingMask = [.width, .height]
        inspectorContainer.addSubview(inspectorView)
        slot.addSubview(inspectorContainer)
        contentView.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            window.makeFirstResponder(inspectorView),
            "Precondition failed: inspector probe should become first responder"
        )
        XCTAssertTrue(window.firstResponder === inspectorView)

        slot.isHidden = true

        XCTAssertFalse(
            window.firstResponder === inspectorView,
            "Hiding a browser slot should yield any owned inspector responder before it goes off-screen"
        )
        if let firstResponderView = window.firstResponder as? NSView {
            XCTAssertFalse(
                firstResponderView === slot || firstResponderView.isDescendant(of: slot),
                "Hiding a browser slot should not leave first responder inside the hidden slot"
            )
        }
    }

    func testHiddenPortalSyncDoesNotStealLocallyHostedDevToolsWebViewDuringResize() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 260, height: 180))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        contentView.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let hiddenPortalSlot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        XCTAssertTrue(hiddenPortalSlot.isHidden, "Hidden portal entry should keep its slot hidden")

        let localInlineSlot = WindowBrowserSlotView(frame: anchor.frame)
        contentView.addSubview(localInlineSlot)

        let inspectorView = WKInspectorProbeView(
            frame: NSRect(x: 0, y: 0, width: localInlineSlot.bounds.width, height: 72)
        )
        inspectorView.autoresizingMask = [.width]
        localInlineSlot.addSubview(inspectorView)

        localInlineSlot.addSubview(webView)
        webView.frame = NSRect(
            x: 0,
            y: inspectorView.frame.maxY,
            width: localInlineSlot.bounds.width,
            height: localInlineSlot.bounds.height - inspectorView.frame.height
        )
        localInlineSlot.layoutSubtreeIfNeeded()

        anchor.frame = NSRect(x: 40, y: 24, width: 220, height: 180)
        localInlineSlot.frame = anchor.frame
        contentView.layoutSubtreeIfNeeded()
        localInlineSlot.layoutSubtreeIfNeeded()
        portal.synchronizeWebViewForAnchor(anchor)

        XCTAssertTrue(
            webView.superview === localInlineSlot,
            "Hidden portal sync should not steal a DevTools-hosted web view back out of local inline hosting during pane resize"
        )
        XCTAssertTrue(
            inspectorView.superview === localInlineSlot,
            "Hidden portal sync should leave local DevTools companion views in the local inline host"
        )
        XCTAssertTrue(hiddenPortalSlot.isHidden, "The retiring hidden portal slot should stay hidden during local inline hosting")
    }

    func testPortalHostBoundsBecomeReadyAfterBindingInFrameDrivenHierarchy() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView,
              let host = slot.superview as? WindowBrowserHostView else {
            XCTFail("Expected portal slot + host views")
            return
        }
        XCTAssertGreaterThan(host.bounds.width, 1, "Portal host width should be ready for clipping/sync")
        XCTAssertGreaterThan(host.bounds.height, 1, "Portal host height should be ready for clipping/sync")
    }

    func testPortalDropZoneOverlayPersistsAcrossVisibilityChanges() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)

        guard let slot = webView.superview as? WindowBrowserSlotView,
              let overlay = dropZoneOverlay(in: slot, excluding: webView) else {
            XCTFail("Expected browser slot overlay")
            return
        }

        XCTAssertTrue(overlay.isHidden, "Overlay should start hidden without an active drop zone")

        portal.updateDropZoneOverlay(forWebViewId: ObjectIdentifier(webView), zone: .right)
        slot.layoutSubtreeIfNeeded()
        XCTAssertFalse(overlay.isHidden)
        XCTAssertTrue(slot.superview?.subviews.last === overlay, "Overlay should remain above the hosted web view")
        XCTAssertEqual(overlay.frame.origin.x, slot.frame.origin.x + 110, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.origin.y, slot.frame.origin.y + 4, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.width, 106, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.size.height, 152, accuracy: 0.5)

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        XCTAssertTrue(overlay.isHidden, "Invisible browser entries should hide the overlay")

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: true, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        XCTAssertFalse(overlay.isHidden, "Restoring visibility should restore the active drop-zone overlay")
    }

    func testPortalRevealInvalidatesWithoutWebKitLifecycleChurn() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        let anchor = NSView(frame: NSRect(x: 40, y: 24, width: 220, height: 160))
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        let initialDisplayCount = webView.displayInvalidationCount
        let initialReattachCount = webView.reattachRenderingStateCount

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()
        let hiddenDisplayCount = webView.displayInvalidationCount
        let hiddenReattachCount = webView.reattachRenderingStateCount

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: true, zPriority: 0)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertGreaterThanOrEqual(hiddenDisplayCount, initialDisplayCount)
        XCTAssertEqual(
            hiddenReattachCount,
            initialReattachCount,
            "Hiding a portal-hosted browser should not itself trigger the WebKit reattach path"
        )
        XCTAssertGreaterThan(
            webView.displayInvalidationCount,
            hiddenDisplayCount,
            "Revealing an existing portal-hosted browser should request repaint without forcing display"
        )
        XCTAssertEqual(
            webView.reattachRenderingStateCount,
            hiddenReattachCount,
            "Ordinary tab visibility must repaint without WebKit lifecycle callbacks that can reload the page"
        )
    }

    func testVisiblePortalEntryPreservesPresentationDuringTransientAnchorRemovalUntilRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let anchor1 = NSView(frame: anchorFrame)
        contentView.addSubview(anchor1)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor1, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor1)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        anchor1.removeFromSuperview()
        portal.synchronizeWebViewForAnchor(anchor1)

        XCTAssertTrue(webView.superview === slot, "Visible browser entries should not detach during transient anchor removal")
        XCTAssertFalse(
            slot.isHidden,
            "Transient anchor churn preserves presentation during the bounded recovery window"
        )
        XCTAssertEqual(portal.debugEntryCount(), 1)

        let displayCountBeforeRebind = webView.displayInvalidationCount
        let anchor2 = NSView(frame: anchorFrame)
        contentView.addSubview(anchor2)
        portal.bind(webView: webView, to: anchor2, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor2)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Rebinding after transient anchor removal should reuse the existing portal slot")
        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(portal.debugEntryCount(), 1)
        XCTAssertGreaterThan(
            webView.displayInvalidationCount,
            displayCountBeforeRebind,
            "Anchor rebinds should refresh hosted browser presentation even when geometry is unchanged"
        )
    }

    func testVisiblePortalEntryStaysVisibleDuringOffWindowAnchorReparentUntilRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let anchor = NSView(frame: anchorFrame)
        contentView.addSubview(anchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: anchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        let offWindowContainer = NSView(frame: anchorFrame)
        anchor.removeFromSuperview()
        offWindowContainer.addSubview(anchor)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Off-window anchor reparent should preserve the hosted browser slot during drag churn"
        )
        XCTAssertFalse(
            slot.isHidden,
            "Off-window anchor reparent should keep the visible browser portal alive until the anchor returns"
        )
        XCTAssertEqual(portal.debugEntryCount(), 1)

        contentView.addSubview(anchor)
        portal.synchronizeWebViewForAnchor(anchor)
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Rebinding after off-window reparent should reuse the existing portal slot")
        XCTAssertFalse(slot.isHidden)
        XCTAssertEqual(portal.debugEntryCount(), 1)
    }

    func testRegistryDetachRemovesPortalHostedWebView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        XCTAssertNotNil(webView.superview)

        BrowserWindowPortalRegistry.detach(webView: webView)
        XCTAssertNil(webView.superview)
    }

    func testRegistryHideKeepsPortalHostedWebViewAttachedButHidden() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }
        XCTAssertFalse(slot.isHidden)

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()

        XCTAssertTrue(webView.superview === slot, "Hiding should preserve the hosted WKWebView attachment")
        XCTAssertTrue(slot.isHidden, "Hiding should immediately hide the existing portal slot")
    }

    func testHiddenPortalEntrySurvivesAnchorRemovalUntilWorkspaceRebind() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let portal = WindowBrowserPortal(window: window)

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let anchorFrame = NSRect(x: 40, y: 24, width: 220, height: 160)
        let oldAnchor = NSView(frame: anchorFrame)
        contentView.addSubview(oldAnchor)

        let webView = TrackingPortalWebView(frame: .zero, configuration: WKWebViewConfiguration())
        portal.bind(webView: webView, to: oldAnchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected browser slot")
            return
        }

        portal.updateEntryVisibility(forWebViewId: ObjectIdentifier(webView), visibleInUI: false, zPriority: 0)
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()
        XCTAssertTrue(slot.isHidden, "Workspace handoff should hide the retiring browser before unmount")

        oldAnchor.removeFromSuperview()
        portal.synchronizeWebViewForAnchor(oldAnchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Hidden workspace browsers should stay attached while their SwiftUI anchor is temporarily unmounted"
        )
        XCTAssertTrue(slot.isHidden, "Unmounted hidden workspace browser should remain hidden until rebound")
        XCTAssertEqual(portal.debugEntryCount(), 1, "Workspace handoff should keep the hidden browser portal entry alive")

        let displayCountBeforeRebind = webView.displayInvalidationCount
        let newAnchor = NSView(frame: anchorFrame)
        contentView.addSubview(newAnchor)
        portal.bind(webView: webView, to: newAnchor, visibleInUI: true)
        portal.synchronizeWebViewForAnchor(newAnchor)
        advanceAnimations()

        XCTAssertTrue(
            webView.superview === slot,
            "Selecting the workspace again should reuse the existing hidden browser portal slot"
        )
        XCTAssertFalse(slot.isHidden, "Rebinding the workspace browser should reveal the existing portal slot")
        XCTAssertEqual(portal.debugEntryCount(), 1)
        XCTAssertGreaterThan(
            webView.displayInvalidationCount,
            displayCountBeforeRebind,
            "Workspace rebind should refresh the preserved browser without recreating its portal slot"
        )
    }
}
