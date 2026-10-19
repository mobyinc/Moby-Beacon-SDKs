import Foundation

/// The API accepts at most this many events per request.
let maxEventsPerRequest = 1000

/// Upper bound on the encoded events in one request. The API rejects JSON
/// bodies over 100 kB (Express's default), so this leaves headroom.
let maxRequestBytes = 64 * 1024

/// Batches study events, persists them to disk, and sends them to a Moby
/// Beacon API. Create one instance per app with `start(config:)`.
///
/// Every method may be called from any thread. All state lives on one serial
/// `Scheduler`; `onError` and completions are delivered on the main queue.
@objc(MobyBeacon)
public final class MobyBeacon: NSObject {
    /// The instance that has been started and whose `dispose` has not yet
    /// completed. Two instances would share, and overwrite, one queue file.
    private static var live: MobyBeacon?
    private static let liveLock = NSLock()

    private let settings: Settings
    private let store: EventStore
    private let transport: Transport
    private let scheduler: Scheduler
    private let random: RandomSource
    private let deliverCallback: CallbackDispatcher
    private let lifecycle: LifecycleSource?

    // Everything below is touched only on `scheduler`.

    /// The stored backlog has been read; until then work waits in
    /// `waitingForLoad` so it is ordered after the backlog, as in Flutter.
    private var loaded = false
    private var waitingForLoad: [() -> Void] = []

    private var timer: Cancellable?
    private var flushing = false
    private var flushRequested = false
    /// Run when the flush in flight finishes.
    private var runWaiters: [() -> Void] = []
    /// Run when the flush in flight finishes and then the follow-up run it
    /// latched, if one starts.
    private var latchedWaiters: [() -> Void] = []
    /// Run once no flush is in flight.
    private var idleWaiters: [() -> Void] = []
    private var consecutiveFailures = 0
    /// Most events sent in one request.
    private var batchLimit = maxEventsPerRequest

    private var disposing = false
    private var disposed = false
    private var disposeWaiters: [() -> Void] = []

    private init(
        settings: Settings,
        store: EventStore,
        transport: Transport,
        scheduler: Scheduler,
        random: RandomSource,
        deliverCallback: @escaping CallbackDispatcher,
        lifecycle: LifecycleSource?
    ) {
        self.settings = settings
        self.store = store
        self.transport = transport
        self.scheduler = scheduler
        self.random = random
        self.deliverCallback = deliverCallback
        self.lifecycle = lifecycle
        super.init()
    }

    // MARK: Starting

