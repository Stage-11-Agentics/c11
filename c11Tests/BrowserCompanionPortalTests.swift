import XCTest
import WebKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

@MainActor
final class BrowserCompanionPortalTests: XCTestCase {
    private let linkedAgent = AgentDescriptor(
        identity: CompanionSurfaceIdentity(
            surfaceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            surfaceRef: "surface:11",
            surfaceOrdinal: 11,
            displayName: "Linked Agent"
        ),
        terminalKind: "codex"
    )
    private let activeAgent = AgentDescriptor(
        identity: CompanionSurfaceIdentity(
            surfaceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            surfaceRef: "surface:22",
            surfaceOrdinal: 22,
            displayName: "Active Agent"
        ),
        terminalKind: "claude"
    )

    func testVeilBlocksHitTestingHidesWebKitAccessibilityAndRestoresExactStateAndResponder() {
        let (window, slot, webView) = makeWindowSlotAndWebView()
        defer { window.orderOut(nil) }

        let inspector = CompanionWKInspectorResponderView(frame: slot.bounds)
        inspector.setAccessibilityHidden(true)
        slot.addSubview(inspector)
        XCTAssertTrue(window.makeFirstResponder(inspector))

        slot.setCompanion(configuration(for: .veiled(linked: linkedAgent, active: activeAgent)))

        guard let overlay = companionOverlay(in: slot) else {
            XCTFail("Expected an AppKit companion veil")
            return
        }
        XCTAssertFalse(overlay.isHidden)
        let hit = slot.hitTest(NSPoint(x: slot.bounds.midX, y: slot.bounds.midY))
        XCTAssertTrue(hit === overlay || hit?.isDescendant(of: overlay) == true)
        XCTAssertFalse(hit === webView)
        XCTAssertTrue(webView.isAccessibilityHidden())
        XCTAssertTrue(inspector.isAccessibilityHidden())
        let firstResponderView = owningView(for: window.firstResponder)
        XCTAssertTrue(
            window.firstResponder === overlay ||
                firstResponderView?.isDescendant(of: overlay) == true
        )

        slot.setCompanion(configuration(for: .aligned(linked: linkedAgent)))

        XCTAssertTrue(overlay.isHidden)
        XCTAssertFalse(webView.isAccessibilityHidden(), "Page AX state should restore to its exact prior value")
        XCTAssertTrue(inspector.isAccessibilityHidden(), "Inspector AX state should restore to its exact prior value")
        XCTAssertTrue(window.firstResponder === inspector)
    }

    func testRemovingCoveredInspectorWhileVeiledRestoresItsAccessibilityImmediately() {
        let (window, slot, webView) = makeWindowSlotAndWebView()
        defer { window.orderOut(nil) }

        webView.setAccessibilityHidden(true)
        let inspector = CompanionWKInspectorResponderView(frame: slot.bounds)
        inspector.setAccessibilityHidden(false)
        slot.addSubview(inspector)
        slot.setCompanion(configuration(for: .veiled(linked: linkedAgent, active: activeAgent)))

        XCTAssertTrue(webView.isAccessibilityHidden())
        XCTAssertTrue(inspector.isAccessibilityHidden())

        inspector.removeFromSuperview()
        XCTAssertFalse(
            inspector.isAccessibilityHidden(),
            "A WebKit root leaving the covered slot must not retain veil-owned AX state"
        )

        slot.setCompanion(nil)
        XCTAssertTrue(
            webView.isAccessibilityHidden(),
            "Teardown must restore a page that was already AX-hidden before the veil"
        )
    }

    func testMouseRevealKeepsVeilInstalledThroughMatchingMouseUp() {
        let (window, slot, _) = makeWindowSlotAndWebView()
        defer { window.orderOut(nil) }
        var revealCount = 0
        let configuration = configuration(
            for: .veiled(linked: linkedAgent, active: activeAgent),
            onReveal: {
                revealCount += 1
                slot.setCompanion(nil)
            }
        )
        slot.setCompanion(configuration)
        guard let overlay = companionOverlay(in: slot) else {
            XCTFail("Expected companion overlay")
            return
        }

        overlay.mouseDown(with: mouseEvent(type: .leftMouseDown, window: window))
        XCTAssertEqual(revealCount, 1)
        XCTAssertFalse(
            overlay.isHidden,
            "Synchronous reveal state changes must not expose WebKit before mouse-up is consumed"
        )

        overlay.mouseUp(with: mouseEvent(type: .leftMouseUp, window: window))
        XCTAssertTrue(overlay.isHidden)
    }

