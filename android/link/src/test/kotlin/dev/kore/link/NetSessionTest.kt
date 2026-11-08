package dev.kore.link

import dev.kore.link.Fixtures.b64
import dev.kore.link.Fixtures.hex
import dev.kore.link.Fixtures.o
import dev.kore.link.Fixtures.s
import dev.kore.link.net.NetClientSession
import dev.kore.link.net.NetClientSession.State
import dev.kore.link.net.NetControl
import dev.kore.link.net.NetFrame
import dev.kore.link.net.NetFrameDecoder
import dev.kore.link.net.NetLocal
import dev.kore.link.net.NetPeerFacts
import dev.kore.link.trust.Device
import dev.kore.link.trust.IdentityProof
import dev.kore.link.trust.NodeKind
import dev.kore.link.trust.SoftwareIdentity
import java.util.UUID
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The client half of the handshake against a server played here with the fixture keys (bind.json). */
class NetSessionTest {
    private val bind = Fixtures.json("bind.json")
    private val tn = bind.o("tailnet")
    private val clientId = UUID.fromString(bind.o("client").s("device"))
    private val serverId = UUID.fromString(bind.o("server").s("device"))
    private val clientKey = SoftwareIdentity.fromScalar(hex(bind.o("client").s("privateKey")))
    private val serverKey = SoftwareIdentity.fromScalar(hex(bind.o("server").s("privateKey")))
    private val mac = Device(serverId, "MacBook", NodeKind.MAC, serverKey.publicKey, listOf(tn.s("nodeKeyS")), "macbook.tail.ts.net.")

    private fun session(
        record: Device? = mac,
        sameUser: Boolean = true,
        peerKey: String = tn.s("nodeKeyS"),
        cursors: JsonObject? = null,
        enroll: NetControl.Enroll? = null,
    ) = NetClientSession(
        NetLocal(clientId, tn.s("nodeKeyC"), clientKey), "tailnet", NetPeerFacts(peerKey, sameUser), record?.id, record,
        ticket = byteArrayOf(1, 2, 3), cursors = cursors, enroll = enroll, random = { hex(bind.s("nonceC")) },
    )

    private fun frame(m: NetControl) = NetFrame(NetFrame.Queue.INTERACTIVE, false, 0, m.encoded()).encoded()
    private fun challenge(device: UUID = serverId) = frame(NetControl.Challenge("tailnet", device, hex(bind.s("nonceS"))))
    private fun welcome(sig: ByteArray = b64(tn.s("sigS")), directory: List<JsonObject>? = null) =
        frame(NetControl.Welcome(sig, 1 shl 20, byteArrayOf(9), true, listOf("read", "ask"), 3, directory))

    /** Control messages the session queued, decoded. */
    private fun sent(s: NetClientSession): List<NetControl> {
        val d = NetFrameDecoder(preAuth = false)
        return generateSequence { s.nextFrame() }.flatMap { d.feed(it) }.map { NetControl.decode(it.payload) }.toList()
    }

    @Test fun helloIsSignedOverTheFixtureBindingAndWelcomeEstablishes() {
        val s = session(cursors = buildJsonObject { put("attn", buildJsonObject { put("aid", 4) }) })
        s.receive(challenge())
        assertEquals(State.HelloSent, s.state)
        assertEquals(tn.s("B"), s.binding!!.digest.joinToString("") { "%02x".format(it) })
        val hello = sent(s).single() as NetControl.Hello
        assertTrue(IdentityProof.verify(hello.sig, s.binding!!.digest, clientKey.publicKey))
        assertArrayEquals(byteArrayOf(1, 2, 3), hello.ticket)
        assertEquals(null, hello.enroll)
        s.receive(welcome())
        val peer = (s.state as State.Established).peer
        assertEquals(listOf("read", "ask"), peer.abilities)
        assertEquals(mac, peer.record)
        // The cursors go after the welcome, never in the hello.
        assertEquals(NetControl.Resume(buildJsonObject { put("attn", buildJsonObject { put("aid", 4) }) }).encoded().decodeToString(),
            sent(s).single().encoded().decodeToString())
    }

    @Test fun aWelcomeSignedByAnotherKeyEndsIt() {
        val s = session()
        s.receive(challenge())
        sent(s)
        s.receive(welcome(sig = b64(tn.s("sigC"))))
        assertEquals(State.Closed("proof"), s.state)
        assertEquals(NetControl.Bye("proof"), sent(s).single())
    }

    @Test fun aChallengeFromAnotherDeviceEndsIt() {
        val s = session()
        s.receive(challenge(device = UUID.randomUUID()))
        assertEquals(State.Closed("proof"), s.state)
    }

    @Test fun theServersByeEndsTheHandshake() {
        val s = session()
        s.receive(challenge())
        s.receive(frame(NetControl.Bye("unknown")))
        assertEquals(State.Closed("bye unknown"), s.state)
    }

    @Test fun aNewNodeKeyIsKeptOnlyForTheOwnUser() {
        val rotated = session(peerKey = "nodekey:new", sameUser = true).apply { receive(challenge()) }
        // B is over the node key this side's WhoIs saw: the fixture's sigS no longer fits, so sign it here.
        rotated.receive(welcome(sig = serverKey.sign(rotated.binding!!.digest)))
        assertEquals(listOf(tn.s("nodeKeyS"), "nodekey:new"), (rotated.state as State.Established).peer.record.nodeKeys)
        val stranger = session(peerKey = "nodekey:new", sameUser = false).apply { receive(challenge()) }
        stranger.receive(welcome(sig = serverKey.sign(stranger.binding!!.digest)))
        assertEquals(State.Closed("proof"), stranger.state)
    }

