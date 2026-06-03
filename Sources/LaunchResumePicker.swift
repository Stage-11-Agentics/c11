import AppKit
import SwiftUI

/// Per-workspace launch-time resume picker (C11-34 part A).
///
/// On launch, when a previous session snapshot exists, c11 historically
/// restored *every* workspace from every persisted window. The operator had
/// no agency to bring back a subset — it was all-or-nothing via
/// `CMUX_DISABLE_SESSION_RESTORE=1`. This picker turns that into a real
/// choice: resume all, resume a chosen subset, or skip and start fresh.
///
/// **Policy.** `LaunchResumePolicy.current()` reads the operator's pref
/// from `UserDefaults.standard`. Default is `.ask`. `.always` skips the
/// picker and restores everything (legacy behavior). `.never` skips both
/// the picker and the restore. The policy is stored under
/// `c11.launch.resumePolicy` so other tools can observe / set it.
///
/// **Hook point.** `AppDelegate.attemptStartupSessionRestoreIfNeeded`
/// calls `LaunchResumePicker.presentIfNeeded(...)` before applying the
/// snapshot to the primary window. The completion delivers either the
/// original snapshot (`.always`), `nil` (`.never` / Skip), or a filtered
/// snapshot keeping only the workspaces the user kept ticked.

enum LaunchResumePolicy: String, CaseIterable {
    case ask
    case always
    case never

    static let defaultsKey = "c11.launch.resumePolicy"

    /// Read the current policy from `UserDefaults.standard`. Unknown /
    /// empty values fall back to `.ask` so a typo or absent key is the
    /// "show me a picker" default rather than a silent skip.
    static func current(defaults: UserDefaults = .standard) -> LaunchResumePolicy {
        guard let raw = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty,
              let parsed = LaunchResumePolicy(rawValue: raw) else {
            return .ask
        }
        return parsed
    }

