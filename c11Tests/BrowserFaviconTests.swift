import XCTest
import CoreGraphics
import ImageIO
#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class BrowserFaviconTests: XCTestCase {
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
