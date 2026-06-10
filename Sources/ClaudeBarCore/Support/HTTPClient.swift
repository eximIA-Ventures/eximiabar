import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The pieces of an HTTP response the core cares about.
public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]

    public init(statusCode: Int, data: Data, headers: [String: String]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }

    /// Case-insensitive header lookup.
    public func headerValue(_ name: String) -> String? {
        let target = name.lowercased()
        for (key, value) in headers where key.lowercased() == target {
            return value
        }
        return nil
    }
}

/// Abstraction over network transport so the fetcher can be unit-tested without
/// touching the network. The default implementation uses `URLSession`.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// `URLSession`-based async client with no global mutable state.
public struct HTTPClient: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return HTTPResponse(
            statusCode: http.statusCode,
            data: data,
            headers: headers)
    }
}
