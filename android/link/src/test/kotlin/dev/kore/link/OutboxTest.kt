package dev.kore.link

import dev.kore.link.node.Outbox
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class OutboxTest {
    private var now = 0L
    private val box = Outbox<String>(now = { now })

    @Test fun eachEntryExpiresThirtySecondsAfterItWasMade() {
        box.add("a", "A")
        now = 10_000
        box.add("b", "B")
        assertEquals(30_000L, box.nextExpiry())
        now = 29_999
        assertEquals(emptyList<String>(), box.expire())
        now = 30_000
        assertEquals(listOf("a"), box.expire())
        assertEquals(40_000L, box.nextExpiry())
        now = 40_000
        assertEquals(listOf("b"), box.expire())
        assertNull(box.nextExpiry())
    }

    @Test fun drainHandsBackFreshOnesInOrderAndLeavesExpiredOnes() {
        box.add("a", "A")
        now = 20_000
        box.add("b", "B")
        box.add("c", "C")
        now = 35_000
        assertEquals(listOf("b" to "B", "c" to "C"), box.drain())
        assertEquals(setOf("a"), box.ids())
        assertEquals(listOf("a"), box.expire())
    }

    @Test fun anIdQueuesOnce() {
        box.add("a", "A")
        assertFalse(box.add("a", "again"))
        assertEquals(listOf("a" to "A"), box.drain())
    }
}
