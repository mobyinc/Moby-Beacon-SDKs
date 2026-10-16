package com.mobyinc.beacon

import com.mobyinc.beacon.support.FakeLifecycleSource
import com.mobyinc.beacon.support.FixedRandom
import com.mobyinc.beacon.support.MemoryQueueStorage
import com.mobyinc.beacon.support.MockHttpClient
import com.mobyinc.beacon.support.accepted
import com.mobyinc.beacon.support.actionsOf
import com.mobyinc.beacon.support.eventsOf
import com.mobyinc.beacon.support.jsonToMap
import com.mobyinc.beacon.support.storedActions
import com.mobyinc.beacon.support.storedEvent
import com.mobyinc.beacon.support.v1
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.ConnectException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.TimeUnit

/**
 * Ports the `track`, `automatic flushing` and `flush and dispose` groups of
 * `moby_beacon_test.dart`, plus the Android-only `setUserId`. `track` hops
 * onto the scheduler, so tests run it until idle before asserting.
 */
class MobyBeaconTests : BeaconHarness() {
    // MARK: track

    @Test
    fun test_queuesAnEventWithTheDefaultUserIdAndAUTCTimestamp() {
        val beacon = start()
        beacon.track("screen", "view", mapOf("name" to "home"))
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(1, requests.size)
        assertEquals(1, requests[0].size)
        assertEquals(
            mapOf(
                "userId" to "user-1",
                "category" to "screen",
                "action" to "view",
                "timestamp" to "2026-10-07T12:00:00.000Z",
                "details" to mapOf("name" to "home"),
            ),
            jsonToMap(requests[0][0]),
        )
    }

    @Test
    fun test_replacesALoneSurrogateFromTruncatedText() {
        // Dart's 'I feel \u{1F600}'.substring(0, 8): the emoji cut after its
        // high surrogate.
        val truncated = "I feel \uD83D"
        val beacon = start()
        beacon.track("survey", "answer", mapOf("text" to truncated))
        beacon.flush()
        scheduler.runUntilIdle()

        assertTrue("$errors", errors.isEmpty())
        assertEquals(1, requests.size)
        assertEquals(mapOf("text" to "I feel �"), jsonToMap(requests[0][0].getJSONObject("details")))
        val body = client.requests[0].bodyText
        assertTrue(body, body.contains("I feel �"))
    }

    @Test
    fun test_appliesUserIdAndTimestampOverrides() {
        val beacon = start()
        beacon.track("screen", "view", null, "user-2", Iso8601.parse("2026-01-02T03:00:00.000Z"))
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(1, requests.size)
        assertEquals("user-2", requests[0][0].getString("userId"))
        assertEquals("2026-01-02T03:00:00.000Z", requests[0][0].getString("timestamp"))
    }

    @Test
    fun test_usesTheSchedulerClockForTheDefaultTimestamp() {
        val beacon = start()
        scheduler.advanceBy(1_500)
        beacon.track("screen", "view")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals("2026-10-07T12:00:01.500Z", requests[0][0].getString("timestamp"))
    }

    @Test
    fun test_reportsInvalidEventsInsteadOfThrowing() {
        val beacon = start()
        beacon.track("", "view")
        beacon.flush()
        scheduler.runUntilIdle()

        val error = singleError()
        assertEquals(MobyBeaconErrorType.VALIDATION, error.type)
        assertEquals("category is required and must be a non-empty string", error.message)
        assertFalse(error.willRetry)
        assertEquals(listOf(""), error.events.map { it.category })
        assertTrue(requests.isEmpty())
    }

    @Test
    fun test_reportsAFullQueueInsteadOfThrowing() {
        val beacon = start(maxQueueSize = 1)
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        scheduler.runUntilIdle()

        val error = singleError()
        assertEquals(MobyBeaconErrorType.VALIDATION, error.type)
        assertEquals("Queue is at capacity", error.message)
        assertEquals(listOf("b"), error.events.map { it.action })
    }

