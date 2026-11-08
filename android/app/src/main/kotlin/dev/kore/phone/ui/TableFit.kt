package dev.kore.phone.ui

/**
 * How a markdown table fits the width it has (design spec §5, "Markdown table"): a grid when
 * every column can get at least [min], its cells wrapping, else stacked cards, one per row.
 * Nothing scrolls sideways. Pure: the caller measures, this decides.
 */
object TableFit {
    sealed class Fit {
        /** Column widths that sum to at most the width: each at least the minimum, never more than it needs. */
        data class Grid(val widths: List<Int>) : Fit()
        /** One card per row: the first column as its title, then "Header  value" lines. */
        data object Stacked : Fit()
    }

    /**
     * [natural]: each column's width on one line (its widest cell, padding included); [words]:
     * each column's longest word (a cell may wrap between words, never inside one); [width]: what
     * the table has; [min]: the least a column may get. A column needs at least [min] and its
     * longest word; when those don't all fit, the table stacks (nothing is cut mid-word, spec §9).
     * Otherwise each column gets what it needs when all fit, or its least plus a share of the rest
     * in proportion to how much more it wants, so a wide column wraps more than a narrow one.
     */
    fun fit(natural: List<Int>, words: List<Int>, width: Int, min: Int): Fit {
        if (natural.isEmpty() || width <= 0) return Fit.Stacked
        val least = natural.indices.map { maxOf(min, words.getOrElse(it) { 0 }) }
        if (least.sum() > width) return Fit.Stacked
        if (natural.sum() <= width) return Fit.Grid(natural.map { maxOf(it, 1) })
        val wants = natural.indices.map { maxOf(0, natural[it] - least[it]) }
        val room = width - least.sum()
        val asked = wants.sum()
        val widths = natural.indices.map { least[it] + if (asked == 0) 0 else (wants[it].toLong() * room / asked).toInt() }.toMutableList()
        // Rounding leaves a few pixels: the widest column takes them, never past what it wants.
        val left = width - widths.sum()
        val widest = natural.indices.maxBy { natural[it] }
        widths[widest] = minOf(maxOf(natural[widest], least[widest]), widths[widest] + left)
        return Fit.Grid(widths)
    }

    /** A stacked card's header column: its [width], and which headers go [above] their value. */
    data class Headers(val width: Int, val above: List<Boolean>)

    /**
     * The header column of stacked cards: as wide as the widest header on one line ([natural]),
     * at least [min] and at most [cap] (40 % of the card), so short labels never wrap. A header
     * still wider wraps between its words; one whose longest word ([words]) doesn't fit goes
     * above its value instead of being cut.
     */
    fun headers(natural: List<Int>, words: List<Int>, min: Int, cap: Int): Headers {
        val width = (natural.maxOrNull() ?: 0).coerceIn(min, maxOf(min, cap))
        return Headers(width, words.map { it > width })
    }
}
