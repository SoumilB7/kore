package dev.kore.link.net

import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * The session's own messages, JSON on stream 0 (interactive), told apart by `t`
 * (`Tests/Fixtures/link/v2/control.json`). Bytes are base64; device ids are UUID strings. Encoded
 * compact with sorted keys, as the Mac's encoder gives them.
 */
sealed class NetControl {
    data class Challenge(val route: String, val device: UUID, val nonce: ByteArray, val v: Int = VERSION) : NetControl()

    data class Hello(
        val service: String,
        val device: UUID,
        val nonce: ByteArray,
        val sig: ByteArray,
        val credit: Long,
        val ticket: ByteArray? = null,
        val enroll: Enroll? = null,
        val v: Int = VERSION,
    ) : NetControl()

    /** Who this phone is, for a server without its record (the Mac's Add device window). */
    data class Enroll(val name: String, val identityKey: ByteArray, val model: String? = null, val kind: String? = "phone", val raiseKey: ByteArray? = null)

    data class Welcome(
        val sig: ByteArray,
        val credit: Long,
        val ticket: ByteArray,
        val resumed: Boolean,
        val abilities: List<String>,
        val devicesRev: Int? = null,
        /** First contact (an enroll): the server's directory, its own record among them. */
        val directory: List<JsonObject>? = null,
        val v: Int = VERSION,
    ) : NetControl()

    data class Credit(val n: Long) : NetControl()

    /** The client's first message after the welcome when it has cursors. */
    data class Resume(val cursors: JsonObject) : NetControl()

    data class Bye(val reason: String) : NetControl()

    fun encoded(): ByteArray = toJson().toString().toByteArray(Charsets.UTF_8)

    fun toJson(): JsonObject = sorted(
        when (this) {
            is Challenge -> mapOf("t" to p("challenge"), "v" to p(v), "route" to p(route), "device" to p(id(device)), "nonce" to p(b64(nonce)))
            is Hello -> buildMap {
                put("t", p("hello")); put("v", p(v)); put("service", p(service)); put("device", p(id(device)))
                put("nonce", p(b64(nonce))); put("sig", p(b64(sig))); put("credit", p(credit))
                ticket?.let { put("ticket", p(b64(it))) }
                enroll?.let { e ->
                    put("enroll", sorted(buildMap {
                        put("name", p(e.name)); put("identityKey", p(b64(e.identityKey)))
                        e.model?.let { put("model", p(it)) }; e.kind?.let { put("kind", p(it)) }; e.raiseKey?.let { put("raiseKey", p(b64(it))) }
                    }))
                }
            }
            is Welcome -> buildMap {
                put("t", p("welcome")); put("v", p(v)); put("sig", p(b64(sig))); put("credit", p(credit)); put("ticket", p(b64(ticket)))
                put("resumed", JsonPrimitive(resumed)); put("abilities", JsonArray(abilities.map(::JsonPrimitive)))
                devicesRev?.let { put("devicesRev", p(it)) }
                directory?.let { put("directory", JsonArray(it)) }
            }
            is Credit -> mapOf("t" to p("credit"), "n" to p(n))
            is Resume -> mapOf("t" to p("resume"), "cursors" to cursors)
            is Bye -> mapOf("t" to p("bye"), "reason" to p(reason))
        }
    )

    companion object {
        const val VERSION = 2

        /** Why a session ended, as `bye` says it. */
        object Reason {
            const val UNKNOWN = "unknown"
            const val REVOKED = "revoked"
            const val PAUSED = "paused"
            const val REPLACED = "replaced"
            const val PROOF = "proof"
            const val REFUSED = "refused"
            const val SERVICE = "service"
            const val VERSION = "version"
            const val TIMEOUT = "timeout"
            const val LIMIT = "limit"
            const val PROTOCOL = "protocol"
        }

        private val json = Json { ignoreUnknownKeys = true }

        /** A control message off stream 0; throws on anything malformed. */
        fun decode(bytes: ByteArray): NetControl {
            val o = json.parseToJsonElement(bytes.decodeToString()) as? JsonObject ?: error("not an object")
            fun s(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: error("no $k")
            fun l(k: String) = (o[k] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: error("no $k")
            fun i(k: String) = (o[k] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull ?: error("no $k")
            fun bytes(k: String) = Base64.getDecoder().decode(s(k))
            fun opt(k: String) = (o[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
            return when (val t = s("t")) {
                "challenge" -> Challenge(s("route"), UUID.fromString(s("device")), bytes("nonce"), i("v"))
                "hello" -> Hello(
                    s("service"), UUID.fromString(s("device")), bytes("nonce"), bytes("sig"), l("credit"), opt("ticket")?.let { Base64.getDecoder().decode(it) },
                    (o["enroll"] as? JsonObject)?.let { e ->
                        fun es(k: String) = (e[k] as? JsonPrimitive)?.contentOrNull
                        Enroll(es("name") ?: error("no name"), Base64.getDecoder().decode(es("identityKey") ?: error("no key")), es("model"), es("kind"),
                            es("raiseKey")?.let { Base64.getDecoder().decode(it) })
                    },
                    i("v"),
                )
                "welcome" -> Welcome(
                    sig = bytes("sig"), credit = l("credit"), ticket = bytes("ticket"),
                    resumed = (o["resumed"] as? JsonPrimitive)?.booleanOrNull ?: error("no resumed"),
                    abilities = (o["abilities"] as? JsonArray ?: error("no abilities")).map { (it as JsonPrimitive).content },
                    devicesRev = (o["devicesRev"] as? JsonPrimitive)?.intOrNull,
                    directory = (o["directory"] as? JsonArray)?.map { it as JsonObject },
                    v = i("v"),
                )
                "credit" -> Credit(l("n").also { require(it > 0) { "credit $it" } })
                "resume" -> Resume(o["cursors"] as? JsonObject ?: error("no cursors"))
                "bye" -> Bye(s("reason"))
                else -> error("unknown control $t")
            }
        }

        private fun p(s: String) = JsonPrimitive(s)
        private fun p(n: Number) = JsonPrimitive(n)
        private fun id(u: UUID) = u.toString().uppercase()
        private fun b64(b: ByteArray): String = Base64.getEncoder().encodeToString(b)

        /** Keys sorted at every level, as the Mac's `.sortedKeys` encoder writes them. */
        fun sorted(map: Map<String, JsonElement>): JsonObject = JsonObject(map.toSortedMap().mapValues { (_, v) -> sortedDeep(v) })

        private fun sortedDeep(e: JsonElement): JsonElement = when (e) {
            is JsonObject -> sorted(e)
            is JsonArray -> JsonArray(e.map(::sortedDeep))
            else -> e
        }
    }
}

internal fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.contentOrNull
