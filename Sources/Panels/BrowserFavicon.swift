import Foundation
import CoreGraphics
import ImageIO
import Bonsplit

/// Bounds untrusted favicon input before ImageIO decodes it, away from the UI actor.
enum BrowserFavicon {
    static let maximumBytes = 1 << 20

    static let directSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        return URLSession(configuration: configuration)
    }()

    enum FetchError: Error {
        case invalidURL
        case badResponse
        case tooLarge
    }

    static func isFetchable(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    static func fetch(_ request: URLRequest, session: URLSession, maximumBytes: Int) async throws -> Data {
        guard let url = request.url, isFetchable(url) else { throw FetchError.invalidURL }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetchError.badResponse
        }
        guard maximumBytes >= 0, response.expectedContentLength <= Int64(maximumBytes) else {
#if DEBUG
            dlog("browser.favicon.rejected reason=tooLarge declaredBytes=\(response.expectedContentLength)")
#endif
            throw FetchError.tooLarge
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else {
#if DEBUG
                dlog("browser.favicon.rejected reason=tooLarge bytes=\(data.count + 1)")
#endif
                throw FetchError.tooLarge
            }
            data.append(byte)
        }
        return data
    }

    static func decodePNG(_ data: Data, targetPx: Int) -> Data? {
        guard data.count <= maximumBytes else {
#if DEBUG
            dlog("browser.favicon.rejected reason=tooLarge bytes=\(data.count)")
#endif
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              ["public.png", "com.microsoft.ico", "public.jpeg", "com.compuserve.gif",
               "org.webmproject.webp", "com.microsoft.bmp"].contains(type as String) else {
#if DEBUG
            dlog("browser.favicon.rejected reason=badType")
#endif
            return nil
        }
        let px = max(16, min(128, targetPx))
        let count = type as String == "com.microsoft.ico" ? min(64, CGImageSourceGetCount(source)) : min(1, CGImageSourceGetCount(source))
        var candidates: [(index: Int, edge: Int)] = []
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { return nil }
            guard width <= 2048, height <= 2048 else {
#if DEBUG
                dlog("browser.favicon.rejected reason=tooManyPixels width=\(width) height=\(height)")
#endif
                return nil
            }
            candidates.append((index, max(width, height)))
        }
        let fitting = candidates.filter { $0.edge >= px }.min { $0.edge < $1.edge }
        guard let selected = fitting ?? candidates.max(by: { $0.edge < $1.edge }),
              let image = CGImageSourceCreateThumbnailAtIndex(source, selected.index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: px,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary),
              let context = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                                      bytesPerRow: px * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        let scale = min(CGFloat(px) / CGFloat(image.width), CGFloat(px) / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: ((CGFloat(px) - width) / 2).rounded(),
                                      y: ((CGFloat(px) - height) / 2).rounded(),
                                      width: width.rounded(), height: height.rounded()))
        guard let output = context.makeImage() else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return png as Data
    }
}
