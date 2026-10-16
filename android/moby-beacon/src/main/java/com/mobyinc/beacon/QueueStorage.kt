package com.mobyinc.beacon

import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException

/** Where the serialized event queue is kept between app runs. */
internal interface QueueStorage {
    /** Returns the stored queue, or null if nothing has been stored. */
    fun read(): String?

    /** Replaces the stored queue with [contents]. */
    fun write(contents: String)

    /** Moves an unreadable stored queue aside so it is not loaded again. */
    fun quarantine()
}

/**
 * Stores the queue as `queue.json` in [directory], writing atomically via a
 * temp file and rename.
 */
internal class FileQueueStorage(private val directory: File) : QueueStorage {
    private val file get() = File(directory, "queue.json")
    private val tempFile get() = File(directory, "queue.json.tmp")
    private val corruptFile get() = File(directory, "queue.json.corrupt")

    override fun read(): String? {
        val bytes = try {
            file.readBytes()
        } catch (e: FileNotFoundException) {
            return null
        }
        // Malformed bytes become U+FFFD rather than throwing. Damage inside a
        // JSON string just alters that string; only structural damage fails
        // parsing and is treated as corruption.
        return String(bytes, Charsets.UTF_8)
    }

    override fun write(contents: String) {
        try {
            directory.mkdirs()
            if (!directory.isDirectory) {
                throw IOException("Not a directory: $directory")
            }
            FileOutputStream(tempFile).use { out ->
                out.write(contents.toByteArray(Charsets.UTF_8))
                out.flush()
                // Make the temp file durable before it replaces the real one.
                out.fd.sync()
            }
            if (!tempFile.renameTo(file)) {
                throw IOException("Could not rename $tempFile to $file")
            }
        } catch (e: Exception) {
            try {
                tempFile.delete()
            } catch (ignored: Exception) {
                // Best effort; the next write replaces it anyway.
            }
            throw e
        }
    }

    override fun quarantine() {
        if (file.exists() && !file.renameTo(corruptFile)) {
            throw IOException("Could not rename $file to $corruptFile")
        }
    }
}
