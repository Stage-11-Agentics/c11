import AppKit

/// One monitor per visible quick view, scoped to its owner and popover windows.
final class FeedQuickViewKeyboardSession {
    enum Action { case move(Int), open, cancel, toggleFilter, consume }
    weak var popoverWindow: NSWindow?
    private weak var ownerWindow: NSWindow?
    private weak var originResponder: NSResponder?
    private var monitor: Any?
    private var action: ((Action) -> Void)?
    private(set) var monitorInstallCount = 0

    func start(window: NSWindow, action: @escaping (Action) -> Void) {
        guard monitor == nil else { return }
        ownerWindow = window
        originResponder = window.firstResponder
        self.action = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        monitorInstallCount += 1
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard monitor != nil, let ownerWindow,
              let eventWindow = event.window ?? NSApp.keyWindow,
              eventWindow === ownerWindow || eventWindow === popoverWindow else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let shortcut = KeyboardShortcutSettings.shortcut(for: .showNotifications)
        let shortcutMatches = flags == shortcut.modifierFlags && (
            shortcut.key == "\r" ? [36, 76].contains(Int(event.keyCode)) :
                event.charactersIgnoringModifiers?.lowercased() == shortcut.key.lowercased()
        )
        if shortcutMatches { action?(.cancel); return true }
        guard flags.isDisjoint(with: [.command, .option, .control]) else { return false }
        switch event.keyCode {
        case 53 where flags.isEmpty: action?(.cancel)
        case 36, 76: action?(flags.isEmpty ? .open : .consume)
        case 48 where flags.isEmpty || flags == .shift: action?(.toggleFilter)
        case 125 where flags.isEmpty: action?(.move(1))
        case 126 where flags.isEmpty: action?(.move(-1))
        default: action?(.consume) // Read-only: never leak text/Return into a tenant PTY.
        }
        return true
    }

    func stop(restoreFocus: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        action = nil
        if restoreFocus, let window = ownerWindow, let responder = originResponder,
           NSApp.windows.contains(where: { $0 === window }),
           (window.isKeyWindow || popoverWindow?.isKeyWindow == true),
           (responder as? NSView)?.window === window {
            window.makeFirstResponder(responder)
        }
        ownerWindow = nil
        originResponder = nil
        popoverWindow = nil
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
