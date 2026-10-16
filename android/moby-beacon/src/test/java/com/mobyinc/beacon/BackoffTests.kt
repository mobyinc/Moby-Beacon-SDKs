package com.mobyinc.beacon

import com.mobyinc.beacon.support.FixedRandom
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** With `FixedRandom(0.0)` a backoff after `n` failures is exactly `5 s × 2^n`, capped at 300 s. */
class BackoffTests {
    private val baseMs = 5_000L
    private val noJitter = FixedRandom(0.0)
    private val fullJitter = FixedRandom(1.0)

    @Test
    fun test_returnsTheBaseIntervalWhenHealthy() {
        assertEquals(baseMs, nextFlushDelayMs(baseMs, 0, random = noJitter))
    }

    @Test
    fun test_doublesPerConsecutiveFailure() {
        assertEquals(10_000L, nextFlushDelayMs(baseMs, 1, random = noJitter))
        assertEquals(40_000L, nextFlushDelayMs(baseMs, 3, random = noJitter))
    }

    @Test
    fun test_capsAtMaxFlushDelayBeforeJitter() {
        assertEquals(MAX_FLUSH_DELAY_MS, nextFlushDelayMs(baseMs, 30, random = noJitter))
    }

    @Test
    fun test_addsUpTo25PercentJitter() {
        assertEquals(12_500L, nextFlushDelayMs(baseMs, 1, random = fullJitter))
    }

    @Test
    fun test_usesRetryAfterAsIsWithoutJitter() {
        assertEquals(7_000L, nextFlushDelayMs(baseMs, 4, retryAfterSeconds = 7, random = fullJitter))
    }

    @Test
    fun test_capsRetryAfterAtMaxFlushDelay() {
        assertEquals(MAX_FLUSH_DELAY_MS, nextFlushDelayMs(baseMs, 1, retryAfterSeconds = 3600, random = noJitter))
    }

    @Test
    fun test_treatsNegativeFailureCountsAsHealthy() {
        assertEquals(baseMs, nextFlushDelayMs(baseMs, -1, random = noJitter))
    }

    @Test
    fun test_reachesTheCapExactlyWhereDoublingExceedsIt() {
        assertEquals(160_000L, nextFlushDelayMs(baseMs, 5, random = noJitter))
        assertEquals(MAX_FLUSH_DELAY_MS, nextFlushDelayMs(baseMs, 6, random = noJitter))
    }

    @Test
    fun test_jitterOnTheCappedDelayStaysWithin25Percent() {
        assertEquals(375_000L, nextFlushDelayMs(baseMs, 30, random = fullJitter))
    }

    @Test
    fun test_neverBacksOffBelowABaseIntervalLongerThanTheCap() {
        val longBaseMs = 600_000L
        assertEquals(longBaseMs, nextFlushDelayMs(longBaseMs, 3, random = noJitter))
        assertEquals(longBaseMs, nextFlushDelayMs(longBaseMs, 1, retryAfterSeconds = 3600, random = noJitter))
    }

    @Test
    fun test_floorsAZeroOrNegativeRetryAfterAtTheBaseInterval() {
        for (seconds in listOf(0, -3)) {
            assertEquals("$seconds", baseMs, nextFlushDelayMs(baseMs, 1, retryAfterSeconds = seconds, random = noJitter))
        }
    }

    @Test
    fun test_capsAnEnormousRetryAfterWithoutOverflowing() {
        assertEquals(300_000L, nextFlushDelayMs(baseMs, 1, retryAfterSeconds = Int.MAX_VALUE, random = noJitter))
    }

    @Test
    fun test_doesNotOverflowWithAnExtremeBaseInterval() {
        val hugeBaseMs = 1_000_000_000_000_000L
        assertEquals(hugeBaseMs, nextFlushDelayMs(hugeBaseMs, 1000, random = noJitter))
        assertEquals(hugeBaseMs, nextFlushDelayMs(hugeBaseMs, 1000, retryAfterSeconds = Int.MAX_VALUE, random = noJitter))
    }

    @Test
    fun test_usesTheRealRandomByDefaultWithinBounds() {
        repeat(20) {
            val delay = nextFlushDelayMs(baseMs, 1)
            assertTrue("jittered delay out of range: $delay", delay in 10_000L..12_500L)
        }
    }
}
