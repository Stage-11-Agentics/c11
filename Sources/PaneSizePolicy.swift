import CoreGraphics
import Foundation

// Size-aware pane creation.
//
// c11 splits a pane 50/50 with no notion of a minimum usable size, so stacking
// splits drives panes below the size a coding-agent TUI needs to be readable.
// This module is the pure decision core: given a pane's current pixel rect, the
// font cell size, the kind of surface involved, the requested split axis, and the
// active policy mode, it decides whether to split (and on which axis), fall back to
// a tab, or refuse. It has no AppKit/Bonsplit dependencies so it unit-tests in the
// host-free `c11LogicTests` target.
//
// All sizes are in AppKit points. Pane frames (from `bonsplitController.layoutSnapshot`)
// and cell sizes (`GhosttySurfaceScrollView.cellSize`) share that unit, so
// `cols = frame.width / cellSize.width` is consistent with no retina-scale correction.

/// How size-aware split creation behaves when a 50/50 split would leave a child
/// pane below the minimum usable size for what it holds.
enum PaneSizeMode: String, CaseIterable, Identifiable {
    /// Never block — the blind 50/50 split (legacy behavior).
    case off
    /// Never block, but report when a result is undersized or near the threshold.
    case warn
    /// Requested axis if it fits; else flip to the roomier axis; else refuse. (Default.)
    case balance
    /// Like `balance`, but fall back to a tab on the target pane instead of refusing.
    case tab

    var id: String { rawValue }

    static var `default`: PaneSizeMode { .balance }

    static func parse(_ raw: String?) -> PaneSizeMode? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        return PaneSizeMode(rawValue: trimmed)
    }
}

/// A pane size expressed in terminal cells (columns × rows).
struct PaneCellSize: Equatable {
    var cols: Int
    var rows: Int
}

/// Which way a 50/50 split divides a pane.
enum SplitAxis: Equatable {
    /// Side-by-side — children keep full height and halve width.
    case horizontal
    /// Stacked — children keep full width and halve height.
    case vertical

    var flipped: SplitAxis { self == .horizontal ? .vertical : .horizontal }
}

/// Whether a resulting child pane is comfortably sized, close to the minimum, or below it.
enum PaneSizeStatus: Equatable {
    case ok
    case near
    case undersized
}

enum PaneSizePolicy {
    // MARK: Per-kind minimums / optimums (columns × rows)

    /// Coding-agent TUIs (Claude Code, Codex, …) need a substantial grid to stay usable.
    static let agentMin = PaneCellSize(cols: 80, rows: 20)
    static let agentOptimum = PaneCellSize(cols: 120, rows: 30)
    /// A plain shell / log tail is usable much smaller.
    static let terminalMin = PaneCellSize(cols: 40, rows: 10)
    static let terminalOptimum = PaneCellSize(cols: 80, rows: 24)

    /// Point floor for panes with no character grid (browser / markdown).
    static let nonTerminalMinPoints = CGSize(width: 320, height: 240)

    /// Conservative fallback cell size (pt), used only when a source surface has not
    /// reported its real cell metrics yet (≈ a 13pt monospaced font).
    static let fallbackCellSize = CGSize(width: 8.4, height: 17.0)

    /// A split that lands within this fraction above the minimum is flagged "near".
    static let nearThresholdFraction: CGFloat = 0.15

    /// Surface `terminal_type` values treated as coding agents. Derived from
    /// the agent registry plus `opencode-run` (the headless opencode variant,
    /// which is a detected terminal_type but not a launchable AgentType).
    static let agentKinds: Set<String> = {
        var kinds: Set<String> = ["opencode-run"]
        for manifest in AgentRegistry.shared.all where manifest.isCanonicalTerminalType {
            kinds.insert(manifest.kind)
        }
        return kinds
    }()

    static func isAgentKind(_ kind: String?) -> Bool {
        guard let k = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !k.isEmpty
        else { return false }
        return agentKinds.contains(k)
    }

