package com.mobyinc.beacon

import kotlin.random.Random

/** Upper bound on the computed delay between flush attempts. */
internal const val MAX_FLUSH_DELAY_MS = 5 * 60 * 1000L

/**
 * Delay before the next timer-driven flush.
 *
 * Healthy: [baseIntervalMs]. After failures: [baseIntervalMs] doubled per
 * consecutive failure, capped at [MAX_FLUSH_DELAY_MS] (or at [baseIntervalMs]
 * if that is longer), plus 0-25% jitter. A server `Retry-After` is used
 * instead of the computed delay, without jitter, clamped to the same range.
 * Backoff never retries sooner than a healthy flush would.
 */
internal fun nextFlushDelayMs(
    baseIntervalMs: Long,
    consecutiveFailures: Int,
    retryAfterSeconds: Int? = null,
    random: Random = Random.Default,
): Long {
    val ceilingMs = maxOf(baseIntervalMs, MAX_FLUSH_DELAY_MS)

    if (retryAfterSeconds != null) {
        val maxSeconds = ceilingMs / 1000
        val seconds = retryAfterSeconds.toLong().coerceIn(0L, maxSeconds)
        return maxOf(seconds * 1000, baseIntervalMs)
    }
    if (consecutiveFailures <= 0) return baseIntervalMs

    // Double step by step so the delay never overflows.
    var delayMs = baseIntervalMs
    var i = 0
    while (i < consecutiveFailures && delayMs < ceilingMs) {
        delayMs *= 2
        i++
    }
    if (delayMs > ceilingMs) delayMs = ceilingMs

    val jitter = 1 + random.nextDouble() * 0.25
    return (delayMs * jitter).toLong()
}
