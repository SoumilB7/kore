package dev.kore.phone.ui

/** The "/" menu's filter: only while the message is a single slash word at its start. */
object Commands {
    fun filter(all: List<Pair<String, String>>, text: String, max: Int = 8): List<Pair<String, String>> {
        if (!text.startsWith("/") || text.any { it.isWhitespace() }) return emptyList()
        val query = text.drop(1).lowercase()
        val starts = all.filter { it.first.lowercase().startsWith(query) }
        val contains = all.filter { it !in starts && query.isNotEmpty() && it.first.lowercase().contains(query) }
        return (starts + contains).take(max)
    }

    /** What picking an entry puts in the message, as the Mac's `SlashCommand.insertion`: a Codex skill is `$name`. */
    fun insertion(name: String, kind: String?): String = if (kind == "skill") "\$$name " else "/$name "
}
