import XCTest
import CoreGraphics
import ImageIO
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class BrowserFaviconTests: XCTestCase {
    func testDiscoveredURLTrimsSmallInputs() {
        XCTAssertEqual(BrowserFavicon.discoveredURL(from: " \nhttps://example.com/icon.png\t")?.absoluteString, "https://example.com/icon.png")
        XCTAssertNil(BrowserFavicon.discoveredURL(from: " \n\t"))
    }

    func testDiscoveredURLAcceptsExactHrefLimit() {
        let prefix = "https://example.com/"
        let href = prefix + String(repeating: "a", count: BrowserFavicon.maximumDiscoveredURLCharacters - prefix.utf16.count)
        XCTAssertEqual(BrowserFavicon.discoveredURL(from: href)?.absoluteString, href)
    }

    func testDiscoveredURLRejectsOversizedInputsBeforeParsing() {
        let limit = BrowserFavicon.maximumDiscoveredURLCharacters
        for href in [
            "data:image/png;base64," + String(repeating: "A", count: limit),
            "https://example.com/" + String(repeating: "a", count: 2 * limit),
            String(repeating: " ", count: limit) + "https://example.com/icon.png",
            "data:," + String(repeating: "😀", count: limit / 2),
        ] {
            XCTAssertNil(BrowserFavicon.discoveredURL(from: href))
        }
    }

    func testRejectsOversizedPixelDimensionsBeforeDecode() throws {
        for (width, height) in [(10000, 1), (2049, 2049)] {
            let data = try Self.raster(width: width, height: height)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, width)
            XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, height)
            XCTAssertNil(BrowserFavicon.decodePNG(data, targetPx: 32))
        }
    }

    func testLargeGIFDecodesTo32PixelPNGQuickly() throws {
        let data = try Self.raster(width: 2048, height: 2048, type: "com.compuserve.gif")
        let started = Date()
        let png = try XCTUnwrap(BrowserFavicon.decodePNG(data, targetPx: 32))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 32)
    }

    func testICOChoosesSmallestEntryAtLeastTargetSize() throws {
        let entries = try [(16, [CGFloat(1), 0, 0, 1]), (32, [CGFloat(0), 1, 0, 1]), (256, [CGFloat(0), 0, 1, 1])].map { size, color in
            (size, try Self.raster(width: size, height: size, color: color))
        }
        var ico = Data([0, 0, 1, 0, 3, 0])
        var offset = 6 + entries.count * 16
        func appendLE(_ value: Int, bytes: Int) {
            for shift in 0..<bytes { ico.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
        }
        for (size, png) in entries {
            ico.append(contentsOf: [UInt8(truncatingIfNeeded: size), UInt8(truncatingIfNeeded: size), 0, 0])
            appendLE(1, bytes: 2)
            appendLE(32, bytes: 2)
            appendLE(png.count, bytes: 4)
            appendLE(offset, bytes: 4)
            offset += png.count
        }
        for (_, png) in entries { ico.append(png) }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(ico as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        let png = try XCTUnwrap(BrowserFavicon.decodePNG(ico, targetPx: 32))
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertLessThan(pixel[0], 10)
        XCTAssertGreaterThan(pixel[1], 245)
        XCTAssertLessThan(pixel[2], 10)
    }

    func testRejectsPDFAndSVGQuickly() throws {
        let pdf = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: pdf))
        var rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &rect, nil))
        context.beginPDFPage(nil)
        context.fill(rect)
        context.endPDFPage()
        context.closePDF()
        for data in [pdf as Data, Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32'/></svg>".utf8)] {
            let started = Date()
            XCTAssertNil(BrowserFavicon.decodePNG(data, targetPx: 32))
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        }
    }

    func testRejectsBodyOverByteCap() {
        XCTAssertNil(BrowserFavicon.decodePNG(Data(repeating: 0, count: BrowserFavicon.maximumBytes + 1), targetPx: 32))
    }

    func testFetchableSchemes() throws {
        for value in ["file:///dev/zero", "data:image/png;base64,AA==", "blob:https://example.com/id", "about:blank"] {
            XCTAssertFalse(BrowserFavicon.isFetchable(try XCTUnwrap(URL(string: value))))
        }
        for value in ["http://example.com/icon", "https://example.com/icon", "HTTPS://example.com/icon"] {
            XCTAssertTrue(BrowserFavicon.isFetchable(try XCTUnwrap(URL(string: value))))
        }
    }

    func testBase64DataPNGDecodes() throws {
        let png = try Self.raster(width: 16, height: 16)
        let url = try XCTUnwrap(URL(string: "data:image/png;base64," + png.base64EncodedString()))
        XCTAssertEqual(BrowserFavicon.dataURLPayload(url), png)
        XCTAssertNotNil(BrowserFavicon.decodeDataURL(url, targetPx: 32))
    }

    func testForgivingBase64PayloadForms() throws {
        let cases: [(String, Data)] = [
            ("data:;base64,AA%20AA", Data([0, 0, 0])),
            ("data:;base64,AA%0AAA", Data([0, 0, 0])),
            ("data:;base64,AA%3D%3D", Data([0])),
            ("data:;base64,AA", Data([0])),
            ("data:;base64,AAA", Data([0, 0])),
            ("data:; base64 ,AA==", Data([0])),
            ("data:;%20base64%20,AA==", Data([0])),
            ("data:;base64,%09%0A%0C%0DAA%20==", Data([0])),
        ]
        for (value, expected) in cases {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(BrowserFavicon.dataURLPayload(url), expected, value)
        }
    }

    func testForgivingBase64PNGStillDecodes() throws {
        let png = try Self.raster(width: 16, height: 16)
        let encoded = png.base64EncodedString()
        for payload in [encoded.replacingOccurrences(of: "=", with: ""),
                        "%20%0A" + encoded.replacingOccurrences(of: "=", with: "%3D") + "%20"] {
            let url = try XCTUnwrap(URL(string: "data:image/png;%20base64%20," + payload))
            XCTAssertEqual(BrowserFavicon.dataURLPayload(url), png)
            XCTAssertNotNil(BrowserFavicon.decodeDataURL(url, targetPx: 32))
        }
    }

    func testDataPayloadDropsURLFragmentWithoutDroppingEscapedHash() throws {
        let url = try XCTUnwrap(URL(string: "data:application/octet-stream,one%23two#ignored"))
        XCTAssertEqual(BrowserFavicon.dataURLPayload(url), Data("one#two".utf8))
    }

    func testMalformedBase64RemainsRejected() throws {
        for payload in ["A", "AA=", "AA===", "A=AA", "AA%21AA", "AA%250AAA"] {
            let url = try XCTUnwrap(URL(string: "data:;base64," + payload))
            XCTAssertNil(BrowserFavicon.dataURLPayload(url), payload)
        }
    }

    func testBase64NormalizationKeepsDecodedByteCap() throws {
        let exact = Data(repeating: 0, count: BrowserFavicon.maximumBytes)
        let exactPayload = "%20" + exact.base64EncodedString().replacingOccurrences(of: "=", with: "") + "%0A"
        let exactURL = try XCTUnwrap(URL(string: "data:;%20base64," + exactPayload))
        XCTAssertEqual(BrowserFavicon.dataURLPayload(exactURL), exact)
        let oversized = Data(repeating: 0, count: BrowserFavicon.maximumBytes + 1)
        let oversizedPayload = "%20" + oversized.base64EncodedString().replacingOccurrences(of: "=", with: "") + "%0A"
        let oversizedURL = try XCTUnwrap(URL(string: "data:;base64," + oversizedPayload))
        XCTAssertNil(BrowserFavicon.dataURLPayload(oversizedURL))
    }

    func testDataURLRejectsOversizedNormalizationEnvelopes() throws {
        let maximumBase64Length = 4 * ((BrowserFavicon.maximumBytes + 2) / 3)
        let whitespace = try XCTUnwrap(URL(string: "data:;base64," + String(repeating: "%20", count: maximumBase64Length + 1)))
        XCTAssertNil(BrowserFavicon.dataURLPayload(whitespace))
        let header = try XCTUnwrap(URL(string: "data:" + String(repeating: "a", count: BrowserFavicon.maximumBytes + 1) + ";base64,AA=="))
        XCTAssertNil(BrowserFavicon.dataURLPayload(header))
    }

    func testPercentEncodedDataPNGDecodesBinaryBytes() throws {
        let png = try Self.raster(width: 16, height: 16)
        let encoded = png.map { String(format: "%%%02X", $0) }.joined()
        let url = try XCTUnwrap(URL(string: "data:image/png," + encoded))
        XCTAssertEqual(BrowserFavicon.dataURLPayload(url), png)
        XCTAssertNotNil(BrowserFavicon.decodeDataURL(url, targetPx: 32))
    }

    func testOversizedDataPayloadIsRejectedBeforeImageDecode() throws {
        // The base64 envelope of cap+1 bytes has the same length as cap bytes.
        // Padding must be checked before Data(base64Encoded:) allocates output.
        let tooLarge = Data(repeating: 0, count: BrowserFavicon.maximumBytes + 1)
        for payload in [tooLarge.base64EncodedString(), String(repeating: "A", count: 4 * ((BrowserFavicon.maximumBytes + 2) / 3) + 4)] {
            let url = try XCTUnwrap(URL(string: "data:image/png;base64," + payload))
            XCTAssertNil(BrowserFavicon.dataURLPayload(url))
        }
        let raw = try XCTUnwrap(URL(string: "data:image/png," + String(repeating: "A", count: BrowserFavicon.maximumBytes + 1)))
        XCTAssertNil(BrowserFavicon.dataURLPayload(raw))
        let escaped = try XCTUnwrap(URL(string: "data:image/png," + String(repeating: "%41", count: BrowserFavicon.maximumBytes + 1)))
        XCTAssertNil(BrowserFavicon.dataURLPayload(escaped))
        let exact = try XCTUnwrap(URL(string: "data:application/octet-stream;base64," + Data(repeating: 0, count: BrowserFavicon.maximumBytes).base64EncodedString()))
        XCTAssertEqual(BrowserFavicon.dataURLPayload(exact)?.count, BrowserFavicon.maximumBytes)
    }

    func testSVGDataURLIsRejected() throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'/>".utf8)
        let url = try XCTUnwrap(URL(string: "data:image/svg+xml;base64," + svg.base64EncodedString()))
        XCTAssertEqual(BrowserFavicon.dataURLPayload(url), svg)
        XCTAssertNil(BrowserFavicon.decodeDataURL(url, targetPx: 32))
    }

    func testUnsupportedDiscoveredIconsKeepHTTPFallback() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/page"))
        let fallback = try XCTUnwrap(URL(string: "https://example.com/favicon.ico"))
        for value in ["blob:https://example.com/id", "file:///dev/zero", "about:blank"] {
            XCTAssertEqual(BrowserFavicon.iconCandidates(discoveredURL: URL(string: value), pageURL: page), [fallback])
        }
        let data = try XCTUnwrap(URL(string: "data:image/png;base64,AA=="))
        XCTAssertEqual(BrowserFavicon.iconCandidates(discoveredURL: data, pageURL: page), [data, fallback])
        XCTAssertEqual(BrowserFavicon.iconCandidates(discoveredURL: fallback, pageURL: page), [fallback])
    }

    func testICORejectsSmallDirectoryEntryWithOversizedEmbeddedPNG() throws {
        let png = try Self.raster(width: 4096, height: 4096)
        var ico = Data([0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0])
        for value in [png.count, 22] {
            for shift in 0..<4 { ico.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
        }
        ico.append(png)
        XCTAssertLessThan(ico.count, BrowserFavicon.maximumBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(ico as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.microsoft.ico")
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 4096)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 4096)
        XCTAssertNil(BrowserFavicon.decodePNG(ico, targetPx: 32))
    }

    func testGIFRejectsSmallLogicalScreenWithOversizedFirstFrame() throws {
        var gif = Data("GIF89a".utf8)
        gif.append(contentsOf: [16, 0, 16, 0, 0x80, 0, 0])
        gif.append(contentsOf: [0, 0, 0, 255, 255, 255])
        // Image separator, left/top, 4096-square descriptor, no local table.
        gif.append(contentsOf: [0x2c, 0, 0, 0, 0, 0, 16, 0, 16, 0])
        // Tiny LZW stream: clear, one black pixel, end. Remaining frame is empty.
        gif.append(contentsOf: [2, 2, 0x44, 0x01, 0, 0x3b])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(gif as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.compuserve.gif")
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        // The deliberately tiny LZW stream need not expose ImageIO properties.
        // Inspect the real descriptor directly before any thumbnail work.
        let frame = try XCTUnwrap(BrowserFavicon.firstGIFFrameDimensions(gif))
        XCTAssertEqual(frame.width, 4096)
        XCTAssertEqual(frame.height, 4096)
        XCTAssertNil(BrowserFavicon.decodePNG(gif, targetPx: 32))
    }

    func testGIFFrameInspectionHandlesExtensionsAndTruncation() throws {
        let gif = try Self.raster(width: 16, height: 16, type: "com.compuserve.gif")
        let bytes = Array(gif)
        let tableSize = bytes[10] & 0x80 == 0 ? 0 : 3 * (1 << (Int(bytes[10] & 7) + 1))
        let offset = 13 + tableSize
        var extended = Data(gif.prefix(offset))
        extended.append(contentsOf: [0x21, 0xfe, 3, 65, 66, 67, 0])
        extended.append(gif.dropFirst(offset))
        let frame = try XCTUnwrap(BrowserFavicon.firstGIFFrameDimensions(extended))
        XCTAssertEqual(frame.width, 16)
        XCTAssertEqual(frame.height, 16)
        XCTAssertNotNil(BrowserFavicon.decodePNG(extended, targetPx: 32))
        for length in 0..<(offset + 7) {
            XCTAssertNil(BrowserFavicon.firstGIFFrameDimensions(Data(extended.prefix(length))))
        }
    }

    func testEndlessStreamThrowsAtByteCap() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await BrowserFavicon.fetch(Self.request("endless"), session: session, maximumBytes: 8192)
            XCTFail("An endless stream must exceed the cap")
        } catch BrowserFavicon.FetchError.tooLarge {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testDeclaredOversizeThrowsBeforeReadingBody() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let started = Date()
        do {
            _ = try await BrowserFavicon.fetch(Self.request("oversize"), session: session, maximumBytes: 8192)
            XCTFail("Oversized Content-Length must be rejected")
        } catch BrowserFavicon.FetchError.tooLarge {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testNonSuccessResponseThrowsBeforeBody() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await BrowserFavicon.fetch(Self.request("failure"), session: session, maximumBytes: 8192)
            XCTFail("Non-2xx must be rejected")
        } catch BrowserFavicon.FetchError.badResponse {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSmallPNGBodiedResponseReturnsBytesIncludingExactCap() async throws {
        let session = Self.session()
        defer { session.invalidateAndCancel() }
        let expected = try Self.raster(width: 16, height: 16)
        let actual = try await BrowserFavicon.fetch(Self.request("png"), session: session, maximumBytes: expected.count)
        XCTAssertEqual(actual, expected)
    }

    func testAspectFitKeepsTransparentPadding() throws {
        let input = try Self.raster(width: 32, height: 16)
        let png = try XCTUnwrap(BrowserFavicon.decodePNG(input, targetPx: 32))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(pixels[3], 0)
        XCTAssertEqual(pixels[(16 * 32 + 16) * 4 + 3], 255)
    }

    fileprivate static func raster(width: Int, height: Int, type: String = "public.png", color: [CGFloat] = [1, 0, 0, 1]) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: color)))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FaviconTestURLProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 4
        return URLSession(configuration: configuration)
    }

    private static func request(_ path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://favicon.test/\(path)")!)
    }
}

private final class FaviconTestURLProtocol: URLProtocol {
    private let queue = DispatchQueue(label: "c11.favicon-test-stream")
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "favicon.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.lastPathComponent
        let response = HTTPURLResponse(url: url, statusCode: path == "failure" ? 404 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: path == "oversize" ? ["Content-Length": "9999999"] : nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // URLProtocol must finish header-only responses to release Foundation's
        // AsyncBytes continuation. No body bytes exist for the iterator to read.
        if path == "oversize" || path == "failure" {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if path == "endless" {
            sendChunk()
        } else {
            do {
                client?.urlProtocol(self, didLoad: try BrowserFaviconTests.raster(width: 16, height: 16))
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    private func sendChunk() {
        queue.asyncAfter(deadline: .now() + 0.005) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stopped = self.stopped
            self.lock.unlock()
            guard !stopped else { return }
            self.client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 4096))
            self.sendChunk()
        }
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
