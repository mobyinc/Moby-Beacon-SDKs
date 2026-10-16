package com.mobyinc.beacon

import com.mobyinc.beacon.support.canonical
import com.mobyinc.beacon.support.utf16String
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.Date

class ValidationTests {
    private val fixedMs = 1_791_331_200_000L

    private fun event(
        userId: String = "user-1",
        category: String = "screen",
        action: String = "view",
        details: Map<String, Any?>? = null,
    ): MobyBeaconEvent = MobyBeaconEvent(userId, category, action, fixedMs, details)

    private fun assertThrowsMessage(message: String, event: MobyBeaconEvent) {
        try {
            validateEvent(event)
        } catch (e: IllegalArgumentException) {
            assertEquals(message, e.message)
            return
        }
        fail("expected IllegalArgumentException: $message")
    }

    private fun withField(field: String, value: String): MobyBeaconEvent = event(
        userId = if (field == "userId") value else "user-1",
        category = if (field == "category") value else "screen",
        action = if (field == "action") value else "view",
    )

    @Test
    fun test_acceptsAMinimalEvent() {
        validateEvent(event())
    }

    @Test
    fun test_acceptsPrimitiveDetails() {
        validateEvent(event(details = mapOf(
            "s" to "text", "i" to 3, "l" to 3L, "d" to 1.5, "f" to 1.5f, "b" to true, "n" to null,
        )))
    }

    @Test
    fun test_rejectsEmptyFields() {
        for (field in listOf("userId", "category", "action")) {
            assertThrowsMessage("$field is required and must be a non-empty string", withField(field, ""))
        }
    }

    @Test
    fun test_rejectsFieldsOver255Characters() {
        for (field in listOf("userId", "category", "action")) {
            assertThrowsMessage("$field must be at most 255 characters", withField(field, "x".repeat(256)))
        }
    }

    @Test
    fun test_rejectsNestedMapValues() {
        assertThrowsMessage(
            "details.nested must be a string, number, boolean, or null — not a nested object or array",
            event(details = mapOf("nested" to mapOf("a" to 1))),
        )
    }

    @Test
    fun test_rejectsListValues() {
        assertThrowsMessage(
            "details.list must be a string, number, boolean, or null — not a nested object or array",
            event(details = mapOf("list" to listOf(1, 2))),
        )
    }

    @Test
    fun test_rejectsMoreThan50Keys() {
        val details = (0 until 51).associate { "k$it" to it }
        assertThrowsMessage("details must have at most 50 keys", event(details = details))
    }

    @Test
    fun test_rejectsKeysOver255Characters() {
        assertThrowsMessage("details key must be at most 255 characters", event(details = mapOf("k".repeat(256) to 1)))
    }

    @Test
    fun test_rejectsStringValuesOver1000Characters() {
        assertThrowsMessage(
            "details string values must be at most 1000 characters",
            event(details = mapOf("s" to "x".repeat(1001))),
        )
    }

    @Test
    fun test_rejectsNaNAndInfinity() {
        assertThrowsMessage("details.n must be a finite number", event(details = mapOf("n" to Double.NaN)))
        assertThrowsMessage("details.n must be a finite number", event(details = mapOf("n" to Double.POSITIVE_INFINITY)))
        assertThrowsMessage("details.n must be a finite number", event(details = mapOf("n" to Float.NaN)))
    }

    @Test
    fun test_rejectsNULCharactersInRequiredStrings() {
        assertThrowsMessage("category must not contain NUL characters", event(category = "a\u0000b"))
    }

    @Test
    fun test_rejectsNULCharactersInDetailsKeysAndStringValues() {
        assertThrowsMessage("details keys must not contain NUL characters", event(details = mapOf("k\u0000" to 1)))
        assertThrowsMessage("details.s must not contain NUL characters", event(details = mapOf("s" to "a\u0000")))
    }

    @Test
    fun test_acceptsValuesExactlyAtTheLimits() {
        val details = LinkedHashMap<String, Any?>()
        for (i in 0 until 49) details["k$i"] = i
        details["k".repeat(255)] = "x".repeat(1000)
        validateEvent(event(category = "x".repeat(255), details = details))
    }

    @Test
    fun test_rejectsAWhitespaceOnlyUserId() {
        assertThrowsMessage("userId must not be blank", event(userId = " \t\n"))
    }

    // validateUserId

    @Test
    fun test_validateUserIdAcceptsAUsableId() {
        validateUserId("user-1")
        validateUserId("x".repeat(255))
    }

    @Test
    fun test_validateUserIdRejectsBlankLongAndNULIds() {
        for ((value, message) in listOf(
            "" to "userId must not be empty",
            " \t" to "userId must not be empty",
            "x".repeat(256) to "userId must be at most 255 characters",
            "a\u0000b" to "userId must not contain NUL characters",
        )) {
            try {
                validateUserId(value)
                fail("expected IllegalArgumentException: $message")
            } catch (e: IllegalArgumentException) {
                assertEquals(message, e.message)
            }
        }
    }

    // sanitizeString

    @Test
    fun test_replacesALoneHighSurrogate() {
        assertEquals("a�b", sanitizeString(utf16String(0x61, 0xD83D, 0x62)))
    }

    @Test
    fun test_replacesALoneLowSurrogate() {
        assertEquals("a�b", sanitizeString(utf16String(0x61, 0xDE00, 0x62)))
    }

    @Test
    fun test_replacesAHighSurrogateAtTheEndOfTheString() {
        // "I feel " followed by the first half of U+1F600.
        assertEquals("I feel �", sanitizeString("I feel \uD83D"))
    }

