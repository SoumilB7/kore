package dev.kore.phone.link

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** One chat's followed window of entries, kept from `tx.page`, `tx.delta` and `tx.reset`. */
class Transcript(val chatId: String) {
    private val byId = LinkedHashMap<String, JsonObject>()
    var order: List<String> = emptyList()
        private set
    var hasEarlier = false
        private set

    val entries: List<JsonObject> get() = order.mapNotNull { byId[it] }

    /** Applies one message for this chat; true when it changed anything. */
    fun apply(m: JsonObject): Boolean {
        if (m["chatId"]?.jsonPrimitive?.content != chatId) return false
        when (m["t"]?.jsonPrimitive?.content) {
            "tx.page" -> {
                byId.clear()
                val list = m["entries"]?.jsonArray?.map { it.jsonObject }.orEmpty()
                list.forEach { byId[id(it)] = it }
                order = list.map(::id)
                hasEarlier = m["hasEarlier"]?.jsonPrimitive?.booleanOrNull ?: false
            }
            "tx.delta" -> {
                val removed = m["removed"]?.jsonArray?.map { it.jsonPrimitive.content }?.toSet().orEmpty()
                removed.forEach { byId.remove(it) }
                val upserts = m["upserts"]?.jsonArray?.map { it.jsonObject }.orEmpty()
                upserts.forEach { byId[id(it)] = it }
                order = m["order"]?.jsonArray?.map { it.jsonPrimitive.content }
                    ?: (order.filter { it !in removed } + upserts.map(::id).filter { it !in order })
                m["hasEarlier"]?.jsonPrimitive?.booleanOrNull?.let { hasEarlier = it }
            }
            "tx.reset" -> {
                byId.clear()
                order = emptyList()
            }
            else -> return false
        }
        return true
    }

    private fun id(e: JsonObject) = e["id"]!!.jsonPrimitive.content
}
