import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

// Recents data model, ordering and search live in CreateWorkspaceRecents.swift
// and CreateWorkspacePickerLogic.swift; row, tile and search-field views in
// CreateWorkspacePickerViews.swift (C11-240).

/// Globally-remembered last-picked blueprint id. Pre-selects on next sheet
/// open so power users don't keep re-picking their preferred layout.
enum CreateWorkspaceLastLayout {
    static let key = "createWorkspace.lastBlueprintId"

    static func load(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key)
    }

    static func save(_ id: String, defaults: UserDefaults = .standard) {
        defaults.set(id, forKey: key)
    }
}

enum RecentsSort: String, CaseIterable {
    case recent
    case opened

    var label: String {
        switch self {
        case .recent:
            return String(localized: "createWorkspace.recents.sort.recent",
                          defaultValue: "Most recent")
        case .opened:
            return String(localized: "createWorkspace.recents.sort.opened",
                          defaultValue: "Most opened")
        }
    }

    var key: RecentsOrdering.Key { self == .recent ? .recent : .opened }

    func toggle() -> RecentsSort { self == .recent ? .opened : .recent }
}

/// Holds the list's scroll proxy so keyboard handlers can scroll without an
/// onChange observer (a click must never scroll).
private final class ScrollProxyBox {
    var proxy: ScrollViewProxy?
}

private struct ListRow: Identifiable {
    let entry: RecentDirectory
    let match: RecentMatch?
    var kind: RecentRowView.Kind = .recent
    var hasHistory: Bool = true
    var id: String { entry.path }
}

/// The "Cancel" shortcut is Esc only while the query is empty; with a query,
/// Esc clears it first.
private struct CancelShortcut: ViewModifier {
    let active: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.keyboardShortcut(.cancelAction)
        } else {
            content
        }
    }
}

/// Shown when File → New Workspace (⌘N) is triggered. Hosted in its own
/// non-modal window (AppDelegate.presentCreateWorkspaceSheet).
@MainActor
struct CreateWorkspaceSheet: View {
    struct Outcome {
        var workingDirectory: String
        var workspaceName: String
        var plan: WorkspaceApplyPlan
        var launchAgent: Bool
    }

    let initialDirectory: String
    /// Rows the list shows (8...16), computed from the target screen.
    let listRows: Int
    /// Non-nil when even the minimum list does not fit the screen: the whole
    /// sheet scrolls inside this height.
    let maxContentHeight: CGFloat?
    /// Standardized root directories of the workspaces open in this c11.
    let openRoots: () -> Set<String>
    /// Select the open workspace rooted at this path and close the window.
    let onSwitchToOpen: (String) -> Bool
    let onCancel: () -> Void
    let onCreate: (Outcome) -> Void

    @State private var directory: String
    @State private var workspaceName: String = ""
    @State private var selectionId: String
    @State private var launchAgent: Bool = true
    @State private var entries: [BlueprintEntry] = []
    @State private var recentsState = CreateWorkspaceRecents.State()
    @State private var recentsSort: RecentsSort = .recent
    @State private var query: String = ""
    @State private var selectedPath: String?
    @State private var openRootSet: Set<String> = []
    @State private var missingPaths: Set<String> = []
    @State private var verifiedPaths: Set<String> = []
    @State private var pathChildren: [String] = []
    @State private var pathChildrenKey: String = ""
    @State private var pathToken: Int = 0
    @State private var flashPath: String?
    @State private var notice: String?
    @State private var searchFocus = SearchFocusRequest()
    @State private var lastPinChange: Date = .distantPast
    @State private var draggingPin: String?
    @State private var scrollBox = ScrollProxyBox()
    @State private var loadFailureMessage: String?
    @State private var submitting: Bool = false
    @State private var helpPopoverOpen: Bool = false
    @State private var isDropTargeted: Bool = false

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(
        initialDirectory: String,
        listRows: Int = 12,
        maxContentHeight: CGFloat? = nil,
        openRoots: @escaping () -> Set<String> = { [] },
        onSwitchToOpen: @escaping (String) -> Bool = { _ in false },
        onCancel: @escaping () -> Void,
        onCreate: @escaping (Outcome) -> Void
    ) {
        self.initialDirectory = initialDirectory
        self.listRows = listRows
        self.maxContentHeight = maxContentHeight
        self.openRoots = openRoots
        self.onSwitchToOpen = onSwitchToOpen
        _directory = State(initialValue: initialDirectory)
        let seededEntries = Self.computeEntries(forDirectory: initialDirectory)
        _entries = State(initialValue: seededEntries)
        _recentsState = State(initialValue: CreateWorkspaceRecents.loadState())
        _openRootSet = State(initialValue: openRoots())
        let savedLast = CreateWorkspaceLastLayout.load()
        let initial: String
        if let savedLast, seededEntries.contains(where: { $0.id == savedLast }) {
            initial = savedLast
        } else {
            initial = seededEntries.first?.id ?? (BlueprintEntry.starterIds.first ?? "")
        }
        _selectionId = State(initialValue: initial)
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            header
            baseDirectorySection
            layoutsSection
            footer
        }
        .padding(20)
        .frame(width: 720)

