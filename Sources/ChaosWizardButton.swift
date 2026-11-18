import AppKit
import SwiftUI

// MARK: - Chaos Wizard button (C11H-199)

/// The cast the button fires. One per app, so a cast in flight keeps its
/// state when the footer slot swaps to Flagged or the column count changes.
/// Main-actor state; the draw and the cast run on a background queue because
/// `agent.launch` refuses main.
@MainActor
final class ChaosCastModel: ObservableObject {
    static let shared = ChaosCastModel()

    /// A cast that failed, shown under the Chaos button of the window it was
    /// cast from until dismissed. Model state, so it survives the button
    /// leaving the footer (Flagged takes its slot while a flag is up).
    struct Failure {
        let windowId: UUID?
        let message: String
    }

    @Published private(set) var isCasting = false
    @Published var failure: Failure?

    /// Draw two fresh commissions and cast them into `windowId`'s window,
    /// selecting the new workspace if the window still shows
    /// `expectedSelection` (an operator gesture).
    func castTwo(windowId: UUID?, expectedSelection: UUID?) {
        guard !isCasting else { return }
        isCasting = true
        failure = nil
        let controller = TerminalController.shared
        let windowRef = windowId?.uuidString
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let drawn = ChaosCaster.draw(mode: .two)
            let plan = ChaosCaster.plan(mode: .two, seed: drawn.seed, pieces: drawn.pieces)
            let outcome = ChaosCaster.cast(plan, controller: controller, windowRef: windowRef,
                                           select: true, expectedSelection: expectedSelection)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCasting = false
                guard let error = outcome.error else { return }
                var message = error.message
                if !outcome.launched.isEmpty {
                    message = String(localized: "chaos.error.partial",
                                     defaultValue: "Cast stopped after \(outcome.launched.count) of \(plan.slots.count) pieces.")
                        + " " + error.message
                }
                self.failure = Failure(windowId: windowId, message: message)
            }
        }
    }
}

/// The footer pill beside Waiting. Click: cast two agents on two fresh wild
/// prompts, side by side, at once. Right-click: the gallery, the folder and the deck.
/// Quiet at rest like an unlit Waiting pill: it is a tool, never an attention signal.
struct ChaosWizardButton: View {
    let style: SidebarThemeStyle

    @ObservedObject private var model = ChaosCastModel.shared
    @State private var isHovering = false
    /// The window this button lives in. A click in a background window does
    /// not make it key, so the key window is only the fallback.
    @State private var host = ChaosHostWindow()

    static let magenta = Color(red: 184.0 / 255.0, green: 50.0 / 255.0, blue: 122.0 / 255.0)

    private var label: String {
        model.isCasting
            ? String(localized: "chaos.draw.casting", defaultValue: "Casting…")
            : String(localized: "sidebar.chaos.title", defaultValue: "Chaos")
    }

    private var ink: Color {
        style.effectivePillStyle == nil ? BrandColors.whiteSwiftUI.opacity(0.72) : (style.cardText ?? BrandColors.whiteSwiftUI.opacity(0.72))
    }

    private var isEngaged: Bool { isHovering || model.isCasting }

    private var edge: Color {
        if isEngaged { return Self.magenta }
        return style.effectivePillStyle == nil ? BrandColors.ruleSwiftUI : (style.cardBorder ?? BrandColors.ruleSwiftUI)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.pillRadius ?? 6, style: .continuous)
        Button(action: cast) {
            HStack(spacing: 6) {
                Text(verbatim: style.pill.apply(label))
                    .chromeStyle(style.pill, size: 11, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Image(systemName: ChaosSettings.groupIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isEngaged ? Self.magenta : ink)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(shape.fill(style.effectivePillStyle == nil ? BrandColors.surfaceSwiftUI : (style.cardFill ?? BrandColors.surfaceSwiftUI)))
            .overlay(shape.stroke(edge, lineWidth: 1))
            .foregroundColor(ink)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .overlay {
            if style.hoverBrackets, isHovering {
                SidebarHoverBrackets(color: (style.cardBorderActive ?? style.cardText ?? .primary).opacity(0.78))
            }
        }
        .onHover { isHovering = $0 }
        .background(WindowAccessor { [host] window in host.window = window })
        .popover(isPresented: failureShown, arrowEdge: .top) {
            Text(model.failure?.message ?? "")
                .font(.system(size: 12))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(width: 320, alignment: .leading)
                .accessibilityIdentifier("ChaosCastError")
        }
        .contextMenu { menu }
        .accessibilityIdentifier("SidebarChaosButton")
        .accessibilityLabel(Text(String(localized: "sidebar.chaos.accessibility",
                                        defaultValue: "Chaos Wizard: cast two agents on two wild prompts")))
        .safeHelp(String(localized: "sidebar.chaos.help",
                         defaultValue: "Chaos Wizard: click to cast two agents on two wild prompts in a new Chaos workspace"))
    }

    /// A failed cast shows under this button only in the window it was cast from.
    private var failureShown: Binding<Bool> {
        Binding(
            get: {
                guard let failure = model.failure else { return false }
                guard let windowId = failure.windowId else { return true }
                return host.window.flatMap { AppDelegate.shared?.mainWindowId(for: $0) } == windowId
            },
            set: { if !$0 { model.failure = nil } }
        )
    }

    /// The window this button lives in and the workspace it shows, read at the click.
    private func gestureContext() -> (window: UUID?, selection: UUID?) {
        guard let window = host.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              let windowId = AppDelegate.shared?.mainWindowId(for: window) else { return (nil, nil) }
        return (windowId, AppDelegate.shared?.workspaceManagerFor(windowId: windowId)?.selectedWorkspaceId)
    }

    private func cast() {
        guard !model.isCasting else { return }
        let context = gestureContext()
        model.castTwo(windowId: context.window, expectedSelection: context.selection)
    }

    @ViewBuilder
    private var menu: some View {
        Button(String(localized: "sidebar.chaos.menu.gallery", defaultValue: "Open Gallery")) { ChaosFolderActions.openGallery() }
        Button(String(localized: "sidebar.chaos.menu.showFolder", defaultValue: "Show Chaos Folder in Finder")) { ChaosFolderActions.showFolder() }
        Button(String(localized: "sidebar.chaos.menu.editDeck", defaultValue: "Edit Deck")) { ChaosFolderActions.editDeck() }
        Button(String(localized: "sidebar.chaos.menu.chooseFolder", defaultValue: "Choose Chaos Folder…")) { ChaosFolderActions.chooseFolder() }
    }
}

/// A weak hold on the button's window, set from the hosting view.
final class ChaosHostWindow {
    weak var window: NSWindow?
}

/// The right-click menu's folder actions. Operator gestures, on main.
@MainActor
enum ChaosFolderActions {
    static func openGallery() {
        let root = ChaosSettings.root()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ChaosCaster.writeRootGallery(root: root)
        NSWorkspace.shared.open(root.appendingPathComponent(ChaosCaster.galleryFileName))
    }

    static func showFolder() {
        let root = ChaosSettings.root()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    static func editDeck() {
        guard let url = try? ChaosSettings.ensureDeckFile() else { return }
        NSWorkspace.shared.open(url)
    }

    static func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = ChaosSettings.root().deletingLastPathComponent()
        panel.prompt = String(localized: "sidebar.chaos.chooseFolder.prompt", defaultValue: "Use This Folder")
        panel.message = String(localized: "sidebar.chaos.chooseFolder.message",
                               defaultValue: "Every Chaos cast builds inside this folder.")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            ChaosSettings.setRoot(url)
        }
    }
}
