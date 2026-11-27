package dev.kore.phone.ui

/**
 * A question card's picks, as the Mac's `QuestionPicks`: the options by question id, the questions
 * whose Other is picked, and what's typed under Other. A one-of question holds one pick, an option
 * or Other, whichever came last; the words stay while an option has Other's place, and go only
 * while Other is picked.
 */
class CardPicks {
    val chosen = LinkedHashMap<String, MutableList<String>>()
    val other = HashSet<String>()

    /** An option picked, or unpicked when it was; a one-of's takes Other's place. */
    fun pick(qid: String, label: String, multiple: Boolean) {
        val list = chosen.getOrPut(qid) { mutableListOf() }
        if (list.contains(label)) list.remove(label) else { if (!multiple) list.clear(); list.add(label) }
        if (!multiple) other.remove(qid)
    }

    /** Other picked; a one-of's takes the option's place. */
    fun pickOther(qid: String, multiple: Boolean) {
        other.add(qid)
        if (!multiple) chosen[qid]?.clear()
    }

    /** A multi-select's typed answer unticked: its words stay in the field but aren't sent. */
    fun unpickOther(qid: String) { other.remove(qid) }

    fun on(qid: String, label: String) = chosen[qid]?.contains(label) == true

    /** A question has its answer, as the Mac's: something picked or typed, and no typed answer left empty. */
    fun answered(qid: String, typed: String?) =
        if (qid in other) !typed.isNullOrBlank() else chosen[qid]?.isNotEmpty() == true

    /** Each question's picks, then its words while Other is picked. */
    fun answers(typed: Map<String, String>): Map<String, List<String>> = LinkedHashMap<String, List<String>>().apply {
        chosen.forEach { (k, v) -> put(k, v.toList()) }
        typed.forEach { (k, t) -> t.trim().takeIf { k in other && it.isNotEmpty() }?.let { put(k, (get(k) ?: emptyList()) + it) } }
    }
}
