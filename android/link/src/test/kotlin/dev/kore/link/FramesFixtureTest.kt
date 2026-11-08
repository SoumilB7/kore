package dev.kore.link

import dev.kore.link.Fixtures.a
import dev.kore.link.Fixtures.hex
import dev.kore.link.Fixtures.o
import dev.kore.link.Fixtures.s
import dev.kore.link.net.NetFrame
import dev.kore.link.net.NetFrameDecoder
import dev.kore.link.net.NetFrameError
import dev.kore.link.net.NetScheduler
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.long
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

/** frames.json: every valid frame encodes and decodes byte for byte; every invalid one fails with its code. */
class FramesFixtureTest {
    private val f = Fixtures.json("frames.json")

    @Test fun limitsMatch() {
        val l = f.o("limits")
        assertEquals(NetFrame.HEADER_SIZE, (l["headerSize"] as JsonPrimitive).int)
        assertEquals(NetFrame.MAX_PAYLOAD, (l["maxPayload"] as JsonPrimitive).int)
        assertEquals(NetFrame.MAX_MESSAGE, (l["maxMessage"] as JsonPrimitive).int)
        assertEquals(NetFrame.MAX_PARTIAL_STREAMS, (l["maxPartialStreams"] as JsonPrimitive).int)
        assertEquals(NetFrame.PRE_AUTH_MAX_FRAME, (l["preAuthMaxFrame"] as JsonPrimitive).int)
    }

    @Test fun validFramesEncodeAndDecode() {
        for (v in f.a("valid")) {
            val queue = NetFrame.Queue.of((v["queue"] as JsonPrimitive).int)!!
            val stream = (v["stream"] as JsonPrimitive).long
            val payload = hex(v.s("payload"))
            val frame = NetFrame(queue, (v["flags"] as JsonPrimitive).int and 1 != 0, stream, payload)
            assertEquals(v.s("name"), v.s("encoded"), frame.encoded().hex())
            val out = NetFrameDecoder(preAuth = false).feed(hex(v.s("encoded")))
            assertEquals(1, out.size)
            assertEquals(queue, out[0].queue)
            assertEquals(stream, out[0].stream)
            assertArrayEquals(payload, out[0].payload)
        }
    }

    @Test fun fragmentsReassembleAroundAnInteractiveMessage() {
        val frag = f.o("fragmented")
        val d = NetFrameDecoder(preAuth = false)
        // Byte by byte: the decoder holds partial frames.
        val bytes = (frag["frames"] as kotlinx.serialization.json.JsonArray).flatMap { hex((it as JsonPrimitive).content).toList() }
        val got = bytes.flatMap { d.feed(byteArrayOf(it)) }
        val want = frag.a("messages")
        assertEquals(want.size, got.size)
        for ((m, w) in got.zip(want)) {
            assertEquals((w["queue"] as JsonPrimitive).int, m.queue.wire)
            assertEquals((w["stream"] as JsonPrimitive).long, m.stream)
            assertEquals(w.s("payload"), m.payload.hex())
        }
        assertEquals(31L, d.takeStreamBytes())
    }

    @Test fun invalidFramesFailWithTheirCode() {
        for (v in f.a("invalid")) {
            val d = NetFrameDecoder(preAuth = (v["preAuth"] as JsonPrimitive).content == "true")
            try {
                d.feed(hex(v.s("encoded")))
                fail("${v.s("name")}: no error")
            } catch (e: NetFrameError) {
                assertEquals(v.s("name"), v.s("error"), e.code)
            }
        }
    }

    @Test fun schedulerPutsInteractiveAheadAndSplitsBigMessages() {
        val s = NetScheduler(credit = 1L shl 20)
        s.enqueue(ByteArray(NetFrame.MAX_PAYLOAD * 2 + 5), NetFrame.Queue.STREAM, 3)
        val first = s.next()!!
        assertEquals(NetFrame.Queue.STREAM, first.queue)
        assertEquals(true, first.more)
        s.enqueue("{\"cmd\":\"stop\"}".toByteArray(), NetFrame.Queue.INTERACTIVE, 5)
        assertEquals(NetFrame.Queue.INTERACTIVE, s.next()!!.queue)
        val rest = generateSequence { s.next() }.toList()
        assertEquals(listOf(true, false), rest.map { it.more })
        assertEquals(5, rest.last().payload.size)
    }

    @Test fun streamFramesWaitForCredit() {
        val s = NetScheduler(credit = 10)
        s.enqueue(ByteArray(25), NetFrame.Queue.STREAM, 3)
        assertEquals(10, s.next()!!.payload.size)
        assertEquals(null, s.next())
        s.grant(100)
        assertEquals(15, s.next()!!.payload.size)
    }
}
