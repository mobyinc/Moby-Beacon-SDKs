import XCTest
@testable import MobyBeacon

final class TransportTests: XCTestCase {
    private let events = [event("view")]

    /// A transport over a mock client that answers with `respond`.
    private func makeTransport(
        timeout: TimeInterval = 30,
        _ respond: @escaping (HTTPRequest) -> Result<HTTPResponse, Error>
    ) -> (Transport, MockHTTPClient) {
        let client = MockHTTPClient()
        client.handler = { request, completion in completion(respond(request)) }
        let transport = Transport(endpoint: "https://beacon.test", apiKey: "key-123", client: client, timeout: timeout)
        return (transport, client)
    }

    /// Sends `events` and returns the result the completion received.
    private func send(
        _ transport: Transport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Result<EventBatchResponse, Error>? {
        var result: Result<EventBatchResponse, Error>?
        transport.send(events) { result = $0 }
        XCTAssertNotNil(result, "send did not complete", file: file, line: line)
        return result
    }

    /// Sends `events` and returns the `TransportError` it failed with.
    private func sendFailure(
        _ transport: Transport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> TransportError? {
        switch send(transport, file: file, line: line) {
        case .failure(let error):
            guard let transportError = error as? TransportError else {
                XCTFail("not a TransportError: \(error)", file: file, line: line)
                return nil
            }
            return transportError
        case .success(let response):
            XCTFail("expected a failure, got \(response)", file: file, line: line)
            return nil
        case nil:
            return nil
        }
    }

    private func sendSuccess(
        _ transport: Transport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> EventBatchResponse? {
        switch send(transport, file: file, line: line) {
        case .success(let response):
            return response
        case .failure(let error):
            XCTFail("expected a response, got \(error)", file: file, line: line)
            return nil
        case nil:
            return nil
        }
    }

    func test_postsEventsToEndpointEventsWithHeadersAndBody() throws {
        let (transport, client) = makeTransport { _ in
            .success(jsonResponse(["accepted": 1, "errors": [Any]()], status: 201))
        }

        _ = send(transport)

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(request.url.absoluteString, "https://beacon.test/events")
        XCTAssertEqual(request.headers["X-API-Key"], "key-123")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? NSDictionary)
        XCTAssertEqual(body, ["events": [events[0].toJSONObject()]] as NSDictionary)
    }

    func test_returnsTheResponseOn201() {
        let (transport, _) = makeTransport { _ in
            .success(jsonResponse(["accepted": 1, "errors": [Any]()], status: 201))
        }
        let response = sendSuccess(transport)
        XCTAssertEqual(response?.accepted, 1)
        XCTAssertEqual(response?.errors, [])
    }

    func test_returnsPerEventErrorsOn207And422() {
        for status in [207, 422] {
            XCTContext.runActivity(named: "status \(status)") { _ in
                let (transport, _) = makeTransport { _ in
                    .success(jsonResponse(
                        ["accepted": 0, "errors": [["index": 0, "message": "category is required"]]],
                        status: status))
                }
                let response = sendSuccess(transport)
                XCTAssertEqual(response?.errors.count, 1)
                XCTAssertEqual(response?.errors.first?.index, 0)
                XCTAssertEqual(response?.errors.first?.message, "category is required")
            }
        }
    }

    func test_throwsWithStatusOn5xx() {
        let (transport, _) = makeTransport { _ in .success(emptyResponse(status: 503)) }
        XCTAssertEqual(sendFailure(transport), TransportError(message: "Server error: 503", statusCode: 503, retryAfter: nil))
    }

    func test_throwsWithRetryAfterOn429() {
        let (transport, _) = makeTransport { _ in .success(emptyResponse(status: 429, headers: ["retry-after": "12"])) }
        XCTAssertEqual(sendFailure(transport), TransportError(message: "Rate limited", statusCode: 429, retryAfter: 12))
    }

    func test_readsNamedThrottlerRetryAfterHeadersOn429() {
        let (transport, _) = makeTransport { _ in
            .success(emptyResponse(status: 429, headers: ["retry-after-ip-limit": "37", "retry-after-key-limit": "5"]))
        }
        XCTAssertEqual(sendFailure(transport), TransportError(message: "Rate limited", statusCode: 429, retryAfter: 37))
    }

    func test_429WithoutAUsableRetryAfterHasNoRetryAfter() {
        let (transport, _) = makeTransport { _ in .success(emptyResponse(status: 429, headers: ["retry-after": "soon"])) }
        XCTAssertEqual(sendFailure(transport), TransportError(message: "Rate limited", statusCode: 429, retryAfter: nil))
    }

    func test_reportsARedirectDistinctly() {
        let (transport, _) = makeTransport { _ in .success(emptyResponse(status: 301)) }
        let error = sendFailure(transport)
        XCTAssertEqual(error?.statusCode, 301)
        XCTAssertEqual(error?.message, "Unexpected redirect (301); check the endpoint URL")
    }

    func test_throwsWithStatusOn413SoTheCallerCanSplitTheBatch() {
        let (transport, _) = makeTransport { _ in .success(emptyResponse(status: 413)) }
        XCTAssertEqual(sendFailure(transport), TransportError(message: "Client error: 413", statusCode: 413, retryAfter: nil))
    }

    func test_throwsWithStatusOn400401403() {
        for status in [400, 401, 403] {
            XCTContext.runActivity(named: "status \(status)") { _ in
                let (transport, _) = makeTransport { _ in .success(emptyResponse(status: status)) }
                XCTAssertEqual(
                    sendFailure(transport),
                    TransportError(message: "Client error: \(status)", statusCode: status, retryAfter: nil))
            }
        }
    }

    func test_throwsWithoutStatusWhenTheClientThrows() {
        let failure = URLError(.cannotConnectToHost)
        let (transport, _) = makeTransport { _ in .failure(failure) }
        let error = sendFailure(transport)
        XCTAssertEqual(error?.message, "Network error: \(failure.localizedDescription)")
        XCTAssertNil(error?.statusCode)
        XCTAssertNil(error?.retryAfter)
    }

    func test_throwsWithoutStatusOnTimeout() {
        let (transport, _) = makeTransport(timeout: 0.01) { _ in .failure(URLError(.timedOut)) }
        XCTAssertEqual(sendFailure(transport), TransportError(message: "Request timed out", statusCode: nil, retryAfter: nil))
    }

    func test_acceptedResponseWithUnparsableBodyCountsAsAccepted() {
        let (transport, _) = makeTransport { _ in
            .success(HTTPResponse(statusCode: 201, headers: [:], body: Data("not json".utf8)))
        }
        XCTAssertEqual(sendSuccess(transport), EventBatchResponse(accepted: 0, errors: []))
    }

    func test_urlSessionClientRefusesRedirects() throws {
        let client = URLSessionHTTPClient(timeout: 30)
        defer { client.invalidate() }
        let url = try XCTUnwrap(URL(string: "https://beacon.test"))
        let task = URLSession.shared.dataTask(with: url)
        let redirect = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://elsewhere.test"]))

        var called = false
        var followed: URLRequest?
        client.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: url)) {
            called = true
            followed = $0
        }

        XCTAssertTrue(called)
        XCTAssertNil(followed)
    }

    func test_closeLeavesAnInjectedClientAlone() {
        let client = MockHTTPClient()
        Transport(endpoint: "https://beacon.test", apiKey: "key-123", client: client).close()
        XCTAssertEqual(client.invalidateCount, 0)
    }

    func test_retryAfterSecondsIgnoresHTTPDates() {
        XCTAssertNil(retryAfterSeconds(from: ["retry-after": "Wed, 21 Oct 2026 07:28:00 GMT"]))
    }
}
