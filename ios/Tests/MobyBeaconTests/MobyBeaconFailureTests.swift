import Foundation
import XCTest
@testable import MobyBeacon

private struct Boom: Error {}

/// Transport whose send fails with something other than a `TransportError`.
private final class ThrowingTransport: Transport {
    var sends = 0

    init() {
        super.init(endpoint: "https://beacon.test", apiKey: "key-123", client: MockHTTPClient())
    }

    override func send(_ events: [MobyBeaconEvent], completion: @escaping (Result<EventBatchResponse, Error>) -> Void) {
        sends += 1
        completion(.failure(Boom()))
    }
}

/// Port of the `failures`, `backoff` and `batching` groups of
/// `moby_beacon_test.dart`. With `FixedRandom(0)` a backoff after `n`
/// failures is exactly `5 × 2^n` seconds, capped at 300.
final class MobyBeaconFailureTests: BeaconHarness {
    private func offline() {
        respond = { _, done in done(.failure(URLError(.notConnectedToInternet))) }
    }

    private func answer(_ status: Int, headers: [String: String] = [:]) {
        respond = { _, done in done(.success(emptyResponse(status: status, headers: headers))) }
    }

    private func acceptAll() {
        respond = { _, done in done(.success(accepted())) }
    }

    /// Dart's `errors.single`.
    private func singleError(file: StaticString = #filePath, line: UInt = #line) -> MobyBeaconError? {
        XCTAssertEqual(errors.count, 1, "\(errors)", file: file, line: line)
        return errors.count == 1 ? errors[0] : nil
    }

    // MARK: failures

    func test_networkFailureKeepsEventsAndBacksOffTheTimer() throws {
        offline()
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(singleError()?.type, .network)
        XCTAssertEqual(singleError()?.willRetry, true)
        XCTAssertEqual(requests.count, 1)

        // Backoff after one failure is 10s, not the 5s interval.
        scheduler.advance(by: 5)
        XCTAssertEqual(requests.count, 1)

        acceptAll()
        scheduler.advance(by: 5)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(sentActions(1), ["a"])

        // Success resets the timer to the normal interval.
        beacon.track("screen", "b")
        scheduler.advance(by: 5)
        XCTAssertEqual(sentActions(2), ["b"])
    }

    func test_429WaitsForRetryAfterBeforeTheNextAttempt() throws {
        answer(429, headers: ["retry-after": "30"])
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(singleError()?.type, .server)
        XCTAssertEqual(singleError()?.willRetry, true)

        acceptAll()
        scheduler.advance(by: 29)
        XCTAssertEqual(requests.count, 1)
        scheduler.advance(by: 1)
        XCTAssertEqual(requests.count, 2)
    }

    func test_5xxKeepsEventsForRetry() throws {
        answer(503)
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(singleError()?.type, .server)
        XCTAssertEqual(singleError()?.willRetry, true)
        XCTAssertEqual(singleError()?.events.map(\.action), ["a"])
    }

    func test_408KeepsEventsForRetryWithBackoff() throws {
        answer(408)
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(singleError()?.type, .server)
        XCTAssertEqual(singleError()?.willRetry, true)
        XCTAssertEqual(singleError()?.events.map(\.action), ["a"])

        acceptAll()
        scheduler.advance(by: 5)
        XCTAssertEqual(requests.count, 1, "backed off to 10s")
        scheduler.advance(by: 5)
        XCTAssertEqual(sentActions(1), ["a"])
    }

