import Foundation

enum AIUsageHTTPError: Error {
    case badResponse
    case http(Int)
    case decoding
    case network(Error)
}

enum AIUsageHTTP {
    static func makeSession(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }

    static func sanitizeHeaderValue(_ value: String) -> String {
        var out = String()
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                continue
            }
            if scalar == ";" || scalar == "," {
                continue
            }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    static func getJSONObject(url: URL,
                              headers: [String: String] = [:],
                              session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, raw) in headers {
            request.setValue(sanitizeHeaderValue(raw), forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError {
                throw CancellationError()
            }
            throw AIUsageHTTPError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIUsageHTTPError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AIUsageHTTPError.http(http.statusCode)
        }

        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIUsageHTTPError.decoding
            }
            return object
        } catch let httpError as AIUsageHTTPError {
            throw httpError
        } catch {
            throw AIUsageHTTPError.decoding
        }
    }
}
