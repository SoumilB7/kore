package dev.kore.link

import dev.kore.link.net.ByteConn
import dev.kore.link.net.LinkSession
import dev.kore.link.net.NetClientSession
import dev.kore.link.net.Tailnet
import dev.kore.link.net.TailnetNode
import dev.kore.link.trust.Device
import dev.kore.link.trust.NodeKind
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

/** A link that never touches a socket: the test reads what the phone sent and pushes what the node says. */
class FakeLink(
    record: Device,
    private val clock: () -> Long,
    override val binding: ByteArray = ByteArray(32) { 7 },
    abilities: List<String> = listOf("read", "ask"),
    /** Answers a sent message, as the node would. */
    var respond: (JsonObject) -> JsonObject? = { null },
) : LinkSession {
    val sent = mutableListOf<JsonObject>()
    private val channel = Channel<ByteArray>(Channel.UNLIMITED)
    private val end = CompletableDeferred<String>()
    override val incoming get() = channel
    override val ended get() = end
    override val peer = NetClientSession.State.Established.Peer(record, abilities, false, byteArrayOf(4, 2), null, null)
    override var lastInbound: Long = clock()

    override fun send(payload: ByteArray): Boolean {
        if (end.isCompleted) return false
        val m = Json.parseToJsonElement(payload.decodeToString()) as JsonObject
        sent += m
        respond(m)?.let(::push)
        return true
    }

    override fun close(reason: String) {
        if (end.complete(reason)) channel.close()
    }

    fun push(m: JsonObject) {
        lastInbound = clock()
        channel.trySend(m.toString().toByteArray())
    }

    /** The node's bye (or a drop with null). */
    fun drop(reason: String?) = close(reason?.let { "bye $it" } ?: "closed")

    fun types(): List<String> = sent.map { (it["t"] as kotlinx.serialization.json.JsonPrimitive).content }
}

fun mac(id: UUID = UUID.fromString("B3D9E1F0-7A2C-4E6B-8D41-5C0F9A3E2B02")) =
    Device(id, "MacBook", NodeKind.MAC, ByteArray(91) { 1 }, listOf("nodekey:mac"), "macbook.tail.ts.net.")

fun node(name: String, os: String = "macOS", online: Boolean = true, user: Long? = 7, tags: List<String> = emptyList(), key: String = "nodekey:$name") =
    TailnetNode("$name.tail.ts.net.", name, os, online, user, "me@example.com", key, listOf("100.64.0.${name.length}"), tags)

/** A tailnet in memory: its state, its peers, and who answers a dial. */
class FakeTailnet(var state: String = Tailnet.NEEDS_LOGIN) : Tailnet {
    var url: String? = "https://login.tailscale.com/a/x"
    var me: TailnetNode? = null
    var others: List<TailnetNode> = emptyList()
    val dials = mutableListOf<String>()
    var started = 0
    var listening: (String) -> Boolean = { false }

    override fun state() = state
    override fun authUrl() = url.takeIf { state == Tailnet.NEEDS_LOGIN }
    override fun self() = me.takeIf { state == Tailnet.RUNNING }
    override fun peers() = others
    override fun whois(ip: String) = others.firstOrNull { ip in it.ips }
    override fun dial(address: String, port: Int, timeoutMs: Long): ByteConn {
        dials += address
        if (!listening(address)) throw java.io.IOException("connection refused")
        error("the tests enroll through a fake")
    }
    override fun start() { started++ }
    override fun stop() { state = "Stopped" }
    override fun logout() { state = Tailnet.NEEDS_LOGIN }
}
