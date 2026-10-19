package com.mobyinc.beacon

import com.mobyinc.beacon.support.TestScheduler
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** Pins the test doubles the beacon suites rely on, and the real [Worker] they stand in for. */
class TestSchedulerTests {
    private val startMs = TestScheduler.START_MS

    @Test
    fun test_runUntilIdleRunsWorkEnqueuedByWork() {
        val scheduler = TestScheduler()
        val log = ArrayList<String>()
        scheduler.post {
            log.add("a")
            scheduler.post { log.add("c") }
        }
        scheduler.post { log.add("b") }
        assertEquals(2, scheduler.pendingWorkCount)
        assertEquals(emptyList<String>(), log)

        scheduler.runUntilIdle()

        assertEquals(listOf("a", "b", "c"), log)
        assertEquals(0, scheduler.pendingWorkCount)
    }

    @Test
    fun test_advanceFiresTimersInDueOrderThenInsertionOrder() {
        val scheduler = TestScheduler()
        val log = ArrayList<String>()
        scheduler.schedule(3_000) { log.add("3-first") }
        scheduler.schedule(1_000) { log.add("1") }
        scheduler.schedule(3_000) { log.add("3-second") }
        scheduler.schedule(2_000) {
            log.add("2")
            scheduler.post { log.add("2-work") }
        }
        scheduler.schedule(4_000) { log.add("4") }
        assertEquals(5, scheduler.pendingTimerCount)

        scheduler.advanceBy(3_000)

        assertEquals(listOf("1", "2", "2-work", "3-first", "3-second"), log)
        assertEquals(1, scheduler.pendingTimerCount)
        assertEquals(startMs + 3_000, scheduler.nowMs)
    }

    @Test
    fun test_advanceMovesNowToEachTimerBeforeFiring() {
        val scheduler = TestScheduler()
        val seen = ArrayList<Long>()
        scheduler.schedule(5_000) { seen.add(scheduler.currentTimeMillis()) }
        scheduler.schedule(2_000) { seen.add(scheduler.currentTimeMillis()) }

        scheduler.advanceBy(10_000)

        assertEquals(listOf(startMs + 2_000, startMs + 5_000), seen)
        assertEquals(startMs + 10_000, scheduler.nowMs)
    }

    @Test
    fun test_cancelledTimerDoesNotFire() {
        val scheduler = TestScheduler()
        var fired = false
        val timer = scheduler.schedule(1_000) { fired = true }
        assertEquals(1, scheduler.pendingTimerCount)

        timer.cancel()

        assertEquals(0, scheduler.pendingTimerCount)
        scheduler.advanceBy(5_000)
        assertFalse(fired)
    }

    @Test
    fun test_timerScheduledDuringAdvanceFiresIfDueWithinTheSameAdvance() {
        val scheduler = TestScheduler()
        val log = ArrayList<String>()
        scheduler.schedule(1_000) {
            log.add("outer")
            scheduler.schedule(2_000) { log.add("inner-in-window") }
            scheduler.schedule(5_000) { log.add("inner-past-window") }
        }

        scheduler.advanceBy(3_000)

        assertEquals(listOf("outer", "inner-in-window"), log)
        assertEquals(1, scheduler.pendingTimerCount)

        scheduler.advanceBy(3_000)

        assertEquals(listOf("outer", "inner-in-window", "inner-past-window"), log)
        assertEquals(0, scheduler.pendingTimerCount)
    }

    @Test
    fun test_sendJobsRunInTheSameFifoAsWork() {
        val scheduler = TestScheduler()
        val log = ArrayList<String>()
        scheduler.post { log.add("work-1") }
        scheduler.send {
            log.add("send")
            scheduler.post { log.add("result") }
        }
        scheduler.post { log.add("work-2") }

        scheduler.runUntilIdle()

        assertEquals(listOf("work-1", "send", "work-2", "result"), log)
    }

    @Test
    fun test_heldResponsesAreDeliveredOnRelease() {
        val scheduler = TestScheduler()
        val log = ArrayList<String>()
        scheduler.holdResponses = true
        scheduler.send {
            log.add("send")
            scheduler.post { log.add("result") }
        }
        scheduler.post { log.add("other work") }
        scheduler.runUntilIdle()
        assertEquals(listOf("send", "other work"), log)
        assertEquals(1, scheduler.heldResponseCount)

        scheduler.releaseResponses()
        assertEquals(0, scheduler.heldResponseCount)
        assertFalse(scheduler.holdResponses)
        scheduler.runUntilIdle()
        assertEquals(listOf("send", "other work", "result"), log)

        // Later sends pass straight through.
        scheduler.send { scheduler.post { log.add("second result") } }
        scheduler.runUntilIdle()
        assertEquals(listOf("send", "other work", "result", "second result"), log)
    }

    @Test
    fun test_eachSchedulerHasItsOwnSerialQueue() {
        val a = TestScheduler()
        val b = TestScheduler()
        var done: (() -> Unit)? = null
        a.turns.enqueue { done = it }
        var ran = false
        b.turns.enqueue { ran = true; it() }
        assertTrue("b is not blocked by a", ran)
        done!!()
    }

    // The real threads

    @Test
    fun test_workerRunsJobsOnItsOwnThreads() {
        val names = java.util.Collections.synchronizedList(ArrayList<String>())
        val latch = CountDownLatch(3)
        Worker.post {
            names.add("post:" + Thread.currentThread().name)
            latch.countDown()
        }
        Worker.send {
            names.add("send:" + Thread.currentThread().name)
            latch.countDown()
        }
        Worker.schedule(10) {
            names.add("timer:" + Thread.currentThread().name)
            latch.countDown()
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS))

        assertTrue(names.toString(), names.contains("post:moby-beacon"))
        assertTrue(names.toString(), names.contains("send:moby-beacon-send"))
        assertTrue(names.toString(), names.contains("timer:moby-beacon"))
        assertTrue(Worker.currentTimeMillis() > 0)
    }

    @Test
    fun test_workerCancelsAScheduledJob() {
        val fired = CountDownLatch(1)
        val timer = Worker.schedule(50) { fired.countDown() }
        timer.cancel()
        assertFalse(fired.await(200, TimeUnit.MILLISECONDS))
    }
}
