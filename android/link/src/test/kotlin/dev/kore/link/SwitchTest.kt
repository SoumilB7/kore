package dev.kore.link

import dev.kore.link.net.ByteConn
import dev.kore.link.net.Tailnet
import dev.kore.link.net.TailnetNode
import dev.kore.link.node.TailnetSwitch
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Starts and stops in turn, on real threads: a blocking stop that lands after a newer start must
 * not leave the tailnet off while the app thinks it's on. Latches, not sleeps.
 */
class SwitchTest {
    private val pool = Executors.newFixedThreadPool(4)
    private val io = pool.asCoroutineDispatcher()

    @After fun down() = pool.shutdownNow().let { }

    /** A tailnet whose stop blocks until [release]; it records what ran, in order. */
    private class Slow : Tailnet {
        val log: MutableList<String> = Collections.synchronizedList(mutableListOf())
        @Volatile var on = false
        val stopping = CountDownLatch(1)
        val release = CountDownLatch(1)
        var failNext = false

        override fun start() {
            if (failNext) { failNext = false; throw IllegalStateException("keystore busy") }
            log += "start"
            on = true
        }
        override fun stop() {
            log += "stop"
            stopping.countDown()
            check(release.await(5, TimeUnit.SECONDS))
            on = false
            log += "stopped"
        }
        override fun state() = if (on) Tailnet.RUNNING else "Stopped"
        override fun authUrl(): String? = null
        override fun self(): TailnetNode? = null
        override fun peers() = emptyList<TailnetNode>()
        override fun whois(ip: String): TailnetNode? = null
        override fun dial(address: String, port: Int, timeoutMs: Long): ByteConn = error("no")
        override fun logout() { on = false; log += "logout" }
    }

    private fun CountDownLatch.sure() = check(await(5, TimeUnit.SECONDS)) { "timed out" }

    @Test fun aStopThatLandsAfterANewerStartIsUndone() = runBlocking {
        val t = Slow()
        val sw = TailnetSwitch(t, io)
        sw.set(true)
        val stop = launch(io) { sw.set(false) }
        t.stopping.sure()
        // Back on screen while the stop still blocks: wanted up.
        val again = async(io, CoroutineStart.UNDISPATCHED) { sw.set(true) }
        t.release.countDown()
        stop.join()
        again.await()
        assertEquals(listOf("start", "stop", "stopped", "start"), t.log.toList())
        assertTrue(t.on)
        assertTrue(sw.up)
    }

    @Test fun manyInterleavedCallsEndAsTheLastOneSaid() = runBlocking {
        val t = Slow().apply { release.countDown() }
        val sw = TailnetSwitch(t, io)
        repeat(50) { i ->
            val jobs = (0 until 8).map { k -> launch(io) { sw.set((i + k) % 2 == 0) } }
            jobs.forEach { it.join() }
            // Whatever order they ran in, the switch's idea matches the tailnet's.
            assertEquals("round $i", t.on, sw.up)
            sw.set(i % 2 == 1)
            assertEquals("round $i", i % 2 == 1, t.on)
        }
        // Never two starts or two stops in a row: each ran in turn.
        val runs = t.log.filter { it != "stopped" }
        assertTrue(runs.zipWithNext().none { (a, b) -> a == b })
    }

    @Test fun cancellingACallerNeverCutsAStopInHalf() = runBlocking {
        val t = Slow()
        val sw = TailnetSwitch(t, io)
        sw.set(true)
        val stop = launch(io) { sw.set(false) }
        t.stopping.sure()
        stop.cancel()
        t.release.countDown()
        stop.join()
        sw.settle()
        assertFalse(t.on)
        assertFalse(sw.up)
    }

    @Test fun aFailedStartThrowsStaysDownAndTheNextOneStarts() = runBlocking {
        val t = Slow().apply { failNext = true }
        val sw = TailnetSwitch(t, io)
        try {
            sw.set(true)
            fail("no throw")
        } catch (e: IllegalStateException) {
            assertEquals("keystore busy", e.message)
        }
        assertFalse(sw.up)
        sw.settle()
        assertTrue(sw.up)
        assertEquals(listOf("start"), t.log.toList())
    }

    @Test fun leaveLogsOutThenFollowsWhatsWanted() = runBlocking {
        val t = Slow().apply { release.countDown() }
        val sw = TailnetSwitch(t, io)
        sw.set(true)
        sw.want(false)
        sw.logout()
        assertFalse(sw.up)
        assertEquals(listOf("start", "logout"), t.log.toList())
    }
}
