package dev.kore.link

import dev.kore.link.Fixtures.hex
import dev.kore.link.Fixtures.o
import dev.kore.link.Fixtures.s
import dev.kore.link.net.ByteConn
import dev.kore.link.net.NetClientSession
import dev.kore.link.net.NetConnection
import dev.kore.link.net.NetControl
import dev.kore.link.net.NetFailure
import dev.kore.link.net.NetFrame
import dev.kore.link.net.NetFrameDecoder
import dev.kore.link.net.NetLocal
import dev.kore.link.net.NetPeerFacts
import dev.kore.link.trust.Device
import dev.kore.link.trust.IdentityProof
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
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The session's bytes over real streams (in-memory pipes, real threads): handshake, a message each way, bye. */
class NetConnectionTest {
    private val bind = Fixtures.json("bind.json")
    private val tn = bind.o("tailnet")
    private val clientId = UUID.fromString(bind.o("client").s("device"))
    private val serverId = UUID.fromString(bind.o("server").s("device"))
    private val clientKey = SoftwareIdentity.fromScalar(hex(bind.o("client").s("privateKey")))
    private val serverKey = SoftwareIdentity.fromScalar(hex(bind.o("server").s("privateKey")))
    private val mac = Device(serverId, "MacBook", NodeKind.MAC, serverKey.publicKey, listOf(tn.s("nodeKeyS")), "mac.ts.net.")

    private class Pipe : ByteConn {
        /** Flushed on every write: a piped reader otherwise wakes only on its 1 s poll. */
        val toClient = object : PipedOutputStream() {
            override fun write(b: ByteArray) { super.write(b); flush() }
        }
        override val input = PipedInputStream(toClient, 1 shl 16)
        override val output = PipedOutputStream()
        val fromClient = PipedInputStream(output, 1 shl 16)
        override fun close() { runCatching { output.close() }; runCatching { toClient.close() } }
    }

    private fun frame(m: NetControl) = NetFrame(NetFrame.Queue.INTERACTIVE, false, 0, m.encoded()).encoded()

    /** A server that checks the hello's proof and welcomes it (or says [bye]), then echoes link messages. */
    private fun server(pipe: Pipe, bye: String? = null) = thread(isDaemon = true) {
        val d = NetFrameDecoder(preAuth = false)
        pipe.toClient.write(frame(NetControl.Challenge("tailnet", serverId, hex(bind.s("nonceS")))))
        val buf = ByteArray(4096)
        runCatching {
            while (true) {
                val n = pipe.fromClient.read(buf)
                if (n < 0) break
                for (m in d.feed(buf, 0, n)) {
                    if (m.stream == 0L) {
                        when (val c = NetControl.decode(m.payload)) {
                            is NetControl.Hello -> {
                                val b = dev.kore.link.trust.Binding("tailnet", hex(bind.s("nonceS")), c.nonce, c.device, serverId, tn.s("nodeKeyC"), tn.s("nodeKeyS"))
                                check(IdentityProof.verify(c.sig, b.digest, clientKey.publicKey))
                                if (bye != null) { pipe.toClient.write(frame(NetControl.Bye(bye))); pipe.toClient.close(); return@thread }
                                pipe.toClient.write(frame(NetControl.Welcome(serverKey.sign(b.digest), 1 shl 20, byteArrayOf(1), false, listOf("read", "ask"))))
                                pipe.toClient.write(NetFrame(NetFrame.Queue.INTERACTIVE, false, 1, "{\"t\":\"welcome\"}".toByteArray()).encoded())
                            }
                            is NetControl.Ping -> pipe.toClient.write(frame(NetControl.Pong(c.n)))
                            is NetControl.Bye -> { pipe.toClient.close(); return@thread }
                            else -> Unit
                        }
                    } else {
                        pipe.toClient.write(NetFrame(NetFrame.Queue.INTERACTIVE, false, 1, m.payload).encoded())
                    }
                }
            }
        }
    }

    private fun session() = NetClientSession(NetLocal(clientId, tn.s("nodeKeyC"), clientKey), "tailnet", NetPeerFacts(tn.s("nodeKeyS"), true), serverId, mac)

    @Test fun handshakeThenMessagesBothWaysThenBye() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pipe = Pipe()
        server(pipe)
        val link = withTimeout(5_000) { NetConnection(pipe, session(), scope).handshake(5_000) }
        assertEquals(listOf("read", "ask"), link.peer.abilities)
        assertEquals(32, link.binding.size)
        assertEquals("{\"t\":\"welcome\"}", withTimeout(5_000) { link.incoming.receive() }.decodeToString())
        assertTrue(link.send("{\"t\":\"presence\",\"onScreen\":true}".toByteArray()))
        assertEquals("{\"t\":\"presence\",\"onScreen\":true}", withTimeout(5_000) { link.incoming.receive() }.decodeToString())
        // A probe: KoreNet's ping, answered on stream 0 by the server's pong.
        withTimeout(5_000) { link.ping()!!.await() }
        link.close("quit")
        assertEquals("quit", withTimeout(5_000) { link.ended.await() })
        scope.cancel()
    }

    @Test fun theServersByeFailsTheHandshakeWithItsReason() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pipe = Pipe()
        server(pipe, bye = "unknown")
        val failure = runCatching { withTimeout(5_000) { NetConnection(pipe, session(), scope).handshake(5_000) } }.exceptionOrNull()
        assertEquals("bye unknown", (failure as NetFailure).reason)
        scope.cancel()
    }
}
