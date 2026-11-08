package dev.kore.phone.background

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.TaskStackBuilder
import android.content.Context
import android.content.Intent
import dev.kore.phone.R
import dev.kore.phone.ui.ChatActivity
import dev.kore.phone.ui.DeviceActivity
import dev.kore.phone.ui.HomeActivity
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Kore's accent, for the status-bar mark. */
internal val ACCENT = dev.kore.phone.ui.Tone.accent

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
        // Spec §6: "Kore · {device} · now", "{chat} needs you", then what it asks.
        post(NEEDS, chatId, "${item.str("chatTitle") ?: "A chat"} needs you", ask(item.str("kind")))
        summarize()
    }

    private fun clear(key: String) {
        val item = open.remove(key) ?: return
        if (open.values.none { it.chatId == item.chatId }) manager.cancel(id(item.chatId))
        summarize()
    }

    /**
     * Two or more chats needing you fold under one "N chats need you", a line per chat (spec §6);
     * one or none, the fold goes.
     */
    private fun summarize() {
        val chats = open.values.distinctBy { it.chatId }
        if (chats.size < 2) return manager.cancel(summaryId())
        val style = Notification.InboxStyle().setBigContentTitle(folded(chats.size))
        chats.take(6).forEach { style.addLine("${it.title} · ${ask(it.kind)}") }
        val note = Notification.Builder(context, NEEDS)
            .setSmallIcon(R.drawable.ic_notify).setColor(ACCENT)
            .setContentTitle(folded(chats.size))
            .setContentText(chats.joinToString(", ") { it.title })
            .setStyle(style)
            .apply { nodeName()?.let { setSubText(it) } }
            .setGroup(GROUP)
            .setGroupSummary(true)
            .setLocalOnly(true)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(Notification.Builder(context, NEEDS).setSmallIcon(R.drawable.ic_notify).setColor(ACCENT).setContentTitle("Kore").setContentText(folded(chats.size)).build())
            .setContentIntent(PendingIntent.getActivity(context, summaryId(), Intent(context, HomeActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            .setAutoCancel(true)
            .build()
        runCatching { manager.notify(summaryId(), note) }
    }

    private fun turn(turn: JsonObject, onScreen: String?) {
        val chatId = turn.str("chatId") ?: return
        if (chatId == onScreen || open.values.any { it.chatId == chatId }) return
        val failed = turn.str("outcome") == "failed"
        post(if (failed) FAILED else FINISHED, chatId, turn.str("chatTitle") ?: "A chat", if (failed) "Failed" else "Finished")
    }

    private fun post(channel: String, chatId: String, title: String, what: String) {
        // Back from the chat goes to its device, then Home, as if opened there.
        val tap = TaskStackBuilder.create(context)
            .addNextIntent(Intent(context, HomeActivity::class.java))
            .apply { if (node.isNotEmpty()) addNextIntent(Intent(context, DeviceActivity::class.java).putExtra("node", node)) }
            .addNextIntent(Intent(context, ChatActivity::class.java).putExtra("chat", chatId).putExtra("node", node))
            .getPendingIntent(id(chatId), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val public = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_notify).setColor(ACCENT)
            .setContentTitle("Kore")
            .setContentText(if (channel == NEEDS) "A chat needs you" else "A chat $what".lowercase().replaceFirstChar { it.uppercase() })
            .build()
        val note = Notification.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_notify).setColor(ACCENT)
            .setContentTitle(title)
            .setContentText(what)
            .apply { nodeName()?.let { setSubText(it) } }
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setLocalOnly(true)
            .setAllowSystemGeneratedContextualActions(false)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setGroup(GROUP)
            .build()
        runCatching { manager.notify(id(chatId), note) }
    }

    /** Everything this link raised: the link ended. */
    @Synchronized fun clearAll() {
        open.values.map { it.chatId }.toSet().forEach { manager.cancel(id(it)) }
        open.clear()
    }

    private fun id(chatId: String) = 1000 + ("$node/$chatId".hashCode() and 0x7fffff)
    private fun summaryId() = 1000 + ("$node/needs-you".hashCode() and 0x7fffff)
    private fun JsonObject.str(key: String) = this[key]?.jsonPrimitive?.contentOrNull

    companion object {
        /** What a card asks, by its kind: the notification's text (never the card's own words). */
        fun ask(kind: String?): String = when (kind) {
            "permission" -> "Asks to go ahead"
            "question" -> "Has a question"
            "plan" -> "Has a plan to approve"
            "planReady" -> "Plan ready to build"
            "signIn" -> "Needs a sign-in on the Mac"
            else -> "Waiting for you"
        }

        /** The fold's title. */
        fun folded(n: Int) = "$n chats need you"

        private const val GROUP = "kore"
        const val NEEDS = "needs-you"
        const val FAILED = "failed"
        const val FINISHED = "finished"
    }
}
