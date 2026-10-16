package com.mobyinc.beacon

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.Collections

/**
 * FIFO queue of events, mirrored to [QueueStorage] so it survives restarts.
 *
 * Every method must be called on the single worker thread, so no locking is
 * needed. Mutations apply to memory immediately and ask [scheduleWrite] to run
 * [flushPendingWrite] on that worker later; any number of mutations before it
 * runs share one write.
 *
 * Nothing is written before [load] has run. Mutations before it stay in
 * memory and are written right after it, so a store whose load is waiting on
 * the previous instance's final save cannot overwrite that save.
 *
 * The stored file is `{"v":1,"events":[...]}`.
 */
internal class EventStore(
    private val storage: QueueStorage,
    val maxSize: Int,
    private val scheduleWrite: (Runnable) -> Unit,
) {
    /**
     * An event together with its JSON, encoded once so writes never re-encode
     * the whole queue, and that JSON's UTF-8 size for byte-bounded batches.
     */
    private class Entry(val event: MobyBeaconEvent, val json: String, val bytes: Int)

    /**
     * Called with a human-readable message when stored events could not be
     * read and were dropped. Settable so the owner can wire it after creation.
     */
    var onDiscarded: ((String) -> Unit)? = null

    private val entries = ArrayList<Entry>()

    /** A mutation has not been written yet. */
    private var dirty = false

    /** The last write failed, so disk may not match memory. */
    private var stale = false

    /** A [flushPendingWrite] job has been requested and has not started yet. */
    private var writeScheduled = false

    /** [load] has run, so writing the file is allowed. */
    private var loaded = false

    val size: Int get() = entries.size

    /**
     * Loads persisted events and appends them to whatever was added before.
     * Call once. Until it has run, mutations are kept in memory and not
     * written; it writes them once loading is done.
     *
     * Never throws for storage or content problems: unreadable content is
     * quarantined and reported via [onDiscarded].
     */
    fun load() {
        try {
            readStored()
        } finally {
            loaded = true
            // Covers events added before the load, and entries skipped by it.
            if (dirty) requestWrite()
        }
    }

    private fun readStored() {
        val contents: String?
        try {
            contents = storage.read()
        } catch (e: Exception) {
            // Anything other than "missing" is treated as corruption.
            discardStored()
            return
        }
        if (contents == null) return

        val parsed = parse(contents)
        if (parsed == null) {
            discardStored()
            return
        }
        val (stored, skipped) = parsed
        // Append, never prepend: a flush may have peeked the front of the
        // queue and will remove exactly that many events when it finishes.
        entries.addAll(stored)
        if (skipped > 0) {
            report("$skipped persisted event(s) were unreadable and have been discarded")
            dirty = true // Drop the bad entries from disk.
        }
    }

    /**
     * Appends [event]. Throws [IllegalStateException] when the queue holds
     * [maxSize] events, or [IllegalArgumentException] if the event cannot be
     * encoded as JSON.
     */
    fun add(event: MobyBeaconEvent) {
        if (entries.size >= maxSize) {
            throw IllegalStateException("Queue is at capacity")
        }
        val json = try {
            event.toJson().toString()
        } catch (e: JSONException) {
            throw IllegalArgumentException("Event could not be encoded as JSON", e)
        }
        entries.add(newEntry(event, json))
        requestWrite()
    }

    /**
     * Returns up to [count] events from the front without removing them.
     *
     * With [maxBytes], returns the longest such prefix whose UTF-8 encoded
     * events, plus one comma between each, fit in [maxBytes]. At least one
     * event is returned whenever the queue is non-empty, even if it alone is
     * larger, so the caller can still send (or drop) it.
     */
    fun peek(count: Int, maxBytes: Int? = null): List<MobyBeaconEvent> {
        var n = minOf(count, entries.size).coerceAtLeast(0)
        if (maxBytes != null && n > 1) {
            var total = entries[0].bytes.toLong()
            var fits = 1
            while (fits < n) {
                total += 1L + entries[fits].bytes
                if (total > maxBytes) break
                fits++
            }
            n = fits
        }
        val result = ArrayList<MobyBeaconEvent>(n)
        for (i in 0 until n) result.add(entries[i].event)
        return Collections.unmodifiableList(result)
    }

    /** Removes up to [count] events from the front. */
    fun removeFirst(count: Int) {
        val n = minOf(count, entries.size)
        if (n <= 0) return
        entries.subList(0, n).clear()
        requestWrite()
    }

    /**
     * Writes now if disk may differ from memory. Does nothing before [load]
     * has run. Never throws.
     */
    fun persist() {
        if (!loaded) return
        // A failed write cleared dirty, so a stale queue needs it set again.
        if (stale) dirty = true
        if (dirty) flushPendingWrite()
    }

    /**
     * The body of the coalesced write job. Writes until no mutation is
     * outstanding; a failed write leaves [stale] set for [persist] or the next
     * mutation to retry. Never throws.
     */
    fun flushPendingWrite() {
        writeScheduled = false
        while (dirty) {
            dirty = false
            try {
                storage.write(encode())
                stale = false
            } catch (e: Exception) {
                // Keep working from memory; persist() or the next mutation retries.
                stale = true
                return
            }
        }
    }

    private fun requestWrite() {
        dirty = true
        if (!loaded || writeScheduled) return
        writeScheduled = true
        try {
            scheduleWrite(Runnable { flushPendingWrite() })
        } catch (e: Exception) {
            // The job never got queued. dirty stays set, so persist() still writes.
            writeScheduled = false
        }
    }

    private fun encode(): String {
        val sb = StringBuilder("{\"v\":1,\"events\":[")
        for (i in entries.indices) {
            if (i > 0) sb.append(',')
            sb.append(entries[i].json)
        }
        return sb.append("]}").toString()
    }

    private fun discardStored() {
        try {
            storage.quarantine()
        } catch (e: Exception) {
            // Nothing more we can do; start empty either way.
        }
        report("Persisted event queue was unreadable and has been discarded")
    }

    /**
     * Returns the stored entries and how many were skipped, or null if the
     * content as a whole is unreadable.
     */
    private fun parse(contents: String): Pair<List<Entry>, Int>? {
        val root = try {
            JSONObject(contents)
        } catch (e: JSONException) {
            return null
        }
        val version = root.opt("v") as? Number
        if (version == null || version.toDouble() != 1.0) return null
        val array = root.opt("events") as? JSONArray ?: return null

        val parsed = ArrayList<Entry>()
        var skipped = 0
        for (i in 0 until array.length()) {
            try {
                val obj = array.opt(i) as? JSONObject
                    ?: throw JSONException("event must be an object")
                val event = sanitizeEvent(MobyBeaconEvent.fromJson(obj))
                validateEvent(event)
                parsed.add(newEntry(event, event.toJson().toString()))
            } catch (e: Exception) {
                skipped++
            }
        }
        return Pair(parsed, skipped)
    }

    private fun newEntry(event: MobyBeaconEvent, json: String): Entry =
        Entry(event, json, json.toByteArray(Charsets.UTF_8).size)

    private fun report(message: String) {
        try {
            onDiscarded?.invoke(message)
        } catch (e: Exception) {
            // A throwing callback must not break loading or writing.
        }
    }
}