        Group {
            if let maxContentHeight {
                ScrollView(.vertical) { content }
                    .frame(width: 720, height: maxContentHeight)
            } else {
                content.fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(BrandColors.surfaceSwiftUI)
        .environment(\.colorScheme, .dark)
        .background(
            PickerKeyMonitor(
                onPinShortcut: { n in
                    openPin(number: n)
                    return true
                },
                onFocusSearch: { requestSearchFocus(selectAll: true) },
                onTypeToSearch: { typed in
                    query += typed
                    requestSearchFocus(selectAll: false)
                },
                onArrow: { moveSelection($0) },
                onEscapeOutsideSearch: {
                    guard !trimmedQuery.isEmpty else { return false }
                    query = ""
                    requestSearchFocus(selectAll: false)
                    return true
                }
            )
        )
        .onAppear {
            reloadEntries()
            reloadRecents()
            openRootSet = openRoots()
            refreshMissing()
        }
        .onChange(of: query) { _, _ in queryDidChange() }
        .onReceive(NotificationCenter.default.publisher(for: CreateWorkspaceRecents.didChangeNotification)) { _ in
            // An agent (or this sheet) changed recents or pins: stay in step.
            reloadRecents()
        }
        .onChange(of: directory) { _, newValue in
            let normalized = RecentsPath.normalize(newValue)
            if selectedPath != normalized {
                selectedPath = recentsState.entries.contains(where: { $0.path == normalized }) ? normalized : nil
            }
        }
    }

    // MARK: - Derived

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var pins: [String] { recentsState.pins }

    private var isPathMode: Bool { RecentsPathMode.isPathQuery(query) }

    private var rows: [ListRow] {
        if isPathMode { return pathModeRows }
        if trimmedQuery.isEmpty {
            return RecentsOrdering.sorted(recentsState.entries, by: recentsSort.key)
                .map { ListRow(entry: $0, match: nil) }
        }
        return RecentsFuzzy.rank(query: trimmedQuery, entries: recentsState.entries, home: Self.home)
            .map { ListRow(entry: $0.entry, match: $0.match) }
    }

    /// Path mode: the typed path first, then the directories under it.
    private var pathModeRows: [ListRow] {
        let resolution = RecentsPathMode.resolve(query: trimmedQuery)
        let key = resolution.listDirectory + "\n" + resolution.namePrefix
        let byPath = Dictionary(recentsState.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return RecentsPathMode.rows(
            resolution: resolution,
            children: pathChildrenKey == key ? pathChildren : [],
            recents: recentsState.entries
        ).map { row in
            ListRow(
                entry: byPath[row.path]
                    ?? RecentDirectory(path: row.path, lastOpenedAt: .distantPast, openCount: 0, pinned: false),
                match: nil,
                kind: row.kind == .typed ? .typed : .child,
                hasHistory: row.isRecent
            )
        }
    }

    private func displayPath(_ path: String) -> String {
        RecentsPath.displayPath(path, home: Self.home)
    }

    private func isOpen(_ path: String) -> Bool { openRootSet.contains(RecentsPath.normalize(path)) }

    private func isMissing(_ path: String) -> Bool { missingPaths.contains(path) }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(String(localized: "createWorkspace.title", defaultValue: "New Workspace"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(String(
                localized: "createWorkspace.subtitle",
                defaultValue: "Pick a working directory and a blueprint to start from."
            ))
            .font(.system(size: 12))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.66))
            .lineLimit(1)
        }
    }

    // MARK: - Base directory (path, pins, search, list)

