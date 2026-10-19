package com.mobyinc.beacon

import com.mobyinc.beacon.support.FixedRandom
import com.mobyinc.beacon.support.HttpResponse
import com.mobyinc.beacon.support.MemoryQueueStorage
import com.mobyinc.beacon.support.accepted
import com.mobyinc.beacon.support.actionsOf
import com.mobyinc.beacon.support.emptyResponse
import com.mobyinc.beacon.support.eventsOf
import com.mobyinc.beacon.support.jsonResponse
import com.mobyinc.beacon.support.storedActions
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.SocketTimeoutException

/** Transport whose send fails with something other than a [TransportError]. */
private class ThrowingTransport : EventTransport {
    var sends = 0

    override fun send(events: List<MobyBeaconEvent>): EventBatchResponse {
        sends++
        throw IllegalStateException("boom")
    }
}

/**
 * Port of the `failures`, `backoff` and `batching` groups of
 * `moby_beacon_test.dart`. With `FixedRandom(0.0)` a backoff after `n`
 * failures is exactly `5 s × 2^n`, capped at 300 s.
 */
class MobyBeaconFailureTests : BeaconHarness() {
    private fun perEventErrors(status: Int, vararg errors: Pair<Int, String>): HttpResponse {
        val array = JSONArray()
        for ((index, message) in errors) array.put(JSONObject().put("index", index).put("message", message))
        return jsonResponse(JSONObject().put("accepted", 1).put("errors", array), status)
    }

    // MARK: failures

    @Test
    fun test_networkFailureKeepsEventsAndBacksOffTheTimer() {
        offline()
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(MobyBeaconErrorType.NETWORK, singleError().type)
        assertTrue(singleError().willRetry)
        assertTrue(singleError().message.startsWith("Network error: "))
        assertEquals(1, requests.size)

        // Backoff after one failure is 10s, not the 5s interval.
        scheduler.advanceBy(5_000)
        assertEquals(1, requests.size)

        acceptAll()
        scheduler.advanceBy(5_000)
        assertEquals(2, requests.size)
        assertEquals(listOf("a"), sentActions(1))

        // Success resets the timer to the normal interval.
        beacon.track("screen", "b")
        scheduler.advanceBy(5_000)
        assertEquals(listOf("b"), sentActions(2))
    }

    @Test
    fun test_aTimeoutIsANetworkFailure() {
        respond = { throw SocketTimeoutException("Read timed out") }
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(MobyBeaconErrorType.NETWORK, singleError().type)
        assertEquals("Request timed out", singleError().message)
        assertTrue(singleError().willRetry)
        assertEquals(listOf("a"), storedActions(storage.contents))
    }

    @Test
    fun test_429WaitsForRetryAfterBeforeTheNextAttempt() {
        answer(429, mapOf("Retry-After" to "30"))
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(MobyBeaconErrorType.SERVER, singleError().type)
        assertEquals("Rate limited", singleError().message)
        assertTrue(singleError().willRetry)

        acceptAll()
        scheduler.advanceBy(29_000)
        assertEquals(1, requests.size)
        scheduler.advanceBy(1_000)
        assertEquals(2, requests.size)
    }

    @Test
    fun test_429UsesTheLongestNamedThrottlerHeader() {
        answer(429, mapOf("retry-after-ip-limit" to "20", "retry-after-key-limit" to "7"))
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        acceptAll()
        scheduler.advanceBy(19_000)
        assertEquals(1, requests.size)
        scheduler.advanceBy(1_000)
        assertEquals(2, requests.size)
    }

    @Test
    fun test_5xxKeepsEventsForRetry() {
        answer(503)
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(MobyBeaconErrorType.SERVER, singleError().type)
        assertEquals("Server error: 503", singleError().message)
        assertTrue(singleError().willRetry)
        assertEquals(listOf("a"), singleError().events.map { it.action })
        assertEquals(listOf("a"), storedActions(storage.contents))
    }

