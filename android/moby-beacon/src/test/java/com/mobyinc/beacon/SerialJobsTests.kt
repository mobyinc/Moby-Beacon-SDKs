package com.mobyinc.beacon

import org.junit.Assert.assertEquals
import org.junit.Test

/** The worker-confined queue that orders an instance's load behind the previous instance's dispose. */
class SerialJobsTests {
    @Test
    fun test_aJobThatFinishesAtOnceLetsTheNextStartAtOnce() {
        val jobs = SerialJobs()
        val log = ArrayList<String>()
        jobs.enqueue { done -> log.add("a"); done() }
        jobs.enqueue { done -> log.add("b"); done() }
        assertEquals(listOf("a", "b"), log)
    }

    @Test
    fun test_theNextJobWaitsUntilTheRunningOneCallsDone() {
        val jobs = SerialJobs()
        val log = ArrayList<String>()
        var finishFirst: (() -> Unit)? = null
        jobs.enqueue { done -> log.add("a"); finishFirst = done }
        jobs.enqueue { done -> log.add("b"); done() }
        jobs.enqueue { done -> log.add("c"); done() }
        assertEquals(listOf("a"), log)

        finishFirst!!()
        assertEquals(listOf("a", "b", "c"), log)
    }

    @Test
    fun test_callingDoneTwiceDoesNotStartTheNextJobTwice() {
        val jobs = SerialJobs()
        var starts = 0
        var finishFirst: (() -> Unit)? = null
        jobs.enqueue { done -> finishFirst = done }
        var finishSecond: (() -> Unit)? = null
        jobs.enqueue { done -> starts++; finishSecond = done }
        jobs.enqueue { done -> starts++; done() }

        finishFirst!!()
        assertEquals(1, starts)
        finishFirst!!()
        assertEquals("the second job is still running", 1, starts)

        finishSecond!!()
        assertEquals(2, starts)
    }

    @Test
    fun test_aJobEnqueuedAfterTheQueueDrainsStartsImmediately() {
        val jobs = SerialJobs()
        val log = ArrayList<String>()
        jobs.enqueue { done -> log.add("a"); done() }
        jobs.enqueue { done -> log.add("b"); done() }
        assertEquals(listOf("a", "b"), log)
    }

    @Test
    fun test_aJobMayEnqueueAnotherWhichRunsAfterIt() {
        val jobs = SerialJobs()
        val log = ArrayList<String>()
        jobs.enqueue { done ->
            log.add("outer")
            jobs.enqueue { inner -> log.add("inner"); inner() }
            log.add("outer-end")
            done()
        }
        assertEquals(listOf("outer", "outer-end", "inner"), log)
    }
}
