import XCTest
@testable import MobyBeacon

final class TestSchedulerTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-10-07T12:00:00Z")!

    func test_runUntilIdleRunsWorkEnqueuedByWork() {
        let scheduler = TestScheduler()
        var log: [String] = []
        scheduler.async {
            log.append("a")
            scheduler.async { log.append("c") }
        }
        scheduler.async { log.append("b") }
        XCTAssertEqual(scheduler.pendingWorkCount, 2)
        XCTAssertEqual(log, [])

        scheduler.runUntilIdle()

        XCTAssertEqual(log, ["a", "b", "c"])
        XCTAssertEqual(scheduler.pendingWorkCount, 0)
    }

    func test_advanceFiresTimersInDueOrderThenInsertionOrder() {
        let scheduler = TestScheduler()
        var log: [String] = []
        _ = scheduler.schedule(after: 3) { log.append("3-first") }
        _ = scheduler.schedule(after: 1) { log.append("1") }
        _ = scheduler.schedule(after: 3) { log.append("3-second") }
        _ = scheduler.schedule(after: 2) {
            log.append("2")
            scheduler.async { log.append("2-work") }
        }
        _ = scheduler.schedule(after: 4) { log.append("4") }
        XCTAssertEqual(scheduler.pendingTimerCount, 5)

        scheduler.advance(by: 3)

        XCTAssertEqual(log, ["1", "2", "2-work", "3-first", "3-second"])
        XCTAssertEqual(scheduler.pendingTimerCount, 1)
        XCTAssertEqual(scheduler.now, start.addingTimeInterval(3))
    }

    func test_advanceMovesNowToEachTimerBeforeFiring() {
        let scheduler = TestScheduler()
        var seen: [Date] = []
        _ = scheduler.schedule(after: 5) { seen.append(scheduler.now) }
        _ = scheduler.schedule(after: 2) { seen.append(scheduler.now) }

        scheduler.advance(by: 10)

        XCTAssertEqual(seen, [start.addingTimeInterval(2), start.addingTimeInterval(5)])
        XCTAssertEqual(scheduler.now, start.addingTimeInterval(10))
    }

    func test_cancelledTimerDoesNotFire() {
        let scheduler = TestScheduler()
        var fired = false
        let timer = scheduler.schedule(after: 1) { fired = true }
        XCTAssertEqual(scheduler.pendingTimerCount, 1)

        timer.cancel()

        XCTAssertEqual(scheduler.pendingTimerCount, 0)
        scheduler.advance(by: 5)
        XCTAssertFalse(fired)
    }

    func test_timerScheduledDuringAdvanceFiresIfDueWithinTheSameAdvance() {
        let scheduler = TestScheduler()
        var log: [String] = []
        _ = scheduler.schedule(after: 1) {
            log.append("outer")
            _ = scheduler.schedule(after: 2) { log.append("inner-in-window") }
            _ = scheduler.schedule(after: 5) { log.append("inner-past-window") }
        }

        scheduler.advance(by: 3)

        XCTAssertEqual(log, ["outer", "inner-in-window"])
        XCTAssertEqual(scheduler.pendingTimerCount, 1)

        scheduler.advance(by: 3)

        XCTAssertEqual(log, ["outer", "inner-in-window", "inner-past-window"])
        XCTAssertEqual(scheduler.pendingTimerCount, 0)
    }

    func test_dispatchSchedulerRunsWorkOnItsQueue() {
        let queue = DispatchQueue(label: "test.scheduler")
        let scheduler = DispatchScheduler(queue: queue, clock: { self.start })
        XCTAssertEqual(scheduler.now, start)

        let ranAsync = expectation(description: "async work ran")
        let ranTimer = expectation(description: "timer fired")
        scheduler.async {
            dispatchPrecondition(condition: .onQueue(queue))
            ranAsync.fulfill()
        }
        _ = scheduler.schedule(after: 0.01) {
            dispatchPrecondition(condition: .onQueue(queue))
            ranTimer.fulfill()
        }

        wait(for: [ranAsync, ranTimer], timeout: 1)
    }
}
