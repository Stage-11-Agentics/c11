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

    // URLSession decodes Content-Encoding before delivering bytes, so this cap
    // bounds decoded bytes we keep, not what CFNetwork inflates internally.
    // In this project's Swift 5 mode, nonisolated async runs off the main actor.
    static func fetch(_ request: URLRequest, session: URLSession, maximumBytes: Int) async throws -> Data {
        guard let url = request.url, isFetchable(url) else { throw FetchError.invalidURL }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
#if DEBUG
        dlog("browser.favicon.response status=\((response as? HTTPURLResponse)?.statusCode ?? -1)")
#endif
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

    static func iconCandidates(discoveredURL: URL?, pageURL: URL) -> [URL] {
        var candidates: [URL] = []
        if let discoveredURL, isFetchable(discoveredURL) || discoveredURL.scheme?.lowercased() == "data" {
            candidates.append(discoveredURL)
        }
        if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL,
           isFetchable(fallback), !candidates.contains(fallback) {
            candidates.append(fallback)
        }
        return candidates
    }

    static func decodeDataURL(_ url: URL, targetPx: Int) -> Data? {
        guard let payload = dataURLPayload(url) else { return nil }
        return decodePNG(payload, targetPx: targetPx)
    }

    static func dataURLPayload(_ url: URL) -> Data? {
        guard url.scheme?.lowercased() == "data" else { return nil }
        let value = url.absoluteString.dropFirst(5)
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let header = value[..<comma]
        let payload = value[value.index(after: comma)...].utf8
        if header.lowercased().hasSuffix(";base64") {
            guard payload.count <= 4 * ((maximumBytes + 2) / 3), payload.count % 4 == 0 else { return nil }
            let padding = payload.suffix(2).filter { $0 == 61 }.count
            guard payload.count / 4 * 3 - padding <= maximumBytes else { return nil }
            return Data(base64Encoded: String(value[value.index(after: comma)...]))
        }
        guard payload.count <= maximumBytes * 3 else { return nil }
        let encoded = Array(payload)
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        // Count and validate before allocating or decoding the binary payload.
        var index = 0
        var count = 0
        while index < encoded.count {
            if encoded[index] == 37 {
                guard index + 2 < encoded.count, hex(encoded[index + 1]) != nil,
                      hex(encoded[index + 2]) != nil else { return nil }
                index += 3
            } else { index += 1 }
            count += 1
            guard count <= maximumBytes else { return nil }
        }
        var result = Data(capacity: count)
        index = 0
        while index < encoded.count {
            if encoded[index] == 37 {
                result.append(hex(encoded[index + 1])! * 16 + hex(encoded[index + 2])!)
                index += 3
            } else {
                result.append(encoded[index])
                index += 1
            }
        }
        return result
    }

    /// ImageIO need not expose the real GIF frame size in its image properties.
    static func firstGIFFrameDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count <= maximumBytes else { return nil }
        let bytes = Array(data)
        guard bytes.count >= 13,
              ["GIF87a", "GIF89a"].contains(String(bytes: bytes.prefix(6), encoding: .ascii) ?? "") else { return nil }
        var offset = 13
        if bytes[10] & 0x80 != 0 {
            offset += 3 * (1 << (Int(bytes[10] & 7) + 1))
        }
        while offset < bytes.count {
            switch bytes[offset] {
            case 0x2c:
                guard bytes.count - offset >= 10 else { return nil }
                return (Int(bytes[offset + 5]) | Int(bytes[offset + 6]) << 8,
                        Int(bytes[offset + 7]) | Int(bytes[offset + 8]) << 8)
            case 0x21:
                guard bytes.count - offset >= 2 else { return nil }
                offset += 2 // Extension introducer and label, then bounded sub-blocks.
                while true {
                    guard offset < bytes.count else { return nil }
                    let count = Int(bytes[offset])
                    offset += 1
                    guard count <= bytes.count - offset else { return nil }
                    offset += count
                    if count == 0 { break }
                }
            default: return nil
            }
        }
        return nil
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
        if type as String == "com.compuserve.gif" {
            guard let frame = firstGIFFrameDimensions(data), frame.width > 0, frame.height > 0,
                  frame.width <= 2048, frame.height <= 2048 else {
#if DEBUG
                dlog("browser.favicon.rejected reason=tooManyPixels source=gifFrame")
#endif
                return nil
            }
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
