package dev.kore.link.node

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Each CLI login's plan windows as a node pushes them (link 1.14 `clis[].usage`, the Mac's
 * `AccountUsage`): read from the snapshot as it stands, never asked for on a timer. A node reads
 * its logins again when the phone sends [Control.accountUsage] (a screen opening); what it finds
 * comes back in the next delta. Read-only: nothing here switches or signs in.
 */
object AccountUsage {
    /** One window: [kind] "5h" or "7d", [used] whole percent (past 100 once over), [resetsAt] ms since 1970. */
    data class Limit(val kind: String, val used: Int, val resetsAt: Long?)

    /** One login of [provider]'s CLI: "main" or an added one; [email] as the node shows it (masked where its privacy says). */
    data class Login(
        val provider: String,
        val login: String,
        val email: String?,
        val active: Boolean,
        val plan: String?,
        val limits: List<Limit>,
    )

    const val FIVE_HOUR = "5h"
    const val WEEK = "7d"

    /** Every CLI's logins, in the node's order; none from a node that sends no usage. */
    fun of(snapshot: JsonObject?): List<Login> =
        (snapshot?.get("clis") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.flatMap { cli ->
            val provider = cli.str("provider") ?: return@flatMap emptyList()
            (cli["usage"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonObject)?.let { u -> login(provider, u) } }
        }

    /** The CLIs whose usage the node sends (a node from before 1.14 sends none). */
    fun providers(snapshot: JsonObject?): List<String> =
        (snapshot?.get("clis") as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }.filter { it["usage"] is JsonArray }.mapNotNull { it.str("provider") }

    /**
     * The login a chat runs on: the one its controls name (a box's Claude chat, `controls.login`),
     * else its CLI's active one.
     */
    fun forChat(snapshot: JsonObject?, chat: JsonObject?): Login? {
        val provider = chat?.str("provider") ?: return null
        val mine = of(snapshot).filter { it.provider == provider }
        val named = (chat["controls"] as? JsonObject)?.str("login")
        return named?.let { n -> mine.firstOrNull { it.login == n } } ?: mine.firstOrNull { it.active } ?: mine.singleOrNull()
    }

    private fun login(provider: String, u: JsonObject): Login? {
        val id = u.str("login") ?: return null
        val limits = (u["limits"] as? JsonArray).orEmpty().mapNotNull { l ->
            val o = l as? JsonObject ?: return@mapNotNull null
            val kind = o.str("kind") ?: return@mapNotNull null
            val used = (o["used"] as? JsonPrimitive)?.intOrNull ?: return@mapNotNull null
            Limit(kind, used, (o["resetsAt"] as? JsonPrimitive)?.longOrNull)
        }
        return Login(provider, id, u.str("email"), (u["active"] as? JsonPrimitive)?.booleanOrNull == true, u.str("plan"), limits)
    }
}
