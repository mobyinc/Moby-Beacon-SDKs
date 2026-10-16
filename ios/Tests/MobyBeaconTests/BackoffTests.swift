import XCTest
@testable import MobyBeacon

final class BackoffTests: XCTestCase {
    private let base: TimeInterval = 5

    func test_returnsTheBaseIntervalWhenHealthy() {
        XCTAssertEqual(
            nextFlushDelay(baseInterval: base, consecutiveFailures: 0, random: FixedRandom(0)),
            base
        )
    }

    func test_doublesPerConsecutiveFailure() {
        let noJitter = FixedRandom(0)
        XCTAssertEqual(
            nextFlushDelay(baseInterval: base, consecutiveFailures: 1, random: noJitter),
            10, accuracy: 1e-9
        )
        XCTAssertEqual(
            nextFlushDelay(baseInterval: base, consecutiveFailures: 3, random: noJitter),
            40, accuracy: 1e-9
        )
    }

    func test_capsAtMaxFlushDelayBeforeJitter() {
        XCTAssertEqual(
            nextFlushDelay(baseInterval: base, consecutiveFailures: 30, random: FixedRandom(0)),
            maxFlushDelay, accuracy: 1e-9
        )
    }

    func test_addsUpTo25PercentJitter() {
        XCTAssertEqual(
            nextFlushDelay(baseInterval: base, consecutiveFailures: 1, random: FixedRandom(1)),
            12.5, accuracy: 1e-9
        )
    }

    func test_usesRetryAfterAsIsWithoutJitter() {
        XCTAssertEqual(
            nextFlushDelay(
                baseInterval: base,
                consecutiveFailures: 4,
                retryAfterSeconds: 7,
                random: FixedRandom(1)
            ),
            7, accuracy: 1e-9
        )
    }

    func test_capsRetryAfterAtMaxFlushDelay() {
        XCTAssertEqual(
            nextFlushDelay(
                baseInterval: base,
                consecutiveFailures: 1,
                retryAfterSeconds: 3600,
                random: FixedRandom(0)
            ),
            maxFlushDelay, accuracy: 1e-9
        )
    }

    func test_treatsNegativeFailureCountsAsHealthy() {
        XCTAssertEqual(
            nextFlushDelay(baseInterval: base, consecutiveFailures: -1, random: FixedRandom(0)),
            base
        )
    }

    func test_reachesTheCapExactlyWhereDoublingExceedsIt() {
        let noJitter = FixedRandom(0)
        XCTAssertEqual(
            nextFlushDelay(baseInterval: base, consecutiveFailures: 5, random: noJitter),
            160, accuracy: 1e-9
        )
        XCTAssertEqual(
            nextFlushDelay(baseInterval: base, consecutiveFailures: 6, random: noJitter),
            maxFlushDelay, accuracy: 1e-9
        )
    }

    func test_jitterOnTheCappedDelayStaysWithin25Percent() {
        XCTAssertEqual(
            nextFlushDelay(baseInterval: base, consecutiveFailures: 30, random: FixedRandom(1)),
            375, accuracy: 1e-9
        )
    }

    func test_neverBacksOffBelowABaseIntervalLongerThanTheCap() {
        let longBase: TimeInterval = 600
        XCTAssertEqual(
            nextFlushDelay(baseInterval: longBase, consecutiveFailures: 3, random: FixedRandom(0)),
            longBase, accuracy: 1e-9
        )
        XCTAssertEqual(
            nextFlushDelay(
                baseInterval: longBase,
                consecutiveFailures: 1,
                retryAfterSeconds: 3600,
                random: FixedRandom(0)
            ),
            longBase, accuracy: 1e-9
        )
    }

    func test_floorsAZeroOrNegativeRetryAfterAtTheBaseInterval() {
        for seconds in [0, -3] {
            XCTAssertEqual(
                nextFlushDelay(
                    baseInterval: base,
                    consecutiveFailures: 1,
                    retryAfterSeconds: seconds,
                    random: FixedRandom(0)
                ),
                base, accuracy: 1e-9, "\(seconds)"
            )
        }
    }

    func test_capsAnEnormousRetryAfterWithoutOverflowing() {
        XCTAssertEqual(
            nextFlushDelay(
                baseInterval: base,
                consecutiveFailures: 1,
                retryAfterSeconds: Int.max,
                random: FixedRandom(0)
            ),
            300, accuracy: 1e-9
        )
    }

    func test_doesNotOverflowWithAnExtremeBaseInterval() {
        let hugeBase: TimeInterval = 1e15
        let result = nextFlushDelay(
            baseInterval: hugeBase,
            consecutiveFailures: 1000,
            random: FixedRandom(0)
        )
        XCTAssertTrue(result.isFinite)
        XCTAssertEqual(result, hugeBase, accuracy: 1e-9)
    }
}
