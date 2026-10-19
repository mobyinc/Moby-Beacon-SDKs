/// A source of uniformly distributed doubles, injectable so jitter is testable.
protocol RandomSource: AnyObject {
    /// A value in `[0, 1)`.
    func nextDouble() -> Double
}

/// `RandomSource` backed by the system random number generator.
final class SystemRandom: RandomSource {
    func nextDouble() -> Double {
        Double.random(in: 0..<1)
    }
}
