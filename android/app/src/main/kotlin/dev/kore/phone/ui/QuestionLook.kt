package dev.kore.phone.ui

/**
 * The question card's rules (z-docs/design/phone-question-card.html), apart from its views so they
 * can be tested: every option and its whole description show, a question that takes a typed answer
 * ends with "Type an answer", and the card is as tall as what it holds. The transcript above gives
 * way before anything in the card scrolls, and nothing in it fades.
 */
object QuestionLook {
    /** The last row of a question that takes a typed answer (the Mac's Other). */
    const val TYPE_ANSWER = "Type an answer"
    const val TYPE_HINT = "Your answer"

    /** Under the description of an option that has a preview: a hold shows it. */
    const val PREVIEW_CUE = "Preview · hold to see it"

    /** TalkBack's name for the hold. */
    const val DETAILS_ACTION = "Show details"

    /** How much of the transcript stays above a card too long to show whole, in dp, while the keyboard is down. */
    const val PEEK = 96

    /** Soft edges, in dp, on anything in the card that scrolls: none (owner: "blur is bad"). */
    const val EDGE_FADE = 0

    /** An option's label takes one line; its description wraps in full. */
    const val LABEL_LINES = 1
    const val DESCRIPTION_LINES = Int.MAX_VALUE

    /** A row of a question: one of its options, or [TYPE_ANSWER]. */
    data class Row(val label: String, val description: String?, val preview: String?, val typed: Boolean = false)

    /**
     * Each option, in the CLI's order, and "Type an answer" after them when the question takes one.
     * A question with no options can only be typed (Codex), whatever it says of Other, as on the Mac.
     */
    fun rows(options: List<Row>, other: Boolean): List<Row> {
        val picks = options.filter { it.label.isNotBlank() }
        return if (other || picks.isEmpty()) picks + Row(TYPE_ANSWER, null, null, typed = true) else picks
    }

    /** One single-choice question: a tap on an option is the answer, and there's no Submit. */
    fun tapAnswers(questions: Int, multiple: Boolean, canSubmit: Boolean) = canSubmit && questions == 1 && !multiple

    /** The top line: "Needs you", then the question's short header when there's one and no tabs. */
    fun overline(header: String?, tabs: Boolean): String =
        header?.trim()?.takeIf { it.isNotEmpty() && !tabs }?.let { "Needs you · $it" } ?: "Needs you"

    /** A tab's name: the CLI's short header, else "Question N". */
    fun tabName(header: String?, index: Int): String = header?.trim()?.takeIf { it.isNotEmpty() } ?: "Question ${index + 1}"

    /**
     * The most the card's body may take, in px, out of [room], once the composer and what's below
     * the body in the card ([chrome]) are kept. Whole ([content]) whenever that fits, the transcript
     * giving way as far as it must, so every option shows; too long for that, it scrolls, and the
     * transcript keeps its [peek], at most a quarter of the room (landscape). The composer is always whole.
     */
    fun bodyCap(room: Int, composer: Int, chrome: Int, content: Int, peek: Int): Int {
        val left = maxOf(0, room - composer - chrome)
        return if (content <= left) left else left - minOf(peek, left / 4)
    }

    /** The peek in px: none while the keyboard is up, so the field and Send stay over it. */
    fun peek(keyboardUp: Boolean, peekPx: Int): Int = if (keyboardUp) 0 else peekPx

    /**
     * The bottom button: Next (and the question it goes to) while the shown one is answered and
     * another isn't, as the Mac's; else Submit, live only once every question is answered.
     */
    data class Footer(val label: String, val goTo: Int?, val live: Boolean)

    fun footer(shown: Int, answered: List<Boolean>): Footer {
        val next = if (answered.getOrElse(shown) { false }) {
            (1 until answered.size).map { (shown + it) % answered.size }.firstOrNull { !answered[it] }
        } else null
        return if (next != null) Footer("Next", next, live = true) else Footer("Submit", null, live = answered.isNotEmpty() && answered.all { it })
    }
}
