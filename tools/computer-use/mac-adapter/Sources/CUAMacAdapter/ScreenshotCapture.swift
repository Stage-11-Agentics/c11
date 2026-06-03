import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Observation: Codable {
    let ok: Bool
    let window: WindowInfo
    let screenshotPath: String?
    let screenshotBase64: String?
    let screenshotWidth: Int
    let screenshotHeight: Int
    let scale: Double
    let displayID: UInt32?
    let capturedAt: String
}

enum ScreenshotError: Error, CustomStringConvertible {
    case captureFailed(UInt32)
    case writeFailed(String)

    var description: String {
        switch self {
        case .captureFailed(let id):
            return "failed to capture window \(id)"
        case .writeFailed(let path):
            return "failed to write screenshot to \(path)"
        }
    }
}

enum ScreenshotCapture {
    static func observe(window: WindowInfo, outPath: String?, includeBase64: Bool) throws -> Observation {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowID),
            [.boundsIgnoreFraming, .bestResolution]
        ) else {
            throw ScreenshotError.captureFailed(window.windowID)
        }

        let width = image.width
        let height = image.height
        let scale = window.bounds.width > 0 ? Double(width) / window.bounds.width : 1.0
        var normalizedOut: String?
        var base64: String?

        if let outPath {
            let expanded = NSString(string: outPath).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ScreenshotError.writeFailed(expanded)
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ScreenshotError.writeFailed(expanded)
            }
            normalizedOut = expanded
            if includeBase64 {
                base64 = try Data(contentsOf: url).base64EncodedString()
            }
        } else if includeBase64 {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw ScreenshotError.writeFailed("<memory>")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ScreenshotError.writeFailed("<memory>")
            }
            base64 = (data as Data).base64EncodedString()
        }

        return Observation(
            ok: true,
            window: window,
            screenshotPath: normalizedOut,
            screenshotBase64: base64,
            screenshotWidth: width,
            screenshotHeight: height,
            scale: scale,
            displayID: displayID(for: window.bounds.cgRect),
            capturedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func pointInWindow(x: Double, y: Double, observation: Observation) -> CGPoint {
        let scale = observation.scale == 0 ? 1 : observation.scale
        let bounds = observation.window.bounds
        return CGPoint(x: bounds.x + x / scale, y: bounds.y + y / scale)
    }

    private static func displayID(for rect: CGRect) -> UInt32? {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        let err = CGGetDisplaysWithRect(rect, UInt32(displays.count), &displays, &count)
        guard err == .success, count > 0 else { return nil }
        return displays[0]
    }
}
