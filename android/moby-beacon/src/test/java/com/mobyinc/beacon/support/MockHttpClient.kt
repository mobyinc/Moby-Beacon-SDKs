package com.mobyinc.beacon.support

import com.mobyinc.beacon.Transport
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL

/** What the module sent, as the fake connection saw it. */
class HttpRequest(
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val body: ByteArray,
) {
    val bodyText: String get() = String(body, Charsets.UTF_8)
}

/** A scripted answer. Header names are matched case-insensitively by the module. */
class HttpResponse(
    val status: Int,
    val headers: Map<String, List<String>> = emptyMap(),
    val body: ByteArray = ByteArray(0),
)

/** A response carrying [body] encoded as JSON. */
fun jsonResponse(body: JSONObject, status: Int, headers: Map<String, String> = emptyMap()): HttpResponse =
    HttpResponse(status, headers.mapValues { listOf(it.value) }, body.toString().toByteArray(Charsets.UTF_8))

/** A response with an empty body. */
fun emptyResponse(status: Int, headers: Map<String, String> = emptyMap()): HttpResponse =
    HttpResponse(status, headers.mapValues { listOf(it.value) })

/** A 201 accepting the batch with no per-event errors. */
fun accepted(): HttpResponse =
    jsonResponse(JSONObject().put("accepted", 1).put("errors", JSONArray()), 201)

/**
 * Stands in for the network under [Transport]: [open] hands the transport a
 * connection whose response comes from [handler]. The default handler answers
 * 201 with an empty accepted batch. Requests are recorded in order.
 */
class MockHttpClient {
    var handler: (HttpRequest) -> HttpResponse = { accepted() }

    private val recorded = ArrayList<HttpRequest>()

    /** Every request made so far, in order. Safe to read from any thread. */
    val requests: List<HttpRequest> get() = synchronized(recorded) { ArrayList(recorded) }

    @Volatile var disconnectCount = 0
        private set

    /** The connection factory to pass to [Transport]. */
    fun open(url: String): HttpURLConnection = FakeHttpURLConnection(URL(url), this)

    /** A [Transport] over this client. */
    internal fun transport(
        endpoint: String = "https://beacon.test",
        apiKey: String = "key-123",
        timeoutMs: Int = 30_000,
    ): Transport = Transport(endpoint, apiKey, timeoutMs, ::open)

    internal fun record(request: HttpRequest) {
        synchronized(recorded) { recorded.add(request) }
    }

    internal fun disconnected() {
        disconnectCount++
    }
}

/**
 * An [HttpURLConnection] that never touches a socket. The request is captured
 * when the module asks for the response code, and the scripted response is
 * served from then on. Reading the input stream of an error status throws, as
 * the real class does, so the module has to use the error stream for 422.
 */
class FakeHttpURLConnection(url: URL, private val client: MockHttpClient) : HttpURLConnection(url) {
    private val body = ByteArrayOutputStream()
    private var response: HttpResponse? = null

    var disconnected = false
        private set

    override fun connect() {}

    override fun disconnect() {
        disconnected = true
        client.disconnected()
    }

    override fun usingProxy(): Boolean = false

    override fun getOutputStream(): OutputStream = body

    private fun response(): HttpResponse {
        response?.let { return it }
        val headers = LinkedHashMap<String, String>()
        for ((name, values) in requestProperties) {
            if (name != null) headers[name] = values?.firstOrNull() ?: ""
        }
        val request = HttpRequest(url.toString(), requestMethod, headers, body.toByteArray())
        client.record(request)
        return client.handler(request).also { response = it }
    }

    override fun getResponseCode(): Int = response().status

    override fun getHeaderFields(): Map<String?, List<String>> {
        val answered = response()
        val fields = HashMap<String?, List<String>>()
        // The real class files the status line under a null name.
        fields[null] = listOf("HTTP/1.1 ${answered.status}")
        fields.putAll(answered.headers)
        return fields
    }

    override fun getInputStream(): InputStream {
        val answered = response()
        if (answered.status >= 400) {
            throw IOException("Server returned HTTP response code: ${answered.status} for URL: $url")
        }
        return ByteArrayInputStream(answered.body)
    }

    override fun getErrorStream(): InputStream? {
        val answered = response ?: return null
        return if (answered.status >= 400) ByteArrayInputStream(answered.body) else null
    }
}
