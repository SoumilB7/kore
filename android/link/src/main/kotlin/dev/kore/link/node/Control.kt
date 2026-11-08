package dev.kore.link.node

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Link commands and reads (link 1.11 bodies, unchanged under link 2.0), as the `cmd` objects and
 * requests the phone sends. Nothing here widens what a chat may do without asking, spends credit
 * or touches a login; raising a mode goes through `raise` (a signature). Every node checks every
 * one again against what this phone may do there (read + ask).
 */
object Control {
    /** Where a new chat goes: a board (and one of its sections) or a tab group. */
    sealed class Place {
        data class Board(val boardTabId: String, val sectionId: String? = null) : Place()
        data class Group(val groupId: String) : Place()
    }

    private fun cmd(type: String, body: JsonObjectBuilder.() -> Unit = {}) = buildJsonObject { put("type", type); body() }
    private fun JsonObjectBuilder.putOpt(key: String, value: String?) { if (value != null) put(key, value) }

    // Chat (step 1)

    fun rename(chatId: String, title: String) = cmd("chat.rename") {
        put("chatId", chatId)
        // One line, at most 200 characters, as the Mac takes it.
        put("title", title.lines().joinToString(" ").trim().take(200))
    }
    fun close(chatId: String, force: Boolean = false) = cmd("chat.close") { put("chatId", chatId); if (force) put("force", true) }
    fun select(chatId: String) = cmd("chat.select") { put("chatId", chatId) }
    fun setModel(chatId: String, modelId: String) = cmd("chat.setModel") { put("chatId", chatId); put("modelId", modelId) }
    fun setEffort(chatId: String, level: String) = cmd("chat.setEffort") { put("chatId", chatId); put("level", level) }
    fun setFast(chatId: String, on: Boolean) = cmd("chat.setFast") { put("chatId", chatId); put("on", on) }
    fun setPlan(chatId: String, on: Boolean) = cmd("chat.setPlan") { put("chatId", chatId); put("on", on) }
    fun compact(chatId: String, instructions: String? = null) = cmd("chat.compact") {
        put("chatId", chatId)
        instructions?.trim()?.takeIf { it.isNotEmpty() }?.let { put("instructions", it) }
    }
    /** [at] is a percentage, or null for off (sent as an explicit null). */
    fun setAutoCompact(chatId: String, at: Int?) = cmd("chat.setAutoCompact") { put("chatId", chatId); put("at", at?.let(::JsonPrimitive) ?: JsonNull) }
    fun fork(chatId: String, entryId: String, after: Boolean) = cmd("chat.fork") { put("chatId", chatId); put("entryId", entryId); put("after", after) }
    /** Without [turnId], the stalled turn; with it, the retryable ended turn. */
    fun retry(chatId: String, turnId: String? = null) = cmd("chat.retry") { put("chatId", chatId); putOpt("turnId", turnId) }
    fun continueTurn(chatId: String) = cmd("chat.continue") { put("chatId", chatId) }
    fun sendAtReset(chatId: String, text: String, blobs: List<String> = emptyList()) = cmd("chat.sendAtReset") {
        put("chatId", chatId)
        put("text", text)
        if (blobs.isNotEmpty()) put("blobs", JsonArray(blobs.map(::JsonPrimitive)))
    }
    fun cancelContinue(chatId: String) = cmd("chat.cancelContinue") { put("chatId", chatId) }
    // The basics (link 1.0).

    fun send(chatId: String, text: String, blobs: List<String> = emptyList()) = cmd("chat.send") {
        put("chatId", chatId)
        put("text", text)
        if (blobs.isNotEmpty()) put("blobs", JsonArray(blobs.map(::JsonPrimitive)))
    }
    fun stop(chatId: String) = cmd("chat.stop") { put("chatId", chatId) }
    /** Lowers the chat's mode; a higher one is refused (`denied.raiseMode`) and goes through [raise]. */
    fun setMode(chatId: String, modeId: String) = cmd("chat.setMode") { put("chatId", chatId); put("modeId", modeId) }
    /** A plain card answer: [digest] is the card's as last seen, so a changed card isn't answered. */
    fun answer(chatId: String, cardId: String, action: String, digest: String, answers: Map<String, List<String>>? = null) = cmd("chat.answer") {
        put("chatId", chatId); put("cardId", cardId); put("action", action); put("digest", digest)
        answers?.let { a -> put("answers", buildJsonObject { a.forEach { (q, labels) -> put(q, JsonArray(labels.map(::JsonPrimitive))) } }) }
    }

