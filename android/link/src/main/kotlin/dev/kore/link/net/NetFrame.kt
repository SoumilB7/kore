package dev.kore.link.net

import java.io.ByteArrayOutputStream

/**
 * Link 2.0's framing (phase 18 §1): `u32 len | u8 queue | u8 flags | u32 stream | payload`, big
 * endian, `len` counting the payload only. A message longer than one frame is cut into fragments of
 * at most [MAX_PAYLOAD] with MORE set on all but the last; fragments of different streams
 * interleave, so a large stream message never holds up an interactive one.
 * `Tests/Fixtures/link/v2/frames.json` holds worked encodings.
 */
class NetFrame(val queue: Queue, val more: Boolean, val stream: Long, val payload: ByteArray) {
    enum class Queue(val wire: Int) {
        /** Control, commands and results, nav reads, pty input. */
        INTERACTIVE(0),
        /** Catch-up events, transcript pages, blobs, file reads; under stream credit. */
        STREAM(1);

        companion object {
            fun of(b: Int): Queue? = entries.firstOrNull { it.wire == b }
        }
    }

    fun encoded(): ByteArray {
        val out = ByteArray(HEADER_SIZE + payload.size)
        putU32(out, 0, payload.size.toLong())
        out[4] = queue.wire.toByte()
        out[5] = (if (more) FLAG_MORE else 0).toByte()
        putU32(out, 6, stream)
        payload.copyInto(out, HEADER_SIZE)
        return out
    }

    companion object {
        const val HEADER_SIZE = 10
        const val MAX_PAYLOAD = 64 shl 10
        /** The largest whole message (a reassembled stream message). */
        const val MAX_MESSAGE = 16 shl 20
        /** Messages being reassembled at once, per connection. */
        const val MAX_PARTIAL_STREAMS = 64
        /** Before the hello is verified: one frame, header included, no fragments. */
        const val PRE_AUTH_MAX_FRAME = 4 shl 10
        /** Stream 0 is the session's own (challenge, hello, welcome, credit, bye), interactive only. */
        const val CONTROL_STREAM = 0L
        const val FLAG_MORE = 1
        const val MAX_STREAM = 0xFFFF_FFFFL

        internal fun putU32(b: ByteArray, at: Int, v: Long) {
            b[at] = (v ushr 24).toByte(); b[at + 1] = (v ushr 16).toByte(); b[at + 2] = (v ushr 8).toByte(); b[at + 3] = v.toByte()
        }

        internal fun u32(b: ByteArray, at: Int): Long =
            ((b[at].toLong() and 0xFF) shl 24) or ((b[at + 1].toLong() and 0xFF) shl 16) or ((b[at + 2].toLong() and 0xFF) shl 8) or (b[at + 3].toLong() and 0xFF)
    }
}

/** Why the bytes off the wire end the connection; [code] as frames.json names it. */
class NetFrameError(val code: String, message: String) : Exception(message)

/** A whole message off the wire. */
class NetMessage(val queue: NetFrame.Queue, val stream: Long, val payload: ByteArray)

/**
 * Bytes in, whole messages out, every limit checked as the bytes arrive: a violation throws and the
 * connection ends. Not thread-safe: one reader feeds it.
 */
class NetFrameDecoder(var preAuth: Boolean) {
    private var buffer = ByteArray(0)
    private var held = 0
    private class Partial(val queue: NetFrame.Queue, val bytes: ByteArrayOutputStream)
    private val partial = HashMap<Long, Partial>()
    private var preAuthFrames = 0
    private var streamBytes = 0L

    /** Stream-queue payload bytes taken since the last call: what goes back as credit. */
    fun takeStreamBytes(): Long = streamBytes.also { streamBytes = 0 }

    /** Lets one more pre-auth frame in. */
    fun expectAnotherPreAuthFrame() { preAuthFrames = 0 }

    /** Bytes held but not yet a whole frame. */
    val pending: Int get() = held

