package dev.kore.phone.ui

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/** Small readers for the wire's JSON. */
fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
fun JsonObject.bool(key: String): Boolean = (this[key] as? JsonPrimitive)?.booleanOrNull ?: false
fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
fun JsonObject.objs(key: String): List<JsonObject> = (this[key] as? JsonArray)?.mapNotNull { it as? JsonObject }.orEmpty()
fun JsonObject.strs(key: String): List<String> = (this[key] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()
fun JsonElement?.int(): Int? = (this as? JsonPrimitive)?.content?.toIntOrNull()

/** The chats of a snapshot, by id. */
fun JsonObject.chatsById(): Map<String, JsonObject> = objs("chats").associateBy { it.str("id") ?: "" }
