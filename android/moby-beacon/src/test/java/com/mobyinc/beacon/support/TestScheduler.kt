package com.mobyinc.beacon.support

import com.mobyinc.beacon.Cancellable
import com.mobyinc.beacon.Iso8601
import com.mobyinc.beacon.Scheduler
import com.mobyinc.beacon.SerialJobs

/**
 * Virtual-time [Scheduler], the stand-in for Dart's `fake_async` and the iOS
 * `TestScheduler`.
 *
 * Nothing runs until the test drives it: [runUntilIdle] in place of
 * `flushMicrotasks()`, [advanceBy] in place of `elapse()`. Sender jobs run in
 * the same FIFO as worker jobs, so a send completes synchronously, unless
 * [holdResponses] is set: then whatever a sender job posts back to the worker
 * (the send's result) is held until [releaseResponses], which models a request
 * that has been made but not yet answered. Single-threaded by design; drive it
 * from the test thread only.
 */
internal class TestScheduler(startMs: Long = START_MS) : Scheduler {
    private class Timer(val dueMs: Long, val seq: Int, val job: Runnable) : Cancellable {
        var cancelled = false

        override fun cancel() {
            cancelled = true
        }
    }

    var nowMs: Long = startMs
        private set

    private val work = ArrayDeque<Runnable>()
    private val timers = ArrayList<Timer>()
    private var nextSeq = 0
    private var inSenderJob = false
    private val heldResponses = ArrayDeque<Runnable>()

    /** While true, results posted back by sender jobs are held. */
    var holdResponses = false

    override val turns = SerialJobs()

    /** Timers scheduled and neither fired nor cancelled. */
    val pendingTimerCount: Int get() = timers.count { !it.cancelled }

    /** Posted work not yet run. */
    val pendingWorkCount: Int get() = work.size

    /** Send results waiting for [releaseResponses]. */
    val heldResponseCount: Int get() = heldResponses.size

    override fun currentTimeMillis(): Long = nowMs

    override fun post(job: Runnable) {
        if (inSenderJob && holdResponses) heldResponses.addLast(job) else work.addLast(job)
    }

    override fun schedule(delayMs: Long, job: Runnable): Cancellable {
        val timer = Timer(nowMs + delayMs, nextSeq++, job)
        timers.add(timer)
        return timer
    }

    override fun send(job: Runnable) {
        work.addLast(
            Runnable {
                inSenderJob = true
                try {
                    job.run()
                } finally {
                    inSenderJob = false
                }
            }
        )
    }

    /** Stops holding and queues every held result, in order, behind pending work. */
    fun releaseResponses() {
        holdResponses = false
        while (heldResponses.isNotEmpty()) work.addLast(heldResponses.removeFirst())
    }

    /**
     * Runs queued work FIFO, including work enqueued while running, until the
     * queue is empty.
     */
    fun runUntilIdle() {
        while (work.isNotEmpty()) work.removeFirst().run()
    }

    /**
     * Moves [nowMs] forward to each timer due within [deltaMs], in due order
     * (scheduling order on ties), firing it and then running until idle.
     * Timers scheduled meanwhile fire if they fall within the window. [nowMs]
     * ends at the start plus [deltaMs].
     */
    fun advanceBy(deltaMs: Long) {
        val end = nowMs + deltaMs
        runUntilIdle()
        while (true) {
            val timer = nextDueTimer(end) ?: break
            timers.remove(timer)
            nowMs = timer.dueMs
            timer.job.run()
            runUntilIdle()
        }
        nowMs = end
    }

    private fun nextDueTimer(notAfterMs: Long): Timer? {
        timers.removeAll { it.cancelled }
        val next = timers.minWithOrNull(compareBy({ it.dueMs }, { it.seq })) ?: return null
        return if (next.dueMs <= notAfterMs) next else null
    }

    companion object {
        /** 2026-10-07T12:00:00Z, the iOS harness's fixed "now". */
        val START_MS: Long = Iso8601.parse("2026-10-07T12:00:00.000Z")
    }
}
