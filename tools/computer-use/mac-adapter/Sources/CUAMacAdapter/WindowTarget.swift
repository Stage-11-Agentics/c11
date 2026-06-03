import AppKit
import CoreGraphics
import Foundation

struct RectInfo: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct WindowInfo: Codable {
    let windowID: UInt32
    let pid: Int32
    let ownerName: String
    let bundleID: String?
    let title: String?
    let bounds: RectInfo
    let layer: Int
    let alpha: Double
    let isOnscreen: Bool
    let isFrontmostApp: Bool
}

struct TargetOptions {
    let bundleID: String
    let appPath: String?
}

enum WindowTargetError: Error, CustomStringConvertible {
    case bundleNotRunning(String)
    case noVisibleWindow(String)
    case frontmostMismatch(expected: String, actual: String?)
    case launchFailed(String)

    var description: String {
        switch self {
        case .bundleNotRunning(let bundle):
            return "target bundle is not running: \(bundle)"
        case .noVisibleWindow(let bundle):
            return "no visible window found for target bundle: \(bundle)"
        case .frontmostMismatch(let expected, let actual):
            return "frontmost app mismatch; expected \(expected), actual \(actual ?? "none")"
        case .launchFailed(let reason):
            return "launch failed: \(reason)"
        }
    }
}

final class WindowTarget {
    let options: TargetOptions

    init(options: TargetOptions) {
        self.options = options
    }

    func launchOrActivate(waitSeconds: Double) throws -> WindowInfo {
        if let app = runningApplications().first {
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        } else if let path = options.appPath {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            var launched: NSRunningApplication?
            var launchError: Error?
            let sema = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
                launched = app
                launchError = error
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + max(waitSeconds, 1))
            if let launchError {
                throw WindowTargetError.launchFailed(launchError.localizedDescription)
            }
            guard let launched else {
                throw WindowTargetError.launchFailed("no NSRunningApplication returned for \(url.path)")
            }
            launched.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        } else {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: options.bundleID) else {
                throw WindowTargetError.launchFailed("bundle id not found by LaunchServices and no --app-path supplied")
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            var launchError: Error?
            let sema = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: app, configuration: config) { _, error in
                launchError = error
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + max(waitSeconds, 1))
            if let launchError {
                throw WindowTargetError.launchFailed(launchError.localizedDescription)
            }
        }

        let deadline = Date().addingTimeInterval(waitSeconds)
        var lastError: Error?
        repeat {
            do {
                let window = try bestVisibleWindow()
                if let app = NSRunningApplication(processIdentifier: window.pid) {
                    app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                }
                _ = AccessibilitySupport.raise(pid: window.pid)
                if waitUntilFrontmost(deadline: deadline) {
                    return try bestVisibleWindow()
                }
                return window
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        } while Date() < deadline
        throw lastError ?? WindowTargetError.noVisibleWindow(options.bundleID)
    }

    func requireFrontmostTarget() throws -> WindowInfo {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            throw WindowTargetError.frontmostMismatch(expected: options.bundleID, actual: nil)
        }
        guard front.bundleIdentifier == options.bundleID else {
            throw WindowTargetError.frontmostMismatch(expected: options.bundleID, actual: front.bundleIdentifier)
        }
        return try bestVisibleWindow()
    }

    func bestVisibleWindow() throws -> WindowInfo {
        let matches = windows().filter { $0.bundleID == options.bundleID && $0.isOnscreen && $0.layer == 0 && $0.alpha > 0 && $0.bounds.width > 80 && $0.bounds.height > 80 }
        if matches.isEmpty {
            if runningApplications().isEmpty {
                throw WindowTargetError.bundleNotRunning(options.bundleID)
            }
            throw WindowTargetError.noVisibleWindow(options.bundleID)
        }
        if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let frontWindow = matches.first(where: { $0.pid == front }) {
            return frontWindow
        }
        return matches[0]
    }

    func windows() -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return raw.compactMap { item in
            guard let windowID = item[kCGWindowNumber as String] as? UInt32,
                  let pidNumber = item[kCGWindowOwnerPID as String] as? NSNumber,
                  let owner = item[kCGWindowOwnerName as String] as? String,
                  let boundsDict = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                return nil
            }
            let pid = pidNumber.int32Value
            let app = NSRunningApplication(processIdentifier: pid)
            let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (item[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            let title = item[kCGWindowName as String] as? String
            let onscreen = (item[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            return WindowInfo(
                windowID: windowID,
                pid: pid,
                ownerName: owner,
                bundleID: app?.bundleIdentifier,
                title: title,
                bounds: RectInfo(bounds),
                layer: layer,
                alpha: alpha,
                isOnscreen: onscreen,
                isFrontmostApp: frontPid == pid
            )
        }
    }

    private func runningApplications() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleID)
    }

    private func waitUntilFrontmost(deadline: Date) -> Bool {
        repeat {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == options.bundleID {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }
}
