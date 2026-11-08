package dev.kore.link.net

import java.io.InputStream
import java.io.OutputStream
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** A connected byte stream: a tailnet socket (one end of the shim's socketpair), or a test's pipe. */
interface ByteConn {
    val input: InputStream
    val output: OutputStream
    fun close()
}

/** Why a dial or a handshake didn't give a link: [reason] is the server's bye, or this side's. */
class NetFailure(val reason: String) : Exception(reason)

/**
 * One live link: messages for the service above in [incoming], [send] for the other way. The
 * node client sees only this, so its tests run on fakes in virtual time.
 */
interface LinkSession {
    val incoming: ReceiveChannel<ByteArray>
    /** The reason it ended: `bye <reason>` for the server's, else this side's or `closed`. */
    val ended: Deferred<String>
    /** B, what a raise signs over. */
    val binding: ByteArray
    val peer: NetClientSession.State.Established.Peer
    /** Wall-clock ms of the last bytes from the server: a quiet link gets a probe. */
    val lastInbound: Long
    fun send(payload: ByteArray): Boolean
    fun close(reason: String = "quit")
}

/**
 * Moves a [NetClientSession]'s bytes over a [ByteConn]: one reader (blocking reads on [io]) and
 * one writer woken when frames wait. Link bodies go on stream 1, interactive queue, as the box
 * serves them (`NetLinkWire`).
 */
class NetConnection(
    private val conn: ByteConn,
    private val session: NetClientSession,
    private val scope: CoroutineScope,
    private val clock: () -> Long = System::currentTimeMillis,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : LinkSession {
    private val lock = Any()
    private val messages = Channel<ByteArray>(Channel.UNLIMITED)
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val endedDeferred = CompletableDeferred<String>()
    private val established = CompletableDeferred<NetClientSession.State.Established.Peer>()
    @Volatile override var lastInbound: Long = clock()
        private set

    override val incoming: ReceiveChannel<ByteArray> get() = messages
    override val ended: Deferred<String> get() = endedDeferred
    override val binding: ByteArray get() = session.binding?.digest ?: ByteArray(0)
    override val peer: NetClientSession.State.Established.Peer get() = session.established?.peer ?: error("not established")

    /** Starts the reader and writer; returns once the welcome holds, or throws [NetFailure]. */
    suspend fun handshake(windowMs: Long = NetClientSession.CLIENT_WINDOW_MS, helloSent: () -> Unit = {}): LinkSession {
        scope.launch(io) { readLoop(helloSent) }
        scope.launch(io) { writeLoop() }
        val peer = withTimeoutOrNull(windowMs) {
            kotlinx.coroutines.selects.select {
                established.onAwait { it }
                endedDeferred.onAwait { null }
            }
        }
        if (peer == null) {
            val reason = if (endedDeferred.isCompleted) endedDeferred.getCompleted() else NetControl.Companion.Reason.TIMEOUT
            close(reason)
            throw NetFailure(reason)
        }
        return this
    }

    override fun send(payload: ByteArray): Boolean {
        synchronized(lock) {
            if (session.established == null) return false
            if (session.backlog > OUTBOUND_CAP) return false
            session.send(payload, NetFrame.Queue.INTERACTIVE, LINK_STREAM)
        }
        wake.trySend(Unit)
        return true
    }

    override fun close(reason: String) {
        synchronized(lock) { session.close(reason) }
        wake.trySend(Unit)
        finish(reason)
    }

    private fun readLoop(helloSent: () -> Unit) {
        val buf = ByteArray(64 shl 10)
        var announced = false
        try {
            while (true) {
                val n = conn.input.read(buf)
                if (n < 0) break
                lastInbound = clock()
                val (inbox, state) = synchronized(lock) { session.receive(buf, n) to session.state }
                if (!announced && state != NetClientSession.State.Handshaking) {
                    announced = true
                    helloSent()
                }
                if (state is NetClientSession.State.Established) established.complete(state.peer)
                inbox.forEach { messages.trySend(it.payload) }
                wake.trySend(Unit)
                if (state is NetClientSession.State.Closed) {
                    // Whatever it queued (its bye) goes before the socket closes.
                    wake.trySend(Unit)
                    return finish(state.reason)
                }
            }
        } catch (_: Exception) {
        }
        synchronized(lock) { session.ended("closed") }
        finish((session.state as? NetClientSession.State.Closed)?.reason ?: "closed")
    }

    private suspend fun writeLoop() {
        try {
            while (true) {
                while (true) {
                    val frame = synchronized(lock) { session.nextFrame() } ?: break
                    conn.output.write(frame)
                }
                conn.output.flush()
                if (endedDeferred.isCompleted) break
                wake.receive()
            }
        } catch (_: Exception) {
        }
        runCatching { conn.close() }
        finish("closed")
    }

    private fun finish(reason: String) {
        if (endedDeferred.complete(reason)) {
            messages.close()
            wake.trySend(Unit)
        }
    }

    companion object {
        /** Link bodies' stream: the box's `NetLinkWire.stream`. */
        const val LINK_STREAM = 1L
        /** Bytes waiting to go past which a send is refused (the link is too slow). */
        const val OUTBOUND_CAP = 8L shl 20
    }
}
