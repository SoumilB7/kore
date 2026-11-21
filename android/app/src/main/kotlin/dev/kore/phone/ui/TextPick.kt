package dev.kore.phone.ui

import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.widget.TextView

/**
 * Picking part of a chat's text (owner, 2026-11-20): a message's bubble and an answer's text
 * (paragraphs, code, table cells) take the system's selection, a long-press then the handles and
 * its Copy · Share · Select all, with one more item, [MESSAGE], for the message's own menu (Copy,
 * Fork, Roll back). A long-press beside the text (outside the bubble, between an answer's blocks)
 * still opens that menu. Only the rows on screen hold text views; nothing runs per frame.
 */
object TextPick {
    /** The rows whose text can be picked from. */
    private val KINDS = setOf("user", "answer", "plan")

    /** The selection toolbar's item that opens the message menu. */
    const val MESSAGE = "Message…"

    /** That item's id: clear of the system's own (`android.R.id.*`). */
    const val MESSAGE_ID = 0x4b50

    /** After the system's Select all (order 8 in its toolbar), before its text actions (100 on). */
    const val ORDER = 9

    fun selectable(kind: String?): Boolean = kind in KINDS

    /**
     * A finger that went down and up within [slop] px of where it started and before a long-press
     * ([longPressMs]): a tap (an image in a bubble opens), not the start of a selection.
     */
    fun isTap(dx: Float, dy: Float, ms: Long, slop: Int, longPressMs: Long): Boolean =
        ms < longPressMs && dx * dx + dy * dy <= slop.toFloat() * slop
}

/** A chat row whose text picks: [menu] opens its message menu at the view that asked; null for none. */
interface PickRow {
    val menu: ((View) -> Unit)?
}

/**
 * What holds the picking rows (the chat's list): told when a selection's toolbar opens and when it
 * closes, so the list holds still under the handles and a row holding a selection isn't redrawn.
 */
interface PickWatch {
    fun picking(v: TextView, on: Boolean)
}

/**
 * [this] picks ([on]) or not: the system's selection, its toolbar with [TextPick.MESSAGE] for the
 * menu of the row it sits in ([PickRow], looked up when the toolbar opens, so a view built later,
 * a table's cells once its width is known, needs nothing more). Cheap to call on every bind.
 */
fun TextView.picks(on: Boolean = true) {
    if (isTextSelectable != on) setTextIsSelectable(on)
    if (on && customSelectionActionModeCallback !is PickToolbar) customSelectionActionModeCallback = PickToolbar(this)
}

private class PickToolbar(private val v: TextView) : ActionMode.Callback {
    /** The list told this selection opened; told again, the same one, when it closes (the row may be gone by then). */
    private var watch: PickWatch? = null

    override fun onCreateActionMode(mode: ActionMode, m: Menu): Boolean {
        if (row() != null) m.add(Menu.NONE, TextPick.MESSAGE_ID, TextPick.ORDER, TextPick.MESSAGE)
        watch = up<PickWatch>()
        watch?.picking(v, true)
        return true
    }

    override fun onPrepareActionMode(mode: ActionMode, m: Menu) = false

    override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
        if (item.itemId != TextPick.MESSAGE_ID) return false
        val open = row() ?: return false
        mode.finish()
        open(v)
        return true
    }

    override fun onDestroyActionMode(mode: ActionMode) {
        watch?.picking(v, false)
        watch = null
    }

    private fun row(): ((View) -> Unit)? = up<PickRow>()?.menu

    private inline fun <reified T> up(): T? {
        var at = v.parent
        while (at != null) {
            if (at is T) return at
            at = at.parent
        }
        return null
    }
}
