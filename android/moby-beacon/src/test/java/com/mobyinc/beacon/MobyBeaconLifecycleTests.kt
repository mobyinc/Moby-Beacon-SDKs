package com.mobyinc.beacon

import com.mobyinc.beacon.support.FakeLifecycleSource
import com.mobyinc.beacon.support.MemoryQueueStorage
import com.mobyinc.beacon.support.storedActions
import com.mobyinc.beacon.support.storedEvent
import com.mobyinc.beacon.support.v1
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.IOException

/**
 * Ports the `lifecycle` group of `moby_beacon_test.dart`. Changes arrive
 * through [FakeLifecycleSource.emitStart] and [FakeLifecycleSource.emitStop],
 * Dart's `setLifecycle`. Android has only `ON_START` and `ON_STOP`: there is
 * no `hidden`, `inactive` or `detached` state.
 */
class MobyBeaconLifecycleTests : BeaconHarness() {
    private lateinit var lifecycle: FakeLifecycleSource

    @Before
    fun setUpLifecycle() {
        lifecycle = FakeLifecycleSource()
    }

    @Test
    fun test_onStopPersistsAndFlushes() {
        val beacon = start(lifecycle = lifecycle)
        beacon.track("screen", "a")
        lifecycle.emitStop()
        scheduler.runUntilIdle()

        assertEquals(listOf("a"), sentActions(0))
        assertEquals(emptyList<String>(), storedActions(storage.contents))
    }

    /** The persist half of Dart's "hidden persists and flushes": a failed coalesced write is retried. */
    @Test
    fun test_onStopPersistsEvenWhenTheEarlierWriteFailed() {
        offline()
        val beacon = start(lifecycle = lifecycle)
        // The write `track` starts fails, so only `persist` can store "a".
        storage.writeError = IOException("cannot write")
        beacon.track("screen", "a")
        scheduler.runUntilIdle()
        assertNull("the write track started failed", storage.contents)
        storage.writeError = null

        lifecycle.emitStop()
        scheduler.runUntilIdle()

        assertEquals(listOf("a"), storedActions(storage.contents))
        assertEquals("stop also flushes", 1, requests.size)
    }

    @Test
    fun test_onStartFlushesImmediatelyAndResetsBackoff() {
        offline()
        val beacon = start(lifecycle = lifecycle)
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals("two failures so far", 2, requests.size)

        lifecycle.emitStart()
        scheduler.runUntilIdle()
        assertEquals("start flushes immediately", 3, requests.size)

        // Reset to zero, then one failure: next attempt in 10s, not 40s.
        scheduler.advanceBy(10_000)
        assertEquals(4, requests.size)
    }

    @Test
    fun test_onStartWithAnEmptyQueueSendsNothing() {
        start(lifecycle = lifecycle)
        lifecycle.emitStart()
        scheduler.runUntilIdle()
        assertTrue(requests.isEmpty())
        assertEquals(1, scheduler.pendingTimerCount)
    }

    @Test
    fun test_aLifecycleChangeBeforeTheLoadRunsAfterIt() {
        storage = MemoryQueueStorage(v1(listOf(storedEvent("stored"))))
        val beacon = makeBeacon(lifecycle = lifecycle)
        disposeLater(beacon)
        lifecycle.emitStop()
        scheduler.runUntilIdle()

        assertEquals(listOf("stored"), sentActions(0))
        assertEquals(1, requests.size)
        assertEquals(emptyList<String>(), storedActions(storage.contents))
    }

    @Test
    fun test_disposeFlushesThenTrackAndFlushDoNothing() {
        val beacon = start(lifecycle = lifecycle)
        beacon.track("screen", "a")
        beacon.dispose()
        scheduler.runUntilIdle()
        assertEquals(listOf("a"), sentActions(0))

        beacon.track("screen", "b")
        beacon.flush()
        scheduler.runUntilIdle()
        scheduler.advanceBy(10 * 60 * 1000)
        assertEquals(1, requests.size)
        assertEquals("b was never queued", emptyList<String>(), storedActions(storage.contents))
    }

    @Test
    fun test_disposeKeepsUnsentEventsOnDisk() {
        offline()
        val beacon = start(lifecycle = lifecycle)
        beacon.track("screen", "a")
        beacon.dispose()
        scheduler.runUntilIdle()

        assertEquals(listOf("a"), storedActions(storage.contents))
    }

    @Test
    fun test_startRegistersAndDisposeStopsTheLifecycleSource() {
        val beacon = makeBeacon(lifecycle = lifecycle)
        disposeLater(beacon)
        assertTrue("registered before the first worker turn", lifecycle.started)
        assertFalse(lifecycle.stopped)

        beacon.dispose()
        assertTrue("stopped as soon as dispose returns", lifecycle.stopped)
    }

    @Test
    fun test_aBeaconWithoutALifecycleSourceStillWorks() {
        val beacon = start(lifecycle = null)
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals(listOf("a"), sentActions(0))
    }
}