    func testReturnAndSpaceRevealWhileOtherKeysRemainConsumed() {
        let (window, slot, _) = makeWindowSlotAndWebView()
        defer { window.orderOut(nil) }
        var revealCount = 0
        let blockingConfiguration = configuration(
            for: .veiled(linked: linkedAgent, active: activeAgent),
            onReveal: {
                revealCount += 1
                slot.setCompanion(nil)
            }
        )
        slot.setCompanion(blockingConfiguration)
        guard let overlay = companionOverlay(in: slot) else {
            XCTFail("Expected companion overlay")
            return
        }

        overlay.keyDown(with: keyEvent(characters: "a", keyCode: 0, window: window))
        XCTAssertEqual(revealCount, 0)
        overlay.keyDown(with: keyEvent(characters: "\r", keyCode: 36, window: window))
        XCTAssertEqual(revealCount, 1)
        XCTAssertFalse(
            overlay.isHidden,
            "Synchronous keyboard reveal must retain the veil until matching key-up"
        )
        overlay.keyUp(with: keyEvent(type: .keyUp, characters: "\r", keyCode: 36, window: window))
        XCTAssertTrue(overlay.isHidden)

        slot.setCompanion(blockingConfiguration)
        guard let revealButton = descendantRevealButton(in: overlay) else {
            XCTFail("Expected focused reveal button")
            return
        }
        revealButton.keyDown(with: keyEvent(characters: " ", keyCode: 49, window: window))
        XCTAssertEqual(revealCount, 2)
        XCTAssertFalse(
            overlay.isHidden,
            "The focused button must route activation through the same key-up hold"
        )
        revealButton.keyUp(with: keyEvent(type: .keyUp, characters: " ", keyCode: 49, window: window))
        XCTAssertTrue(overlay.isHidden)
    }

    func testVeilRefreshDoesNotStealFirstResponderFromAnotherPane() {
        let (window, slot, _) = makeWindowSlotAndWebView()
        defer { window.orderOut(nil) }
        let outsideResponder = CompanionOutsideResponderView(
            frame: NSRect(x: 460, y: 30, width: 40, height: 40)
        )
        window.contentView?.addSubview(outsideResponder)
        XCTAssertTrue(window.makeFirstResponder(outsideResponder))

        slot.setCompanion(configuration(for: .veiled(linked: linkedAgent, active: activeAgent)))
        slot.setPaneTopChromeHeight(18)

        XCTAssertTrue(window.firstResponder === outsideResponder)
        XCTAssertFalse(companionOverlay(in: slot)?.isHidden ?? true)
    }

    func testRevealDoesNotRestoreCoveredResponderOverAnotherPane() {
        let (window, slot, _) = makeWindowSlotAndWebView()
        defer { window.orderOut(nil) }
        let coveredResponder = CompanionWKInspectorResponderView(frame: slot.bounds)
        slot.addSubview(coveredResponder)
        XCTAssertTrue(window.makeFirstResponder(coveredResponder))
        slot.setCompanion(configuration(for: .veiled(linked: linkedAgent, active: activeAgent)))

        let outsideResponder = CompanionOutsideResponderView(
            frame: NSRect(x: 460, y: 30, width: 40, height: 40)
        )
        window.contentView?.addSubview(outsideResponder)
        XCTAssertTrue(window.makeFirstResponder(outsideResponder))
        slot.setCompanion(configuration(for: .aligned(linked: linkedAgent)))

        XCTAssertTrue(window.firstResponder === outsideResponder)
    }

