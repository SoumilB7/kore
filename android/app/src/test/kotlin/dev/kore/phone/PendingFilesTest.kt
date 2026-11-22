package dev.kore.phone

import dev.kore.phone.ui.PendingFiles
import dev.kore.phone.ui.PendingFiles.Outcome
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * A chat's attachments through a trip to the camera or a picker: kept on disk across a screen
 * made again and a process started again, and uploaded only once the link is up. Virtual time.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class PendingFilesTest {
    @get:Rule val tmp = TemporaryFolder()
    private val photo = byteArrayOf(1, 2, 3, 4)

    /** A fake device: answers what [answers] says, in turn (Uploaded after them), and counts tries. */
    private class Device(vararg answers: Outcome) {
        val next = ArrayDeque(answers.toList())
        val tried = ArrayList<String>()
        suspend fun upload(item: PendingFiles.Item, bytes: ByteArray): Outcome {
            tried += item.name
            return next.removeFirstOrNull() ?: Outcome.Uploaded("blob-${item.name}-${bytes.size}")
        }
    }

    private fun TestScope.files(dir: File = tmp.root, scope: CoroutineScope = backgroundScope) = PendingFiles(dir, scope)

    @Test fun aScreenMadeAgainFindsTheSameFiles() = runTest {
        PendingFiles.forgetAll()
        val first = PendingFiles.of(tmp.root, "chat/1", backgroundScope)
        first.add("a.jpg", "image/jpeg", photo)
        // "Don't keep activities": the chat's screen and its composer are new; the holder isn't.
        val again = PendingFiles.of(tmp.root, "chat/1", backgroundScope)
        assertSame(first, again)
        assertEquals(listOf("a.jpg"), again.items.value.map { it.name })
        PendingFiles.forgetAll()
    }

    @Test fun theFilesAndTheCamerasTargetOutliveTheProcess() = runTest {
        val before = files()
        val shot = File(tmp.root, "shot-1.jpg")
        before.shot = shot
        val a = before.add("a.jpg", "image/jpeg", photo)
        val b = before.add("b.pdf", "application/pdf", byteArrayOf(9))
        before.uploaded(b.id, "blob-b")
        // A leftover from a message that was in flight when the process ended.
        File(tmp.root, "stray").writeBytes(photo)

        // Android ended the process while the camera ran: a new one reads the folder.
        val after = files()
        assertEquals(shot, after.shot)
        assertEquals(listOf(a.copy(), b.copy(blobId = "blob-b")), after.items.value)
        assertArrayEquals(photo, after.file(a.id).readBytes())
        assertFalse(File(tmp.root, "stray").exists())
        after.shot = null
        assertNull(files().shot)
    }

    @Test fun anUploadWaitsForTheLink() = runTest {
        val f = files()
        val up = MutableStateFlow(false)
        val device = Device()
        // The camera's photo comes back before the link does.
        val a = f.add("a.jpg", "image/jpeg", photo)
        f.drain(up, device::upload)
        advanceTimeBy(60_000); runCurrent()
        assertEquals(emptyList<String>(), device.tried)
        assertEquals(listOf(a), f.items.value)
        up.value = true
        runCurrent()
        assertEquals(listOf("a.jpg"), device.tried)
        assertEquals("blob-a.jpg-4", f.items.value.single().blobId)
    }

    @Test fun aLinkThatDropsMidUploadMeansItWaitsAgainNeverLost() = runTest {
        val f = files()
        val up = MutableStateFlow(true)
        val device = Device(Outcome.NoAnswer, Outcome.NoAnswer)
        f.add("a.jpg", "image/jpeg", photo)
        f.drain(up, device::upload)
        runCurrent()
        assertEquals(1, device.tried.size)
        // The link went: nothing is tried while it's down, and the file stays.
        up.value = false
        advanceTimeBy(PendingFiles.RETRY_CAP_MS * 4); runCurrent()
        assertEquals(1, device.tried.size)
        assertNull(f.items.value.single().blobId)
        up.value = true
        runCurrent()
        assertEquals(2, device.tried.size)
        // No answer again: once more after the doubled wait.
        advanceTimeBy(PendingFiles.RETRY_MS * 2 - 1); runCurrent()
        assertEquals(2, device.tried.size)
        advanceTimeBy(1); runCurrent()
        assertEquals(3, device.tried.size)
        assertEquals("blob-a.jpg-4", f.items.value.single().blobId)
    }

    @Test fun uploadsGoInOrderOneLoopPerChat() = runTest {
        val f = files()
        val up = MutableStateFlow(false)
        val device = Device()
        f.add("a.jpg", "image/jpeg", photo)
        f.drain(up, device::upload)
        f.add("b.jpg", "image/jpeg", photo)
        // Every pick kicks it: still one loop.
        f.drain(up, device::upload)
        up.value = true
        runCurrent()
        assertEquals(listOf("a.jpg", "b.jpg"), device.tried)
        assertTrue(f.items.value.all { it.blobId != null })
    }

    @Test fun aRefusalRemovesItAndSaysWhy() = runTest {
        val f = files()
        val device = Device(Outcome.Refused("over 12 MB"))
        val said = ArrayList<Pair<String, String>>()
        backgroundScope.launch { f.refused.collect { said += it } }
        val a = f.add("big.jpg", "image/jpeg", photo)
        f.drain(MutableStateFlow(true), device::upload)
        runCurrent()
        assertEquals(emptyList<PendingFiles.Item>(), f.items.value)
        assertFalse(f.file(a.id).exists())
        assertEquals(listOf("big.jpg" to "over 12 MB"), said)
    }

    @Test fun removedWhileWaitingIsNeverUploaded() = runTest {
        val f = files()
        val up = MutableStateFlow(false)
        val device = Device()
        val a = f.add("a.jpg", "image/jpeg", photo)
        f.drain(up, device::upload)
        runCurrent()
        f.remove(a.id)
        up.value = true
        runCurrent()
        assertEquals(emptyList<String>(), device.tried)
    }

    @Test fun aSentMessageKeepsItsBytesUntilItWent() = runTest {
        val f = files()
        val a = f.add("a.jpg", "image/jpeg", photo)
        f.uploaded(a.id, "blob-a")
        val sent = f.take(listOf(a.id))
        assertEquals(emptyList<PendingFiles.Item>(), f.items.value)
        assertTrue(f.file(a.id).exists())
        // It didn't go: back in the composer, before what's there.
        val b = f.add("b.jpg", "image/jpeg", photo)
        f.restore(sent)
        assertEquals(listOf(a.id, b.id), f.items.value.map { it.id })
        // It went this time.
        f.forget(f.take(listOf(a.id)).map { it.id })
        assertFalse(f.file(a.id).exists())
        assertTrue(f.file(b.id).exists())
    }
}
