@testable import MobyBeacon

/// `RandomSource` that always returns `value`, for deterministic jitter.
final class FixedRandom: RandomSource {
    private let value: Double

    init(_ value: Double) {
        self.value = value
    }

    func nextDouble() -> Double {
        value
    }
}