    @Test
    fun test_408KeepsEventsForRetryWithBackoff() {
        answer(408)
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(MobyBeaconErrorType.SERVER, singleError().type)
        assertTrue(singleError().willRetry)
        assertEquals(listOf("a"), singleError().events.map { it.action })

        acceptAll()
        scheduler.advanceBy(5_000)
        assertEquals("backed off to 10s", 1, requests.size)
        scheduler.advanceBy(5_000)
        assertEquals(listOf("a"), sentActions(1))
    }

    @Test
    fun test_207DropsTheBatchAndReportsPerEventErrors() {
        respond = { perEventErrors(207, 1 to "details must be a flat object") }
        val beacon = start()
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        beacon.flush()
        scheduler.runUntilIdle()

        val error = singleError()
        assertEquals(MobyBeaconErrorType.VALIDATION, error.type)
        assertEquals("1 event(s) rejected by server", error.message)
        assertFalse(error.willRetry)
        assertEquals(listOf("a", "b"), error.events.map { it.action })
        assertEquals(1, error.errors?.size)
        assertEquals(1, error.errors?.get(0)?.index)
        assertEquals("details must be a flat object", error.errors?.get(0)?.message)

        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals(1, requests.size)
        assertEquals(emptyList<String>(), storedActions(storage.contents))
    }

    @Test
    fun test_422DropsTheBatchAndReportsPerEventErrors() {
        respond = { perEventErrors(422, 0 to "category is required", 1 to "action is required") }
        val beacon = start()
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        beacon.flush()
        scheduler.runUntilIdle()

        val error = singleError()
        assertEquals(MobyBeaconErrorType.VALIDATION, error.type)
        assertEquals("2 event(s) rejected by server", error.message)
        assertEquals(listOf(0, 1), error.errors?.map { it.index })
        assertEquals(emptyList<String>(), storedActions(storage.contents))

        // A real answer: the failure count is zero, so the next track flushes on time.
        beacon.track("screen", "c")
        scheduler.advanceBy(5_000)
        assertEquals(listOf("c"), sentActions(1))
    }

    @Test
    fun test_anAcceptedResponseWithAnUnreadableBodyDropsTheBatchSilently() {
        respond = { HttpResponse(201, emptyMap(), "not json".toByteArray()) }
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertTrue("$errors", errors.isEmpty())
        assertEquals(1, requests.size)
        assertEquals(emptyList<String>(), storedActions(storage.contents))
    }

    @Test
    fun test_401KeepsEventsAndRetriesAtTheBackoffCeiling() {
        answer(401)
        val beacon = start(batchSize = 3)
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(MobyBeaconErrorType.AUTH, singleError().type)
        assertEquals("Client error: 401", singleError().message)
        assertTrue(singleError().willRetry)
        assertEquals(listOf("a"), singleError().events.map { it.action })

        // Tracking past batchSize does not retry early.
        beacon.track("screen", "b")
        beacon.track("screen", "c")
        scheduler.advanceBy(4 * 60 * 1000 + 59_000)
        assertEquals(1, requests.size)

        acceptAll() // The key works again.
        scheduler.advanceBy(1_000)
        assertEquals(2, requests.size)
        assertEquals(listOf("a", "b", "c"), sentActions(1))
        assertEquals(1, errors.size)
    }

    @Test
    fun test_403KeepsEventsAndReportsAnAuthError() {
        answer(403)
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(MobyBeaconErrorType.AUTH, singleError().type)
        assertTrue(singleError().willRetry)

        acceptAll()
        scheduler.advanceBy(5 * 60 * 1000)
        assertEquals(listOf("a"), sentActions(1))
    }

    @Test
    fun test_404KeepsEventsAndReportsAServerError() {
        answer(404)
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(MobyBeaconErrorType.SERVER, singleError().type)
        assertTrue(singleError().willRetry)
        assertEquals("Client error: 404", singleError().message)

        acceptAll()
        scheduler.advanceBy(5 * 60 * 1000)
        assertEquals(listOf("a"), sentActions(1))
    }

