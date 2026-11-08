package dev.kore.link.node

import dev.kore.link.net.LinkSession
import dev.kore.link.net.NetFailure
import dev.kore.link.trust.Device
import dev.kore.link.trust.Raise
import java.util.Base64
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.onTimeout
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** What a node client resumes from: the last welcome's ticket and the cursors it holds. */
class NetResume(val ticket: ByteArray, val cursors: JsonObject)

/** Opens one link to a node (the app's [dev.kore.link.net.NetDialer]; a fake in tests). */
fun interface NodeDialer {
    /** [enrolling]: the hello went out with an enroll (first contact; the owner has to Allow it). */
    suspend fun dial(device: Device, resume: NetResume?, enrolling: () -> Unit): LinkSession
}

/** The tailnet says the node is offline: nothing to dial until it's back. */
class PeerOffline : Exception("offline")

/**
 * Signs a raise digest with the biometric `kore_raise` key, one prompt at a time: a second ask
 * while one is showing gets null at once (concurrent prompts got stuck doubled on OnePlus).
 */
fun interface RaiseSigner {
    /** The signature (DER), or null when the owner didn't give the fingerprint. */
    suspend fun sign(digest: ByteArray): ByteArray?
}

/** Lets one signature through at a time; the rest get null. */
class SingleFlight(private val inner: RaiseSigner) : RaiseSigner {
    private val busy = AtomicBoolean(false)
    override suspend fun sign(digest: ByteArray): ByteArray? {
        if (!busy.compareAndSet(false, true)) return null
        return try { inner.sign(digest) } finally { busy.set(false) }
    }
}

/**
 * One node (a Mac or a box) and the phone's link to it (phase 18 §5): dials when its
 * [NodeMachine] says so, keeps the snapshot current from deltas, queues commands made while it's
 * out of reach ([Outbox], 30 s each), and re-follows open transcripts on every new link. No
 * periodic timers: a link quiet for over 15 s gets a probe only when something asks (the app
 * opening, the network changing), and is abandoned when nothing comes back within 5 s.
 * Messages come up as raw JSON in the wire's shapes (link 1.11 bodies).
 */