    @Test
    fun test_replacesEachHalfOfAReversedPair() {
        assertEquals("��", sanitizeString(utf16String(0xDE00, 0xD83D)))
    }

    @Test
    fun test_keepsValidPairsAndOtherTextUnchanged() {
        val text = "plain, accents é, emoji 😀👍"
        assertEquals(text, sanitizeString(text))
        assertSame("no copy when nothing changes", text, sanitizeString(text))
        assertEquals("", sanitizeString(""))
    }

    @Test
    fun test_replacesEveryLoneSurrogateInAString() {
        assertEquals("�a�😀�", sanitizeString("\uD83Da\uDE00😀\uDBFF"))
    }

    // sanitizeEvent

    @Test
    fun test_cleansRequiredStringsDetailsKeysAndStringValues() {
        val cleaned = sanitizeEvent(MobyBeaconEvent(
            userId = utf16String(0x75, 0xD83D),
            category = utf16String(0x63, 0xDE00),
            action = utf16String(0xD83D, 0x61),
            timestampMs = fixedMs,
            details = mapOf(utf16String(0x6B, 0xD83D) to utf16String(0x76, 0xDE00), "n" to 1, "b" to true, "z" to null),
        ))

        assertEquals("u�", cleaned.userId)
        assertEquals("c�", cleaned.category)
        assertEquals("�a", cleaned.action)
        assertEquals(fixedMs, cleaned.timestampMs)
        val details = cleaned.details!!
        assertEquals(4, details.size)
        assertEquals("v�", details["k�"])
        assertEquals(1, details["n"])
        assertEquals(true, details["b"])
        assertTrue(details.containsKey("z"))
        assertNull(details["z"])
        assertTrue(canonical(cleaned.toJson()).contains("�"))
    }

    @Test
    fun test_copiesDetailsSoLaterChangesDoNotLeakIn() {
        val details = HashMap<String, Any?>()
        details["a"] = 1
        val cleaned = sanitizeEvent(event(details = details))
        details["a"] = 2
        details["b"] = 1

        assertEquals(1, cleaned.details?.size)
        assertEquals(1, cleaned.details?.get("a"))
    }

    @Test
    fun test_theDetailsCopyIsUnmodifiable() {
        val cleaned = sanitizeEvent(event(details = mapOf("a" to 1)))
        try {
            (cleaned.details as MutableMap<String, Any?>)["b"] = 2
            fail("expected the copy to be unmodifiable")
        } catch (e: UnsupportedOperationException) {
            // Expected.
        }
        assertEquals(1, cleaned.details?.size)
    }

    @Test
    fun test_aSelfContainingListIsCopiedWithoutRecursingAndRejected() {
        val loop = ArrayList<Any?>()
        loop.add("x")
        loop.add(loop)
        try {
            val cleaned = sanitizeEvent(event(details = mapOf("loop" to loop)))

            assertEquals(2, (cleaned.details?.get("loop") as List<*>).size)
            assertThrowsMessage(
                "details.loop must be a string, number, boolean, or null — not a nested object or array",
                cleaned,
            )
        } finally {
            loop.clear() // Break the cycle.
        }
    }

    @Test
    fun test_aNullDetailValueStaysNullAndEncodesAsJsonNull() {
        val cleaned = sanitizeEvent(event(details = mapOf("note" to null, "present" to "x")))

        assertTrue(cleaned.details!!.containsKey("note"))
        assertNull(cleaned.details!!["note"])
        assertEquals("x", cleaned.details!!["present"])
        validateEvent(cleaned)
        assertTrue(canonical(cleaned.toJson()).contains("\"note\":null"))
    }

    @Test
    fun test_keepsNullDetails() {
        assertNull(sanitizeEvent(event()).details)
    }

    @Test
    fun test_sanitizeEventReturnsANewEvent() {
        val original = event(details = mapOf("a" to 1))
        val cleaned = sanitizeEvent(original)
        assertNotSame(original, cleaned)
        assertNotSame(original.details, cleaned.details)
    }

    // JVM values

    @Test
    fun test_acceptsBoxedPrimitiveDetailValues() {
        val e = MobyBeaconEvent("u", "c", "a", fixedMs, mapOf("b" to true, "i" to 1, "d" to 1.5, "n" to null, "s" to "x"))
        validateEvent(e)
        val text = canonical(e.toJson())
        assertTrue(text, text.contains("\"b\":true")) // a Boolean stays a JSON boolean, not 1
        assertTrue(text, text.contains("\"n\":null"))
    }

    @Test
    fun test_rejectsDateAndByteArrayDetailValues() {
        val message = "must be a string, number, boolean, or null"
        for ((key, value) in listOf("when" to Date(), "blob" to byteArrayOf(1, 2, 3))) {
            try {
                validateEvent(event(details = mapOf(key to value)))
                fail("expected $key to be rejected")
            } catch (e: IllegalArgumentException) {
                val actual = e.message ?: ""
                assertTrue(actual, actual.startsWith("details.$key $message"))
            }
        }
    }

    @Test
    fun test_sanitizedStringEncodesAsJSON() {
        val sanitized = sanitizeString(utf16String(0x49, 0xD83D))
        assertEquals("I�", sanitized)
        val text = org.json.JSONObject().put("s", sanitized).toString()
        assertTrue(text, text.contains("I�"))
        assertEquals(sanitized, org.json.JSONObject(text).getString("s"))
    }
}
