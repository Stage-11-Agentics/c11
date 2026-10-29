import Foundation
import CoreGraphics
import ImageIO
import Bonsplit

/// Bounds untrusted favicon input before ImageIO decodes it, away from the UI actor.
enum BrowserFavicon {
    static let maximumBytes = 1 << 20
    static let maximumDiscoveredURLCharacters = 1_500_000

    /// Settings every favicon session starts from. Pages choose favicon URLs,
    /// so a favicon fetch sends and keeps no cookies and no stored
    /// credentials (C11-496).
    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        return configuration
    }

    private static let directSessionsLock = NSLock()
    private static var directSessions: [UUID: URLSession] = [:]

    /// The direct favicon session for one browser profile. Each profile has
    /// its own in-memory cache, so an icon is fetched once per profile and
    /// nothing one profile's favicon fetches leave behind reaches another.
    static func directSession(forProfile profileID: UUID) -> URLSession {
        directSessionsLock.lock()
        defer { directSessionsLock.unlock() }
        if let session = directSessions[profileID] { return session }
        let configuration = makeSessionConfiguration()
        configuration.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 0)
        let session = URLSession(configuration: configuration)
        directSessions[profileID] = session
        return session
    }

    enum FetchError: Error {
        case invalidURL
        case badResponse
        case tooLarge
    }

    static func isFetchable(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    static func discoveredURL(from href: String) -> URL? {
        // Match JavaScript's UTF-16 length and stop counting at the boundary.
        guard href.utf16.prefix(maximumDiscoveredURLCharacters + 1).count <= maximumDiscoveredURLCharacters else { return nil }
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
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
        let maximumBase64Length = 4 * ((maximumBytes + 2) / 3)
        let rawValue = url.absoluteString.dropFirst(5)
        guard rawValue.utf8.count <= maximumBytes + maximumBase64Length * 3 else { return nil }
        let value = rawValue.prefix { $0 != "#" }
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let header = value[..<comma]
        guard header.utf8.count <= maximumBytes,
              let decodedHeader = header.removingPercentEncoding else { return nil }
        let isBase64 = decodedHeader.contains(";") && decodedHeader.split(separator: ";", omittingEmptySubsequences: false)
            .last?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "base64"
        let payload = value[value.index(after: comma)...].utf8
        guard payload.count <= (isBase64 ? maximumBase64Length : maximumBytes) * 3 else { return nil }

        func hex(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        func isASCIIWhitespace(_ byte: UInt8) -> Bool {
            byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
        }
        func forEachDecodedByte(_ body: (UInt8) -> Bool) -> Bool {
            var index = payload.startIndex
            while index < payload.endIndex {
                let byte = payload[index]
                index = payload.index(after: index)
                if byte == 37 {
                    guard index < payload.endIndex, let high = hex(payload[index]) else { return false }
                    index = payload.index(after: index)
                    guard index < payload.endIndex, let low = hex(payload[index]) else { return false }
                    index = payload.index(after: index)
                    guard body(high * 16 + low) else { return false }
                } else if !body(byte) { return false }
            }
            return true
        }

        // Validate and measure the normalized payload before allocating it.
        var count = 0
        var padding = 0
        guard forEachDecodedByte({ byte in
            if isBase64, isASCIIWhitespace(byte) { return true }
            count += 1
            if isBase64 {
                guard count <= maximumBase64Length else { return false }
                if byte == 61 {
                    padding += 1
                    return padding <= 2
                }
                return padding == 0 && ((65...90).contains(byte) || (97...122).contains(byte)
                    || (48...57).contains(byte) || byte == 43 || byte == 47)
            }
            return count <= maximumBytes
        }) else { return nil }
        var missingPadding = 0
        if isBase64 {
            guard count % 4 != 1, padding == 0 || count % 4 == 0 else { return nil }
            missingPadding = (4 - count % 4) % 4
            guard (count + missingPadding) / 4 * 3 - padding - missingPadding <= maximumBytes else { return nil }
        }
        var result = Data(capacity: count + missingPadding)
        guard forEachDecodedByte({ byte in
            if !isBase64 || !isASCIIWhitespace(byte) { result.append(byte) }
            return true
        }) else { return nil }
        for _ in 0..<missingPadding { result.append(61) }
        return isBase64 ? Data(base64Encoded: result) : result
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
