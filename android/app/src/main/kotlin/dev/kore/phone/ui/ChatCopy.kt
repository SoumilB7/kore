package dev.kore.phone.ui

import android.app.Activity
import dev.kore.link.node.Control
import dev.kore.link.node.NodeClient
import dev.kore.link.trust.NodeKind
import dev.kore.phone.kore
import kotlinx.coroutines.launch

/**
 * Copy and paste a chat, as the Mac's ⌘C/⌘V on a History row (cap "copyVia", owner 2026-11-24): Copy
 * on a chat here holds it on this phone; Paste chat on a window, on any device, asks the Mac to
 * copy it there (`chat.copyVia`). The Mac runs the copy with its own grants, from itself or one
 * of its boxes to itself or one of its boxes; the phone never moves a chat, and the source stays.
 */
object ChatCopy {
    /** The chat held: where it is, and what it's called. */
    data class Clip(
        val device: String, val deviceName: String, val windowId: String, val chatId: String?, val sessionId: String?,
        val provider: String, val title: String,
    )

    /** A device as a copy's route needs it: its id, a Mac or not, the Macs that told this phone of it. */
    data class Dev(val id: String, val name: String, val mac: Boolean, val via: List<String>)

    /** Which Mac runs a copy from [from] to [to], or the line why none can. */
    sealed class Route {
        data class Via(val mac: String) : Route()
        data class No(val line: String) : Route()
    }

    fun route(from: Dev, to: Dev): Route = when {
        from.mac && to.mac -> if (from.id == to.id) Route.Via(from.id) else Route.No("Copying between two Macs isn't offered")
        from.mac -> if (to.via.isEmpty() || from.id in to.via) Route.Via(from.id) else Route.No("${to.name} isn't one of ${from.name}'s boxes")
        to.mac -> if (from.via.isEmpty() || to.id in from.via) Route.Via(to.id) else Route.No("${from.name} isn't one of ${to.name}'s boxes")
        else -> (from.via.firstOrNull { it in to.via } ?: from.via.firstOrNull() ?: to.via.firstOrNull())?.let { Route.Via(it) }
            ?: Route.No("No Mac knows ${from.name} to copy from it")
    }

    /** The command for [clip] into [windowId] on [to], run by the Mac [mac]: an end on that Mac names no device. */
    fun command(clip: Clip, to: String, windowId: String, mac: String) = Control.copyVia(
        Control.CopyEnd(clip.device.takeIf { it != mac }, clip.windowId, clip.chatId, clip.sessionId),
        Control.CopyEnd(to.takeIf { it != mac }, windowId),
        clip.provider, clip.title,
    )

    /** The Mac's word that it takes `chat.copyVia`. */
    const val CAP = "copyVia"

    /** How long a copy may take before the phone says it got no answer (a long chat to a slow box). */
    const val WAIT_MS = 15 * 60_000L
}

/** [n] as a copy's route reads it. */
private fun copyDev(n: NodeClient): ChatCopy.Dev {
    val d = n.device.value
    return ChatCopy.Dev(n.id.toString(), n.name, d.kind == NodeKind.MAC, d.via.map { it.toString() })
}

/** Copy on a chat: whether this device's Mac takes copies from here (its caps say so). */
fun Activity.copyOffered(n: NodeClient?): Boolean {
    n ?: return false
    val mesh = kore.mesh
    val mac = if (n.device.value.kind == NodeKind.MAC) n else n.device.value.via.firstNotNullOfOrNull { id -> mesh.node(id) } ?: return false
    return ChatCopy.CAP in mesh.caps(mac)
}

/** Holds a chat for Paste chat, as the Mac's Copy does; the line says so. */
fun Activity.copyChat(clip: ChatCopy.Clip) {
    kore.chatClip = clip
    Quiet.say(this, "Copied “${clip.title}” · paste it on a window")
}

/** Paste chat on [windowName] of [to]: the Mac runs the copy, a line while it does and one at its end. */
fun Activity.pasteChat(to: NodeClient, windowId: String, windowName: String) {
    val clip = kore.chatClip ?: return
    val mesh = kore.mesh
    val from = mesh.node(clip.device) ?: return Quiet.say(this, "${clip.deviceName} isn't one of this phone's devices any more")
    val mac = when (val r = ChatCopy.route(copyDev(from), copyDev(to))) {
        is ChatCopy.Route.No -> return Quiet.say(this, r.line)
        is ChatCopy.Route.Via -> mesh.node(r.mac) ?: return Quiet.say(this, "That Mac isn't one of this phone's devices")
    }
    if (ChatCopy.CAP !in mesh.caps(mac)) return Quiet.say(this, "Update Kore on ${mac.name} to copy chats from here")
    val where = if (to.id == mac.id) windowName else to.name
    Quiet.say(this, "Copying “${clip.title}” to $where…", holdMs = ChatCopy.WAIT_MS)
    kore.scope.launch {
        val r = mac.call(ChatCopy.command(clip, to.id.toString(), windowId, mac.id.toString()), timeoutMs = ChatCopy.WAIT_MS)
        val line = when {
            r.bool("ok") -> "Copied “${clip.title}” to $where"
            // Never sent: out of reach, or queued and given up on.
            r.str("code") == "offline" || r.str("code") == "expired" -> "Not copied · ${mac.name} is out of reach"
            // Sent, but its answer never came (the link dropped): it may have been made.
            r.str("code") == "timeout" -> "No word from ${mac.name} · look there before copying again"
            else -> refusalWords(r.str("code"), r.str("message"))
        }
        // The line ends where it started, and the screen in front says it too if another took its place.
        runOnUiThread {
            Quiet.say(this@pasteChat, line)
            kore.frontActivity?.takeIf { it !== this@pasteChat }?.let { Quiet.say(it, line) }
        }
    }
}
