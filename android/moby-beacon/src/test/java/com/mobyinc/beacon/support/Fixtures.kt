package com.mobyinc.beacon.support

import com.mobyinc.beacon.Iso8601
import com.mobyinc.beacon.MobyBeaconEvent
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.fail

/** 2026-10-07T00:00:00Z, the timestamp of every [event]. */
val FIXTURE_TIMESTAMP_MS: Long = Iso8601.parse("2026-10-07T00:00:00.000Z")

/** A valid event with [action], timestamped 2026-10-07T00:00:00Z. */
fun event(
    action: String,
    details: Map<String, Any?>? = null,
    category: String = "test",
    userId: String = "user-1",
): MobyBeaconEvent = MobyBeaconEvent(userId, category, action, FIXTURE_TIMESTAMP_MS, details)

/** A stored event as it appears in a queue file written by an earlier run. */
fun storedEvent(action: String): JSONObject =
    JSONObject()
        .put("userId", "user-1")
        .put("category", "screen")
        .put("action", action)
        .put("timestamp", "2026-10-06T09:00:00.000Z")

/** Builds a version 1 queue file holding [events] (JSON objects or anything else). */
fun v1(events: List<Any?>): String =
    JSONObject().put("v", 1).put("events", JSONArray(events)).toString()

/** Actions of the events in a stored version 1 queue file. */
fun storedActions(contents: String?): List<String> {
    assertNotNull("no queue file", contents)
    val root = try {
        JSONObject(contents!!)
    } catch (e: Exception) {
        fail("not a queue file: $contents")
        throw e
    }
    assertEquals(1, root.optInt("v", -1))
    val events = root.optJSONArray("events") ?: run {
        fail("not a queue file: $contents")
        return emptyList()
    }
    return (0 until events.length()).map { events.getJSONObject(it).optString("action", "<missing action>") }
}

/** Actions of [events] as sent on the wire. */
fun actionsOf(events: List<JSONObject>): List<String> =
    events.map { it.optString("action", "<missing action>") }

/** The `events` array of a request body, or empty when the body is not one. */
fun eventsOf(body: ByteArray): List<JSONObject> {
    val root = try {
        JSONObject(String(body, Charsets.UTF_8))
    } catch (e: Exception) {
        return emptyList()
    }
    val events = root.optJSONArray("events") ?: return emptyList()
    return (0 until events.length()).map { events.getJSONObject(it) }
}

/** [json] as a plain map: `JSONObject.NULL` becomes null, nested objects become maps. */
fun jsonToMap(json: JSONObject): Map<String, Any?> {
    val map = LinkedHashMap<String, Any?>()
    for (key in json.keys()) {
        val value = json.get(key)
        map[key] = when (value) {
            JSONObject.NULL -> null
            is JSONObject -> jsonToMap(value)
            is JSONArray -> (0 until value.length()).map { value.get(it) }
            else -> value
        }
    }
    return map
}

/**
 * [json] rendered with keys sorted at every level, so two objects with the
 * same content compare equal as text whatever their insertion order.
 */
fun canonical(json: JSONObject): String {
    val sb = StringBuilder("{")
    for ((i, key) in json.keys().asSequence().sorted().withIndex()) {
        if (i > 0) sb.append(',')
        sb.append(JSONObject.quote(key)).append(':')
        sb.append(canonicalValue(json.get(key)))
    }
    return sb.append('}').toString()
}

private fun canonicalValue(value: Any?): String = when (value) {
    null, JSONObject.NULL -> "null"
    is JSONObject -> canonical(value)
    is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonicalValue(value.get(it)) }
    is String -> JSONObject.quote(value)
    else -> value.toString()
}

/** A string containing the given UTF-16 code units, lone surrogates included. */
fun utf16String(vararg units: Int): String {
    val chars = CharArray(units.size) { units[it].toChar() }
    return String(chars)
}
