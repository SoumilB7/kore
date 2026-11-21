package dev.kore.link

import dev.kore.link.net.ByteConn
import dev.kore.link.net.NetControl
import dev.kore.link.net.NetDialer
import dev.kore.link.net.NetFailure
import dev.kore.link.net.NetFrame
import dev.kore.link.net.NetFrameDecoder
import dev.kore.link.net.PhoneIdentity
import dev.kore.link.net.Tailnet
import dev.kore.link.net.TailnetNode
import dev.kore.link.node.NodeClient
import dev.kore.link.node.NodeMachine
import dev.kore.link.node.PeerOffline
import dev.kore.link.trust.Binding
import dev.kore.link.trust.Device
import dev.kore.link.trust.NodeKind
import dev.kore.link.trust.SoftwareIdentity
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.UUID
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Mac moved to a new tailnet node (installed Tailscale uninstalled, Kore's own tailnet in its
 * place): the phone finds it among its user's Macs, its proof over the pinned identity key holds,
 * the new node key is appended, and no Join or Allow is needed. Real sessions over in-memory pipes.
 */
class NetDialerTest {
    private class Pipe : ByteConn {
        val toClient = object : PipedOutputStream() {
            override fun write(b: ByteArray) { super.write(b); flush() }
        }
        override val input = PipedInputStream(toClient, 1 shl 16)
        override val output = PipedOutputStream()
        val fromClient = PipedInputStream(output, 1 shl 16)
        override fun close() { runCatching { output.close() }; runCatching { toClient.close() } }
    }

    /** A Mac running Kore on a node: challenges as [id], welcomes a hello (or says [bye]). */
    private class Mac(val id: UUID, val key: SoftwareIdentity, val nodeKey: String, val bye: String? = null) {
        @Volatile var hellos = 0

        private fun frame(m: NetControl) = NetFrame(NetFrame.Queue.INTERACTIVE, false, 0, m.encoded()).encoded()

        fun serve(phoneNodeKey: String): ByteConn {
            val pipe = Pipe()
            val nonceS = ByteArray(Binding.NONCE_SIZE) { 9 }
            thread(isDaemon = true) {
                runCatching {
                    pipe.toClient.write(frame(NetControl.Challenge("tailnet", id, nonceS)))
                    val d = NetFrameDecoder(preAuth = false)
                    val buf = ByteArray(4096)
                    while (true) {
                        val n = pipe.fromClient.read(buf)
                        if (n < 0) break
                        for (m in d.feed(buf, 0, n)) {
                            val c = if (m.stream == 0L) NetControl.decode(m.payload) else continue
                            if (c is NetControl.Hello) {
                                hellos++
                                if (bye != null) {
                                    pipe.toClient.write(frame(NetControl.Bye(bye)))
                                    pipe.toClient.close()
                                    return@thread
                                }
                                val b = Binding("tailnet", nonceS, c.nonce, c.device, id, phoneNodeKey, nodeKey)
                                pipe.toClient.write(frame(NetControl.Welcome(key.sign(b.digest), 1 shl 20, byteArrayOf(1), false, listOf("read", "ask"))))
                            }
                        }
                    }
                }
            }
            return pipe
        }
    }

    private val macId = UUID.fromString("B3D9E1F0-7A2C-4E6B-8D41-5C0F9A3E2B02")
    private val macKey = SoftwareIdentity.fresh()
    private val phoneKey = SoftwareIdentity.fresh()
    private val record = Device(macId, "MacBook", NodeKind.MAC, macKey.publicKey, listOf("nodekey:mac"), "macbook.tail.ts.net.")
    private val phone = TailnetNode("kore-pixel.tail.ts.net.", "kore-pixel", "android", true, 7, "me@example.com", "nodekey:phone", listOf("100.64.1.1"))

    private fun peer(name: String, ip: String, key: String = "nodekey:$name", online: Boolean = true, os: String = "macOS", user: Long? = 7, tags: List<String> = emptyList()) =
        TailnetNode("$name.tail.ts.net.", name, os, online, user, "me@example.com", key, listOf(ip), tags)

