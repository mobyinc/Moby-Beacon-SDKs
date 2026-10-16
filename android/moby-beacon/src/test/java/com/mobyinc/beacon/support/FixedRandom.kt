package com.mobyinc.beacon.support

import kotlin.random.Random

/** A [Random] whose [nextDouble] always returns [value], for deterministic jitter. */
class FixedRandom(private val value: Double) : Random() {
    override fun nextBits(bitCount: Int): Int = 0

    override fun nextDouble(): Double = value
}
