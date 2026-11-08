package dev.kore.link.trust

import java.util.Base64
import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

/** What a device is (phase 18 §1 "Trust"). */
enum class NodeKind(val wire: String) {
    MAC("mac"), BOX("box"), PHONE("phone");

    companion object {
        fun of(s: String?): NodeKind? = entries.firstOrNull { it.wire == s }
    }
}

/**
 * Another device as this phone knows it: a Mac it pinned on first Allow, or a box from the
 * directory a Mac sent. The shape is `DeviceRecord`'s JSON (KoreTrust), dates as ISO 8601.
 */
data class Device(
    val id: UUID,
    val name: String,
    val kind: NodeKind,
    /** SPKI DER: the key its proofs are checked against. */
    val identityKey: ByteArray,
    /** Its Tailscale node keys, newest last (at most 3). */
    val nodeKeys: List<String>,
    val fqdn: String,
    val abilities: List<String> = emptyList(),
    val owner: Boolean = false,
    val userId: Long? = null,
    val tags: List<String> = emptyList(),
    val raiseKey: ByteArray? = null,
    val paused: Boolean = false,
) {
    /** `box-1.tail1234.ts.net.` → `box-1`. */
    val shortName: String get() = fqdn.substringBefore('.').ifEmpty { name }

    fun withNodeKey(key: String): Device =
        if (key in nodeKeys) this else copy(nodeKeys = (nodeKeys + key).takeLast(MAX_NODE_KEYS))

    fun toJson(): JsonObject = buildJsonObject {
        put("id", id.toString().uppercase())
        put("name", name)
        put("kind", kind.wire)
        put("abilities", JsonArray(abilities.map(::JsonPrimitive)))
        if (owner) put("owner", true)
        put("identityKey", b64(identityKey))
        put("nodeKeys", JsonArray(nodeKeys.map(::JsonPrimitive)))
        userId?.let { put("userId", it) }
        if (tags.isNotEmpty()) put("tags", JsonArray(tags.map(::JsonPrimitive)))
        put("fqdn", fqdn)
        raiseKey?.let { put("raiseKey", b64(it)) }
        if (paused) put("paused", true)
    }

    override fun equals(other: Any?): Boolean = other is Device && toJson() == other.toJson()
    override fun hashCode(): Int = toJson().hashCode()

    companion object {
        const val MAX_NODE_KEYS = 3

        /** A record off the wire; null when a field is missing or wrong. */
        fun fromJson(o: JsonObject): Device? = runCatching {
            Device(
                id = UUID.fromString(o.s("id")!!),
                name = o.s("name")!!,
                kind = NodeKind.of(o.s("kind"))!!,
                identityKey = Base64.getDecoder().decode(o.s("identityKey")!!),
                nodeKeys = (o["nodeKeys"] as JsonArray).map { (it as JsonPrimitive).content },
                fqdn = o.s("fqdn") ?: "",
                abilities = (o["abilities"] as? JsonArray)?.map { (it as JsonPrimitive).content }.orEmpty(),
                owner = (o["owner"] as? JsonPrimitive)?.booleanOrNull ?: false,
                userId = (o["userId"] as? JsonPrimitive)?.longOrNull,
                tags = (o["tags"] as? JsonArray)?.map { (it as JsonPrimitive).content }.orEmpty(),
                raiseKey = o.s("raiseKey")?.let { Base64.getDecoder().decode(it) },
                paused = (o["paused"] as? JsonPrimitive)?.booleanOrNull ?: false,
            ).takeIf { it.identityKey.isNotEmpty() && it.nodeKeys.size <= MAX_NODE_KEYS }
        }.getOrNull()

        private fun JsonObject.s(k: String) = (this[k] as? JsonPrimitive)?.contentOrNull
        internal fun b64(b: ByteArray): String = Base64.getEncoder().encodeToString(b)
    }
}

/**
 * The devices this phone knows, persisted by [save] (the app keeps it in its private files). A Mac
 * is pinned once, on its first welcome; boxes come from an owner Mac's directory. The Mac that
 * sent a directory is the only one whose later directories replace it.
 */
class DeviceBook(initial: List<Device> = emptyList(), private val save: (List<Device>) -> Unit = {}) {
    private val devices = LinkedHashMap<UUID, Device>().apply { initial.forEach { put(it.id, it) } }

    @Synchronized fun all(): List<Device> = devices.values.toList()
    @Synchronized fun get(id: UUID): Device? = devices[id]

    @Synchronized fun put(device: Device) {
        devices[device.id] = device
        save(devices.values.toList())
    }

    @Synchronized fun remove(id: UUID) {
        if (devices.remove(id) != null) save(devices.values.toList())
    }

    @Synchronized fun clear() {
        devices.clear()
        save(emptyList())
    }

    /**
     * An owner Mac's directory: every box and Mac it lists, except this phone itself. Records the
     * phone already pinned keep their node keys (and a Mac's identity key never changes here).
     */
    @Synchronized fun applyDirectory(from: UUID, self: UUID, records: List<Device>) {
        val mac = devices[from] ?: return
        if (mac.kind != NodeKind.MAC) return
        for (r in records) {
            if (r.id == self || r.kind == NodeKind.PHONE) continue
            val known = devices[r.id]
            devices[r.id] = if (known != null && known.kind == NodeKind.MAC) known.copy(name = r.name)
            else if (known != null) r.copy(nodeKeys = (known.nodeKeys + r.nodeKeys).distinct().takeLast(Device.MAX_NODE_KEYS))
            else r
        }
        save(devices.values.toList())
    }
}
