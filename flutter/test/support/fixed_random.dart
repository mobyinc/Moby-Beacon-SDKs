import 'dart:math';

/// [Random] whose `nextDouble` always returns [value], for deterministic
/// jitter.
class FixedRandom implements Random {
  FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
}
