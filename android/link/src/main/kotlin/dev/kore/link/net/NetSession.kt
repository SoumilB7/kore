package dev.kore.link.net

import dev.kore.link.trust.Binding
import dev.kore.link.trust.Device
import dev.kore.link.trust.IdentityProof
import dev.kore.link.trust.IdentitySigner
import dev.kore.link.trust.NodeKind
import dev.kore.link.trust.secureRandom
import java.util.UUID
import kotlinx.serialization.json.JsonObject

/** This phone as a session sees it. */
class NetLocal(val device: UUID, /** This node's key from its own Status. */ val nodeKey: String, val signer: IdentitySigner)

/** The peer as this side's own WhoIs saw it, never as the peer says. */
class NetPeerFacts(val nodeKey: String, /** Its WhoIs user is this phone's own (a node key may be appended). */ val sameUser: Boolean)

/**
 * One link 2.0 connection, the client's half (phase 18 §1): the server's challenge → this hello
 * signed over B (with only a resume ticket) → the server's welcome signed over B; then the cursors
 * as the first message, and messages both ways through the two-queue scheduler under stream
 * credit. A pure state machine: bytes in ([receive]), frames out ([nextFrame]); [NetConnection]
 * moves the bytes. Not thread-safe: its owner holds one lock round every call.
 */
