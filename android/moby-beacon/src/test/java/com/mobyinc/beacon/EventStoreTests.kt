package com.mobyinc.beacon

import com.mobyinc.beacon.support.MemoryQueueStorage
import com.mobyinc.beacon.support.TestScheduler
import com.mobyinc.beacon.support.canonical
import com.mobyinc.beacon.support.event
import com.mobyinc.beacon.support.storedActions
import com.mobyinc.beacon.support.storedEvent
import com.mobyinc.beacon.support.v1
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.IOException
import java.util.concurrent.RejectedExecutionException

class EventStoreTests {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var scheduler: TestScheduler

    @Before
    fun setUp() {
        scheduler = TestScheduler()
    }

    private fun makeStore(storage: MemoryQueueStorage = MemoryQueueStorage(), maxSize: Int = 10): EventStore =
        EventStore(storage, maxSize) { scheduler.post(it) }

    /** Loads [store] and runs the scheduler until the write it may have requested has settled. */
    private fun load(store: EventStore) {
        store.load()
        scheduler.runUntilIdle()
    }

    /** Persists [store] and runs the scheduler until any pending write has settled. */
    private fun persist(store: EventStore) {
        store.persist()
        scheduler.runUntilIdle()
    }

    private fun actions(events: List<MobyBeaconEvent>): List<String> = events.map { it.action }

    /** [e] encoded as the store encodes it. */
    private fun json(e: MobyBeaconEvent): String = e.toJson().toString()

    private fun assertAtCapacity(block: () -> Unit) {
        try {
            block()
            fail("expected IllegalStateException")
        } catch (e: IllegalStateException) {
            assertEquals("Queue is at capacity", e.message)
        }
    }

    // MARK: EventStore

    @Test
    fun test_behavesAsAFIFOQueue() {
        val store = makeStore()
        store.add(event("a"))
        store.add(event("b"))
        store.add(event("c"))

        assertEquals(3, store.size)
        assertEquals(listOf("a", "b"), actions(store.peek(2)))
        assertEquals("peek does not remove", 3, store.size)

        store.removeFirst(2)
        assertEquals(listOf("c"), actions(store.peek(10)))
    }

    @Test
    fun test_addThrowsIllegalStateAtMaxSize() {
        val store = makeStore(maxSize = 1)
        store.add(event("a"))
        assertAtCapacity { store.add(event("b")) }
        assertEquals(1, store.size)
    }

