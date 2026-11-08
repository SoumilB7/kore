package dev.kore.phone.ui

/**
 * A table as "Copy table" puts it on the clipboard: the same text the Mac copies for a table
 * (its Copy, or a selection of all of it): the header, then a line per row, cells split by tabs.
 */
object TableCopy {
    fun text(header: List<String>, rows: List<List<String>>): String =
        (listOf(header) + rows).joinToString("\n") { it.joinToString("\t") }
}
