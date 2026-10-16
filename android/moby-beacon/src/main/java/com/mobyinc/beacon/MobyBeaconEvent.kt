package com.mobyinc.beacon

import org.json.JSONException
import org.json.JSONObject
import java.text.ParseException
import java.text.ParsePosition
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

/** A single study event, in the shape sent to `POST /events`. */
class MobyBeaconEvent(
    val userId: String,
    val category: String,
    val action: String,
    val timestampMs: Long,
    val details: Map<String, Any?>?,
) {
    internal fun toJson(): JSONObject {
        val json = JSONObject()
        json.put("userId", userId)
        json.put("category", category)
        json.put("action", action)
        json.put("timestamp", Iso8601.format(timestampMs))
        if (details != null) {
            val detailsJson = JSONObject()
            for ((key, value) in details) {
                detailsJson.put(key, value ?: JSONObject.NULL)
            }
            json.put("details", detailsJson)
        }
        return json
    }

    companion object {
        /**
         * Throws [JSONException] or [ParseException] when a field is missing or
         * malformed. `details` is optional.
         */
        internal fun fromJson(json: JSONObject): MobyBeaconEvent {
            val rawDetails = json.opt("details")
            val details: Map<String, Any?>? = when (rawDetails) {
                null, JSONObject.NULL -> null
                is JSONObject -> {
                    val map = LinkedHashMap<String, Any?>()
                    val keys = rawDetails.keys()
                    while (keys.hasNext()) {
                        val key = keys.next()
                        val value = rawDetails.get(key)
                        map[key] = if (value == JSONObject.NULL) null else value
                    }
                    map
                }
                else -> throw JSONException("details must be an object")
            }
            return MobyBeaconEvent(
                userId = json.requireString("userId"),
                category = json.requireString("category"),
                action = json.requireString("action"),
                timestampMs = Iso8601.parse(json.requireString("timestamp")),
                details = details,
            )
        }
    }
}

/** A per-event rejection returned by the API in a 207 or 422 response. */
class EventBatchError(
    /** Position of the rejected event in the sent batch. */
    val index: Int,
    val message: String,
) {
    companion object {
        internal fun fromJson(json: JSONObject): EventBatchError {
            val index = json.opt("index") as? Number
                ?: throw JSONException("index must be a number")
            return EventBatchError(index.toInt(), json.requireString("message"))
        }
    }
}

private fun JSONObject.requireString(key: String): String =
    opt(key) as? String ?: throw JSONException("$key must be a string")

/** UTC timestamps as `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`. */
internal object Iso8601 {
    private const val PATTERN = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"

    // SimpleDateFormat is not thread-safe, so every call gets its own.
    private fun newFormat(): SimpleDateFormat =
        SimpleDateFormat(PATTERN, Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
            isLenient = false
        }

    fun format(ms: Long): String = newFormat().format(ms)

    /** Throws [ParseException] on anything that is not exactly the pattern. */
    fun parse(text: String): Long {
        val position = ParsePosition(0)
        val date = newFormat().parse(text, position)
        if (date == null || position.index != text.length) {
            throw ParseException("Invalid timestamp: $text", maxOf(position.errorIndex, 0))
        }
        return date.time
    }
}