    @Test
    fun test_persistsAndReloadsEvents() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage)
        load(store)
        store.add(event("a"))
        store.add(event("b"))
        persist(store)

        val reloaded = makeStore(storage)
        load(reloaded)
        assertEquals(listOf("a", "b"), actions(reloaded.peek(10)))
    }

    @Test
    fun test_writesTheVersionedFileFormat() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage)
        load(store)
        store.add(event("a"))
        persist(store)

        assertEquals(listOf("a"), storedActions(storage.contents))
        assertTrue(storage.contents!!.startsWith("{\"v\":1,\"events\":["))
    }

    @Test
    fun test_roundTripsEventsWithDetails() {
        val storage = MemoryQueueStorage()
        val original = MobyBeaconEvent(
            "user-1", "test", "a", Iso8601.parse("2026-10-07T12:30:15.250Z"),
            mapOf("s" to "text", "i" to 3, "d" to 1.5, "b" to true, "n" to null),
        )
        val store = makeStore(storage)
        load(store)
        store.add(original)
        persist(store)

        val reloaded = makeStore(storage)
        load(reloaded)
        val loaded = reloaded.peek(1)
        assertEquals(1, loaded.size)
        // Compared as canonical JSON so a boolean turning into a number would show.
        assertEquals(canonical(original.toJson()), canonical(loaded[0].toJson()))
        assertEquals(original.timestampMs, loaded[0].timestampMs)
    }

    @Test
    fun test_loadWithNothingStoredStartsEmpty() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage)
        load(store)
        assertEquals(0, store.size)
        assertFalse(storage.quarantined)
        assertEquals(0, storage.writeCount)
    }

    @Test
    fun test_loadQuarantinesAnUnparseableQueueAndStartsEmpty() {
        val storage = MemoryQueueStorage("{not json")
        val messages = ArrayList<String>()
        val store = makeStore(storage)
        store.onDiscarded = { messages.add(it) }

        load(store)
        assertEquals(0, store.size)
        assertTrue(storage.quarantined)
        assertEquals(listOf("Persisted event queue was unreadable and has been discarded"), messages)
    }

    private fun assertLoadQuarantinesWrongShapeContent(contents: String) {
        val storage = MemoryQueueStorage(contents)
        val messages = ArrayList<String>()
        val store = makeStore(storage)
        store.onDiscarded = { messages.add(it) }

        load(store)
        assertEquals(contents, 0, store.size)
        assertTrue(contents, storage.quarantined)
        assertEquals(contents, 1, messages.size)
    }

    @Test
    fun test_loadQuarantinesWrongShapeContentEmptyObject() {
        assertLoadQuarantinesWrongShapeContent("{}")
    }

    @Test
    fun test_loadQuarantinesWrongShapeContentEmptyArray() {
        assertLoadQuarantinesWrongShapeContent("[]")
    }

    @Test
    fun test_loadQuarantinesWrongShapeContentVersion2() {
        assertLoadQuarantinesWrongShapeContent("""{"v":2,"events":[]}""")
    }

    @Test
    fun test_loadQuarantinesWrongShapeContentEventsNotAnArray() {
        assertLoadQuarantinesWrongShapeContent("""{"v":1,"events":{}}""")
    }

    @Test
    fun test_loadSkipsBadEntriesKeepsGoodOnesAndRewritesTheFile() {
        val storage = MemoryQueueStorage(v1(listOf(
            event("a").toJson(),
            JSONObject().put("bogus", 1),
            event("b").toJson(),
            "not even an object",
        )))
        val messages = ArrayList<String>()
        val store = makeStore(storage)
        store.onDiscarded = { messages.add(it) }

        load(store)
        assertEquals(listOf("a", "b"), actions(store.peek(10)))
        assertFalse(storage.quarantined)
        assertEquals(listOf("2 persisted event(s) were unreadable and have been discarded"), messages)
        assertEquals("rewritten right after the load", 1, storage.writeCount)
        assertEquals(listOf("a", "b"), storedActions(storage.contents))
    }

    @Test
    fun test_loadSkipsStoredEntriesThatFailValidation() {
        val nested = event("nested").toJson()
        nested.put("details", JSONObject().put("x", JSONObject().put("y", 1)))
        val blank = event("blank").toJson()
        blank.put("category", "")
        val storage = MemoryQueueStorage(v1(listOf(event("a").toJson(), nested, blank, event("b").toJson())))
        val messages = ArrayList<String>()
        val store = makeStore(storage)
        store.onDiscarded = { messages.add(it) }

        load(store)
        assertEquals(listOf("a", "b"), actions(store.peek(10)))
        assertEquals(listOf("2 persisted event(s) were unreadable and have been discarded"), messages)
    }

    /** Review focus: one entry whose timestamp does not parse. */
    @Test
    fun test_loadSkipsAnEntryWithAnUnparseableTimestampAndRewritesWithoutIt() {
        val bad = storedEvent("bad").put("timestamp", "2026-10-06 09:00")
        val storage = MemoryQueueStorage(v1(listOf(storedEvent("a"), bad, storedEvent("b"))))
        val messages = ArrayList<String>()
        val store = makeStore(storage)
        store.onDiscarded = { messages.add(it) }

        load(store)
        assertEquals(listOf("a", "b"), actions(store.peek(10)))
        assertFalse(storage.quarantined)
        assertEquals(listOf("1 persisted event(s) were unreadable and have been discarded"), messages)
        assertEquals(listOf("a", "b"), storedActions(storage.contents))
        assertFalse(storage.contents!!.contains("2026-10-06 09:00"))
    }

    @Test
    fun test_loadReplacesLoneSurrogatesInStoredEntries() {
        // The file text Dart's `v1([event('a\uD83D').toJson()])` produces: a
        // lone surrogate can only reach the file as a JSON escape.
        val contents = v1(listOf(event("a").toJson()))
            .replace("\"action\":\"a\"", "\"action\":\"a\\ud83d\"")
        assertTrue(contents, contents.contains("\\ud83d"))
        val store = makeStore(MemoryQueueStorage(contents))

        load(store)
        assertEquals(listOf("a�"), actions(store.peek(10)))
    }

    /**
     * Guards the lone-surrogate repair above: escaped pairs and an escaped
     * backslash followed by `ud83d` are left as they are.
     */
    @Test
    fun test_loadKeepsSurrogatePairEscapesAndEscapedBackslashes() {
        val contents = v1(listOf(event("a", details = mapOf("k" to "\\ud83d")).toJson()))
            .replace("\"action\":\"a\"", "\"action\":\"\\ud83d\\ude00\"")
        assertTrue(contents, contents.contains("\"action\":\"\\ud83d\\ude00\""))
        assertTrue(contents, contents.contains("\\\\ud83d"))
        val store = makeStore(MemoryQueueStorage(contents))

        load(store)
        val loaded = store.peek(10)
        assertEquals(listOf("😀"), actions(loaded))
        assertEquals("\\ud83d", loaded[0].details?.get("k"))
    }

    @Test
    fun test_loadKeepsAStoredQueueLargerThanMaxSize() {
        val storage = MemoryQueueStorage(v1(listOf(event("a").toJson(), event("b").toJson(), event("c").toJson())))
        val store = makeStore(storage, maxSize = 2)

        load(store)
        assertEquals(3, store.size)
        assertAtCapacity { store.add(event("d")) }
    }

    @Test
    fun test_nothingIsWrittenBeforeLoad() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage)
        store.add(event("a"))
        store.removeFirst(1)
        store.add(event("b"))
        scheduler.runUntilIdle()
        store.persist()
        scheduler.runUntilIdle()

        assertEquals(0, storage.writeCount)
        assertNull(storage.contents)
        assertEquals(listOf("b"), actions(store.peek(10)))
    }

    @Test
    fun test_eventsAddedBeforeLoadStayAheadOfStoredOnesAndAreWrittenAfterLoad() {
        val storage = MemoryQueueStorage(v1(listOf(storedEvent("stored"))))
        val store = makeStore(storage)
        store.add(event("fresh"))
        assertEquals(0, storage.writeCount)

        load(store)
        assertEquals(listOf("fresh", "stored"), actions(store.peek(10)))
        assertEquals(1, storage.writeCount)
        assertEquals(listOf("fresh", "stored"), storedActions(storage.contents))
    }

    @Test
    fun test_coalescesRapidMutationsIntoOneWrite() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage, maxSize = 1000)
        load(store)
        for (i in 0 until 100) {
            store.add(event("e$i"))
        }
        assertEquals("no write before the job runs", 0, storage.writeCount)
        scheduler.runUntilIdle()
        assertEquals(1, storage.writeCount)
        assertEquals(100, storedActions(storage.contents).size)

        persist(store)
        assertEquals("nothing left to write", 1, storage.writeCount)
    }

    @Test
    fun test_aMutationAfterAWriteSchedulesExactlyOneMoreWrite() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage)
        load(store)
        store.add(event("a"))
        scheduler.runUntilIdle()
        assertEquals(1, storage.writeCount)

        store.add(event("b"))
        store.removeFirst(1)
        assertEquals(1, scheduler.pendingWorkCount)
        scheduler.runUntilIdle()
        assertEquals(2, storage.writeCount)
        assertEquals(listOf("b"), storedActions(storage.contents))
    }

    @Test
    fun test_persistReflectsRemovals() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage)
        load(store)
        store.add(event("a"))
        store.add(event("b"))
        store.removeFirst(1)
        persist(store)

        assertEquals(listOf("b"), storedActions(storage.contents))
    }

    @Test
    fun test_persistWritesNowWithoutWaitingForTheScheduledJob() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage)
        load(store)
        store.add(event("a"))
        store.persist()
        assertEquals(1, storage.writeCount)
        assertEquals(listOf("a"), storedActions(storage.contents))

        scheduler.runUntilIdle()
        assertEquals("the queued job finds nothing dirty", 1, storage.writeCount)
    }

    @Test
    fun test_persistRetriesAFailedWrite() {
        val storage = MemoryQueueStorage()
        storage.writeError = IOException("out of space")
        val store = makeStore(storage)
        load(store)
        store.add(event("a"))
        persist(store)
        assertEquals(1, storage.writeCount)
        assertNull(storage.contents)

        storage.writeError = null
        persist(store)
        assertEquals(2, storage.writeCount)
        assertEquals(listOf("a"), storedActions(storage.contents))
    }

    @Test
    fun test_theNextMutationRetriesAFailedWrite() {
        val storage = MemoryQueueStorage()
        storage.writeError = IOException("out of space")
        val store = makeStore(storage)
        load(store)
        store.add(event("a"))
        scheduler.runUntilIdle()
        assertEquals(1, storage.writeCount)
        assertNull(storage.contents)

        storage.writeError = null
        store.add(event("b"))
        scheduler.runUntilIdle()
        assertEquals(listOf("a", "b"), storedActions(storage.contents))
    }

    @Test
    fun test_persistDoesNothingWhenDiskMatchesMemory() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage)
        load(store)
        persist(store)
        assertEquals(0, storage.writeCount)

        store.add(event("a"))
        scheduler.runUntilIdle()
        persist(store)
        assertEquals(1, storage.writeCount)
    }

    @Test
    fun test_addRejectsAnEventThatCannotBeEncodedAsJSON() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage)
        load(store)
        // NaN slipped past validation: org.json refuses to encode it.
        val bad = MobyBeaconEvent("user-1", "test", "bad", Iso8601.parse("2026-10-07T00:00:00.000Z"), mapOf("x" to Double.NaN))

        try {
            store.add(bad)
            fail("expected IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            assertEquals("Event could not be encoded as JSON", e.message)
        }
        assertEquals(0, store.size)

        store.add(event("a"))
        persist(store)
        assertTrue(storage.writeCount > 0)
        assertEquals(listOf("a"), storedActions(storage.contents))
    }

    /** Unlike iOS, Android has no locked-at-launch state: a read error is corruption. */
    @Test
    fun test_aReadErrorQuarantinesAndStartsEmpty() {
        val storage = MemoryQueueStorage(v1(listOf(event("stored").toJson())))
        storage.readError = IOException("no permission")
        val messages = ArrayList<String>()
        val store = makeStore(storage)
        store.onDiscarded = { messages.add(it) }

        load(store)
        assertEquals(0, store.size)
        assertTrue(storage.quarantined)
        assertEquals(listOf("Persisted event queue was unreadable and has been discarded"), messages)

        store.add(event("new"))
        persist(store)
        assertEquals(listOf("new"), storedActions(storage.contents))
    }

    /**
     * The store half of FileQueueStorage's invalid-UTF-8 test: storage hands
     * back the bytes `[0xFF, 0xFE, 0x7B, 0x80]` decoded with U+FFFD.
     */
    @Test
    fun test_loadQuarantinesTextDecodedFromInvalidUTF8() {
        val text = String(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x7B, 0x80.toByte()), Charsets.UTF_8)
        val storage = MemoryQueueStorage(text)
        val messages = ArrayList<String>()
        val store = makeStore(storage)
        store.onDiscarded = { messages.add(it) }

        load(store)
        assertEquals(0, store.size)
        assertEquals(1, messages.size)
        assertTrue(storage.quarantined)
    }

    @Test
    fun test_aFailedQuarantineStillStartsEmptyAndReports() {
        val storage = MemoryQueueStorage("{not json")
        storage.quarantineError = IOException("cannot rename")
        val messages = ArrayList<String>()
        val store = makeStore(storage)
        store.onDiscarded = { messages.add(it) }

        load(store)
        assertEquals(0, store.size)
        assertEquals(1, messages.size)
        assertTrue(storage.quarantined)

        store.add(event("a"))
        persist(store)
        assertEquals(listOf("a"), storedActions(storage.contents))
    }

    @Test
    fun test_aThrowingOnDiscardedDoesNotBreakLoading() {
        val storage = MemoryQueueStorage(v1(listOf(event("a").toJson(), JSONObject().put("bogus", 1))))
        val store = makeStore(storage)
        store.onDiscarded = { throw IllegalStateException("handler failed") }

        load(store)
        assertEquals(listOf("a"), actions(store.peek(10)))
        assertEquals(listOf("a"), storedActions(storage.contents))
    }

    @Test
    fun test_aFailedScheduleWriteLeavesTheQueueDirtyForPersist() {
        val storage = MemoryQueueStorage()
        var attempts = 0
        val store = EventStore(storage, 10) {
            attempts++
            throw RejectedExecutionException("shut down")
        }
        store.load()
        store.add(event("a"))
        assertEquals(1, attempts)
        assertEquals(0, storage.writeCount)

        store.add(event("b"))
        assertEquals("retried once the first request failed", 2, attempts)

        store.persist()
        assertEquals(listOf("a", "b"), storedActions(storage.contents))
    }

    @Test
    fun test_eventStoreSurvivesAReloadFromDisk() {
        val dir = temp.newFolder("moby_beacon")
        val runNow: (Runnable) -> Unit = { it.run() }

        val store = EventStore(FileQueueStorage(dir), 10, runNow)
        store.load()
        store.add(event("a"))
        store.persist()

        val reloaded = EventStore(FileQueueStorage(dir), 10, runNow)
        reloaded.load()
        assertEquals(listOf("a"), actions(reloaded.peek(10)))
    }

    @Test
    fun test_aCorruptFileOnDiskIsQuarantinedByLoad() {
        val dir = temp.newFolder("moby_beacon")
        val storage = FileQueueStorage(dir)
        storage.write("{not json")
        val messages = ArrayList<String>()
        val store = EventStore(storage, 10) { it.run() }
        store.onDiscarded = { messages.add(it) }

        store.load()
        assertEquals(0, store.size)
        assertEquals(1, messages.size)
        assertEquals("{not json", java.io.File(dir, "queue.json.corrupt").readText())
        assertNull(storage.read())
    }

    @Test
    fun test_removeFirstBeyondTheQueueClearsItAndRemoveFirstOfZeroDoesNothing() {
        val storage = MemoryQueueStorage()
        val store = makeStore(storage)
        load(store)
        store.add(event("a"))
        scheduler.runUntilIdle()
        val writes = storage.writeCount

        store.removeFirst(0)
        store.removeFirst(-1)
        scheduler.runUntilIdle()
        assertEquals(writes, storage.writeCount)

        store.removeFirst(5)
        assertEquals(0, store.size)
    }

    @Test
    fun test_peekReturnsAnUnmodifiableSnapshot() {
        val store = makeStore()
        store.add(event("a"))
        val peeked = store.peek(10)
        try {
            (peeked as MutableList<MobyBeaconEvent>).add(event("b"))
            fail("expected an unmodifiable list")
        } catch (e: UnsupportedOperationException) {
            // Expected.
        }
        store.removeFirst(1)
        assertEquals(listOf("a"), actions(peeked))
    }

    // MARK: EventStore.peek with maxBytes

    /** UTF-8 size of [e] as the store encodes it. */
    private fun bytesOf(e: MobyBeaconEvent): Int = json(e).toByteArray(Charsets.UTF_8).size

    @Test
    fun test_returnsTheLongestPrefixWhoseEntriesAndCommasFit() {
        val store = makeStore()
        store.add(event("a"))
        store.add(event("b"))
        store.add(event("c"))
        val size = bytesOf(event("a"))

        assertEquals(listOf("a", "b"), actions(store.peek(10, 2 * size + 1)))
        assertEquals("the comma between entries counts", listOf("a"), actions(store.peek(10, 2 * size)))
        assertEquals(listOf("a", "b", "c"), actions(store.peek(10, 3 * size + 2)))
    }

    @Test
    fun test_stillRespectsCount() {
        val store = makeStore()
        store.add(event("a"))
        store.add(event("b"))

        assertEquals(listOf("a"), actions(store.peek(1, 1 shl 20)))
    }

    @Test
    fun test_returnsOneEventEvenWhenItExceedsMaxBytes() {
        val store = makeStore()
        store.add(event("a"))
        store.add(event("b"))

        assertEquals(listOf("a"), actions(store.peek(10, 1)))
    }

    @Test
    fun test_returnsNothingFromAnEmptyStore() {
        val store = makeStore()

        assertEquals(0, store.peek(10, 1).size)
        assertEquals(0, store.peek(0).size)
    }

    @Test
    fun test_measuresUTF8BytesNotStringLength() {
        val store = makeStore()
        store.add(event("üüüü"))
        store.add(event("üüüü"))
        val chars = json(event("üüüü")).length

        assertEquals(1, store.peek(10, 2 * chars + 1).size)
        assertEquals(2, store.peek(10, 2 * bytesOf(event("üüüü")) + 1).size)
    }

    @Test
    fun test_measuresEventsLoadedFromStorage() {
        val storage = MemoryQueueStorage(v1(listOf(event("a").toJson(), event("b").toJson())))
        val store = makeStore(storage)
        load(store)
        val size = bytesOf(event("a"))

        assertEquals(listOf("a"), actions(store.peek(10, 2 * size)))
        assertEquals(listOf("a", "b"), actions(store.peek(10, 2 * size + 1)))
    }
}
