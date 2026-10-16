package com.mobyinc.beacon;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.content.Context;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.After;
import org.junit.Test;

/**
 * Pins the surface the Java app calls: the builder, the {@code onError}
 * lambda, every {@code track} overload, {@code setUserId}, {@code flush} and
 * {@code dispose}. The counterpart of the iOS Objective-C surface tests.
 */
public class JavaSurfaceTest {
    private final JavaTestSupport support = new JavaTestSupport();
    private final List<MobyBeaconError> errors = new ArrayList<>();

    @After
    public void tearDown() {
        support.tearDown();
    }

    private MobyBeaconConfig config() {
        return new MobyBeaconConfig.Builder("https://beacon.test", "key-123", "user-1")
                .batchSize(3)
                .onError(errors::add)
                .build();
    }

    @Test
    public void configBuilderIsChainableAndValidatesFromJava() {
        MobyBeaconConfig config = new MobyBeaconConfig.Builder("https://beacon.test/", "key-123", "user-1")
                .flushIntervalMs(2000)
                .batchSize(5)
                .maxQueueSize(50)
                .onError(null)
                .build();
        assertEquals("https://beacon.test", config.getEndpoint());
        assertEquals("key-123", config.getApiKey());
        assertEquals("user-1", config.getUserId());
        assertEquals(2000L, config.getFlushIntervalMs());
        assertEquals(5, config.getBatchSize());
        assertEquals(50, config.getMaxQueueSize());
        assertNull(config.getOnError());

        try {
            new MobyBeaconConfig.Builder("beacon.test", "key-123", "user-1").build();
            fail("expected IllegalArgumentException");
        } catch (IllegalArgumentException e) {
            assertEquals("endpoint must be an absolute http(s) URL", e.getMessage());
        }
    }

    @Test
    public void errorHandlerIsAFunctionalInterface() {
        List<MobyBeaconError> seen = new ArrayList<>();
        MobyBeaconErrorHandler handler = seen::add;
        MobyBeacon beacon = support.start(new MobyBeaconConfig.Builder("https://beacon.test", "k", "u")
                .onError(handler)
                .build());

        beacon.track("", "view");

        assertEquals(1, seen.size());
        assertEquals(MobyBeaconErrorType.VALIDATION, seen.get(0).getType());
        assertEquals("category is required and must be a non-empty string", seen.get(0).getMessage());
        assertFalse(seen.get(0).getWillRetry());
        assertNull(seen.get(0).getErrors());
    }

    @Test
    public void everyTrackOverloadIsUsableFromJava() {
        MobyBeacon beacon = support.start(config());
        Map<String, Object> details = new HashMap<>();
        details.put("name", "home");

        beacon.track("screen", "two");
        beacon.track("screen", "three", details);
        beacon.track("screen", "four", null, "user-2");
        beacon.track("screen", "five", Collections.singletonMap("n", 1), "user-3", 1_791_331_200_000L);
        beacon.flush();
        support.runUntilIdle();

        assertEquals(2, support.requestCount()); // Batch size 3, then the flush.
        List<Map<String, Object>> first = support.sentEvents(0);
        assertEquals(3, first.size());
        assertEquals("two", first.get(0).get("action"));
        assertFalse(first.get(0).containsKey("details"));
        assertEquals(Collections.singletonMap("name", "home"), first.get(1).get("details"));
        assertEquals("user-2", first.get(2).get("userId"));
        List<Map<String, Object>> second = support.sentEvents(1);
        assertEquals("user-3", second.get(0).get("userId"));
        assertEquals("2026-10-07T00:00:00.000Z", second.get(0).get("timestamp"));
        assertEquals(Collections.singletonMap("n", 1), second.get(0).get("details"));
        assertTrue(errors.toString(), errors.isEmpty());
    }

    @Test
    public void trackCopiesTheDetailsMapBeforeReturning() {
        MobyBeacon beacon = support.start(config());
        Map<String, Object> details = new HashMap<>();
        details.put("text", "before");
        beacon.track("survey", "answer", details);
        details.put("text", "after");
        beacon.flush();
        support.runUntilIdle();

        assertEquals(Collections.singletonMap("text", "before"), support.sentEvents(0).get(0).get("details"));
    }

