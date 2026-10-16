package com.mobyinc.beacon

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL

internal class EventBatchResponse(
    val accepted: Int,
    val errors: List<EventBatchError>,
) {
    companion object {
        /** Throws [JSONException] when the body is not the expected shape. */
        fun fromJson(json: JSONObject): EventBatchResponse {
            val rawErrors = json.opt("errors")
            val errors = ArrayList<EventBatchError>()
            when (rawErrors) {
                null, JSONObject.NULL -> Unit
                is JSONArray -> {
                    for (i in 0 until rawErrors.length()) {
                        errors.add(EventBatchError.fromJson(rawErrors.getJSONObject(i)))
                    }
                }
                else -> throw JSONException("errors must be an array")
            }
            val accepted = (json.opt("accepted") as? Number)?.toInt() ?: 0
            return EventBatchResponse(accepted, errors)
        }
    }
}

internal class TransportError(
    message: String,
    /** HTTP status, or null when the request never got a response. */
    val statusCode: Int? = null,
    /** Seconds from the `Retry-After` header on a 429. */
    val retryAfterSeconds: Int? = null,
) : Exception(message) {
    override fun toString(): String = "TransportError($statusCode): $message"
}

/** Delivers one batch of events to the API. [Transport] is the HTTP implementation. */
internal fun interface EventTransport {
    /**
     * Returns the API response for 201, 207 and 422. Throws [TransportError]
     * for everything else. Blocking; called on the sender thread.
     */
    fun send(events: List<MobyBeaconEvent>): EventBatchResponse
}

/**
 * Sends event batches to `POST {endpoint}/events`. Synchronous and blocking;
 * call it only from a background thread.
 *
 * [open] turns the request URL into a connection; tests pass a factory that
 * answers from a script instead of the network.
 */
internal class Transport(
    endpoint: String,
    private val apiKey: String,
    private val timeoutMs: Int = 30_000,
    private val open: (String) -> HttpURLConnection = { URL(it).openConnection() as HttpURLConnection },
) : EventTransport {
    private val url = "$endpoint/events"

    override fun send(events: List<MobyBeaconEvent>): EventBatchResponse {
        val eventsJson = JSONArray()
        for (event in events) eventsJson.put(event.toJson())
        val body = JSONObject().put("events", eventsJson).toString().toByteArray(Charsets.UTF_8)

        var opened: HttpURLConnection? = null
        try {
            val connection: HttpURLConnection
            val status: Int
            try {
                connection = open(url)
                opened = connection
                connection.requestMethod = "POST"
                connection.instanceFollowRedirects = false
                connection.connectTimeout = timeoutMs
                connection.readTimeout = timeoutMs
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(body.size)
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setRequestProperty("X-API-Key", apiKey)
                connection.outputStream.use { it.write(body) }
                status = connection.responseCode
            } catch (e: SocketTimeoutException) {
                throw TransportError("Request timed out")
            } catch (e: IOException) {
                throw TransportError("Network error: $e")
            }

            if (status == 429) {
                throw TransportError(
                    "Rate limited",
                    429,
                    retryAfterSeconds(headersOf(connection)),
                )
            }
            if (status >= 500) {
                throw TransportError("Server error: $status", status)
            }
            if (status in 300..399) {
                throw TransportError(
                    "Unexpected redirect ($status); check the endpoint URL",
                    status,
                )
            }
            if (status == 201 || status == 207 || status == 422) {
                return try {
                    val stream = if (status >= 400) connection.errorStream else connection.inputStream
                    val text = stream?.use { String(it.readBytes(), Charsets.UTF_8) } ?: ""
                    EventBatchResponse.fromJson(JSONObject(text))
                } catch (e: Exception) {
                    // The server took the batch; an unreadable body carries no
                    // per-event errors to report.
                    EventBatchResponse(0, emptyList())
                }
            }
            throw TransportError("Client error: $status", status)
        } finally {
            opened?.disconnect()
        }
    }

    // The status line arrives under a null key; drop it.
    private fun headersOf(connection: HttpURLConnection): Map<String, List<String>?> {
        val headers = HashMap<String, List<String>?>()
        for ((name, values) in connection.headerFields) {
            if (name != null) headers[name] = values
        }
        return headers
    }
}

/**
 * Seconds to wait from `Retry-After`, or from the longest of the
 * `Retry-After-<name>` headers that NestJS named throttlers send instead.
 * Header names are matched case-insensitively.
 */
internal fun retryAfterSeconds(headers: Map<String, List<String>?>): Int? {
    var plain: Int? = null
    var longest: Int? = null
    for ((rawName, values) in headers) {
        val name = rawName.lowercase()
        val seconds = values?.firstOrNull()?.trim()?.toIntOrNull() ?: continue
        if (name == "retry-after") {
            if (plain == null) plain = seconds
        } else if (name.startsWith("retry-after-")) {
            if (longest == null || seconds > longest) longest = seconds
        }
    }
    return plain ?: longest
}
