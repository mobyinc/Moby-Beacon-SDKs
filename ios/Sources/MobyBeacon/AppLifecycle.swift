import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The app lifecycle changes the beacon reacts to.
enum AppLifecycleState {
    case paused, resumed, terminating
}

/// Reports app lifecycle changes to the beacon.
protocol LifecycleSource: AnyObject {
    /// Starts reporting changes to `handler`, which calls `done` once it has
    /// finished reacting to that change.
    func start(_ handler: @escaping (_ state: AppLifecycleState, _ done: @escaping () -> Void) -> Void)

    /// Stops reporting changes.
    func stop()
}

/// Runs a body at most once, however many threads call `run`.
final class OnceToken {
    private let lock = NSLock()
    private var ran = false

    /// Runs `body` if no earlier call has; otherwise does nothing.
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !ran
        ran = true
        lock.unlock()
        if first { body() }
    }
}

#if canImport(UIKit)
/// Reports `UIApplication` lifecycle notifications. Entering the background
/// holds a background task until the beacon has persisted and flushed.
final class UIKitLifecycleSource: LifecycleSource {
    private let notificationCenter: NotificationCenter
    private let application: UIApplication?
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    /// `application` defaults to `UIApplication.shared`, resolved when the app enters the background.
    init(notificationCenter: NotificationCenter = .default, application: UIApplication? = nil) {
        self.notificationCenter = notificationCenter
        self.application = application
    }

    func start(_ handler: @escaping (AppLifecycleState, @escaping () -> Void) -> Void) {
        let center = notificationCenter
        let injected = application
        let added = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
                let task = BackgroundTask(application: injected ?? UIApplication.shared)
                task.begin()
                handler(.paused, task.end)
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
                handler(.resumed, {})
            },
            center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                handler(.terminating, {})
            },
        ]
        lock.lock()
        observers += added
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let removed = observers
        observers = []
        lock.unlock()
        removed.forEach(notificationCenter.removeObserver)
    }
}

/// One background task, ended exactly once: when the beacon is done or when
/// the system's time runs out, whichever comes first (possibly on different
/// threads).
private final class BackgroundTask {
    private let application: UIApplication
    private let once = OnceToken()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(application: UIApplication) {
        self.application = application
    }

    /// Called on the main thread, before `end` can run.
    func begin() {
        identifier = application.beginBackgroundTask(withName: "MobyBeacon flush") { [self] in end() }
    }

    func end() {
        once.run {
            if identifier != .invalid { application.endBackgroundTask(identifier) }
        }
    }
}
#endif
