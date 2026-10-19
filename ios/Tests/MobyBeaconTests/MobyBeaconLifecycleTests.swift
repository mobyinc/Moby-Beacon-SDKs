import Foundation
import XCTest
@testable import MobyBeacon

/// Ports the `lifecycle` group of `moby_beacon_test.dart`. Lifecycle changes
/// arrive through `FakeLifecycleSource.emit`, Dart's `setLifecycle`.
final class MobyBeaconLifecycleTests: BeaconHarness {
    private var lifecycle: FakeLifecycleSource!

    override func setUp() {
        super.setUp()
        lifecycle = FakeLifecycleSource()
    }

    override func tearDown() {
        lifecycle = nil
        super.tearDown()
    }

    private func offline() {
        respond = { _, done in done(.failure(URLError(.notConnectedToInternet))) }
    }

    func test_pausedPersistsAndFlushes() throws {
        let beacon = try start(lifecycle: lifecycle)
        beacon.track("screen", "a")
        lifecycle.emit(.paused)
        scheduler.runUntilIdle()

        XCTAssertEqual(sentActions(0), ["a"])
        XCTAssertEqual(storedActions(storage.contents), [])
    }

    /// Dart's "hidden persists and flushes": iOS has no `hidden`, so this
    /// covers the one remaining state, which persists without sending.
    func test_terminatingPersistsWithoutFlushing() throws {
        let beacon = try start(lifecycle: lifecycle)
        // The write `track` starts fails, so only `persist` can store "a".
        storage.writeError = URLError(.cannotWriteToFile)
        beacon.track("screen", "a")
        scheduler.runUntilIdle()
        XCTAssertNil(storage.contents, "the write track started failed")
        storage.writeError = nil

        var done = false
        lifecycle.emit(.terminating) { done = true }
        scheduler.runUntilIdle()

        XCTAssertTrue(done)
        XCTAssertTrue(requests.isEmpty, "terminating does not flush")
        XCTAssertEqual(storedActions(storage.contents), ["a"])
    }

    func test_resumedFlushesImmediatelyAndResetsBackoff() throws {
        offline()
        let beacon = try start(lifecycle: lifecycle)
        beacon.track("screen", "a")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, 2, "two failures so far")

        lifecycle.emit(.resumed)
        scheduler.runUntilIdle()
        XCTAssertEqual(requests.count, 3, "resume flushes immediately")

        // Reset to zero, then one failure: next attempt in 10s, not 40s.
        scheduler.advance(by: 10)
        XCTAssertEqual(requests.count, 4)
    }

    func test_resumedReadsABacklogThatWasLockedAtLaunchAndSendsIt() throws {
        storage = MemoryQueueStorage(v1([storedEvent("stored")]))
        storage.readError = CocoaError(.fileReadNoPermission)
        _ = try start(lifecycle: lifecycle)
        scheduler.advance(by: 5)
        XCTAssertTrue(requests.isEmpty)

        storage.readError = nil
        lifecycle.emit(.resumed)
        scheduler.runUntilIdle()

        XCTAssertEqual(sentActions(0), ["stored"])
        XCTAssertEqual(storedActions(storage.contents), [])
        XCTAssertTrue(errors.isEmpty, "\(errors)")
    }

    func test_disposeFlushesThenTrackAndFlushDoNothing() throws {
        let beacon = try start(lifecycle: lifecycle)
        beacon.track("screen", "a")
        beacon.dispose(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertEqual(sentActions(0), ["a"])

        beacon.track("screen", "b")
        beacon.flush(completion: nil)
        scheduler.runUntilIdle()
        scheduler.advance(by: 10 * 60)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(storedActions(storage.contents), [], "b was never queued")
    }

    func test_disposeKeepsUnsentEventsOnDisk() throws {
        offline()
        let beacon = try start(lifecycle: lifecycle)
        beacon.track("screen", "a")
        beacon.dispose(completion: nil)
        scheduler.runUntilIdle()

        XCTAssertEqual(storedActions(storage.contents), ["a"])
    }

    // MARK: Swift additions

    func test_pausedCompletionFiresAfterPersistAndFlushSettle() throws {
        var send: ((Result<HTTPResponse, Error>) -> Void)?
        respond = { _, done in send = done }
        let beacon = try start(lifecycle: lifecycle)
        beacon.track("screen", "a")
        var done = false
        lifecycle.emit(.paused) { done = true }
        scheduler.runUntilIdle()
        XCTAssertNotNil(send, "the flush is sending")
        XCTAssertFalse(done, "the send has not settled")

        send?(.success(accepted()))
        scheduler.runUntilIdle()
        XCTAssertTrue(done)
    }

    func test_disposeStopsTheLifecycleSource() throws {
        let beacon = try start(lifecycle: lifecycle)
        XCTAssertFalse(lifecycle.stopped)

        beacon.dispose(completion: nil)
        scheduler.runUntilIdle()
        XCTAssertTrue(lifecycle.stopped)
    }

    /// The guard that ends a background task once, whether the beacon's
    /// `done` or the expiration handler fires first.
    func test_onceTokenRunsItsBodyOnceAcrossThreads() {
        let once = OnceToken()
        let lock = NSLock()
        var runs = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            once.run {
                lock.lock()
                runs += 1
                lock.unlock()
            }
        }
        once.run { runs += 1 }
        XCTAssertEqual(runs, 1)
    }
}
