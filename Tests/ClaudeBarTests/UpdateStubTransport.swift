import ClaudeBarCore
import Foundation

/// A deterministic `HTTPTransport` for the app-target update tests.
///
/// The Core test target has its own `StubTransport`, but test helpers don't cross target
/// boundaries — this is the `ClaudeBarTests` equivalent, built on the *public* `HTTPTransport` /
/// `HTTPResponse` API so no `@testable` access is needed.
struct UpdateStubTransport: HTTPTransport {
    let response: HTTPResponse?
    let error: Error?

    init(response: HTTPResponse) {
        self.response = response
        self.error = nil
    }

    init(error: Error) {
        self.response = nil
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if let error { throw error }
        if let response { return response }
        throw URLError(.unknown)
    }
}

extension HTTPResponse {
    /// Mirror of the Core test factory, restated here for the app target.
    static func stub(
        status: Int,
        json: String = "{}",
        headers: [String: String] = [:]) -> HTTPResponse
    {
        HTTPResponse(statusCode: status, data: Data(json.utf8), headers: headers)
    }
}
