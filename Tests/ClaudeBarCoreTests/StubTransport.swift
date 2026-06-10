import Foundation
@testable import ClaudeBarCore

/// A deterministic `HTTPTransport` for tests — returns a canned response (or throws).
struct StubTransport: HTTPTransport {
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
    static func make(
        status: Int,
        json: String = "{}",
        headers: [String: String] = [:]) -> HTTPResponse
    {
        HTTPResponse(statusCode: status, data: Data(json.utf8), headers: headers)
    }
}