    @Test
    fun test_aThrowingOnErrorDoesNotBreakTracking() {
        var handled = 0
        val beacon = start(onError = MobyBeaconErrorHandler {
            handled++
            throw IllegalStateException("handler failed")
        })
        beacon.track("", "view") // Rejected on the caller's thread.
        beacon.track("screen", "view")
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals(1, handled)
        assertEquals(listOf("view"), sentActions(0))

        offline()
        beacon.track("screen", "later") // Reported from the worker.
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals(2, handled)
        assertEquals(2, requests.size)
        assertEquals(listOf("later"), storedActions(storage.contents))
    }

    /**
     * An `onError` that calls back into the beacon must neither deadlock nor
     * disturb delivery. Validation errors are reported on the caller's thread,
     * so the handler's event is queued before the one tracked next.
     */
    @Test
    fun test_anOnErrorThatTracksAndFlushesDoesNotBreakTracking() {
        var beacon: MobyBeacon? = null
        var handled = 0
        beacon = start(onError = MobyBeaconErrorHandler {
            handled++
            beacon!!.track("screen", "from-handler")
            beacon!!.flush()
        })
        beacon.track("", "view")
        beacon.track("screen", "view")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(1, handled)
        assertEquals(listOf("from-handler", "view"), requests.flatMap { actionsOf(it) })
    }

    @Test
    fun test_aMutableListChangedAfterTrackIsRejectedAsTracked() {
        val items = ArrayList<Any?>()
        items.add("x")
        var reportedItems: List<Any?>? = null
        val beacon = start(onError = MobyBeaconErrorHandler {
            errors.add(it)
            reportedItems = ArrayList(it.events[0].details?.get("items") as List<*>)
        })
        beacon.track("screen", "view", mapOf("items" to items))
        items.add("y")
        beacon.flush()
        scheduler.runUntilIdle()

        val error = singleError()
        assertEquals(MobyBeaconErrorType.VALIDATION, error.type)
        assertEquals(
            "details.items must be a string, number, boolean, or null — not a nested object or array",
            error.message,
        )
        assertEquals(listOf("x"), reportedItems)
        assertTrue(requests.isEmpty())
    }

    /** Review focus: the queued event holds a copy made before `track` returned. */
    @Test
    fun test_aDetailsMapChangedAfterTrackIsSentAsTracked() {
        val details = HashMap<String, Any?>()
        details["text"] = "before"
        val beacon = start()
        beacon.track("survey", "answer", details)
        details["text"] = "after"
        details["extra"] = 1
        beacon.flush()
        scheduler.runUntilIdle()

        assertTrue("$errors", errors.isEmpty())
        assertEquals(mapOf("text" to "before"), jsonToMap(requests[0][0].getJSONObject("details")))
    }

    @Test
    fun test_aNullDetailValueIsSentAsJsonNull() {
        val beacon = start()
        beacon.track("survey", "answer", mapOf("note" to null))
        beacon.flush()
        scheduler.runUntilIdle()

        assertTrue(client.requests[0].bodyText.contains("\"note\":null"))
        assertEquals(mapOf("note" to null), jsonToMap(requests[0][0].getJSONObject("details")))
    }

    @Test
    fun test_aNullDetailsKeyIsReportedNotThrown() {
        val hostile = HashMap<String?, Any?>()
        hostile[null] = 1
        val beacon = start()
        @Suppress("UNCHECKED_CAST")
        beacon.track("screen", "view", hostile as Map<String, Any?>)
        scheduler.runUntilIdle()

        val error = singleError()
        assertEquals(MobyBeaconErrorType.VALIDATION, error.type)
        assertTrue(error.events.isEmpty())
        assertTrue(requests.isEmpty())
    }

    @Test
    fun test_trackWithoutDetailsOmitsTheDetailsKey() {
        val beacon = start()
        beacon.track("screen", "view")
        beacon.flush()
        scheduler.runUntilIdle()

        assertFalse(requests[0][0].has("details"))
    }

    // MARK: setUserId (Android addition)

    @Test
    fun test_setUserIdAppliesToLaterEventsOnly() {
        val beacon = start()
        beacon.track("screen", "a")
        beacon.setUserId("user-2")
        beacon.track("screen", "b")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(listOf("a", "b"), sentActions(0))
        assertEquals(listOf("user-1", "user-2"), requests[0].map { it.getString("userId") })
        assertTrue("$errors", errors.isEmpty())
    }