    /** Dart's `for (final status in [400, 200, 204])` loop, one test per status. */
    private fun assertUnexpectedStatusKeepsEventsAsAServerError(status: Int) {
        answer(status)
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals("status $status", MobyBeaconErrorType.SERVER, singleError().type)
        assertTrue("status $status", singleError().willRetry)
        assertEquals("status $status", "Client error: $status", singleError().message)
        assertEquals("status $status", listOf("a"), singleError().events.map { it.action })
        assertEquals("status $status", listOf("a"), storedActions(storage.contents))

        acceptAll()
        scheduler.advanceBy(5 * 60 * 1000)
        assertEquals("status $status", listOf("a"), sentActions(1))
    }

    @Test
    fun test_unexpectedStatus400KeepsEventsAsAServerError() {
        assertUnexpectedStatusKeepsEventsAsAServerError(400)
    }

    @Test
    fun test_unexpectedStatus200KeepsEventsAsAServerError() {
        assertUnexpectedStatusKeepsEventsAsAServerError(200)
    }

    @Test
    fun test_unexpectedStatus204KeepsEventsAsAServerError() {
        assertUnexpectedStatusKeepsEventsAsAServerError(204)
    }

    @Test
    fun test_aRedirectKeepsEventsAndPassesTheMessageThrough() {
        answer(301, mapOf("Location" to "https://elsewhere.test/events"))
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(MobyBeaconErrorType.SERVER, singleError().type)
        assertTrue(singleError().willRetry)
        assertTrue("$errors", singleError().message.contains("Unexpected redirect"))
        assertEquals(listOf("a"), singleError().events.map { it.action })
        assertEquals("the redirect was not followed", 1, client.requests.size)

        acceptAll()
        scheduler.advanceBy(5 * 60 * 1000)
        assertEquals(listOf("a"), sentActions(1))
    }

    @Test
    fun test_413ForAMultiEventBatchSplitsItAndDeliversEverything() {
        val delivered = ArrayList<String>()
        respond = { request ->
            val events = eventsOf(request.body)
            if (events.size > 3) {
                emptyResponse(413)
            } else {
                delivered.addAll(actionsOf(events))
                accepted()
            }
        }
        val beacon = start(batchSize = 100)
        for (i in 0 until 10) {
            beacon.track("screen", "e$i")
        }
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals((0 until 10).map { "e$it" }, delivered)
        assertTrue("$errors", errors.isEmpty())
        assertEquals(10, requests[0].size)
        for (request in requests.drop(1)) {
            assertTrue(request.size < 10)
        }
        assertEquals(emptyList<String>(), storedActions(storage.contents))
    }

    /** Review focus: 413 on a batch of one drops it, reports it, and the loop moves on. */
    @Test
    fun test_413ForASingleEventDropsItAndDeliversTheRest() {
        val delivered = ArrayList<String>()
        respond = { request ->
            val actions = actionsOf(eventsOf(request.body))
            if (actions.contains("big")) {
                emptyResponse(413)
            } else {
                delivered.addAll(actions)
                accepted()
            }
        }
        val beacon = start()
        beacon.track("screen", "a")
        beacon.track("screen", "big")
        beacon.track("screen", "c")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(listOf("a", "c"), delivered)
        val error = singleError()
        assertEquals(MobyBeaconErrorType.VALIDATION, error.type)
        assertEquals("Event is larger than the API accepts", error.message)
        assertFalse(error.willRetry)
        assertEquals(listOf("big"), error.events.map { it.action })
        assertEquals(emptyList<String>(), storedActions(storage.contents))

        val sent = requests.size
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals("nothing left to send", sent, requests.size)
    }

