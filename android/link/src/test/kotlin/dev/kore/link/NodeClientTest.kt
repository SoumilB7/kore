package dev.kore.link

import dev.kore.link.net.NetFailure
import dev.kore.link.node.NodeClient
import dev.kore.link.node.NodeDialer
import dev.kore.link.node.NodeMachine
import dev.kore.link.node.NodeMachine.State
import dev.kore.link.node.PeerOffline
import dev.kore.link.node.RaiseSigner
import dev.kore.link.node.SingleFlight
import dev.kore.link.trust.Raise
import java.util.Base64
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class NodeClientTest {
    private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.content
    private fun JsonObject.cmd() = this["cmd"] as JsonObject

    /** A node client whose dials are answered, in order, by [plan] (a link, or a failure). */
    private class Rig(scope: TestScope, plan: List<() -> Any>, signer: RaiseSigner? = null) {
        val clock = { scope.testScheduler.currentTime }
        val links = mutableListOf<FakeLink>()
        val dials = mutableListOf<Long>()
        private val queue = ArrayDeque(plan)
        val client = NodeClient(mac(), scope.backgroundScope, NodeDialer { device, _, enrolling ->
            dials += clock()
            when (val next = (queue.removeFirstOrNull() ?: { NetFailure("timeout") })()) {
                is FakeLink -> next.also { links += it }
                is Throwable -> throw next
                "enroll" -> { enrolling(); CompletableDeferred<Unit>().await(); error("never") }
                else -> error("bad plan")
            }
        }, clock = clock, raiseSigner = signer, machineRandom = object : kotlin.random.Random() {
            override fun nextBits(bitCount: Int) = 0
            override fun nextDouble() = 0.5
        })
    }

    private fun TestScope.link() = FakeLink(mac(), { testScheduler.currentTime })

    @Test fun startDialsAndRoutesTheSnapshotAndDeltas() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(listOf("presence"), link.types())
        link.push(buildJsonObject { put("t", "snapshot"); put("rev", 1); put("windows", kotlinx.serialization.json.JsonArray(emptyList())); put("chats", kotlinx.serialization.json.JsonArray(listOf(buildJsonObject { put("id", "c1"); put("title", "one") }))) })
        link.push(buildJsonObject { put("t", "delta"); put("rev", 2); put("chats", kotlinx.serialization.json.JsonArray(listOf(buildJsonObject { put("id", "c2"); put("title", "two") }))) })
        runCurrent()
        val snap = rig.client.snapshot.value!!
        assertEquals("2", snap.s("rev"))
        assertEquals(2, (snap["chats"] as kotlinx.serialization.json.JsonArray).size)
    }

    @Test fun commandsMadeWhileAwayExpireThirtySecondsEachWithOneTimer() = runTest {
        val rig = Rig(this, listOf({ PeerOffline() }))
        val results = mutableListOf<JsonObject>()
        backgroundScope.launch { rig.client.results.collect { results += it } }
        rig.client.start()
        runCurrent()
        assertTrue(rig.client.state.value is State.Away)
        val a = rig.client.send("c1", "hi")
        advanceTimeBy(10_000)
        val b = rig.client.stop("c1")
        assertEquals(setOf(a, b), rig.client.queued.value)
        advanceTimeBy(20_000)
        runCurrent()
        assertEquals(listOf(a), results.map { it.s("id") })
        assertEquals("expired", results.single().s("code"))
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals(listOf(a, b), results.map { it.s("id") })
        assertEquals(emptySet<String>(), rig.client.queued.value)
        // Offline means no timer of its own: one dial only.
        assertEquals(1, rig.dials.size)
    }

    @Test fun queuedCommandsGoOutOnceTheNodeIsBack() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ NetFailure("timeout") }, { link }))
        rig.client.start()
        runCurrent()
        val id = rig.client.send("c1", "hello")
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(listOf(0L, 1_000L), rig.dials)
        assertEquals(State.Up, rig.client.state.value)
        val cmd = link.sent.single { it.s("t") == "cmd" }
        assertEquals(id, cmd.s("id"))
        assertEquals("chat.send", cmd.cmd().s("type"))
        assertEquals(emptySet<String>(), rig.client.queued.value)
    }

    @Test fun openTranscriptsAreFollowedAgainOnTheNextLink() = runTest {
        val first = link()
        val second = link()
        val rig = Rig(this, listOf({ first }, { second }))
        rig.client.start()
        runCurrent()
        rig.client.openTranscript("c1", 40)
        first.drop(null)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals(State.Up, rig.client.state.value)
        assertEquals(listOf("presence", "tx.open"), second.types())
        assertEquals("40", second.sent[1].s("last"))
    }

    @Test fun revokedStopsDialing() = runTest {
        val link = link()
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        link.drop("revoked")
        runCurrent()
        assertEquals(State.Removed, rig.client.state.value)
        rig.client.reconnectNow()
        advanceTimeBy(600_000)
        assertEquals(1, rig.dials.size)
    }

    @Test fun aQuietLinkGetsOneProbeAndIsAbandonedWhenNothingComesBack() = runTest {
        val dead = link()
        val fresh = link()
        val rig = Rig(this, listOf({ dead }, { fresh }))
        rig.client.start()
        runCurrent()
        advanceTimeBy(14_000)
        rig.client.reconnectNow()
        runCurrent()
        assertEquals(listOf("presence"), dead.types())
        advanceTimeBy(2_000)
        rig.client.reconnectNow()
        rig.client.reconnectNow()
        runCurrent()
        assertEquals(1, dead.sent.count { it.s("t") == "cmd" && it.cmd().s("type") == "link.ping" })
        advanceTimeBy(5_100)
        runCurrent()
        assertEquals("abandoned", dead.ended.getCompleted())
        assertEquals(2, rig.dials.size)
        assertEquals(State.Up, rig.client.state.value)
    }

    @Test fun anAnsweredProbeKeepsTheLink() = runTest {
        val link = link()
        link.respond = { m -> if (m.s("t") == "cmd") buildJsonObject { put("t", "result"); put("id", m.s("id")); put("ok", false); put("code", "invalid") } else null }
        val rig = Rig(this, listOf({ link }))
        rig.client.start()
        runCurrent()
        advanceTimeBy(20_000)
        rig.client.reconnectNow()
        advanceTimeBy(6_000)
        runCurrent()
        assertTrue(!link.ended.isCompleted)
        assertEquals(1, rig.dials.size)
    }

    @Test fun raiseSignsTheDigestOverThisLinksBindingAndTheNodesNonce() = runTest {
        val key = dev.kore.link.trust.SoftwareIdentity.fresh()
        val nonce = ByteArray(32) { it.toByte() }
        val link = link()
        link.respond = { m ->
            when {
                m.s("t") == "raise.chal" -> buildJsonObject { put("t", "raise.chal"); put("id", m.s("id")); put("nonce", Base64.getEncoder().encodeToString(nonce)) }
                m.s("t") == "cmd" && m.cmd().s("type") == "raise" -> buildJsonObject { put("t", "result"); put("id", m.s("id")); put("ok", true) }
                else -> null
            }
        }
        val rig = Rig(this, listOf({ link }), signer = { d -> key.sign(d) })
        rig.client.start()
        runCurrent()
        val r = rig.client.raise("chat-7f3a", "auto")
        assertEquals("true", r.s("ok"))
        val raise = link.sent.single { it.s("t") == "cmd" }.cmd()
        assertEquals("chat-7f3a", raise.s("chatId"))
        assertEquals("auto", raise.s("modeId"))
        val digest = Raise.digest(link.binding, nonce, "chat-7f3a", "auto")
        assertTrue(dev.kore.link.trust.IdentityProof.verify(Base64.getDecoder().decode(raise.s("sig")), digest, key.publicKey))
        assertArrayEquals(nonce, Base64.getDecoder().decode(raise.s("nonce")))
    }

    @Test fun noFingerprintIsCancelledAndNothingIsSent() = runTest {
        val link = link()
        link.respond = { m -> if (m.s("t") == "raise.chal") buildJsonObject { put("t", "raise.chal"); put("id", m.s("id")); put("nonce", Base64.getEncoder().encodeToString(ByteArray(32))) } else null }
        val rig = Rig(this, listOf({ link }), signer = { null })
        rig.client.start()
        runCurrent()
        assertEquals("cancelled", rig.client.raise("c", "auto").s("code"))
        assertEquals(0, link.sent.count { it.s("t") == "cmd" })
    }

    @Test fun aRefusedChallengeComesBackAsItsResult() = runTest {
        val link = link()
        link.respond = { m -> if (m.s("t") == "raise.chal") buildJsonObject { put("t", "result"); put("id", "raise.chal:" + m.s("id")); put("ok", false); put("code", "denied.raiseMode") } else null }
        val rig = Rig(this, listOf({ link }), signer = { ByteArray(1) })
        rig.client.start()
        runCurrent()
        assertEquals("denied.raiseMode", rig.client.raise("c", "bypass").s("code"))
    }

    @Test fun oneFingerprintPromptAtATime() = runTest {
        val gate = CompletableDeferred<ByteArray?>()
        var asked = 0
        val one = SingleFlight { asked++; gate.await() }
        val first = async { one.sign(ByteArray(32)) }
        runCurrent()
        assertEquals(null, one.sign(ByteArray(32)))
        gate.complete(byteArrayOf(1))
        assertArrayEquals(byteArrayOf(1), first.await())
        assertEquals(1, asked)
        assertTrue(one.sign(ByteArray(32)) != null)
    }

    @Test fun anEnrollingDialWaitsForAllow() = runTest {
        val rig = Rig(this, listOf({ "enroll" }))
        rig.client.start()
        runCurrent()
        assertEquals(State.AwaitingAllow, rig.client.state.value)
    }

    @Test fun uploadFramesUseLinkOneElevenShapes() {
        val frames = NodeClient.uploadFrames("u1", "a.png", "image/png", ByteArray(NodeClient.UPLOAD_CHUNK + 1))
        assertEquals(4, frames.size)
        assertTrue(frames[0].startsWith("{\"t\":\"blob.put.begin\",\"uploadId\":\"u1\""))
        assertTrue(frames[2].contains("\"index\":1"))
        assertEquals("{\"t\":\"blob.put.end\",\"uploadId\":\"u1\"}", frames[3])
    }
}
