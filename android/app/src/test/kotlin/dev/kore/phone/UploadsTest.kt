package dev.kore.phone

import dev.kore.phone.ui.Uploads
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A pick of several photos: the message's 10, 12 MB a file, 256 MB an hour, and one line for what didn't come. */
class UploadsTest {
    @Test fun thePickerPicksWhatTheMessageHasRoomFor() {
        assertEquals(10, Uploads.room(0))
        assertEquals(3, Uploads.room(7))
        assertEquals(0, Uploads.room(10))
        assertEquals(0, Uploads.room(12))
    }

    @Test fun anHoursBytesAreCountedAndFreedAsTheyAge() {
        val mb = 1024L * 1024
        val budget = Uploads.Budget(perHour = 30 * mb)
        budget.spend(12 * mb, now = 0)
        budget.spend(12 * mb, now = 60_000)
        assertTrue(budget.fits(6 * mb, now = 120_000))
        assertFalse(budget.fits(7 * mb, now = 120_000))
        // The first upload is an hour old: its 12 MB are free again, the second's aren't.
        assertTrue(budget.fits(18 * mb, now = 3_600_000))
        assertFalse(budget.fits(19 * mb, now = 3_600_000))
        assertTrue(budget.fits(30 * mb, now = 3_660_000))
    }

    @Test fun aDevicesRefusalInAFewWords() {
        assertEquals("over 12 MB", Uploads.refused("tooLarge", "Files can be at most 12 MB."))
        assertEquals("busy there, try again", Uploads.refused("busy", "Too many uploads at once."))
        assertEquals("past this hour's 256 MB", Uploads.refused("rateLimited", null))
        assertEquals("A bad SHA-256", Uploads.refused("invalid", "A bad SHA-256."))
        assertEquals("no answer", Uploads.refused(null, null))
    }

    @Test fun whatDidntComeIsOneLine() {
        assertNull(Uploads.refusedLine(emptyList()))
        assertEquals("Not attached: big.heic, over 12 MB", Uploads.refusedLine(listOf("big.heic" to Uploads.tooBig())))
        assertEquals("2 not attached: a.jpg, more than 10 in a message; b.png, couldn't be read",
            Uploads.refusedLine(listOf("a.jpg" to Uploads.tooMany(), "b.png" to Uploads.unread())))
    }
}
