import Foundation

/// Upper bound, in seconds, on the computed delay between flush attempts.
let maxFlushDelay: TimeInterval = 300

/// Delay before the next timer-driven flush.
///
/// Healthy: `baseInterval`. After failures: `baseInterval` doubled per
/// consecutive failure, capped at `maxFlushDelay` (or at `baseInterval` if
/// that is longer), plus 0-25% jitter. A server `Retry-After` is used instead
/// of the computed delay, without jitter, clamped to the same range. Backoff
/// never retries sooner than a healthy flush would.
func nextFlushDelay(
    baseInterval: TimeInterval,
    consecutiveFailures: Int,
    retryAfterSeconds: Int? = nil,
    random: RandomSource
) -> TimeInterval {
    let ceiling = max(baseInterval, maxFlushDelay)

    if let retryAfterSeconds {
        let clamped = min(max(Double(retryAfterSeconds), 0), ceiling.rounded(.down))
        return max(clamped, baseInterval)
    }
    if consecutiveFailures <= 0 { return baseInterval }

    // Double step by step so the delay never overflows.
    var delay = baseInterval
    var i = 0
    while i < consecutiveFailures && delay < ceiling {
        delay *= 2
        i += 1
    }
    if delay > ceiling { delay = ceiling }

    let jitter = 1 + random.nextDouble() * 0.25
    return delay * jitter
}
