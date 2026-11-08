package dev.kore.link

import dev.kore.link.trust.Device
import dev.kore.link.trust.DeviceBook
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A Mac's directory, whole, on the phone's book: boxes it stops listing go, another Mac's stay. */
class DeviceBookTest {
    private val self = UUID.randomUUID()
    private val macA = mac(UUID.randomUUID())
    private val macB = mac(UUID.randomUUID())
    private val box1 = box(UUID.randomUUID())
    private val box2 = box(UUID.randomUUID())

    @Test fun aBoxTheMacNoLongerListsLeavesTheBook() {
        val book = DeviceBook(listOf(macA))
        book.applyDirectory(macA.id, self, listOf(macA, box1, box2))
        book.applyDirectory(macA.id, self, listOf(macA, box2))
        assertNull(book.get(box1.id))
        assertEquals(setOf(macA.id), book.get(box2.id)?.via)
    }

    @Test fun aBoxAnotherMacStillListsStays() {
        val book = DeviceBook(listOf(macA, macB))
        book.applyDirectory(macA.id, self, listOf(macA, box1))
        book.applyDirectory(macB.id, self, listOf(macB, box1))
        book.applyDirectory(macA.id, self, listOf(macA))
        assertEquals(setOf(macB.id), book.get(box1.id)?.via)
        book.applyDirectory(macB.id, self, listOf(macB))
        assertNull(book.get(box1.id))
    }

    @Test fun aBoxKeptFromBeforeTheNoteCountsAsTheSendersAndAnotherMacsIsLeftAlone() {
        val book = DeviceBook(listOf(macA, macB, box1, box2.copy(via = setOf(macB.id))))
        book.applyDirectory(macA.id, self, listOf(macA))
        assertNull(book.get(box1.id))
        assertEquals(setOf(macB.id), book.get(box2.id)?.via)
    }

    @Test fun theNoteSurvivesTheFileAndARecordPutAndStaysOffTheWire() {
        var saved: List<Device> = emptyList()
        val book = DeviceBook(listOf(macA)) { saved = it }
        book.applyDirectory(macA.id, self, listOf(macA, box1))
        book.put(box1.withNodeKey("nodekey:new"))
        assertEquals(setOf(macA.id), book.get(box1.id)?.via)
        val disk = saved.first { it.id == box1.id }.toJson(local = true)
        assertEquals(setOf(macA.id), Device.fromJson(disk)?.via)
        assertNull(box1.copy(via = setOf(macA.id)).toJson()["via"])
        assertEquals(box1, box1.copy(via = setOf(macA.id)))
    }
}
