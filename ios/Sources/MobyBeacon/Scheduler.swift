import Foundation

/// A handle to scheduled work that can be cancelled before it runs.
protocol Cancellable: AnyObject {
    func cancel()
}

/// The SDK's single serial execution context, standing in for Dart's event
/// loop. All SDK state is touched only from work run by a `Scheduler`.
protocol Scheduler: AnyObject {
    /// The current time. Safe to read from any thread.
    var now: Date { get }

    /// Runs `work` later on the serial context.
    func async(_ work: @escaping () -> Void)

    /// Runs `work` on the serial context after `delay` seconds, unless the
    /// returned handle is cancelled first.
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> Cancellable
}

/// Production `Scheduler` backed by a serial `DispatchQueue`.
final class DispatchScheduler: Scheduler {
    let queue: DispatchQueue
    private let clock: () -> Date

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.mobyinc.beacon"),
        clock: @escaping () -> Date = Date.init
    ) {
        self.queue = queue
        self.clock = clock
    }

    var now: Date {
        clock()
    }

    func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> Cancellable {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }
}

extension DispatchWorkItem: Cancellable {}

/// Delivers a user-facing callback, by default on the main queue:
/// `{ DispatchQueue.main.async(execute: $0) }`.
typealias CallbackDispatcher = (@escaping () -> Void) -> Void