    private var baseDirectorySection: some View {
        let currentRows = rows
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(
                        localized: "createWorkspace.baseDirectory.label",
                        defaultValue: "Base directory for your new workspace"
                    ))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandColors.whiteSwiftUI)
                    .lineLimit(1)

                    HStack(spacing: 8) {
                        TextField("", text: $directory)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { activate(directory, alt: NSEvent.modifierFlags.contains(.option)) }
                        Button {
                            chooseDirectory()
                        } label: {
                            Label(
                                String(localized: "createWorkspace.browse", defaultValue: "Browse…"),
                                systemImage: "folder"
                            )
                            .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "createWorkspace.name", defaultValue: "Workspace name"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrandColors.whiteSwiftUI)
                        .lineLimit(1)
                    TextField(
                        "",
                        text: $workspaceName,
                        prompt: Text(defaultWorkspaceName)
                            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.4))
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .controlSize(.large)
                    .onSubmit { submit() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(String(
                    localized: "createWorkspace.name.hint",
                    defaultValue: "Defaults to the directory name. Override to give this workspace a custom label."
                ))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [BrandColors.whiteSwiftUI.opacity(0.02), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            if recentsState.entries.isEmpty {
                recentsEmptyState
            } else {
                pinsSection
                searchBar(matchCount: currentRows.count)
                recentsList(currentRows)
                recentsFooter
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(BrandColors.surface2SwiftUI)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isDropTargeted ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI,
                    lineWidth: 1
                )
        )
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .fill(BrandColors.surfaceSwiftUI.opacity(0.78))
                    .overlay(
                        Text(String(
                            localized: "createWorkspace.dropTarget",
                            defaultValue: "Drop folder to set base directory"
                        ))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrandColors.goldSwiftUI)
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: Pins

    private var pinsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(localized: "createWorkspace.pins.caption", defaultValue: "PINNED"))
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
                Spacer()
                if !pins.isEmpty {
                    Text(String(
                        localized: "createWorkspace.pins.aside",
                        defaultValue: "Drag to reorder · ⌘1–⌘9 opens"
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.32))
                }
            }
            .padding(.trailing, 14)

            if pins.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "star")
                        .font(.system(size: 11))
                    Text(String(
                        localized: "createWorkspace.pins.empty",
                        defaultValue: "Star a recent directory to pin it here"
                    ))
                    .font(.system(size: 11))
                }
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.4))
                .frame(maxWidth: .infinity)
                .frame(height: PinTileView.height - 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color(white: 0.23), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .padding(.trailing, 14)
            } else {
                pinGrid
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 10)
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColors.surfaceSwiftUI.opacity(0.25))
        .overlay(alignment: .top) {
            Rectangle().fill(BrandColors.ruleSwiftUI).frame(height: 1)
        }
    }

    private var pinGrid: some View {
        let pinRows = PinGridShape.rowsOfPins(pins)
        let columns = PinGridShape.columns(forPinCount: pins.count)
        let gridHeight = CGFloat(pinRows.count) * PinTileView.height + CGFloat(max(0, pinRows.count - 1)) * 8 + 10
        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(pinRows.enumerated()), id: \.offset) { rowIdx, rowPins in
                    HStack(spacing: 8) {
                        ForEach(Array(rowPins.enumerated()), id: \.element) { colIdx, path in
                            pinTile(path: path, index: rowIdx * columns + colIdx)
                        }
                    }
                }
            }
            .padding(.trailing, 14)
            .padding(.bottom, 8)
        }
        .frame(height: gridHeight)
    }

    private func pinTile(path: String, index: Int) -> some View {
        PinTileView(
            path: path,
            index: index,
            displayPath: displayPath(path),
            isSelected: selectedPath == path,
            isOpen: isOpen(path),
            isMissing: isMissing(path),
            isFlashing: flashPath == path,
            actions: actions(for: path),
            onClick: { select(path) },
            onDoubleClick: { alt in doubleClicked(path, alt: alt) },
            onUnpin: { setPinned(path, false) }
        )
        .onDrag {
            draggingPin = path
            return NSItemProvider(object: path as NSString)
        }
        .onDrop(
            of: [.plainText],
            delegate: PinReorderDropDelegate(
                target: path,
                dragging: $draggingPin,
                pins: { pins },
                move: { moved, to in movePin(moved, to: to) }
            )
        )
    }

    // MARK: Search + sort

    private func searchBar(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            PickerSearchField(
                text: $query,
                placeholder: String(
                    format: String(
                        localized: "createWorkspace.search.placeholder",
                        defaultValue: "Search %d recent directories"
                    ),
                    recentsState.entries.count
                ),
                focusRequest: searchFocus,
                onMove: { moveSelection($0) },
                onSubmit: { alt in activateCurrent(alt: alt) },
                onEscape: { onCancel() },
                onTab: { completeSelection() }
            )
            .frame(height: 26)

            Group {
                if trimmedQuery.isEmpty {
                    kbdGlyph("⌘F")
                } else if isPathMode {
                    Text(String(localized: "createWorkspace.search.pathMode", defaultValue: "path"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(BrandColors.goldSwiftUI)
                } else {
                    Text(String(
                        format: String(localized: "createWorkspace.search.count", defaultValue: "%d of %d"),
                        matchCount,
                        recentsState.entries.count
                    ))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.55))
                }
            }
            .frame(width: 64, alignment: .trailing)

            Button {
                recentsSort = recentsSort.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(recentsSort.label)
                        .font(.system(size: 11))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .frame(width: 112, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(BrandColors.surface3SwiftUI)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(BrandColors.ruleSwiftUI, lineWidth: 0.5)
                )
                .opacity(trimmedQuery.isEmpty ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!trimmedQuery.isEmpty)
            .help(trimmedQuery.isEmpty
                  ? ""
                  : String(
                    localized: "createWorkspace.search.sortDisabled",
                    defaultValue: "Search results are ranked by match"
                  ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(BrandColors.surfaceSwiftUI.opacity(0.25))
        .overlay(alignment: .top) {
            Rectangle().fill(BrandColors.ruleSwiftUI).frame(height: 1)
        }
    }

    // MARK: List

    private func recentsList(_ currentRows: [ListRow]) -> some View {
        let height = CGFloat(listRows) * RecentRowView.height
        return Group {
            if currentRows.isEmpty {
                VStack(spacing: 4) {
                    Text(String(
                        format: String(
                            localized: "createWorkspace.search.noMatch",
                            defaultValue: "No recent directory matches “%@”."
                        ),
                        trimmedQuery
                    ))
                    Text(String(
                        localized: "createWorkspace.search.noMatchHint",
                        defaultValue: "Type a path in the field above, or Browse…"
                    ))
                    .opacity(0.7)
                }
                .font(.system(size: 12))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(currentRows) { row in
                                RecentRowView(
                                    kind: row.kind,
                                    hasHistory: row.hasHistory,
                                    recent: row.entry,
                                    displayPath: displayPath(row.entry.path),
                                    match: row.match,
                                    isSelected: selectedPath == row.entry.path,
                                    isOpen: isOpen(row.entry.path),
                                    isMissing: isMissing(row.entry.path),
                                    isFlashing: flashPath == row.entry.path,
                                    actions: actions(for: row.entry.path),
                                    onClick: { select(row.entry.path) },
                                    onDoubleClick: { alt in doubleClicked(row.entry.path, alt: alt) },
                                    onTogglePin: { setPinned(row.entry.path, !row.entry.pinned) }
                                )
                                .id(row.entry.path)
                            }
                        }
                    }
                    .onAppear { scrollBox.proxy = proxy }
                }
            }
        }
        .frame(height: height)
        .overlay(alignment: .top) {
            Rectangle().fill(BrandColors.ruleSwiftUI).frame(height: 1)
        }
    }

    private var recentsFooter: some View {
        HStack(spacing: 6) {
            if let notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(BrandColors.goldSwiftUI)
                    .lineLimit(1)
            } else if isPathMode {
                kbdGlyph("⇥")
                Text(String(localized: "createWorkspace.hint.pathComplete", defaultValue: "completes the highlighted folder"))
                dotSeparator
                kbdGlyph("⏎")
                Text(String(localized: "createWorkspace.hint.pathCreate", defaultValue: "creates in the highlighted path"))
                dotSeparator
                kbdGlyph("↑↓")
                Text(String(localized: "createWorkspace.hint.move", defaultValue: "move"))
            } else {
                Text(String(localized: "createWorkspace.hint.click", defaultValue: "Click selects"))
                dotSeparator
                Text(String(localized: "createWorkspace.hint.doubleClickOr", defaultValue: "double-click or"))
                kbdGlyph("⏎")
                Text(String(localized: "createWorkspace.hint.creates", defaultValue: "creates"))
                dotSeparator
                kbdGlyph("↑↓")
                Text(String(localized: "createWorkspace.hint.move", defaultValue: "move"))
                dotSeparator
                kbdGlyph("⌘1")
                Text("–")
                kbdGlyph("⌘9")
                Text(String(localized: "createWorkspace.hint.openPin", defaultValue: "open a pin"))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(BrandColors.surfaceSwiftUI.opacity(0.25))
        .overlay(alignment: .top) {
            Rectangle().fill(BrandColors.ruleSwiftUI).frame(height: 1)
        }
    }

    private var dotSeparator: some View {
        Text("·").foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.3))
    }

    private var recentsEmptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        BrandColors.whiteSwiftUI.opacity(0.30),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
            }
            .frame(width: 38, height: 38)
            Text(String(
                localized: "createWorkspace.recents.empty.title",
                defaultValue: "No recent directories yet"
            ))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(BrandColors.whiteSwiftUI)
            Text(String(
                localized: "createWorkspace.recents.empty.hint",
                defaultValue: "Pick a directory above, browse to one, or drag a folder here."
            ))
            .font(.system(size: 11))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .overlay(alignment: .top) {
            Rectangle().fill(BrandColors.ruleSwiftUI).frame(height: 1)
        }
    }

    @ViewBuilder
    private func kbdGlyph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.78))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(BrandColors.surface3SwiftUI)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(BrandColors.ruleSwiftUI, lineWidth: 0.5)
            )
    }

    // MARK: - Selection and activation

    private func requestSearchFocus(selectAll: Bool) {
        searchFocus = SearchFocusRequest(id: searchFocus.id + 1, selectAll: selectAll)
    }

    /// A click selects and fills the path field. It never scrolls.
    private func select(_ path: String, scrollIntoView: Bool = false) {
        selectedPath = path
        directory = path
        if scrollIntoView {
            scrollBox.proxy?.scrollTo(path, anchor: nil)
        }
    }

    /// ↑↓ move the selection through the visible list and scroll only as far
    /// as needed to keep it in view.
    private func moveSelection(_ delta: Int) {
        let currentRows = rows
        guard !currentRows.isEmpty else { return }
        let current = selectedPath.flatMap { p in currentRows.firstIndex(where: { $0.id == p }) }
        var next: Int
        if let current {
            next = current + delta
        } else {
            next = delta > 0 ? 0 : currentRows.count - 1
        }
        next = max(0, min(currentRows.count - 1, next))
        select(currentRows[next].id, scrollIntoView: true)
    }

    private func queryDidChange() {
        guard !trimmedQuery.isEmpty else { return }
        if isPathMode {
            refreshPathChildren()
            select(RecentsPathMode.resolve(query: trimmedQuery).typedPath)
            scrollBox.proxy?.scrollTo(RecentsPathMode.resolve(query: trimmedQuery).typedPath, anchor: .top)
            return
        }
        let currentRows = rows
        if let top = currentRows.first {
            select(top.id)
            scrollBox.proxy?.scrollTo(top.id, anchor: .top)
        } else {
            selectedPath = nil
        }
    }

    /// Real filesystem children of the typed path, listed off the main thread;
    /// the typed path is stat'ed there too, so a missing path shows as missing.
    private func refreshPathChildren() {
        let resolution = RecentsPathMode.resolve(query: trimmedQuery)
        let key = resolution.listDirectory + "\n" + resolution.namePrefix
        pathToken += 1
        let token = pathToken
        DispatchQueue.global(qos: .userInitiated).async {
            let kids = RecentsPathMode.listChildren(of: resolution.listDirectory, prefix: resolution.namePrefix)
            let exists = Workspace.isExistingDirectory(resolution.typedPath)
            DispatchQueue.main.async {
                guard token == pathToken else { return }
                pathChildren = kids
                pathChildrenKey = key
                if exists {
                    missingPaths.remove(resolution.typedPath)
                    verifiedPaths.insert(resolution.typedPath)
                } else {
                    verifiedPaths.remove(resolution.typedPath)
                    missingPaths.insert(resolution.typedPath)
                }
            }
        }
    }

    /// Tab in path mode completes the highlighted folder (the first one when
    /// the typed row is highlighted), leaving the caret after a trailing slash.
    private func completeSelection() -> Bool {
        guard isPathMode else { return false }
        let currentRows = rows
        let highlighted = selectedPath.flatMap { p in currentRows.first(where: { $0.id == p && $0.kind == .child }) }
        guard let target = highlighted ?? currentRows.first(where: { $0.kind == .child }) else { return true }
        query = RecentsPathMode.completion(of: target.id, forQuery: query, home: Self.home)
        requestSearchFocus(selectAll: false)
        return true
    }

    /// The top hit is auto-selected while searching, so ⏎ opens it.
    private func activateCurrent(alt: Bool) {
        let target: String
        if !trimmedQuery.isEmpty {
            guard let path = selectedPath ?? rows.first?.id else {
                NSSound.beep()
                return
            }
            target = path
        } else {
            target = selectedPath ?? directory
        }
        activate(target, alt: alt)
    }

    private func doubleClicked(_ path: String, alt: Bool) {
        // A click on a star or × changes the layout under the cursor; a second
        // click landing within 400 ms belongs to the old layout.
        guard Date().timeIntervalSince(lastPinChange) > 0.4 else { return }
        select(path)
        activate(path, alt: alt)
    }

    private func openPin(number: Int) {
        guard number >= 1, number <= pins.count else { return }
        let path = pins[number - 1]
        select(path)
        activate(path, alt: false)
    }

    private func activate(_ rawPath: String, alt: Bool) {
        let path = RecentsPath.normalize(rawPath)
        guard !path.isEmpty else { return }
        if alt, openRootSet.contains(path), onSwitchToOpen(path) {
            return
        }
        if missingPaths.contains(path) {
            flash(path)
            showNotice(String(
                format: String(
                    localized: "createWorkspace.notice.missing",
                    defaultValue: "“%@” no longer exists, so no workspace was created."
                ),
                RecentsPath.lastComponent(path)
            ))
            return
        }
        if !verifiedPaths.contains(path) {
            // Not stat'ed yet (a path typed a moment ago): check off the main
            // thread, then decide.
            DispatchQueue.global(qos: .userInitiated).async {
                let exists = Workspace.isExistingDirectory(path)
                DispatchQueue.main.async {
                    if exists { verifiedPaths.insert(path) } else { missingPaths.insert(path) }
                    activate(rawPath, alt: alt)
                }
            }
            return
        }
        directory = rawPath.hasPrefix("~") ? rawPath : path
        submit()
    }

    private func flash(_ path: String) {
        flashPath = path
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if flashPath == path { flashPath = nil }
        }
    }

    private func showNotice(_ message: String) {
        notice = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if notice == message { notice = nil }
        }
    }

    // MARK: - Recents mutations

    private func reloadRecents() {
        recentsState = CreateWorkspaceRecents.loadState()
    }

    private func setPinned(_ path: String, _ pinned: Bool) {
        lastPinChange = Date()
        let ok = CreateWorkspaceRecents.mutate { state in
            if pinned { state.pin(path) } else { state.unpin(path) }
        }
        if !ok { showNotice(unreadableNotice) }
        reloadRecents()
    }

    private func movePin(_ path: String, to index: Int) {
        lastPinChange = Date()
        CreateWorkspaceRecents.movePin(path, to: index)
        reloadRecents()
    }

    private func removeRecent(_ path: String) {
        lastPinChange = Date()
        let ok = CreateWorkspaceRecents.mutate { $0.remove(path) }
        if !ok { showNotice(unreadableNotice) }
        if selectedPath == path { selectedPath = nil }
        reloadRecents()
    }

    private var unreadableNotice: String {
        String(
            localized: "createWorkspace.notice.unreadable",
            defaultValue: "Saved recents could not be read, so nothing was changed."
        )
    }

    private func actions(for path: String) -> RecentActions {
        RecentActions(
            isPinned: pins.contains(path),
            isOpen: isOpen(path),
            isMissing: isMissing(path),
            create: { select(path); activate(path, alt: false) },
            switchToOpen: {
                if !onSwitchToOpen(RecentsPath.normalize(path)) { NSSound.beep() }
            },
            togglePin: { setPinned(path, !pins.contains(path)) },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
            copyPath: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            remove: { removeRecent(path) }
        )
    }

    /// Stat every recent off the main thread (a hung network mount must not
    /// stall the UI). Results are cached for this open of the sheet.
    private func refreshMissing() {
        let paths = recentsState.entries.map(\.path)
        for path in paths {
            DispatchQueue.global(qos: .utility).async {
                let exists = Workspace.isExistingDirectory((path as NSString).expandingTildeInPath)
                DispatchQueue.main.async {
                    if exists { verifiedPaths.insert(path) } else { missingPaths.insert(path) }
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                   isDir.boolValue {
                    directory = url.path
                }
            }
        }
        return true
    }

    // MARK: - Workspace name (the right half of the panel head)

    private var defaultWorkspaceName: String {
        let trimmed = directory.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Workspace" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let last = URL(fileURLWithPath: expanded).lastPathComponent
        return last.isEmpty ? "Workspace" : last
    }

    private var effectiveWorkspaceName: String {
        let trimmed = workspaceName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? defaultWorkspaceName : trimmed
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = String(
            localized: "createWorkspace.browse.panelTitle",
            defaultValue: "Choose Working Directory"
        )
        if !directory.isEmpty {
            let expanded = (directory as NSString).expandingTildeInPath
            panel.directoryURL = URL(fileURLWithPath: expanded)
        }
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
        }
    }

    // MARK: - Layouts (one consolidated row: defaults + custom blueprints)

    private var layoutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(String(localized: "createWorkspace.layouts", defaultValue: "Layouts"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandColors.whiteSwiftUI)
                Button {
                    helpPopoverOpen.toggle()
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(
                    localized: "createWorkspace.customBlueprints.helpHint",
                    defaultValue: "What is a custom blueprint?"
                ))
                .popover(isPresented: $helpPopoverOpen, arrowEdge: .top) {
                    helpPopoverContent
                }
                Spacer()
            }

            DragScrollView {
                HStack(spacing: 10) {
                    ForEach(starterEntries) { entry in
                        blueprintCard(entry, showLetters: true)
                    }
                    if !savedEntries.isEmpty {
                        Rectangle()
                            .fill(BrandColors.ruleSwiftUI)
                            .frame(width: 1, height: 80)
                            .padding(.horizontal, 4)
                    }
                    ForEach(savedEntries) { entry in
                        blueprintCard(entry, showLetters: false)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(height: 118)

            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: "cursorarrow.click.2")
                        .font(.system(size: 11, weight: .semibold))
                    Text(String(
                        localized: "createWorkspace.layouts.doubleClickHint",
                        defaultValue: "Double-click a layout to create instantly"
                    ))
                    .font(.system(size: 11))
                }
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.45))
                Spacer()
                legendBadge("A", String(localized: "createWorkspace.legend.agent", defaultValue: "agent"))
                legendBadge("T", String(localized: "createWorkspace.legend.terminal", defaultValue: "terminal"))
                legendBadge("B", String(localized: "createWorkspace.legend.browser", defaultValue: "browser"))
                legendBadge("M", String(localized: "createWorkspace.legend.markdown", defaultValue: "markdown"))
            }

            if let loadFailureMessage {
                Text(loadFailureMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.5))
            }
        }
    }

    @ViewBuilder
    private func legendBadge(_ letter: String, _ word: String) -> some View {
        HStack(spacing: 4) {
            Text(letter)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.85))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(BrandColors.surface3SwiftUI)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(BrandColors.ruleSwiftUI, lineWidth: 0.5)
                )
            Text(word)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.5))
        }
    }

    private var helpPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(
                localized: "createWorkspace.customBlueprints.help.body1",
                defaultValue: "Saved pane and surface layouts you can launch a workspace from."
            ))
            Text(String(
                localized: "createWorkspace.customBlueprints.help.body2",
                defaultValue: "c11 is agent-first software, so we didn't build a UI to make these. Just ask your agent. It can write a blueprint file to your blueprints folder, and it'll show up here."
            ))
            Button {
                revealBlueprintsFolder()
            } label: {
                Label(
                    String(
                        localized: "createWorkspace.customBlueprints.help.reveal",
                        defaultValue: "Reveal blueprints folder"
                    ),
                    systemImage: "folder"
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .font(.system(size: 12))
        .frame(width: 320)
        .padding(14)
    }

    private func revealBlueprintsFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".config/c11/blueprints", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Blueprint card (shared by default + custom)

    @ViewBuilder
    private func blueprintCard(_ entry: BlueprintEntry, showLetters: Bool) -> some View {
        let isSelected = entry.id == selectionId
        VStack(alignment: .center, spacing: 8) {
            if showLetters, let topology = entry.shape.letterTopology {
                LetterCellIcon(topology: topology)
                    .frame(width: 60, height: 38)
            } else {
                OutlineShapeIcon(shape: entry.shape)
                    .frame(width: 60, height: 38)
            }
            Text(entry.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.top, 4)
        .frame(width: 80, height: 80, alignment: .center)
        .padding(8)
        .frame(width: 96, height: 96)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? BrandColors.goldFaintSwiftUI : BrandColors.surface2SwiftUI)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isSelected ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI,
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help(entry.description ?? entry.label)
        // Single-click selects, double-click selects and submits. A SwiftUI
        // Button swallows the second click, so the card is a plain View with
        // composed taps.
        .gesture(
            TapGesture(count: 2).onEnded {
                selectionId = entry.id
                CreateWorkspaceLastLayout.save(entry.id)
                submit()
            }
        )
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                selectionId = entry.id
                CreateWorkspaceLastLayout.save(entry.id)
            }
        )
    }

    private var starterEntries: [BlueprintEntry] {
        entries.filter { $0.kind == .starter }
    }

    private var savedEntries: [BlueprintEntry] {
        entries.filter { $0.kind == .saved }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Toggle(isOn: $launchAgent) {
                Text(String(
                    localized: "createWorkspace.launchAgent",
                    defaultValue: "Launch your default coding agent in the first pane"
                ))
                .font(.system(size: 11))
                .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.75))
            }
            .toggleStyle(.checkbox)
            Spacer()
            Button(String(localized: "common.cancel", defaultValue: "Cancel")) {
                onCancel()
            }
            .modifier(CancelShortcut(active: trimmedQuery.isEmpty))

            Button {
                activateCurrent(alt: NSEvent.modifierFlags.contains(.option))
            } label: {
                HStack(spacing: 8) {
                    Text(String(
                        localized: "createWorkspace.createWorkspace",
                        defaultValue: "Create Workspace"
                    ))
                    Text("\u{23CE}")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.55)
                }
            }
            .buttonStyle(GoldCTAButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
    }

    /// With a query and no match there is nothing to create: disable Create so
    /// ⏎ never creates in a stale directory.
    private var canSubmit: Bool {
        !submitting
            && !directory.trimmingCharacters(in: .whitespaces).isEmpty
            && entries.contains(where: { $0.id == selectionId })
            && (trimmedQuery.isEmpty || selectedPath != nil || !rows.isEmpty)
    }

    private func submit() {
        guard !submitting else { return }
        guard let entry = entries.first(where: { $0.id == selectionId }) else { return }
        submitting = true
        let plan: WorkspaceApplyPlan
        do {
            plan = try entry.loadPlan()
        } catch {
            loadFailureMessage = String(
                format: String(
                    localized: "createWorkspace.loadFailed",
                    defaultValue: "Could not load blueprint: %@"
                ),
                "\(error)"
            )
            submitting = false
            return
        }
        let resolvedDir = (directory as NSString).expandingTildeInPath
        CreateWorkspaceLastLayout.save(entry.id)
        onCreate(Outcome(
            workingDirectory: resolvedDir,
            workspaceName: effectiveWorkspaceName,
            plan: plan,
            launchAgent: launchAgent
        ))
    }

    // MARK: - Loading

    private func reloadEntries() {
        let collected = Self.computeEntries(forDirectory: directory)
        entries = collected
        if !entries.contains(where: { $0.id == selectionId }) {
            if let savedLast = CreateWorkspaceLastLayout.load(),
               entries.contains(where: { $0.id == savedLast }) {
                selectionId = savedLast
            } else {
                selectionId = entries.first?.id ?? ""
            }
        }
    }

    private static func computeEntries(forDirectory directory: String) -> [BlueprintEntry] {
        let store = WorkspaceBlueprintStore()
        let cwdURL: URL? = {
            let trimmed = directory.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }()
        let allIndex = store.merged(cwd: cwdURL)
        var collected: [BlueprintEntry] = []
        let starterDefs = BlueprintEntry.starterDefinitions
        for def in starterDefs {
            if let match = allIndex.first(where: { $0.name == def.fileName }) {
                collected.append(BlueprintEntry(
                    id: def.starterId,
                    kind: .starter,
                    label: def.label,
                    description: def.description,
                    shape: def.shape,
                    sourceBadge: nil,
                    loader: .index(match)
                ))
            }
        }
        let starterFileNames = Set(starterDefs.map(\.fileName))
        for index in allIndex where !starterFileNames.contains(index.name) {
            collected.append(BlueprintEntry(
                id: "saved:\(index.url)",
                kind: .saved,
                label: index.name,
                description: index.description,
                shape: .custom,
                sourceBadge: badge(for: index.source),
                loader: .index(index)
            ))
        }
        return collected
    }

    private static func badge(for source: WorkspaceBlueprintIndex.Source) -> String {
        switch source {
        case .repo:    return String(localized: "createWorkspace.badge.repo", defaultValue: "Repo")
        case .user:    return String(localized: "createWorkspace.badge.user", defaultValue: "User")
        case .builtIn: return String(localized: "createWorkspace.badge.builtIn", defaultValue: "Built-in")
        }
    }
}

