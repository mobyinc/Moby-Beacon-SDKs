package com.mobyinc.beacon

import com.mobyinc.beacon.support.HttpRequest
import com.mobyinc.beacon.support.HttpResponse
import com.mobyinc.beacon.support.MockHttpClient
import com.mobyinc.beacon.support.canonical
import com.mobyinc.beacon.support.emptyResponse
import com.mobyinc.beacon.support.event
import com.mobyinc.beacon.support.jsonResponse
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException

class TransportTests {
    private val events = listOf(event("view"))

    /** A transport over a mock client that answers with [respond]. */
    private fun makeTransport(
        timeoutMs: Int = 30_000,
        respond: (HttpRequest) -> HttpResponse,
    ): Pair<Transport, MockHttpClient> {
        val client = MockHttpClient()
        client.handler = respond
        return client.transport(timeoutMs = timeoutMs) to client
    }

    private fun accepted(): HttpResponse =
        jsonResponse(JSONObject().put("accepted", 1).put("errors", JSONArray()), 201)

    /** Sends [events] and returns the [TransportError] it failed with. */
    private fun sendFailure(transport: Transport): TransportError {
        try {
            val response = transport.send(events)
            fail("expected a failure, got accepted=${response.accepted}")
            throw AssertionError()
        } catch (e: TransportError) {
            return e
        }
    }

    private fun assertError(error: TransportError, message: String, status: Int?, retryAfter: Int? = null) {
        assertEquals(message, error.message)
        assertEquals(status, error.statusCode)
        assertEquals(retryAfter, error.retryAfterSeconds)
    }

    @Test
    fun test_postsEventsToEndpointEventsWithHeadersAndBody() {
        val (transport, client) = makeTransport { accepted() }

        transport.send(events)

        assertEquals(1, client.requests.size)
        val request = client.requests[0]
        assertEquals("https://beacon.test/events", request.url)
        assertEquals("POST", request.method)
        assertEquals("key-123", request.headers["X-API-Key"])
        assertEquals("application/json", request.headers["Content-Type"])
        val expected = JSONObject().put("events", JSONArray().put(events[0].toJson()))
        assertEquals(canonical(expected), canonical(JSONObject(request.bodyText)))
    }

    @Test
    fun test_configuresTheConnectionForABlockingPostWithoutRedirects() {
        var connection: HttpURLConnection? = null
        val client = MockHttpClient()
        val transport = Transport("https://beacon.test", "key-123", 12_345) { url ->
            client.open(url).also { connection = it }
        }

        transport.send(events)

        val opened = connection!!
        assertFalse(opened.instanceFollowRedirects)
        assertEquals(12_345, opened.connectTimeout)
        assertEquals(12_345, opened.readTimeout)
        assertTrue(opened.doOutput)
        assertEquals(1, client.disconnectCount)
    }

    @Test
    fun test_returnsTheResponseOn201() {
        val (transport, _) = makeTransport { accepted() }
        val response = transport.send(events)
        assertEquals(1, response.accepted)
        assertTrue(response.errors.isEmpty())
    }

    @Test
    fun test_returnsPerEventErrorsOn207And422() {
        for (status in listOf(207, 422)) {
            val (transport, _) = makeTransport {
                jsonResponse(
                    JSONObject().put("accepted", 0).put(
                        "errors",
                        JSONArray().put(JSONObject().put("index", 0).put("message", "category is required")),
                    ),
                    status,
                )
            }
            val response = transport.send(events)
            assertEquals("status $status", 0, response.accepted)
            assertEquals("status $status", 1, response.errors.size)
            assertEquals("status $status", 0, response.errors[0].index)
            assertEquals("status $status", "category is required", response.errors[0].message)
        }
    }

    @Test
    fun test_throwsWithStatusOn5xx() {
        val (transport, _) = makeTransport { emptyResponse(503) }
        assertError(sendFailure(transport), "Server error: 503", 503)
    }

    @Test
    fun test_throwsWithRetryAfterOn429() {
        val (transport, _) = makeTransport { emptyResponse(429, mapOf("Retry-After" to "12")) }
        assertError(sendFailure(transport), "Rate limited", 429, 12)
    }

    @Test
    fun test_readsNamedThrottlerRetryAfterHeadersOn429() {
        val (transport, _) = makeTransport {
            emptyResponse(429, mapOf("retry-after-ip-limit" to "37", "retry-after-key-limit" to "5"))
        }
        assertError(sendFailure(transport), "Rate limited", 429, 37)
    }

    @Test
    fun test_429WithoutAUsableRetryAfterHasNoRetryAfter() {
        val (transport, _) = makeTransport { emptyResponse(429, mapOf("retry-after" to "soon")) }
        assertError(sendFailure(transport), "Rate limited", 429, null)
    }

    @Test
    fun test_reportsARedirectDistinctly() {
        val (transport, _) = makeTransport { emptyResponse(301, mapOf("Location" to "https://elsewhere.test")) }
        assertError(sendFailure(transport), "Unexpected redirect (301); check the endpoint URL", 301)
    }

    @Test
    fun test_throwsWithStatusOn413SoTheCallerCanSplitTheBatch() {
        val (transport, _) = makeTransport { emptyResponse(413) }
        assertError(sendFailure(transport), "Client error: 413", 413)
    }

