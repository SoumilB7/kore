package dev.kore.phone.ui

import android.app.Activity
import dev.kore.link.node.Control
import kotlinx.serialization.json.JsonObject

/**
 * Closing a chat's tab from the phone, as Arsenal's `kore_close` closes one (the owner,
 * 2026-11-17): History keeps it, and nothing in it is lost. While closing would lose work it's
 * refused, never asked, with the first reason in one line: a turn running (or messages waiting
 * behind it), a message waiting for the network, a card waiting, text or files in this phone's
 * composer, sub-agents or background commands still running. The Mac or box checks again.
 */
object CloseHold {
    /** Why [chat] can't close now, or null. [draft] and [files]: this phone's composer for it. */
    fun reason(chat: JsonObject, draft: String? = null, files: Int = 0): String? {
        val background = Waiting.of(chat)
        return when {
            chat.bool("running") || chat.str("state") == "working" || (chat["queued"].int() ?: 0) > 0 -> "It's working: stop it first."
            chat.obj("rescue")?.str("connection") == "offline" -> "A message in it waits for the network."
            chat.objs("cards").isNotEmpty() || chat.str("state") == "needsYou" -> "A card in it waits for an answer."
            !draft.isNullOrBlank() -> "Its message isn't sent yet."
            files > 0 -> "Its attachments aren't sent yet."
            (background?.agents ?: 0) > 0 -> "Its sub-agents are running."
            (background?.commands ?: 0) > 0 -> "Commands it started still run."
            else -> null
        }
    }

    /**
     * Whether Close shows for [chat]: the Mac says so in its `can` (full control or the phone's
     * ask view); a box closes any of its chats, and says so from 1.13 on.
     */
    fun offered(chat: JsonObject, box: Boolean): Boolean {
        val can = chat.obj("can")
        return can?.bool("close") == true || (box && can?.containsKey("close") != true)
    }
}

/**
 * Closes [chat]'s tab (`chat.close`, never forced): refused with [CloseHold]'s one line, or the
 * device's own when it says no (a turn that just started: `confirm.close`). [done] once closed.
 */
fun Activity.closeChat(chat: JsonObject, draft: String? = null, files: Int = 0, done: () -> Unit = {}) {
    val id = chat.str("id") ?: return
    CloseHold.reason(chat, draft, files)?.let { return Quiet.say(this, it) }
    act(Control.close(id)) { done() }
}
