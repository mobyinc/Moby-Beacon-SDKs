package com.mobyinc.beacon

import com.mobyinc.beacon.support.canonical
import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.text.ParseException

class EventTests {
    private fun ms(text: String): Long = Iso8601.parse(text)

    @Test
    fun test_toJsonSerializesTimestampAsUTCISO8601() {
        val event = MobyBeaconEvent("user-1", "screen", "view", ms("2026-10-07T12:00:00.000Z"), null)
        val json = event.toJson()
        assertEquals("2026-10-07T12:00:00.000Z", json.getString("timestamp"))
        assertFalse(json.has("details"))
        assertEquals(setOf("userId", "category", "action", "timestamp"), json.keys().asSequence().toSet())
    }

    @Test
    fun test_toJsonIncludesDetailsWhenPresent() {
        val event = MobyBeaconEvent(
            "user-1", "survey", "answer", ms("2026-10-07T00:00:00.000Z"),
            mapOf("question" to 3, "value" to "agree"),
        )
        val details = event.toJson().getJSONObject("details")
        assertEquals(3, details.getInt("question"))
        assertEquals("agree", details.getString("value"))
        assertEquals(2, details.length())
    }

    @Test
    fun test_toJsonWritesNullDetailValuesAsJsonNull() {
        val event = MobyBeaconEvent("u", "c", "a", ms("2026-10-07T00:00:00.000Z"), mapOf("note" to null))
        val details = event.toJson().getJSONObject("details")
        assertTrue(details.has("note"))
        assertTrue(details.isNull("note"))
        assertTrue(canonical(event.toJson()).contains("\"note\":null"))
    }

    @Test
    fun test_fromJsonRoundTripsToJson() {
        val event = MobyBeaconEvent(
            "user-1", "survey", "answer", ms("2026-10-07T08:00:00.000Z"),
            mapOf("question" to 3, "skipped" to false, "note" to null),
        )
        val restored = MobyBeaconEvent.fromJson(JSONObject(event.toJson().toString()))
        assertEquals("user-1", restored.userId)
        assertEquals("survey", restored.category)
        assertEquals("answer", restored.action)
        assertEquals(event.timestampMs, restored.timestampMs)
        assertEquals(3, restored.details?.get("question"))
        assertEquals(false, restored.details?.get("skipped"))
        assertTrue(restored.details!!.containsKey("note"))
        assertNull(restored.details!!["note"])
        assertEquals(canonical(event.toJson()), canonical(restored.toJson()))
    }

    @Test
    fun test_eventBatchErrorFromJsonReadsIndexAndMessage() {
        val error = EventBatchError.fromJson(JSONObject().put("index", 2).put("message", "bad"))
        assertEquals(2, error.index)
        assertEquals("bad", error.message)
    }

    @Test
    fun test_eventBatchErrorFromJsonThrowsWhenAFieldIsMissingOrMistyped() {
        for (json in listOf(
            JSONObject().put("index", 2),
            JSONObject().put("message", "bad"),
            JSONObject().put("index", "two").put("message", "bad"),
            JSONObject().put("index", 2).put("message", 5),
        )) {
            try {
                EventBatchError.fromJson(json)
                fail("expected JSONException for $json")
            } catch (e: JSONException) {
                // Expected.
            }
        }
    }

    @Test
    fun test_fromJsonProducesACopyOfDetails() {
        val source = JSONObject().put("question", 3)
        val event = MobyBeaconEvent.fromJson(
            JSONObject()
                .put("userId", "user-1").put("category", "survey").put("action", "answer")
                .put("timestamp", "2026-10-07T08:00:00.000Z").put("details", source)
        )
        source.put("question", 4)
        source.put("extra", 1)
        assertEquals(3, event.details?.get("question"))
        assertEquals(1, event.details?.size)
    }

    private fun full(): JSONObject = JSONObject()
        .put("userId", "u").put("category", "c").put("action", "a")
        .put("timestamp", "2026-10-07T08:00:00.000Z")

    @Test
    fun test_fromJsonThrowsWhenARequiredKeyIsMissingOrNotAString() {
        MobyBeaconEvent.fromJson(full())
        for (key in listOf("userId", "category", "action", "timestamp")) {
            val missing = full()
            missing.remove(key)
            try {
                MobyBeaconEvent.fromJson(missing)
                fail("missing $key")
            } catch (e: JSONException) {
                assertEquals("$key must be a string", e.message)
            }
            val mistyped = full().put(key, 5)
            try {
                MobyBeaconEvent.fromJson(mistyped)
                fail("non-string $key")
            } catch (e: JSONException) {
                assertEquals("$key must be a string", e.message)
            }
        }
    }

    @Test
    fun test_fromJsonThrowsParseExceptionOnABadTimestamp() {
        try {
            MobyBeaconEvent.fromJson(full().put("timestamp", "not a date"))
            fail("expected ParseException")
        } catch (e: ParseException) {
            assertEquals("Invalid timestamp: not a date", e.message)
        }
    }

    @Test
    fun test_fromJsonRejectsNonObjectDetailsAndAcceptsNullDetails() {
        try {
            MobyBeaconEvent.fromJson(full().put("details", "oops"))
            fail("expected JSONException")
        } catch (e: JSONException) {
            assertEquals("details must be an object", e.message)
        }
        assertNull(MobyBeaconEvent.fromJson(full().put("details", JSONObject.NULL)).details)
        assertNull(MobyBeaconEvent.fromJson(full()).details)
    }

    @Test
    fun test_fromJsonTurnsJsonNullDetailValuesIntoNull() {
        val details = JSONObject().put("note", JSONObject.NULL).put("n", 1)
        val event = MobyBeaconEvent.fromJson(full().put("details", details))
        assertTrue(event.details!!.containsKey("note"))
        assertNull(event.details!!["note"])
        assertEquals(1, event.details!!["n"])
    }

    // Iso8601

    @Test
    fun test_iso8601FormatsAndParsesMilliseconds() {
        val without = ms("2026-10-07T12:00:00.000Z")
        val withFraction = ms("2026-10-07T12:00:00.250Z")
        assertEquals(250L, withFraction - without)
        assertEquals("2026-10-07T12:00:00.000Z", Iso8601.format(without))
        assertEquals("2026-10-07T12:00:00.250Z", Iso8601.format(withFraction))
        assertEquals("1970-01-01T00:00:00.000Z", Iso8601.format(0))
    }

    @Test
    fun test_iso8601RejectsGarbageAndTrailingText() {
        for (text in listOf("garbage", "", "2026-10-07T12:00:00.000Z junk", "2026-10-07T12:00:00.000Zz")) {
            try {
                Iso8601.parse(text)
                fail("expected ParseException for '$text'")
            } catch (e: ParseException) {
                assertEquals("Invalid timestamp: $text", e.message)
            }
        }
    }

    @Test
    fun test_iso8601RequiresMillisecondsAndAZuluSuffix() {
        // The Flutter SDK always writes milliseconds, so the stored format is exact.
        for (text in listOf("2026-10-07T12:00:00Z", "2026-10-07T12:00:00.000+00:00", "2026-10-07 12:00:00.000Z")) {
            try {
                Iso8601.parse(text)
                fail("expected ParseException for '$text'")
            } catch (e: ParseException) {
                // Expected.
            }
        }
    }

    @Test
    fun test_iso8601IsStrictAboutFieldRanges() {
        try {
            Iso8601.parse("2026-13-07T12:00:00.000Z")
            fail("expected ParseException for month 13")
        } catch (e: ParseException) {
            // Expected: not lenient.
        }
    }
}