    @Test
    fun test_setUserIdRejectsAnInvalidIdAndKeepsTheCurrentOne() {
        val beacon = start()
        beacon.setUserId("")
        beacon.setUserId("x".repeat(256))
        beacon.setUserId("a\u0000b")
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(
            listOf(
                "userId must not be empty",
                "userId must be at most 255 characters",
                "userId must not contain NUL characters",
            ),
            errors.map { it.message },
        )
        for (error in errors) {
            assertEquals(MobyBeaconErrorType.VALIDATION, error.type)
            assertFalse(error.willRetry)
            assertTrue(error.events.isEmpty())
        }
        assertEquals("user-1", requests[0][0].getString("userId"))
    }

    @Test
    fun test_setUserIdDoesNotOverrideAnExplicitUserId() {
        val beacon = start()
        beacon.setUserId("user-2")
        beacon.track("screen", "a", null, "user-3")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals("user-3", requests[0][0].getString("userId"))
    }

    @Test
    fun test_setUserIdSanitizesNothingButAcceptsTheLimit() {
        val beacon = start()
        beacon.setUserId("x".repeat(255))
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertTrue("$errors", errors.isEmpty())
        assertEquals(255, requests[0][0].getString("userId").length)
    }

    // MARK: automatic flushing

    @Test
    fun test_flushesWhenBatchSizeIsReached() {
        val beacon = start(batchSize = 3)
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        scheduler.runUntilIdle()
        assertTrue(requests.isEmpty())

        beacon.track("screen", "c")
        scheduler.runUntilIdle()
        assertEquals(listOf("a", "b", "c"), sentActions(0))
    }

    @Test
    fun test_flushesWhenTheTimerFires() {
        val beacon = start()
        beacon.track("screen", "a")
        scheduler.advanceBy(4_000)
        assertTrue(requests.isEmpty())

        scheduler.advanceBy(1_000)
        assertEquals(listOf("a"), sentActions(0))
    }

    @Test
    fun test_theTimerKeepsFiringAtTheIntervalWhileHealthy() {
        val beacon = start()
        scheduler.advanceBy(5_000)
        assertTrue(requests.isEmpty())

        beacon.track("screen", "a")
        scheduler.advanceBy(5_000)
        assertEquals(listOf("a"), sentActions(0))

        beacon.track("screen", "b")
        scheduler.advanceBy(5_000)
        assertEquals(listOf("b"), sentActions(1))
        assertEquals(1, scheduler.pendingTimerCount)
    }

    @Test
    fun test_aFlushOfAnEmptyQueueDoesNotBlockLaterFlushes() {
        val beacon = start()
        beacon.flush()
        scheduler.runUntilIdle()
        scheduler.advanceBy(5_000)
        assertTrue(requests.isEmpty())

        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals(listOf("a"), sentActions(0))
    }

    @Test
    fun test_sendsEventsPersistedByAPreviousInstanceOnStart() {
        storage = MemoryQueueStorage(v1(listOf(storedEvent("left-over"))))
        start()

        assertEquals(listOf("left-over"), sentActions(0))
        assertEquals(emptyList<String>(), storedActions(storage.contents))
    }

    @Test
    fun test_reportsAnUnreadablePersistedQueueOnStart() {
        storage = MemoryQueueStorage("{not json")
        start()

        val error = singleError()
        assertEquals(MobyBeaconErrorType.VALIDATION, error.type)
        assertEquals("Persisted event queue was unreadable and has been discarded", error.message)
        assertFalse(error.willRetry)
        assertTrue(error.events.isEmpty())
        assertTrue(storage.quarantined)
        assertTrue(requests.isEmpty())
    }

    /** Review focus: one stored entry with an unparseable timestamp. */
    @Test
    fun test_reportsAStoredEntryWithABadTimestampOnStartAndSendsTheRest() {
        val bad = storedEvent("bad").put("timestamp", "yesterday")
        storage = MemoryQueueStorage(v1(listOf(storedEvent("a"), bad, storedEvent("b"))))
        start()

        val error = singleError()
        assertEquals(MobyBeaconErrorType.VALIDATION, error.type)
        assertEquals("1 persisted event(s) were unreadable and have been discarded", error.message)
        assertEquals(listOf("a", "b"), sentActions(0))
        assertFalse(storage.quarantined)
        assertEquals(emptyList<String>(), storedActions(storage.contents))
    }

