package dev.kore.phone.ui

import kotlinx.serialization.json.JsonObject

/**
 * What a device says it does in its welcome (`caps`), for the menus that offer it: tab groups and
 * boards are a Mac's ("group", "board"); a box ("box") has neither, so its windows offer only
 * tabs. Files go where "blob" is said.
 */
object Offers {
    fun caps(welcome: JsonObject?): Set<String> = welcome?.strs("caps").orEmpty().toSet()

    fun groups(caps: Set<String>): Boolean = "group" in caps || unsaid(caps)
    fun boards(caps: Set<String>): Boolean = "board" in caps || unsaid(caps)
    fun uploads(caps: Set<String>): Boolean = "blob" in caps || "upload" in caps

    /** A Mac from before 0.3.5 did groups and boards without saying so; every box says "box". */
    private fun unsaid(caps: Set<String>): Boolean = caps.isNotEmpty() && "box" !in caps && "group" !in caps && "board" !in caps

    /** A tab's long-press items, by label, in order. */
    fun tabItems(caps: Set<String>, box: Boolean, hasBoards: Boolean, closable: Boolean): List<String> = listOfNotNull(
        "Rename…",
        "Show on the Mac".takeIf { !box },
        "Group".takeIf { groups(caps) },
        "Attach to board".takeIf { boards(caps) && hasBoards },
        "Close tab".takeIf { closable },
    )

    /** ＋'s rows past the chats, by label. */
    fun newItems(caps: Set<String>, canReopen: Boolean): List<String> = listOfNotNull(
        "Board".takeIf { boards(caps) },
        "Reopen closed tab".takeIf { canReopen },
    )

    /** Why 📎 doesn't open here, in one line; null when files can go. */
    fun uploadsOff(caps: Set<String>, control: Boolean, box: Boolean, name: String): String? = when {
        uploads(caps) -> null
        !control -> "This phone can only watch $name."
        box -> "Files need a newer kore-host on $name."
        else -> "Files need a newer Kore on $name."
    }
}