    @Test
    fun test_413OnABatchOfOneDoesNotSpinOrStopTheRun() {
        answer(413)
        val beacon = start()
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        beacon.flush()
        scheduler.runUntilIdle()

        // [a, b] -> 413 -> [a] -> 413 drop -> [b] -> 413 drop. Three requests, two errors.
        assertEquals(listOf(listOf("a", "b"), listOf("a"), listOf("b")), requests.map { actionsOf(it) })
        assertEquals(listOf("a", "b"), errors.map { it.events[0].action })
        assertTrue(errors.all { it.type == MobyBeaconErrorType.VALIDATION })
        assertEquals(emptyList<String>(), storedActions(storage.contents))
        assertEquals("healthy again: the timer is back at the base interval", 1, scheduler.pendingTimerCount)
    }

    // MARK: backoff

    @Test
    fun test_trackingPastBatchSizeWhileOfflineWaitsForTheBackoff() {
        offline()
        val beacon = start(batchSize = 3)
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        beacon.track("screen", "c")
        scheduler.runUntilIdle()
        assertEquals(1, requests.size)

        for (i in 0 until 50) {
            beacon.track("screen", "more$i")
            scheduler.advanceBy(100)
        }
        assertEquals("still inside the 10s backoff", 1, requests.size)

        scheduler.advanceBy(5_000)
        assertEquals("the backoff timer fired", 2, requests.size)
    }

    @Test
    fun test_trackingPastBatchSizeHonoursRetryAfter() {
        answer(429, mapOf("retry-after" to "60"))
        val beacon = start(batchSize = 3)
        beacon.track("screen", "a")
        beacon.track("screen", "b")
        beacon.track("screen", "c")
        scheduler.runUntilIdle()
        assertEquals(1, requests.size)

        for (i in 0 until 30) {
            beacon.track("screen", "more$i")
            scheduler.advanceBy(1_000)
        }
        assertEquals(1, requests.size)

        scheduler.advanceBy(30_000)
        assertEquals(2, requests.size)
    }

    @Test
    fun test_aServerAnswerAfterNetworkFailuresRestoresTheInterval() {
        offline()
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        scheduler.advanceBy(10_000)
        assertEquals("two network failures", 2, requests.size)

        // The server rejects the lone event as too large: a real answer.
        answer(413)
        scheduler.advanceBy(20_000)
        assertEquals(3, requests.size)
        assertEquals(MobyBeaconErrorType.VALIDATION, errors.last().type)

        acceptAll()
        beacon.track("screen", "b")
        scheduler.advanceBy(5_000)
        assertEquals(listOf("b"), sentActions(3))
    }

    @Test
    fun test_aLatchedFlushIsDiscardedAfterATransientFailure() {
        hold()
        answer(503)
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        beacon.track("screen", "b")
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals(1, requests.size)

        release()
        scheduler.runUntilIdle()
        assertEquals("the latched flush does not bypass the backoff", 1, requests.size)
        assertEquals(listOf("a", "b"), storedActions(storage.contents))
    }

    @Test
    fun test_aLatchedFlushRunsAgainAfterASuccess() {
        hold()
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        // Nothing new is tracked, but a flush was asked for mid-flight.
        beacon.flush()
        scheduler.runUntilIdle()

        release()
        scheduler.runUntilIdle()
        assertEquals("a follow-up run over an empty queue sends nothing", 1, requests.size)
        assertEquals(1, scheduler.pendingTimerCount)
    }

    @Test
    fun test_anUnexpectedExceptionIsTreatedAsANetworkFailure() {
        val transport = ThrowingTransport()
        val beacon = start(transport = transport)
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(1, transport.sends)
        assertEquals(MobyBeaconErrorType.NETWORK, singleError().type)
        assertTrue(singleError().willRetry)
        assertTrue(singleError().message, singleError().message.startsWith("Unexpected error: "))
        assertEquals(listOf("a"), singleError().events.map { it.action })

        scheduler.advanceBy(5_000)
        assertEquals("backed off to 10s", 1, transport.sends)
        scheduler.advanceBy(5_000)
        assertEquals("the event was kept", 2, transport.sends)
    }

