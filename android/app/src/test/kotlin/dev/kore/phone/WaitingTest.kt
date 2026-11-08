package dev.kore.phone

import dev.kore.phone.ui.DeviceList
import dev.kore.phone.ui.DeviceList.Cue
import dev.kore.phone.ui.Waiting
import dev.kore.phone.ui.objs
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Link 1.13 `background`: read from the wire's own fixture, and a chat with it counts as working. */
class WaitingTest {
    private fun o(s: String): JsonObject = Json.parseToJsonElement(s).jsonObject

    /** The fixture both sides test against (`Tests/Fixtures/link/v1/delta.background.json`). */
    @Test fun theFixtureParses() {
        val delta = o(File("../../Tests/Fixtures/link/v1/delta.background.json").readText())
        val chat = delta.objs("chats").single()
        assertEquals(Waiting(agents = 2, commands = 1), Waiting.of(chat))
        assertEquals("Waiting on a sub-agent, Waiting on a command", Waiting.of(chat)!!.words)
    }

    @Test fun absentOrZeroIsNothing() {
        assertNull(Waiting.of(o("""{"id":"a"}""")))
        assertNull(Waiting.of(o("""{"id":"a","background":{"agents":0,"commands":0}}""")))
        assertNull(Waiting.of(null))
        assertEquals(Waiting(0, 3), Waiting.of(o("""{"background":{"commands":3}}""")))
        assertEquals("Waiting on a command", Waiting(0, 3).words)
    }

    /** Between turns (idle), background work keeps a chat with the working ones, its symbols on its row. */
    @Test fun anIdleChatWithBackgroundWorkRanksAsWorking() {
        val now = 1_800_000_000_000L
        val snap = o("""{"windows":[{"id":"w","name":"kore","tabs":[{"kind":"chat","chatId":"a"},{"kind":"chat","chatId":"b"}]}],
            "chats":[{"id":"a","title":"Recent","state":"idle","lastAt":${now - 60_000}},
                     {"id":"b","title":"Agents out","state":"idle","lastAt":${now - 3_600_000},"background":{"agents":1,"commands":0}}]}""")
        val none = object : DeviceList.Seen { override fun unread(chatId: String, at: Long?) = false }
        val rows = DeviceList.rows(snap, null, now, none)
        assertEquals(listOf("Agents out", "Recent"), rows.map { it.title })
        assertEquals(Cue.WORKING, rows[0].cue)
        assertEquals(Waiting(1, 0), rows[0].waiting)
        assertNull(rows[1].waiting)
    }

    /** bg-command-cue C: ">_" only while commands alone run and the model is idle or waits on you. */
    @Test fun promptOnlyWhenCommandsAloneRun() {
        assert(Waiting.promptOnly(o("""{"state":"working","running":false,"background":{"commands":1}}""")))
        assert(Waiting.promptOnly(o("""{"state":"needsYou","running":true,"background":{"commands":2}}""")))
        assert(!Waiting.promptOnly(o("""{"state":"working","running":true,"background":{"commands":1}}""")))
        assert(!Waiting.promptOnly(o("""{"state":"working","running":false,"background":{"agents":1,"commands":1}}""")))
        assert(!Waiting.promptOnly(o("""{"state":"idle","running":false}""")))
        assert(!Waiting.promptOnly(null))
    }

    /** The row leads with ">_" and doesn't repeat the command symbol on its line. */
    @Test fun aPromptRowDropsItsCommandSymbol() {
        val now = 1_800_000_000_000L
        val snap = o("""{"windows":[{"id":"w","name":"kore","tabs":[{"kind":"chat","chatId":"a"}]}],
            "chats":[{"id":"a","title":"Build","state":"working","running":false,"lastAt":$now,"background":{"agents":0,"commands":1}}]}""")
        val none = object : DeviceList.Seen { override fun unread(chatId: String, at: Long?) = false }
        val row = DeviceList.rows(snap, null, now, none).single()
        assert(row.prompt)
        assertNull(row.waiting)
        assertEquals(Cue.WORKING, row.cue)
    }
}