    @Test
    public void setUserIdFlushAndDisposeTakeNoCallbacks() {
        MobyBeacon beacon = support.start(config());
        beacon.setUserId("control_abc");
        beacon.track("auth", "login");
        beacon.flush();
        support.runUntilIdle();
        assertEquals("control_abc", support.sentEvents(0).get(0).get("userId"));

        beacon.track("screen", "late");
        beacon.dispose();
        beacon.track("screen", "dropped");
        support.runUntilIdle();
        assertEquals(2, support.requestCount());
        assertEquals("late", support.sentEvents(1).get(0).get("action"));
        assertTrue(support.storedContents().endsWith("\"events\":[]}"));
    }

    @Test
    public void createIsAStaticMethodTakingAContext() throws NoSuchMethodException {
        Method create = MobyBeacon.class.getMethod("create", Context.class, MobyBeaconConfig.class);
        assertTrue(Modifier.isStatic(create.getModifiers()));
        assertTrue(Modifier.isPublic(create.getModifiers()));
        assertEquals(MobyBeacon.class, create.getReturnType());
        // Only create() makes one: the constructor is private (Kotlin adds a
        // synthetic accessor for the companion, which Java cannot call).
        for (java.lang.reflect.Constructor<?> constructor : MobyBeacon.class.getDeclaredConstructors()) {
            assertTrue(constructor.toString(), constructor.isSynthetic() || !Modifier.isPublic(constructor.getModifiers()));
        }
    }

    @Test
    public void trackHasAnOverloadForEachOptionalParameter() throws NoSuchMethodException {
        assertNotNull(MobyBeacon.class.getMethod("track", String.class, String.class));
        assertNotNull(MobyBeacon.class.getMethod("track", String.class, String.class, Map.class));
        assertNotNull(MobyBeacon.class.getMethod("track", String.class, String.class, Map.class, String.class));
        assertNotNull(MobyBeacon.class.getMethod("track", String.class, String.class, Map.class, String.class, Long.class));
        assertNotNull(MobyBeacon.class.getMethod("setUserId", String.class));
        assertNotNull(MobyBeacon.class.getMethod("flush"));
        assertNotNull(MobyBeacon.class.getMethod("dispose"));
    }

    @Test
    public void eventsAndErrorsExposeGetters() {
        MobyBeaconEvent event = new MobyBeaconEvent("u", "c", "a", 1_791_331_200_000L, Collections.singletonMap("k", "v"));
        assertEquals("u", event.getUserId());
        assertEquals("c", event.getCategory());
        assertEquals("a", event.getAction());
        assertEquals(1_791_331_200_000L, event.getTimestampMs());
        assertEquals("v", event.getDetails().get("k"));

        EventBatchError batchError = new EventBatchError(2, "bad");
        assertEquals(2, batchError.getIndex());
        assertEquals("bad", batchError.getMessage());

        MobyBeaconError error = new MobyBeaconError(
                MobyBeaconErrorType.SERVER, "Server error: 503", Collections.singletonList(event),
                Collections.singletonList(batchError), true);
        assertEquals(MobyBeaconErrorType.SERVER, error.getType());
        assertEquals("Server error: 503", error.getMessage());
        assertEquals(1, error.getEvents().size());
        assertEquals(1, error.getErrors().size());
        assertTrue(error.getWillRetry());
        assertEquals("MobyBeaconError(SERVER): Server error: 503", error.toString());
    }

    @Test
    public void aThrowingHandlerIsSwallowed() {
        MobyBeacon beacon = support.start(new MobyBeaconConfig.Builder("https://beacon.test", "k", "u")
                .onError(error -> { throw new RuntimeException("handler failed"); })
                .build());
        beacon.track("", "view"); // Must not throw.
        beacon.track("screen", "view");
        beacon.flush();
        support.runUntilIdle();
        assertEquals("view", support.sentEvents(0).get(0).get("action"));
    }
}