class NetClientSession(
    private val local: NetLocal,
    private val route: String,
    private val peer: NetPeerFacts,
    /** The device this side dialled: the challenge must name it. Null on first contact (any Mac). */
    private val expected: UUID?,
    /** Its record as this phone knows it; null on first contact, when [enroll] says who this is. */
    private val record: Device?,
    private val service: String = "link",
    private val ticket: ByteArray? = null,
    private val cursors: JsonObject? = null,
    private val enroll: NetControl.Enroll? = null,
    private val credit: Long = INITIAL_CREDIT,
    private val random: (Int) -> ByteArray = ::secureRandom,
) {
    sealed class State {
        data object Handshaking : State()
        /** The hello went out; the welcome is awaited (on first contact: the owner's Allow). */
        data object HelloSent : State()
        data class Established(val peer: Established.Peer) : State() {
            /** [record]: the server, as now pinned (a node key it gained, or its first record). */
            class Peer(val record: Device, val abilities: List<String>, val resumed: Boolean, val ticket: ByteArray, val devicesRev: Int?, val directory: List<JsonObject>?)
        }
        /** Ended: the reason this side gave, or `bye <reason>` for the peer's. */
        data class Closed(val reason: String) : State()
    }

    var state: State = State.Handshaking
        private set
    /** B, once the challenge came: what a raise signs over. */
    var binding: Binding? = null
        private set
    /** The server's device id, as its challenge named it. */
    var server: UUID? = expected
        private set
    private val decoder = NetFrameDecoder(preAuth = true)
    /** The `n` of the last ping this side sent, and of the last pong heard. */
    private var lastPing = 0L
    var lastPong = 0L
        private set
    private val scheduler = NetScheduler(0)

    val isClosed: Boolean get() = state is State.Closed
    val established: State.Established? get() = state as? State.Established

    /** Bytes off the socket; the messages for the service above. */
    fun receive(bytes: ByteArray, length: Int = bytes.size): List<NetMessage> {
        if (isClosed) return emptyList()
        val messages = try {
            decoder.feed(bytes, 0, length)
        } catch (e: NetFrameError) {
            fail(NetControl.Companion.Reason.LIMIT)
            return emptyList()
        }
        val inbox = ArrayList<NetMessage>()
        for (m in messages) {
            if (isClosed) break
            if (m.stream == NetFrame.CONTROL_STREAM) control(m.payload)
            else if (state is State.Established) inbox += m
            else fail(NetControl.Companion.Reason.PROTOCOL)
        }
        if (state is State.Established) {
            val owed = decoder.takeStreamBytes()
            if (owed > 0) queueControl(NetControl.Credit(owed))
        }
        return inbox
    }

    /** Queues a message for the service above on a non-zero [stream]. */
    fun send(payload: ByteArray, queue: NetFrame.Queue, stream: Long) {
        check(state is State.Established) { "not established" }
        require(stream != NetFrame.CONTROL_STREAM) { "control stream" }
        require(payload.size <= NetFrame.MAX_MESSAGE) { "too long" }
        require(!scheduler.busy(stream, queue)) { "stream on the other queue" }
        scheduler.enqueue(payload, queue, stream)
    }

    /** An on-demand probe (`{"t":"ping","n":…}` on stream 0): its `n`, answered by the peer's pong. */
    fun ping(): Long? {
        if (state !is State.Established) return null
        lastPing += 1
        queueControl(NetControl.Ping(lastPing))
        return lastPing
    }

    /** The next frame's bytes for the socket, or null. */
    fun nextFrame(): ByteArray? = scheduler.next()?.encoded()

    val wantsWrite: Boolean get() = !scheduler.isEmpty
    val backlog: Long get() = scheduler.queuedBytes

    /** Says `bye` (as far as the socket takes it) and ends. */
    fun close(reason: String) = fail(reason)

    /** The socket ended under it. */
    fun ended(reason: String) {
        if (!isClosed) state = State.Closed(reason)
    }

    private fun queueControl(message: NetControl) = scheduler.enqueue(message.encoded(), NetFrame.Queue.INTERACTIVE, NetFrame.CONTROL_STREAM)

    private fun fail(reason: String) {
        if (isClosed) return
        queueControl(NetControl.Bye(reason))
        state = State.Closed(reason)
    }

    private fun control(payload: ByteArray) {
        val message = runCatching { NetControl.decode(payload) }.getOrElse { return fail(NetControl.Companion.Reason.PROTOCOL) }
        if (message is NetControl.Bye) {
            state = State.Closed("bye ${message.reason}")
            return
        }
        when {
            state == State.Handshaking && message is NetControl.Challenge -> challenge(message)
            state == State.HelloSent && message is NetControl.Welcome -> welcome(message)
            state is State.Established && message is NetControl.Credit -> scheduler.grant(message.n)
            state is State.Established && message is NetControl.Ping -> queueControl(NetControl.Pong(message.n))
            state is State.Established && message is NetControl.Pong -> lastPong = maxOf(lastPong, message.n)
            else -> fail(NetControl.Companion.Reason.PROTOCOL)
        }
    }

    private fun challenge(c: NetControl.Challenge) {
        if (c.v != NetControl.VERSION) return fail(NetControl.Companion.Reason.VERSION)
        if (c.route != route || (expected != null && c.device != expected)) return fail(NetControl.Companion.Reason.PROOF)
        if (record == null && enroll == null) return fail(NetControl.Companion.Reason.UNKNOWN)
        if (record != null && record.id != c.device) return fail(NetControl.Companion.Reason.PROOF)
        server = c.device
        val nonceC = random(Binding.NONCE_SIZE)
        val b = runCatching { Binding(route, c.nonce, nonceC, local.device, c.device, local.nodeKey, peer.nodeKey) }.getOrElse { return fail(NetControl.Companion.Reason.PROOF) }
        val sig = runCatching { IdentityProof.sign(b, local.signer) }.getOrElse { return fail(NetControl.Companion.Reason.PROOF) }
        binding = b
        queueControl(NetControl.Hello(service, local.device, nonceC, sig, credit, ticket, enroll))
        // The welcome and the service's first messages may come in one read.
        decoder.preAuth = false
        state = State.HelloSent
    }

    private fun welcome(w: NetControl.Welcome) {
        val b = binding ?: return fail(NetControl.Companion.Reason.PROTOCOL)
        val server = b.deviceS
        if (w.v != NetControl.VERSION) return fail(NetControl.Companion.Reason.VERSION)
        // First contact: the server's record comes in its directory and is pinned now.
        val known = record ?: w.directory?.mapNotNull(Device::fromJson)?.firstOrNull { it.id == server }
            ?: return fail(NetControl.Companion.Reason.PROOF)
        // Only a Mac takes a phone in (its Add device window); a box learns of it from the Mac.
        if (record == null && known.kind != NodeKind.MAC) return fail(NetControl.Companion.Reason.PROOF)
        if (known.id != server || !IdentityProof.verify(w.sig, b.digest, known.identityKey)) return fail(NetControl.Companion.Reason.PROOF)
        // Its node key as this side's WhoIs saw it: one its record holds, or (rotation, or the
        // first pin) appended after the proof held and the WhoIs said it's this phone's own user.
        val pinned = when {
            peer.nodeKey in known.nodeKeys -> known
            peer.sameUser -> known.withNodeKey(peer.nodeKey)
            else -> return fail(NetControl.Companion.Reason.PROOF)
        }
        if (w.credit !in 1..MAX_CREDIT) return fail(NetControl.Companion.Reason.PROTOCOL)
        scheduler.grant(w.credit)
        state = State.Established(State.Established.Peer(pinned, w.abilities, w.resumed, w.ticket, w.devicesRev, w.directory))
        if (cursors != null && cursors.isNotEmpty()) queueControl(NetControl.Resume(cursors))
    }

    companion object {
        const val INITIAL_CREDIT = 512L shl 10
        const val MAX_CREDIT = 64L shl 20
        /** How long the welcome may take (as the SSH route's 20 s handshake). */
        const val CLIENT_WINDOW_MS = 20_000L
        /** First contact: the owner reads the Allow card on the Mac. */
        const val ENROLL_WINDOW_MS = 120_000L
    }
}