// MARK: - Gold CTA button style

/// The standard c11 gold button (solid gold fill, void-black content) sized
/// up as a sheet's primary call to action. Module-internal so other sheets
/// (e.g. the agent-config editor, C11-182) reuse the exact gold-CTA idiom.
struct GoldCTAButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(
                isEnabled ? BrandColors.blackSwiftUI : BrandColors.whiteSwiftUI.opacity(0.35)
            )
            .padding(.horizontal, 26)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isEnabled
                        ? BrandColors.goldSwiftUI.opacity(configuration.isPressed ? 0.82 : 1.0)
                        : BrandColors.surface3SwiftUI
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isEnabled ? BrandColors.goldSwiftUI : BrandColors.ruleSwiftUI,
                        lineWidth: isEnabled ? 0.75 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Internal blueprint entry model

private struct BlueprintEntry: Identifiable {
    enum Kind { case starter, saved }
    enum Loader {
        case index(WorkspaceBlueprintIndex)
    }

    let id: String
    let kind: Kind
    let label: String
    let description: String?
    let shape: BlueprintShape
    let sourceBadge: String?
    let loader: Loader

    func loadPlan() throws -> WorkspaceApplyPlan {
        switch loader {
        case .index(let index):
            let url = URL(fileURLWithPath: index.url)
            let file = try WorkspaceBlueprintStore().read(url: url)
            return file.plan
        }
    }