    func test_207DropsTheBatchAndReportsPerEventErrors() throws {
        respond = { _, done in
            done(.success(jsonResponse(
                ["accepted": 1, "errors": [["index": 1, "message": "details must be a flat object"]]],
                status: 207)))
        }
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        let error = singleError()
        XCTAssertEqual(error?.type, .validation)
        XCTAssertEqual(error?.willRetry, false)
        XCTAssertEqual(error?.events.map(\.action), ["a", "b"])
        XCTAssertEqual(error?.errors?.count, 1)
        XCTAssertEqual(error?.errors?.first?.index, 1)

        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, 1)
    }

    func test_401KeepsEventsAndRetriesAtTheBackoffCeiling() throws {
        answer(401)
        let beacon = try start(batchSize: 3)
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(singleError()?.type, .auth)
        XCTAssertEqual(singleError()?.willRetry, true)
        XCTAssertEqual(singleError()?.events.map(\.action), ["a"])

        // Tracking past batchSize does not retry early.
        beacon.track("screen", "b")
        beacon.track("screen", "c")
        scheduler.advance(by: 4 * 60 + 59)
        XCTAssertEqual(requests.count, 1)

        acceptAll() // The key works again.
        scheduler.advance(by: 1)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(sentActions(1), ["a", "b", "c"])
        XCTAssertEqual(errors.count, 1)
    }

    func test_403KeepsEventsAndReportsAnAuthError() throws {
        answer(403)
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(singleError()?.type, .auth)
        XCTAssertEqual(singleError()?.willRetry, true)

        acceptAll()
        scheduler.advance(by: 5 * 60)
        XCTAssertEqual(sentActions(1), ["a"])
    }

    func test_404KeepsEventsAndReportsAServerError() throws {
        answer(404)
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(singleError()?.type, .server)
        XCTAssertEqual(singleError()?.willRetry, true)
        XCTAssertEqual(singleError()?.message, "Client error: 404")

        acceptAll()
        scheduler.advance(by: 5 * 60)
        XCTAssertEqual(sentActions(1), ["a"])
    }

    /// Dart's `for (final status in [400, 200, 204])` loop: one activity per
    /// status, each with a fresh beacon over fresh storage.
    func test_unexpectedStatusKeepsEventsAsAServerError() throws {
        for status in [400, 200, 204] {
            try XCTContext.runActivity(named: "unexpected status \(status) keeps events as a server error") { _ in
                storage = MemoryQueueStorage()
                requests = []
                errors = []
                answer(status)
                let beacon = try start()
                beacon.track("screen", "a")
                beacon.flush(completion: nil)
                scheduler.runUntilIdle()

                XCTAssertEqual(singleError()?.type, .server, "status \(status)")
                XCTAssertEqual(singleError()?.willRetry, true, "status \(status)")
                XCTAssertEqual(singleError()?.events.map(\.action), ["a"], "status \(status)")

                // Free the live slot for the next status.
                beacon.dispose(completion: nil)
                scheduler.runUntilIdle()
            }
        }
    }

    func test_aRedirectKeepsEventsAndPassesTheMessageThrough() throws {
        answer(301, headers: ["location": "https://elsewhere.test/events"])
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(singleError()?.type, .server)
        XCTAssertEqual(singleError()?.willRetry, true)
        XCTAssertTrue(singleError()?.message.contains("Unexpected redirect") ?? false, "\(errors)")
        XCTAssertEqual(singleError()?.events.map(\.action), ["a"])

        acceptAll()
        scheduler.advance(by: 5 * 60)
        XCTAssertEqual(sentActions(1), ["a"])
    }

    func test_413ForAMultiEventBatchSplitsItAndDeliversEverything() throws {
        var delivered: [String] = []
        respond = { [unowned self] _, done in
            let events = self.requests.last!
            if events.count > 3 { return done(.success(emptyResponse(status: 413))) }
            delivered.append(contentsOf: self.actionsOf(events))
            done(.success(accepted()))
        }
        let beacon = try start(batchSize: 100)
        for i in 0..<10 {
            beacon.track("screen", "e\(i)")
        }
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(delivered, (0..<10).map { "e\($0)" })
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(requests.first?.count, 10)
        for request in requests.dropFirst() {
            XCTAssertLessThan(request.count, 10)
        }
    }

    func test_413ForASingleEventDropsItAndDeliversTheRest() throws {
        var delivered: [String] = []
        respond = { [unowned self] _, done in
            let events = self.requests.last!
            if self.actionsOf(events).contains("big") { return done(.success(emptyResponse(status: 413))) }
            delivered.append(contentsOf: self.actionsOf(events))
            done(.success(accepted()))
        }
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.track("screen", "big")
        beacon.track("screen", "c")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(delivered, ["a", "c"])
        let error = singleError()
        XCTAssertEqual(error?.type, .validation)
        XCTAssertEqual(error?.message, "Event is larger than the API accepts")
        XCTAssertEqual(error?.willRetry, false)
        XCTAssertEqual(error?.events.map(\.action), ["big"])

        let sent = requests.count
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, sent, "nothing left to send")
    }

    // MARK: backoff

    func test_trackingPastBatchSizeWhileOfflineWaitsForTheBackoff() throws {
        offline()
        let beacon = try start(batchSize: 3)
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        beacon.track("screen", "c")
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, 1)

        for i in 0..<50 {
            beacon.track("screen", "more\(i)")
            scheduler.advance(by: 0.1)
        }
        XCTAssertEqual(requests.count, 1, "still inside the 10s backoff")

        scheduler.advance(by: 5)
        XCTAssertEqual(requests.count, 2, "the backoff timer fired")
    }

    func test_trackingPastBatchSizeHonoursRetryAfter() throws {
        answer(429, headers: ["retry-after": "60"])
        let beacon = try start(batchSize: 3)
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        beacon.track("screen", "c")
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, 1)

        for i in 0..<30 {
            beacon.track("screen", "more\(i)")
            scheduler.advance(by: 1)
        }
        XCTAssertEqual(requests.count, 1)

        scheduler.advance(by: 30)
        XCTAssertEqual(requests.count, 2)
    }

    func test_aServerAnswerAfterNetworkFailuresRestoresTheInterval() throws {
        offline()
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        scheduler.advance(by: 10)
        XCTAssertEqual(requests.count, 2, "two network failures")

        // The server rejects the lone event as too large: a real answer.
        answer(413)
        scheduler.advance(by: 20)
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(errors.last?.type, .validation)

        acceptAll()
        beacon.track("screen", "b")
        scheduler.advance(by: 5)
        XCTAssertEqual(sentActions(3), ["b"])
    }

    func test_aLatchedFlushIsDiscardedAfterATransientFailure() throws {
        var firstResponse: ((Result<HTTPResponse, Error>) -> Void)?
        respond = { _, done in firstResponse = done }
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        beacon.track("screen", "b")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        firstResponse?(.success(emptyResponse(status: 503)))
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, 1)
    }

    func test_anUnexpectedExceptionIsTreatedAsANetworkFailure() throws {
        let transport = ThrowingTransport()
        let beacon = try start(transport: transport)
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(transport.sends, 1)
        XCTAssertEqual(singleError()?.type, .network)
        XCTAssertEqual(singleError()?.willRetry, true)
        XCTAssertEqual(singleError()?.events.map(\.action), ["a"])

        scheduler.advance(by: 5)
        XCTAssertEqual(transport.sends, 1, "backed off to 10s")
        scheduler.advance(by: 5)
        XCTAssertEqual(transport.sends, 2, "the event was kept")
    }

    // MARK: batching

    func test_theBatchSizeRecoversAfterA413OnceTheQueueDrains() throws {
        respond = { [unowned self] _, done in
            done(.success(self.requests.last!.count > 3 ? emptyResponse(status: 413) : accepted()))
        }
        let beacon = try start(batchSize: 100)
        for i in 0..<10 {
            beacon.track("screen", "e\(i)")
        }
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertTrue(errors.isEmpty, "\(errors)")

        acceptAll()
        let before = requests.count
        for i in 0..<10 {
            beacon.track("screen", "f\(i)")
        }
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, before + 1)
        XCTAssertEqual(requests.last?.count, 10)
    }

    func test_theBatchSizeRecoversAfterDroppingAnOversizedEvent() throws {
        respond = { [unowned self] _, done in
            done(.success(self.actionsOf(self.requests.last!).contains("big") ? emptyResponse(status: 413) : accepted()))
        }
        let beacon = try start(batchSize: 100)
        for action in ["a", "big", "c", "d", "e"] {
            beacon.track("screen", action)
        }
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(singleError()?.events.map(\.action), ["big"])
        XCTAssertEqual(sentActions(requests.count - 1), ["c", "d", "e"])
    }

    func test_aBacklogReadMidSendIsAppendedAndSentInOrder() throws {
        storage = MemoryQueueStorage(v1([storedEvent("stored")]))
        storage.readError = CocoaError(.fileReadNoPermission)
        var firstResponse: ((Result<HTTPResponse, Error>) -> Void)?
        respond = { [unowned self] _, done in
            if self.requests.count == 1 {
                firstResponse = done
            } else {
                done(.success(accepted()))
            }
        }
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(sentActions(0), ["a"])

        storage.readError = nil
        beacon.track("screen", "b") // Its write reads the backlog.
        scheduler.runUntilIdle()

        firstResponse?(.success(accepted()))
        scheduler.runUntilIdle()
        XCTAssertEqual(sentActions(1), ["b", "stored"])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(storedActions(storage.contents), [])
    }
}