    @Test
    fun test_sendsALargeBacklogInBoundedRequestsInOrder() {
        val beacon = start(batchSize = 5000, maxQueueSize = 2500)
        for (i in 0 until 2500) {
            beacon.track("screen", "e$i")
        }
        beacon.flush()
        scheduler.runUntilIdle()

        val sent = requests
        assertEquals((0 until 2500).map { "e$it" }, sent.flatMap { actionsOf(it) })
        assertTrue(sent.size > 1)
        for (request in sent) {
            assertTrue(request.size <= MAX_EVENTS_PER_REQUEST)
        }
        for (bytes in requestBytes) {
            assertTrue("$bytes bytes", bytes <= MAX_REQUEST_BYTES + 64)
        }
        assertTrue("$errors", errors.isEmpty())
    }

    @Test
    fun test_fillsEachRequestUpToThe64KiBBound() {
        // Even the smallest event is ~90 bytes, so the byte bound always bites
        // before the 1000-event bound; each request must hold the longest
        // prefix that fits.
        val beacon = start(batchSize = 5000, maxQueueSize = 2200)
        for (i in 0 until 2200) {
            beacon.track("s", "e")
        }
        beacon.flush()
        scheduler.runUntilIdle()

        val sent = requests
        assertTrue(sent.size > 2)
        assertEquals(2200, sent.sumOf { it.size })
        val eventBytes = sent[0][0].toString().toByteArray(Charsets.UTF_8).size
        val wrapper = "{\"events\":[]}".length
        for ((i, bytes) in requestBytes.withIndex()) {
            assertTrue("request $i: $bytes bytes", bytes - wrapper <= MAX_REQUEST_BYTES)
            assertTrue("request $i could hold more", sent[i].size <= MAX_EVENTS_PER_REQUEST)
            if (i < sent.size - 1) {
                assertTrue("request $i is not full", bytes - wrapper + 1 + eventBytes > MAX_REQUEST_BYTES)
            }
        }
    }

    /** Review focus: `track` from another caller while a batch is in flight. */
    @Test
    fun test_aFlushRequestedMidFlightSendsEventsTrackedMeanwhile() {
        hold()
        val beacon = start()

        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        beacon.track("screen", "b")
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals(1, requests.size)
        assertEquals("b reached disk while a was in flight", listOf("a", "b"), storedActions(storage.contents))

        release()
        scheduler.runUntilIdle()
        assertEquals(listOf("a"), sentActions(0))
        assertEquals(listOf("b"), sentActions(1))
        assertEquals(2, requests.size)
        assertEquals(emptyList<String>(), storedActions(storage.contents))
    }

    @Test
    fun test_rapidTracksShareOneWrite() {
        val beacon = start(batchSize = 1000)
        for (i in 0 until 100) {
            beacon.track("screen", "e$i")
        }
        assertEquals(0, storage.writeCount)
        scheduler.runUntilIdle()

        assertEquals(1, storage.writeCount)
        assertEquals(100, storedActions(storage.contents).size)
    }

    // MARK: flush and dispose

    @Test
    fun test_disposeWaitsForAnInFlightSendThenSendsTheRest() {
        hold()
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        beacon.track("screen", "b")

        beacon.dispose()
        scheduler.runUntilIdle()
        assertEquals(1, requests.size)
        assertEquals(1, scheduler.heldResponseCount)

        release()
        scheduler.runUntilIdle()
        assertEquals(listOf("b"), sentActions(1))
        assertEquals(2, requests.size)
        assertEquals(emptyList<String>(), storedActions(storage.contents))
        assertEquals(0, scheduler.pendingTimerCount)
    }

