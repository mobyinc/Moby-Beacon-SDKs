package com.mobyinc.beacon

import android.content.Context
import java.io.File
import kotlin.random.Random

/** The API accepts at most this many events per request. */
internal const val MAX_EVENTS_PER_REQUEST = 1000

/**
 * Upper bound on the encoded events in one request. The API rejects JSON
 * bodies over 100 kB (Express's default), so this leaves headroom.
 */
internal const val MAX_REQUEST_BYTES = 64 * 1024

/**
 * Batches study events, persists them to disk, and sends them to a Moby
 * Beacon API. Create one instance per app with [create].
 *
 * All queue and disk work runs on one background thread, the worker. HTTP
 * requests run on a second thread, one at a time, and hand their result back
 * to the worker, so a slow request never delays writing tracked events to
 * disk. The [MobyBeaconConfig.onError] handler is called on the worker, or on
 * the caller's thread for events rejected by [track] or [setUserId]
 * validation. Exceptions the handler throws are ignored.
 */
class MobyBeacon private constructor(
    private val config: MobyBeaconConfig,
    private val store: EventStore,
    private val transport: EventTransport,
    private val scheduler: Scheduler,
    private val lifecycle: LifecycleSource?,
    private val random: Random,
) {
    // Read on caller, main and worker threads; written under the class lock.
    @Volatile private var disposing = false
    @Volatile private var defaultUserId: String = config.userId

    // Worker-confined.
    private var consecutiveFailures = 0
    /** Most events sent in one request. Lowered when the server answers 413. */
    private var batchLimit = MAX_EVENTS_PER_REQUEST
    private var timer: Cancellable? = null
    /**
     * A flush run is in progress: a batch is being sent on the sender, or its
     * result is on its way back to the worker. Mirrors the Flutter SDK's
     * `_inFlight`.
     */
    private var inFlight = false
    /**
     * A flush was requested while a run was in flight. The run that ends runs
     * again, if sends are healthy at that point. Mirrors `_flushRequested`.
     */
    private var flushRequested = false
    /** Runs on the worker when the in-flight run ends. Only [dispose] sets it. */
    private var onIdle: (() -> Unit)? = null
    /**
     * Set as the dispose job's first step. Jobs queued before it still run, so
     * events tracked just before [dispose] are sent or persisted; jobs that run
     * after it do nothing, since the next instance may already own the file.
     */
    private var disposed = false

    private val lifecycleListener = object : LifecycleListener {
        override fun onStart() {
            if (disposing) return
            scheduler.post {
                if (disposed) return@post
                consecutiveFailures = 0
                requestFlush()
            }
        }

        override fun onStop() {
            if (disposing) return
            scheduler.post {
                if (disposed) return@post
                store.persist()
                requestFlush()
            }
        }
    }

    init {
        store.onDiscarded = { report(MobyBeaconErrorType.VALIDATION, it, emptyList()) }
    }

    /**
     * Queues an event. Never throws for invalid event content; invalid events
     * and a full queue are reported through `onError`. Passing `null` for
     * [category] or [action] (possible from Java) is a programmer error and
     * throws [NullPointerException].
     *
     * @param category event category, such as `"screen"`.
     * @param action event action, such as `"view"`.
     * @param details optional flat key-value pairs, copied before this returns.
     * @param userId overrides the default user ID for this event only; `null`
     *   uses the configured ID (or the one set with [setUserId]).
     * @param timestampMs event time in epoch milliseconds; `null` means now. It
     *   is sent as a UTC ISO 8601 timestamp.
     */
    @JvmOverloads
    fun track(
        category: String,
        action: String,
        details: Map<String, Any?>? = null,
        userId: String? = null,
        timestampMs: Long? = null,
    ) {
        if (disposing) return

        // sanitizeEvent also copies details, so later changes by the caller
        // cannot alter the queued event. It can throw on hostile input (a null
        // key, or a map another thread is modifying); that is reported, not thrown.
        var sanitized: MobyBeaconEvent? = null
        val event = try {
            val candidate = sanitizeEvent(
                MobyBeaconEvent(
                    userId = userId ?: defaultUserId,
                    category = category,
                    action = action,
                    timestampMs = timestampMs ?: scheduler.currentTimeMillis(),
                    details = details,
                )
            )
            sanitized = candidate
            validateEvent(candidate)
            candidate
        } catch (e: RuntimeException) {
            report(MobyBeaconErrorType.VALIDATION, e.message ?: e.toString(), listOfNotNull(sanitized))
            return
        }

        scheduler.post {
            // Only an add that runs after the dispose job is dropped: the final
            // persist has run, and the next instance may already own the file.
            if (disposed) return@post
            try {
                store.add(event)
            } catch (e: IllegalStateException) {
                report(MobyBeaconErrorType.VALIDATION, e.message ?: "Queue is at capacity", listOf(event))
                return@post
            } catch (e: IllegalArgumentException) {
                report(MobyBeaconErrorType.VALIDATION, e.message ?: "Invalid event", listOf(event))
                return@post
            }
            // While backing off, leave retries to the timer so tracking cannot
            // bypass the backoff or a server's Retry-After.
            if (store.size >= config.batchSize && consecutiveFailures == 0) requestFlush()
        }
    }

    /**
     * Sets the user ID for later events tracked without an explicit userId.
     * An invalid ID is reported through `onError` and ignored.
     */
    fun setUserId(userId: String) {
        try {
            validateUserId(userId)
        } catch (e: IllegalArgumentException) {
            report(MobyBeaconErrorType.VALIDATION, e.message ?: "Invalid userId", emptyList())
            return
        }
        defaultUserId = userId
    }

    /**
     * Sends queued events in the background until the queue is empty or a send
     * fails transiently (events stay queued and are retried with backoff).
     * Does nothing once [dispose] has been called.
     */
    fun flush() {
        if (disposing) return
        scheduler.post { if (!disposed) requestFlush() }
    }

    /**
     * Stops automatic flushing and sends what it can in the background. Unsent
     * events stay on disk for the next instance, which may be created as soon
     * as this returns. After this is called, [track] and [flush] do nothing.
     */
    fun dispose() {
        synchronized(MobyBeacon) {
            if (disposing) return
            disposing = true
            // Posted under the lock, before `live` is cleared, so a create() on
            // another thread cannot queue its load ahead of this job.
            scheduler.post {
                disposed = true
                timer?.cancel()
                timer = null
                // Let the in-flight run end, send what is left, then save. The
                // next instance's load waits behind this on the serial queue,
                // so no write of this instance lands after that load.
                scheduler.turns.enqueue { done ->
                    whenIdle {
                        startRun()
                        whenIdle {
                            store.persist()
                            done()
                        }
                    }
                }
            }
            if (live === this) live = null
        }
        lifecycle?.stop()
    }

    private fun begin() {
        scheduler.post {
            scheduler.turns.enqueue { done ->
                // Loads even if dispose() ran first: its final flush and persist
                // are queued behind this and then cover the loaded events too.
                store.load()
                if (!disposed) {
                    scheduleTimer()
                    if (store.size > 0) requestFlush()
                }
                done()
            }
        }
        lifecycle?.start(lifecycleListener)
    }

    /**
     * Worker only. Starts a flush run, or asks for one more after the run in
     * flight (granted when it ends only if sends are healthy by then).
     */
    private fun requestFlush() {
        if (inFlight) {
            flushRequested = true
            return
        }
        startRun()
    }

    /**
     * Worker only. Starts a run: the queue is sent one batch at a time until it
     * is empty or a send fails. Each send happens on the sender and its result
     * comes back to the worker through [handleSendResult], so between the two
     * the worker is free to add events and write them to disk.
     */
    private fun startRun() {
        inFlight = true
        sendNextBatch()
    }

    /** Worker only. Sends the front of the queue, or ends the run if it is empty. */
    private fun sendNextBatch() {
        if (store.size == 0) {
            finishRun(null)
            return
        }
        val batch = store.peek(batchLimit, MAX_REQUEST_BYTES)
        scheduler.send {
            var response: EventBatchResponse? = null
            var failure: Throwable? = null
            try {
                response = transport.send(batch)
            } catch (t: Throwable) {
                // Every outcome must reach the worker, or the run would never end.
                failure = t
            }
            scheduler.post { handleSendResult(batch, response, failure) }
        }
    }

    /**
     * Worker only. Applies one send's outcome, then sends the next batch or
     * ends the run. Only the worker touches the queue, and only one run is in
     * flight, so [batch] is still the front of the queue: events added since
     * were appended behind it.
     */
    private fun handleSendResult(
        batch: List<MobyBeaconEvent>,
        response: EventBatchResponse?,
        failure: Throwable?,
    ) {
        if (failure == null) {
            store.removeFirst(batch.size)
            consecutiveFailures = 0
            val errors = response?.errors ?: emptyList()
            if (errors.isNotEmpty()) {
                report(
                    MobyBeaconErrorType.VALIDATION,
                    "${errors.size} event(s) rejected by server",
                    batch,
                    errors = errors,
                )
            }
            sendNextBatch()
            return
        }
        if (failure !is TransportError) {
            // Not expected from the transport; keep the events and back off.
            consecutiveFailures++
            report(
                MobyBeaconErrorType.NETWORK,
                "Unexpected error: $failure",
                batch,
                willRetry = true,
            )
            finishRun(null)
            return
        }
        val message = failure.message ?: failure.toString()
        val status = failure.statusCode
        if (status == null) {
            consecutiveFailures++
            report(MobyBeaconErrorType.NETWORK, message, batch, willRetry = true)
            finishRun(null)
            return
        }
        if (status == 408 || status == 429 || status >= 500) {
            consecutiveFailures++
            report(MobyBeaconErrorType.SERVER, message, batch, willRetry = true)
            finishRun(failure.retryAfterSeconds)
            return
        }
        if (status == 413) {
            // The server answered, so the connection is healthy again.
            consecutiveFailures = 0
            if (batch.size > 1) {
                // Too large for the server: retry right away in smaller
                // requests. Not a failure; nothing is reported.
                batchLimit = maxOf(1, batch.size / 2)
                sendNextBatch()
                return
            }
            store.removeFirst(1)
            // Only that one event was too large; send the rest in full
            // batches again.
            batchLimit = MAX_EVENTS_PER_REQUEST
            report(
                MobyBeaconErrorType.VALIDATION,
                "Event is larger than the API accepts",
                batch,
            )
            sendNextBatch()
            return
        }
        // Anything else (401/403, 404, 3xx, other 4xx, unexpected 2xx) is
        // likely a configuration or deployment problem that will be fixed
        // without an app update. Keep the events and retry rarely.
        consecutiveFailures++
        report(
            if (status == 401 || status == 403) MobyBeaconErrorType.AUTH
            else MobyBeaconErrorType.SERVER,
            message,
            batch,
            willRetry = true,
        )
        finishRun((MAX_FLUSH_DELAY_MS / 1000).toInt())
    }

    /**
     * Worker only. Ends the run: reschedules the timer and, if a flush was
     * requested meanwhile and sends are healthy, runs again right away.
     */
    private fun finishRun(retryAfterSeconds: Int?) {
        inFlight = false
        if (store.size == 0) batchLimit = MAX_EVENTS_PER_REQUEST
        // Don't bypass backoff: after a failure, leave the retry to the timer.
        val runAgain = flushRequested && consecutiveFailures == 0
        flushRequested = false
        if (!disposed) {
            scheduleTimer(retryAfterSeconds)
            if (runAgain) {
                startRun()
                return
            }
        }
        val continuation = onIdle
        onIdle = null
        continuation?.invoke()
    }

    /** Worker only. Runs [block] now, or when the in-flight run ends. */
    private fun whenIdle(block: () -> Unit) {
        if (inFlight) onIdle = block else block()
    }

    /** Worker only. Replaces the pending timer-driven flush. */
    private fun scheduleTimer(retryAfterSeconds: Int? = null) {
        timer?.cancel()
        timer = scheduler.schedule(
            nextFlushDelayMs(config.flushIntervalMs, consecutiveFailures, retryAfterSeconds, random),
        ) { if (!disposed) requestFlush() }
    }

    private fun report(
        type: MobyBeaconErrorType,
        message: String,
        events: List<MobyBeaconEvent>,
        errors: List<EventBatchError>? = null,
        willRetry: Boolean = false,
    ) {
        val onError = config.onError ?: return
        try {
            onError.onError(MobyBeaconError(type, message, events, errors, willRetry))
        } catch (t: Throwable) {
            // A failing error handler must not break event delivery.
        }
    }

    companion object {
        /**
         * The instance that has been created and not yet disposed. Two
         * instances would share, and overwrite, one queue file.
         */
        private var live: MobyBeacon? = null

        /**
         * Starts a client that loads any events left from a previous run in the
         * background, then starts sending. Returns immediately, though resolving
         * `noBackupFilesDir` may do a little disk I/O on the calling thread.
         * Throws [IllegalStateException] if another instance has not been disposed.
         */
        @JvmStatic
        fun create(context: Context, config: MobyBeaconConfig): MobyBeacon {
            synchronized(MobyBeacon) { checkNotLive() }
            val directory = File(context.applicationContext.noBackupFilesDir, "moby_beacon")
            val store = EventStore(FileQueueStorage(directory), config.maxQueueSize) { Worker.post(it) }
            return start(
                config,
                store,
                Transport(config.endpoint, config.apiKey),
                Worker,
                ProcessLifecycleSource(),
            )
        }

        /**
         * [create] over injected parts. Tests pass in-memory storage, a fake
         * transport, a virtual-time scheduler and a driven lifecycle source.
         */
        internal fun start(
            config: MobyBeaconConfig,
            store: EventStore,
            transport: EventTransport,
            scheduler: Scheduler,
            lifecycle: LifecycleSource?,
            random: Random = Random.Default,
        ): MobyBeacon {
            val beacon = synchronized(MobyBeacon) {
                checkNotLive()
                MobyBeacon(config, store, transport, scheduler, lifecycle, random)
                    .also { live = it }
            }
            beacon.begin()
            return beacon
        }

        /** Forgets the live instance so the next test can start one. */
        internal fun resetLiveForTesting() {
            synchronized(MobyBeacon) { live = null }
        }

        private fun checkNotLive() {
            check(live == null) {
                "A MobyBeacon is already running. Use one instance per app, " +
                    "or dispose() it before creating another."
            }
        }
    }
}
