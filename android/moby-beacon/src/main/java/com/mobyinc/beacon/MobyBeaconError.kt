package com.mobyinc.beacon

/** The kind of problem a [MobyBeaconError] describes. */
enum class MobyBeaconErrorType {
    /** No response from the server (offline, DNS, TLS or timeout). Events are kept and retried. */
    NETWORK,

    /** The server answered with a retryable or unexpected status. Events are kept and retried. */
    SERVER,

    /** The server rejected the API key (HTTP 401 or 403). Events are kept and retried rarely. */
    AUTH,

    /** An event was invalid, dropped, or rejected by the server, or the queue file was unreadable. */
    VALIDATION,
}

/** Reported through [MobyBeaconConfig.onError]. */
class MobyBeaconError(
    val type: MobyBeaconErrorType,
    val message: String,
    /**
     * The events affected. For server validation errors this is the full sent
     * batch, so [errors] indexes line up with it.
     */
    val events: List<MobyBeaconEvent>,
    /** Per-event errors from a 207/422 response. */
    val errors: List<EventBatchError>? = null,
    /** True when [events] are still queued and will be retried. */
    val willRetry: Boolean = false,
) {
    override fun toString(): String = "MobyBeaconError($type): $message"
}

/** Called when events are rejected, dropped, or queued for retry. */
fun interface MobyBeaconErrorHandler {
    fun onError(error: MobyBeaconError)
}
