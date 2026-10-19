package com.mobyinc.beacon.support

import com.mobyinc.beacon.LifecycleListener
import com.mobyinc.beacon.LifecycleSource
import org.junit.Assert.fail

/**
 * A [LifecycleSource] the test drives: [emitStart] and [emitStop] deliver a
 * change to the listener passed to [start], as Dart's `setLifecycle` does. It
 * keeps delivering after [stop], like a callback already in flight.
 */
internal class FakeLifecycleSource : LifecycleSource {
    private var listener: LifecycleListener? = null

    var stopped = false
        private set

    val started: Boolean get() = listener != null

    override fun start(listener: LifecycleListener) {
        this.listener = listener
    }

    override fun stop() {
        stopped = true
    }

    /** The app came to the foreground. */
    fun emitStart() {
        (listener ?: return fail("emitStart() before start")).onStart()
    }

    /** The app left the foreground. */
    fun emitStop() {
        (listener ?: return fail("emitStop() before start")).onStop()
    }
}
