import XCTest
import SwiftUI
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Renders the real confirm card and compares pixels, so the card's own
/// missing-selection fallback is covered, not just the runtime helper.
@MainActor
final class AreaInteractionCardRenderTests: XCTestCase {

    private func render(runtime: AreaInteractionRuntime, panelId: UUID) throws -> Data {
        let interaction = try XCTUnwrap(runtime.active[panelId], "no active confirm")
        let view = AreaInteractionCardView(panelId: panelId, interaction: interaction, runtime: runtime)
            .frame(width: 480, height: 320)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage, "card did not render")
        return try XCTUnwrap(image.tiffRepresentation)
    }

    func testConfirmCardHighlightsCancelWhenSelectionIsMissing() throws {
        let runtime = AreaInteractionRuntime()
        let panelId = UUID()
        // A standard confirm starts on its confirm button, so Cancel being
        // selected below can only come from the missing-selection fallback.
        let content = ConfirmContent(
            title: "Continue?", message: nil, confirmLabel: "Proceed", cancelLabel: "Abort",
            role: .standard, source: .local, completion: { _ in }
        )
        runtime.present(panelId: panelId, interaction: .confirm(content))
        XCTAssertEqual(runtime.confirmSelectionForDisplay(panelId: panelId), .confirm)
        let confirmSelected = try render(runtime: runtime, panelId: panelId)

        runtime.moveConfirmSelection(panelId: panelId, direction: .left)
        XCTAssertEqual(runtime.confirmSelectionForDisplay(panelId: panelId), .cancel)
        let cancelSelected = try render(runtime: runtime, panelId: panelId)
        XCTAssertNotEqual(confirmSelected, cancelSelected, "the two selections must render differently")

        runtime.debugClearConfirmSelection(panelId: panelId)
        let missing = try render(runtime: runtime, panelId: panelId)
        XCTAssertEqual(missing, cancelSelected, "A missing selection must render Cancel highlighted, as Return treats it")
        XCTAssertNotEqual(missing, confirmSelected, "A missing selection must not render Confirm highlighted")
    }
}
