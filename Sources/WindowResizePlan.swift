import Foundation

/// Deterministic frame math for the computer-use sizing primitive (cmux #9826).
/// AppKit origins are bottom-left; resizing preserves the current top-left.
enum WindowResizePlan {
    enum Failure: Error { case notFound, fullscreen }

    struct Decision {
        let frame: CGRect
        let clamped: Bool
        let write: Bool
    }

    static func decide(
        frame: CGRect,
        width: CGFloat?,
        height: CGFloat?,
        minSize: CGSize,
        visibleFrame: CGRect?
    ) -> Decision {
        guard width != nil || height != nil else {
            return Decision(frame: frame, clamped: false, write: false)
        }
        func edge(_ requested: CGFloat?, current: CGFloat, minimum: CGFloat, maximum: CGFloat?) -> CGFloat {
            guard let requested else { return current }
            return max(minimum, min(requested, maximum ?? requested))
        }
        let appliedWidth = edge(width, current: frame.width, minimum: minSize.width, maximum: visibleFrame?.width)
        let appliedHeight = edge(height, current: frame.height, minimum: minSize.height, maximum: visibleFrame?.height)
        return Decision(
            frame: CGRect(x: frame.origin.x, y: frame.maxY - appliedHeight, width: appliedWidth, height: appliedHeight),
            clamped: (width.map { $0 != appliedWidth } ?? false) || (height.map { $0 != appliedHeight } ?? false),
            write: true
        )
    }
}
