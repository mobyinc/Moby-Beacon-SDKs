package com.mobyinc.beacon

/**
 * Settings for a [MobyBeacon] instance. Build one with [Builder]; the values
 * are validated when [Builder.build] is called.
 */
class MobyBeaconConfig private constructor(
    /** API base URL, without a trailing slash. Events are sent to `{endpoint}/events`. */
    val endpoint: String,
    /** Ingest API key, sent as the `X-API-Key` header. */
    val apiKey: String,
    /** Default user ID attached to every event. */
    val userId: String,
    /** Time between automatic flushes when sends are succeeding. */
    val flushIntervalMs: Long,
    /** Flush as soon as this many events are queued. */
    val batchSize: Int,
    /** Maximum number of events held on disk. New events are rejected when full. */
    val maxQueueSize: Int,
    /**
     * Called when events are rejected, dropped, or queued for retry (see
     * [MobyBeaconError.willRetry]). Exceptions it throws are ignored. Without
     * it, failures are silent.
     */
    val onError: MobyBeaconErrorHandler?,
) {
    /**
     * Collects the settings. [endpoint] is the API base URL, [apiKey] the ingest
     * key and [userId] the default user ID attached to events.
     */
    class Builder(
        private val endpoint: String,
        private val apiKey: String,
        private val userId: String,
    ) {
        private var flushInterval: Long = 5000
        private var batchSize: Int = 10
        private var maxQueueSize: Int = 10000
        private var errorHandler: MobyBeaconErrorHandler? = null

        /** Milliseconds between automatic flushes while sends succeed. Default 5000; must be positive. */
        fun flushIntervalMs(value: Long): Builder = apply { flushInterval = value }

        /** Flush as soon as this many events are queued, while sends are healthy. Default 10; at least 1. */
        fun batchSize(value: Int): Builder = apply { batchSize = value }

        /** Maximum events held on disk; new events are rejected when full. Default 10000; at least 1. */
        fun maxQueueSize(value: Int): Builder = apply { maxQueueSize = value }

        /** Sets the callback for rejected, dropped or retried events, or `null` for none (the default). */
        fun onError(handler: MobyBeaconErrorHandler?): Builder = apply { errorHandler = handler }

        /** Throws [IllegalArgumentException] when any setting is invalid. */
        fun build(): MobyBeaconConfig {
            val normalized = endpoint.replace(Regex("/+$"), "")
            require(isAbsoluteHttpUrl(normalized)) {
                "endpoint must be an absolute http(s) URL"
            }
            require(apiKey.isNotBlank()) { "apiKey must not be empty" }
            validateUserId(userId)
            require(flushInterval > 0) { "flushIntervalMs must be positive" }
            require(batchSize >= 1) { "batchSize must be at least 1" }
            require(maxQueueSize >= 1) { "maxQueueSize must be at least 1" }
            return MobyBeaconConfig(
                endpoint = normalized,
                apiKey = apiKey,
                userId = userId,
                flushIntervalMs = flushInterval,
                batchSize = batchSize,
                maxQueueSize = maxQueueSize,
                onError = errorHandler,
            )
        }
    }
}
