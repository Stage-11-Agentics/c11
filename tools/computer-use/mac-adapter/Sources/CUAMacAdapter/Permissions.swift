import ApplicationServices
import CoreGraphics
import Foundation

struct PermissionStatus: Codable {
    let screenRecording: Bool
    let accessibility: Bool
    let remediation: [String]

    static func current() -> PermissionStatus {
        let screen = CGPreflightScreenCaptureAccess()
        let ax = AXIsProcessTrusted()
        var remediation: [String] = []
        if !screen {
            remediation.append("Grant Screen Recording to the terminal or adapter host in System Settings > Privacy & Security > Screen Recording.")
        }
        if !ax {
            remediation.append("Grant Accessibility to the terminal or adapter host in System Settings > Privacy & Security > Accessibility.")
        }
        return PermissionStatus(screenRecording: screen, accessibility: ax, remediation: remediation)
    }
}