    /// The minimum cell budget for a surface of the given kind.
    static func minCells(forKind kind: String?) -> PaneCellSize {
        isAgentKind(kind) ? agentMin : terminalMin
    }

    /// A human label for the kind, used in warnings and refusals.
    static func kindLabel(forKind kind: String?) -> String {
        isAgentKind(kind) ? (kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "terminal") : "terminal"
    }

    /// Convert a cell budget to points using the given cell size (falling back to a
    /// default when the surface has not reported metrics yet).
    static func points(_ cells: PaneCellSize, cellSize: CGSize) -> CGSize {
        let cw = cellSize.width > 0 ? cellSize.width : fallbackCellSize.width
        let ch = cellSize.height > 0 ? cellSize.height : fallbackCellSize.height
        return CGSize(width: CGFloat(cells.cols) * cw, height: CGFloat(cells.rows) * ch)
    }

    // MARK: Geometry

    /// The size each child pane would have after a 50/50 split on the given axis.
    static func childSize(_ axis: SplitAxis, paneFrame: CGSize) -> CGSize {
        switch axis {
        case .horizontal: return CGSize(width: paneFrame.width / 2, height: paneFrame.height)
        case .vertical:   return CGSize(width: paneFrame.width, height: paneFrame.height / 2)
        }
    }

    /// A split on `axis` is admissible when both resulting children meet the minimum
    /// in both dimensions.
    static func admissible(_ axis: SplitAxis, paneFrame: CGSize, minPoints: CGSize) -> Bool {
        let child = childSize(axis, paneFrame: paneFrame)
        return child.width >= minPoints.width && child.height >= minPoints.height
    }

    /// Classify a resulting child against the minimum.
    static func status(child: CGSize, minPoints: CGSize) -> PaneSizeStatus {
        let belowW = minPoints.width > 0 && child.width < minPoints.width
        let belowH = minPoints.height > 0 && child.height < minPoints.height
        if belowW || belowH { return .undersized }
        let nearW = minPoints.width > 0 && child.width < minPoints.width * (1 + nearThresholdFraction)
        let nearH = minPoints.height > 0 && child.height < minPoints.height * (1 + nearThresholdFraction)
        return (nearW || nearH) ? .near : .ok
    }

    // MARK: Decision

    enum Outcome: Equatable {
        /// Create the split on this axis (may differ from the requested axis).
        case proceed(SplitAxis)
        /// Add a tab to the target pane instead of splitting.
        case addTab
        /// Do not create anything; surface an actionable refusal.
        case refuse
    }

    struct Decision: Equatable {
        var outcome: Outcome
        var requestedAxis: SplitAxis
        /// The axis actually applied (nil for `addTab` / `refuse`).
        var appliedAxis: SplitAxis?
        /// True when the applied axis differs from the requested one.
        var flipped: Bool
        /// Status of the resulting child for the chosen path (or the requested,
        /// undersized child when refusing / falling back to a tab).
        var status: PaneSizeStatus
        /// Resulting child size for the chosen path (points).
        var resultingChild: CGSize
        /// The controlling minimum applied (points).
        var minPoints: CGSize
    }