    func testNewBlockingStateSupersedesRevealQueuedUntilKeyUp() {
        let (window, slot, webView) = makeWindowSlotAndWebView()
        defer { window.orderOut(nil) }
        slot.setCompanion(
            configuration(
                for: .veiled(linked: linkedAgent, active: activeAgent),
                onReveal: { slot.setCompanion(nil) }
            )
        )
        guard let overlay = companionOverlay(in: slot) else {
            XCTFail("Expected companion overlay")
            return
        }

        overlay.keyDown(with: keyEvent(characters: "\r", keyCode: 36, window: window))
        slot.setCompanion(configuration(for: .orphaned(link: AgentSurfaceLink(
            surfaceID: linkedAgent.identity.surfaceID,
            lastKnownName: linkedAgent.identity.displayName
        ))))
        overlay.keyUp(with: keyEvent(type: .keyUp, characters: "\r", keyCode: 36, window: window))

        XCTAssertFalse(overlay.isHidden, "Newer blocking state must cancel queued reveal state")
        XCTAssertTrue(webView.isAccessibilityHidden())
    }

    func testReparentDuringHeldRevealDoesNotResurrectStaleVeil() {
        let (window, slot, webView) = makeWindowSlotAndWebView()
        defer { window.orderOut(nil) }
        guard let parent = slot.superview else {
            XCTFail("Expected slot parent")
            return
        }
        slot.setCompanion(
            configuration(
                for: .veiled(linked: linkedAgent, active: activeAgent),
                onReveal: { slot.setCompanion(nil) }
            )
        )
        guard let overlay = companionOverlay(in: slot) else {
            XCTFail("Expected companion overlay")
            return
        }

        overlay.keyDown(with: keyEvent(characters: "\r", keyCode: 36, window: window))
        XCTAssertFalse(overlay.isHidden)
        slot.removeFromSuperview()
        XCTAssertFalse(webView.isAccessibilityHidden())
        parent.addSubview(slot)

        XCTAssertTrue(overlay.isHidden, "Detached stale blocking state must not reappear on reparent")
        XCTAssertFalse(webView.isAccessibilityHidden())
    }

    func testBlockingCompanionClosesSearchBeforeInstallingVeilAndRejectsReopen() {
        let (window, slot, _) = makeWindowSlotAndWebView()
        defer { window.orderOut(nil) }
        var closeCount = 0
        let search = searchConfiguration(onClose: { closeCount += 1 })
        slot.setSearchOverlay(search)
        XCTAssertTrue(slot.subviews.contains { String(describing: type(of: $0)).contains("NSHostingView") })

        slot.setCompanion(configuration(for: .veiled(linked: linkedAgent, active: activeAgent)))

        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(slot.subviews.contains { String(describing: type(of: $0)).contains("NSHostingView") })
        XCTAssertFalse(companionOverlay(in: slot)?.isHidden ?? true)

        slot.setSearchOverlay(search)
        XCTAssertEqual(closeCount, 2)
        XCTAssertFalse(slot.subviews.contains { String(describing: type(of: $0)).contains("NSHostingView") })
    }

    func testInteractionLayerOrderIsWebKitThenSearchThenVeilThenDragThenModal() {
        let (window, slot, webView) = makeWindowSlotAndWebView()
        defer { window.orderOut(nil) }

        slot.setCompanion(configuration(for: .veiled(linked: linkedAgent, active: activeAgent)))
        slot.setCompanion(configuration(for: .revealed(linked: linkedAgent, active: activeAgent)))
        slot.setSearchOverlay(searchConfiguration(onClose: {}))
        slot.setPaneInteraction(
            BrowserPortalPaneInteractionConfiguration(
                panelId: UUID(),
                runtime: PaneInteractionRuntime()
            )
        )

        let subviews = slot.subviews
        guard let webIndex = subviews.firstIndex(where: { $0 === webView }),
              let searchIndex = subviews.firstIndex(where: {
                  String(describing: type(of: $0)).contains("NSHostingView")
              }),
              let veilIndex = subviews.firstIndex(where: { $0 is BrowserCompanionOverlayHost }),
              let dragIndex = subviews.firstIndex(where: {
                  String(describing: type(of: $0)).contains("BrowserPaneDropTargetView")
              }),
              let modalIndex = subviews.firstIndex(where: { $0 is PaneInteractionOverlayHost })
        else {
            XCTFail("Expected all five portal interaction layers")
            return
        }

        XCTAssertLessThan(webIndex, searchIndex)
        XCTAssertLessThan(searchIndex, veilIndex)
        XCTAssertLessThan(veilIndex, dragIndex)
        XCTAssertLessThan(dragIndex, modalIndex)
    }