    @Test fun firstContactPinsTheMacFromItsDirectory() {
        val enroll = NetControl.Enroll("Pixel 9", clientKey.publicKey, "Pixel 9")
        val s = session(record = null, peerKey = tn.s("nodeKeyS"), enroll = enroll)
        s.receive(challenge())
        assertEquals("Pixel 9", (sent(s).single() as NetControl.Hello).enroll!!.name)
        val dir = listOf(mac.copy(nodeKeys = emptyList()).toJson())
        s.receive(welcome(directory = dir))
        val pinned = (s.state as State.Established).peer.record
        assertEquals(serverId, pinned.id)
        assertEquals(listOf(tn.s("nodeKeyS")), pinned.nodeKeys)
    }

    @Test fun firstContactTakesOnlyAMac() {
        val s = session(record = null, enroll = NetControl.Enroll("Pixel 9", clientKey.publicKey))
        s.receive(challenge())
        s.receive(welcome(directory = listOf(mac.copy(kind = NodeKind.BOX).toJson())))
        assertEquals(State.Closed("proof"), s.state)
    }

    @Test fun streamBytesGoBackAsCredit() {
        val s = session()
        s.receive(challenge())
        s.receive(welcome())
        sent(s)
        val inbox = s.receive(NetFrame(NetFrame.Queue.STREAM, false, 1, ByteArray(1000)).encoded())
        assertEquals(1, inbox.size)
        assertEquals(NetControl.Credit(1000), sent(s).single())
    }

    @Test fun messagesBeforeTheWelcomeEndIt() {
        val s = session()
        s.receive(challenge())
        s.receive(NetFrame(NetFrame.Queue.INTERACTIVE, false, 1, "{}".toByteArray()).encoded())
        assertEquals(State.Closed("protocol"), s.state)
    }

    @Test fun anOversizedPreAuthFrameIsALimit() {
        val s = session()
        s.receive(NetFrame(NetFrame.Queue.INTERACTIVE, false, 0, ByteArray(5000)).encoded())
        assertEquals(State.Closed("limit"), s.state)
    }

    @Test fun sendsGoOnTheRequestedStream() {
        val s = session()
        s.receive(challenge())
        s.receive(welcome())
        sent(s)
        s.send("{\"t\":\"presence\"}".toByteArray(), NetFrame.Queue.INTERACTIVE, 1)
        val m = NetFrameDecoder(preAuth = false).feed(s.nextFrame()!!).single()
        assertEquals(1L, m.stream)
        assertEquals(JsonPrimitive("presence").content, "presence")
    }

    private fun established(): NetClientSession = session().apply { receive(challenge()); receive(welcome()); sent(this) }

    @Test fun thePeersPingIsAnsweredWithItsPong() {
        val s = established()
        assertEquals(0, s.receive(frame(NetControl.Ping(41))).size)
        assertEquals(NetControl.Pong(41), sent(s).single())
    }

    @Test fun aProbeIsAPingAndItsPongIsNoted() {
        val s = established()
        assertEquals(1L, s.ping())
        assertEquals(NetControl.Ping(1), sent(s).single())
        s.receive(frame(NetControl.Pong(1)))
        assertEquals(1L, s.lastPong)
        assertEquals(State.Established::class, s.state::class)
    }

    @Test fun noPingBeforeTheWelcome() {
        val s = session()
        assertEquals(null, s.ping())
        s.receive(challenge())
        sent(s)
        s.receive(frame(NetControl.Ping(1)))
        assertEquals(State.Closed("protocol"), s.state)
    }

    /** A welcome's directory as the Mac's encoder writes `DeviceRecord`s: sorted keys, ISO dates, the Mac first. */
    @Test fun aSwiftDirectoryPinsTheMacAndListsItsBoxes() {
        val pub = java.util.Base64.getEncoder().encodeToString(serverKey.publicKey)
        val boxKey = java.util.Base64.getEncoder().encodeToString(SoftwareIdentity.fresh().publicKey)
        val dir = kotlinx.serialization.json.Json.parseToJsonElement("""[
            {"abilities":["read","ask","run"],"added":"1970-01-01T00:00:00Z","fqdn":"macbook.tail.ts.net.","id":"$serverId","identityKey":"$pub",
             "kind":"mac","name":"MacBook","nodeKeys":["${tn.s("nodeKeyS")}"],"owner":true,"tags":[],"userId":7},
            {"abilities":["read","ask","run"],"added":"2026-11-08T10:00:00Z","fqdn":"mybox.tail.ts.net.","id":"0C1D2E3F-4A5B-4C6D-8E7F-901A2B3C4D5E","identityKey":"$boxKey",
             "issuedBy":"$serverId","kind":"box","lastSeen":"2026-11-08T11:00:00Z","name":"mybox","nodeKeys":["nodekey:box"],"tags":[],"userId":7}
        ]""") as kotlinx.serialization.json.JsonArray
        val s = session(record = null, enroll = NetControl.Enroll("Pixel 9", clientKey.publicKey))
        s.receive(challenge())
        sent(s)
        s.receive(welcome(directory = dir.map { it as JsonObject }))
        val peer = (s.state as State.Established).peer
        assertEquals("MacBook", peer.record.name)
        assertEquals(true, peer.record.owner)
        val book = dev.kore.link.trust.DeviceBook()
        book.put(peer.record)
        book.applyDirectory(serverId, clientId, peer.directory!!.mapNotNull(Device::fromJson))
        assertEquals(listOf("MacBook" to NodeKind.MAC, "mybox" to NodeKind.BOX), book.all().map { it.name to it.kind })
    }
}