class NodeClient(
    initial: Device,
    private val scope: CoroutineScope,
    private val dialer: NodeDialer,
    private val clock: () -> Long = System::currentTimeMillis,
    private val raiseSigner: RaiseSigner? = null,
    /** The node's record changed (a node key appended on a welcome): keep it. */
    private val onRecord: (Device) -> Unit = {},
    /** An owner Mac sent its directory (`devices.set`, or a welcome's): keep the boxes it lists. */
    private val onDirectory: (List<Device>) -> Unit = {},
    machineRandom: kotlin.random.Random = kotlin.random.Random.Default,
) {
    private val deviceFlow = MutableStateFlow(initial)
    val device: StateFlow<Device> = deviceFlow.asStateFlow()
    val id: UUID get() = deviceFlow.value.id

    private val machine = NodeMachine(machineRandom)
    private val stateFlow = MutableStateFlow<NodeMachine.State>(machine.state)
    val state: StateFlow<NodeMachine.State> = stateFlow.asStateFlow()

    private val welcomeFlow = MutableStateFlow<JsonObject?>(null)
    private val snapshotFlow = MutableStateFlow<JsonObject?>(null)
    private val transcriptFlow = MutableSharedFlow<JsonObject>(extraBufferCapacity = 256)
    private val attentionFlow = MutableSharedFlow<JsonObject>(extraBufferCapacity = 256)
    private val messageFlow = MutableSharedFlow<JsonObject>(extraBufferCapacity = 256)
    private val resultFlow = MutableSharedFlow<JsonObject>(extraBufferCapacity = 64)
    private val queuedFlow = MutableStateFlow<Set<String>>(emptySet())
    private val abilitiesFlow = MutableStateFlow<List<String>>(emptyList())

    /** The node's link welcome (`host`, providers, policy, caps). */
    val welcome: StateFlow<JsonObject?> = welcomeFlow.asStateFlow()
    /** Windows and chats, kept across reconnects: the app shows the last one at once. */
    val snapshot: StateFlow<JsonObject?> = snapshotFlow.asStateFlow()
    val transcripts: SharedFlow<JsonObject> = transcriptFlow.asSharedFlow()
    val attention: SharedFlow<JsonObject> = attentionFlow.asSharedFlow()
    val messages: SharedFlow<JsonObject> = messageFlow.asSharedFlow()
    /** `result {id, ok, code?, message?}`, one per command. */
    val results: SharedFlow<JsonObject> = resultFlow.asSharedFlow()
    /** Command ids waiting for the link to come back (shown as ⟳). */
    val queued: StateFlow<Set<String>> = queuedFlow.asStateFlow()
    /** What this phone may do on the node, as its welcome said. */
    val abilities: StateFlow<List<String>> = abilitiesFlow.asStateFlow()

    /** When the node was last up (ms). */
    @Volatile var lastSeen: Long? = null
        private set

    private sealed class Internal {
        class LinkUp(val link: LinkSession) : Internal()
        class LinkDown(val link: LinkSession, val reason: String?) : Internal()
        class DialFailed(val error: Throwable) : Internal()
        data object Enrolling : Internal()
    }

    private val events = Channel<Any>(Channel.UNLIMITED)
    @Volatile private var session: LinkSession? = null
    private var dialing: Job? = null
    private var actor: Job? = null
    private var expiry: Job? = null
    private val outbox = Outbox<suspend (LinkSession) -> String?>(now = clock)
    private val following = LinkedHashMap<String, Int>()
    @Volatile private var onScreen = true
    @Volatile private var visibleChat: String? = null
    @Volatile private var lastAid = 0
    private var ticket: ByteArray? = null

    /** The node's name: its welcome's, else its record's. */
    val name: String
        get() = (welcomeFlow.value?.get("host") as? JsonObject)?.get("name")?.jsonPrimitive?.contentOrNull ?: deviceFlow.value.shortName

    /** Starts following the node (the app came on screen, or KoreNet turned on). */
    fun start() {
        if (actor == null) actor = scope.launch { run() }
        events.trySend(NodeMachine.Event.Start)
    }

    /** Stops dialing and ends the link (the app went off screen with background mode off). */
    fun stop() = post(NodeMachine.Event.Stop)

    fun post(event: NodeMachine.Event) {
        events.trySend(event)
    }

    /** Ends everything for good (the node was removed, or KoreNet left). */
    fun close() {
        session?.close()
        actor?.cancel()
        dialing?.cancel()
        expiry?.cancel()
    }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private suspend fun run() {
        while (true) {
            val wake = machine.wakeAt
            val event = if (wake == null) events.receive() else select {
                events.onReceive { it }
                onTimeout(maxOf(0L, wake - clock())) { NodeMachine.Event.Tick }
            }
            apply(event)
        }
    }

    private fun apply(event: Any) {
        when (event) {
            is Internal.LinkUp -> {
                dialing = null
                if (machine.state !is NodeMachine.State.Connecting && machine.state !is NodeMachine.State.AwaitingAllow) {
                    event.link.close()
                } else {
                    up(event.link)
                    machine.on(NodeMachine.Event.Connected, clock())
                }
            }
            is Internal.LinkDown -> if (event.link === session) {
                session = null
                machine.on(NodeMachine.Event.Ended(event.reason), clock())
            }
            is Internal.DialFailed -> {
                dialing = null
                val e = event.error
                machine.on(
                    when {
                        e is PeerOffline -> NodeMachine.Event.PeerOffline
                        e is NetFailure && e.reason.startsWith("bye ") -> NodeMachine.Event.Ended(e.reason.removePrefix("bye "))
                        else -> NodeMachine.Event.Failed
                    },
                    clock(),
                )
            }
            Internal.Enrolling -> machine.on(NodeMachine.Event.Enrolling, clock())
            NodeMachine.Event.Stop, NodeMachine.Event.SignedOut -> {
                dialing?.cancel()
                dialing = null
                session?.close()
                session = null
                machine.on(event as NodeMachine.Event, clock())
            }
            is NodeMachine.Event -> machine.on(event, clock())
        }
        if (machine.state == NodeMachine.State.Connecting && dialing == null && session == null) dial()
        stateFlow.value = machine.state
    }

    private fun dial() {
        val device = deviceFlow.value
        val resume = ticket?.let { NetResume(it, cursors()) }
        dialing = scope.launch {
            val outcome = runCatching { dialer.dial(device, resume) { events.trySend(Internal.Enrolling) } }
            events.trySend(outcome.fold({ Internal.LinkUp(it) }, { Internal.DialFailed(it) }))
        }
    }

    private fun cursors(): JsonObject = buildJsonObject {
        put("attn", buildJsonObject { put("aid", lastAid) })
        snapshotFlow.value?.get("rev")?.jsonPrimitive?.intOrNull?.let { rev -> put("snapshot", buildJsonObject { put("rev", rev) }) }
    }

    private fun up(link: LinkSession) {
        session = link
        lastSeen = clock()
        val peer = link.peer
        ticket = peer.ticket
        abilitiesFlow.value = peer.abilities
        if (peer.record != deviceFlow.value) {
            deviceFlow.value = peer.record
            onRecord(peer.record)
        }
        peer.directory?.mapNotNull(Device::fromJson)?.let { if (it.isNotEmpty()) onDirectory(it) }
        scope.launch {
            for (data in link.incoming) {
                val message = runCatching { Json.parseToJsonElement(data.decodeToString()).jsonObject }.getOrNull() ?: continue
                route(message)
            }
        }
        scope.launch { events.trySend(Internal.LinkDown(link, link.ended.await().removePrefix("bye ").takeIf { it != "closed" })) }
        link.send(Control.presence(onScreen, visibleChat).bytes())
        synchronized(following) { following.toMap() }.forEach { (chat, last) -> link.send(Control.txOpen(chat, last).bytes()) }
        scope.launch { flush(link) }
    }

    // MARK: liveness

    private val probing = AtomicBoolean(false)

    /**
     * The app opened, the screen came on, the network changed: a node out of reach is tried at
     * once, and a link quiet for over [QUIET_MS] gets one probe; nothing back within [PROBE_MS]
     * and it's abandoned and made again (a socket dead after sleep says nothing).
     */
    fun reconnectNow() {
        val link = session
        if (link == null) {
            post(NodeMachine.Event.Trigger)
            return
        }
        if (clock() - link.lastInbound < QUIET_MS || !probing.compareAndSet(false, true)) return
        scope.launch {
            try {
                // KoreNet's own ping on stream 0: its pong overtakes any stream traffic.
                val pong = link.ping() ?: return@launch
                val alive = withTimeoutOrNull(PROBE_MS) { pong.await() } != null
                if (!alive && session === link) link.close("abandoned")
            } finally {
                probing.set(false)
            }
        }
    }

    // MARK: presence and transcripts

    /** The app on screen or not, and the chat it shows: off screen a node sends attention only. */
    fun setPresence(onScreen: Boolean, chat: String? = null) {
        this.onScreen = onScreen
        visibleChat = if (onScreen) chat else null
        session?.send(Control.presence(onScreen, visibleChat).bytes())
    }

    val chatOnScreen: String? get() = visibleChat

    fun openTranscript(chatId: String, last: Int = 60) {
        synchronized(following) { following[chatId] = last }
        session?.send(Control.txOpen(chatId, last).bytes())
    }

    fun closeTranscript(chatId: String) {
        synchronized(following) { following.remove(chatId) }
        session?.send(Control.txClose(chatId).bytes())
    }

    // MARK: commands

    /** Sends a message to the chat; returns the command id its `result` carries. */
    fun send(chatId: String, text: String, blobs: List<String> = emptyList()): String = command(Control.send(chatId, text, blobs))
    fun setMode(chatId: String, modeId: String): String = command(Control.setMode(chatId, modeId))
    fun stop(chatId: String): String = command(Control.stop(chatId))

    /**
     * A card answer, over the card as last seen; null when the card is gone. A plain tap, except
     * Allow on a risky card (`risk`: shell, write outside the folder, network): that one carries
     * the fingerprint's signature over `approve.<digest>` and the node's nonce (`cancelled` without
     * it). Deny is always free.
     */
    fun answer(chatId: String, cardId: String, action: String, answers: Map<String, List<String>>? = null): String? {
        card(chatId, cardId) ?: return null
        return issue { link ->
            val card = card(chatId, cardId) ?: return@issue null
            val digest = card.str("digest") ?: return@issue null
            val body = Control.answer(chatId, cardId, action, digest, answers)
            if (card.str("risk") == null || action != "allow") return@issue body.toString()
            val modeId = APPROVE + digest
            val (nonce, sig) = signRaise(link, chatId, modeId) ?: throw NotSigned()
            JsonObject(body + mapOf("nonce" to JsonPrimitive(nonce), "sig" to JsonPrimitive(sig))).toString()
        }
    }

    /** The fingerprint wasn't given (or the nonce didn't come): the command is answered `cancelled`. */
    class NotSigned : Exception("not signed")

    /**
     * The node's nonce for [modeId] on [link], and the `kore_raise` signature over
     * `SHA256("kore-raise/1" | B | nonce | chatId | modeId)` (base64 both); null when refused,
     * unanswered, or not signed.
     */
    private suspend fun signRaise(link: LinkSession, chatId: String, modeId: String): Pair<String, String>? {
        val signer = raiseSigner ?: return null
        val chal = readOn(link, Control.raiseChallenge(chatId, modeId)) ?: return null
        if (chal.str("t") != "raise.chal") return null
        val nonceText = chal.str("nonce") ?: return null
        val nonce = runCatching { Base64.getDecoder().decode(nonceText) }.getOrNull()?.takeIf { it.size == Raise.NONCE_SIZE } ?: return null
        val sig = signer.sign(Raise.digest(link.binding, nonce, chatId, modeId)) ?: return null
        return nonceText to Base64.getEncoder().encodeToString(sig)
    }

    /**
     * A new `kore_raise` public key (a fingerprint enrolled on the phone made the old one void), for
     * a Mac: taken only once its owner Allows it. Its one `result` (`raise.key:<id>`) comes after
     * Allow, Deny or the Mac's 100 s; `offline` without a link, `timeout` if none comes.
     */
    suspend fun raiseKey(pub: ByteArray): JsonObject {
        val link = session ?: return failure("raise.key", "offline")
        val id = UUID.randomUUID().toString()
        val answer = scope.async(start = CoroutineStart.UNDISPATCHED) { resultFlow.first { it.str("id") == "raise.key:$id" } }
        link.send(Control.raiseKey(id, Base64.getEncoder().encodeToString(pub)).bytes())
        return withTimeoutOrNull(RAISE_KEY_MS) { answer.await() } ?: run { answer.cancel(); failure("raise.key:$id", "timeout") }
    }

    /** Sends a [Control] command; returns the id its `result` carries. */
    fun command(cmd: JsonObject): String = issue { cmd.toString() }

    /**
     * Sends a [Control] command and waits for its `result`. A command queued while the node is
     * out of reach waits with it; no answer gives `timeout`.
     */
    suspend fun call(cmd: JsonObject, timeoutMs: Long = 45_000): JsonObject {
        val id = UUID.randomUUID().toString()
        val answer = scope.async(start = CoroutineStart.UNDISPATCHED) { resultFlow.first { it.str("id") == id } }
        issue(id) { cmd.toString() }
        return withTimeoutOrNull(timeoutMs) { answer.await() } ?: run {
            answer.cancel()
            failure(id, "timeout")
        }
    }

    /** An on-demand read ([Control.historyList], [Control.diffGet], `raise.chal`): its reply, or the refusing `result`. */
    suspend fun read(request: JsonObject, timeoutMs: Long = 15_000): JsonObject? = readOn(session ?: return null, request, timeoutMs)

    private suspend fun readOn(link: LinkSession, request: JsonObject, timeoutMs: Long = 15_000): JsonObject? {
        val type = request.str("t") ?: return null
        val reply = Control.replyTo(type)
        val id = UUID.randomUUID().toString()
        val answer = scope.async(start = CoroutineStart.UNDISPATCHED) {
            messageFlow.first { m ->
                val mid = m.str("id")
                (m.str("t") == reply && mid == id) || (m.str("t") == "result" && (mid == "$type:$id" || mid == id))
            }
        }
        link.send(JsonObject(request + ("id" to JsonPrimitive(id))).bytes())
        return withTimeoutOrNull(timeoutMs) { answer.await() } ?: run { answer.cancel(); null }
    }

    /** A message with no answer of its own ([Control.txEarlier], [Control.txMore]); false without a link. */
    fun post(message: JsonObject): Boolean = session?.send(message.bytes()) ?: false

    /**
     * Raises the chat's mode (or an Arsenal tier, `arsenal.<tier>`) with the fingerprint: the node's
     * nonce, the `kore_raise` signature over `SHA256("kore-raise/1" | B | nonce | chatId | modeId)`,
     * then the `raise` command, all on one link (B is that link's). The result, or a failure:
     * `offline`, `cancelled` (no fingerprint, or a prompt already showing), `gone` (the link changed).
     */
    suspend fun raise(chatId: String, modeId: String): JsonObject {
        val signer = raiseSigner ?: return failure("raise", "denied.raiseMode")
        val link = session ?: return failure("raise", "offline")
        val chal = readOn(link, Control.raiseChallenge(chatId, modeId)) ?: return failure("raise", "timeout")
        if (chal.str("t") == "result") return chal
        val nonceText = chal.str("nonce") ?: return failure("raise", "invalid")
        val nonce = runCatching { Base64.getDecoder().decode(nonceText) }.getOrNull()?.takeIf { it.size == Raise.NONCE_SIZE }
            ?: return failure("raise", "invalid")
        val digest = Raise.digest(link.binding, nonce, chatId, modeId)
        val sig = signer.sign(digest) ?: return failure("raise", "cancelled")
        if (session !== link) return failure("raise", "gone")
        val id = UUID.randomUUID().toString()
        val answer = scope.async(start = CoroutineStart.UNDISPATCHED) { resultFlow.first { it.str("id") == id } }
        link.send(Control.envelope(id, Control.raise(chatId, modeId, nonceText, Base64.getEncoder().encodeToString(sig))).bytes())
        return withTimeoutOrNull(15_000) { answer.await() } ?: run { answer.cancel(); failure(id, "timeout") }
    }

    /**
     * Uploads one file for a later [send] (link 1.1: `blob.put.begin`, base64 chunks, `blob.put.end`);
     * the node answers `result {id: "blob.put:<id>", ok, blobId}`. The blob id, or null.
     */
    suspend fun upload(name: String, mime: String, bytes: ByteArray): String? {
        val link = session ?: return null
        val uploadId = UUID.randomUUID().toString()
        val answer = scope.async(start = CoroutineStart.UNDISPATCHED) { resultFlow.first { it.str("id") == "blob.put:$uploadId" } }
        for (frame in uploadFrames(uploadId, name, mime, bytes)) if (!link.send(frame.toByteArray())) break
        val r = withTimeoutOrNull(60_000) { answer.await() } ?: run { answer.cancel(); return null }
        return if (r["ok"]?.jsonPrimitive?.contentOrNull == "true") r.str("blobId") else null
    }

    /** An attachment's bytes (`variant` thumb or full) for a ref in [chatId]'s transcript; null when refused. */
    suspend fun blobGet(chatId: String, ref: String, variant: String = "thumb"): ByteArray? {
        val out = java.io.ByteArrayOutputStream()
        while (true) {
            val link = session ?: return null
            val id = UUID.randomUUID().toString()
            val answer = scope.async(start = CoroutineStart.UNDISPATCHED) {
                messageFlow.first { it.str("id") == id && (it.str("t") == "blob.chunk" || it.str("t") == "result") }
            }
            link.send(Control.blobGet(id, chatId, ref, variant, out.size()).bytes())
            val m = withTimeoutOrNull(20_000) { answer.await() } ?: run { answer.cancel(); return null }
            if (m.str("t") != "blob.chunk") return null
            val data = Base64.getDecoder().decode(m.str("data") ?: "")
            if (data.isEmpty() && out.size() == 0 && (m["total"]?.jsonPrimitive?.intOrNull ?: 0) > 0) return null
            out.write(data)
            val total = m["total"]?.jsonPrimitive?.intOrNull ?: return null
            if (out.size() >= total || data.isEmpty()) return out.toByteArray()
        }
    }

    /** Sends now when the link is up, else queues it (see [queued]). */
    private fun issue(id: String = UUID.randomUUID().toString(), make: suspend (LinkSession) -> String?): String {
        val link = session
        if (link != null && machine.state == NodeMachine.State.Up) {
            scope.launch { sendNow(link, id, make) }
        } else {
            outbox.add(id, make)
            queuedFlow.value = outbox.ids()
            armExpiry()
        }
        return id
    }

    private suspend fun sendNow(link: LinkSession, id: String, make: suspend (LinkSession) -> String?) {
        val made = runCatching { make(link) }
        if (made.exceptionOrNull() is NotSigned) return fail(id, "cancelled")
        val body = made.getOrNull() ?: return fail(id, "gone.card")
        if (!link.send("{\"t\":\"cmd\",\"id\":${quote(id)},\"cmd\":$body}".toByteArray())) fail(id, "busy")
    }

    private suspend fun flush(link: LinkSession) {
        outbox.drain().forEach { (id, make) -> sendNow(link, id, make) }
        queuedFlow.value = outbox.ids()
        armExpiry()
    }

    /** One timer, for the oldest queued command: each says `expired` when its 30 s are up. */
    private fun armExpiry() {
        expiry?.cancel()
        val at = outbox.nextExpiry() ?: return
        expiry = scope.launch {
            delay(maxOf(0, at - clock()))
            outbox.expire().forEach { fail(it, "expired") }
            queuedFlow.value = outbox.ids()
            armExpiry()
        }
    }

    private fun fail(id: String, code: String) {
        resultFlow.tryEmit(failure(id, code))
    }

    private fun failure(id: String, code: String): JsonObject = buildJsonObject {
        put("t", "result"); put("id", id); put("ok", false); put("code", code)
    }

    /** The card as last seen (its `digest`, its `risk`). */
    private fun card(chatId: String, cardId: String): JsonObject? {
        val chats = snapshotFlow.value?.get("chats") as? JsonArray ?: return null
        val chat = chats.map { it.jsonObject }.firstOrNull { it.str("id") == chatId } ?: return null
        val cards = chat["cards"] as? JsonArray ?: return null
        return cards.map { it.jsonObject }.firstOrNull { it.str("id") == cardId }?.takeIf { it.str("digest") != null }
    }

    private fun route(message: JsonObject) {
        messageFlow.tryEmit(message)
        when (message.str("t")) {
            "welcome" -> welcomeFlow.value = message
            "policy" -> welcomeFlow.value?.let { w ->
                val policy = (w["policy"] as? JsonObject).orEmpty() + message.filterKeys { it != "t" && it != "seq" }
                welcomeFlow.value = JsonObject(w + ("policy" to JsonObject(policy)))
            }
            "snapshot" -> snapshotFlow.value = message
            "delta" -> snapshotFlow.value = snapshotFlow.value?.let { merge(it, message) } ?: message
            "tx.page", "tx.delta", "tx.reset" -> transcriptFlow.tryEmit(message)
            "attn.state", "attn.event" -> {
                message["aid"]?.jsonPrimitive?.intOrNull?.let { if (it > lastAid) lastAid = it }
                attentionFlow.tryEmit(message)
            }
            "result" -> resultFlow.tryEmit(message)
            // An owner Mac's directory: the boxes it knows (only a Mac's is taken).
            "devices.set" -> if (deviceFlow.value.kind == dev.kore.link.trust.NodeKind.MAC) {
                (message["records"] as? JsonArray)?.mapNotNull { (it as? JsonObject)?.let(Device::fromJson) }?.let(onDirectory)
            }
        }
    }

    companion object {
        const val QUIET_MS = 15_000L
        const val PROBE_MS = 5_000L
        /** A risky card's Allow signs this mode id, with the card's digest after it. */
        const val APPROVE = "approve."
        /** The Mac waits up to 100 s for its owner on a new fingerprint key. */
        const val RAISE_KEY_MS = 110_000L
        /** Bytes per upload chunk, before base64. */
        const val UPLOAD_CHUNK = 48 * 1024

        /** A delta onto the snapshot: windows and extras replaced when sent, chats upserted by id, removed ids dropped. */
        fun merge(snapshot: JsonObject, delta: JsonObject): JsonObject {
            val chats = LinkedHashMap<String, JsonElement>()
            snapshot["chats"]?.jsonArray?.forEach { c -> c.jsonObject.str("id")?.let { chats[it] = c } }
            delta["chats"]?.jsonArray?.forEach { c -> c.jsonObject.str("id")?.let { chats[it] = c } }
            delta["removed"]?.jsonArray?.forEach { r -> r.jsonPrimitive.contentOrNull?.let { chats.remove(it) } }
            return JsonObject(
                snapshot + mapOf(
                    "rev" to (delta["rev"] ?: snapshot["rev"] ?: JsonNull),
                    "windows" to (delta["windows"] ?: snapshot["windows"] ?: JsonArray(emptyList())),
                    "chats" to JsonArray(chats.values.toList()),
                ) + listOf("mac", "clis", "extras", "ghSignedIn").mapNotNull { k -> delta[k]?.let { k to it } }
            )
        }

        /** The upload's messages in order (link 1.1 shapes): begin with size and SHA-256, the chunks, end. */
        fun uploadFrames(uploadId: String, name: String, mime: String, bytes: ByteArray): List<String> {
            val sha = java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
            val out = ArrayList<String>()
            out += """{"t":"blob.put.begin","uploadId":${quote(uploadId)},"name":${quote(name)},"mime":${quote(mime)},"size":${bytes.size},"sha256":${quote(sha)}}"""
            var index = 0
            var at = 0
            while (at < bytes.size) {
                val end = minOf(bytes.size, at + UPLOAD_CHUNK)
                val data = Base64.getEncoder().encodeToString(bytes.copyOfRange(at, end))
                out += """{"t":"blob.put.chunk","uploadId":${quote(uploadId)},"index":${index++},"data":${quote(data)}}"""
                at = end
            }
            out += """{"t":"blob.put.end","uploadId":${quote(uploadId)}}"""
            return out
        }

        internal fun quote(s: String) = JsonPrimitive(s).toString()
    }
}

internal fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.contentOrNull
internal fun JsonObject.bytes(): ByteArray = toString().toByteArray(Charsets.UTF_8)