    // Remote create (phase 18 §3): a new chat on the device in context. On a Mac: a tab in one of
    // its windows; on a box: in a folder already open there.

    /** A box's new chat, in a folder it already serves. */
    fun newChatInFolder(folder: String, provider: String) = cmd("chat.new") { put("folder", folder); put("provider", provider) }
    /** The folders a box serves (its windows). */
    fun foldersList() = cmd("folders.list")

    fun newChat(windowId: String, provider: String, modelId: String? = null, place: Place? = null) = cmd("chat.new") {
        put("windowId", windowId)
        put("provider", provider)
        putOpt("modelId", modelId)
        when (place) {
            is Place.Board -> put("place", buildJsonObject { put("boardTabId", place.boardTabId); putOpt("sectionId", place.sectionId) })
            is Place.Group -> put("place", buildJsonObject { put("groupId", place.groupId) })
            null -> Unit
        }
    }

    // Arsenal: a chat's tier for agents driving Kore. A raise from the chat's current tier (off
    // counts as lowest) needs the fingerprint (a `raise`); lowering, off and stopping all don't.
    // `full` is never sent.

    /** Arsenal's tiers by wire id, lowest first. */
    val ARSENAL_TIERS = listOf("off", "watch", "own", "drive")
    /** A tier's name as Kore shows it. */
    fun arsenalName(tier: String?): String = when (tier ?: "off") {
        "off" -> "Off"
        "watch" -> "Read"
        "own" -> "Act limited"
        "drive" -> "Act unlimited"
        else -> tier!!
    }
    /** Whether moving a chat from [from] to [to] raises it (and so needs the fingerprint). */
    fun arsenalRaises(from: String?, to: String): Boolean = ARSENAL_TIERS.indexOf(to) > maxOf(ARSENAL_TIERS.indexOf(from ?: "off"), 0)
    fun setArsenal(chatId: String, tier: String) = cmd("chat.setArsenal") { put("chatId", chatId); put("tier", tier) }
    fun arsenalStopAll() = cmd("arsenal.stopAll")

    // Tabs, groups, boards, windows, history (step 2)

    fun tabMove(windowId: String, tabId: String, index: Int) = cmd("tab.move") { put("windowId", windowId); put("tabId", tabId); put("index", index) }
    fun tabReopen(windowId: String) = cmd("tab.reopen") { put("windowId", windowId) }
    /** [groupId]: an id, null to take the tab out of its group, or [NEW_GROUP]. */
    fun groupSet(windowId: String, tabId: String, groupId: String?) = cmd("group.set") {
        put("windowId", windowId); put("tabId", tabId); put("groupId", groupId?.let(::JsonPrimitive) ?: JsonNull)
    }
    fun groupEdit(windowId: String, groupId: String, name: String? = null, color: String? = null, folded: Boolean? = null) = cmd("group.edit") {
        put("windowId", windowId); put("groupId", groupId)
        putOpt("name", name?.trim()); putOpt("color", color); folded?.let { put("folded", it) }
    }
    fun groupUngroup(windowId: String, groupId: String) = cmd("group.ungroup") { put("windowId", windowId); put("groupId", groupId) }
    fun groupClose(windowId: String, groupId: String, force: Boolean = false) = cmd("group.close") {
        put("windowId", windowId); put("groupId", groupId); if (force) put("force", true)
    }
    fun boardNew(windowId: String) = cmd("board.new") { put("windowId", windowId) }
    /** [sectionId]: a section, [NEW_SECTION], or null for the board's own choice. */
    fun boardAttach(windowId: String, chatId: String, boardTabId: String, sectionId: String? = null) = cmd("board.attach") {
        put("windowId", windowId); put("chatId", chatId); put("boardTabId", boardTabId); putOpt("sectionId", sectionId)
    }
    fun boardDetach(windowId: String, boardTabId: String, chatId: String, toTab: Boolean = false) = cmd("board.detach") {
        put("windowId", windowId); put("boardTabId", boardTabId); put("chatId", chatId); put("toTab", toTab)
    }
    /** One change per command: a name, a swatch (null for none), a merge, or a removal. */
    sealed class SectionChange {
        data class Name(val name: String) : SectionChange()
        data class Swatch(val swatch: String?) : SectionChange()
        data class MergeInto(val sectionId: String) : SectionChange()
        data object Remove : SectionChange()
    }
    fun boardSection(windowId: String, boardTabId: String, sectionId: String, change: SectionChange) = cmd("board.section") {
        put("windowId", windowId); put("boardTabId", boardTabId); put("sectionId", sectionId)
        when (change) {
            is SectionChange.Name -> put("name", change.name.trim())
            is SectionChange.Swatch -> put("swatch", change.swatch?.let(::JsonPrimitive) ?: JsonNull)
            is SectionChange.MergeInto -> put("mergeInto", change.sectionId)
            SectionChange.Remove -> put("remove", true)
        }
    }
    fun windowOpen(recentId: String) = cmd("window.open") { put("recentId", recentId) }
    fun windowReopen() = cmd("window.reopen")
    fun windowClose(windowId: String, force: Boolean = false) = cmd("window.close") { put("windowId", windowId); if (force) put("force", true) }
    fun historyOpen(windowId: String, sessionId: String) = cmd("history.open") { put("windowId", windowId); put("sessionId", sessionId) }
    fun historyRename(windowId: String, sessionId: String, title: String) = cmd("history.rename") {
        put("windowId", windowId); put("sessionId", sessionId); put("title", title.lines().joinToString(" ").trim().take(200))
    }
    fun historyArchive(windowId: String, sessionId: String, on: Boolean) = cmd("history.archive") {
        put("windowId", windowId); put("sessionId", sessionId); put("on", on)
    }

