import 'dart:math';

/// Upper bound on the computed delay between flush attempts.
const maxFlushDelay = Duration(minutes: 5);

/// Delay before the next timer-driven flush.
///
/// Healthy: [baseInterval]. After failures: [baseInterval] doubled per
/// consecutive failure, capped at [maxFlushDelay] (or at [baseInterval] if
/// that is longer), plus 0–25% jitter. A server `Retry-After` is used instead
/// of the computed delay, without jitter, clamped to the same range. Backoff
/// never retries sooner than a healthy flush would.
Duration nextFlushDelay({
  required Duration baseInterval,
  required int consecutiveFailures,
  int? retryAfterSeconds,
  Random? random,
}) {
  final ceiling = baseInterval > maxFlushDelay ? baseInterval : maxFlushDelay;

  if (retryAfterSeconds != null) {
    final delay =
        Duration(seconds: retryAfterSeconds.clamp(0, ceiling.inSeconds));
    return delay < baseInterval ? baseInterval : delay;
  }
  if (consecutiveFailures <= 0) return baseInterval;

  // Double step by step so the delay never overflows.
  var delay = baseInterval;
  for (var i = 0; i < consecutiveFailures && delay < ceiling; i++) {
    delay *= 2;
  }
  if (delay > ceiling) delay = ceiling;

  final jitter = 1 + (random ?? Random()).nextDouble() * 0.25;
  return delay * jitter;
}
