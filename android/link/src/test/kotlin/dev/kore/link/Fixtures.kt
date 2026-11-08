package dev.kore.link

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** `Tests/Fixtures/link/v2`, read in place: the contract the Swift side tests against too. */
object Fixtures {
    private val dir = File(System.getProperty("kore.fixtures") ?: error("kore.fixtures not set"))

    fun json(name: String): JsonObject = Json.parseToJsonElement(File(dir, name).readText()) as JsonObject

    fun hex(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }
    fun b64(s: String): ByteArray = java.util.Base64.getDecoder().decode(s)

    fun JsonObject.s(k: String): String = (this[k] as JsonPrimitive).content
    fun JsonObject.o(k: String): JsonObject = this[k] as JsonObject
    fun JsonObject.a(k: String): List<JsonObject> = (this[k] as JsonArray).map { it as JsonObject }
}