    // Reads: the request without its `id` (the client adds it).

    fun historyList(windowId: String, query: String = "", archived: Boolean = false, offset: Int = 0): JsonObject = buildJsonObject {
        put("t", "history.list"); put("windowId", windowId); put("query", query); put("archived", archived); put("offset", offset)
    }
    fun diffGet(chatId: String, turnId: String, path: String): JsonObject = buildJsonObject {
        put("t", "diff.get"); put("chatId", chatId); put("turnId", turnId); put("path", path)
    }
    /** The conversation before a compaction; it arrives as `tx.delta`. */
    fun txEarlier(chatId: String): JsonObject = buildJsonObject { put("t", "tx.earlier"); put("chatId", chatId) }
    /** Earlier entries of Kore's own transcript (1.1). */
    fun txMore(chatId: String, count: Int = 60): JsonObject = buildJsonObject { put("t", "tx.more"); put("chatId", chatId); put("count", count) }

    /** Asks the node for a raise nonce (`raise.chal`); the answer carries `nonce` (base64, 60 s, single use). */
    fun raiseChallenge(chatId: String, modeId: String): JsonObject = buildJsonObject {
        put("t", "raise.chal"); put("chatId", chatId); put("modeId", modeId)
    }

    /** The raise itself: the nonce and the `kore_raise` signature over `Raise.digest(B, nonce, chatId, modeId)`. */
    fun raise(chatId: String, modeId: String, nonce: String, sig: String) = cmd("raise") {
        put("chatId", chatId); put("modeId", modeId); put("nonce", nonce); put("sig", sig)
    }

    // Link messages that aren't commands.

    fun txOpen(chatId: String, last: Int = 60): JsonObject = buildJsonObject { put("t", "tx.open"); put("chatId", chatId); put("last", last) }
    fun txClose(chatId: String): JsonObject = buildJsonObject { put("t", "tx.close"); put("chatId", chatId) }
    /** Whether this phone is on screen (and which chat): off screen, a node sends attention only. */
    fun presence(onScreen: Boolean, chatId: String?): JsonObject = buildJsonObject {
        put("t", "presence"); put("onScreen", onScreen); putOpt("chatId", chatId)
    }
    fun blobGet(id: String, chatId: String, ref: String, variant: String, offset: Int = 0): JsonObject = buildJsonObject {
        put("t", "blob.get"); put("id", id); put("chatId", chatId); put("ref", ref); put("variant", variant); put("offset", offset)
    }
    /** A command in its envelope. */
    fun envelope(id: String, cmd: JsonObject): JsonObject = buildJsonObject { put("t", "cmd"); put("id", id); put("cmd", cmd) }

    const val NEW_GROUP = "new"
    const val NEW_SECTION = "new"

    /** The reply a read waits for. */
    fun replyTo(request: String): String? = when (request) {
        "history.list" -> "history.page"
        "diff.get" -> "diff.hunks"
        "import.list" -> "import.page"
        "at.search" -> "at.results"
        "raise.chal" -> "raise.chal"
        else -> null
    }
}