    @Test
    fun test_throwsWithStatusOn400401403() {
        for (status in listOf(400, 401, 403)) {
            val (transport, _) = makeTransport { emptyResponse(status) }
            assertError(sendFailure(transport), "Client error: $status", status)
        }
    }

    @Test
    fun test_treatsAnUnexpected2xxAsAClientError() {
        for (status in listOf(200, 204)) {
            val (transport, _) = makeTransport { emptyResponse(status) }
            assertError(sendFailure(transport), "Client error: $status", status)
        }
    }

    @Test
    fun test_throwsWithoutStatusWhenTheConnectionFails() {
        val failure = ConnectException("Connection refused")
        val (transport, _) = makeTransport { throw failure }
        assertError(sendFailure(transport), "Network error: $failure", null)
    }

    @Test
    fun test_throwsWithoutStatusOnTimeout() {
        val (transport, _) = makeTransport(timeoutMs = 10) { throw SocketTimeoutException("Read timed out") }
        assertError(sendFailure(transport), "Request timed out", null)
    }

    @Test
    fun test_acceptedResponseWithUnparsableBodyCountsAsAccepted() {
        val (transport, _) = makeTransport { HttpResponse(201, emptyMap(), "not json".toByteArray()) }
        val response = transport.send(events)
        assertEquals(0, response.accepted)
        assertTrue(response.errors.isEmpty())
    }

    @Test
    fun test_acceptedResponseWithAnEmptyBodyCountsAsAccepted() {
        val (transport, _) = makeTransport { emptyResponse(201) }
        val response = transport.send(events)
        assertEquals(0, response.accepted)
        assertTrue(response.errors.isEmpty())
    }

    @Test
    fun test_disconnectsAfterSuccessAndAfterFailure() {
        val (ok, okClient) = makeTransport { accepted() }
        ok.send(events)
        assertEquals(1, okClient.disconnectCount)

        val (failing, failingClient) = makeTransport { emptyResponse(500) }
        sendFailure(failing)
        assertEquals(1, failingClient.disconnectCount)

        val (broken, brokenClient) = makeTransport { throw ConnectException("refused") }
        sendFailure(broken)
        assertEquals(1, brokenClient.disconnectCount)
    }

    @Test
    fun test_anUnexpectedExceptionWhileReadingTheResponsePropagates() {
        val client = MockHttpClient()
        val transport = Transport("https://beacon.test", "key-123") {
            throw IllegalStateException("boom")
        }
        try {
            transport.send(events)
            fail("expected the exception to propagate")
        } catch (e: IllegalStateException) {
            assertEquals("boom", e.message)
        }
        assertEquals(0, client.requests.size)
    }

    // retryAfterSeconds

    @Test
    fun test_retryAfterSecondsIgnoresHTTPDates() {
        assertNull(retryAfterSeconds(mapOf("retry-after" to listOf("Wed, 21 Oct 2026 07:28:00 GMT"))))
    }

    @Test
    fun test_retryAfterSecondsMatchesHeaderNamesCaseInsensitively() {
        assertEquals(9, retryAfterSeconds(mapOf("Retry-After" to listOf(" 9 "))))
        assertEquals(4, retryAfterSeconds(mapOf("RETRY-AFTER-KEY-LIMIT" to listOf("4"))))
    }

    @Test
    fun test_retryAfterSecondsPrefersThePlainHeaderOverNamedOnes() {
        assertEquals(
            3,
            retryAfterSeconds(mapOf("retry-after" to listOf("3"), "retry-after-ip-limit" to listOf("60"))),
        )
    }

    @Test
    fun test_retryAfterSecondsSkipsNullAndEmptyHeaderValues() {
        assertNull(retryAfterSeconds(mapOf("retry-after" to null, "x" to listOf("1"))))
        assertNull(retryAfterSeconds(mapOf("retry-after" to emptyList())))
        assertNull(retryAfterSeconds(emptyMap()))
    }

    @Test
    fun test_eventBatchResponseFromJsonReadsAcceptedAndErrors() {
        val response = EventBatchResponse.fromJson(
            JSONObject().put("accepted", 2).put("errors", JSONArray().put(JSONObject().put("index", 1).put("message", "m")))
        )
        assertEquals(2, response.accepted)
        assertEquals(1, response.errors.size)
        assertEquals(1, response.errors[0].index)

        val bare = EventBatchResponse.fromJson(JSONObject())
        assertEquals(0, bare.accepted)
        assertTrue(bare.errors.isEmpty())
        assertTrue(EventBatchResponse.fromJson(JSONObject().put("errors", JSONObject.NULL)).errors.isEmpty())
    }

    @Test
    fun test_eventBatchResponseFromJsonRejectsNonArrayErrors() {
        try {
            EventBatchResponse.fromJson(JSONObject().put("errors", "nope"))
            fail("expected JSONException")
        } catch (e: org.json.JSONException) {
            assertEquals("errors must be an array", e.message)
        }
    }

    @Test
    fun test_transportErrorToStringNamesStatusAndMessage() {
        assertEquals("TransportError(503): Server error: 503", TransportError("Server error: 503", 503).toString())
        assertEquals("TransportError(null): Request timed out", TransportError("Request timed out").toString())
    }
}
