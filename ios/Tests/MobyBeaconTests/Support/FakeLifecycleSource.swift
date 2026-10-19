import Foundation
import XCTest
@testable import MobyBeacon

/// A `LifecycleSource` the test drives: `emit` delivers a change to the
/// handler passed to `start`, as Dart's `setLifecycle` does. It keeps
/// delivering after `stop`, like a notification already in flight.
final class FakeLifecycleSource: LifecycleSource {
    private var handler: ((AppLifecycleState, @escaping () -> Void) -> Void)?
    var stopped = false

    func start(_ handler: @escaping (AppLifecycleState, @escaping () -> Void) -> Void) {
        self.handler = handler
    }

    func stop() {
        stopped = true
    }

    func emit(
        _ state: AppLifecycleState,
        done: @escaping () -> Void = {},
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let handler else {
            return XCTFail("emit(\(state)) before start", file: file, line: line)
        }
        handler(state, done)
    }
}