    @Test
    fun test_disposeTwiceIsHarmless() {
        val beacon = start()
        beacon.track("screen", "a")
        beacon.dispose()
        beacon.dispose()
        scheduler.runUntilIdle()
        val writes = storage.writeCount

        beacon.dispose()
        scheduler.runUntilIdle()
        assertEquals(listOf("a"), sentActions(0))
        assertEquals(1, requests.size)
        assertEquals(writes, storage.writeCount)
    }

    @Test
    fun test_trackJustBeforeDisposeIsStillSent() {
        val beacon = start()
        beacon.track("screen", "a")
        beacon.dispose()
        beacon.track("screen", "b")
        scheduler.runUntilIdle()

        assertEquals(listOf("a"), sentActions(0))
        assertEquals(1, requests.size)
        assertEquals(emptyList<String>(), storedActions(storage.contents))
    }

    @Test
    fun test_flushDuringDisposeDoesNotStartAnotherSend() {
        offline()
        val beacon = start()
        beacon.track("screen", "a")

        beacon.dispose()
        scheduler.runUntilIdle()
        assertEquals(1, requests.size)

        beacon.flush()
        scheduler.runUntilIdle()
        scheduler.advanceBy(10 * 60 * 1000)
        assertEquals(1, requests.size)
        assertEquals(listOf("a"), storedActions(storage.contents))
    }

    @Test
    fun test_createThrowsWhileAnotherInstanceIsLive() {
        start()

        try {
            makeBeacon()
            fail("expected IllegalStateException")
        } catch (e: IllegalStateException) {
            assertTrue(e.message ?: "", (e.message ?: "").contains("already running"))
        }
    }

    /**
     * Review focus: `dispose()` immediately followed by `create()` with a new
     * user. The second instance's load waits behind the first's final persist,
     * and the live slot is free as soon as `dispose()` returns.
     */
    @Test
    fun test_createRightAfterDisposeLoadsAfterTheFinalPersist() {
        hold()
        val first = start()
        first.track("screen", "a")
        first.flush()
        scheduler.runUntilIdle()
        assertEquals(1, requests.size)

        first.dispose()
        // The second instance's only send fails, so its queue must survive on disk.
        respond = { if (client.requests.size >= 2) throw ConnectException("offline") else accepted() }
        val second = makeBeacon(userId = "user-2")
        disposeLater(second)
        second.track("screen", "b")
        scheduler.runUntilIdle()
        assertEquals("the first instance's send is still in flight", 1, requests.size)
        assertEquals("the second instance has not loaded yet", listOf("a"), storedActions(storage.contents))

        release()
        scheduler.runUntilIdle()
        assertEquals(listOf("a"), sentActions(0))
        assertEquals(listOf("b"), sentActions(1))
        assertEquals("user-2", requests[1][0].getString("userId"))
        assertEquals(2, requests.size)
        assertEquals("the first's final persist did not clobber the second's queue", listOf("b"), storedActions(storage.contents))
        assertEquals(MobyBeaconErrorType.NETWORK, singleError().type)
    }

    @Test
    fun test_disposeLeavesNoTimersBehind() {
        offline()
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals(1, scheduler.pendingTimerCount)

        beacon.dispose()
        scheduler.runUntilIdle()
        assertEquals(0, scheduler.pendingTimerCount)
        scheduler.advanceBy(10 * 60 * 1000)
        assertEquals(2, requests.size) // The dispose's final attempt, then nothing.
    }

    /**
     * Lifecycle changes that arrive after `dispose` (a callback already in
     * flight when the source was stopped) do nothing.
     */
    @Test
    fun test_lifecycleChangesAfterDisposeDoNothing() {
        offline()
        val lifecycle = FakeLifecycleSource()
        val beacon = start(lifecycle = lifecycle)
        beacon.track("screen", "a")
        beacon.dispose()
        scheduler.runUntilIdle()
        val sent = requests.size
        val writes = storage.writeCount
        // The failed send leaves "a" queued, so a persist or flush would act.
        assertEquals(listOf("a"), storedActions(storage.contents))

        lifecycle.emitStop()
        lifecycle.emitStart()
        scheduler.runUntilIdle()
        scheduler.advanceBy(10 * 60 * 1000)
        assertEquals(sent, requests.size)
        assertEquals(writes, storage.writeCount)
    }