    private fun dialer(tailnet: FakeTailnet, scope: CoroutineScope) =
        NetDialer(tailnet, { PhoneIdentity(UUID.randomUUID(), phoneKey, "Pixel 9", "Pixel 9", null) }, scope)

    private fun tailnet(peers: List<TailnetNode>, macs: Map<String, Mac>) = FakeTailnet(Tailnet.RUNNING).apply {
        me = phone
        others = peers
        answer = { address -> macs[address]?.serve(phone.nodeKey) }
    }

    /** The owner's switch: the old node lingers offline, another Kore Mac answers first and is passed by. */
    @Test fun aMacOnANewNodeIsFoundAndItsNewKeyKept() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val studio = Mac(UUID.randomUUID(), SoftwareIdentity.fresh(), "nodekey:studio")
        val moved = Mac(macId, macKey, "nodekey:kore-mac")
        val net = tailnet(
            listOf(peer("macbook", "100.64.0.1", "nodekey:mac", online = false), peer("studio", "100.64.0.5"), peer("zed-mac", "100.64.0.9", "nodekey:kore-mac")),
            mapOf("100.64.0.5" to studio, "100.64.0.9" to moved),
        )
        val link = withTimeout(10_000) { dialer(net, scope).dial(record, null) {} }
        assertEquals(listOf("nodekey:mac", "nodekey:kore-mac"), link.peer.record.nodeKeys)
        assertEquals(listOf("100.64.0.5", "100.64.0.9"), net.dials)
        // The other Mac heard no hello: this phone stopped at its challenge.
        assertEquals(0, studio.hellos)
        link.close("quit")
        scope.cancel()
    }

    /** A Mac that kept its name (`macbook-1` beside the old `macbook`) is tried first. */
    @Test fun itsOldNameGoesFirst() {
        val peers = listOf(peer("aaa", "100.64.0.2"), peer("macbook-1", "100.64.0.3"), peer("macbook", "100.64.0.1", "nodekey:mac", online = false))
        assertEquals(listOf("macbook-1", "aaa"), NetDialer.movedMacs(record, peers, phone).map { it.hostName })
    }

    /** Only this phone's user's online, untagged Macs, never a node the record holds or itself. */
    @Test fun onlyThisUsersMacsAreTried() {
        val peers = listOf(
            peer("other-user", "100.64.0.2", user = 9),
            peer("tagged", "100.64.0.3", tags = listOf("tag:ci")),
            peer("asleep", "100.64.0.4", online = false),
            peer("box", "100.64.0.5", os = "linux"),
            peer("macbook", "100.64.0.1", "nodekey:mac"),
            peer("shared", "100.64.0.6", user = null),
            peer("mine", "100.64.0.7"),
        )
        assertEquals(listOf("mine"), NetDialer.movedMacs(record, peers, phone).map { it.hostName })
        assertEquals(emptyList<TailnetNode>(), NetDialer.movedMacs(record, peers, null))
        val many = (1..9).map { peer("m$it", "100.64.2.$it") }
        assertEquals(NetDialer.MOVED_TRIES, NetDialer.movedMacs(record, many, phone).size)
    }

    /** The moved Mac answers as itself and says no (removed there): that's the answer, no more tries. */
    @Test fun theMovedMacsByeIsTheAnswer() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val moved = Mac(macId, macKey, "nodekey:kore-mac", bye = "revoked")
        val later = Mac(UUID.randomUUID(), SoftwareIdentity.fresh(), "nodekey:zz")
        val net = tailnet(
            listOf(peer("macbook", "100.64.0.1", "nodekey:mac", online = false), peer("macbook-1", "100.64.0.9", "nodekey:kore-mac"), peer("zz", "100.64.0.8")),
            mapOf("100.64.0.9" to moved, "100.64.0.8" to later),
        )
        val failure = runCatching { withTimeout(10_000) { dialer(net, scope).dial(record, null) {} } }.exceptionOrNull()
        assertEquals("bye revoked", (failure as NetFailure).reason)
        assertEquals(listOf("100.64.0.9"), net.dials)
        scope.cancel()
    }

    /**
     * Kore 0.3.7 gave the Mac a new identity key: its welcome fails this phone's pinned proof, the
     * handshake ends `key-changed`, and the node's row says Key changed · Pair again (never the
     * endless "retrying"). Through the real dialer and session, on its node and on a moved one.
     */
    @Test fun aMacWithANewKeyIsKeyChangedNotRetried() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val rekeyed = Mac(macId, SoftwareIdentity.fresh(), "nodekey:mac")
        val net = tailnet(listOf(peer("macbook", "100.64.0.1", "nodekey:mac")), mapOf("100.64.0.1" to rekeyed))
        val failure = runCatching { withTimeout(10_000) { dialer(net, scope).dial(record, null) {} } }.exceptionOrNull()
        assertEquals(NetControl.Companion.Reason.KEY_CHANGED, (failure as NetFailure).reason)
        // The node client over the same dialer: Denied("key-changed"), and no dial after it.
        val client = NodeClient(record, scope, dialer(net, scope))
        client.start()
        val state = withTimeout(10_000) { client.state.first { it is NodeMachine.State.Denied } }
        assertEquals(NodeMachine.State.Denied("key-changed"), state)
        assertEquals(2, rekeyed.hellos)
        client.stop()
        scope.cancel()
    }

    /** The Mac on a new node with a new key: that's its answer too, no other Mac tried after it. */
    @Test fun aMovedMacWithANewKeyIsTheAnswer() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val moved = Mac(macId, SoftwareIdentity.fresh(), "nodekey:kore-mac")
        val later = Mac(UUID.randomUUID(), SoftwareIdentity.fresh(), "nodekey:zz")
        val net = tailnet(
            listOf(peer("macbook", "100.64.0.1", "nodekey:mac", online = false), peer("macbook-1", "100.64.0.9", "nodekey:kore-mac"), peer("zz", "100.64.0.8")),
            mapOf("100.64.0.9" to moved, "100.64.0.8" to later),
        )
        val failure = runCatching { withTimeout(10_000) { dialer(net, scope).dial(record, null) {} } }.exceptionOrNull()
        assertEquals(NetControl.Companion.Reason.KEY_CHANGED, (failure as NetFailure).reason)
        assertEquals(listOf("100.64.0.9"), net.dials)
        scope.cancel()
    }

    /** Nowhere to be found (the Mac asleep, no other Mac): offline, as before. */
    @Test fun noMacAnywhereIsOffline() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val net = tailnet(listOf(peer("macbook", "100.64.0.1", "nodekey:mac", online = false)), emptyMap())
        val failure = runCatching { withTimeout(10_000) { dialer(net, scope).dial(record, null) {} } }.exceptionOrNull()
        assertTrue("$failure", failure is PeerOffline)
        assertEquals(listOf("100.64.0.1"), net.dials)
        scope.cancel()
    }
}

/** A box offline on its node is never looked for on other nodes (its key comes from the Mac's directory). */
class NetDialerBoxTest {
    @Test fun aBoxIsNotLookedForElsewhere() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val net = FakeTailnet(Tailnet.RUNNING).apply {
            me = TailnetNode("p.tail.ts.net.", "p", "android", true, 7, null, "nodekey:p", listOf("100.64.1.1"))
            others = listOf(
                TailnetNode("mybox.tail.ts.net.", "mybox", "linux", false, 7, null, "nodekey:box", listOf("100.64.0.2")),
                TailnetNode("mac.tail.ts.net.", "mac", "macOS", true, 7, null, "nodekey:m", listOf("100.64.0.3")),
            )
        }
        val dialer = NetDialer(net, { PhoneIdentity(UUID.randomUUID(), SoftwareIdentity.fresh(), "P", "P", null) }, scope)
        val failure = runCatching { withTimeout(10_000) { dialer.dial(box(), null) {} } }.exceptionOrNull()
        assertTrue("$failure", failure is PeerOffline)
        assertEquals(listOf("100.64.0.2"), net.dials)
        scope.cancel()
    }
}
