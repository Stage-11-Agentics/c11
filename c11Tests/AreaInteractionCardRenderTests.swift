import XCTest
import SwiftUI
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Renders the real confirm card and checks which button it highlights, so the
/// card's own missing-selection fallback is covered, not just the runtime helper.
///
/// Whole-image byte equality is not stable across runs and machines (the same
/// render differs in a few antialiased pixels), so a render is classified by its
/// distance to two reference renders: the card with Cancel explicitly selected and
/// the card with Confirm explicitly selected. The selection box is a 2pt white
/// stroke, which dwarfs that noise.
@MainActor
final class AreaInteractionCardRenderTests: XCTestCase {

    private static let width = 480
    private static let height = 320

    private func render(runtime: AreaInteractionRuntime, panelId: UUID) throws -> [UInt8] {
        let interaction = try XCTUnwrap(runtime.active[panelId], "no active confirm")
        let view = AreaInteractionCardView(panelId: panelId, interaction: interaction, runtime: runtime)
            .frame(width: CGFloat(Self.width), height: CGFloat(Self.height))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cgImage = try XCTUnwrap(renderer.cgImage, "card did not render")
        var pixels = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: Self.width, height: Self.height,
                bitsPerComponent: 8, bytesPerRow: Self.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
            return true
        }
        XCTAssertTrue(drawn, "could not read back rendered pixels")
        return pixels
    }

    /// Mean absolute per-byte difference between two renders.
    private func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        precondition(a.count == b.count)
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }

    func testConfirmCardHighlightsCancelWhenSelectionIsMissing() throws {
        let runtime = AreaInteractionRuntime()
        let panelId = UUID()
        // A standard confirm starts on its confirm button, so Cancel being
        // highlighted below can only come from the missing-selection fallback.
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

        let between = distance(confirmSelected, cancelSelected)
        XCTAssertGreaterThan(between, 0.05, "the two selections must render visibly differently (\(between))")

        runtime.debugClearConfirmSelection(panelId: panelId)
        let missing = try render(runtime: runtime, panelId: panelId)
        let toCancel = distance(missing, cancelSelected)
        let toConfirm = distance(missing, confirmSelected)
        print("AreaInteractionCardRenderTests distances: between=\(between) missingToCancel=\(toCancel) missingToConfirm=\(toConfirm)")
        XCTAssertLessThan(
            toCancel, toConfirm,
            "A missing selection must render closer to Cancel highlighted (\(toCancel)) than Confirm highlighted (\(toConfirm)), as Return treats it"
        )
        XCTAssertLessThan(toCancel, between / 4, "missing selection must render like Cancel selected (\(toCancel) vs \(between))")
    }
}
