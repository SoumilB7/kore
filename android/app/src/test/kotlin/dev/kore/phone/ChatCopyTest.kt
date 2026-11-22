package dev.kore.phone

import dev.kore.phone.ui.ChatCopy
import dev.kore.phone.ui.ChatCopy.Dev
import dev.kore.phone.ui.ChatCopy.Route
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Test

/** Which Mac runs a copy the phone asks for, and the ends it names. */
class ChatCopyTest {
    private val mac = Dev("m", "MacBook", true, emptyList())
    private val other = Dev("m2", "Studio", true, emptyList())
    private val box = Dev("b", "mybox", false, listOf("m"))
    private val box2 = Dev("b2", "devbox", false, listOf("m"))
    private val strange = Dev("b3", "lab", false, listOf("m2"))
    private val unknown = Dev("b4", "new", false, emptyList())

    @Test fun theMacOnEitherEndRunsIt() {
        assertEquals(Route.Via("m"), ChatCopy.route(mac, mac))
        assertEquals(Route.Via("m"), ChatCopy.route(mac, box))
        assertEquals(Route.Via("m"), ChatCopy.route(box, mac))
    }

    @Test fun boxToBoxGoesThroughTheirMac() {
        assertEquals(Route.Via("m"), ChatCopy.route(box, box2))
        assertEquals(Route.Via("m"), ChatCopy.route(box, box))
        // Told of by different Macs: the source's, and that Mac says if it doesn't know the other.
        assertEquals(Route.Via("m"), ChatCopy.route(box, strange))
    }

    @Test fun whatNoMacCanRunIsALine() {
        assertEquals(Route.No("Copying between two Macs isn't offered"), ChatCopy.route(mac, other))
        assertEquals(Route.No("lab isn't one of MacBook's boxes"), ChatCopy.route(mac, strange))
        assertEquals(Route.No("lab isn't one of MacBook's boxes"), ChatCopy.route(strange, mac))
        assertEquals(Route.No("No Mac knows new to copy from it"), ChatCopy.route(unknown, Dev("b5", "x", false, emptyList())))
    }

    @Test fun anEndOnTheRunningMacNamesNoDevice() {
        val clip = ChatCopy.Clip("b", "mybox", "w_box", "c1", null, "claude", "Repos")
        val copy = ChatCopy.command(clip, "m", "w_1", "m")["copy"] as JsonObject
        assertEquals("""{"device":"b","windowId":"w_box","chatId":"c1"}""", copy["from"].toString())
        assertEquals("""{"windowId":"w_1"}""", copy["to"].toString())
        val back = ChatCopy.command(ChatCopy.Clip("m", "MacBook", "w_1", null, "s1", "codex", "Repos"), "b", "w_box", "m")["copy"] as JsonObject
        assertEquals("""{"windowId":"w_1","sessionId":"s1"}""", back["from"].toString())
        assertEquals("""{"device":"b","windowId":"w_box"}""", back["to"].toString())
    }
}
