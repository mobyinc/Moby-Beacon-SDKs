import Foundation
import XCTest
@testable import MobyBeacon

/// Ports the `track`, `automatic flushing` and `flush and dispose` groups of
/// `moby_beacon_test.dart`. Dart's synchronous `track` becomes a hop onto the
/// scheduler, so tests run it until idle before asserting.
final class MobyBeaconTests: BeaconHarness {
    // MARK: track

    func test_queuesAnEventWithTheDefaultUserIdAndAUTCTimestamp() throws {
        let beacon = try start()
        beacon.track("screen", "view", details: ["name": "home"])
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.count, 1)
        XCTAssertEqual(requests.first?.first as NSDictionary?, [
            "userId": "user-1",
            "category": "screen",
            "action": "view",
            "timestamp": "2026-10-07T12:00:00.000Z",
            "details": ["name": "home"],
        ] as NSDictionary)
    }

    func test_replacesALoneSurrogateFromTruncatedText() throws {
        // Dart's 'I feel \u{1F600}'.substring(0, 8): the emoji cut after its
        // high surrogate. Swift literals cannot hold a lone surrogate.
        let truncated = utf16String(Array("I feel ".utf16) + [0xD83D])
        let beacon = try start()
        beacon.track("survey", "answer", details: ["text": truncated])
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.first?["details"] as? NSDictionary, ["text": "I feel \u{FFFD}"] as NSDictionary)
        let body = mock.requests.first.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
        XCTAssertTrue(body.contains("I feel \u{FFFD}"), body)
    }

    func test_appliesUserIdAndTimestampOverrides() throws {
        let beacon = try start()
        beacon.track("screen", "view", userId: "user-2", timestamp: ISO8601.date(from: "2026-01-02T03:00:00.000Z")!)
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.first?["userId"] as? String, "user-2")
        XCTAssertEqual(requests.first?.first?["timestamp"] as? String, "2026-01-02T03:00:00.000Z")
    }

    func test_reportsInvalidEventsInsteadOfThrowing() throws {
        let beacon = try start()
        beacon.track("", "view")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.type, .validation)
        XCTAssertEqual(errors.first?.message, "category is required and must be a non-empty string")
        XCTAssertEqual(errors.first?.willRetry, false)
        XCTAssertTrue(requests.isEmpty)
    }

    func test_reportsAFullQueueInsteadOfThrowing() throws {
        let beacon = try start(maxQueueSize: 1)
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        scheduler.runUntilIdle()

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.type, .validation)
        XCTAssertEqual(errors.first?.message, "Queue is at capacity")
        XCTAssertEqual(errors.first?.events.map(\.action), ["b"])
    }

    /// Ports "a throwing onError does not break tracking". Swift cannot catch
    /// an exception from `onError`, so the hazard here is a handler that calls
    /// back into the beacon: it must neither deadlock nor disturb delivery.
    func test_anOnErrorThatTracksAndFlushesDoesNotBreakTracking() throws {
        var beacon: MobyBeacon!
        var handled = 0
        beacon = try start(onError: { _ in
            handled += 1
            beacon.track("screen", "from-handler")
            beacon.flush(completion: nil)
        })
        beacon.track("", "view")
        beacon.track("screen", "view")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(handled, 1)
        XCTAssertEqual(sentActions(0), ["view"])
        XCTAssertEqual(requests.flatMap(actionsOf), ["view", "from-handler"])
    }

    /// Dart snapshots the event inside `track`; here the scheduler runs later,
    /// so `track` must copy caller-owned mutable values before it returns.
    func test_aMutableArrayChangedAfterTrackIsReportedAsTracked() throws {
        let items = NSMutableArray(array: ["x"])
        let beacon = try start()
        beacon.track("screen", "view", details: ["items": items])
        items.add("y")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.type, .validation)
        XCTAssertEqual(
            errors.first?.message,
            "details.items must be a string, number, boolean, or null — not a nested object or array")
        XCTAssertEqual(errors.first?.events.first?.details?["items"] as? [String], ["x"])
        XCTAssertTrue(requests.isEmpty)
    }

    func test_aMutableStringChangedAfterTrackIsSentAsTracked() throws {
        let text = NSMutableString(string: "before")
        let beacon = try start()
        beacon.track("survey", "answer", details: ["text": text])
        text.setString("after")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(requests.first?.first?["details"] as? NSDictionary, ["text": "before"] as NSDictionary)
    }

    // MARK: automatic flushing

    func test_flushesWhenBatchSizeIsReached() throws {
        let beacon = try start(batchSize: 3)
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        scheduler.runUntilIdle()
        XCTAssertTrue(requests.isEmpty)

        beacon.track("screen", "c")
        scheduler.runUntilIdle()
        XCTAssertEqual(sentActions(0), ["a", "b", "c"])
    }

    func test_flushesWhenTheTimerFires() throws {
        let beacon = try start()
        beacon.track("screen", "a")
        scheduler.advance(by: 4)
        XCTAssertTrue(requests.isEmpty)

        scheduler.advance(by: 1)
        XCTAssertEqual(sentActions(0), ["a"])
    }

    func test_aFlushOfAnEmptyQueueDoesNotBlockLaterFlushes() throws {
        let beacon = try start()
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        scheduler.advance(by: 5)
        XCTAssertTrue(requests.isEmpty)

        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(sentActions(0), ["a"])
    }

    func test_sendsEventsPersistedByAPreviousInstanceOnStart() throws {
        storage = MemoryQueueStorage(v1([storedEvent("left-over")]))
        _ = try start()

        XCTAssertEqual(sentActions(0), ["left-over"])
    }

    func test_reportsAnUnreadablePersistedQueueOnStart() throws {
        storage = MemoryQueueStorage("{not json")
        _ = try start()

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.type, .validation)
        XCTAssertEqual(errors.first?.willRetry, false)
        XCTAssertTrue(storage.quarantined)
    }

    func test_sendsALargeBacklogInBoundedRequestsInOrder() throws {
        let beacon = try start(batchSize: 5000, maxQueueSize: 2500)
        for i in 0..<2500 {
            beacon.track("screen", "e\(i)")
        }
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(requests.flatMap(actionsOf), (0..<2500).map { "e\($0)" })
        XCTAssertGreaterThan(requests.count, 1)
        for request in requests {
            XCTAssertLessThanOrEqual(request.count, maxEventsPerRequest)
        }
        for bytes in requestBytes {
            XCTAssertLessThanOrEqual(bytes, maxRequestBytes + 64)
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
    }

    func test_aFlushRequestedMidFlightSendsEventsTrackedMeanwhile() throws {
        var firstResponse: ((Result<HTTPResponse, Error>) -> Void)?
        respond = { [unowned self] _, done in
            if self.requests.count == 1 { firstResponse = done } else { done(.success(accepted())) }
        }
        let beacon = try start()

        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        beacon.track("screen", "b")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, 1)

        firstResponse?(.success(accepted()))
        scheduler.runUntilIdle()
        XCTAssertEqual(sentActions(0), ["a"])
        XCTAssertEqual(sentActions(1), ["b"])
        XCTAssertEqual(requests.count, 2)
    }

    // MARK: flush and dispose

    func test_awaitingFlushDuringAFlushWaitsForEventsQueuedMeanwhile() throws {
        var firstResponse: ((Result<HTTPResponse, Error>) -> Void)?
        var flushDone = false
        var doneWhenSecondSent: Bool?
        respond = { [unowned self] _, done in
            if self.requests.count == 1 {
                firstResponse = done
                return
            }
            doneWhenSecondSent = flushDone
            done(.success(accepted()))
        }
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        beacon.track("screen", "b")
        beacon.flush { flushDone = true }
        scheduler.runUntilIdle()
        XCTAssertFalse(flushDone)

        firstResponse?(.success(accepted()))
        scheduler.runUntilIdle()
        XCTAssertEqual(sentActions(1), ["b"])
        XCTAssertEqual(doneWhenSecondSent, false)
        XCTAssertTrue(flushDone)
    }

    func test_disposeWaitsForAnInFlightSendThenSendsTheRest() throws {
        var firstResponse: ((Result<HTTPResponse, Error>) -> Void)?
        respond = { [unowned self] _, done in
            if self.requests.count == 1 { firstResponse = done } else { done(.success(accepted())) }
        }
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        beacon.track("screen", "b")

        var disposed = false
        beacon.dispose { disposed = true }
        scheduler.runUntilIdle()
        XCTAssertFalse(disposed)
        XCTAssertEqual(requests.count, 1)

        firstResponse?(.success(accepted()))
        scheduler.runUntilIdle()
        XCTAssertEqual(sentActions(1), ["b"])
        XCTAssertTrue(disposed)
        XCTAssertEqual(storedActions(storage.contents), [])
    }

    func test_aSecondDisposeCompletesOnlyWhenTheFirstDoes() throws {
        var response: ((Result<HTTPResponse, Error>) -> Void)?
        respond = { _, done in response = done }
        let beacon = try start()
        beacon.track("screen", "a")

        var firstDone = false
        var secondDone = false
        beacon.dispose { firstDone = true }
        scheduler.runUntilIdle()
        beacon.dispose { secondDone = true }
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(secondDone)

        response?(.success(accepted()))
        scheduler.runUntilIdle()
        XCTAssertTrue(firstDone)
        XCTAssertTrue(secondDone)
    }

    func test_flushDuringDisposeDoesNotStartAnotherSend() throws {
        respond = { _, done in done(.failure(URLError(.notConnectedToInternet))) }
        storage.holdWrites = true
        let beacon = try start()
        beacon.track("screen", "a")

        var disposed = false
        beacon.dispose { disposed = true }
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(disposed, "waiting for the held write")

        var flushed = false
        beacon.flush { flushed = true }
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(flushed, "a flush after dispose still completes")

        storage.releaseHeldWrites()
        scheduler.runUntilIdle()
        XCTAssertTrue(disposed)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(storedActions(storage.contents), ["a"])
    }

    func test_onlyOneInstanceCanBeLiveUntilDisposeCompletes() throws {
        var response: ((Result<HTTPResponse, Error>) -> Void)?
        respond = { _, done in response = done }
        let first = try start()

        XCTAssertThrowsError(try makeBeacon()) { error in
            XCTAssertEqual(error as? MobyBeaconSetupError, .alreadyRunning)
            XCTAssertTrue(error.localizedDescription.contains("already running"), error.localizedDescription)
        }

        first.track("screen", "a")
        first.dispose(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertThrowsError(try makeBeacon(), "still disposing") { error in
            XCTAssertEqual(error as? MobyBeaconSetupError, .alreadyRunning)
        }

        response?(.success(accepted()))
        scheduler.runUntilIdle()
        XCTAssertNoThrow(try start(), "dispose finished, so this succeeds")
    }

    func test_disposeLeavesNoTimersBehind() throws {
        respond = { _, done in done(.failure(URLError(.notConnectedToInternet))) }
        let beacon = try start()
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()

        beacon.dispose(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(scheduler.pendingTimerCount, 0)
    }

    /// Lifecycle changes that arrive after `dispose` (a notification already
    /// in flight when the source was stopped) only call `done`.
    func test_lifecycleChangesAfterDisposeDoNothing() throws {
        respond = { _, done in done(.failure(URLError(.notConnectedToInternet))) }
        let lifecycle = FakeLifecycleSource()
        let beacon = try start(lifecycle: lifecycle)
        beacon.track("screen", "a")
        beacon.dispose(completion: nil)
        scheduler.runUntilIdle()
        let sent = requests.count
        let writes = storage.writeCount
        // The failed send leaves "a" queued, so a persist or flush would act.
        XCTAssertEqual(storedActions(storage.contents), ["a"])

        var completed: [AppLifecycleState] = []
        for state in [AppLifecycleState.paused, .resumed, .terminating] {
            lifecycle.emit(state) { completed.append(state) }
        }
        scheduler.runUntilIdle()
        scheduler.advance(by: 10 * 60)
        XCTAssertEqual(completed, [.paused, .resumed, .terminating])
        XCTAssertEqual(requests.count, sent)
        XCTAssertEqual(storage.writeCount, writes)
    }

    // MARK: Review Focus — real threads

    func test_concurrentTrackFromManyThreadsLosesNoEvents() throws {
        let client = MockHTTPClient()
        client.handler = { _, done in DispatchQueue.global().async { done(.success(accepted())) } }
        let beacon = try startOnDispatchScheduler(client: client, batchSize: 1000, maxQueueSize: 1000)

        DispatchQueue.concurrentPerform(iterations: 8) { thread in
            for index in 0..<50 {
                beacon.track("screen", "concurrent", details: ["thread": thread, "index": index])
            }
        }
        let flushed = expectation(description: "flush")
        beacon.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 1)

        let sent = client.requests.flatMap { request -> [[String: Any]] in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            return body?["events"] as? [[String: Any]] ?? []
        }
        XCTAssertEqual(sent.count, 400)
        let keys = sent.compactMap { event -> String? in
            guard let details = event["details"] as? [String: Any],
                  let thread = details["thread"] as? Int,
                  let index = details["index"] as? Int
            else { return nil }
            return "\(thread)-\(index)"
        }
        XCTAssertEqual(keys.count, 400)
        XCTAssertEqual(Set(keys).count, 400, "duplicate events")

        disposeAndWait(beacon)
    }

    func test_onlyOneOfTwoConcurrentStartsSucceeds() throws {
        let lock = NSLock()
        var started: [MobyBeacon] = []
        var failures: [Error] = []
        let group = DispatchGroup()
        for _ in 0..<2 {
            DispatchQueue.global().async(group: group) {
                do {
                    let beacon = try self.startOnDispatchScheduler(client: MockHTTPClient())
                    lock.lock()
                    started.append(beacon)
                    lock.unlock()
                } catch {
                    lock.lock()
                    failures.append(error)
                    lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first as? MobyBeaconSetupError, .alreadyRunning)

        for beacon in started {
            disposeAndWait(beacon)
        }
    }

    /// A beacon on its own `DispatchScheduler`, over in-memory storage and
    /// `client`.
    private func startOnDispatchScheduler(
        client: MockHTTPClient,
        batchSize: Int = 10,
        maxQueueSize: Int = 100
    ) throws -> MobyBeacon {
        let scheduler = DispatchScheduler()
        let config = try MobyBeaconConfig(endpoint: "https://beacon.test", apiKey: "key-123", userId: "user-1")
        config.batchSize = batchSize
        config.maxQueueSize = maxQueueSize
        return try MobyBeacon.start(
            config: config,
            store: EventStore(storage: MemoryQueueStorage(), maxSize: maxQueueSize, scheduler: scheduler),
            transport: Transport(endpoint: "https://beacon.test", apiKey: "key-123", client: client),
            scheduler: scheduler,
            random: FixedRandom(0),
            deliverCallback: { $0() },
            lifecycle: nil)
    }

    private func disposeAndWait(_ beacon: MobyBeacon) {
        let disposed = expectation(description: "dispose")
        beacon.dispose { disposed.fulfill() }
        wait(for: [disposed], timeout: 1)
    }
}
