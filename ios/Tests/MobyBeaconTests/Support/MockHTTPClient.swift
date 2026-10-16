import Foundation
@testable import MobyBeacon

/// An `HTTPClient` whose responses come from `handler`. The default handler
/// answers 201 with an empty accepted batch. Completes on the calling thread.
final class MockHTTPClient: HTTPClient {
    var handler: (HTTPRequest, @escaping (Result<HTTPResponse, Error>) -> Void) -> Void = { _, completion in
        completion(.success(jsonResponse(["accepted": 1, "errors": [Any]()], status: 201)))
    }
    private(set) var requests: [HTTPRequest] = []
    private(set) var invalidateCount = 0

    func post(_ request: HTTPRequest, completion: @escaping (Result<HTTPResponse, Error>) -> Void) {
        requests.append(request)
        handler(request, completion)
    }

    func invalidate() {
        invalidateCount += 1
    }
}

/// A response carrying `body` encoded as JSON. Header names are lowercased,
/// as `HTTPResponse` requires.
func jsonResponse(_ body: Any, status: Int, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(
        statusCode: status,
        headers: lowercasedKeys(headers),
        body: try! JSONSerialization.data(withJSONObject: body))
}

/// A response with an empty body.
func emptyResponse(status: Int, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: lowercasedKeys(headers), body: Data())
}

private func lowercasedKeys(_ headers: [String: String]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
}
