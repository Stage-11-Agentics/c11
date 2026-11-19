import Foundation

/// Ticket 5 implements these hooks. Native lanes never synchronously enter
/// main; the probe hooks perform no work when the probe is disabled.
protocol HCRenderingAdapter: HCScreenProvider {
    @MainActor func wrapNewTerminalArgv(_ argv: [String]) -> [String]
    func noteRawInput(_ ptr: UnsafeRawPointer, _ len: Int)
    func noteOutput(_ chunk: HCOutputChunk)
    func didParse(_ chunk: HCOutputChunk)
    func claimInBandGrid(columns: UInt16, rows: UInt16) -> Bool
    @MainActor func displayStateForAttach(attachmentGeneration: UInt64, focused: Bool) -> HCDisplayState?
    @MainActor func attached(_ attachment: any HCAttachment)
    @MainActor func detached()
    @MainActor func surfaceSizeChanged()
    @MainActor func focusChanged(_ focused: Bool)
    /// Called at ordered writer admission, immediately before a display
    /// update's RESIZE. False omits a stale or already-applied RESIZE; FACTS and
    /// FOCUS for the same update are still sent. Default: always send.
    func admitDisplayResize(_ state: HCDisplayState) -> Bool
}

extension HCRenderingAdapter {
    func admitDisplayResize(_ state: HCDisplayState) -> Bool { true }
}

struct HCUnavailableRenderingAdapter: HCRenderingAdapter {
    @MainActor func wrapNewTerminalArgv(_ argv: [String]) -> [String] { argv }
    func noteRawInput(_ ptr: UnsafeRawPointer, _ len: Int) {}
    func noteOutput(_ chunk: HCOutputChunk) {}
    func didParse(_ chunk: HCOutputChunk) {}
    func claimInBandGrid(columns: UInt16, rows: UInt16) -> Bool { true }
    @MainActor func displayStateForAttach(attachmentGeneration: UInt64, focused: Bool) -> HCDisplayState? { nil }
    @MainActor func attached(_ attachment: any HCAttachment) {}
    @MainActor func detached() {}
    @MainActor func surfaceSizeChanged() {}
    @MainActor func focusChanged(_ focused: Bool) {}
    func screenCurrent(after revision: HCDisplayRevision) async -> HCScreenReceipt? { nil }
}
