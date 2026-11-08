package dev.kore.link.net

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

/** A node on the tailnet as the phone's own Status or WhoIs sees it. */
data class TailnetNode(
    /** MagicDNS name, `mac.tail1234.ts.net.` */
    val dnsName: String,
    val hostName: String,
    /** `macOS`, `linux`, `android`… as Tailscale reports it. */
    val os: String,
    val online: Boolean,
    val userId: Long?,
    val login: String?,
    val nodeKey: String,
    val ips: List<String>,
    val tags: List<String> = emptyList(),
) {
    /** The address to dial: its first IPv4 tailnet address, else its name. */
    val address: String get() = ips.firstOrNull { '.' in it } ?: ips.firstOrNull() ?: dnsName.trimEnd('.')
    val shortName: String get() = dnsName.substringBefore('.').ifEmpty { hostName }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        /** One node as the shim writes it (`{"dnsName","hostName","os","online","userId","login","nodeKey","ips","tags"}`). */
        fun fromJson(o: JsonObject): TailnetNode? = runCatching {
            fun s(k: String) = (o[k] as? JsonPrimitive)?.contentOrNull
            TailnetNode(
                dnsName = s("dnsName") ?: "",
                hostName = s("hostName") ?: "",
                os = s("os") ?: "",
                online = (o["online"] as? JsonPrimitive)?.booleanOrNull ?: false,
                userId = (o["userId"] as? JsonPrimitive)?.longOrNull?.takeIf { it != 0L },
                login = s("login"),
                nodeKey = s("nodeKey")!!.also { require(it.isNotEmpty()) },
                ips = (o["ips"] as? JsonArray)?.map { (it as JsonPrimitive).content }.orEmpty(),
                tags = (o["tags"] as? JsonArray)?.map { (it as JsonPrimitive).content }.orEmpty(),
            )
        }.getOrNull()

        fun parse(text: String): TailnetNode? = runCatching { fromJson(json.parseToJsonElement(text) as JsonObject) }.getOrNull()
        fun parseList(text: String): List<TailnetNode> =
            runCatching { (json.parseToJsonElement(text) as JsonArray).mapNotNull { fromJson(it as JsonObject) } }.getOrDefault(emptyList())
    }
}

/**
 * The phone's tailnet, as the rest of the app needs it: the embedded node (the `:tailnet` shim) on
 * the phone, a fake in tests. Every call may block (the shim talks to its LocalAPI): call off the
 * main thread.
 */
interface Tailnet {
    /** `NoState`, `NeedsLogin`, `NeedsMachineAuth`, `Starting`, `Running`, `Stopped`. */
    fun state(): String
    /** The interactive sign-in URL while [state] is NeedsLogin; never logged. */
    fun authUrl(): String?
    /** This node, once signed in. */
    fun self(): TailnetNode?
    fun peers(): List<TailnetNode>
    /** Who holds tailnet address [ip], from this node's own WhoIs. */
    fun whois(ip: String): TailnetNode?
    /** TCP to [address]:[port] over the tailnet (blocks until connected; throws when it can't). */
    fun dial(address: String, port: Int, timeoutMs: Long): ByteConn
    fun start()
    fun stop()
    /** Leave KoreNet: drop the node key on the control plane and locally. */
    fun logout()

    companion object {
        const val RUNNING = "Running"
        const val NEEDS_LOGIN = "NeedsLogin"
        const val NEEDS_MACHINE_AUTH = "NeedsMachineAuth"
        const val PORT = 47470
    }
}
