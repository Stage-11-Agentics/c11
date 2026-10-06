import AppKit
import SwiftUI
import XCTest
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class FeedQuickViewTests: XCTestCase {
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    private func row(_ n: Int, kind: FeedKind? = .question, flag: Bool = false, prompt: String? = nil) -> FeedRow {
        .init(workspaceID: id(99), panelID: id(n), kind: kind, prompt: prompt, options: nil,
            promptAvailable: prompt != nil, source: "hook", sourceRank: 4, openedAtMs: Int64(n),
            state: kind == .turnEnd ? nil : "open", requestID: "synthetic", confirmation: "unconfirmed",
            blocking: kind == .turnEnd ? false : true,
            flag: flag ? .init(reason: "Synthetic flag", raisedAtMs: Int64(n), callerPanelID: nil) : nil)
    }

    func testFiltersUseProjectionCountsAndNeverReplaceJumpSequence() {
        let projection = FeedProjectionSnapshot(rows: AttentionOrder.ordered([
            row(1, flag: true), row(2, kind: .permission), row(3, kind: .turnEnd), row(4, kind: .turnEnd, flag: true)]))
        let tail = [AttentionOrder.Candidate(target: .init(workspaceID: id(99), panelID: id(3)), notificationID: id(103)),
                    .init(target: .init(workspaceID: id(99), panelID: id(5)), notificationID: id(105))]
        let jump = AttentionOrder.candidates(rows: projection.attentionRows, unreadTail: tail)
        let model = FeedQuickViewModel()
        var opened: [AttentionOrder.Target] = []
        model.onOpen = { opened.append($0); return true }
        model.apply(.init(projection: projection, loading: false))
        XCTAssertEqual(model.rows, projection.attentionRows)
        XCTAssertEqual(model.rows.map(\.panelID), [id(1), id(4), id(2)])
        XCTAssertFalse(model.rows.contains { $0.kind == .turnEnd })
        XCTAssertEqual(model.snapshot.projection.openAskCount, 2)
        XCTAssertEqual(model.snapshot.projection.flagCount, 2)
        model.move(1)
        model.switchFilter(.turns)
        XCTAssertEqual(model.selection.selectedPanelID, id(4))
        XCTAssertEqual(Set(model.rows.map(\.panelID)), Set([id(3), id(4)]))
        model.switchFilter(.asks)
        model.apply(.init(projection: .init(rows: Array(projection.rows.dropFirst())), loading: false))
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(jump.map { $0.target.panelID }, [id(1), id(4), id(2), id(3), id(5)])
        XCTAssertEqual(AttentionOrder.candidates(rows: projection.attentionRows, unreadTail: tail), jump)
    }

    func testToggleFilterCyclesBothFiltersWithoutOpeningAnything() {
        let model = FeedQuickViewModel()
        var opened = 0
        model.onOpen = { _ in opened += 1; return true }
        model.apply(.init(projection: .init(rows: [row(1), row(2, kind: .turnEnd)]), loading: false))
        XCTAssertEqual(model.selection.filter, .asks)
        XCTAssertEqual(model.rows.map(\.panelID), [id(1)])
        model.toggleFilter()
        XCTAssertEqual(model.selection.filter, .turns)
        XCTAssertEqual(model.rows.map(\.panelID), [id(2)])
        XCTAssertEqual(model.selection.selectedPanelID, id(2))
        model.toggleFilter()
        XCTAssertEqual(model.selection.filter, .asks)
        XCTAssertEqual(model.selection.selectedPanelID, id(1))
        XCTAssertEqual(opened, 0)
    }

    func testEnterOnlyOpensExactTargetAndUnavailableStaysWithoutDismissal() {
        let model = FeedQuickViewModel()
        model.apply(.init(projection: .init(rows: [row(1), row(2)]), loading: false))
        model.move(1)
        var attempts: [AttentionOrder.Target] = []
        var dismissed = 0
        model.onOpened = { dismissed += 1 }
        model.onOpen = { attempts.append($0); return false }
        model.openSelected()
        XCTAssertEqual(attempts, [.init(workspaceID: id(99), panelID: id(2))])
        XCTAssertEqual(dismissed, 0)
        // The English text lives in the catalog (C11-337: R5 syncs it), so compare the lookup.
        XCTAssertEqual(model.status, String(localized: "feed.quick.unavailable", defaultValue: "That panel is unavailable"))
        XCTAssertEqual(model.selection.selectedPanelID, id(2))
        model.onOpen = { attempts.append($0); return true }
        model.openSelected()
        XCTAssertEqual(dismissed, 1)
    }

    func testKeyboardLifecycleScopeModifiersAndOriginalResponderRestoration() throws {
        let owner = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        defer { owner.orderOut(nil); other.orderOut(nil) }
        let origin = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 100))
        owner.contentView?.addSubview(origin)
        owner.makeKeyAndOrderFront(nil)
        owner.makeFirstResponder(origin)
        let session = FeedQuickViewKeyboardSession()
        var moves = 0, opens = 0, cancels = 0, toggles = 0
        func action(_ action: FeedQuickViewKeyboardSession.Action) {
            switch action { case .move: moves += 1; case .open: opens += 1; case .cancel: cancels += 1; case .toggleFilter: toggles += 1; case .consume: break }
        }
        session.start(window: owner, action: action)
        session.start(window: owner, action: action)
        XCTAssertEqual(session.monitorInstallCount, 1)
        func event(_ window: NSWindow, key: UInt16, flags: NSEvent.ModifierFlags = [], chars: String = "") throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: chars,
                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: key))
        }
        XCTAssertFalse(session.handle(try event(other, key: 125)))
        XCTAssertFalse(session.handle(try event(other, key: 36)))
        XCTAssertFalse(session.handle(try event(other, key: 53)))
        XCTAssertFalse(session.handle(try event(owner, key: 125, flags: .option)))
        XCTAssertTrue(session.handle(try event(owner, key: 125)))
        XCTAssertTrue(session.handle(try event(owner, key: 36)))
        XCTAssertTrue(session.handle(try event(owner, key: 53)))
        XCTAssertFalse(session.handle(try event(other, key: 48)))
        XCTAssertFalse(session.handle(try event(owner, key: 48, flags: .option)))
        XCTAssertTrue(session.handle(try event(owner, key: 48)))
        XCTAssertTrue(session.handle(try event(owner, key: 48, flags: .shift)))
        XCTAssertEqual(moves, 1); XCTAssertEqual(opens, 1); XCTAssertEqual(cancels, 1); XCTAssertEqual(toggles, 2)
        let displaced = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 100))
        owner.contentView?.addSubview(displaced)
        owner.makeFirstResponder(displaced)
        session.stop(restoreFocus: true)
        XCTAssertTrue(owner.firstResponder === origin)
        XCTAssertFalse(session.handle(try event(owner, key: 125)))
        session.start(window: owner, action: action)
        XCTAssertEqual(session.monitorInstallCount, 2)
        origin.removeFromSuperview()
        owner.makeFirstResponder(displaced)
        session.stop(restoreFocus: true)
        XCTAssertTrue(owner.firstResponder === displaced)
    }

    func testFilterFocusFollowsActiveFilterForTabShiftTabAndPointerWithFixedFrames() throws {
        let model = FeedQuickViewModel()
        model.apply(.init(projection: .init(rows: [row(1), row(2, kind: .turnEnd)]), loading: false))
        var focus: [FeedQuickViewSelection.Filter?] = []
        var frames: [String: CGRect] = [:]
        let host = NSHostingView(rootView: FeedQuickView(model: model,
            onLayout: { frames[$0] = $1 }, onFilterFocus: { focus.append($0) }))
        host.frame = .init(origin: .zero, size: FeedQuickViewGeometry.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15)) }
        settle()
        XCTAssertEqual(focus.last ?? nil, .asks, "opening focuses the default filter")
        let filters = frames["filters"]
        model.toggleFilter() // Tab
        settle()
        XCTAssertEqual(model.selection.filter, .turns)
        XCTAssertEqual(focus.last ?? nil, .turns, "Tab moves real focus to Turns")
        model.toggleFilter() // Shift-Tab (two filters cycle both ways)
        settle()
        XCTAssertEqual(focus.last ?? nil, .asks, "Shift-Tab moves real focus back to Asks")
        model.switchFilter(.turns) // pointer selection
        settle()
        XCTAssertEqual(focus.last ?? nil, .turns, "pointer selection moves real focus too")
        XCTAssertEqual(frames["filters"], filters, "focus changes never move or resize the controls")
        XCTAssertEqual(host.fittingSize, FeedQuickViewGeometry.size)
    }

    func testHostRendersSameFixedSizeAcrossEmptyLoadingLongMissingAndFilters() throws {
        let model = FeedQuickViewModel()
        var frames: [String: CGRect] = [:]
        let host = NSHostingView(rootView: FeedQuickView(model: model, onLayout: { frames[$0] = $1 }))
        host.frame = .init(origin: .zero, size: FeedQuickViewGeometry.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        var original: [String: CGRect] = [:]
        for state in [FeedQuickViewSnapshot(), .init(loading: false),
            .init(projection: .init(rows: [row(1, prompt: "Short"), row(2, prompt: String(repeating: "Long\n", count: 100)), row(3)]),
                  titles: [id(1): String(repeating: "Synthetic long name ", count: 50)], loading: false),
            .init(projection: .init(rows: (1...120).map { row($0, flag: true) }), loading: false)] {
            model.apply(state)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            XCTAssertEqual(host.fittingSize, FeedQuickViewGeometry.size)
            for (key, size) in [("filters", NSSize(width: 200, height: 28)),
                                ("filter.0", NSSize(width: 100, height: 28)), ("filter.1", NSSize(width: 100, height: 28)),
                                ("hint", NSSize(width: 520, height: 28)), ("status", NSSize(width: 520, height: 16))] {
                XCTAssertEqual(frames[key]?.size, size, key)
                if let first = original[key] { XCTAssertEqual(frames[key], first, key) }
                else { original[key] = frames[key] }
            }
            for (key, frame) in frames where key.hasPrefix("row.") { XCTAssertEqual(frame.height, 64, key) }
            model.switchFilter(.turns)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertEqual(host.fittingSize, FeedQuickViewGeometry.size)
            model.switchFilter(.asks)
        }
        // Render the longest shipped strings from each built locale as stress
        // labels, not new product translations. C11-291 owns the new keys.
        for locale in ["ja", "uk", "ko", "zh-Hans", "zh-Hant", "ru"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: locale), locale)
            let localized = try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String], locale)
            let longest = try XCTUnwrap(localized.values.max(by: { $0.count < $1.count }), locale)
            frames = [:]
            let localeHost = NSHostingView(rootView: FeedQuickView(model: model, filterLabels: [longest, longest], onLayout: { frames[$0] = $1 }))
            localeHost.frame = .init(origin: .zero, size: FeedQuickViewGeometry.size)
            window.contentView = localeHost
            localeHost.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            XCTAssertEqual(frames["filters"]?.size, NSSize(width: 200, height: 28), locale)
            XCTAssertEqual(frames["filter.0"]?.size, NSSize(width: 100, height: 28), locale)
            XCTAssertEqual(frames["filter.1"]?.size, NSSize(width: 100, height: 28), locale)
            XCTAssertEqual(frames["hint"], original["hint"], locale)
            XCTAssertEqual(localeHost.fittingSize, FeedQuickViewGeometry.size)
            let bitmap = try XCTUnwrap(localeHost.bitmapImageRepForCachingDisplay(in: localeHost.bounds))
            localeHost.cacheDisplay(in: localeHost.bounds, to: bitmap)
            let image = NSImage(size: localeHost.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Feed fixed geometry longest shipped label " + locale
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
