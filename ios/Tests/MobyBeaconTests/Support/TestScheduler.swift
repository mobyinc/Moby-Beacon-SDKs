import Foundation
@testable import MobyBeacon

/// Virtual-time `Scheduler`, the Swift stand-in for Dart's `fake_async`.
///
/// Nothing runs until the test drives it: `runUntilIdle()` in place of
/// `flushMicrotasks()`, `advance(by:)` in place of `elapse()`. Single-threaded
/// by design; drive it from the test thread only.
final class TestScheduler: Scheduler {
    private final class Timer: Cancellable {
        let due: Date
        let seq: Int
        let work: () -> Void
        var cancelled = false

        init(due: Date, seq: Int, work: @escaping () -> Void) {
            self.due = due
            self.seq = seq
            self.work = work
        }

        func cancel() {
            cancelled = true
        }
    }

    var now: Date
    private var work: [() -> Void] = []
    private var timers: [Timer] = []
    private var nextSeq = 0

    init(now: Date = ISO8601DateFormatter().date(from: "2026-10-07T12:00:00Z")!) {
        self.now = now
    }

    /// Timers scheduled and neither fired nor cancelled.
    var pendingTimerCount: Int {
        timers.filter { !$0.cancelled }.count
    }

    /// `async` work queued and not yet run.
    var pendingWorkCount: Int {
        work.count
    }

    func async(_ work: @escaping () -> Void) {
        self.work.append(work)
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> Cancellable {
        let timer = Timer(due: now.addingTimeInterval(delay), seq: nextSeq, work: work)
        nextSeq += 1
        timers.append(timer)
        return timer
    }

    /// Runs queued `async` work FIFO, including work enqueued while running,
    /// until the queue is empty.
    func runUntilIdle() {
        while !work.isEmpty {
            work.removeFirst()()
        }
    }

    /// Moves `now` forward to each timer due within `delta`, in due order
    /// (scheduling order on ties), firing it and then running until idle.
    /// Timers scheduled meanwhile fire if they fall within the window. `now`
    /// ends at the start plus `delta`.
    func advance(by delta: TimeInterval) {
        let end = now.addingTimeInterval(delta)
        runUntilIdle()
        while let timer = nextDueTimer(notAfter: end) {
            timers.removeAll { $0 === timer }
            now = timer.due
            timer.work()
            runUntilIdle()
        }
        now = end
    }

    private func nextDueTimer(notAfter end: Date) -> Timer? {
        timers.removeAll { $0.cancelled }
        guard let next = timers.min(by: { ($0.due, $0.seq) < ($1.due, $1.seq) }),
              next.due <= end
        else { return nil }
        return next
    }
}