    // MARK: Review focus — real threads

    /** A beacon on the real [Worker] threads over in-memory storage and [client]. */
    private fun startOnWorker(
        client: MockHttpClient,
        storage: MemoryQueueStorage = MemoryQueueStorage(),
        batchSize: Int = 10,
        maxQueueSize: Int = 100,
    ): MobyBeacon {
        val config = MobyBeaconConfig.Builder("https://beacon.test", "key-123", "user-1")
            .batchSize(batchSize)
            .maxQueueSize(maxQueueSize)
            .build()
        return MobyBeacon.start(
            config,
            EventStore(storage, maxQueueSize) { Worker.post(it) },
            client.transport(),
            Worker,
            null,
            FixedRandom(0.0),
        )
    }

    private fun await(what: String, timeoutMs: Long = 5_000, condition: () -> Boolean) {
        val end = System.currentTimeMillis() + timeoutMs
        while (!condition()) {
            if (System.currentTimeMillis() > end) fail("timed out waiting for $what")
            Thread.sleep(5)
        }
    }

    /** Waits until every job queued on the worker's serial queue, a dispose included, has finished. */
    private fun awaitWorkerTurns() {
        val settled = CountDownLatch(1)
        Worker.post {
            Worker.turns.enqueue { done ->
                settled.countDown()
                done()
            }
        }
        assertTrue("worker did not settle", settled.await(5, TimeUnit.SECONDS))
    }

    @Test
    fun test_concurrentTrackFromManyThreadsLosesNoEvents() {
        val client = MockHttpClient()
        client.handler = {
            Thread.sleep(5) // Keep sends in flight while other threads track.
            accepted()
        }
        val memory = MemoryQueueStorage()
        val beacon = startOnWorker(client, memory, batchSize = 50, maxQueueSize = 1000)
        try {
            val threads = (0 until 8).map { thread ->
                Thread {
                    for (index in 0 until 50) {
                        beacon.track("screen", "concurrent", mapOf("thread" to thread, "index" to index))
                    }
                }
            }
            threads.forEach { it.start() }
            threads.forEach { it.join() }
            beacon.flush()
            await("400 events to be sent") { client.requests.sumOf { eventsOf(it.body).size } == 400 }

            val keys = client.requests.flatMap { eventsOf(it.body) }.map {
                val details = it.getJSONObject("details")
                "${details.getInt("thread")}-${details.getInt("index")}"
            }
            assertEquals(400, keys.size)
            assertEquals("duplicate events", 400, keys.toSet().size)
            // A run that starts at batchSize keeps draining whatever arrives meanwhile.
            assertTrue(client.requests.size > 1)
            assertTrue(client.requests.all { eventsOf(it.body).size <= MAX_EVENTS_PER_REQUEST })
        } finally {
            beacon.dispose()
            awaitWorkerTurns()
        }
        assertEquals(emptyList<String>(), storedActions(memory.contents))
    }

    @Test
    fun test_onlyOneOfTwoConcurrentStartsSucceeds() {
        val barrier = CyclicBarrier(2)
        val started = java.util.Collections.synchronizedList(ArrayList<MobyBeacon>())
        val failures = java.util.Collections.synchronizedList(ArrayList<Throwable>())
        val threads = (0 until 2).map {
            Thread {
                barrier.await()
                try {
                    started.add(startOnWorker(MockHttpClient()))
                } catch (e: Throwable) {
                    failures.add(e)
                }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join(5_000) }

        try {
            assertEquals(1, started.size)
            assertEquals(1, failures.size)
            assertTrue(failures[0] is IllegalStateException)
            assertTrue(failures[0].message ?: "", (failures[0].message ?: "").contains("already running"))
        } finally {
            for (beacon in started) beacon.dispose()
            awaitWorkerTurns()
        }
    }

    @Test
    fun test_disposeOnTheWorkerFreesTheLiveSlotAtOnce() {
        val client = MockHttpClient()
        val first = startOnWorker(client)
        first.dispose()
        val second = startOnWorker(client)
        assertNotNull(second)
        second.dispose()
        awaitWorkerTurns()
        assertNull(client.requests.firstOrNull())
    }
}
