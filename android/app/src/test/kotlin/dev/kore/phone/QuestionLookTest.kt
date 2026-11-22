package dev.kore.phone

import dev.kore.phone.ui.CardPicks
import dev.kore.phone.ui.QuestionLook
import dev.kore.phone.ui.QuestionLook.Row
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The phone's question card (phone-question-card.html): everything shows, sized by its content, no fade. */
class QuestionLookTest {
    private val two = listOf(
        Row("Patch 0.3.9.1 now (Recommended)", "Only kore-host changes. Boxes pick it up on their next update; the Mac app stays on 0.3.9.", null),
        Row("Wait for 0.3.10", "It ships with the rest of 0.3.10, later this week.", null),
    )

    @Test fun everyOptionShowsThenTypeAnAnswer() {
        val rows = QuestionLook.rows(two, other = true)
        assertEquals(listOf("Patch 0.3.9.1 now (Recommended)", "Wait for 0.3.10", "Type an answer"), rows.map { it.label })
        assertEquals(listOf(false, false, true), rows.map { it.typed })
        // Descriptions come through whole, never cut.
        assertEquals(two[0].description, rows[0].description)
    }

    @Test fun noTypedRowWhenTheQuestionTakesNone() {
        assertEquals(2, QuestionLook.rows(two, other = false).size)
    }

    @Test fun blankLabelsAreDroppedAndPreviewsKept() {
        val rows = QuestionLook.rows(listOf(Row("", null, null), Row("Grid", null, "┌──┬──┐")), other = false)
        assertEquals(listOf("Grid"), rows.map { it.label })
        assertEquals("┌──┬──┐", rows[0].preview)
    }

    @Test fun labelsTakeOneLineDescriptionsWrapInFull() {
        assertEquals(1, QuestionLook.LABEL_LINES)
        assertEquals(Int.MAX_VALUE, QuestionLook.DESCRIPTION_LINES)
    }

    @Test fun aQuestionWithNoOptionsIsTyped() {
        assertEquals(listOf(Row("Type an answer", null, null, typed = true)), QuestionLook.rows(emptyList(), other = false))
    }

    @Test fun aBodyThatFitsShowsWholeThePeekGivingWay() {
        // A 760-high column: composer 66 and the card's button 80 leave 614.
        assertEquals(614, QuestionLook.bodyCap(room = 760, composer = 66, chrome = 80, content = 230, peek = 96))
        // Over 614 - 96 but it fits: every option shows.
        assertEquals(614, QuestionLook.bodyCap(room = 760, composer = 66, chrome = 80, content = 614, peek = 96))
    }

    @Test fun aBodyTooLongScrollsUnderThePeek() {
        assertEquals(518, QuestionLook.bodyCap(room = 760, composer = 66, chrome = 80, content = 615, peek = 96))
        // Landscape: 120 left, the peek takes a quarter at most.
        assertEquals(90, QuestionLook.bodyCap(room = 266, composer = 66, chrome = 80, content = 230, peek = 96))
    }

    @Test fun theKeyboardTakesThePeek() {
        assertEquals(96, QuestionLook.peek(keyboardUp = false, peekPx = 96))
        assertEquals(0, QuestionLook.peek(keyboardUp = true, peekPx = 96))
        assertEquals(284, QuestionLook.bodyCap(room = 430, composer = 66, chrome = 80, content = 400, peek = QuestionLook.peek(true, 96)))
    }

    @Test fun theComposerIsNeverPushedOff() {
        assertEquals(0, QuestionLook.bodyCap(room = 100, composer = 66, chrome = 80, content = 230, peek = 96))
    }

    @Test fun onlyOneSingleChoiceQuestionAnswersOnATap() {
        assertTrue(QuestionLook.tapAnswers(1, multiple = false, canSubmit = true))
        assertFalse(QuestionLook.tapAnswers(1, multiple = true, canSubmit = true))
        assertFalse(QuestionLook.tapAnswers(2, multiple = false, canSubmit = true))
        assertFalse(QuestionLook.tapAnswers(1, multiple = false, canSubmit = false))
    }

    @Test fun overlineNamesTheHeaderOnlyWithoutTabs() {
        assertEquals("Needs you · Release", QuestionLook.overline("Release", tabs = false))
        assertEquals("Needs you", QuestionLook.overline("Release", tabs = true))
        assertEquals("Needs you", QuestionLook.overline(" ", tabs = false))
        assertEquals("Question 2", QuestionLook.tabName(null, 1))
    }

    @Test fun nextGoesToTheNextUnansweredThenSubmit() {
        assertEquals(QuestionLook.Footer("Next", 1, true), QuestionLook.footer(0, listOf(true, false)))
        // Past the end it wraps to an earlier one.
        assertEquals(QuestionLook.Footer("Next", 0, true), QuestionLook.footer(2, listOf(false, true, true)))
        // The shown one unanswered: Submit, dim.
        assertEquals(QuestionLook.Footer("Submit", null, false), QuestionLook.footer(1, listOf(true, false)))
        assertEquals(QuestionLook.Footer("Submit", null, true), QuestionLook.footer(1, listOf(true, true)))
        assertNull(QuestionLook.footer(0, listOf(true)).goTo)
    }

    @Test fun typedWordsAnswerAndMultiSelectKeepsTicksWithThem() {
        val q = "Which checks?"
        val picks = CardPicks()
        assertFalse(picks.answered(q, null))
        picks.pick(q, "Focused tests", multiple = true)
        picks.pickOther(q, multiple = true)
        // Ticked but empty, it isn't answered yet, as on the Mac.
        assertFalse(picks.answered(q, ""))
        assertTrue(picks.answered(q, "and the phone build"))
        assertEquals(mapOf(q to listOf("Focused tests", "and the phone build")), picks.answers(mapOf(q to "and the phone build")))
        // Unticked, the words stay in the field but aren't sent.
        picks.unpickOther(q)
        assertEquals(mapOf(q to listOf("Focused tests")), picks.answers(mapOf(q to "and the phone build")))
    }

    @Test fun aTypedAnswerAloneNeedsWords() {
        val q = "Patch or wait?"
        val picks = CardPicks()
        picks.pickOther(q, multiple = false)
        assertFalse(picks.answered(q, "  "))
        assertTrue(picks.answered(q, "Patch after the live check"))
    }

    /** No soft edge on the card or its options: the constant, and no fade switched on in the card's code. */
    @Test fun nothingInTheCardFades() {
        assertEquals(0, QuestionLook.EDGE_FADE)
        val src = listOf("ChatActions.kt", "QuestionLook.kt").map { File(ui(), it).readText() }
        src.forEach {
            assertFalse(it.contains("isVerticalFadingEdgeEnabled = true"))
            assertFalse(Regex("""setFadingEdgeLength\(activity\.dp\(\d+\)\)""").containsMatchIn(it))
            assertFalse(it.contains("LinearGradient"))
        }
    }

    /** Every option row of the card shows its description in full: no line cap on it in the code. */
    @Test fun noDescriptionIsCut() {
        val src = File(ui(), "ChatActions.kt").readText()
        val questions = src.substring(src.indexOf("private fun showQuestions"), src.indexOf("private fun showOption"))
        assertTrue(questions.contains("maxLines = QuestionLook.DESCRIPTION_LINES"))
        assertFalse(questions.contains("maxLines = 1;"))
    }

    private fun ui(): File = listOf("src/main/kotlin/dev/kore/phone/ui", "app/src/main/kotlin/dev/kore/phone/ui").map(::File).first { it.isDirectory }
}