    struct Definition {
        let starterId: String
        let label: String
        let description: String
        let fileName: String
        let shape: BlueprintShape
    }

    static let starterDefinitions: [Definition] = [
        Definition(
            starterId: "starter:one-column",
            label: String(localized: "createWorkspace.starter.single.label", defaultValue: "Single"),
            description: String(
                localized: "createWorkspace.starter.single.description",
                defaultValue: "One terminal pane filling the workspace."
            ),
            fileName: "basic-terminal",
            shape: .oneColumn
        ),
        Definition(
            starterId: "starter:two-columns",
            label: String(localized: "createWorkspace.starter.twoColumns.label", defaultValue: "Two columns"),
            description: String(
                localized: "createWorkspace.starter.twoColumns.description",
                defaultValue: "Two terminals split side by side. Agent left, terminal right."
            ),
            fileName: "side-by-side",
            shape: .twoColumns
        ),
        Definition(
            starterId: "starter:quad",
            label: String(localized: "createWorkspace.starter.quad.label", defaultValue: "2 × 2"),
            description: String(
                localized: "createWorkspace.starter.quad.description",
                defaultValue: "Four terminal panes in a 2 × 2 grid. Agent in the top-left."
            ),
            fileName: "quad-terminal",
            shape: .quad
        ),
        Definition(
            starterId: "starter:two-by-three",
            label: String(localized: "createWorkspace.starter.twoByThree.label", defaultValue: "2 × 3"),
            description: String(
                localized: "createWorkspace.starter.twoByThree.description",
                defaultValue: "Six terminal panes in 2 columns, 3 rows. External 27-inch+ monitor suggested."
            ),
            fileName: "two-by-three",
            shape: .twoByThree
        ),
    ]

