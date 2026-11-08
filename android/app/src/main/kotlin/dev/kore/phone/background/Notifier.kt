package dev.kore.phone.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import dev.kore.phone.R
import dev.kore.phone.ui.ChatActivity
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * Alerts from one device's attention stream: one notification per chat, gone when the card is
 * answered anywhere. The lock screen only says that a chat needs you; the text says which, and
 * names the device ([nodeName], null with one). A tap opens the chat on its device.
 */
class Notifier(private val context: Context, private val node: String = "", private val nodeName: () -> String? = { null }) {
    private val manager = context.getSystemService(NotificationManager::class.java)
    /** Open cards, by key ("chatId/cardId"), and what each belongs to. */
    private val open = mutableMapOf<String, Item>()

    private data class Item(val chatId: String, val window: String, val title: String, val kind: String)

    init {
        manager.createNotificationChannels(
            listOf(
                NotificationChannel(NEEDS, "Needs you", NotificationManager.IMPORTANCE_HIGH),
                NotificationChannel(FAILED, "Failed", NotificationManager.IMPORTANCE_HIGH),
                NotificationChannel(FINISHED, "Finished", NotificationManager.IMPORTANCE_DEFAULT),
            ).onEach { it.lockscreenVisibility = Notification.VISIBILITY_PRIVATE }
        )
    }

    /** One `attn.state` or `attn.event`; [onScreen] is the chat open in the app, never alerted. */
    @Synchronized fun handle(message: JsonObject, onScreen: String?) {
        when (message.str("t")) {
            "attn.state" -> {
                val items = (message["open"] as? JsonArray)?.map { it.jsonObject } ?: emptyList()
                val keys = items.mapNotNull { it.str("key") }.toSet()
                (open.keys - keys).toList().forEach { clear(it) }
                items.forEach { add(it, onScreen) }
            }
            "attn.event" -> when (message.str("op")) {
                "open" -> (message["item"] as? JsonObject)?.let { add(it, onScreen) }
                "clear" -> message.str("key")?.let { clear(it) }
                "turn" -> (message["turn"] as? JsonObject)?.let { turn(it, onScreen) }
            }
        }
    }

    private fun add(item: JsonObject, onScreen: String?) {
        val key = item.str("key") ?: return
        val chatId = item.str("chatId") ?: return
        if (key in open) return
        open[key] = Item(chatId, item.str("window") ?: "", item.str("chatTitle") ?: "A chat", item.str("kind") ?: "")
        if (chatId == onScreen) return
        post(NEEDS, chatId, "${item.str("window") ?: "Kore"} · ${item.str("chatTitle") ?: "a chat"}", "Needs you")
    }

    private fun clear(key: String) {
        val item = open.remove(key) ?: return
        if (open.values.none { it.chatId == item.chatId }) manager.cancel(id(item.chatId))
    }

    private fun turn(turn: JsonObject, onScreen: String?) {
        val chatId = turn.str("chatId") ?: return
        if (chatId == onScreen || open.values.any { it.chatId == chatId }) return
        val failed = turn.str("outcome") == "failed"
        val where = "${turn.str("window") ?: "Kore"} · ${turn.str("chatTitle") ?: "a chat"}"
        post(if (failed) FAILED else FINISHED, chatId, where, if (failed) "Failed" else "Finished")
    }

    private fun post(channel: String, chatId: String, title: String, what: String) {
        val open = Intent(context, ChatActivity::class.java).putExtra("chat", chatId).putExtra("node", node)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val tap = PendingIntent.getActivity(context, id(chatId), open, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val public = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.kore_mark)
            .setContentTitle("Kore")
            .setContentText(if (channel == NEEDS) "A chat needs you" else "A chat $what".lowercase().replaceFirstChar { it.uppercase() })
            .build()
        val note = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.kore_mark)
            .setContentTitle(title)
            .setContentText(what)
            .apply { nodeName()?.let { setSubText(it) } }
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setLocalOnly(true)
            .setAllowSystemGeneratedContextualActions(false)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setGroup("kore")
            .build()
        runCatching { manager.notify(id(chatId), note) }
    }

    /** Everything this link raised: the link ended. */
    @Synchronized fun clearAll() {
        open.values.map { it.chatId }.toSet().forEach { manager.cancel(id(it)) }
        open.clear()
    }

    private fun id(chatId: String) = 1000 + ("$node/$chatId".hashCode() and 0x7fffff)
    private fun JsonObject.str(key: String) = this[key]?.jsonPrimitive?.contentOrNull

    companion object {
        const val NEEDS = "needs-you"
        const val FAILED = "failed"
        const val FINISHED = "finished"
    }
}