    func persist(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// Snapshot-derived row data shown in the picker. Built once at launch
/// from `AppSessionSnapshot`; the picker view itself never reaches back
/// into the snapshot.
struct LaunchResumePickerEntry: Identifiable, Hashable {
    /// Stable workspace UUID — survives across restarts when
    /// `SessionPersistencePolicy.stableWorkspaceIdsEnabled` is true (the
    /// default). Used as the picker's selection key and to filter the
    /// snapshot at apply time.
    let id: UUID
    /// Window index in the snapshot (0 = primary). Used to group rows
    /// when more than one window's worth of state is being offered.
    let windowIndex: Int
    /// Resolved display title: `customTitle ?? stableDefaultTitle ?? processTitle`.
    let title: String
    /// Number of panels in this workspace. Drives the "3 surfaces" hint.
    let surfaceCount: Int
    /// Up to 3 surface titles for the row's secondary line. Truncated by
    /// the view if it overflows; the picker is not the place for full
    /// fidelity — it's just enough to recognise the workspace.
    let surfaceTitles: [String]
}

/// What the operator decided. Returned to `AppDelegate` via the picker's
/// completion closure.
enum LaunchResumePickerDecision {
    /// Restore every workspace in the snapshot (legacy behavior).
    case resumeAll
    /// Restore only the workspaces with these UUIDs.
    case resumeSelected(Set<UUID>)
    /// Skip the restore — start with a fresh empty session.
    case skipAll
}

@MainActor
enum LaunchResumePicker {
    /// Present the picker as a sheet on `parentWindow` and call
    /// `completion` once the operator picks. When the snapshot has no
    /// workspaces (nothing to choose from), the picker is skipped and
    /// `completion(.skipAll)` fires synchronously.
    ///
    /// The sheet is non-cancellable via the standard ⎋ keystroke alone:
    /// a misclick that dismisses the sheet should not silently throw the
    /// session away. ⎋ inside the picker is wired to "Skip" so the
    /// operator's intent is recorded explicitly.
    static func presentSheet(
        on parentWindow: NSWindow,
        snapshot: AppSessionSnapshot,
        completion: @escaping (LaunchResumePickerDecision) -> Void
    ) {
        let entries = entries(from: snapshot)
        guard !entries.isEmpty else {
            completion(.skipAll)
            return
        }

        // Default: every workspace selected (matches "resume all" intent
        // for a one-click confirm).
        var initialSelection = Set<UUID>()
        for entry in entries { initialSelection.insert(entry.id) }

        let viewModel = LaunchResumePickerViewModel(
            entries: entries,
            selection: initialSelection
        )

        // Var-capture pattern so the dismissal closure can reach the
        // sheet window after it's created. Set after `beginSheet` below.
        var capturedSheetWindow: NSWindow?

        let hosting = NSHostingController(
            rootView: LaunchResumePickerView(model: viewModel) { decision in
                // Tear the sheet down before invoking the caller so any
                // window-level effects from the caller (focus, restore)
                // observe a clean window.
                if let sheet = capturedSheetWindow {
                    parentWindow.endSheet(sheet)
                }
                completion(decision)
            }
        )

        let sheetWindow = NSWindow(contentViewController: hosting)
        sheetWindow.styleMask = [.titled]
        sheetWindow.title = String(
            localized: "launch.resume.title",
            defaultValue: "Resume previous session?"
        )
        sheetWindow.setContentSize(NSSize(width: 460, height: 420))

        capturedSheetWindow = sheetWindow
        parentWindow.beginSheet(sheetWindow, completionHandler: nil)
    }

    /// Filter `snapshot.windows[*].tabManager.workspaces` to only those
    /// whose UUID is in `keep`. Empty windows (all workspaces dropped)
    /// are themselves dropped so the operator doesn't get a phantom
    /// blank window. Returns `nil` when the filter empties the snapshot
    /// completely; the caller treats `nil` the same as `.skipAll`.
    static func filtered(
        snapshot: AppSessionSnapshot,
        keep: Set<UUID>
    ) -> AppSessionSnapshot? {
        var newWindows: [SessionWindowSnapshot] = []
        for window in snapshot.windows {
            let kept = window.tabManager.workspaces.filter { keep.contains($0.id) }
            guard !kept.isEmpty else { continue }
            var newWindow = window
            // Reanchor selectedWorkspaceIndex to a kept workspace —
            // dropping arbitrary workspaces can leave the index pointing
            // at a position that no longer exists, which the restore
            // path treats as "no selection" (focus reconcile schedules a
            // fallback). Map the prior selected ID to the new index, or
            // fall back to the first kept workspace.
            let priorSelectedId: UUID? = {
                if let idx = window.tabManager.selectedWorkspaceIndex,
                   idx >= 0,
                   idx < window.tabManager.workspaces.count {
                    return window.tabManager.workspaces[idx].id
                }
                return nil
            }()
            let newSelectedIndex = priorSelectedId.flatMap { id in
                kept.firstIndex { $0.id == id }
            } ?? 0
            newWindow.tabManager = SessionTabManagerSnapshot(
                selectedWorkspaceIndex: newSelectedIndex,
                workspaces: kept
            )
            newWindows.append(newWindow)
        }
        guard !newWindows.isEmpty else { return nil }
        return AppSessionSnapshot(
            version: snapshot.version,
            createdAt: snapshot.createdAt,
            windows: newWindows
        )
    }

    /// Project the snapshot into the picker's row data. Stable order:
    /// window-major, then snapshot-declared workspace order.
    private static func entries(from snapshot: AppSessionSnapshot) -> [LaunchResumePickerEntry] {
        var out: [LaunchResumePickerEntry] = []
        for (windowIndex, window) in snapshot.windows.enumerated() {
            for workspace in window.tabManager.workspaces {
                let resolvedTitle = (workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? workspace.stableDefaultTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? workspace.processTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = resolvedTitle.isEmpty ? "(untitled)" : resolvedTitle
                let titles = workspace.panels.compactMap { panel -> String? in
                    let raw = (panel.customTitle ?? panel.title)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let raw, !raw.isEmpty else { return nil }
                    return raw
                }
                out.append(LaunchResumePickerEntry(
                    id: workspace.id,
                    windowIndex: windowIndex,
                    title: title,
                    surfaceCount: workspace.panels.count,
                    surfaceTitles: Array(titles.prefix(3))
                ))
            }
        }
        return out
    }
}

/// Picker view-model. Holds selection state for the lifetime of the
/// sheet.
@MainActor
final class LaunchResumePickerViewModel: ObservableObject {
    @Published var selection: Set<UUID>
    let entries: [LaunchResumePickerEntry]

    init(entries: [LaunchResumePickerEntry], selection: Set<UUID>) {
        self.entries = entries
        self.selection = selection
    }

    func selectAll() {
        selection = Set(entries.map { $0.id })
    }

    func selectNone() {
        selection.removeAll()
    }

    func toggle(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    var groupedByWindow: [(windowIndex: Int, entries: [LaunchResumePickerEntry])] {
        let grouped = Dictionary(grouping: entries, by: { $0.windowIndex })
        return grouped.keys.sorted().map { idx in
            (windowIndex: idx, entries: grouped[idx] ?? [])
        }
    }
}

struct LaunchResumePickerView: View {
    @ObservedObject var model: LaunchResumePickerViewModel
    let onComplete: (LaunchResumePickerDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    localized: "launch.resume.heading",
                    defaultValue: "Resume previous session?"
                ))
                .font(.system(size: 15, weight: .semibold))
                Text(String(
                    localized: "launch.resume.subheading",
                    defaultValue: "Pick which workspaces to bring back. Unticked workspaces are not opened."
                ))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.groupedByWindow, id: \.windowIndex) { group in
                        if model.groupedByWindow.count > 1 {
                            Text(String(
                                format: String(
                                    localized: "launch.resume.windowHeader",
                                    defaultValue: "Window %lld"
                                ),
                                group.windowIndex + 1
                            ))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        }
                        ForEach(group.entries) { entry in
                            LaunchResumePickerRow(
                                entry: entry,
                                isSelected: model.selection.contains(entry.id),
                                onToggle: { model.toggle(entry.id) }
                            )
                            Divider().padding(.leading, 18)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 200, maxHeight: 320)

            Divider()

            HStack(spacing: 8) {
                Button(action: model.selectAll) {
                    Text(String(
                        localized: "launch.resume.selectAll",
                        defaultValue: "Select all"
                    ))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Button(action: model.selectNone) {
                    Text(String(
                        localized: "launch.resume.selectNone",
                        defaultValue: "Select none"
                    ))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Spacer()
                Button(action: { onComplete(.skipAll) }) {
                    Text(String(
                        localized: "launch.resume.skip",
                        defaultValue: "Skip"
                    ))
                    .frame(minWidth: 60)
                }
                .keyboardShortcut(.cancelAction)
                Button(action: {
                    if model.selection.isEmpty {
                        onComplete(.skipAll)
                    } else if model.selection.count == model.entries.count {
                        onComplete(.resumeAll)
                    } else {
                        onComplete(.resumeSelected(model.selection))
                    }
                }) {
                    Text(resumeButtonTitle)
                        .frame(minWidth: 96)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.entries.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
    }

    private var resumeButtonTitle: String {
        if model.selection.isEmpty {
            return String(localized: "launch.resume.skip", defaultValue: "Skip")
        }
        if model.selection.count == model.entries.count {
            return String(
                localized: "launch.resume.resumeAll",
                defaultValue: "Resume all"
            )
        }
        let format = String(
            localized: "launch.resume.resumeSelected",
            defaultValue: "Resume %lld"
        )
        return String(format: format, model.selection.count)
    }
}

private struct LaunchResumePickerRow: View {
    let entry: LaunchResumePickerEntry
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 18, alignment: .center)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(secondaryLine)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var secondaryLine: String {
        let countFormat = String(
            localized: "launch.resume.surfaceCount",
            defaultValue: "%lld surface(s)"
        )
        let countText = String(format: countFormat, entry.surfaceCount)
        if entry.surfaceTitles.isEmpty {
            return countText
        }
        let titleList = entry.surfaceTitles.joined(separator: " · ")
        return "\(countText) — \(titleList)"
    }
}
