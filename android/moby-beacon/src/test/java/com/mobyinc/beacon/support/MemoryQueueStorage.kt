package com.mobyinc.beacon.support

import com.mobyinc.beacon.QueueStorage

/**
 * In-memory [QueueStorage] for tests. Every call completes synchronously on
 * the calling thread, as the file-backed one does on the worker.
 */
class MemoryQueueStorage(initialContents: String? = null) : QueueStorage {
    @Volatile var contents: String? = initialContents

    /** Number of write attempts, including ones that failed. */
    @Volatile var writeCount = 0

    @Volatile var quarantined = false

    /** When set, [read] throws it (simulates storage that cannot be read). */
    var readError: Exception? = null

    /** When set, [write] throws it after counting the attempt. */
    var writeError: Exception? = null

    /** When set, [quarantine] throws it after recording the attempt. */
    var quarantineError: Exception? = null

    override fun read(): String? {
        readError?.let { throw it }
        return contents
    }

    override fun write(contents: String) {
        writeCount++
        writeError?.let { throw it }
        this.contents = contents
    }

    override fun quarantine() {
        quarantined = true
        quarantineError?.let { throw it }
        contents = null
    }
}
