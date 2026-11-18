import AppKit
import SwiftUI

/// Fills a window to the visible frame (menu bar and Dock excluded) of the
/// screen the pointer is on, and puts it back on a second click.
///
/// c11, 2026-11-04: moving from a large display to a small one can leave
/// only a sliver of the window on screen. The title bar's top-right corner and
/// the sidebar's bottom-left corner each carry this button, so whichever
/// corner is still visible restores the whole window in one click.
enum WindowMaximizer {
    /// The frame each window had before it was maximized, for the restore click.
    private static let restoreFrames = NSMapTable<NSWindow, NSValue>.weakToStrongObjects()

    static func toggle(_ window: NSWindow, pointer: NSPoint = NSEvent.mouseLocation) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        guard let screen = targetScreen(for: window, pointer: pointer) else { return }
        let target = screen.visibleFrame

        if isFilling(window.frame, target), let previous = restoreFrames.object(forKey: window)?.rectValue {
            restoreFrames.removeObject(forKey: window)
            window.setFrame(previous, display: true, animate: true)
            return
        }
        guard !isFilling(window.frame, target) else { return }
        restoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
        window.setFrame(target, display: true, animate: true)
    }

    /// The screen under the pointer; else the window's screen; else the main one.
    static func targetScreen(for window: NSWindow, pointer: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? window.screen
            ?? NSScreen.main
    }

    /// Within a point on every edge, so a frame macOS rounded still counts.
    static func isFilling(_ frame: NSRect, _ target: NSRect) -> Bool {
        abs(frame.minX - target.minX) <= 1
            && abs(frame.minY - target.minY) <= 1
            && abs(frame.width - target.width) <= 1
            && abs(frame.height - target.height) <= 1
    }
}

/// Four arrows to the corners; the caller picks the button style. It resolves
/// its window from the click itself, so it works on the first click into an
/// inactive window.
struct WindowMaximizeButton: View {
    let foregroundColor: Color
    var iconSize: CGFloat = 12
    var buttonSize: CGFloat = 18
    var accessibilityIdentifier: String

    private var helpText: String {
        String(localized: "window.maximize.help", defaultValue: "Fill this screen (click again to restore)")
    }

    var body: some View {
        Button {
            guard let window = NSApp.currentEvent?.window ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
            WindowMaximizer.toggle(window)
        } label: {
            Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundColor(foregroundColor)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .frame(width: buttonSize, height: buttonSize)
        .safeHelp(helpText)
        .accessibilityLabel(String(localized: "window.maximize.label", defaultValue: "Fill Screen"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
