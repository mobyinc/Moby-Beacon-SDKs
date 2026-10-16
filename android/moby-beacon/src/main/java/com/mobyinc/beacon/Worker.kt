package com.mobyinc.beacon

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/** Something that can be cancelled before it runs, such as a timer. */
internal fun interface Cancellable {
    fun cancel()
}

/**
 * Where a [MobyBeacon] runs its work. [Worker] is the production
 * implementation over two background threads; tests substitute a virtual-time
 * scheduler so the flush loop can be driven deterministically.
 */
internal interface Scheduler {
    /** Wall-clock time in epoch milliseconds, used to timestamp tracked events. */
    fun currentTimeMillis(): Long

    /** Runs [job] on the worker, after every job posted before it. */
    fun post(job: Runnable)

    /** Runs [job] on the worker once [delayMs] have passed. */
    fun schedule(delayMs: Long, job: Runnable): Cancellable

    /** Runs [job] on the sender, the thread for blocking HTTP requests. */
    fun send(job: Runnable)

    /**
     * Worker-confined. Orders the jobs that must not overlap even though they
     * span worker turns: an instance's load, and the previous instance's
     * final flush and persist, whose sends complete on later turns.
     */
    val turns: SerialJobs
}

/**
 * The background threads shared by all instances.
 *
 * [executor], "the worker", is the single thread that runs every queue
 * mutation, disk write, timer and lifecycle reaction, and every reaction to a
 * send's result. Nothing on it blocks for long.
 *
 * [sender] runs the blocking HTTP sends, one at a time, so a slow request (up
 * to 30 s to connect per route attempt plus 30 s to read) never holds up the
 * worker: events tracked meanwhile still reach disk within the usual
 * write-coalescing window. A flush run sends one batch at a time, so a send
 * rarely waits for another; it can only when a disposed instance's final
 * batch and the next instance's first batch are both pending.
 */
internal object Worker : Scheduler {
    val executor: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "moby-beacon").apply { isDaemon = true }
        }

    val sender: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "moby-beacon-send").apply { isDaemon = true }
        }

    override val turns = SerialJobs()

    override fun currentTimeMillis(): Long = System.currentTimeMillis()

    override fun post(job: Runnable) {
        executor.execute(job)
    }

    override fun schedule(delayMs: Long, job: Runnable): Cancellable {
        val future = executor.schedule(job, delayMs, TimeUnit.MILLISECONDS)
        return Cancellable { future.cancel(false) }
    }

    override fun send(job: Runnable) {
        sender.execute(job)
    }
}

/**
 * Runs jobs one at a time, in the order they were given. A job ends when it
 * calls the `done` it was handed, which may be on a later worker turn than
 * the one it started on; the next job starts right then. Calling `done`
 * twice does nothing.
 *
 * Not thread-safe: call only on the worker.
 */
internal class SerialJobs {
    private val waiting = ArrayDeque<(done: () -> Unit) -> Unit>()
    private var running = false

    fun enqueue(job: (done: () -> Unit) -> Unit) {
        if (running) {
            waiting.addLast(job)
            return
        }
        start(job)
    }

    private fun start(job: (done: () -> Unit) -> Unit) {
        running = true
        var finished = false
        job {
            if (!finished) {
                finished = true
                startNext()
            }
        }
    }

    private fun startNext() {
        val next = waiting.removeFirstOrNull()
        if (next == null) running = false else start(next)
    }
}
