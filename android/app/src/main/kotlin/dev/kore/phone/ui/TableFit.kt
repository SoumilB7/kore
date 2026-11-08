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
     * [natural]: each column's width on one line (its widest cell, padding included); [width]:
     * what the table has; [min]: the least a column may get. A grid gives each column what it
     * needs when all fit; otherwise each gets [min] and the rest is shared in proportion to how
     * much more each one wants, so a wide column wraps more than a narrow one.
     */
    fun fit(natural: List<Int>, width: Int, min: Int): Fit {
        if (natural.isEmpty() || width <= 0) return Fit.Stacked
        if (natural.size * min > width) return Fit.Stacked
        if (natural.sum() <= width) return Fit.Grid(natural.map { maxOf(it, 1) })
        val wants = natural.map { maxOf(0, it - min) }
        val room = width - natural.size * min
        val asked = wants.sum()
        val widths = wants.map { want -> min + if (asked == 0) 0 else (want.toLong() * room / asked).toInt() }.toMutableList()
        // Rounding leaves a few pixels: the widest column takes them, never past what it wants.
        val left = width - widths.sum()
        val widest = natural.indices.maxBy { natural[it] }
        widths[widest] = minOf(natural[widest], widths[widest] + left)
        return Fit.Grid(widths)
    }
}