    func testRegistrySetterAppliesVeilAndDetachRestoresAccessibility() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        let anchor = NSView(frame: NSRect(x: 30, y: 30, width: 420, height: 220))
        contentView.addSubview(anchor)
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        defer {
            BrowserWindowPortalRegistry.detach(webView: webView)
            window.orderOut(nil)
        }

        BrowserWindowPortalRegistry.updateCompanion(
            for: webView,
            configuration: configuration(for: .orphaned(link: AgentSurfaceLink(
                surfaceID: linkedAgent.identity.surfaceID,
                lastKnownName: linkedAgent.identity.displayName
            )))
        )

        guard let slot = webView.superview as? WindowBrowserSlotView else {
            XCTFail("Expected registry-bound portal slot")
            return
        }
        XCTAssertFalse(companionOverlay(in: slot)?.isHidden ?? true)
        XCTAssertTrue(webView.isAccessibilityHidden())

        BrowserWindowPortalRegistry.detach(webView: webView)
        XCTAssertFalse(webView.isAccessibilityHidden())
    }

    private func makeWindowSlotAndWebView() -> (NSWindow, WindowBrowserSlotView, WKWebView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        let slot = WindowBrowserSlotView(frame: NSRect(x: 30, y: 30, width: 420, height: 220))
        contentView.addSubview(slot)
        let webView = WKWebView(frame: slot.bounds, configuration: WKWebViewConfiguration())
        webView.autoresizingMask = [.width, .height]
        slot.addSubview(webView)
        slot.pinHostedWebView(webView)
        window.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        return (window, slot, webView)
    }

    private func configuration(
        for presentation: BrowserCompanionPresentation,
        onReveal: @escaping @MainActor @Sendable () -> Void = {},
        onHide: @escaping @MainActor @Sendable () -> Void = {}
    ) -> BrowserPortalCompanionConfiguration {
        BrowserPortalCompanionConfiguration(
            state: BrowserPortalCompanionState(presentation: presentation),
            onReveal: onReveal,
            onHide: onHide
        )
    }

    private func searchConfiguration(onClose: @escaping () -> Void) -> BrowserPortalSearchOverlayConfiguration {
        BrowserPortalSearchOverlayConfiguration(
            panelId: UUID(),
            searchState: BrowserSearchState(),
            focusRequestGeneration: 0,
            canApplyFocusRequest: { _ in true },
            onNext: {},
            onPrevious: {},
            onClose: onClose,
            onFieldDidFocus: {}
        )
    }

    private func companionOverlay(in slot: WindowBrowserSlotView) -> BrowserCompanionOverlayHost? {
        slot.subviews.compactMap { $0 as? BrowserCompanionOverlayHost }.first
    }

    private func descendantRevealButton(in root: NSView) -> NSButton? {
        var stack = root.subviews
        while let view = stack.popLast() {
            if let button = view as? NSButton { return button }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func owningView(for responder: NSResponder?) -> NSView? {
        if let editor = responder as? NSTextView,
           editor.isFieldEditor,
           let editedView = editor.delegate as? NSView {
            return editedView
        }
        return responder as? NSView
    }

    private func mouseEvent(type: NSEvent.EventType, window: NSWindow) -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        ) else {
            fatalError("Failed to create pointer event")
        }
        return event
    }

    private func keyEvent(
        type: NSEvent.EventType = .keyDown,
        characters: String,
        keyCode: UInt16,
        window: NSWindow
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to create key event")
        }
        return event
    }
}

private final class CompanionWKInspectorResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class CompanionOutsideResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
