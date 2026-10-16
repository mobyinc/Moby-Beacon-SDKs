package com.mobyinc.beacon

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException

class FileQueueStorageTests {
    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var dir: File

    @org.junit.Before
    fun setUp() {
        dir = temp.newFolder("moby_beacon")
    }

    private fun file(name: String): File = File(dir, name)

    private fun exists(name: String): Boolean = file(name).exists()

    private fun assumeNotRoot() {
        assumeFalse("root bypasses file permissions", System.getProperty("user.name") == "root")
    }

    @Test
    fun test_readReturnsNullWhenNoFileExists() {
        assertNull(FileQueueStorage(dir).read())
    }

    @Test
    fun test_writeThenReadRoundTripsAndLeavesNoTempFile() {
        val storage = FileQueueStorage(dir)
        storage.write("[1,2,3]")

        assertEquals("[1,2,3]", storage.read())
        assertFalse(exists("queue.json.tmp"))
        assertTrue(exists("queue.json"))
    }

    @Test
    fun test_writeCreatesAMissingDirectory() {
        val nested = File(dir, "nested/moby_beacon")
        FileQueueStorage(nested).write("[]")
        assertTrue(File(nested, "queue.json").isFile)
    }

    @Test
    fun test_writeReplacesEarlierContent() {
        val storage = FileQueueStorage(dir)
        storage.write("first")
        storage.write("second, longer")
        storage.write("3")
        assertEquals("3", storage.read())
    }

    @Test
    fun test_quarantineMovesTheQueueAside() {
        val storage = FileQueueStorage(dir)
        storage.write("{not json")
        storage.quarantine()

        assertNull(storage.read())
        assertEquals("{not json", file("queue.json.corrupt").readText())
    }

    @Test
    fun test_quarantineWithNoFileDoesNothing() {
        FileQueueStorage(dir).quarantine()
        assertFalse(exists("queue.json.corrupt"))
    }

    @Test
    fun test_quarantineReplacesAnEarlierCorruptFile() {
        val storage = FileQueueStorage(dir)
        storage.write("first bad")
        storage.quarantine()
        storage.write("second bad")
        storage.quarantine()
        assertEquals("second bad", file("queue.json.corrupt").readText())
        assertNull(storage.read())
    }

    @Test
    fun test_aStrayTempFileIsIgnoredByReadAndReplacedByWrite() {
        file("queue.json.tmp").writeText("partial")
        val storage = FileQueueStorage(dir)
        assertNull(storage.read())

        storage.write("complete")
        assertEquals("complete", storage.read())
        assertFalse(exists("queue.json.tmp"))
    }

    @Test
    fun test_aFailedRenameRemovesTheTempFileAndRethrows() {
        // A non-empty directory where queue.json should be makes the rename fail
        // after the temp file has already been written.
        val storage = FileQueueStorage(dir)
        assertTrue(file("queue.json").mkdir())
        assertTrue(File(file("queue.json"), "occupant").createNewFile())

        try {
            storage.write("new")
            fail("expected the write to fail")
        } catch (e: IOException) {
            assertTrue(e.message ?: "", (e.message ?: "").contains("Could not rename"))
        }
        assertFalse(exists("queue.json.tmp"))
    }

    @Test
    fun test_aWriteIntoAReadOnlyDirectoryFailsAndKeepsTheOldFile() {
        assumeNotRoot()
        val storage = FileQueueStorage(dir)
        storage.write("old")
        assertTrue(dir.setWritable(false))
        try {
            try {
                storage.write("new")
                fail("expected the write to fail")
            } catch (e: IOException) {
                // Expected: the temp file cannot be created.
            }
            assertFalse(exists("queue.json.tmp"))
            assertEquals("old", storage.read())
        } finally {
            dir.setWritable(true)
        }
    }

    @Test
    fun test_writeFailsWhenTheDirectoryIsAFile() {
        val notADir = temp.newFile("not_a_dir")
        try {
            FileQueueStorage(notADir).write("[]")
            fail("expected the write to fail")
        } catch (e: IOException) {
            assertTrue(e.message ?: "", (e.message ?: "").contains("Not a directory"))
        }
    }

    @Test
    fun test_invalidUTF8ReadsAsTextWithReplacementCharacters() {
        // The quarantine half lives with the EventStore tests.
        file("queue.json").writeBytes(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x7B, 0x80.toByte()))
        val text = FileQueueStorage(dir).read()
        assertNotNull(text)
        assertTrue(text!!.contains("�"))
        assertTrue(text.contains("{"))
    }

    @Test
    fun test_readTreatsAnInaccessibleDirectoryAsMissing() {
        // Opening a file in a directory without search permission fails with
        // FileNotFoundException, which read() maps to "nothing stored". The
        // store then starts empty and its writes fail, so nothing is lost.
        assumeNotRoot()
        val storage = FileQueueStorage(dir)
        storage.write("[]")
        assertTrue(dir.setExecutable(false))
        try {
            assertNull(storage.read())
        } finally {
            dir.setExecutable(true)
        }
        assertEquals("[]", storage.read())
    }

    @Test
    fun test_readAndWriteUseUTF8() {
        val storage = FileQueueStorage(dir)
        storage.write("üüüü 😀")
        assertEquals("üüüü 😀", storage.read())
        assertEquals(8 + 1 + 4, file("queue.json").length())
    }
}
