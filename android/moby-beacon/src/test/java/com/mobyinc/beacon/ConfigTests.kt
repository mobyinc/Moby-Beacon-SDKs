package com.mobyinc.beacon

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ConfigTests {
    private fun builder(
        endpoint: String = "https://beacon.test",
        apiKey: String = "key-123",
        userId: String = "user-1",
    ): MobyBeaconConfig.Builder = MobyBeaconConfig.Builder(endpoint, apiKey, userId)

    private fun assertRejects(message: String, build: () -> MobyBeaconConfig) {
        try {
            build()
        } catch (e: IllegalArgumentException) {
            assertEquals(message, e.message)
            return
        }
        fail("expected IllegalArgumentException: $message")
    }

    @Test
    fun test_appliesDefaults() {
        val c = MobyBeaconConfig.Builder("https://beacon.test", "k", "u").build()
        assertEquals(5000L, c.flushIntervalMs)
        assertEquals(10, c.batchSize)
        assertEquals(10_000, c.maxQueueSize)
        assertNull(c.onError)
    }

    @Test
    fun test_stripsATrailingSlashFromEndpoint() {
        assertEquals("https://beacon.test", builder(endpoint = "https://beacon.test/").build().endpoint)
    }

    @Test
    fun test_rejectsEmptyEndpointApiKeyAndUserId() {
        assertRejects("endpoint must be an absolute http(s) URL") { builder(endpoint = "").build() }
        assertRejects("endpoint must be an absolute http(s) URL") { builder(endpoint = "/").build() }
        assertRejects("apiKey must not be empty") { builder(apiKey = "").build() }
        assertRejects("userId must not be empty") { builder(userId = "").build() }
    }

    @Test
    fun test_rejectsNonPositiveFlushIntervalBatchSizeAndMaxQueueSize() {
        assertNotNull(builder().build())
        assertRejects("flushIntervalMs must be positive") { builder().flushIntervalMs(0).build() }
        assertRejects("flushIntervalMs must be positive") { builder().flushIntervalMs(-1).build() }
        assertRejects("batchSize must be at least 1") { builder().batchSize(0).build() }
        assertRejects("maxQueueSize must be at least 1") { builder().maxQueueSize(0).build() }
    }

    @Test
    fun test_buildCapturesEverySetting() {
        val handler = MobyBeaconErrorHandler { }
        val c = MobyBeaconConfig.Builder("https://beacon.test/", "k", "u")
            .flushIntervalMs(2000)
            .batchSize(3)
            .maxQueueSize(4)
            .onError(handler)
            .build()
        assertEquals("https://beacon.test", c.endpoint)
        assertEquals("k", c.apiKey)
        assertEquals("u", c.userId)
        assertEquals(2000L, c.flushIntervalMs)
        assertEquals(3, c.batchSize)
        assertEquals(4, c.maxQueueSize)
        assertSame(handler, c.onError)
    }

    @Test
    fun test_builderSettersReturnTheBuilder() {
        val b = builder()
        assertSame(b, b.flushIntervalMs(1))
        assertSame(b, b.batchSize(1))
        assertSame(b, b.maxQueueSize(1))
        assertSame(b, b.onError(null))
    }

    @Test
    fun test_stripsAllTrailingSlashesAndKeepsAnyPath() {
        assertEquals("https://beacon.test", builder(endpoint = "https://beacon.test//").build().endpoint)
        assertEquals("https://beacon.test/api", builder(endpoint = "https://beacon.test/api/").build().endpoint)
        assertEquals("https://beacon.test/api", builder(endpoint = "https://beacon.test/api///").build().endpoint)
    }

    @Test
    fun test_rejectsEndpointsThatAreNotAbsoluteHttpUrls() {
        for (endpoint in listOf("beacon.test", "localhost:3011", "ftp://beacon.test", "https://", "", "https:beacon.test")) {
            assertRejects("endpoint must be an absolute http(s) URL") { builder(endpoint = endpoint).build() }
        }
    }

    @Test
    fun test_acceptsHttpAndMixedCaseSchemesWithPortsAndUserInfo() {
        assertEquals("http://localhost:3011", builder(endpoint = "http://localhost:3011").build().endpoint)
        assertEquals("HTTPS://Beacon.test", builder(endpoint = "HTTPS://Beacon.test").build().endpoint)
        assertEquals("https://me@beacon.test:8443/api", builder(endpoint = "https://me@beacon.test:8443/api/").build().endpoint)
    }

    @Test
    fun test_isAbsoluteHttpUrlSplitsTheTextLikeAndroidUri() {
        assertTrue(isAbsoluteHttpUrl("https://beacon.test"))
        assertTrue(isAbsoluteHttpUrl("https://beacon.test?x=1"))
        assertTrue(isAbsoluteHttpUrl("https://beacon.test#frag"))
        assertTrue(isAbsoluteHttpUrl("https://beacon.test\\path"))
        assertTrue(isAbsoluteHttpUrl("https://user:pw@beacon.test:8080/x"))
        assertFalse("port without host", isAbsoluteHttpUrl("https://:8080"))
        assertFalse("user info without host", isAbsoluteHttpUrl("https://me@"))
        assertFalse("single slash", isAbsoluteHttpUrl("https:/beacon.test"))
        assertFalse("no authority", isAbsoluteHttpUrl("https:"))
        assertFalse("empty scheme", isAbsoluteHttpUrl("://beacon.test"))
    }

    @Test
    fun test_rejectsEndpointsWithAQueryFragmentOrWhitespace() {
        for (endpoint in listOf(
            "https://beacon.test?x=1", "https://beacon.test/api?", "https://beacon.test#frag",
            "https://beacon.test ", "https://beacon.test\n", "https://bea con.test",
        )) {
            assertRejects("endpoint must be an absolute http(s) URL") { builder(endpoint = endpoint).build() }
        }
    }

    @Test
    fun test_rejectsAnApiKeyWithControlCharacters() {
        for (apiKey in listOf("key\n", "key\r\n", "\tkey", "ke\u0000y", "key\u007F")) {
            assertRejects("apiKey must not contain control characters") { builder(apiKey = apiKey).build() }
        }
        assertEquals("key with spaces", builder(apiKey = "key with spaces").build().apiKey)
    }

    @Test
    fun test_rejectsWhitespaceOnlyApiKeyAndUserId() {
        assertRejects("apiKey must not be empty") { builder(apiKey = "  ").build() }
        assertRejects("userId must not be empty") { builder(userId = "\n").build() }
    }

    @Test
    fun test_rejectsAUserIdTheAPIWouldNotAccept() {
        assertRejects("userId must be at most 255 characters") { builder(userId = "x".repeat(256)).build() }
        assertRejects("userId must not contain NUL characters") { builder(userId = "a\u0000b").build() }
        assertEquals(255, builder(userId = "x".repeat(255)).build().userId.length)
    }

    @Test
    fun test_errorToStringNamesTypeAndMessage() {
        val error = MobyBeaconError(MobyBeaconErrorType.NETWORK, "offline", emptyList(), null, true)
        assertEquals("MobyBeaconError(NETWORK): offline", error.toString())
        for ((type, name) in listOf(
            MobyBeaconErrorType.SERVER to "SERVER",
            MobyBeaconErrorType.AUTH to "AUTH",
            MobyBeaconErrorType.VALIDATION to "VALIDATION",
        )) {
            assertEquals("MobyBeaconError($name): m", MobyBeaconError(type, "m", emptyList()).toString())
        }
    }

    @Test
    fun test_errorTypeNamesAreStable() {
        assertEquals(
            listOf("NETWORK", "SERVER", "AUTH", "VALIDATION"),
            MobyBeaconErrorType.values().map { it.name },
        )
    }

    @Test
    fun test_errorDefaultsToNoPerEventErrorsAndNoRetry() {
        val error = MobyBeaconError(MobyBeaconErrorType.VALIDATION, "bad", emptyList())
        assertNull(error.errors)
        assertFalse(error.willRetry)
        assertTrue(error.events.isEmpty())
    }
}
