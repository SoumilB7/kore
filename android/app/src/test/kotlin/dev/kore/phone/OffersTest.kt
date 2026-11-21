package dev.kore.phone

import dev.kore.phone.ui.Offers
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The menus follow what each device's welcome says it does, never its kind. */
class OffersTest {
    private fun caps(json: String) = Offers.caps(Json.parseToJsonElement(json).jsonObject)
    private val mac = caps("""{"t":"welcome","caps":["tx","attn","blob","commands","control","raise","history","diff","group","board"]}""")
    private val box = caps("""{"t":"welcome","caps":["tx","attn","commands","control","box","device","history","blob","diff"]}""")

    @Test fun aMacsWindowsOfferGroupsAndBoards() {
        assertEquals(listOf("Rename…", "Show on the Mac", "Group", "Attach to board", "Close tab"), Offers.tabItems(mac, box = false, hasBoards = true, closable = true))
        assertEquals(listOf("Rename…", "Show on the Mac", "Group"), Offers.tabItems(mac, box = false, hasBoards = false, closable = false))
        assertEquals(listOf("Board", "Reopen closed tab"), Offers.newItems(mac, canReopen = true))
    }

    @Test fun aBoxsWindowsOfferTabsOnly() {
        assertEquals(listOf("Rename…", "Close tab"), Offers.tabItems(box, box = true, hasBoards = true, closable = true))
        assertEquals(listOf("Reopen closed tab"), Offers.newItems(box, canReopen = true))
        assertFalse(Offers.groups(box))
        assertFalse(Offers.boards(box))
    }

    /** The capability drives it: a box that said it does groups would get them. */
    @Test fun theWelcomeNotTheKindDecides() {
        assertTrue("Group" in Offers.tabItems(box + "group", box = true, hasBoards = false, closable = false))
        assertFalse("Group" in Offers.tabItems(mac - "group", box = false, hasBoards = false, closable = false))
        assertEquals(emptySet<String>(), Offers.caps(null))
    }

    /** A Mac from before the caps said them still offers its groups and boards; an old box doesn't. */
    @Test fun anOlderMacKeepsItsGroupsAndBoards() {
        val older = mac - "group" - "board"
        assertEquals(listOf("Rename…", "Show on the Mac", "Group", "Attach to board"), Offers.tabItems(older, box = false, hasBoards = true, closable = false))
        assertEquals(listOf("Board"), Offers.newItems(older, canReopen = false))
        val olderBox = caps("""{"t":"welcome","caps":["tx","attn","commands","control","box","history"]}""")
        assertEquals(listOf("Rename…"), Offers.tabItems(olderBox, box = true, hasBoards = true, closable = false))
        assertEquals(emptyList<String>(), Offers.newItems(olderBox, canReopen = false))
        // No welcome yet: nothing is offered.
        assertFalse(Offers.groups(emptySet()) || Offers.boards(emptySet()))
    }

    @Test fun attachSaysWhyWhenFilesCantGo() {
        assertNull(Offers.uploadsOff(box, control = true, box = true, name = "mybox"))
        assertNull(Offers.uploadsOff(mac, control = true, box = false, name = "MacBook"))
        val old = box - "blob"
        assertEquals("Files need a newer kore-host on mybox.", Offers.uploadsOff(old, control = true, box = true, name = "mybox"))
        assertEquals("This phone can only watch mybox.", Offers.uploadsOff(old - "history", control = false, box = true, name = "mybox"))
        assertEquals("Files need a newer Kore on MacBook.", Offers.uploadsOff(mac - "blob", control = true, box = false, name = "MacBook"))
    }

    /** A cold start with no link: the menus keep the device's last caps; 📎 says it isn't connected. */
    @Test fun beforeTheFirstWelcomeTheLastCapsHold() {
        assertEquals(mac, Offers.caps(null, mac))
        assertEquals(listOf("Rename…", "Show on the Mac", "Group", "Attach to board"), Offers.tabItems(Offers.caps(null, mac), box = false, hasBoards = true, closable = false))
        assertEquals(listOf("Board"), Offers.newItems(Offers.caps(null, mac), canReopen = false))
        // Never seen: nothing assumed.
        assertEquals(emptySet<String>(), Offers.caps(null, null))
        // A welcome wins over what was kept.
        assertEquals(box, Offers.caps(Json.parseToJsonElement("""{"t":"welcome","caps":["tx","attn","commands","control","box","device","history","blob","diff"]}""").jsonObject, mac))
        assertEquals("Not connected to mybox.", Offers.uploadsOff(box, control = true, box = true, name = "mybox", welcomed = false))
        assertEquals("Not connected to MacBook.", Offers.uploadsOff(emptySet(), control = false, box = false, name = "MacBook", welcomed = false))
        assertNull(Offers.uploadsOff(mac, control = true, box = false, name = "MacBook", welcomed = true))
    }
}