    @Test
    fun test_backoffJitterComesFromTheInjectedRandom() {
        offline()
        val beacon = start(random = FixedRandom(1.0))
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()

        acceptAll()
        scheduler.advanceBy(12_499)
        assertEquals("10s doubled plus 25% jitter", 1, requests.size)
        scheduler.advanceBy(1)
        assertEquals(2, requests.size)
    }

    @Test
    fun test_consecutiveFailuresKeepDoublingUpToTheCeiling() {
        offline()
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals(1, requests.size)

        var expectedDelay = 10_000L
        for (attempt in 2..7) {
            scheduler.advanceBy(expectedDelay - 1)
            assertEquals("attempt $attempt waits $expectedDelay ms", attempt - 1, requests.size)
            scheduler.advanceBy(1)
            assertEquals(attempt, requests.size)
            expectedDelay = minOf(expectedDelay * 2, MAX_FLUSH_DELAY_MS)
        }
        assertEquals(MAX_FLUSH_DELAY_MS, expectedDelay)
    }

    // MARK: batching

    @Test
    fun test_theBatchSizeRecoversAfterA413OnceTheQueueDrains() {
        respond = { request -> if (eventsOf(request.body).size > 3) emptyResponse(413) else accepted() }
        val beacon = start(batchSize = 100)
        for (i in 0 until 10) {
            beacon.track("screen", "e$i")
        }
        beacon.flush()
        scheduler.runUntilIdle()
        assertTrue("$errors", errors.isEmpty())

        acceptAll()
        val before = requests.size
        for (i in 0 until 10) {
            beacon.track("screen", "f$i")
        }
        beacon.flush()
        scheduler.runUntilIdle()
        assertEquals(before + 1, requests.size)
        assertEquals(10, requests.last().size)
    }

    @Test
    fun test_theBatchSizeRecoversAfterDroppingAnOversizedEvent() {
        respond = { request ->
            if (actionsOf(eventsOf(request.body)).contains("big")) emptyResponse(413) else accepted()
        }
        val beacon = start(batchSize = 100)
        for (action in listOf("a", "big", "c", "d", "e")) {
            beacon.track("screen", action)
        }
        beacon.flush()
        scheduler.runUntilIdle()

        assertEquals(listOf("big"), singleError().events.map { it.action })
        assertEquals(listOf("c", "d", "e"), sentActions(requests.size - 1))
    }

    @Test
    fun test_eventsTrackedDuringAFailedRunStayQueuedInOrder() {
        hold()
        offline()
        val beacon = start()
        beacon.track("screen", "a")
        beacon.flush()
        scheduler.runUntilIdle()
        beacon.track("screen", "b")
        scheduler.runUntilIdle()

        release()
        scheduler.runUntilIdle()
        assertEquals(listOf("a", "b"), storedActions(storage.contents))

        acceptAll()
        scheduler.advanceBy(10_000)
        assertEquals(listOf("a", "b"), sentActions(1))
    }

    @Test
    fun test_aPersistedBacklogIsRetriedWithBackoffAfterAFailedStart() {
        offline()
        storage = MemoryQueueStorage(
            com.mobyinc.beacon.support.v1(listOf(com.mobyinc.beacon.support.storedEvent("stored")))
        )
        start()
        assertEquals(listOf("stored"), sentActions(0))
        assertEquals(MobyBeaconErrorType.NETWORK, singleError().type)

        acceptAll()
        scheduler.advanceBy(9_999)
        assertEquals(1, requests.size)
        scheduler.advanceBy(1)
        assertEquals(listOf("stored"), sentActions(1))
        assertEquals(emptyList<String>(), storedActions(storage.contents))
    }
}
