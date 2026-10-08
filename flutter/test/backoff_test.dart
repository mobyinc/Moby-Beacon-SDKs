import 'package:flutter_test/flutter_test.dart';
import 'package:moby_beacon/src/backoff.dart';

import 'support/fixed_random.dart';

void main() {
  const base = Duration(seconds: 5);

  test('returns the base interval when healthy', () {
    expect(nextFlushDelay(baseInterval: base, consecutiveFailures: 0), base);
  });

  test('doubles per consecutive failure', () {
    final noJitter = FixedRandom(0);
    expect(
      nextFlushDelay(
          baseInterval: base, consecutiveFailures: 1, random: noJitter),
      const Duration(seconds: 10),
    );
    expect(
      nextFlushDelay(
          baseInterval: base, consecutiveFailures: 3, random: noJitter),
      const Duration(seconds: 40),
    );
  });

  test('caps at maxFlushDelay before jitter', () {
    expect(
      nextFlushDelay(
          baseInterval: base, consecutiveFailures: 30, random: FixedRandom(0)),
      maxFlushDelay,
    );
  });

  test('adds up to 25% jitter', () {
    expect(
      nextFlushDelay(
          baseInterval: base, consecutiveFailures: 1, random: FixedRandom(1)),
      const Duration(milliseconds: 12500),
    );
  });

  test('uses Retry-After as-is without jitter', () {
    expect(
      nextFlushDelay(
        baseInterval: base,
        consecutiveFailures: 4,
        retryAfterSeconds: 7,
        random: FixedRandom(1),
      ),
      const Duration(seconds: 7),
    );
  });

  test('caps Retry-After at maxFlushDelay', () {
    expect(
      nextFlushDelay(
          baseInterval: base, consecutiveFailures: 1, retryAfterSeconds: 3600),
      maxFlushDelay,
    );
  });

  test('treats negative failure counts as healthy', () {
    expect(nextFlushDelay(baseInterval: base, consecutiveFailures: -1), base);
  });

  test('reaches the cap exactly where doubling exceeds it', () {
    final noJitter = FixedRandom(0);
    expect(
      nextFlushDelay(
          baseInterval: base, consecutiveFailures: 5, random: noJitter),
      const Duration(seconds: 160),
    );
    expect(
      nextFlushDelay(
          baseInterval: base, consecutiveFailures: 6, random: noJitter),
      maxFlushDelay,
    );
  });

  test('jitter on the capped delay stays within 25%', () {
    expect(
      nextFlushDelay(
          baseInterval: base, consecutiveFailures: 30, random: FixedRandom(1)),
      const Duration(seconds: 375),
    );
  });

  test('never backs off below a base interval longer than the cap', () {
    const longBase = Duration(minutes: 10);
    expect(
      nextFlushDelay(
          baseInterval: longBase,
          consecutiveFailures: 3,
          random: FixedRandom(0)),
      longBase,
    );
    expect(
      nextFlushDelay(
          baseInterval: longBase,
          consecutiveFailures: 1,
          retryAfterSeconds: 3600),
      longBase,
    );
  });

  test('floors a zero or negative Retry-After at the base interval', () {
    for (final seconds in [0, -3]) {
      expect(
        nextFlushDelay(
            baseInterval: base,
            consecutiveFailures: 1,
            retryAfterSeconds: seconds),
        base,
        reason: '$seconds',
      );
    }
  });

  test('caps an enormous Retry-After without overflowing', () {
    expect(
      nextFlushDelay(
          baseInterval: base,
          consecutiveFailures: 1,
          retryAfterSeconds: 1 << 62),
      maxFlushDelay,
    );
  });

  test('does not overflow with an extreme base interval', () {
    const hugeBase = Duration(days: 200);
    expect(
      nextFlushDelay(
          baseInterval: hugeBase,
          consecutiveFailures: 25,
          random: FixedRandom(0)),
      hugeBase,
    );
  });
}
