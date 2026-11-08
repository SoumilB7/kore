package dev.kore.link

import dev.kore.link.log.PhoneLog
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** The phone's log: content-free lines in the Mac's shape, one day kept, never piling up. */
class PhoneLogTest {
    @get:Rule val tmp = TemporaryFolder()
    private val day = PhoneLog.DAY_MS
    private val t0 = 1_794_000_000_000L

    @Test fun onlyKnownKeysAndNoTokens() {
        val line = PhoneLog.line(t0, "info", "link", arrayOf("node" to "7f3a91c2", "text" to "hello there", "reason" to "bye unknown", "code" to "A".repeat(40)))
        assertTrue(line, line.endsWith("info link node=7f3a91c2 reason=\"bye unknown\" code=<redacted>"))
        assertFalse(line.contains("hello"))
    }

    @Test fun aCrashIsItsClassAndFramesNeverItsMessage() {
        var now = t0
        val log = PhoneLog(tmp.root) { now }
        val e = IllegalStateException("the user's secret words", RuntimeException("x"))
        log.crash(e, "main")
        val text = log.read()
        assertTrue(text, text.contains("error crash class=java.lang.IllegalStateException cause=java.lang.RuntimeException thread=main at="))
        assertTrue(text.contains("PhoneLogTest.aCrashIsItsClassAndFramesNeverItsMessage:"))
        assertFalse(text.contains("secret"))
    }

    @Test fun oneDayIsKeptAndPrunedOnceADay() {
        var now = t0
        val log = PhoneLog(tmp.root) { now }
        log.info("start")
        val first = tmp.root.resolve(PhoneLog.name(t0))
        first.setLastModified(t0)
        now = t0 + day / 2
        log.info("later")
        assertTrue(first.exists())
        // A day and more later: the next line prunes first.
        now = t0 + day + 60_000
        log.info("next day")
        assertFalse(first.exists())
        assertTrue(log.read().contains("next day"))
    }

    @Test fun aFileStopsAtItsCapAndAllAtTheirs() {
        var now = t0
        val log = PhoneLog(tmp.root) { now }
        repeat(20_000) { log.info("link", "node" to "7f3a91c2", "state" to "up", "ms" to it) }
        assertTrue(tmp.root.resolve(PhoneLog.name(t0)).length() <= PhoneLog.FILE_MAX + 200)
        // Older days over the total go oldest first.
        repeat(3) { i -> tmp.root.resolve(PhoneLog.name(t0 - (i + 1) * 3_600_000L * 8)).writeText("x".repeat(400_000)) }
        log.prune(now)
        assertTrue(tmp.root.listFiles()!!.sumOf { it.length() } <= PhoneLog.ALL_MAX)
    }

    @Test fun aReadSendsTheNewestWholeLines() {
        var now = t0
        val log = PhoneLog(tmp.root) { now }
        repeat(100) { log.info("tick", "n" to it) }
        val tail = log.read(max = 300)
        assertTrue(tail.length <= 300)
        assertTrue(tail.endsWith("info tick n=99\n"))
        assertTrue(tail.lines().first().contains("info tick n="))
        assertEquals(PhoneLog.name(t0), PhoneLog.name(t0 + 1))
    }
}