    /// Decide what to do with a split request.
    ///
    /// - Parameters:
    ///   - paneFrame: current pixel rect of the pane being split (points).
    ///   - requested: the axis the caller asked for.
    ///   - minPoints: the controlling minimum (max over both children's requirements), points.
    ///   - mode: the active policy.
    ///   - force: per-call escape hatch — behave as `.off` for this call.
    static func decide(
        paneFrame: CGSize,
        requested: SplitAxis,
        minPoints: CGSize,
        mode: PaneSizeMode,
        force: Bool
    ) -> Decision {
        func proceed(_ axis: SplitAxis, flipped: Bool) -> Decision {
            let child = childSize(axis, paneFrame: paneFrame)
            return Decision(
                outcome: .proceed(axis),
                requestedAxis: requested,
                appliedAxis: axis,
                flipped: flipped,
                status: status(child: child, minPoints: minPoints),
                resultingChild: child,
                minPoints: minPoints
            )
        }

        // Escape hatch / disabled → always honor the request, never block.
        if force || mode == .off {
            return proceed(requested, flipped: false)
        }

        let other = requested.flipped
        let requestedAdmissible = admissible(requested, paneFrame: paneFrame, minPoints: minPoints)
        let otherAdmissible = admissible(other, paneFrame: paneFrame, minPoints: minPoints)

        switch mode {
        case .off:
            return proceed(requested, flipped: false)  // unreachable; handled above

        case .warn:
            // Never block — report status against the requested axis.
            return proceed(requested, flipped: false)

        case .balance, .tab:
            if requestedAdmissible {
                return proceed(requested, flipped: false)
            }
            if otherAdmissible {
                return proceed(other, flipped: true)
            }
            // Neither axis yields a usable pane.
            let undersizedChild = childSize(requested, paneFrame: paneFrame)
            let fallback: Outcome = (mode == .tab) ? .addTab : .refuse
            return Decision(
                outcome: fallback,
                requestedAxis: requested,
                appliedAxis: nil,
                flipped: false,
                status: status(child: undersizedChild, minPoints: minPoints),
                resultingChild: undersizedChild,
                minPoints: minPoints
            )
        }
    }

    // MARK: Messages (English; socket/CLI responses are not localized)

    private static func axisWord(_ axis: SplitAxis) -> String {
        axis == .horizontal ? "side-by-side" : "stacked"
    }

    private static func dims(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))pt"
    }

    /// A one-line, non-blocking warning for a near-threshold, undersized, or flipped
    /// result. Returns nil when there is nothing worth saying.
    static func warningText(for decision: Decision, kindLabel: String) -> String? {
        switch decision.outcome {
        case .proceed:
            if decision.flipped {
                var msg = "requested a \(axisWord(decision.requestedAxis)) split, but it would leave a pane below the \(dims(decision.minPoints)) minimum for a \(kindLabel) surface; split \(axisWord(decision.appliedAxis ?? decision.requestedAxis)) instead"
                if decision.status == .near {
                    msg += " (still close to the minimum)"
                }
                return msg
            }
            switch decision.status {
            case .ok:
                return nil
            case .near:
                return "the new \(kindLabel) pane (\(dims(decision.resultingChild))) is close to the \(dims(decision.minPoints)) minimum usable size"
            case .undersized:
                return "the new \(kindLabel) pane (\(dims(decision.resultingChild))) is below the \(dims(decision.minPoints)) minimum usable size for a \(kindLabel) surface"
            }
        case .addTab:
            return "too small to split usably; added a tab to the target pane instead"
        case .refuse:
            return nil
        }
    }

    /// The actionable refusal message. `paneRefLabel` is something like `pane:3`.
    static func refusalMessage(for decision: Decision, kindLabel: String, paneRefLabel: String) -> String {
        "won't split \(paneRefLabel): a split would leave a \(dims(decision.resultingChild)) pane below the \(dims(decision.minPoints)) minimum for a \(kindLabel) surface. Add a tab instead (c11 new-surface --pane \(paneRefLabel)), close a sibling pane, or pass --allow-undersized to force."
    }
}

/// Persisted + env-overridable policy mode, following the `SocketControlSettings` pattern.
enum PaneSizeSettings {
    static let appStorageKey = "paneSizeMode"

    /// `C11_SPLIT_SIZE_POLICY` (or the `CMUX_*` compat alias) overrides the stored mode —
    /// useful for headless runs and tests.
    static func envMode() -> PaneSizeMode? {
        let env = ProcessInfo.processInfo.environment
        return PaneSizeMode.parse(env["C11_SPLIT_SIZE_POLICY"] ?? env["CMUX_SPLIT_SIZE_POLICY"])
    }

    static func effectiveMode() -> PaneSizeMode {
        if let env = envMode() { return env }
        return PaneSizeMode.parse(UserDefaults.standard.string(forKey: appStorageKey)) ?? .default
    }
}