    static let starterIds: [String] = starterDefinitions.map(\.starterId)
}

// MARK: - Shape model

enum BlueprintShape {
    case oneColumn
    case twoColumns
    case quad
    case twoByThree
    case custom

    /// Returns the cell topology (rows of letter cells) for default-layout
    /// icons. Custom blueprints return nil and are rendered with the
    /// outline-only fallback.
    var letterTopology: LetterTopology? {
        switch self {
        case .oneColumn:
            return LetterTopology(rows: [["A"]])
        case .twoColumns:
            return LetterTopology(rows: [["A", "T"]])
        case .quad:
            return LetterTopology(rows: [
                ["A", "T"],
                ["T", "T"],
            ])
        case .twoByThree:
            return LetterTopology(rows: [
                ["A", "T"],
                ["T", "T"],
                ["T", "T"],
            ])
        case .custom:
            return nil
        }
    }
}

struct LetterTopology {
    let rows: [[String]]
}

// MARK: - Letter-cell icon (default layouts)

private struct LetterCellIcon: View {
    let topology: LetterTopology

    var body: some View {
        let stroke = BrandColors.whiteSwiftUI.opacity(0.55)
        VStack(spacing: 1) {
            ForEach(Array(topology.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 1) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, letter in
                        ZStack {
                            Rectangle()
                                .fill(BrandColors.surface2SwiftUI)
                            Text(letter)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(stroke)
                        }
                    }
                }
            }
        }
        .background(stroke)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(stroke, lineWidth: 0.5)
        )
    }
}