    /// Starts a beacon that loads any events left from a previous run, then
    /// starts sending.
    ///
    /// Throws `MobyBeaconSetupError.alreadyRunning` if another instance has
    /// not finished `dispose`, `.storageUnavailable` if Application Support
    /// cannot be located, and a validation error for a bad `flushInterval`,
    /// `batchSize` or `maxQueueSize`.
    @objc(startWithConfig:error:)
    public static func start(config: MobyBeaconConfig) throws -> MobyBeacon {
        try checkNoLiveInstance()
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw MobyBeaconSetupError.storageUnavailable("the Application Support directory was not found")
        }
        let settings = try config.validatedSettings()
        let scheduler = DispatchScheduler()
        let transport = Transport(endpoint: settings.endpoint, apiKey: settings.apiKey)
        do {
            return try start(
                settings: settings,
                store: EventStore(
                    storage: FileQueueStorage(directory: support.appendingPathComponent("moby_beacon")),
                    maxSize: settings.maxQueueSize,
                    scheduler: scheduler),
                transport: transport,
                scheduler: scheduler,
                random: SystemRandom(),
                deliverCallback: { DispatchQueue.main.async(execute: $0) },
                lifecycle: defaultLifecycleSource())
        } catch {
            // Lost the race for the live slot (or begin failed): release the URLSession.
            transport.close()
            throw error
        }
    }

    private static func defaultLifecycleSource() -> LifecycleSource? {
        #if canImport(UIKit)
        return UIKitLifecycleSource()
        #else
        return nil
        #endif
    }

    /// Flutter's `createWith`: `start(config:)` with every collaborator
    /// injected.
    static func start(
        config: MobyBeaconConfig,
        store: EventStore,
        transport: Transport,
        scheduler: Scheduler,
        random: RandomSource,
        deliverCallback: @escaping CallbackDispatcher,
        lifecycle: LifecycleSource?
    ) throws -> MobyBeacon {
        try checkNoLiveInstance()
        return try start(
            settings: config.validatedSettings(),
            store: store,
            transport: transport,
            scheduler: scheduler,
            random: random,
            deliverCallback: deliverCallback,
            lifecycle: lifecycle)
    }

    /// Reserves the live slot atomically, then starts outside the lock so
    /// `begin()` (storage, lifecycle source) can never deadlock against it.
    private static func start(
        settings: Settings,
        store: EventStore,
        transport: Transport,
        scheduler: Scheduler,
        random: RandomSource,
        deliverCallback: @escaping CallbackDispatcher,
        lifecycle: LifecycleSource?
    ) throws -> MobyBeacon {
        let beacon = MobyBeacon(
            settings: settings,
            store: store,
            transport: transport,
            scheduler: scheduler,
            random: random,
            deliverCallback: deliverCallback,
            lifecycle: lifecycle)
        liveLock.lock()
        guard live == nil else {
            liveLock.unlock()
            throw MobyBeaconSetupError.alreadyRunning
        }
        live = beacon
        liveLock.unlock()
        do {
            try beacon.begin()
        } catch {
            clearLive(beacon)
            throw error
        }
        return beacon
    }

    private static func clearLive(_ beacon: MobyBeacon) {
        liveLock.lock()
        if live === beacon { live = nil }
        liveLock.unlock()
    }

    /// Forgets the live instance, for tests whose dispose cannot complete.
    static func resetLiveInstanceForTesting() {
        liveLock.lock()
        live = nil
        liveLock.unlock()
    }

    private static func checkNoLiveInstance() throws {
        liveLock.lock()
        defer { liveLock.unlock() }
        if live != nil { throw MobyBeaconSetupError.alreadyRunning }
    }

    /// Runs on the caller's thread, before the beacon is returned, so touching
    /// the store here is safe; every later access hops onto `scheduler`.
    private func begin() throws {
        store.onDiscarded = { [weak self] message in
            guard let self else { return }
            self.report(.validation, message, [])
        }
        try store.load { [self] in
            loaded = true
            scheduleTimer()
            if store.count > 0 { requestFlush() }
            let waiting = waitingForLoad
            waitingForLoad = []
            waiting.forEach { $0() }
        }
        lifecycle?.start { [weak self] state, done in
            guard let self else { return done() }
            self.scheduler.async {
                self.afterLoad { self.handleLifecycle(state, completion: done) }
            }
        }
    }

    private func afterLoad(_ work: @escaping () -> Void) {
        if loaded {
            work()
        } else {
            waitingForLoad.append(work)
        }
    }

    // MARK: Tracking

    /// Queues an event. Never throws; invalid events and a full queue are
    /// reported through `onError`.
    @objc(track:action:details:userId:timestamp:)
    public func track(
        _ category: String,
        _ action: String,
        details: [String: Any]? = nil,
        userId: String? = nil,
        timestamp: Date? = nil
    ) {
        // Sanitized here, on the caller's thread, because sanitizeEvent also
        // copies details: later changes by the caller cannot alter the queued
        // event or race with encoding it. It runs before validation, so its
        // cost grows with the details passed, but it copies nested containers
        // only one level deep.
        let event = sanitizeEvent(MobyBeaconEvent(
            userId: userId ?? settings.userId,
            category: category,
            action: action,
            timestamp: timestamp ?? scheduler.now,
            details: details))
        scheduler.async { [self] in
            afterLoad { [self] in record(event) }
        }
    }

    /// The Objective-C `-track:action:details:`; Swift uses the defaults of
    /// the full form instead.
    @objc(track:action:details:)
    @available(swift, obsoleted: 1.0)
    public func track(_ category: String, _ action: String, details: [String: Any]?) {
        track(category, action, details: details, userId: nil, timestamp: nil)
    }

    /// Validates and queues `event`, which `track` has already sanitized.
    private func record(_ event: MobyBeaconEvent) {
        guard !disposing else { return }
        do {
            try validateEvent(event)
            try store.add(event)
        } catch let error as ValidationError {
            return report(.validation, error.message, [event])
        } catch StoreError.atCapacity {
            return report(.validation, "Queue is at capacity", [event])
        } catch {
            return report(.validation, "Event could not be encoded as JSON", [event])
        }
        // While backing off, leave retries to the timer so tracking cannot
        // bypass the backoff or a server's Retry-After.
        if store.count >= settings.batchSize && consecutiveFailures == 0 {
            scheduler.async { [self] in
                if !disposing { requestFlush() }
            }
        }
    }

    // MARK: Flushing

    /// Sends queued events. `completion` runs when the queue is empty or a
    /// send fails transiently (events stay queued and are retried with
    /// backoff).
    ///
    /// If a flush is already running, this waits for it and for the follow-up
    /// run that sends events queued meanwhile. Sends nothing once `dispose`
    /// has been called, but still calls `completion`.
    @objc(flushWithCompletion:)
    public func flush(completion: (() -> Void)?) {
        scheduler.async { [self] in
            afterLoad { [self] in
                let done = { [self] in deliver(completion) }
                if disposing { return done() }
                requestFlush(done)
            }
        }
    }

    @nonobjc
    public func flush() async {
        await withCheckedContinuation { continuation in
            flush { continuation.resume() }
        }
    }

    private func requestFlush(_ done: (() -> Void)? = nil) {
        if flushing {
            flushRequested = true
            if let done { latchedWaiters.append(done) }
            return
        }
        if let done { runWaiters.append(done) }
        flushing = true
        sendNext()
    }

    /// One pass of Flutter's `_runFlush` loop: sends the next batch, or
    /// finishes when the queue is empty.
    private func sendNext() {
        guard store.count > 0 else { return finishFlush(retryAfter: nil) }
        let batch = store.peek(batchLimit, maxBytes: maxRequestBytes)
        transport.send(batch) { [self] result in
            scheduler.async { [self] in
                switch result {
                case .success(let response):
                    store.removeFirst(batch.count)
                    consecutiveFailures = 0
                    if !response.errors.isEmpty {
                        report(
                            .validation,
                            "\(response.errors.count) event(s) rejected by server",
                            batch,
                            errors: response.errors)
                    }
                    sendNext()
                case .failure(let error as TransportError):
                    guard let status = error.statusCode else {
                        consecutiveFailures += 1
                        report(.network, error.message, batch, willRetry: true)
                        return finishFlush(retryAfter: nil)
                    }
                    if status == 408 || status == 429 || status >= 500 {
                        consecutiveFailures += 1
                        report(.server, error.message, batch, willRetry: true)
                        return finishFlush(retryAfter: error.retryAfter)
                    }
                    if status == 413 {
                        // The server answered, so the connection is healthy again.
                        consecutiveFailures = 0
                        if batch.count > 1 {
                            // Too large for the server: retry right away in
                            // smaller requests. Not a failure; nothing is reported.
                            batchLimit = max(1, batch.count / 2)
                            return sendNext()
                        }
                        store.removeFirst(1)
                        // Only that one event was too large; send the rest in
                        // full batches again.
                        batchLimit = maxEventsPerRequest
                        report(.validation, "Event is larger than the API accepts", batch)
                        return sendNext()
                    }
                    // Anything else (401/403, 404, 3xx, other 4xx, unexpected
                    // 2xx) is likely a configuration or deployment problem that
                    // will be fixed without an app update. Keep the events and
                    // retry rarely.
                    consecutiveFailures += 1
                    report(status == 401 || status == 403 ? .auth : .server, error.message, batch, willRetry: true)
                    finishFlush(retryAfter: Int(maxFlushDelay))
                case .failure(let error):
                    // Not expected from the transport; keep the events and
                    // back off.
                    consecutiveFailures += 1
                    report(.network, "Unexpected error: \(error)", batch, willRetry: true)
                    finishFlush(retryAfter: nil)
                }
            }
        }
    }

    /// Flutter's `finally` block of `_runFlush`.
    private func finishFlush(retryAfter: Int?) {
        if store.count == 0 { batchLimit = maxEventsPerRequest }
        let runAgain = flushRequested && consecutiveFailures == 0 && !disposing
        flushRequested = false
        let finished = runWaiters
        let latched = latchedWaiters
        runWaiters = []
        latchedWaiters = []
        if !disposing { scheduleTimer(retryAfterSeconds: retryAfter) }

        if runAgain {
            // Claim the follow-up run before anyone waiting on this one
            // resumes, so they see it in flight.
            runWaiters = latched
            finished.forEach { $0() }
            sendNext()
        } else {
            flushing = false
            (finished + latched).forEach { $0() }
            notifyIdle()
        }
    }

    private func whenIdle(_ work: @escaping () -> Void) {
        if flushing {
            idleWaiters.append(work)
        } else {
            work()
        }
    }

    private func notifyIdle() {
        while !flushing, !idleWaiters.isEmpty {
            idleWaiters.removeFirst()()
        }
    }

    private func scheduleTimer(retryAfterSeconds: Int? = nil) {
        timer?.cancel()
        let delay = nextFlushDelay(
            baseInterval: settings.flushInterval,
            consecutiveFailures: consecutiveFailures,
            retryAfterSeconds: retryAfterSeconds,
            random: random)
        timer = scheduler.schedule(after: delay) { [weak self] in
            guard let self, !self.disposing else { return }
            self.requestFlush()
        }
    }

    // MARK: Disposing

    /// Stops automatic flushing and sends what it can. Unsent events stay on
    /// disk for the next instance. After this is called, `track` and `flush`
    /// do nothing. Calling it again completes when the first call does.
    @objc(disposeWithCompletion:)
    public func dispose(completion: (() -> Void)?) {
        scheduler.async { [self] in
            afterLoad { [self] in
                beginDispose { [self] in deliver(completion) }
            }
        }
    }

    @nonobjc
    public func dispose() async {
        await withCheckedContinuation { continuation in
            dispose { continuation.resume() }
        }
    }

    private func beginDispose(_ done: @escaping () -> Void) {
        if disposed { return done() }
        disposeWaiters.append(done)
        guard !disposing else { return }
        disposing = true
        timer?.cancel()
        timer = nil
        lifecycle?.stop()
        whenIdle { [self] in
            requestFlush { [self] in
                whenIdle { [self] in
                    store.persist { [self] in
                        whenIdle { [self] in finishDispose() }
                    }
                }
            }
        }
    }

    private func finishDispose() {
        transport.close()
        Self.clearLive(self)
        disposed = true
        let waiters = disposeWaiters
        disposeWaiters = []
        waiters.forEach { $0() }
    }

    // MARK: Lifecycle

    /// Flutter's `_handleLifecycle`: reacts to an app lifecycle change, then
    /// calls `completion` once the work it started has settled. Called on
    /// `scheduler`, once the read of the stored backlog at launch has settled.
    private func handleLifecycle(_ state: AppLifecycleState, completion: @escaping () -> Void) {
        guard !disposing else { return completion() }
        switch state {
        case .paused:
            var pending = 2
            let settled = {
                pending -= 1
                if pending == 0 { completion() }
            }
            store.persist(settled)
            requestFlush(settled)
        case .resumed:
            consecutiveFailures = 0
            // persist() first: if storage was locked at launch (iOS before
            // first unlock), it retries reading the stored backlog so it gets
            // sent too.
            store.persist { [self] in
                if disposing { return completion() }
                requestFlush(completion)
            }
        case .terminating:
            store.persist(completion)
        }
    }

    // MARK: Callbacks

    private func deliver(_ completion: (() -> Void)?) {
        if let completion { deliverCallback(completion) }
    }

    private func report(
        _ type: MobyBeaconErrorType,
        _ message: String,
        _ events: [MobyBeaconEvent],
        errors: [EventBatchError]? = nil,
        willRetry: Bool = false
    ) {
        guard let onError = settings.onError else { return }
        let error = MobyBeaconError(type: type, message: message, events: events, errors: errors, willRetry: willRetry)
        deliverCallback { onError(error) }
    }
}
