package dev.kore.phone

import dev.kore.phone.ui.LiveWork
import dev.kore.phone.ui.LiveWork.Fold
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A running turn as one live line (its current step), the rest folding into "Worked · N steps"; all of it when it ends. */
class LiveWorkTest {
    private fun o(s: String): JsonObject = Json.parseToJsonElement(s).jsonObject
    private fun user(id: String) = o("""{"id":"$id","kind":"user","text":"go","done":true}""")
    private fun answer(id: String, done: Boolean = true) = o("""{"id":"$id","kind":"answer","text":"ok","done":$done}""")
    private fun tool(id: String, name: String = "Read", summary: String = "src/Chat.swift", done: Boolean = true) =
        o("""{"id":"$id","kind":"tool","done":$done,"tool":{"name":"$name","summary":"$summary"}}""")
    private fun thought(id: String, text: String, done: Boolean = true) = o("""{"id":"$id","kind":"thinking","text":${Json.encodeToString(kotlinx.serialization.json.JsonPrimitive.serializer(), kotlinx.serialization.json.JsonPrimitive(text))},"done":$done}""")

    /** The folds, as short marks: U/A one entry, W(n) a fold of n, L the live line, P pending. */
    private fun shape(f: List<Fold>) = f.joinToString(" ") {
        when (it) {
            is Fold.One -> it.e.toString().let { s -> if ("\"user\"" in s) "U" else if ("\"answer\"" in s) "A" else "1" }
            is Fold.Work -> "W${it.steps.size}" + if (it.open) "+" else ""
            is Fold.Live -> "L"
            Fold.Pending -> "P"
        }
    }

    @Test fun aRunningTurnShowsOnlyItsCurrentStep() {
        val e = listOf(user("u"), thought("t1", "a"), tool("r1"), tool("r2"), thought("t2", "b"), tool("b1", "Bash", "git status", done = false))
        assertEquals("U W4 L", shape(LiveWork.fold(e, emptySet(), running = true)))
        // One step before it: folded too, so the turn is one line while it runs.
        assertEquals("U W1 L", shape(LiveWork.fold(e.take(3), emptySet(), running = true)))
        assertEquals("U L", shape(LiveWork.fold(e.take(2), emptySet(), running = true)))
        // The fold opens here, the current step still its one line.
        assertEquals("U W4+ 1 1 1 1 L", shape(LiveWork.fold(e, setOf("t1"), running = true)))
        // The owner's case: one finished step and the turn still going.
        assertEquals("U L", shape(LiveWork.fold(listOf(user("u"), tool("ts", "ToolSearch")), emptySet(), running = true)))
    }

    @Test fun theEndedTurnFoldsWhole() {
        val e = listOf(user("u"), thought("t1", "a"), tool("r1"), tool("r2"), thought("t2", "b"), tool("b1"))
        assertEquals("U W5", shape(LiveWork.fold(e, emptySet(), running = false)))
        assertEquals("U W5 A", shape(LiveWork.fold(e + answer("a"), emptySet(), running = false)))
        // A lone step stays a row of its own, as before.
        assertEquals("U 1 A", shape(LiveWork.fold(listOf(user("u"), tool("r"), answer("a")), emptySet(), running = false)))
    }

    @Test fun aTurnWithNothingOnScreenYetSaysSo() {
        assertEquals("U P", shape(LiveWork.fold(listOf(user("u")), emptySet(), running = true)))
        // A streaming answer moves by itself: no spinner line under it.
        assertEquals("U A", shape(LiveWork.fold(listOf(user("u"), answer("a", done = false)), emptySet(), running = true)))
        assertEquals("U", shape(LiveWork.fold(listOf(user("u")), emptySet(), running = false)))
    }

    @Test fun aLineIsAShortNameAndTarget() {
        assertEquals(LiveWork.Line("Read", "Chat.swift"), LiveWork.line(tool("r", "Read", "Sources/KoreUI/Chat.swift")))
        assertEquals(LiveWork.Line("Bash", "git status"), LiveWork.line(tool("b", "Bash", "git status")))
        assertEquals(LiveWork.Line("shell", "ls -la src/"), LiveWork.line(tool("x", "shell", "ls -la src/")))
        assertEquals("Now the gate", LiveWork.line(thought("t", "First the link.\n\nNow the gate\n")).what)
        assertEquals("Thinking…", LiveWork.line(thought("t", "", done = false)).what)
        assertEquals(LiveWork.Line("Agent", "Scout"), LiveWork.line(o("""{"id":"g","kind":"agent","agent":{"name":"Scout","status":"running"}}""")))
        assertNull(LiveWork.target("  "))
    }
}