// MARK: - Outline-only icon (custom blueprints)

private struct OutlineShapeIcon: View {
    let shape: BlueprintShape

    var body: some View {
        let stroke = BrandColors.whiteSwiftUI.opacity(0.55)
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(stroke, lineWidth: 1)
                Rectangle()
                    .fill(stroke.opacity(0.45))
                    .frame(width: geo.size.width * 0.4, height: 1)
            }
        }
    }
}

// MARK: - Brand color shims

extension BrandColors {
    static var surface2SwiftUI: Color { Color(red: 0.12, green: 0.12, blue: 0.135) }
    static var surface3SwiftUI:  Color { Color(red: 0.175, green: 0.175, blue: 0.196) }
}

// MARK: - Horizontal scroll with click-and-drag

/// Horizontal scroll container that supports click-and-drag panning alongside
/// trackpad/scroll-wheel gestures. The drag handling uses an application-level
/// NSEvent monitor (more robust than NSPanGestureRecognizer, which has been
/// observed to wedge after a scroll-wheel event interrupts its state machine).
/// A visible horizontal scrollbar is always shown so the affordance is
/// explicit even before the user attempts to scroll.
private struct DragScrollView<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false

        let hosting = NSHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        if let documentView = scrollView.documentView, let contentView = scrollView.contentView as NSClipView? {
            NSLayoutConstraint.activate([
                documentView.topAnchor.constraint(equalTo: contentView.topAnchor),
                documentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                documentView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            ])
        }

        context.coordinator.scrollView = scrollView
        context.coordinator.installMonitor()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let hosting = nsView.documentView as? NSHostingView<Content> {
            hosting.rootView = content
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        private var monitor: Any?
        private var pressLocation: NSPoint?
        private var lastLocation: NSPoint?
        private var didPan = false
        private let threshold: CGFloat = 4

        deinit { removeMonitor() }

        func removeMonitor() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self else { return event }
                return self.process(event)
            }
        }

        private func process(_ event: NSEvent) -> NSEvent? {
            guard let sv = scrollView,
                  let window = sv.window,
                  event.window === window else {
                return event
            }
            let pointInSv = sv.convert(event.locationInWindow, from: nil)
            let inside = sv.bounds.contains(pointInSv)

            switch event.type {
            case .leftMouseDown:
                if inside {
                    pressLocation = event.locationInWindow
                    lastLocation = event.locationInWindow
                    didPan = false
                } else {
                    pressLocation = nil
                    lastLocation = nil
                    didPan = false
                }
                return event

            case .leftMouseDragged:
                guard let start = pressLocation, let last = lastLocation else {
                    return event
                }
                let dx = event.locationInWindow.x - start.x
                let dy = event.locationInWindow.y - start.y
                if !didPan && hypot(dx, dy) > threshold {
                    didPan = true
                }
                if didPan {
                    let stepDx = event.locationInWindow.x - last.x
                    let origin = sv.contentView.bounds.origin
                    let docWidth = sv.documentView?.bounds.width ?? 0
                    let viewWidth = sv.contentView.bounds.width
                    let maxX = max(0, docWidth - viewWidth)
                    let nextX = min(maxX, max(0, origin.x - stepDx))
                    sv.contentView.scroll(to: NSPoint(x: nextX, y: origin.y))
                    sv.reflectScrolledClipView(sv.contentView)
                    lastLocation = event.locationInWindow
                    return nil
                }
                return event

            case .leftMouseUp:
                let panned = didPan
                pressLocation = nil
                lastLocation = nil
                didPan = false
                return panned ? nil : event

            default:
                return event
            }
        }
    }
}