    fun feed(bytes: ByteArray, offset: Int = 0, length: Int = bytes.size): List<NetMessage> {
        if (held + length > buffer.size) buffer = buffer.copyOf(maxOf(held + length, buffer.size * 2, 1024))
        System.arraycopy(bytes, offset, buffer, held, length)
        held += length
        val out = ArrayList<NetMessage>()
        var at = 0
        try {
            while (held - at >= NetFrame.HEADER_SIZE) {
                val len = NetFrame.u32(buffer, at)
                val queueByte = buffer[at + 4].toInt() and 0xFF
                val flags = buffer[at + 5].toInt() and 0xFF
                val stream = NetFrame.u32(buffer, at + 6)
                val limit = if (preAuth) NetFrame.PRE_AUTH_MAX_FRAME - NetFrame.HEADER_SIZE else NetFrame.MAX_PAYLOAD
                if (len > limit) throw if (preAuth) NetFrameError("preAuth", "frame of $len bytes") else NetFrameError("tooLong", "frame of $len bytes")
                val queue = NetFrame.Queue.of(queueByte) ?: throw NetFrameError("badQueue", "unknown queue $queueByte")
                if (flags and NetFrame.FLAG_MORE.inv() != 0) throw NetFrameError("badFlags", "unknown flags $flags")
                val more = flags and NetFrame.FLAG_MORE != 0
                if (preAuth) {
                    if (preAuthFrames != 0) throw NetFrameError("preAuth", "a second frame")
                    if (more || stream != NetFrame.CONTROL_STREAM || queue != NetFrame.Queue.INTERACTIVE) throw NetFrameError("preAuth", "not one control frame")
                }
                if (stream == NetFrame.CONTROL_STREAM && (queue != NetFrame.Queue.INTERACTIVE || more)) {
                    throw NetFrameError("control", "fragmented or off the interactive queue")
                }
                val n = len.toInt()
                if (held - at < NetFrame.HEADER_SIZE + n) break
                val payload = buffer.copyOfRange(at + NetFrame.HEADER_SIZE, at + NetFrame.HEADER_SIZE + n)
                at += NetFrame.HEADER_SIZE + n
                if (preAuth) preAuthFrames += 1
                if (queue == NetFrame.Queue.STREAM) streamBytes += n
                take(queue, more, stream, payload)?.let(out::add)
            }
        } finally {
            if (at > 0) {
                System.arraycopy(buffer, at, buffer, 0, held - at)
                held -= at
            }
        }
        return out
    }

    private fun take(queue: NetFrame.Queue, more: Boolean, stream: Long, payload: ByteArray): NetMessage? {
        val held = partial[stream]
        if (held != null) {
            if (held.queue != queue) throw NetFrameError("queueChanged", "stream $stream changed queue mid-message")
            if (held.bytes.size() + payload.size > NetFrame.MAX_MESSAGE) throw NetFrameError("messageTooLong", "message too long")
            held.bytes.write(payload)
            if (more) return null
            partial.remove(stream)
            return NetMessage(queue, stream, held.bytes.toByteArray())
        }
        if (more) {
            if (partial.size >= NetFrame.MAX_PARTIAL_STREAMS) throw NetFrameError("tooManyStreams", "too many partial messages")
            partial[stream] = Partial(queue, ByteArrayOutputStream().apply { write(payload) })
            return null
        }
        return NetMessage(queue, stream, payload)
    }
}

/**
 * What goes on the wire next (phase 18 §1 "Two queues"): any interactive frame strictly ahead of
 * any stream frame; within a queue, streams take turns a fragment at a time and each stream's
 * messages stay in order. Stream frames spend the peer's credit and wait when it's gone.
 */
class NetScheduler(credit: Long = 0) {
    private class Pending(val payload: ByteArray) { var sent = 0; val remaining get() = payload.size - sent }
    private class Lane(val stream: Long, val messages: ArrayDeque<Pending>)

    private val lanes = mapOf(NetFrame.Queue.INTERACTIVE to ArrayDeque<Lane>(), NetFrame.Queue.STREAM to ArrayDeque<Lane>())
    var credit: Long = credit
        private set
    var queuedBytes: Long = 0
        private set

    val isEmpty: Boolean get() = lanes.values.all { it.isEmpty() }

    /** Whether [stream] has messages waiting on the other queue. */
    fun busy(stream: Long, otherThan: NetFrame.Queue): Boolean =
        lanes.any { (q, l) -> q != otherThan && l.any { it.stream == stream } }

    fun enqueue(payload: ByteArray, queue: NetFrame.Queue, stream: Long) {
        require(!busy(stream, queue)) { "stream $stream is on the other queue" }
        queuedBytes += payload.size
        val lane = lanes.getValue(queue).firstOrNull { it.stream == stream }
        if (lane != null) lane.messages.addLast(Pending(payload)) else lanes.getValue(queue).addLast(Lane(stream, ArrayDeque(listOf(Pending(payload)))))
    }

    /** The peer's `credit` message. */
    fun grant(bytes: Long) { credit = minOf(credit + maxOf(bytes, 0), Int.MAX_VALUE.toLong()) }

    /** The next frame, or null when nothing can go (empty, or only stream frames without credit). */
    fun next(): NetFrame? {
        take(NetFrame.Queue.INTERACTIVE, Long.MAX_VALUE)?.let { return it }
        if (credit <= 0) return null
        val frame = take(NetFrame.Queue.STREAM, credit) ?: return null
        credit -= frame.payload.size
        return frame
    }

    private fun take(queue: NetFrame.Queue, budget: Long): NetFrame? {
        val list = lanes.getValue(queue)
        val lane = list.removeFirstOrNull() ?: return null
        val message = lane.messages.first()
        val size = minOf(NetFrame.MAX_PAYLOAD.toLong(), message.remaining.toLong(), budget).toInt()
        val chunk = message.payload.copyOfRange(message.sent, message.sent + size)
        message.sent += size
        val done = message.remaining == 0
        if (done) lane.messages.removeFirst()
        queuedBytes -= size
        if (lane.messages.isNotEmpty()) list.addLast(lane)
        return NetFrame(queue, !done, lane.stream, chunk)
    }
}
